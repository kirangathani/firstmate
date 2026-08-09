#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - a live+fresh successor holds the lock;
#                                                          this arm attaches and follows it
#   watcher: cycle-complete - ... delivered a wake and exited ...
#                                                        - the cycle this arm followed ended by
#                                                          producing a real wake. Exit 0.
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - cycle ended without an actionable reason ...
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor, beacon fresh
#   watcher: FAILED - supervision LAPSED: ...            - no wake, no successor, and the beacon is
#                                                          stale past GRACE: nobody is supervising
#
# The last three used to be one line, and that is the defect the split fixes. A
# cycle always ends with no watcher running and the lock released, so "the cycle
# ended" is equally true of a healthy close and a dead one; reporting both as the
# same failure made the real one unnoticeable among the benign ones. Measured in
# the captain's home on 2026-08-09: all 52 watcher pids that ever produced this
# failure also had an owning `started` record classified actionable-signal/stale/
# check/heartbeat, i.e. every single one was a completed cycle whose wake had
# already been delivered to the arm that owned it. The discriminator is the
# durable wake counter (fm_wake_seq in bin/fm-wake-lib.sh), which only a real
# fm_wake_append advances and which no drain resets, cross-checked against the
# beacon; see cycle_outcome below.
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits the child and propagates the wake
# reason; on attached it stays live across identity-matched successors. An
# attached cycle that ends without a healthy successor is never a clean EMPTY
# completion an adapter could mistake for a no-op: it is either the typed nonzero
# failure or the named cycle-complete line, and both say what happened and what to
# do next. On FAILED it exits non-zero so the failure is loud. A live cycle already
# present means re-arm attaches - do not start a second watcher.
#
# Every observed watcher cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, the cycle_outcome classification, and
# successor disposition. The separate
# state/.watch-triage.log remains exclusively the watcher's absorbed-wake debug
# log and is never written here.
#
# Arming is gated on the SESSION lock (state/.lock), which is a different lock
# from the watcher singleton (state/.watch.lock) used below: the session lock
# says which session controls this home's fleet, the singleton only says which
# process is the one watcher. A session that does not hold the session lock
# declines here, quietly and with exit 0, because a read-only session not arming
# is correct behavior rather than a supervision failure. Without that gate the
# singleton silently ABSORBS the rival: a non-owning session's arm takes the
# lock, the owning session's arm merely attaches to it, and supervision ends up
# in the session that is not responsible for it while everything reports fine.
# This is the one place the gate lives, so every harness inherits it.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${FM_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${FM_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
case "$CYCLE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) CYCLE_LOG_MAX_BYTES=262144 ;; esac
case "$CYCLE_LOG_KEEP_LINES" in ''|*[!0-9]*|0) CYCLE_LOG_KEEP_LINES=1000 ;; esac

# The lifecycle ledger is diagnostic evidence, not a supervision dependency.
# Writes are bounded and best-effort so an observability failure cannot stall an
# otherwise healthy watcher cycle.
cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

lock_snapshot() {
  local pid identity
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  printf 'pid:%s|identity:%s' "$(cycle_clean_field "${pid:-none}")" "$(cycle_clean_field "${identity:-none}")"
}

cycle_active=0
cycle_watcher_pid=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'
# Empty until a cycle registers one. Never pre-seeded with 0: a home that has
# produced wakes before reads a nonzero counter, so a 0 default would "differ"
# from it and report a benign outcome for a cycle that was never registered at
# all. An unregistered cycle can prove nothing, and the whole point of this
# classification is that only proof buys silence.
cycle_wake_seq_before=

cycle_begin() {
  cycle_watcher_pid=$1
  cycle_origin=$2
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_wake_seq_before=$(fm_wake_seq)
  cycle_active=1
}

