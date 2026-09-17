#!/usr/bin/env bash
# The durable hand-off for wake rows that have been drained but not yet READ.
#
# bin/fm-wake-drain.sh's at-least-once no-loss boundary is "print before delete":
# once the rows are on the drain's stdout, the queue file may go. That is exactly
# right while the model itself runs the drain, because the model IS the reader.
# It stops being enough once the arm drains on the way out (bin/fm-watch-arm.sh):
# the reader is then a harness task's output buffer, and nothing obliges anyone to
# look at it. A stopped task, an ended session, or a missed notification would
# take the words with it, and the queue that held them is already gone.
#
# So the arm records the rows here first and prints them second. This file is the
# answer to "what has been drained that no session has picked up?", and it is
# read back at session start, which is the one moment a fresh model is certainly
# looking. Duplicates are the deliberate failure direction: a wake delivered twice
# costs a glance, a wake delivered never costs a crewmate sitting unanswered.
#
# ALSO the delivery route for a firstmate command that runs as a background task
# and has a result worth putting in front of the model - a merge that landed, a
# check that came back - without the model spending a call to go and read it.
# Such a command opts in with one line after it has done its work:
#
#   printf 'merged: %s\n' "$url" | bin/fm-wake-pending.sh --record
#
# and the line is then handed over with the next wake's words. It is a courtesy
# channel, not a queue: a command whose result the model must ACT on belongs in
# the durable wake queue through bin/fm-wake-lib.sh's fm_wake_append instead, so
# that it survives with a kind, a key, and the dedupe that goes with them.
#
# Usage:
#   fm-wake-pending.sh --record      read lines on stdin, append them
#   fm-wake-pending.sh --take        print everything pending, then clear it
#   fm-wake-pending.sh --peek        print everything pending, changing nothing
#
# --take is print-before-clear, the same at-least-once boundary as the drain, and
# for the same reason: a crash between the two repeats a wake, which is the
# recoverable direction.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

PENDING="$STATE/.wake-pending"
PENDING_LOCK="$STATE/.wake-pending.lock"
# A bound so an unread log cannot grow without limit in a home nobody opens. The
# NEWEST rows are the ones kept: an unread wake from days ago has been overtaken
# by the fleet state a fresh session reads anyway.
PENDING_MAX_LINES=${FM_WAKE_PENDING_MAX_LINES:-500}

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

pending_lock() {
  local i=0
  while ! fm_lock_try_acquire "$PENDING_LOCK"; do
    [ "$i" -lt 50 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  return 0
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --record)
    # Never fails its caller. The caller is on the wake path, and a failure to
    # record a courtesy copy must not cost the delivery it is a copy OF.
    pending_lock || exit 0
    cat >> "$PENDING" 2>/dev/null || true
    if [ "$(wc -l < "$PENDING" 2>/dev/null | tr -d '[:space:]')" -gt "$PENDING_MAX_LINES" ] 2>/dev/null; then
      tail -n "$PENDING_MAX_LINES" "$PENDING" > "$PENDING.trim" 2>/dev/null \
        && mv -f "$PENDING.trim" "$PENDING" 2>/dev/null
      command rm -f -- "$PENDING.trim" 2>/dev/null || true
    fi
    fm_lock_release "$PENDING_LOCK"
    exit 0
    ;;
  --peek)
    [ -s "$PENDING" ] || exit 0
    cat "$PENDING" 2>/dev/null || true
    exit 0
    ;;
  --take)
    pending_lock || exit 0
    if [ ! -s "$PENDING" ]; then
      fm_lock_release "$PENDING_LOCK"
      exit 0
    fi
    # Print first, clear second: a crash in the gap repeats a wake rather than
    # dropping one.
    cat "$PENDING" 2>/dev/null || { fm_lock_release "$PENDING_LOCK"; exit 1; }
    : > "$PENDING" 2>/dev/null || true
    fm_lock_release "$PENDING_LOCK"
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
