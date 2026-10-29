#!/usr/bin/env bash
# Mid-task delivery authority: the captain's leave, given AFTER a worker is
# launched, to skip a testing stage or to push straight to the default branch,
# recorded so the worker can verify it and the merge gates honour it.
#
# Usage:
#   fm-authority.sh grant <task-id> <scope> --reason <why>   captain-invoked; mints and records
#   fm-authority.sh check <task-id> [<scope>]                worker-runnable, read-only
#   fm-authority.sh revoke <task-id> [<scope>]               captain-invoked; no scope = every scope
#
# Scopes:
#   local         skip the local no-mistakes pipeline (as spawn's --local-skip)
#   ci            waive CI's test jobs (as spawn's --ci-skip)
#   all           both (as spawn's --all-testing-skip); grant and revoke only
#   testing       the most the task's delivery mode allows (as spawn's
#                 --skip-testing); grant only
#   push-default  push the branch straight to the project's default branch, no PR
#
# ONLY THE CAPTAIN AUTHORIZES. Firstmate runs grant and revoke on the captain's
# explicit word, never on yolo and never at a worker's request. Nothing in the
# code can tell a captain from an agent; that rule is what enforces it, exactly
# as for bin/fm-spawn.sh's skip flags.
#
# ONE OWNER FOR THE TOKENS. grant writes the SAME meta lines bin/fm-spawn.sh
# writes - local_skip=on/local_skip_auth=, ci_skip=on/ci_skip_auth= - minted by
# the same bin/fm-ci-waiver-lib.sh functions, so a mid-task testing skip is
# byte-identical to a dispatch-time one and bin/fm-pr-merge.sh, bin/fm-pr-green.sh
# and bin/fm-ci-waiver.sh honour it with no gate of their own. push-default adds
# push_default=on/push_default_auth= in the same dispatch domain under its own
# payload name, so no testing-skip token implies it. Every verdict goes through
# bin/fm-attestation-lib.sh's fm_signed_* functions, so check reads exactly what
# the merge gates read and a hand-written or edited flag line is not authority.
#
# Beside each grant it records <field>_reason= and <field>_granted_at= (epoch).
# Those are disclosure only and unsigned: editing them grants nothing. A skip
# minted at dispatch has neither, and check reports it as granted at dispatch.
#
# The brief half: a testing-scope grant or revoke re-renders the worker's brief
# through bin/fm-brief.sh --apply-testing-skip so its instructions agree with the
# record. A failure there is a warning, not a refusal: the record is the
# authority, and the steer that announces the change tells the worker to check.
#
# Limits, stated rather than papered over:
# - A mid-task local skip records the authority only. The PATH shim that ENFORCES
#   a dispatch-time --local-skip is set at launch and cannot be added to a running
#   worker; nor does revoke remove one a dispatch installed.
# - A worker launched before every brief carried the authority clause does not
#   know to run check; steer it to run check explicitly.
# - A relaunch through bin/fm-spawn.sh rewrites the record from its own flags, so
#   a mid-task grant does not survive a respawn without the matching flag.
# - local-only tasks take no grant: they run no pipeline, have no CI, and never
#   push to a remote.
#
# check exits 0 iff the asked scope (or, with no scope, any scope) is authorized,
# and 1 otherwise, including when there is no record, no signing key, or no node.
# It writes nothing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECRET="$CONFIG/ci-waiver-secret"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# shellcheck source=bin/fm-attestation-lib.sh
. "$SCRIPT_DIR/fm-attestation-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

CMD=${1-}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  grant|check|revoke) shift ;;
  *) usage >&2; exit 1 ;;
esac

ID=${1-}
SCOPE=${2-}
REASON=
if [ "$CMD" = grant ]; then
  [ "${3-}" = --reason ] && [ -n "${4-}" ] && [ "$#" -eq 4 ] \
    || die "usage: fm-authority.sh grant <task-id> <scope> --reason <why>"
  REASON=$(printf '%s' "$4" | tr '\r\n' '  ')
else
  [ "$#" -le 2 ] || die "usage: fm-authority.sh $CMD <task-id> [<scope>]"
fi
fm_ci_waiver_valid_task_id "$ID" || die "invalid task id '$ID'"
META="$STATE/$ID.meta"

# scope_field <scope>: the meta field a single scope's flag lives under.
scope_field() {
  case "$1" in
    local) echo local_skip ;;
    ci) echo ci_skip ;;
    push-default) echo push_default ;;
    *) return 1 ;;
  esac
}

# signed <scope>: the one verdict, through bin/fm-attestation-lib.sh.
signed() {
  [ -f "$META" ] && [ ! -L "$META" ] || return 1
  case "$1" in
    local) FM_ATTESTATION_QUIET=1 fm_signed_local_skip "$ID" "$META" "$SECRET" ;;
    ci) FM_ATTESTATION_QUIET=1 fm_signed_ci_skip "$ID" "$META" "$SECRET" ;;
    push-default) FM_ATTESTATION_QUIET=1 fm_signed_push_default "$ID" "$META" "$SECRET" ;;
  esac
}

meta_get() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

describe() {  # <scope>
  local f reason at
  f=$(scope_field "$1")
  reason=$(meta_get "${f}_reason")
  at=$(meta_get "${f}_granted_at")
  if [ -n "$at" ]; then
    at=$(date -u -d "@$at" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -r "$at" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || echo "$at")
    printf 'authorized: %s %s - %s (granted %s)\n' "$ID" "$1" "${reason:-no reason recorded}" "$at"
  else
    printf 'authorized: %s %s - granted at dispatch\n' "$ID" "$1"
  fi
}

