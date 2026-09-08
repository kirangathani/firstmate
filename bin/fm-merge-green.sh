#!/usr/bin/env bash
# The captain's MECHANICAL merge switch: land every open task PR that is
# genuinely green, through every existing pre-merge gate, with no judgement in
# the loop.
#
# WHAT IT IS NOT. It is not a merge path. Every candidate is merged by
# bin/fm-pr-merge.sh, invoked exactly as firstmate invokes it by hand, with no
# extra flag and nothing that weakens a gate. This script decides only WHICH
# tasks to hand it, in WHAT ORDER, and what to do with each answer. "Green"
# therefore means precisely what that script's header says it means, including
# its excusal of the `PR must be raised via no-mistakes` attestation check for a
# task carrying a signed testing skip or a direct-PR project - which is what
# makes a waivered PR mechanically green here. That excusal already has one
# owner, bin/fm-attestation-lib.sh, shared by the merge gate and
# bin/fm-pr-green.sh; nothing about it is re-read, re-implemented, or loosened
# here.
#
# HOW IT TELLS THE ANSWERS APART. bin/fm-pr-merge.sh prints
# `fm-pr-merge-refusal: <code>` as the last line of a gate refusal (contract in
# its header). This reads that code, never its English sentences, so the two
# scripts cannot drift into two readings of which gate refused. A refusal
# carrying NO code is machinery that could not reach a verdict and is reported
# as unverified, never as a named gate.
#
# THE SERIAL MERGE QUEUE (captain's ruling, 2026-09-08). When several branches
# are queued against one main, merging the first moves main under every other
# one, and their green CI was measured against a base that no longer exists. So
# candidates are processed ONE AT A TIME, oldest dispatch first:
#   - A candidate that merges moves main. The next candidate's own run of
#     bin/fm-pr-merge.sh fetches the base fresh, so it is re-evaluated against
#     the main this run just created rather than the one it was queued against.
#   - A candidate the up-to-date gate refuses is exactly one main-merge behind.
#     ITS worker - and only its worker - is steered to merge origin/main forward
#     and push, and the run STOPS there: every remaining candidate is reported
#     `queued-behind` and is NOT steered. Steering two siblings at once is what
#     made PRs 71 and 73 each pay two update cycles on 2026-09-08; each branch
#     should need exactly one, and the summary prints how many each has needed.
#   - A candidate refused for its OWN reasons (red checks, attribution, a
#     resolution that deleted content) does not stop the queue: it is reported
#     and the run moves to the next candidate. It is not waiting on main.
#
# THE RE-VERIFICATION AFTER A MAIN MERGE is the push itself, and no third path
# is invented: .github/workflows/reverify-base.yml triggers on `pull_request`,
# so pushing the merge commit re-runs both the branch's own CI and the
# `Base assertions re-verified` check against the NEW head. That workflow runs
# only the base test files that DIFFER from the branch's copies, which is the
# fast path the captain chose; its trade-off is that identical files are not
# re-run there, and what covers them is the branch's own CI on the merged head,
# plus the up-to-date gate, which still refuses any head that does not contain
# the current base tip. So no branch lands whose head was never built against
# the tip it lands on.
#
# FIRSTMATE NEVER WRITES TO A PROJECT. This script merges PRs and steers
# workers; it never merges origin/main into a task branch itself. That work
# belongs to the branch's own worker, which is why a needs-main-merge candidate
# produces a steer rather than a git command.
#
# Usage: fm-merge-green.sh [--dry-run] [<task-id>...]
#   With no task ids, every task in this home whose record carries a pr= is a
#   candidate, oldest dispatch first (bin/fm-spawned-at-lib.sh). With task ids,
#   only those, in the same order.
#   --dry-run merges nothing and steers nobody. It prints the same table, with
#   each candidate's greenness read through bin/fm-pr-green.sh - the same
#   verdict the merge gate reaches, minus the gates that cost the base's whole
#   test suite to evaluate. It is a preview, not a promise: only a real run puts
#   a candidate through every gate.
# Exit 0 when nothing was refused for a reason of its own; 1 when something was
#   (needs-main-merge and queued-behind are not refusals - they are this run's
#   own queue working); 2 on a malformed request.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# This steers workers and merges PRs, so it is a fleet mutation and a
# no-mistakes gate agent must never reach it (bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-spawned-at-lib.sh
. "$SCRIPT_DIR/fm-spawned-at-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  cat <<'EOF'
usage: fm-merge-green.sh [--dry-run] [<task-id>...]
  Land every open task PR that is genuinely green, one at a time, through
  bin/fm-pr-merge.sh's own gates. --dry-run merges nothing and steers nobody.
EOF
}

TAB=$'\t'
DRY_RUN=0
# Newline-delimited rather than an array so an EMPTY value stays safe to expand
# under `set -u` on every Bash this repo supports, stock macOS 3.2 included -
# the same reason bin/fm-pr-merge.sh keeps ATTESTATION_AUTHORITY a string.
WANTED=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) usage >&2; exit 2 ;;
    *)
      fm_pr_task_id_valid "$1" || { echo "error: not a task id: $1" >&2; exit 2; }
      WANTED=$WANTED$1$'\n'
      shift
      ;;
  esac
