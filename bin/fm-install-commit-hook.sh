#!/usr/bin/env bash
# fm-install-commit-hook.sh - install the AI-attribution `commit-msg` hook into
# the repository that owns a given worktree.
#
# Usage: fm-install-commit-hook.sh <path inside the target repo>
#
# bin/fm-spawn.sh calls this for every task worktree it hands out, so the hook is
# in place before the worker's first commit, for every project this fleet ships
# to rather than only for firstmate. It is idempotent: a second call over the
# same repository rewrites our own shim and changes nothing else.
#
# WHERE THE HOOK PHYSICALLY LANDS, AND WHY IT IS THE REPOSITORY AND NOT THE
# WORKTREE
# Verified on git 2.43.0: `git rev-parse --git-path hooks` inside a linked
# worktree resolves to the COMMON directory (<repo>/.git/hooks), not to
# <repo>/.git/worktrees/<name>/hooks. Git hooks are per-repository; there is no
# per-worktree hooks directory to install into. So one install covers the
# project's primary checkout and every worktree of it, and a second spawn in the
# same project is a no-op. docs/attribution-gate.md records that measurement.
#
# This writes under the project's .git/, which is local git metadata and not
# project content: the same class of write bin/fm-spawn.sh already makes to
# <git-common-dir>/info/exclude on every spawn. It never touches tracked files,
# never commits, and never runs a state-changing git command on a ref.
#
# NEVER CLOBBERS A FOREIGN HOOK
# A repository that already has a commit-msg hook we did not write (husky, a
# project's own lint) keeps it, and this exits 3 with a notice. Silently
# replacing a project's hook would break that project to enforce our rule. The
# merge gate still refuses the attribution, so the rule holds without it.
#
# Exit codes:
#   0  the hook is installed and current (freshly written, or rewritten)
#   1  the target is not a git repository, or the hooks directory is unusable
#   3  a foreign commit-msg hook is present; ours was NOT installed
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Bump this when the shim's own shape changes; the installer recognizes its own
# work by this exact string, so it must appear in every shim it writes.
HOOK_MARKER='fm-attribution-hook-v1'

TARGET=${1:?usage: fm-install-commit-hook.sh <path inside the target repo>}
[ -d "$TARGET" ] || { echo "error: $TARGET is not a directory" >&2; exit 1; }

TOPLEVEL=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$TOPLEVEL" ] || { echo "error: $TARGET is not inside a git repository" >&2; exit 1; }

# An explicit core.hooksPath wins over the common directory, exactly as git
# resolves it: absolute as given, relative against the top of the working tree.
HOOKS_DIR=$(git -C "$TARGET" config --get core.hooksPath 2>/dev/null || true)
if [ -n "$HOOKS_DIR" ]; then
  case "$HOOKS_DIR" in
    /*) ;;
    *) HOOKS_DIR="$TOPLEVEL/$HOOKS_DIR" ;;
  esac
else
  COMMON=$(git -C "$TARGET" rev-parse --git-common-dir 2>/dev/null || true)
  [ -n "$COMMON" ] || { echo "error: cannot resolve the git directory for $TARGET" >&2; exit 1; }
  case "$COMMON" in
    /*) ;;
    *) COMMON="$TOPLEVEL/$COMMON" ;;
  esac
  HOOKS_DIR="$COMMON/hooks"
fi

HOOK="$HOOKS_DIR/commit-msg"

if [ -e "$HOOK" ] && ! grep -qF "$HOOK_MARKER" "$HOOK" 2>/dev/null; then
  echo "attribution-hook: a commit-msg hook this fleet did not write is already present at $HOOK; leaving it alone" >&2
  echo "attribution-hook: the merge gate still refuses AI attribution before anything lands" >&2
  exit 3
fi

mkdir -p "$HOOKS_DIR" 2>/dev/null || { echo "error: cannot create $HOOKS_DIR" >&2; exit 1; }

# Written as /bin/sh with an absolute path to the checker, because a task
# worktree is a worktree of the PROJECT, not of firstmate, so nothing relative
# would resolve. The [ -x ] test makes a moved or removed firstmate checkout
# fail OPEN: a hook that cannot find its checker must not wedge every commit in
# the project it was installed into.
TMP_HOOK="$HOOK.fm-tmp.$$"
cat > "$TMP_HOOK" <<EOF
#!/bin/sh
# $HOOK_MARKER - installed by firstmate's bin/fm-install-commit-hook.sh.
# Refuses a commit message carrying AI attribution. Contract:
# docs/attribution-gate.md. Safe to delete; the merge gate still enforces it.
FM_ATTRIBUTION_CHECK='$FM_ROOT/bin/fm-commit-msg-check.sh'
[ -x "\$FM_ATTRIBUTION_CHECK" ] || exit 0
exec "\$FM_ATTRIBUTION_CHECK" "\$@"
EOF
chmod 755 "$TMP_HOOK"
mv -f "$TMP_HOOK" "$HOOK"

echo "attribution-hook: installed $HOOK"
