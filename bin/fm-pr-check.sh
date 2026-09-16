#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and GitHub's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# That poll's header owns when an armed poll wakes firstmate, including the
# standing merge rule's extra requirement that a task still reporting work in
# progress does not wake anything on green.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ack-lib.sh
. "$SCRIPT_DIR/fm-ack-lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
PR_BRANCH=
if [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
  # A SEPARATE read, deliberately, rather than one --json headRefOid,headRefName.
  # The recorded pr_head= above is the older contract and several suites stub gh
  # by matching that exact projection, so widening it would change what every
  # one of those fixtures answers - and a fixture that stops matching answers
  # empty, which reads as "unknown" and silently disables a check rather than
  # failing. The branch name is only ever a guard on the comparison below, so it
  # costs one call on an already-network-bound path and nothing when it fails.
  PR_BRANCH=$(cd "$WT" && gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null || true)
fi

# REFUSE A PR THAT DOES NOT CARRY THE WORK ITS TASK HAS ALREADY COMMITTED.
# This is the other end of the defect bin/fm-brief.sh's definition of done
# addresses: a worker that commits a fix, reports `done: PR <url>`, and stops
# without pushing. Measured 2026-09-16 on fm-brief-attach-ownership-a3, whose
# fix commit 0b16c1b3 never reached PR 97 while its head stayed at 8b2da7d5.
# Firstmate read the resulting red as a verdict on the branch when it was a
# verdict on the version before the fix, and only caught it by hand-comparing
# the two shas - a step nothing required it to take. This is the moment both
# facts are in hand, and it is before the merge poll is armed, which matters
# most under the standing merge rule: arming a poll on a PR missing the fix is
# arming an auto-merge of the wrong commit.
#
# IT REFUSES ONLY ON POSITIVE EVIDENCE, and is silent otherwise, because every
# uncertainty here has an innocent reading:
#   - No gh, no worktree, or an unreadable PR leaves PR_HEAD empty: unknown, not
#     wrong, and already the condition under which pr_head= is simply not
#     recorded.
#   - A worktree on a DIFFERENT branch than the PR's head ref is the upstream-PR
#     shape, where the local branch is not what the PR carries at all.
#   - BEHIND IS FINE and must stay fine. A no-mistakes PR is pushed by the
#     pipeline from its own worktree under ~/.no-mistakes/worktrees/, so the
#     task's own copy legitimately lags the PR head; refusing on that would
#     break every pipeline task. The refusal is specifically that the local
#     branch holds commits the PR head does not contain.
#   - A PR head the local repository has never heard of is left alone rather
#     than fetched. Nothing here may make an unbounded network call: this path
#     runs while firstmate is recording a report, and the case being caught -
#     work committed locally and never pushed - always already has the PR head
#     locally, because that head was pushed from this same copy.
if [ -n "$PR_HEAD" ] && [ -n "$PR_BRANCH" ]; then
  LOCAL_BRANCH=$(cd "$WT" && git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$LOCAL_BRANCH" ] && [ "$LOCAL_BRANCH" = "$PR_BRANCH" ]; then
    LOCAL_TIP=$(cd "$WT" && git rev-parse HEAD 2>/dev/null || true)
    if fm_pr_head_valid "$LOCAL_TIP" && [ "$LOCAL_TIP" != "$PR_HEAD" ]; then
      if (cd "$WT" && git cat-file -e "$PR_HEAD^{commit}" 2>/dev/null) \
        && ! (cd "$WT" && git merge-base --is-ancestor "$LOCAL_TIP" "$PR_HEAD" 2>/dev/null); then
        echo "error: $URL does not carry this task's committed work: its head is $PR_HEAD, but the branch $LOCAL_BRANCH is at $LOCAL_TIP, which that head does not contain" >&2
        echo "error: the PR's checks therefore describe the version before those commits, so nothing is recorded and no merge poll is armed; steer the worker to push $LOCAL_BRANCH, let the checks re-run, then run this again" >&2
        exit 1
      fi
    fi
  fi
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$URL" "$OWNER" "$REPO" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_URL" = "$URL" ] && [ "$FM_PR_META_OWNER" = "$OWNER" ] \
  && [ "$FM_PR_META_REPO" = "$REPO" ] && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_URL" = "$URL" ] && [ "$FM_PR_META_OWNER" = "$OWNER" ] \
  && [ "$FM_PR_META_REPO" = "$REPO" ] && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"

# Recording the PR and arming the merge poll IS the action a PR-ready `done:`
# owes, so ack it here (bin/fm-ack-lib.sh) instead of leaving the task alarming
# while it legitimately waits on review or merge.
fm_ack_record "$STATE" "$ID" "fm-pr-check $URL" || true