# What this cycle did, as opposed to merely that it ended. Every cycle ends with
# no watcher running and the lock released, so "no watcher is running now" is
# true of a perfectly healthy close and of a dead one alike and separates
# nothing. These two observables do:
#
#   wake-delivered  the durable wake counter advanced during this cycle, so the
#                   watcher appended a real wake and exited on it. The wake is in
#                   state/.wake-queue for whoever drains it, and the session that
#                   OWNS that watcher gets the reason line on its own arm's exit.
#                   Nothing is wrong and nothing is lost - this arm was simply
#                   following someone else's completed cycle.
#   lapsed          no wake, and the beacon is stale past GRACE. Only the watcher
#                   touches that beacon, so this is supervision that stopped
#                   beating without being replaced: the fleet is unsupervised.
#   no-wake         no wake, but the beacon is still inside GRACE. Supervision was
#                   alive until this close and produced nothing, e.g. a watcher
#                   killed mid-cycle or a duplicate that stood down. No watcher is
#                   running now either, so it still needs a re-arm - it just is
#                   not the silent multi-minute lapse the case above is.
#
# One function so the ledger record and the reported line can never disagree.
# The wake-delivered arm requires a registered snapshot to compare against, so
# the quiet outcome is the only one that can never be reached by default. Every
# way of failing to know lands on a reported failure instead.
cycle_outcome() {
  if [ -n "$cycle_wake_seq_before" ] && [ "$(fm_wake_seq)" != "$cycle_wake_seq_before" ]; then
    printf 'wake-delivered'
    return
  fi
  if [ "$(fm_path_age "$BEAT")" -ge "$GRACE" ]; then
    printf 'lapsed'
    return
  fi
  printf 'no-wake'
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
  cycle_lock_before=$(lock_snapshot)
}

cycle_signal_name() {
  local rc=$1 signal_number
  case "$rc" in
    ''|*[!0-9]*) printf 'unknown'; return ;;
  esac
  [ "$rc" -gt 128 ] || { printf 'none'; return; }
  signal_number=$((rc - 128))
  kill -l "$signal_number" 2>/dev/null || printf '%s' "$signal_number"
}

cycle_log_append() {
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after outcome size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)
  outcome=$(cycle_outcome)

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\toutcome=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_watcher_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$ended_at" \
    "$(cycle_clean_field "$exit_code")" \
    "$(cycle_clean_field "$signal")" \
    "$(cycle_clean_field "$reason")" \
    "$beacon_age" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$lock_after")" \
    "$outcome" \
    "$(cycle_clean_field "$successor")" >> "$CYCLE_LOG" 2>/dev/null || true

  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ]; then
        tmp="$CYCLE_LOG.tmp.$ARM_PID"
        raw="$tmp.raw"
        tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
          | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its watcher, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-} i tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$CYCLE_LOG.link.$ARM_PID"
  awk -v target="arm_pid=$predecessor" -v replacement="successor=$(cycle_clean_field "$successor")" '
    {
      lines[NR] = $0
      count = split($0, fields, "\t")
      if (fields[1] == target) {
        for (i = 1; i <= count; i += 1) {
          if (fields[i] == "successor=none") last = NR
        }
      }
    }
    END {
      for (i = 1; i <= NR; i += 1) {
        if (i == last) sub(/\tsuccessor=none$/, "\t" replacement, lines[i])
        print lines[i]
      }
    }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$CYCLE_LOG_LOCK"
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

# Give a successor the same bounded confirmation window used for a fresh child.
# Adapter-owned continuations normally win immediately, but the bound avoids a
# false failure when process-close delivery and lock publication cross briefly.
wait_for_healthy_successor() {
  local deadline
  # date(1) exposes whole seconds. Add one rounding second so a timeout of one
  # second cannot collapse to a few milliseconds when called near a boundary.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  while :; do
    healthy_watcher && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# Close a cycle this arm did not get a wake reason from. Three different things
# reach here and only one of them is a supervision problem, so they must not
# share one line: the first covered both a benign several-times-an-hour close and
# a fleet that had been unsupervised for 27 minutes, and a message that means
# both means neither.
report_cycle_end() {
  local age
  age=$(fm_path_age "$BEAT")
  case "$(cycle_outcome)" in
    wake-delivered)
      # Not a failure and not a no-op: the cycle did its job. The reason line
      # went to the arm that owns this watcher, and the wake itself is durable,
      # so this arm's only remaining duty is to say the cycle is over.
      echo "watcher: cycle-complete - the watcher this arm followed delivered a wake and exited (beacon ${age}s); drain state/.wake-queue and re-arm"
      return 0
      ;;
    lapsed)
      # fm_path_age answers a missing path with a 999999 sentinel, which is a
      # real answer to "is this past the grace" and a nonsense answer to "how
      # old is it". Never print the sentinel as an age: the number ends up in a
      # supervision report, and an 11-day beacon in a home minutes old reads as
      # a broken clock rather than the missing beacon it is.
      if [ -e "$BEAT" ]; then
        echo "watcher: FAILED - supervision LAPSED: no live watcher and the beacon has not moved for ${age}s, past the ${GRACE}s grace - the fleet is unsupervised; re-arm with --restart"
      else
        echo "watcher: FAILED - supervision LAPSED: no live watcher and no liveness beacon at all - the fleet is unsupervised; re-arm with --restart"
      fi
      return 1
      ;;
  esac
  echo "watcher: FAILED - cycle ended without an actionable reason - no wake was produced and no successor took over, though the beacon is only ${age}s old (grace ${GRACE}s), so supervision was alive until this close; re-arm"
  return 1
}

