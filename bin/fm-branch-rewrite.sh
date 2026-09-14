#!/usr/bin/env bash
# Rewritten-branch sweep: which in-flight tasks have had their history REWRITTEN
# under an open PR since firstmate last recorded that PR's head.
#
# WHY THIS EXISTS. bin/fm-pr-merge.sh's additive-resolution gate enumerates the
# MERGE COMMITS in the range a PR would land and checks each one's resolution
# against its two parents. A rebase produces no merge commit, so a branch whose
# conflict was resolved during a rebase passes that gate in silence - not
# because the resolution was judged safe, but because there was nothing left to
# judge. docs/merge-resolution-gate.md owns that gap and why the merge shape is
# what closes it.
#
# The rewrite is not hypothetical and is not always a worker's doing. When the
# default branch moves while no-mistakes is monitoring CI, the pipeline rebases
# and re-pushes from its OWN worktree, so the commit-msg hook never fires either.
# Observed in three runs' ci.log on 2026-09-14: "rebased HEAD is byte-identical
# to its pre-rebase state (`440fea3`)". Those were byte-identical, so nothing was
# lost; the point is that nothing would have reported it if something had been.
#
# This sweep does not audit the resolution - after a rebase that evidence is
# gone, which is the whole problem. It reports that an unaudited rewrite
# happened, so the blind spot is loud instead of silent.
#
# THE QUESTION, per in-flight task carrying a recorded PR head:
#   git -C <project> merge-base --is-ancestor <recorded pr_head> <origin/branch>
# True means every commit firstmate last saw is still there and the branch only
# moved forward. False alone is NOT enough, because this reads local refs that a
# clone may simply not have refreshed yet - see THE THREE-WAY TEST below.
#
# NO NETWORK, NO WRITES TO ANY CLONE. Every read is a local ref or object
# lookup, so this cannot hang a caller and cannot cross firstmate's
# project-write boundary. Freshness is supplied by whoever already fetched;
# bin/fm-fleet-sync.sh is the only path that advances a clone's origin refs.
#
# THE THREE-WAY TEST, which is what keeps a stale clone from reading as an
# incident:
#   recorded is an ancestor of current -> the branch moved forward. SILENT.
#   current is an ancestor of recorded -> this clone's origin refs are OLDER
#     than the head firstmate recorded. Nothing was rewritten; the clone has not
#     been refreshed. Reported as undeterminable, never as a rewrite.
#   neither -> the two heads have genuinely diverged. The commits firstmate
#     recorded are no longer reachable from the branch, which is what a rebase,
#     an amend, or a force-push leaves behind. REPORTED.
#
# BRANCH RESOLUTION is git's own record, never agent prose: one
# `git -C <project> worktree list --porcelain` read per project maps each task's
# recorded local copy to the branch checked out in it. That reads only the
# parent clone's administrative files, so it never touches a worker's worktree,
# which may be mid-operation. This mirrors bin/fm-stale-base.sh, which owns that
# reasoning; the two sweeps ask different questions of the same records and
# neither reads the other's state.
#
# NO FALSE ALARMS. Silent for: a scout or secondmate record (no PR by design), a
# task with no recorded pr_head (no PR checked yet, so there is no head to have
# been rewritten away), a branch with no origin ref, and the stale-clone case
# above.
#
# NO FALSE GREENS. Anything it cannot determine - a missing project record or
# clone, a non-git project, a local copy git does not know, a detached HEAD, a
# recorded head whose object this clone does not have, or a git comparison that
# errors - is reported as undeterminable, never folded into silence.
#
# REPORT ONLY. It refuses nothing and blocks nothing. There is deliberately no
# acknowledgement mechanism: bin/fm-stale-base.sh has one because it alarms
# routinely, and this condition has not been observed to fire at all. Add one
# when it does.
#
# Usage:
#   fm-branch-rewrite.sh [--project <dir>]     report; exit 1 if anything to report
# Exit: 0 nothing to report, 1 at least one finding, 2 bad usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat >&2 <<'EOF'
usage: fm-branch-rewrite.sh [--project <dir>]
EOF
}

ONLY_PROJECT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --project)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ONLY_PROJECT=$2
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

[ -d "$STATE" ] || exit 0

# Read every field this sweep needs in ONE pass, with no subprocess per field.
# Last occurrence wins, matching how every other reader treats a meta key -
# bin/fm-pr-check.sh appends pr_head= rather than rewriting it.
META_KIND=
META_PROJECT=
META_WORKTREE=
META_PR=
META_PR_HEAD=
read_meta() {  # <meta-file>
  local line
  META_KIND=
  META_PROJECT=
  META_WORKTREE=
  META_PR=
  META_PR_HEAD=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) META_KIND=${line#kind=} ;;
      project=*) META_PROJECT=${line#project=} ;;
      worktree=*) META_WORKTREE=${line#worktree=} ;;
      pr=*) META_PR=${line#pr=} ;;
      pr_head=*) META_PR_HEAD=${line#pr_head=} ;;
    esac
  done < "$1"
}

