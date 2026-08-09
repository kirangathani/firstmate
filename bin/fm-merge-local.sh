#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# It also refuses when any commit message this fast-forward would land carries AI
# attribution, the local-only twin of the same gate in bin/fm-pr-merge.sh.
# bin/fm-attribution-lib.sh owns the patterns and docs/attribution-gate.md owns
# the contract.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ack-lib.sh
. "$SCRIPT_DIR/fm-ack-lib.sh"
# shellcheck source=bin/fm-attribution-lib.sh
. "$SCRIPT_DIR/fm-attribution-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# AI-attribution gate (docs/attribution-gate.md). This is the local-only twin of
# the same gate in bin/fm-pr-merge.sh, and it is the boundary rather than the
# commit-msg hook: firstmate runs it, on the artefact the worker produced, at the
# point of landing, so no --no-verify and no deleted hook reaches past it. It
# scans every commit message this fast-forward would put on the default branch.
attr_findings=""
attr_rc=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  msg=$(git -C "$PROJ" log -1 --format=%B "$sha" 2>/dev/null) || {
    echo "error: could not read the commit message of $sha; refusing to merge unverified" >&2
    exit 1
  }
  found=$(printf '%s\n' "$msg" | fm_attribution_scan_stdin "${sha:0:12}") || attr_rc=1
  [ -z "$found" ] || attr_findings="${attr_findings}${found}"$'\n'
done <<EOF_SHAS
$(git -C "$PROJ" rev-list "$DEFAULT..$BRANCH")
EOF_SHAS
if [ "$attr_rc" -ne 0 ]; then
  {
    echo "REFUSED: commit message(s) on $BRANCH carry AI attribution:"
    printf '%s' "$attr_findings" | while IFS= read -r line; do
      [ -n "$line" ] && echo "  $line"
    done
    fm_attribution_explain
    echo "Have the worker rewrite those messages on $BRANCH, then retry."
  } >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# The merge IS the action a local-only `done: ready in branch` owes, so ack it
# (bin/fm-ack-lib.sh) for the window between here and teardown.
fm_ack_record "$STATE" "$ID" "fm-merge-local $BRANCH" || true
