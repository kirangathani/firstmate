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
# THE RESULTS CHANNEL is the second thing this file owns, and it is a SEPARATE
# log for a reason. A firstmate command that runs as a background task or a
# Monitor often has a result worth putting in front of the model - a merge that
# landed, a document that was written, a check that came back - and no reason to
# cost a call to go and read it. Such a command opts in with one line after it
# has done its work:
#
#   printf 'merged: %s\n' "$url" | bin/fm-wake-pending.sh --result
#
# and the line goes out with the next wake, printed by the arm on its way out
# (bin/fm-watch-arm.sh) and cleared as it goes. It is a courtesy channel, not a
# queue: a command whose result the model must ACT on belongs in the durable
# wake queue through bin/fm-wake-lib.sh's fm_wake_append instead, so that it
# survives with a kind, a key, and the dedupe that goes with them.
#
# WHY NOT ONE LOG FOR BOTH. The two have opposite lifetimes. A drained wake row
# is UNREAD until a fresh session certainly looks at it, so it must survive every
# wake in between; a result line is delivered the first time anything wakes and
# is then spent. Putting them together would force one rule on both: take them
# on a wake and the unread rows are gone if that notification is missed, leave
# them for session start and a result waits hours for the next `/clear`. They
# are also written by opposite parties - the arm writes rows and reads results,
# a background command writes results and never reads either - so one file would
# have the arm taking back the rows it had just recorded.
# Measured 2026-09-17 (data/fm-foreground-audit-f9/report.md, blocker 3): before
# this split the results route was documented here and wired nowhere, so a line
# a background command recorded surfaced only at the next session start.
#
# Usage:
#   fm-wake-pending.sh --record        read lines on stdin, append them as UNREAD WAKE ROWS
#   fm-wake-pending.sh --take          print every unread wake row, then clear them
#   fm-wake-pending.sh --peek          print every unread wake row, changing nothing
#   fm-wake-pending.sh --result        read lines on stdin, append them as RESULT LINES
#   fm-wake-pending.sh --take-results  print every result line, then clear them
#   fm-wake-pending.sh --peek-results  print every result line, changing nothing
#
# Both takes are print-before-clear, the same at-least-once boundary as the
# drain, and for the same reason: a crash between the two repeats a line, which
# is the recoverable direction.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

PENDING="$STATE/.wake-pending"
PENDING_LOCK="$STATE/.wake-pending.lock"
RESULTS="$STATE/.wake-results"
RESULTS_LOCK="$STATE/.wake-results.lock"
# A bound so an unread log cannot grow without limit in a home nobody opens. The
# NEWEST rows are the ones kept: an unread wake from days ago has been overtaken
# by the fleet state a fresh session reads anyway.
PENDING_MAX_LINES=${FM_WAKE_PENDING_MAX_LINES:-500}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

pending_lock() {
  local lock=${1:-$PENDING_LOCK} i=0
  while ! fm_lock_try_acquire "$lock"; do
    [ "$i" -lt 50 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  return 0
}

# Append stdin to $1, bounded, under $2. Never fails its caller: the caller is on
# the wake path, and a failure to record a courtesy copy must not cost the
# delivery it is a copy OF.
append_bounded() {
  local file=$1 lock=$2
  pending_lock "$lock" || exit 0
  cat >> "$file" 2>/dev/null || true
  if [ "$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]')" -gt "$PENDING_MAX_LINES" ] 2>/dev/null; then
    tail -n "$PENDING_MAX_LINES" "$file" > "$file.trim" 2>/dev/null \
      && mv -f "$file.trim" "$file" 2>/dev/null
    command rm -f -- "$file.trim" 2>/dev/null || true
  fi
  fm_lock_release "$lock"
  exit 0
}

# Print everything in $1 and clear it, under $2. Print FIRST: a crash in the gap
# repeats a line rather than dropping one.
take_all() {
  local file=$1 lock=$2
  pending_lock "$lock" || exit 0
  if [ ! -s "$file" ]; then
    fm_lock_release "$lock"
    exit 0
  fi
  cat "$file" 2>/dev/null || { fm_lock_release "$lock"; exit 1; }
  : > "$file" 2>/dev/null || true
  fm_lock_release "$lock"
  exit 0
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --record)
    append_bounded "$PENDING" "$PENDING_LOCK"
    ;;
  --peek)
    [ -s "$PENDING" ] || exit 0
    cat "$PENDING" 2>/dev/null || true
    exit 0
    ;;
  --take)
    take_all "$PENDING" "$PENDING_LOCK"
    ;;
  --result)
    append_bounded "$RESULTS" "$RESULTS_LOCK"
    ;;
  --peek-results)
    [ -s "$RESULTS" ] || exit 0
    cat "$RESULTS" 2>/dev/null || true
    exit 0
    ;;
  --take-results)
    take_all "$RESULTS" "$RESULTS_LOCK"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
