#!/usr/bin/env bash
# fm-commit-msg-check.sh - the git `commit-msg` hook target that refuses a
# commit whose message carries AI attribution.
#
# Installed by bin/fm-install-commit-hook.sh, which writes a one-line shim into
# the repository's hooks directory that execs THIS script. bin/fm-spawn.sh calls
# that installer for every task worktree it hands out, so a worker in any
# project's worktree - not only firstmate's - hits this at the moment it commits,
# whatever harness it is running under and whether the message arrived by -m, by
# -F, from an editor, or from --amend.
#
# Usage (as a hook, which is how git calls it):
#   fm-commit-msg-check.sh <path-to-commit-message-file>
# Exit 0 lets the commit proceed. Exit 1 aborts it and prints the offending
# lines. bin/fm-attribution-lib.sh owns which lines those are.
#
# WHAT THIS IS AND IS NOT
# It is a mechanism, not an instruction: it runs by default on every commit and
# nothing the worker is told or not told changes that. It is NOT the boundary,
# because `git commit --no-verify` skips every commit-msg hook and the worker
# could delete the hook file. The boundary is the merge gate
# (bin/fm-pr-merge.sh, bin/fm-merge-local.sh), which firstmate runs on the
# artefact the worker produced and the worker cannot reach.
# docs/attribution-gate.md states that split honestly and owns the contract.
#
# FAIL-OPEN CASES
# A missing message file, or a message file that cannot be read, exits 0. A
# commit-msg hook that refuses on its own malfunction wedges every commit in the
# repository it was installed into, including the captain's own, and the merge
# gate still closes the loop. A refusal here is only ever a real finding.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-attribution-lib.sh
. "$SCRIPT_DIR/fm-attribution-lib.sh"

MSG_FILE=${1:-}
if [ -z "$MSG_FILE" ] || [ ! -r "$MSG_FILE" ]; then
  exit 0
fi

FINDINGS=$(fm_attribution_strip_commit_comments < "$MSG_FILE" | fm_attribution_scan_stdin) || {
  {
    echo "refused: this commit message carries AI attribution."
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "  $line"
    done <<EOF_FINDINGS
$FINDINGS
EOF_FINDINGS
    fm_attribution_explain
    echo "Then commit again. Do not reach for --no-verify: the merge gate applies"
    echo "the same rule to the PR before it can land, so bypassing this only moves"
    echo "the refusal later."
  } >&2
  exit 1
}

exit 0
