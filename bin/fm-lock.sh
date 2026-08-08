#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate SESSION lock (state/.lock), the file
# that records which session controls this home's fleet. It is not the watcher
# singleton (state/.watch.lock); bin/fm-session-lock-lib.sh owns that distinction
# and every ancestry walk used here.
# Acquiring writes the harness (agent) process PID found by walking the shell's
# ancestry, which lives as long as the firstmate session - unlike the transient
# subshell PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh             acquire; exit 1 if another live session holds it
#        fm-lock.sh status      print holder and liveness; always exits 0
#        fm-lock.sh ownership   print owned|other|missing for the CALLING
#                               process's ancestry; always exits 0, writes
#                               nothing. This is the one entry point the
#                               OpenCode and Pi adapters use instead of
#                               reimplementing the walk in JavaScript.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "ownership" ]; then
  # Read-only by contract: never create the state dir, never touch the lock.
  fm_session_lock_ownership "$STATE"
  exit 0
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if fm_session_lock_holder_is_harness "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

mkdir -p "$STATE"
me=$(fm_session_harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && fm_session_lock_holder_is_harness "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
