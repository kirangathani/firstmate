#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate SESSION lock (state/.lock), the file
# that records which session controls this home's fleet. It is not the watcher
# singleton (state/.watch.lock); bin/fm-session-lock-lib.sh owns that distinction
# and every ancestry walk used here.
# Acquiring writes the harness (agent) process PID found by walking the shell's
# ancestry, which lives as long as the firstmate session - unlike the transient
# subshell PID of any one tool call, which is dead moments after it is written.
# It writes that PID on line 1 and, where the kernel offers it, that process's
# start ticks on line 2, so a reused PID cannot be mistaken for the holder.
# Usage: fm-lock.sh             acquire; exit 1 if another live session holds it
#        fm-lock.sh status      print holder and liveness; always exits 0
#        fm-lock.sh ownership   print owned|other|missing for the CALLING
#                               process's ancestry; always exits 0, writes
#                               nothing. This is the one entry point the
#                               OpenCode and Pi adapters use instead of
#                               reimplementing the walk in JavaScript.
# Any other argument prints that usage and exits 2, creating nothing: the verb
# list used to be a two-way test, so `fm-lock.sh --help` ATTEMPTED AN ACQUISITION
# and made state/ on the way (run for real during the 2026-09-15 lock-loss
# incident). The holder description and the remedy printed by `status` and by the
# acquire refusal are bin/fm-session-lock-lib.sh's, so every surface that has to
# explain a refusal says the same thing about the same holder.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# The header block above is the usage text; printing it from the file keeps the
# two from drifting, and matching on its content rather than on line numbers
# survives the next edit above it.
usage() {
  sed -n '/^# Usage: fm-lock.sh/,/^# Any other argument/p' "${BASH_SOURCE[0]}" \
    | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  ownership)
    # Read-only by contract: never create the state dir, never touch the lock.
    fm_session_lock_ownership "$STATE"
    exit 0
    ;;
  status)
    if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
    if ! fm_session_lock_read "$STATE"; then
      echo "lock: stale (unreadable or malformed)"
    elif fm_session_lock_holder_is_harness "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_TICKS"; then
      echo "lock: held by live harness $(fm_session_lock_describe_holder "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_TICKS")"
      # A live holder this session is not descended from is the case an operator
      # runs `status` to resolve, so name the way out of it here too.
      if ! fm_pid_ancestry_contains "$FM_SESSION_LOCK_PID"; then
        echo "lock: $(fm_session_lock_remedy)"
      fi
    else
      echo "lock: stale - $(fm_session_lock_describe_holder "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_TICKS")"
    fi
    exit 0
    ;;
  '') ;;
  *)
    usage >&2
    exit 2
    ;;
esac

mkdir -p "$STATE"
me=$(fm_session_harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
# The recorded start ticks are part of the holder's identity, so a pid the kernel
# has since handed to an unrelated process reads as stale here exactly as it does
# in fm_session_lock_ownership.
if fm_session_lock_read "$STATE"; then
  if [ "$FM_SESSION_LOCK_PID" != "$me" ] \
    && fm_session_lock_holder_is_harness "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_TICKS"; then
    echo "error: another live firstmate session holds the lock: $(fm_session_lock_describe_holder "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_TICKS")" >&2
    echo "error: operate read-only until resolved - $(fm_session_lock_remedy)" >&2
    exit 1
  fi
fi
fm_session_lock_write "$STATE" "$me"
echo "lock acquired: harness pid $me"
