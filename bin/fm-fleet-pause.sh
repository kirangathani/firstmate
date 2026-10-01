#!/usr/bin/env bash
# The captain's fleet pause: the ONE way to pause or resume workers on his order.
#
# Usage:
#   fm-fleet-pause.sh pause  [<task-id>...] [--except <task-id>...]
#   fm-fleet-pause.sh resume [<task-id>...] [--except <task-id>...]
#   fm-fleet-pause.sh status
#
# The captain's words, 2026-10-01: "when a worker you told to PAUSE pauses then
# it should not notify you"; "You DETERMINISTICALLY PAUSE WORKERS, DONT go and
# then VERIFY whether the pause has reached them"; and a resume that firstmate
# hand-picked left four of ten workers paused.
#
# TARGETS. With no ids, pause targets EVERY direct report this home records, one
# per state/<id>.meta, and resume targets every state/<id>.captain-pause record.
# Never a hand-picked list: the enumeration is the point. With ids, only those;
# --except removes ids from either set. A named or excepted id this home has no
# record of refuses the whole command before anything is written, because a
# typo in "pause everything except X" would otherwise pause X.
# Pause skips a task the captain is driving himself or that carries a verified
# upstream wait (bin/fm-ack-lib.sh's fm_captain_driven and fm_upstream_waiting):
# both are already out of supervision for their own stated reasons.
#
# PAUSE writes every record FIRST, then sends each worker one fixed instruction
# through bin/fm-send.sh. The record is state/<id>.captain-pause, one line:
#   <epoch>\t<the worker's last status line before the pause>
# bin/fm-ack-lib.sh's fm_captain_paused reads it, and while it exists
# fm_supervision_suspended is true for the task, so the watcher raises no signal,
# stale, or heartbeat wake for it and the unactioned, stalled-validation,
# stale-base, and turn-end guards treat it as owing nothing. It is unsigned by
# design (fm-ack-lib.sh says why) and announced at every session start.
# Re-pausing a paused task keeps its original record, so the pre-pause line is
# never overwritten by whatever the worker said while paused.
# Nothing is peeked, waited on, or verified: a failed send is one line, and the
# record stands either way, so a worker that never got the message still raises
# no notification.
#
# RESUME removes each record, then sends the fixed resume instruction. When the
# worker's own pre-pause status line was a declared wait (`paused:`), the same
# message repeats it back, so a worker that was waiting on a parent branch or an
# upstream release is told to keep waiting on it rather than skipped.
#
# STATUS prints one row per paused task: <id>\t<paused-at-epoch>\t<pre-pause line>.
#
# Exit: 0 done (individual send failures are reported, not fatal), 2 bad usage
# or an unknown id.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SEND="${FM_FLEET_PAUSE_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

# shellcheck source=bin/fm-ack-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ack-lib.sh"

PAUSE_TEXT="CAPTAIN'S ORDER - PAUSE NOW: commit your work in progress on your branch, stop any dev server and close any browser you started, start or re-attach no validation run, push nothing, append no status line, then sit idle until you are told to resume."
RESUME_TEXT="CAPTAIN'S ORDER - RESUME: carry on with your task from where you paused."

usage() {
  sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -ge 1 ] || usage
MODE=$1
shift
case "$MODE" in pause|resume|status) ;; *) usage ;; esac

IDS=
EXCEPT=
in_except=0
for a in "$@"; do
  case "$a" in
    --except) in_except=1 ;;
    -*) usage ;;
    *) if [ "$in_except" = 1 ]; then EXCEPT="$EXCEPT $a"; else IDS="$IDS $a"; fi ;;
  esac
done

for id in $IDS $EXCEPT; do
  if [ ! -f "$STATE/$id.meta" ] && [ ! -f "$(fm_captain_pause_file "$STATE" "$id")" ]; then
    echo "error: no record for '$id' in $STATE; nothing was paused or resumed" >&2
    exit 2
  fi
done

if [ "$MODE" = status ]; then
  found=0
  for f in "$STATE"/*.captain-pause; do
    [ -e "$f" ] || continue
    id=${f##*/}
    id=${id%.captain-pause}
    fm_captain_paused "$STATE" "$id"
    printf '%s\t%s\t%s\n' "$id" "${FM_CAPTAIN_PAUSE_AT:--}" "${FM_CAPTAIN_PAUSE_PRIOR:--}"
    found=1
  done
  [ "$found" = 1 ] || echo "no worker is paused"
  exit 0
fi

if [ -z "$IDS" ]; then
  if [ "$MODE" = pause ]; then glob=meta; else glob=captain-pause; fi
  for f in "$STATE"/*."$glob"; do
    [ -e "$f" ] || continue
    id=${f##*/}
    IDS="$IDS ${id%."$glob"}"
  done
fi

TARGETS=
for id in $IDS; do
  case " $EXCEPT " in *" $id "*) continue ;; esac
  case " $TARGETS " in *" $id "*) continue ;; esac
  TARGETS="$TARGETS $id"
done

send() {  # <id> <text>
  local out
  if ! out=$(FM_ARM_POOL_NO_REFILL=1 FM_SEND_SETTLE=0 FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" "$SEND" "$1" "$2" 2>&1 </dev/null); then
    printf 'send failed: %s: %s\n' "$1" "$(printf '%s' "$out" | tail -n 1)"
  fi
}

if [ "$MODE" = pause ]; then
  SENDS=
  # Every record before any send, so no worker can report into a wake between
  # the instruction arriving and its own record existing.
  for id in $TARGETS; do
    if fm_captain_driven "$STATE" "$id"; then
      printf 'skipped: %s - the captain is driving it\n' "$id"
      continue
    fi
    if fm_upstream_waiting "$STATE" "$id"; then
      printf 'skipped: %s - waiting on action from upstream\n' "$id"
      continue
    fi
    rec=$(fm_captain_pause_file "$STATE" "$id")
    if [ ! -f "$rec" ]; then
      printf '%s\t%s\n' "$(fm_ack_now)" "$(last_status_line "$STATE/$id.status" 2>/dev/null)" > "$rec" || {
        printf 'error: could not write %s\n' "$rec"
        continue
      }
    fi
    SENDS="$SENDS $id"
  done
  for id in $SENDS; do send "$id" "$PAUSE_TEXT"; done
  printf 'paused:%s\n' "${SENDS:- none}"
  exit 0
fi

DONE=
for id in $TARGETS; do
  fm_captain_paused "$STATE" "$id" || continue
  prior=$FM_CAPTAIN_PAUSE_PRIOR
  rm -f "$(fm_captain_pause_file "$STATE" "$id")"
  DONE="$DONE $id"
  [ -f "$STATE/$id.meta" ] || continue
  text=$RESUME_TEXT
  if status_is_paused "$prior"; then
    text="$text Before the pause your own last status was: $prior - if that wait still holds, keep waiting on it exactly as before."
  fi
  send "$id" "$text"
done
printf 'resumed:%s\n' "${DONE:- none}"
exit 0
