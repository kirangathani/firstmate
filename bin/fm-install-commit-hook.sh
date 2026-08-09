#!/usr/bin/env bash
# fm-install-commit-hook.sh - install firstmate's `commit-msg` hook into the
# repository that owns a given worktree.
#
# The one shim runs two independent checks, in this order:
#   1. bin/fm-commit-msg-check.sh        AI attribution in the message
#                                        (docs/attribution-gate.md)
#   2. bin/fm-merge-resolution-check.sh  a merge resolution that deletes content
#                                        one side introduced
#                                        (docs/merge-resolution-gate.md)
# Both are authorship-time speed, not containment; each contract names its own
# landing gate. They share one hook file because git allows a repository exactly
# one `commit-msg` hook, so a second installer would silently disarm the first.
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

# The marker is an opaque FLEET-IDENTITY token - "did we write this hook?" - and
# is deliberately NOT versioned with the shim's shape. Its name is historical: it
# was minted when the shim ran only the attribution check, and it is left alone
# now that the shim runs two. The comments the shim itself carries describe what
# it actually does; this string only has to stay recognizable.
#
# WHY IT IS NOT BUMPED WHEN THE SHIM CHANGES
# Nothing keys any behavior off the version. The installer rewrites its own shim
# unconditionally on every run, so a stale shim is refreshed at the next spawn
# whatever it says. What a bump WOULD do is create a hazard: recognition is a
# plain substring test, and an unrecognized hook takes the foreign-hook branch
# below, which deliberately leaves it alone. So a bump that any reader forgot to
# account for silently disarms every check in every project already spawned into
# - the exact opposite of what bumping is for. A stable token removes that
# hazard class instead of managing it.
#
# HOOK_MARKERS_OWNED is every marker this fleet has ever written, newest first.
# Recognition reads the whole list while only HOOK_MARKER is written, so if a
# future change ever does need a new token, adding it here is what keeps the
# already-installed shims ours.
HOOK_MARKER='fm-attribution-hook-v1'
HOOK_MARKERS_OWNED='fm-attribution-hook-v1'

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

if [ -e "$HOOK" ]; then
  ours=0
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    if grep -qF "$marker" "$HOOK" 2>/dev/null; then
      ours=1
      break
    fi
  done <<EOF_MARKERS
$HOOK_MARKERS_OWNED
EOF_MARKERS
  if [ "$ours" -eq 0 ]; then
    echo "commit-hook: a commit-msg hook this fleet did not write is already present at $HOOK; leaving it alone" >&2
    echo "commit-hook: the landing gates still refuse AI attribution and a deleting merge resolution before anything lands" >&2
    exit 3
  fi
fi

mkdir -p "$HOOKS_DIR" 2>/dev/null || { echo "error: cannot create $HOOKS_DIR" >&2; exit 1; }

# Written as /bin/sh with an absolute path to each checker, because a task
# worktree is a worktree of the PROJECT, not of firstmate, so nothing relative
# would resolve. Each [ -x ] test makes a moved or removed firstmate checkout
# fail OPEN for that checker: a hook that cannot find what it runs must not wedge
# every commit in the project it was installed into.
#
# Each checker is run in turn and the FIRST refusal aborts the commit, so a
# message that carries attribution is reported as attribution rather than being
# masked by, or masking, a resolution finding.
TMP_HOOK="$HOOK.fm-tmp.$$"
cat > "$TMP_HOOK" <<EOF
#!/bin/sh
# $HOOK_MARKER - installed by firstmate's bin/fm-install-commit-hook.sh.
# Refuses a commit message carrying AI attribution (docs/attribution-gate.md),
# and a merge commit whose resolution deletes content one side introduced
# (docs/merge-resolution-gate.md). Safe to delete; the landing gates still
# enforce both.
FM_ATTRIBUTION_CHECK='$FM_ROOT/bin/fm-commit-msg-check.sh'
FM_RESOLUTION_CHECK='$FM_ROOT/bin/fm-merge-resolution-check.sh'

if [ -x "\$FM_ATTRIBUTION_CHECK" ]; then
  "\$FM_ATTRIBUTION_CHECK" "\$@" || exit \$?
fi
if [ -x "\$FM_RESOLUTION_CHECK" ]; then
  "\$FM_RESOLUTION_CHECK" "\$@" || exit \$?
fi
exit 0
EOF
chmod 755 "$TMP_HOOK"
mv -f "$TMP_HOOK" "$HOOK"

echo "commit-hook: installed $HOOK"