done

if [ ! -d "$STATE" ]; then
  echo "error: no fleet state at $STATE, so this home has no PRs to land" >&2
  exit 2
fi

# --- candidate selection ------------------------------------------------------
# A candidate is a task record carrying a recorded pr=. A secondmate record
# never carries one and a scout never opens a PR, so neither needs excluding by
# kind. The order is dispatch order, oldest first, read through the one owner of
# that question; a record with no readable dispatch time sorts on 0 and ties are
# broken by id, so the order is total and repeatable.
CANDIDATES=
collect_candidate() {  # <id>
  local id=$1 at
  local meta=$STATE/$id.meta
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  grep -q '^pr=' "$meta" || return 1
  at=$(fm_spawned_at "$STATE" "$id")
  case "${at:-}" in ''|*[!0-9]*) at=0 ;; esac
  CANDIDATES=$CANDIDATES$at$TAB$id$'\n'
  return 0
}

if [ -n "$WANTED" ]; then
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    collect_candidate "$want" || {
      echo "error: task $want has no recorded PR in $STATE, so there is nothing to land for it" >&2
      exit 2
    }
  done <<EOF_WANTED
$WANTED
EOF_WANTED
else
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    collect_candidate "$id" || true
  done
fi

if [ -z "$CANDIDATES" ]; then
  echo "no task in this home has a PR waiting to land."
  exit 0
fi

ORDERED=$(printf '%s' "$CANDIDATES" | sort -t"$TAB" -k1,1n -k2,2)

# --- update-round bookkeeping -------------------------------------------------
# One line per steer this switch has sent for a task, so the summary can report
# how many update rounds a branch has needed. The captain's target is one; a two
# is evidence that two siblings were steered against the same main, which the
# serial queue above exists to prevent. Removed by bin/fm-teardown.sh with the
# rest of the task's records.
rounds_file() { printf '%s/%s.merge-green-rounds' "$STATE" "$1"; }

rounds_count() {  # <id>
  local f
  f=$(rounds_file "$1")
  if [ -f "$f" ]; then
    awk 'END { print NR + 0 }' "$f"
  else
    printf '0\n'
  fi
}

rounds_record() {  # <id>
  local f
  f=$(rounds_file "$1")
  ( umask 077; date -u +%Y-%m-%dT%H:%M:%SZ >> "$f" ) 2>/dev/null || true
}

# --- the steer for a branch main has moved under ------------------------------
# One line, because bin/fm-send.sh submits one line. It names the merge (never a
# rebase: a rebased branch cannot be pushed at all here), the re-verification,
# and the report, so the worker needs nothing else from this run.
steer_text() {  # <id> <url>
  printf 'main has moved under your PR %s - merge it forward and re-verify: git fetch origin && git merge origin/main (NEVER rebase), resolve additively keeping both sides, run the project lint and full test suite, push, then confirm with bin/fm-pr-green.sh %s %s and report done when it is green.' \
    "$2" "$1" "$2"
}

# steer_worker <id> <url>: steer that task's worker, or say why it could not be
# steered. Prints one indented line. Returns 0 when the steer landed.
steer_worker() {
  local id=$1 url=$2 backend target label verdict pane resume
  local meta=$STATE/$id.meta
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  if [ -z "$target" ]; then
    printf '    worker: no endpoint is recorded for %s, so nobody could be steered\n' "$id"
    return 1
  fi
  label=$(fm_backend_expected_label_of_meta "$meta" "$id")
  verdict=$(fm_backend_agent_alive "$backend" "$target" "$label" 2>/dev/null) || verdict=unknown
  if [ "$verdict" = dead ]; then
    # The resume command is READ from the worker's own window, never guessed:
    # every harness prints its own on exit, and a guessed one is how a session
    # gets forked instead of resumed.
    pane=$(fm_backend_capture "$backend" "$target" 200 "$label" 2>/dev/null) || pane=
    resume=$(printf '%s\n' "$pane" \
      | grep -E -- '--resume|--continue|Resume this session' \
      | tail -1 | sed 's/^[[:space:]]*//')
    if [ -n "$resume" ]; then
      printf '    worker: exited; its window prints this to resume it: %s\n' "$resume"
    else
      printf '    worker: exited, and its window prints no resume command; read %s before relaunching\n' "$target"
    fi
    return 1
  fi
  if "$SCRIPT_DIR/fm-send.sh" "$id" "$(steer_text "$id" "$url")" >/dev/null 2>&1; then
    rounds_record "$id"
    "$SCRIPT_DIR/fm-stale-base.sh" --ack "$id" >/dev/null 2>&1 || true
    printf '    worker: steered to merge main forward and re-verify (update round %s)\n' "$(rounds_count "$id")"
    return 0
  fi
  printf '    worker: the steer did not land on %s; check that window before re-running\n' "$target"
  return 1
}

