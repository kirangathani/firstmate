#!/usr/bin/env bash
# Stale-base sweep: which in-flight tasks are measuring CI against a base that
# has already moved underneath them.
#
# When a change lands on a project's default branch, every other open branch
# that predates it keeps reporting CI results measured against the OLD base.
# Those results look like verdicts on the branch and are not. On 2026-08-09 a
# red assertion on firstmate's main was fixed and merged while four other
# branches were open; three of them then showed a purely inherited red for
# about twenty minutes and were relayed as if they described those branches.
# Nothing in the system had asked the one deterministic question below.
#
# THE QUESTION, per in-flight task with a branch pushed to origin:
#   git -C <project> merge-base --is-ancestor <origin/default> <origin/branch>
# Non-zero means the branch does not contain the current base, so any CI result
# on it was measured against a base that no longer exists.
#
# WHERE IT RUNS (two places, one predicate - this file owns the predicate):
#   IMMEDIATE - bin/fm-fleet-sync.sh, per project, right after that clone's
#               refresh. That is the exact instant the base MOVES locally, and
#               the first instant the new base exists here at all, so the answer
#               is fresh by construction with no extra network.
#   BACKSTOP  - bin/fm-turnend-guard.sh, which already blocks a turn that would
#               end without supervision. A turn that would end with a stale
#               sibling unaddressed is blocked the same way, so the immediate
#               trigger being missed (an absorbed wake, a skipped refresh)
#               cannot let the condition survive a whole turn.
#
# NO NETWORK, NO WRITES TO ANY CLONE. Every read is a local ref lookup, so the
# sweep cannot hang a turn end and cannot cross firstmate's project-write
# boundary. It deliberately does NOT fetch: fetching writes the clone's ref
# store, and a guard on the critical path of every turn end must never make a
# network call. Freshness is supplied by the caller that already fetched -
# bin/fm-fleet-sync.sh is the ONLY path that advances a clone's origin refs, and
# it is reached on every merge wake, every session start, and every
# bin/fm-teardown.sh of a landed task.
#
# BRANCH RESOLUTION is git's own durable record, never agent prose: one
# `git -C <project> worktree list --porcelain` read per project maps each task's
# recorded worktree to the branch checked out in it. That reads only the parent
# clone's administrative files, so it never touches a worker's worktree.
#
# NO FALSE ALARMS. Silent for: a scout or secondmate record (no ship branch by
# design), a project clone with no origin remote at all (nothing is published
# and no CI runs, so there is no verdict to misread), a task whose local copy is
# still on the pristine detached base (no branch yet), a branch with no origin
# ref (never pushed), and a branch that already contains the base (level or
# ahead).
#
# NO FALSE GREENS. Anything it cannot determine - a missing project record or
# clone, a non-git project, an unresolvable default branch, an absent
# origin/<default>, a vanished or unlinked local copy, a detached HEAD carrying
# its own commits, or a git comparison that errors - is reported as
# undeterminable, never folded into silence.
#
# ACKNOWLEDGEMENT. A finding is silenced by `--ack <id>`, which records the
# finding's situation key in state/<id>.stale-base-ack. The key embeds the base
# commit, so the same finding stays quiet while firstmate's steer is in flight
# and the sweep re-alarms the moment the base moves again. That is what keeps
# the backstop from decaying into the ignored-because-constant noise this repo
# has already seen once.
#
# Usage:
#   fm-stale-base.sh [--project <dir>] [--all]   report; exit 1 if anything to report
#   fm-stale-base.sh --ack <task-id> [<id>...]   silence those findings at the current base
#   fm-stale-base.sh --ack-all                   silence every current finding
# Exit: 0 nothing to report, 1 at least one unacknowledged finding, 2 bad usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# default_branch() - the one owner of "which branch is this clone's default".
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

TAB=$'\t'
# A project path can never equal this, so the first task always opens a group.
NO_PROJECT_YET=$'\001'

usage() {
  cat >&2 <<'EOF'
usage: fm-stale-base.sh [--project <dir>] [--all]
       fm-stale-base.sh --ack <task-id> [<task-id>...]
       fm-stale-base.sh --ack-all
EOF
}

ONLY_PROJECT=
SHOW_ACKED=0
MODE=report
ACK_IDS=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --project)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ONLY_PROJECT=$2
      shift 2
      ;;
    --all) SHOW_ACKED=1; shift ;;
    --ack-all) MODE=ack-all; shift ;;
    --ack)
      MODE=ack
      shift
      [ "$#" -ge 1 ] || { usage; exit 2; }
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -*) break ;;
          *) ACK_IDS="$ACK_IDS $1"; shift ;;
        esac
      done
      ;;
    *) usage; exit 2 ;;
  esac
