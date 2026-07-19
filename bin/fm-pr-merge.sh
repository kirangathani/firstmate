#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` directly.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Test-keep gate: after recording and before merging, bin/fm-assert-tests-kept.sh
# must confirm every test assertion present on the authoritative base is still
# present (check 1, by name) and still passing against the branch's code
# (check 2, by running the base's own test files). A missing or failing
# assertion is a hard refusal with no override flag, and a check that cannot
# run at all also refuses, because a merge that cannot be verified must not
# proceed silently. This gate is firstmate-side, so it protects every repo
# including ones with no PR CI.
#
# A refusal has two causes the coder cannot reliably tell apart. Rebase damage:
# the conflict resolution ate the base's behavior; redoing the resolution makes
# the base's assertion pass again and the gate clears itself. Deliberate
# supersession: the branch intentionally changes behavior the base asserted;
# that is a product decision, so it is escalated needs-decision to the captain
# and never decided by the coder or by firstmate.
#
# The supersession record is the ONE deliberate exception to "no suppression":
# without it a legitimate behavior change could never merge, because the base's
# old assertion would keep failing no matter what the coder does.
#   - Location: $FM_HOME/data/supersessions/<project>.md, where <project> is
#     the basename of the task meta's project= path. It lives in firstmate's
#     gitignored data/, never inside the project (firstmate must never write
#     under projects/), so it is private to this fleet by construction.
#   - Absent means empty means no approvals. It is created lazily by the
#     captain's approval, never auto-generated - not at project registration,
#     not at session start, not by this script.
#   - Entry format, one entry per line:
#       - id: <file>::<name> | project: <project> | date: <YYYY-MM-DD> | reason: <captain's stated reason>
#     An entry missing any field, with a project not matching the file, or with
#     a malformed date is NOT honored; it is warned about and ignored.
#   - Only the captain approves an entry. There is no mechanical guarantee of
#     this: nothing physically prevents another writer, and the required fields
#     exist so a fabricated entry is visible rather than silent.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

PROJ_PATH=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
PROJ_NAME=
[ -z "$PROJ_PATH" ] || PROJ_NAME=$(basename "$PROJ_PATH")
SUPERSESSIONS_FILE="$FM_HOME/data/supersessions/$PROJ_NAME.md"

# supersession_approved <file>::<name>: 0 iff the project's supersession record
# holds a fully-formed captain-approved entry for that identifier (format in
# this script's header). An absent file means no approvals; a malformed entry
# is warned about and never honored.
supersession_approved() {
  local ident=$1 line rest entry_id entry_proj entry_date entry_reason
  [ -n "$PROJ_NAME" ] || return 1
  [ -f "$SUPERSESSIONS_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- id: "*) ;;
      *) continue ;;
    esac
    case "$line" in
      *" | project: "*" | date: "*" | reason: "*) ;;
      *)
        echo "warning: ignoring supersession entry missing a required field (id, project, date, reason): $line" >&2
        continue
        ;;
    esac
    rest=${line#- id: }
    entry_id=${rest%% | project: *}
    rest=${rest#* | project: }
    entry_proj=${rest%% | date: *}
    rest=${rest#* | date: }
    entry_date=${rest%% | reason: *}
    entry_reason=${rest#* | reason: }
    if [ -z "$entry_id" ] || [ -z "$entry_proj" ] || [ -z "$entry_reason" ]; then
      echo "warning: ignoring supersession entry with an empty field: $line" >&2
      continue
    fi
    case "$entry_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *)
        echo "warning: ignoring supersession entry whose date is not YYYY-MM-DD: $line" >&2
        continue
        ;;
    esac
    if [ "$entry_proj" != "$PROJ_NAME" ]; then
      echo "warning: ignoring supersession entry for project '$entry_proj' found in $PROJ_NAME's record: $line" >&2
      continue
    fi
    [ "$entry_id" = "$ident" ] && return 0
  done < "$SUPERSESSIONS_FILE"
  return 1
}

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

KEPT_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-kept.XXXXXX")
trap 'rm -f "$KEPT_OUT"' EXIT
set +e
"$SCRIPT_DIR/fm-assert-tests-kept.sh" "$ID" > "$KEPT_OUT"
kept_rc=$?
set -e
cat "$KEPT_OUT"
case "$kept_rc" in
  0) ;;
  1)
    excused=0
    unexcused=0
    while IFS= read -r line; do
      case "$line" in
        'missing: '*) ident=${line#missing: } ;;
        'failing: '*) ident=${line#failing: } ;;
        *) continue ;;
      esac
      if supersession_approved "$ident"; then
        excused=$((excused + 1))
        echo "note: captain-approved supersession covers: $ident" >&2
      else
        unexcused=$((unexcused + 1))
        echo "error: no captain-approved supersession entry covers: $ident" >&2
      fi
    done < "$KEPT_OUT"
    if [ "$unexcused" -gt 0 ] || [ "$excused" -eq 0 ]; then
      echo "error: base test assertion(s) are missing or failing on the PR branch (named above); refusing to merge" >&2
      echo "error: if this is rebase damage, have the coder redo the conflict resolution so the base's assertions pass again, then re-run fm-pr-merge.sh" >&2
      echo "error: if the branch deliberately supersedes the base's behavior, that is the captain's decision - escalate needs-decision naming each assertion; only a captain-approved entry in $SUPERSESSIONS_FILE (entry format in this script's header) lets the merge proceed" >&2
      exit 1
    fi
    echo "note: all $excused missing/failing base assertion(s) are covered by captain-approved supersession entries in $SUPERSESSIONS_FILE; proceeding" >&2
    ;;
  *)
    echo "error: could not verify the base's tests are kept (fm-assert-tests-kept.sh exit $kept_rc, see above); refusing to merge unverified" >&2
    echo "error: repair the task's worktree/project so the check can run, then re-run fm-pr-merge.sh" >&2
    exit 1
    ;;
esac

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