# --- the run ------------------------------------------------------------------
ROWS=$(mktemp "${TMPDIR:-/tmp}/fm-merge-green-rows.XXXXXX")
MERGE_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-merge-green-err.XXXXXX")
trap 'rm -f "$ROWS" "$MERGE_ERR"' EXIT

merged_count=0
halted=0
refused_own=0

record() {  # <outcome> <id> <url>
  printf '%s%s%s%s%s\n' "$1" "$TAB" "$2" "$TAB" "$3" >> "$ROWS"
}

# Read on fd 9, not stdin: this loop runs bin/fm-pr-merge.sh, gh, and
# bin/fm-send.sh, any of which may read stdin and would otherwise eat the
# rest of the candidate list.
while IFS="$TAB" read -r _at id <&9; do
  [ -n "${id:-}" ] || continue
  meta=$STATE/$id.meta
  url=$(grep '^pr=' "$meta" | tail -1 | cut -d= -f2-)

  if [ "$halted" -eq 1 ]; then
    record queued-behind "$id" "$url"
    continue
  fi

  printf '== %s  %s\n' "$id" "$url"

  # A landed or abandoned PR is not a candidate and must not be handed to the
  # merge gate, which would spend the base's whole test suite to find that out.
  pr_state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || pr_state=
  case "$pr_state" in
    MERGED) record already-merged "$id" "$url"; continue ;;
    CLOSED) record closed "$id" "$url"; refused_own=1; continue ;;
    OPEN) ;;
    *)
      printf '    the PR state could not be read, so nothing about it is verified\n'
      record unreadable "$id" "$url"
      refused_own=1
      continue
      ;;
  esac

  if [ "$DRY_RUN" -eq 1 ]; then
    if "$SCRIPT_DIR/fm-pr-green.sh" "$id" "$url" >/dev/null 2>&1; then
      record would-merge "$id" "$url"
    else
      record not-green "$id" "$url"
    fi
    continue
  fi

  : > "$MERGE_ERR"
  "$SCRIPT_DIR/fm-pr-merge.sh" "$id" "$url" 2> "$MERGE_ERR"
  merge_rc=$?
  cat "$MERGE_ERR" >&2
  code=$(grep '^fm-pr-merge-refusal: ' "$MERGE_ERR" | tail -1 | sed 's/^fm-pr-merge-refusal: //')

  if [ "$merge_rc" -eq 0 ]; then
    record merged "$id" "$url"
    merged_count=$((merged_count + 1))
    continue
  fi

  case "$code" in
    up-to-date)
      # This branch is exactly one main-merge behind. Steer its worker and stop
      # the queue here, so no sibling is steered against the same main.
      record needs-main-merge "$id" "$url"
      steer_worker "$id" "$url" || true
      halted=1
      ;;
    tests-kept)
      # A kept-tests refusal AFTER something merged in this run is main having
      # moved under the branch, and takes the same remedy. With nothing merged
      # yet it is the branch's own problem - rebase damage, or a deliberate
      # supersession that is the captain's decision - so the queue continues
      # past it rather than steering anyone.
      if [ "$merged_count" -gt 0 ]; then
        record needs-main-merge "$id" "$url"
        steer_worker "$id" "$url" || true
        halted=1
      else
        record refused-tests-kept "$id" "$url"
        refused_own=1
      fi
      ;;
    checks-green)     record not-green "$id" "$url"; refused_own=1 ;;
    attribution)      record refused-attribution "$id" "$url"; refused_own=1 ;;
    merge-resolution) record refused-merge-resolution "$id" "$url"; refused_own=1 ;;
    '')
      # No code means no gate reached a verdict: a usage failure, an unreadable
      # PR, a local copy that does not resolve, or the merge command itself
      # failing. Reported as unverified rather than as a gate's answer.
      record refused-unverified "$id" "$url"
      refused_own=1
      ;;
    *)
      record "refused-$code" "$id" "$url"
      refused_own=1
      ;;
  esac
done 9<<EOF_ORDERED
$ORDERED
EOF_ORDERED

# --- the one summary table ----------------------------------------------------
echo
printf '%-26s %-28s %s\n' OUTCOME TASK PR
while IFS="$TAB" read -r outcome row_id row_url; do
  [ -n "${outcome:-}" ] || continue
  case "$outcome" in
    needs-main-merge)
      printf '%-26s %-28s %s  (update rounds: %s)\n' \
        "$outcome" "$row_id" "$row_url" "$(rounds_count "$row_id")"
      ;;
    *)
      printf '%-26s %-28s %s\n' "$outcome" "$row_id" "$row_url"
      ;;
  esac
done < "$ROWS"

if [ "$halted" -eq 1 ]; then
  echo
  echo "the queue stopped after one branch was steered to merge main forward: every branch below it is one main behind too, and steering them together is what makes a branch pay two update rounds. Re-run this once that branch reports green."
fi

[ "$refused_own" -eq 0 ] || exit 1
exit 0