done

[ -d "$STATE" ] || exit 0

TMP_DIR=
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-stale-base.XXXXXX") || {
  echo "fm-stale-base: could not create a scratch dir" >&2
  exit 2
}

# --- helpers ----------------------------------------------------------------

# Canonical absolute path, falling back to the literal input when the path does
# not exist, so a missing local copy still compares and still gets reported.
real_path() {
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

project_label() {
  printf '%s\n' "${1##*/}"
}

# Read the three fields this sweep needs in ONE pass, with no subprocess per
# field: this runs on every turn end, once per in-flight task. Last occurrence
# wins, matching how every other reader treats a meta key.
META_KIND=
META_PROJECT=
META_WORKTREE=
read_meta() {  # <meta-file>
  local line
  META_KIND=
  META_PROJECT=
  META_WORKTREE=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) META_KIND=${line#kind=} ;;
      project=*) META_PROJECT=${line#project=} ;;
      worktree=*) META_WORKTREE=${line#worktree=} ;;
    esac
  done < "$1"
}

emit() {  # <status> <id> <situation-key> <sentence>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

ack_path() {  # <task-id>
  printf '%s/%s.stale-base-ack\n' "$STATE" "$1"
}

acked() {  # <task-id> <situation-key>
  local recorded
  recorded=$(cat "$(ack_path "$1")" 2>/dev/null) || return 1
  [ "$recorded" = "$2" ]
}

# --- worktree -> branch, from git's own record ------------------------------
#
# Returns 0 and sets WT_BRANCH/WT_HEAD/WT_DETACHED for <path> from a cached
# `git worktree list --porcelain` capture of the project clone; 1 if <path> is
# not one of that clone's worktrees.
WT_BRANCH=
WT_HEAD=
WT_DETACHED=0
lookup_worktree() {  # <porcelain-file> <path> [<resolved-path>]
  local file=$1 want=$2 want_real=${3:-$2} line cur='' head='' branch='' detached=0
  WT_BRANCH=
  WT_HEAD=
  WT_DETACHED=0
  [ -n "$want" ] || return 1
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *)
        cur=${line#worktree }
        head=
        branch=
        detached=0
        ;;
      HEAD\ *) head=${line#HEAD } ;;
      branch\ *) branch=${line#branch } ;;
      detached) detached=1 ;;
      '')
        if [ "$cur" = "$want" ] || [ "$cur" = "$want_real" ]; then
          WT_HEAD=$head
          WT_BRANCH=${branch#refs/heads/}
          WT_DETACHED=$detached
          return 0
        fi
        cur=
        ;;
    esac
  done < "$file"
  # A capture whose final record is not terminated by a blank line still counts.
  if [ -n "$cur" ] && { [ "$cur" = "$want" ] || [ "$cur" = "$want_real" ]; }; then
    WT_HEAD=$head
    WT_BRANCH=${branch#refs/heads/}
    WT_DETACHED=$detached
    return 0
  fi
  return 1
}

# --- the scan ---------------------------------------------------------------
#
# Emits one tab-separated record per REPORTABLE task:
#   <status><TAB><id><TAB><situation-key><TAB><sentence>
# status is `behind` or `unknown`; a determinate all-clear emits nothing. The
# situation key is what an acknowledgement is recorded against, so it embeds the
# base commit and a base that moves again re-alarms.
scan() {
  local meta id tasks only_real
  local cur_project=$NO_PROJECT_YET proj_state=ok label='' default='' base='' wt_list=''
  local proj_dir project worktree rc pushed behind_by want_real

  tasks="$TMP_DIR/tasks"
  : > "$tasks"
  wt_list="$TMP_DIR/worktrees"

  only_real=
  [ -z "$ONLY_PROJECT" ] || only_real=$(real_path "$ONLY_PROJECT")

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    read_meta "$meta"
    # A scout has no ship branch by design, and a secondmate is a persistent
    # home rather than a branch-bearing work item. Neither can be behind a base.
    case "$META_KIND" in
      scout|secondmate) continue ;;
    esac
    project=$META_PROJECT
    worktree=$META_WORKTREE
    # A record naming neither a project nor a local copy cannot have a branch at
    # all, so it is outside this check's domain rather than an unchecked item;
    # corrupt task metadata is bin/fm-crew-state.sh's to report.
    [ -n "$project" ] || [ -n "$worktree" ] || continue
    if [ -n "$only_real" ]; then
      [ -n "$project" ] || continue
      [ "$(real_path "$project")" = "$only_real" ] || continue
    fi
    printf '%s\t%s\t%s\n' "$project" "$id" "$worktree" >> "$tasks"
  done

  [ -s "$tasks" ] || return 0

  # Grouped by project so each clone is inspected once however many tasks it holds.
  while IFS=$TAB read -r proj_dir id worktree; do
    if [ "$proj_dir" != "$cur_project" ]; then
      cur_project=$proj_dir
      label=$(project_label "$proj_dir")
      proj_state=ok
      default=
      base=
      if [ -z "$proj_dir" ]; then
        proj_state='no-project'
      elif [ ! -d "$proj_dir" ]; then
        proj_state='project-missing'
      elif ! git -C "$proj_dir" rev-parse --git-dir >/dev/null 2>&1; then
        proj_state='not-a-repo'
      elif ! git -C "$proj_dir" remote get-url origin >/dev/null 2>&1; then
        # A clone with no origin at all publishes no branch and runs no CI on
        # one, so nothing here can be a misread verdict. That is out of this
        # check's domain, not an unchecked item - it is exactly the shape
        # bin/fm-fleet-sync.sh skips as a local-only project.
        proj_state='no-origin-remote'
      elif ! default=$(default_branch "$proj_dir"); then
        proj_state='no-default-branch'
      elif ! base=$(git -C "$proj_dir" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}" 2>/dev/null) \
        || [ -z "$base" ]; then
        proj_state='no-origin-base'
      elif ! git -C "$proj_dir" worktree list --porcelain > "$wt_list" 2>/dev/null; then
        proj_state='worktree-list-failed'
      fi
    fi

    case "$proj_state" in
      no-origin-remote) continue ;;
      no-project)
        emit unknown "$id" "unknown:no-project:none" \
          "cannot tell whether $id is behind: its record names no project"
        continue
        ;;
      project-missing)
        emit unknown "$id" "unknown:project-missing:none" \
          "cannot tell whether $id is behind: the local copy of $label ($proj_dir) is not there"
        continue
        ;;
      not-a-repo)
        emit unknown "$id" "unknown:not-a-repo:none" \
          "cannot tell whether $id is behind: $proj_dir is not a git repository"
        continue
        ;;
      no-default-branch)
        emit unknown "$id" "unknown:no-default-branch:none" \
          "cannot tell whether $id is behind: $label's default branch cannot be resolved"
        continue
        ;;
      no-origin-base)
        emit unknown "$id" "unknown:no-origin-base:none" \
          "cannot tell whether $id is behind: $label has no origin/$default ref to measure against"
        continue
        ;;
      worktree-list-failed)
        emit unknown "$id" "unknown:worktree-list-failed:$base" \
          "cannot tell whether $id is behind: git could not list $label's local copies"
        continue
        ;;
    esac

    want_real=$(real_path "$worktree")
    if ! lookup_worktree "$wt_list" "$worktree" "$want_real"; then
      if [ -z "$worktree" ]; then
        emit unknown "$id" "unknown:no-worktree-record:$base" \
          "cannot tell whether $id is behind: its record names no local copy to read a branch from"
      elif [ -d "$worktree" ]; then
        emit unknown "$id" "unknown:worktree-unlinked:$base" \
          "cannot tell whether $id is behind: its local copy $worktree is not one of $label's local copies"
      else
        emit unknown "$id" "unknown:worktree-gone:$base" \
          "cannot tell whether $id is behind: its local copy $worktree is gone"
      fi
      continue
    fi

    if [ "$WT_DETACHED" = 1 ] || [ -z "$WT_BRANCH" ]; then
      # Still parked on the pristine base with no commits of its own: the task
      # has not branched yet, a determinate "nothing here can be behind".
      if [ -n "$WT_HEAD" ] && git -C "$proj_dir" merge-base --is-ancestor "$WT_HEAD" "$base" 2>/dev/null; then
        continue
      fi
      emit unknown "$id" "unknown:detached-head:$base" \
        "cannot tell whether $id is behind: its local copy carries its own commits with no branch to name"
      continue
    fi

    # Never pushed, so no CI verdict exists on it to be misread.
    pushed=$(git -C "$proj_dir" rev-parse --verify --quiet "refs/remotes/origin/$WT_BRANCH^{commit}" 2>/dev/null) || pushed=
    [ -n "$pushed" ] || continue

    git -C "$proj_dir" merge-base --is-ancestor "$base" "$pushed" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] && continue
    if [ "$rc" -ne 1 ]; then
      emit unknown "$id" "unknown:git-compare-failed:$base" \
        "cannot tell whether $id is behind: git could not compare $WT_BRANCH with origin/$default"
      continue
    fi

    behind_by=$(git -C "$proj_dir" rev-list --count "$pushed..$base" 2>/dev/null) || behind_by=
    if [ -n "$behind_by" ]; then
      emit behind "$id" "behind:$base" \
        "$id ($label) is on $WT_BRANCH, $behind_by commit(s) behind origin/$default - every CI result on it was measured against a base that no longer exists; merge origin/$default into $WT_BRANCH and re-verify"
    else
      emit behind "$id" "behind:$base" \
        "$id ($label) is on $WT_BRANCH, behind origin/$default - every CI result on it was measured against a base that no longer exists; merge origin/$default into $WT_BRANCH and re-verify"
    fi
  done < <(sort "$tasks")
}

