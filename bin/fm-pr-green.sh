#!/usr/bin/env bash
# Report whether a task's PR is green on GitHub, addressed by the PR itself, so
# a ship worker can learn its own CI state and report done on its own evidence.
#
# WHY THIS EXISTS. The no-mistakes pipeline's own `ci` step polls `gh pr checks`
# with no PR number, from the pipeline's worktree under ~/.no-mistakes/worktrees/,
# which is at a detached HEAD. gh therefore exits 1 with "could not determine
# current branch: failed to run git: not on any branch" on every poll, the step
# never sees green, and it loops for up to 168 h emitting
# "warning: could not check CI: gh pr checks: exit status 1" while the PR is
# genuinely green on GitHub. Reproduced 2026-09-07 on two PRs (ELN 28, 21 minutes
# of looping; ELN 30, 36 polls). This command is addressed by PR URL, so it is
# immune to that failure and works from any directory, including a detached HEAD
# and a directory that is not a git repository at all.
#
# ONE OWNER. The rollup read and the classification table live in
# bin/fm-pr-lib.sh (fm_pr_rollup_read, fm_pr_rollup_classify) and are shared with
# the merge gate, so a worker can never report green on a PR
# bin/fm-pr-merge.sh would then refuse. bin/fm-pr-merge.sh's header owns the
# policy both implement.
#
# WHAT THIS DOES NOT DO, deliberately, so its green is strictly the STRONGER
# reading of the two:
#   - It excuses NO check. The merge gate may excuse the one named attestation
#     check under a captain's authority; this command has no such authority and
#     asks a different question - has this PR's CI actually gone green - so a
#     failing check of any name is not green here.
#   - Zero checks is never green, with no marker and no waiver route. Those two
#     authorities exist at the merge gate because the captain decides there
#     whether absent CI was deliberate. A worker has no such decision to make,
#     and an empty rollup is indistinguishable from CI that has not reported yet.
#   - It merges nothing, records nothing, and writes nothing.
#
# THE HEAD SHA is read from the PR on GitHub (`gh pr view --json headRefOid`,
# the same reader bin/fm-pr-check.sh uses), never from a local ref: a local HEAD
# can be ahead of, behind, or unrelated to what CI actually measured. It is read
# again after the rollup and must be unchanged; a head that moved mid-read means
# the rollup and the SHA describe different commits, which is exactly the
# false-green this command exists to prevent, so that is not green either.
#
# Usage: fm-pr-green.sh <task-id> [<pr-url>]
#   The PR URL wins when given, which is the worker's case: at the moment a
#   worker polls, the pipeline has opened the PR but firstmate has not yet
#   recorded it. With no URL the task's recorded pr= is used, which is
#   firstmate's case after bin/fm-pr-check.sh has run.
# Exit 0 prints one line on stdout:  green: <url> <sha> <n> checks
# Exit 1 names every failing, unfinished, or unreadable check on stderr.
# Exit 2 is a malformed request or an unusable PR reference.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: fm-pr-green.sh <task-id> [<pr-url>]" >&2
  exit 2
fi
ID=$1
RAW_URL=${2-}
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid task id" >&2
  exit 2
fi

if [ -n "$RAW_URL" ]; then
  if ! fm_pr_url_parse "$RAW_URL"; then
    echo "error: not a GitHub pull request link: $RAW_URL" >&2
    exit 2
  fi
else
  # Task-derived paths are constructed only after the canonical ID validation.
  META="$STATE/$ID.meta"
  if ! fm_pr_metadata_identity_parse "$META"; then
    echo "error: no PR is recorded for $ID, and none was given" >&2
    echo "error: pass the PR link the pipeline printed: fm-pr-green.sh $ID <pr-url>" >&2
    exit 2
  fi
  fm_pr_url_parse "$FM_PR_META_URL" || exit 2
fi
URL=$FM_PR_URL

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is not installed, so the PR's checks cannot be read" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-green.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ERR="$WORK/gh.err"

# head_read: print the PR's head SHA from GitHub, or fail. Bounded, because a
# worker calls this on a loop and a hung read would wedge it.
head_read() {
  local sha
  sha=$(fm_pr_bounded gh pr view "$URL" --json headRefOid -q .headRefOid 2> "$ERR") || return 1
  fm_pr_head_valid "$sha" || return 1
  printf '%s' "$sha"
}

if ! HEAD_BEFORE=$(head_read); then
  cat "$ERR" >&2
  echo "error: could not read the PR's head commit (see above); not green" >&2
  exit 1
fi

set +e
fm_pr_rollup_read "$URL" "$ERR"
rollup_rc=$?
set -e
if [ "$rollup_rc" -ne 0 ]; then
  cat "$ERR" >&2
  echo "error: could not read the PR's checks (gh exit $rollup_rc, see above); not green" >&2
  exit 1
fi

if ! HEAD_AFTER=$(head_read); then
  cat "$ERR" >&2
  echo "error: could not re-read the PR's head commit (see above); not green" >&2
  exit 1
fi
if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ]; then
  echo "error: the PR's head moved from $HEAD_BEFORE to $HEAD_AFTER while its checks were being read, so those checks do not describe the current head; not green" >&2
  exit 1
fi

# No exempt name: this command excuses nothing (see the header).
fm_pr_rollup_classify "$FM_PR_ROLLUP_TSV" ""

while IFS= read -r name; do
  echo "error: PR check is failing: $name" >&2
done < <(fm_pr_rollup_each "$FM_PR_ROLLUP_FAILING_NAMES")
while IFS= read -r name; do
  echo "note: PR check has not finished: $name" >&2
done < <(fm_pr_rollup_each "$FM_PR_ROLLUP_PENDING_NAMES")
while IFS= read -r name; do
  echo "error: PR check state could not be classified: $name" >&2
done < <(fm_pr_rollup_each "$FM_PR_ROLLUP_UNKNOWN_NAMES")

if [ "$FM_PR_ROLLUP_FAILING" -gt 0 ]; then
  echo "error: $FM_PR_ROLLUP_FAILING failing PR check(s) (named above); this PR is red" >&2
  exit 1
fi
if [ "$FM_PR_ROLLUP_UNKNOWN" -gt 0 ]; then
  echo "error: $FM_PR_ROLLUP_UNKNOWN PR check(s) could not be classified (named above); not green" >&2
  exit 1
fi
if [ "$FM_PR_ROLLUP_PENDING" -gt 0 ]; then
  echo "error: $FM_PR_ROLLUP_PENDING PR check(s) have not finished (named above); this PR is not red, it is unfinished - wait and re-run" >&2
  exit 1
fi
if [ "$FM_PR_ROLLUP_TOTAL" -eq 0 ]; then
  echo "error: the PR reports no checks at all; absent CI is not green - wait for CI to report, then re-run" >&2
  exit 1
fi

printf 'green: %s %s %s checks\n' "$URL" "$HEAD_BEFORE" "$FM_PR_ROLLUP_TOTAL"