# Stay alive across identity-matched healthy holders. If one cycle ends, attach
# to a verified successor. With no successor, fail loudly instead of returning a
# clean empty completion that an adapter could mistake for a no-op.
attach_and_wait() {
  local attached_pid=$1
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        cycle_log_append unknown unknown lock-replaced "attached:$HEALTHY_PID"
        attached_pid=$HEALTHY_PID
        report_attached
        cycle_begin "$attached_pid" attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      report_attached
      cycle_begin "$attached_pid" attached
      continue
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    report_cycle_end
    return $?
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_attached_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_attached_signal HUP 129' HUP
trap 'handle_attached_signal TERM 143' TERM
trap 'handle_attached_signal INT 130' INT

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_reason_type() {
  local out=$1 line
  line=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$line" in
    signal:*) printf 'actionable-signal' ;;
    stale:*) printf 'actionable-stale' ;;
    check:*) printf 'actionable-check' ;;
    heartbeat*) printf 'actionable-heartbeat' ;;
    *) printf 'none' ;;
  esac
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

# Session-lock gate, before --restart can stop anything and before any attach:
# a non-owning session must not arm, must not stop this home's watcher, and must
# not attach to the owner's cycle.
# A dead, absent, unreadable, or malformed session lock is NOT a refusal. No
# other session is being displaced there, and refusing would leave a home whose
# session start never ran (or whose lock was lost) permanently unsupervised,
# which is a worse failure than the one this gate exists to stop. It is
# announced rather than silently allowed, and names the command that claims the
# lock.
case "$(fm_session_lock_ownership "$STATE")" in
  owned) ;;
  other)
    echo "watcher: read-only - another firstmate session holds this home's session lock; not arming"
    exit 0
    ;;
  *)
    echo "watcher: no live session holds this home's session lock - arming anyway; run bin/fm-session-start.sh to claim it"
    ;;
esac

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  report_attached
  cycle_begin "$HEALTHY_PID" attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  cycle_log_append "$rc" "$signal" arm-interrupted none
  cleanup_child
  exit "$rc"
}

trap 'handle_arm_signal HUP 129' HUP
trap 'handle_arm_signal TERM 143' TERM
trap 'handle_arm_signal INT 130' INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
"$WATCH" >"$child_out" &
child=$!
cycle_begin "$child" started
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status
  signal=$(cycle_signal_name "$rc")
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$HEALTHY_PID"
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
      report_attached
      cycle_begin "$HEALTHY_PID" attached
      attach_and_wait "$HEALTHY_PID"
      return $?
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    report_cycle_end
    return $?
  fi

  reason_type="nonzero-exit"
  [ "$signal" = none ] || reason_type="signal-exit"
  cycle_log_append "$rc" "$signal" "$reason_type" none
  print_watch_output "$child_out"
  if ! grep -q '^watcher: FAILED' "$child_out" 2>/dev/null; then
    echo "watcher: FAILED - watcher cycle exited $rc without an actionable reason"
  fi
  rm -f "$child_out" 2>/dev/null || true
  child=
  child_out=
  status=$rc
  [ "$status" -gt 0 ] || status=1
  return "$status"
}

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cycle_refresh_lock_before
      cycle_mark_predecessor_successor "started:$child"
      echo "watcher: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      owned_child_finished "$rc"
      exit $?
    fi
    # Another watcher won the singleton; our child stood down.
    wait "$child"
    rc=$?
    owned_child_finished "$rc"
    exit $?
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    owned_child_finished "$rc"
    exit $?
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
print_watch_output "$child_out"
cleanup_child
wait "$child" 2>/dev/null
rc=$?
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "watcher: FAILED - no live watcher with a fresh beacon"
exit 1