# --- run --------------------------------------------------------------------

RECORDS=$(scan) || { echo "fm-stale-base: sweep failed" >&2; exit 2; }

if [ "$MODE" = ack ] || [ "$MODE" = ack-all ]; then
  if [ "$MODE" = ack ] && [ -z "${ACK_IDS# }" ]; then
    usage
    exit 2
  fi
  ACKED_ANY=0
  while IFS=$TAB read -r status id key text; do
    [ -n "$status" ] || continue
    if [ "$MODE" = ack ]; then
      case " ${ACK_IDS# } " in
        *" $id "*) ;;
        *) continue ;;
      esac
    fi
    # The id came from a state/*.meta basename this sweep just read, so the
    # marker path is never caller-controlled.
    printf '%s\n' "$key" > "$(ack_path "$id")" || exit 2
    printf 'acknowledged: %s\n' "$id"
    ACKED_ANY=1
  done <<< "$RECORDS"
  [ "$ACKED_ANY" = 1 ] || printf 'no current stale-base finding to acknowledge\n'
  exit 0
fi

REPORT=
UNACKED=0
HAS_BEHIND=0
HAS_UNKNOWN=0
while IFS=$TAB read -r status id key text; do
  [ -n "$status" ] || continue
  if acked "$id" "$key"; then
    [ "$SHOW_ACKED" = 1 ] || continue
    REPORT="${REPORT}STALE BASE (acknowledged): ${text}"$'\n'
    continue
  fi
  UNACKED=1
  case "$status" in
    behind)
      HAS_BEHIND=1
      REPORT="${REPORT}STALE BASE: ${text}"$'\n'
      ;;
    *)
      HAS_UNKNOWN=1
      REPORT="${REPORT}STALE BASE UNDETERMINABLE: ${text}"$'\n'
      ;;
  esac