# --- local copy -> branch, from git's own record ----------------------------
#
# One `worktree list --porcelain` capture per project, reused across that
# project's tasks. Sets WT_BRANCH for <path>, or returns 1 when git does not
# know that path as one of this clone's worktrees.
WT_CACHE_PROJECT=
WT_CACHE=
WT_BRANCH=
worktree_branch() {  # <project> <worktree-path>
  local project=$1 want=$2 line cur ref
  if [ "$project" != "$WT_CACHE_PROJECT" ]; then
    WT_CACHE=$(git -C "$project" worktree list --porcelain 2>/dev/null) || {
      WT_CACHE_PROJECT=$project
      WT_CACHE=
      return 1
    }
    WT_CACHE_PROJECT=$project
  fi
  WT_BRANCH=
  cur=
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) cur=${line#worktree } ;;
      'branch '*)
        ref=${line#branch }
        [ "$cur" = "$want" ] && { WT_BRANCH=${ref#refs/heads/}; return 0; }
        ;;
      'detached')
        # A detached local copy carries no branch; say so rather than guessing.
        [ "$cur" = "$want" ] && return 2
        ;;
    esac
  done <<EOF
$WT_CACHE
EOF
  return 1
}

FINDINGS=0
report() {  # <task-id> <sentence>
  printf 'BRANCH REWRITTEN: %s - %s\n' "$1" "$2"
  FINDINGS=1
}
undeterminable() {  # <task-id> <sentence>
  printf 'REWRITE UNDETERMINABLE: %s - %s\n' "$1" "$2"
  FINDINGS=1
}

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  read_meta "$meta"

  # A scout produces a report and no PR; a secondmate is a persistent home, not
  # a branch. Neither can have had a PR head rewritten.
  case "$META_KIND" in
    scout|secondmate) continue ;;
  esac

  # No recorded PR head means no PR has been checked yet, so there is no head
  # firstmate has vouched for and nothing can have been rewritten away from it.
  [ -n "$META_PR_HEAD" ] || continue

  [ -n "$ONLY_PROJECT" ] && [ "$META_PROJECT" != "$ONLY_PROJECT" ] && continue

  if [ -z "$META_PROJECT" ]; then
    undeterminable "$id" "its record names a PR head but no project, so the branch cannot be located"
    continue
  fi
  if [ ! -d "$META_PROJECT/.git" ] && [ ! -f "$META_PROJECT/.git" ]; then
    undeterminable "$id" "its project $META_PROJECT is missing or is not a git repository"
    continue
  fi
  if [ -z "$META_WORKTREE" ]; then
    undeterminable "$id" "its record names a PR head but no local copy, so the branch cannot be located"
    continue
  fi

  worktree_branch "$META_PROJECT" "$META_WORKTREE"
  case "$?" in
    0) ;;
    2)
      undeterminable "$id" "its local copy $META_WORKTREE is on a detached HEAD, so it names no branch to check"
      continue
      ;;
    *)
      undeterminable "$id" "git does not know $META_WORKTREE as a local copy of $META_PROJECT"
      continue
      ;;
  esac

  remote_ref="refs/remotes/origin/$WT_BRANCH"
  current=$(git -C "$META_PROJECT" rev-parse --verify --quiet "$remote_ref^{commit}" 2>/dev/null) || current=
  if [ -z "$current" ]; then
    # Never pushed, or the clone has no such remote ref. Nothing published means
    # nothing to have been rewritten under a reviewer.
    continue
  fi

  if ! git -C "$META_PROJECT" rev-parse --verify --quiet "$META_PR_HEAD^{commit}" >/dev/null 2>&1; then
    undeterminable "$id" "this clone does not have the recorded PR head ${META_PR_HEAD:0:12}, so the comparison cannot be made; refresh the clone and re-run"
    continue
  fi

  if git -C "$META_PROJECT" merge-base --is-ancestor "$META_PR_HEAD" "$current" 2>/dev/null; then
    continue
  fi
  if git -C "$META_PROJECT" merge-base --is-ancestor "$current" "$META_PR_HEAD" 2>/dev/null; then
    undeterminable "$id" "this clone's $remote_ref is OLDER than the recorded PR head ${META_PR_HEAD:0:12}, so its refs have not been refreshed; nothing is known to have been rewritten"
    continue
  fi

  report "$id" \
"$WT_BRANCH no longer contains the head firstmate recorded for ${META_PR:-its PR} (${META_PR_HEAD:0:12}); it now points at ${current:0:12}, which does not descend from it. Its history was rewritten by a rebase, an amend, or a force-push, so any conflict resolved in the commits that were replaced left no merge commit for the landing gate to check. Read the branch before landing it."
done

exit "$FINDINGS"
