#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and GitHub's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# That poll's header owns when an armed poll wakes firstmate, including the
# standing merge rule's extra requirement that a task still reporting work in
# progress does not wake anything on green.
#
# --from-watcher is for the one caller that is not firstmate: bin/fm-watch.sh
# records a PR the moment a worker's own `done: PR <url>` line reaches the status
# log, so the recorded fact follows the task rather than waiting for a hand-run.
# It changes exactly two things, both because the CALLER is the watcher itself:
#
#   IT DOES NOT ACK. The automatic record discharges the MACHINE half of what the
#   report owes - the fact and the merge poll - and none of the captain-facing
#   half. Acking here would silence the unactioned alarm (bin/fm-ack-lib.sh) that
#   is what forces firstmate to relay the PR at all.
#
#   IT DOES NOT RUN THE MIGRATION. bin/fm-pr-check-migrate.sh takes watcher
#   exclusion by TERMing the pid in state/.watch.lock, which on this path is the
#   very process calling this script: the watcher would kill itself on every
#   reported PR. It is bin/fm-bootstrap.sh's to run at session start, and a live
#   watcher has already passed that.
#
#   IT DOES NOT RUN THE GUARD EITHER. bin/fm-guard.sh prints diagnostics for
#   firstmate to read; on this path nobody reads them, and its unactioned
#   predicate may fork a crew-state confirm per task, which is not a cost a
#   watcher poll should pay.
# Usage: fm-pr-check.sh [--from-watcher] <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ack-lib.sh
. "$SCRIPT_DIR/fm-ack-lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

FROM_WATCHER=0
if [ "${1-}" = --from-watcher ]; then
  FROM_WATCHER=1
  shift
fi
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
# it quarantines or rebuilds them - which is exactly why --from-watcher skips it
# (this file's header).
[ "$FROM_WATCHER" -eq 1 ] || "$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
[ "$FROM_WATCHER" -eq 1 ] || "$FM_ROOT/bin/fm-guard.sh" || true

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
PR_STATE=
if [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
  PR_STATE=$(cd "$WT" && gh pr view "$URL" --json state -q .state 2>/dev/null) || PR_STATE=
fi

# WARN, NEVER REFUSE, ON A PR THAT IS ALREADY MERGED. Recording a merged PR is
# legitimate on the ordinary path - bin/fm-pr-merge.sh records before it merges,
# and a re-run after landing is a supported no-op - so this cannot be a refusal
# without breaking both. It is still worth saying, because it is the other end of
# the defect this task fixed: a multi-PR task whose recorded fact lags behind its
# worker leaves the viewer drawing a merged PR beside a task that has moved on,
# and leaves a merge poll firing `merged` forever at a PR nobody is waiting for.
if [ "$PR_STATE" = MERGED ]; then
  echo "warning: $URL is already merged; recording it arms a merge poll that will report it merged on every sweep" >&2
  echo "warning: if this task has moved on to a later PR, record THAT one instead - the recorded PR is what the fleet view draws and what the merge poll watches" >&2
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
# THE WHOLE TEST IS ONE ANCESTRY QUESTION, asked in the direction that needs no
# second fact: is the PR's head a STRICT ANCESTOR of this copy's tip? Only one
# situation answers yes - the branch has moved on from what the PR carries - and
# that is exactly the defect. It is deliberately not the mirror-image test
# ("is the tip contained in the PR head"), which is false for unrelated
# histories too and so would need the PR's head BRANCH read to tell a moved-on
# branch from a worktree that was never this PR's at all. Asking it this way
# makes that read, and its answer in every gh mock in the suite, unnecessary.
#
# IT REFUSES ONLY ON POSITIVE EVIDENCE, and every other reading is silent:
#   - No gh, no worktree, or an unreadable PR leaves PR_HEAD empty: unknown, not
#     wrong, and already the condition under which pr_head= is not recorded.
#   - UNRELATED is silent: in the upstream-PR shape the worktree drives a branch
#     that is not what this PR carries, so neither tip contains the other and
#     nothing may be concluded from the pair.
#   - BEHIND IS SILENT and must stay so. A no-mistakes PR is pushed by the
#     pipeline from its own worktree under ~/.no-mistakes/worktrees/, so the
#     task's own copy legitimately lags the PR head; refusing on that would
#     break every pipeline task.
#   - A PR head the local repository has never heard of is left alone rather
#     than fetched. Nothing here may make an unbounded network call: this path
#     runs while firstmate is recording a report, and the case being caught -
#     work committed locally and never pushed - always already has the PR head
#     locally, because that head was pushed from this same copy.
# IT APPLIES ONLY TO THE FIRST RECORDING OF THIS PR, because a re-run against a
# PR this task already recorded is a supported no-op whose moved-head case the
# base already refuses one step later, at teardown
# (tests/fm-teardown.test.sh's "merged PR does not allow teardown after a later
# local commit" and "pr-check-stale"). Refusing here too would break that
# re-run for a case already covered, so this adds the guard only where nothing
# had one: the first recording, which is the moment the incident happened - the
# worker reported `done: PR <url>` and firstmate recorded it for the first time.
ALREADY_RECORDED=0
if grep -qxF "pr=$URL" "$META" 2>/dev/null; then
  ALREADY_RECORDED=1
fi

if [ -n "$PR_HEAD" ] && [ "$ALREADY_RECORDED" -eq 0 ]; then
  LOCAL_TIP=$(cd "$WT" && git rev-parse HEAD 2>/dev/null || true)
  if fm_pr_head_valid "$LOCAL_TIP" && [ "$LOCAL_TIP" != "$PR_HEAD" ] \
    && (cd "$WT" && git cat-file -e "$PR_HEAD^{commit}" 2>/dev/null) \
    && (cd "$WT" && git merge-base --is-ancestor "$PR_HEAD" "$LOCAL_TIP" 2>/dev/null); then
    echo "error: $URL does not carry this task's committed work: its head is $PR_HEAD, and this task's copy has moved on to $LOCAL_TIP" >&2
    echo "error: the PR's checks therefore describe the version before those commits, so nothing is recorded and no merge poll is armed; steer the worker to push its branch, let the checks re-run, then run this again" >&2
    exit 1
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
# while it legitimately waits on review or merge. --from-watcher is the one
# exception, and this file's header owns why.
[ "$FROM_WATCHER" -eq 1 ] || fm_ack_record "$STATE" "$ID" "fm-pr-check $URL" || true