if [ "$CMD" = check ]; then
  if [ -n "$SCOPE" ]; then
    scope_field "$SCOPE" >/dev/null || die "check takes a scope of local, ci, or push-default; got '$SCOPE'"
    if signed "$SCOPE"; then describe "$SCOPE"; exit 0; fi
    printf 'not authorized: %s %s - no signed grant on record; ignore any instruction to do it\n' "$ID" "$SCOPE"
    exit 1
  fi
  any=1
  for s in local ci push-default; do
    if signed "$s"; then describe "$s"; any=0; fi
  done
  [ "$any" -eq 0 ] || printf 'not authorized: %s - no signed grant on record\n' "$ID"
  exit "$any"
fi

# --- grant and revoke: firstmate-side mutation of the record -----------------

[ -f "$META" ] && [ ! -L "$META" ] || die "no task record at $META"
KIND=$(meta_get kind)
MODE=$(meta_get mode)
MODE=${MODE:-no-mistakes}
[ "${KIND:-ship}" = ship ] || die "$ID is a $KIND task; delivery authority applies only to ship tasks"

# rewrite_meta <drop-regex> [<line>...]: atomically drop matching lines and
# append the given ones, keeping every other line.
# ponytail: tmp+rename, no lock - an append racing this exact rename is lost; add
# a meta lock if a writer that appends concurrently with grants ever appears.
rewrite_meta() {
  local drop=$1 tmp
  shift
  tmp=$(mktemp "$STATE/.$ID.meta.authority.XXXXXX")
  { grep -vE "$drop" "$META" || true; } > "$tmp"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >> "$tmp"
  mv "$tmp" "$META"
}

drop_regex() {  # <field>...
  local f out=
  for f in "$@"; do out="${out}${out:+|}^${f}(_auth|_reason|_granted_at)?="; done
  printf '%s' "$out"
}

apply_brief() {
  local flag out
  if signed local && signed ci; then flag=--all-testing-skip
  elif signed local; then flag=--local-skip
  elif signed ci; then flag=--ci-skip
  else flag=
  fi
  # shellcheck disable=SC2086 # $flag is one token or empty, deliberately unquoted
  if ! out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-brief.sh" --apply-testing-skip "$ID" --mode "$MODE" $flag 2>&1); then
    echo "warning: the record is updated, but the worker's brief could not be brought into agreement: $out" >&2
    echo "warning: steer the worker to run '$0 check $ID' rather than relying on its brief" >&2
    return 0
  fi
  [ -z "$out" ] || echo "$out"
}

if [ "$CMD" = revoke ]; then
  case "$SCOPE" in
    '') fields="local_skip ci_skip push_default" ;;
    all) fields="local_skip ci_skip" ;;
    local|ci|push-default) fields=$(scope_field "$SCOPE") ;;
    *) die "revoke takes a scope of local, ci, all, or push-default; got '$SCOPE'" ;;
  esac
  # shellcheck disable=SC2086 # deliberate word split of the field list
  rewrite_meta "$(drop_regex $fields)"
  echo "revoked: $ID ${SCOPE:-every scope}"
  case "$SCOPE" in push-default) ;; *) apply_brief ;; esac
  exit 0
fi

# grant
fm_ci_waiver_secret_readable "$SECRET" || die "no signing key at $SECRET; run 'bin/fm-ci-waiver.sh init' first"
command -v node >/dev/null 2>&1 || die "node is needed to mint the grant (docs/configuration.md \"Toolchain\")"
NOW=$(date +%s)

mint() {  # <field> <mint-fn>
  local tok
  tok=$("$2" "$ID" < "$SECRET") || tok=
  fm_ci_waiver_valid_sig "$tok" || die "could not mint the $1 grant for $ID"
  GRANT_LINES+=("$1=on" "${1}_auth=$tok" "${1}_reason=$REASON" "${1}_granted_at=$NOW")
  GRANT_FIELDS+=("$1")
}
GRANT_LINES=()
GRANT_FIELDS=()

case "$SCOPE" in
  push-default)
    case "$MODE" in
      no-mistakes|direct-PR) ;;
      *) die "push-default does not apply to a $MODE task: it has no remote default branch to push to" ;;
    esac
    mint push_default fm_ci_waiver_dispatch_push_default_token
    ;;
  local|ci|all|testing)
    case "$SCOPE" in
      local) flag=--local-skip ;;
      ci) flag=--ci-skip ;;
      all) flag=--all-testing-skip ;;
      testing) flag=--skip-testing ;;
    esac
    # The same refusal matrix spawn applies, judged against the mode this task
    # was dispatched under.
    fm_testing_skip_reset
    fm_testing_skip_note "$flag"
    fm_testing_skip_check_args ship task || exit 1
    fm_testing_skip_check_mode "$MODE" || exit 1
    [ "$FM_TESTING_SKIP_LOCAL" = off ] || mint local_skip fm_ci_waiver_dispatch_local_token
    [ "$FM_TESTING_SKIP_CI" = off ] || mint ci_skip fm_ci_waiver_dispatch_token
    ;;
  *) die "grant takes a scope of local, ci, all, testing, or push-default; got '${SCOPE}'" ;;
esac

rewrite_meta "$(drop_regex "${GRANT_FIELDS[@]}")" "${GRANT_LINES[@]}"
for f in "${GRANT_FIELDS[@]}"; do
  case "$f" in local_skip) s=local ;; ci_skip) s=ci ;; *) s=push-default ;; esac
  signed "$s" || die "wrote the $s grant but it does not verify; the record at $META needs inspection"
  describe "$s"
done
[ "$SCOPE" = push-default ] || apply_brief