done <<< "$RECORDS"

[ -n "$REPORT" ] || exit 0

# EVERY line this script prints starts with "STALE BASE", including the remedy
# footer. bin/fm-bootstrap.sh's session-start relay is an allowlist that drops
# any fleet-sync line it does not recognise, so a report whose lines did not
# share one stable marker would have its remedy silently stripped, or the whole
# finding dropped, at exactly the moment firstmate is building its picture.
printf '%s' "$REPORT"
if [ "$HAS_BEHIND" = 1 ]; then
  printf 'STALE BASE REMEDY: steer each worker above to do exactly the merge named on its line, then re-verify that branch.\n'
  # shellcheck disable=SC2016 # The backticked flag is literal text, not an expansion.
  printf 'STALE BASE REMEDY: Never rebase - a global settings rule denies `git push --force*`, so a rebased branch cannot be pushed at all.\n'
  # A fast read BEFORE that merge, never instead of it: the CI check re-runs the
  # base's own assertions against the branch without re-driving the suite, but
  # it never merges the base's SOURCE in, so it cannot see the two sets of
  # changes conflicting. The merge above is still what settles that.
  printf "STALE BASE REMEDY: for a fast first read on a branch that has an open PR, re-run its 'Base re-verification' workflow (gh run rerun <run-id>) - it re-fetches the base and re-runs only the base test files that differ, so it needs no new push. It answers whether the base's assertions still hold, NOT whether the two sets of source changes integrate; the merge above is still required.\n"
fi
if [ "$HAS_UNKNOWN" = 1 ]; then
  printf 'STALE BASE REMEDY: undeterminable is not clean - resolve each one above before treating any CI result on that branch as a verdict on the branch.\n'
fi
printf 'STALE BASE REMEDY: once acted on, silence a finding with bin/fm-stale-base.sh --ack <task-id>\n'

[ "$UNACKED" = 1 ] && exit 1
exit 0
