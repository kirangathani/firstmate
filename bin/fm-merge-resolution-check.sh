#!/usr/bin/env bash
# fm-merge-resolution-check.sh - the git `commit-msg` hook target that refuses a
# MERGE COMMIT whose conflict resolution deletes content one side introduced.
#
# Installed by bin/fm-install-commit-hook.sh, whose shim execs this alongside
# bin/fm-commit-msg-check.sh. bin/fm-spawn.sh calls that installer for every task
# worktree it hands out, so a worker in any project's worktree - not only
# firstmate's - hits this at the moment it commits a resolution, whatever harness
# it is running under.
#
# Usage (as a hook, which is how git calls it):
#   fm-merge-resolution-check.sh [<path-to-commit-message-file>]
# The message file argument is accepted and ignored; this reads the merge, not
# the message. Exit 0 lets the commit proceed. Exit 1 aborts it and names the
# lost lines and both candidate resolutions.
# bin/fm-merge-additive-lib.sh owns the verdict.
#
# WHY commit-msg AND NOT pre-commit
# Measured on git 2.43.0 (docs/merge-resolution-gate.md records the run):
#   - conflicted merge, resolve, `git commit`      -> pre-commit AND commit-msg fire
#   - conflicted merge, resolve, `git merge --continue` -> pre-commit AND commit-msg fire
#   - `git merge -X ours` (auto-resolves a REAL conflict by DISCARDING the other
#     side, then auto-commits)                      -> commit-msg fires, pre-commit does NOT
# `-X ours` and `-X theirs` are precisely the "throw one side away" resolution
# this exists to catch, and they are the one path that never reaches pre-commit.
# So the hook lives on commit-msg, which covers all three.
#
# WHAT THIS IS AND IS NOT
# It is a mechanism, not an instruction: it runs by default on every merge commit
# and nothing the worker is told or not told changes that. It is NOT the
# boundary, because `git commit --no-verify` skips every commit-msg hook and the
# worker could delete the hook file. The boundary is the landing gate
# (bin/fm-pr-merge.sh), which firstmate runs over the merges the PR would land,
# through a script the worker never invokes. docs/merge-resolution-gate.md states
# that split honestly and owns the contract.
#
# FAIL-OPEN CASES
# Not a merge (no MERGE_HEAD), an octopus merge, an unreadable repository, or a
# scan that cannot complete all exit 0. A commit-msg hook that refuses on its own
# malfunction wedges every commit in the repository it was installed into,
# including the captain's own, and the landing gate still closes the loop. A
# refusal here is only ever a real finding.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-merge-additive-lib.sh
. "$SCRIPT_DIR/fm-merge-additive-lib.sh"

# How many lost lines to print before summarising the rest. A resolution that
# dropped a whole file produces hundreds, and a hook that floods the terminal
# gets bypassed rather than read.
MAX_SHOWN=${FM_MERGE_RESOLUTION_MAX_SHOWN:-20}

GIT_DIR_PATH=$(git rev-parse --git-dir 2>/dev/null) || exit 0
[ -f "$GIT_DIR_PATH/MERGE_HEAD" ] || exit 0

# An octopus merge has more than one MERGE_HEAD. Git cannot even produce a
# conflicted octopus commit through this path, and the two-side verdict has no
# meaning for three, so it is skipped rather than answered wrongly.
if [ "$(grep -c . "$GIT_DIR_PATH/MERGE_HEAD" 2>/dev/null || echo 0)" -ne 1 ]; then
  exit 0
fi

THEIRS=$(head -1 "$GIT_DIR_PATH/MERGE_HEAD" 2>/dev/null) || exit 0
[ -n "$THEIRS" ] || exit 0
OURS=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || exit 0
[ -n "$OURS" ] || exit 0

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$TOPLEVEL" ] || exit 0

# Unrelated histories have no base; the library reads an empty base as "nothing
# was already shared", which is the correct reading rather than a reason to skip.
BASE=$(git merge-base "$OURS" "$THEIRS" 2>/dev/null | head -1 || true)

FINDINGS=$(fm_additive_scan "$TOPLEVEL" "$BASE" "$OURS" "$THEIRS" index)
SCAN_RC=$?
[ "$SCAN_RC" -eq 1 ] || exit 0
[ -n "$FINDINGS" ] || exit 0

# The side labels are what make the escalation relayable: in the supported flow a
# worker merges the base forward INTO its branch, so HEAD is the branch and
# MERGE_HEAD is the base being merged in.
OURS_LABEL="this branch"
THEIRS_LABEL="the base being merged in"

{
  echo "refused: this merge resolution deletes content one side introduced."
  echo
  shown=0
  total=0
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    total=$((total + 1))
    [ "$shown" -lt "$MAX_SHOWN" ] || continue
    shown=$((shown + 1))
    rest=${finding#lost:}
    side=${rest%%:*}
    rest=${rest#*:}
    path=${rest%%:*}
    text=${rest#*:}
    case "$side" in
      ours)   who="only on $OURS_LABEL" ;;
      theirs) who="only on $THEIRS_LABEL" ;;
      *)      who="on both sides" ;;
    esac
    echo "  $path: a line that was $who is gone from the resolution"
    echo "    | $text"
  done <<EOF_FINDINGS
$FINDINGS
EOF_FINDINGS
  if [ "$total" -gt "$shown" ]; then
    echo "  ... and $((total - shown)) more lost line(s); this listing is capped at $MAX_SHOWN."
  fi
  echo
  fm_additive_explain "$OURS_LABEL" "$THEIRS_LABEL"
  echo
  echo "Do not reach for --no-verify: the landing gate applies the same rule to"
  echo "the merges this PR would land, so bypassing this only moves the refusal"
  echo "later. Never rebase to escape it either - a rebased branch cannot be"
  echo "pushed at all."
} >&2

exit 1
