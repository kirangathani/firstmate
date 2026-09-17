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
# THE WATCHER IS DETACHED FROM THIS ARM'S PROCESS GROUP AND SESSION.
# The arm task is the harness's, and a harness kills it: Claude Code's low-memory
# protection stopped this task at least NINE times in the night of 2026-09-07/08
# ("was stopped because the system is running low on memory"), every time while
# MemAvailable still read 7-12 GB of a 20 GB box and only MemFree had dipped.
# Nothing in the arm uses memory; the dips came from other work on the box, so the
# arm cannot avoid being picked. What it CAN avoid is taking supervision down with
# it. The watcher used to be an ordinary background child in the arm's process
# group, so a group kill of the task killed the watcher too, and every one of
# those nine kills cost a full turn to notice and left the fleet unsupervised for
# minutes. It is now started through setsid(1), in its own session and process
# group, so a group signal aimed at the arm task does not reach it.
# The arm still FOLLOWS it exactly as before: setsid does not fork when the child
# is not already a process-group leader (job control is switched off below so that
# is guaranteed), so the watcher remains this arm's direct child, `wait` still
# returns its exit, and the arm's own exit is still the harness's wake signal.
# Once a fresh watcher is CONFIRMED, TERM and INT stop killing it, for the same
# reason: an arm dying must not take a healthy watcher with it. A killed arm
# therefore means "re-run the arm to re-attach", not "the watcher is gone", and
# the next arm reports `watcher: attached ...` through the ordinary singleton path.
# Two cases deliberately still reap: an UNCONFIRMED child, because a watcher that
# never proved itself is not supervision worth preserving and would only contend
# for the singleton with the next arm's child; and HUP on this arm's own child,
# because HUP means the session that owned the arm is gone rather than that the
# task was stopped. See handle_arm_signal for the ledger evidence behind that
# split - every catchable interrupt this home has ever recorded is TERM.
# A watcher that outlives every arm is still bounded by its own one-shot cycle: it
# exits on the next actionable wake (a heartbeat at the latest), and a beacon that
# lapses without one is what fm-guard.sh alarms on.
#
# Every observed watcher cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, the cycle_outcome classification, the
# pool depth at the handover, and successor disposition. The separate
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
# --dormant: join the dormant-arm pool and wait for a turn instead of arming at
# once. bin/fm-arm-pool-lib.sh owns the pool's size, floor, and membership; this
# flag owns only the waiting. Six of these are issued as six background tasks in
# one reply at session start: one wins the singleton and becomes the watcher, the
# rest sleep on the lock. When the holder fires and exits - which is what wakes
# the model - the next member has the lock within a fraction of a second, with no
# model call in between. That is the whole point: supervision continues without
# firstmate spending a turn on it.
# A dormant arm never becomes a follower. The two endings that are not its own
# wake, finding the lock already held and losing the singleton race, both send it
# back to sleep, so the pool stays one watcher plus waiters. Every FAILED ending
# still prints and exits, because a member that cannot arm when its turn comes is
# exactly what has to be visible, and the turn-end guard's floor then refills it.
#
# EXACTLY ONE NOTIFICATION PER WAKE. A dormant arm runs as a Monitor, and a
# Monitor turns every line it prints into a notification the model has to read,
# so what a member prints IS what a wake costs. Measured in the captain's home
# on 2026-09-17, one crewmate status append cost five: the holder's wake line,
# the same records again from its drain at exit, the successor's
# `watcher: started ...`, an ordinary attach-follow arm still printing
# `watcher: attached ...` down the successor chain, and the harness's own
# stream-end notice for the finished Monitor.
# So a member prints exactly one line, and only on its own wake:
#   dormant arm <S>: watcher exited, firstmate woken, watcher replenished from the pool, <N> dormant watchers lurking - <the crewmate's words>
# S is this member's own pool slot, the same number the Monitor running it is
# labelled with (`--dormant <S>`; bin/fm-arm-pool-lib.sh owns the numbering), and
# N is the ears still asleep after the handover (pool_lurking_count). The
# successor is confirmed before the line claims one. Handover lines go to
# state/.watch-arm.log instead of stdout (announce/arm_log below), and the drain
# at exit still runs but prints nothing, because every record it holds is the
# same payload already on that line (report_pool_wake).
# FAILED endings are never silenced. Neither is the harness's stream-end notice,
# which is emitted by the harness for every finished Monitor and cannot be
# suppressed from here at all - one per wake is the floor this script can reach.
# A PLAIN arm keeps every line it ever printed, and must not be armed alongside a
# live pool: it follows the successor chain and announces every handover, which
# is notification (4) above. See docs/supervision-protocols/claude.md.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u
# Job control OFF, deliberately and explicitly. With it on, bash puts each
# background job in its own process group, which makes the watcher a process-group
# leader, which makes setsid(1) fork: `$!` would then be the short-lived setsid
# process rather than the watcher, `wait` would return immediately, and a correct
# fresh start would be misreported. Non-interactive bash already defaults to this,
# but an exported SHELLOPTS carrying `monitor` would otherwise turn it back on.
set +m

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-arm-pool-lib.sh
. "$SCRIPT_DIR/fm-arm-pool-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
# Detach primitive. Absent on macOS, where the arm keeps its pre-detach behaviour
# rather than failing to arm at all; the harness memory-kill this defends against
# is a Linux observation.
SETSID=$(command -v setsid 2>/dev/null || true)
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
# How often a DORMANT arm looks to see whether the watcher singleton has been
# released. The captain's standing requirement is that everything between the
# watcher firing and the model reading takes under one second, and this poll is
# the whole of the handover gap, so it is set well inside that budget rather
# than at the one-second mark it has to beat.
DORMANT_POLL=${FM_ARM_DORMANT_POLL:-0.25}
# Most of those looks are a single shell test on the lock path and fork nothing:
# five idle members polling four times a second would otherwise cost about a
# hundred process spawns a second to learn nothing. The full health check - which
# is what also catches a lock left behind by a watcher that died without
# releasing it - runs every DORMANT_DEEP_EVERY polls instead.
DORMANT_DEEP_EVERY=${FM_ARM_DORMANT_DEEP_EVERY:-16}
# Where an arm's own announcements go when they are not worth a notification.
# bin/fm-watch-arm.sh is run as a Monitor, and a Monitor turns every printed line
# into a notification the model must read, so for a POOL member the only line
# worth that cost is the wake it was waiting for. A start and a handover are
# facts to look up afterwards, not events to be told about, so they land here.
ARM_LOG="$STATE/.watch-arm.log"
ARM_LOG_MAX_BYTES=${FM_WATCH_ARM_LOG_MAX_BYTES:-131072}
ARM_LOG_KEEP_LINES=${FM_WATCH_ARM_LOG_KEEP_LINES:-500}
case "$ARM_LOG_MAX_BYTES" in ''|*[!0-9]*|0) ARM_LOG_MAX_BYTES=131072 ;; esac
case "$ARM_LOG_KEEP_LINES" in ''|*[!0-9]*|0) ARM_LOG_KEEP_LINES=500 ;; esac
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${FM_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${FM_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
# Set from the flags below. Declared here because the reporting helpers branch on
# it and are defined long before the flag parse reaches them.
dormant=0
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

# Register a cycle so an interrupt from here on is recorded. ALWAYS call this
# BEFORE report_attached announces the cycle, never after. cycle_log_append is a
# no-op while cycle_active is 0, so an arm that announced an attach it had not yet
# registered would exit correctly on a signal and record NOTHING - the one hole in
# the one-record-per-observed-cycle contract in docs/watcher-continuity.md. The
# announcement is also the only observable an attach publishes, so anything acting
# on it (an adapter, a test) necessarily acts inside that window. Verified by
# widening the gap to two seconds in a scratch copy: announce-then-register lost
# the record on every run, register-then-announce kept it on every run.
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
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after outcome pool size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)
  outcome=$(cycle_outcome)
  # Pool depth AT THE HANDOVER, which is the one moment it answers the captain's
  # "let us see what it looks like": how many ears were still asleep when this
  # cycle closed, and therefore whether the next wake had a taker waiting or fell
  # to the turn-end refill. Counted after the outcome above so a failure to count
  # can never change how the cycle itself is classified.
  pool=$(fm_arm_pool_count 2>/dev/null || printf 'unknown')

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  # successor= stays LAST: cycle_mark_predecessor_successor rewrites it with an
  # end-anchored substitution, so a field appended after it would make that
  # rewrite silently miss every record.
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\toutcome=%s\tpool=%s\tsuccessor=%s\n' \
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
    "$(cycle_clean_field "$pool")" \
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

# Append one arm announcement to the bounded arm log. Best-effort in both
# directions: a logging hiccup never affects the arm, and nothing reads this log
# to make a supervision decision - it exists so a silenced line is still there to
# look up.
arm_log() {
  local sz
  printf '[%s] pid=%s slot=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$ARM_PID" "${FM_ARM_POOL_SLOT:-none}" "$1" >> "$ARM_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$ARM_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$ARM_LOG_MAX_BYTES" ]; then
    tail -n "$ARM_LOG_KEEP_LINES" "$ARM_LOG" > "$ARM_LOG.tmp" 2>/dev/null && mv -f "$ARM_LOG.tmp" "$ARM_LOG" 2>/dev/null
    rm -f "$ARM_LOG.tmp" 2>/dev/null || true
  fi
}

# A HANDOVER announcement - this arm took the singleton, or attached to a live
# holder. A pool member says it to the log only: with six members, one crewmate
# status append used to put the successor's `watcher: started ...` in front of
# the captain's supervisor alongside the wake itself, and a member taking its
# turn is the pool working exactly as designed rather than news. A plain arm
# still prints it, because it has no pool behind it and that line is the only
# proof an operator gets that a cycle exists.
# FAILED lines are never routed here. A member that cannot arm when its turn
# comes is precisely what has to be visible.
announce() {
  if [ "$dormant" -eq 1 ]; then
    arm_log "$1"
  else
    echo "$1"
  fi
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  announce "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

# The members of this session's pool OTHER than this arm. fm_arm_pool_count
# counts every live one, and this arm is still among them: its record survives
# until its EXIT trap fires a moment from now.
pool_others_count() {
  local n
  n=$(fm_arm_pool_count 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$(( n - 1 ))
  [ "$n" -ge 0 ] || n=0
  printf '%s' "$n"
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
  local age note lapse fresh
  # fm_path_age answers a MISSING path with a 999999 sentinel. That is a real
  # answer to "is this past the grace" and a nonsense answer to "how old is it",
  # so both phrasings are built here, once, and no branch below is free to print
  # the sentinel as an age. An 11-day-old beacon in a home minutes old reads as a
  # broken clock rather than the missing beacon it is, and a supervision report
  # nobody believes is as useless as one that never fires.
  if [ -e "$BEAT" ]; then
    age=$(fm_path_age "$BEAT")
    note="beacon ${age}s"
    lapse="the beacon has not moved for ${age}s, past the ${GRACE}s grace"
    fresh="the beacon moved ${age}s ago, inside the ${GRACE}s grace"
  else
    note="no beacon"
    lapse="no liveness beacon at all"
    fresh="there is no beacon to read"
  fi
  case "$(cycle_outcome)" in
    wake-delivered)
      # Not a failure and not a no-op: the cycle did its job. The reason line
      # went to the arm that owns this watcher, and the wake itself is durable,
      # so this arm's only remaining duty is to say the cycle is over.
      echo "watcher: cycle-complete - the watcher this arm followed delivered a wake and exited (${note}); drain state/.wake-queue and re-arm"
      return 0
      ;;
    lapsed)
      echo "watcher: FAILED - supervision LAPSED: no live watcher and ${lapse} - the fleet is unsupervised; re-arm with --restart"
      return 1
      ;;
  esac
  echo "watcher: FAILED - cycle ended without an actionable reason - no wake was produced and no successor took over, though ${fresh}, so supervision was alive until this close; re-arm"
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
        cycle_begin "$attached_pid" attached
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      cycle_begin "$attached_pid" attached
      report_attached
      continue
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    report_cycle_end
    return $?
  done
}

# An arm that is FOLLOWING a verified watcher - one it attached to, or its own
# once that watcher is confirmed - records the interrupt and leaves the watcher
# running. That is the whole point of the detach: the arm is the harness's task
# and the harness kills it, so an arm dying must not take supervision with it.
# Only the arm's own temp output goes, because nothing reads it once this arm is
# gone; the wake itself is durable in state/.wake-queue and the next arm attaches
# and reports that cycle. The attach path never allocates one, hence the default.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_following_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  if [ -n "${child_out:-}" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
  exit "$rc"
}

# The ATTACH posture: this arm did not start the watcher it is following, so it
# reaps nothing on any signal, HUP included. Unchanged from before the detach.
attach_signal_traps() {
  trap 'handle_following_signal HUP 129' HUP
  trap 'handle_following_signal TERM 143' TERM
  trap 'handle_following_signal INT 130' INT
}

attach_signal_traps

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

# Drain the durable wake queue here, on the way out, so the model is never asked
# to decide to drain. It always drains, so the decision was never a decision -
# just a model call, about five seconds of it, spent on every single wake.
#
# bin/fm-wake-drain.sh is called rather than reimplemented: it owns the atomic
# move, the print-before-delete no-loss boundary, and the dedupe, and a second
# copy of that boundary is exactly the thing that must not exist twice.
#
# The rows are ALSO appended to a durable pending log before they are printed
# here. This arm's stdout is the harness's task output, and nothing guarantees
# the model ever reads it: the task can be stopped, the session can end, the
# notification can be missed. The queue file itself is gone by then - the drain
# deleted it, correctly - so without this the words would exist only in a buffer
# nobody is obliged to look at. bin/fm-wake-pending.sh owns that log and hands
# back anything a session never picked up.
# It is written BEFORE the print and never fails this arm: a wake that reaches
# the model but not the log is merely repeated later, while a wake that reaches
# neither is lost, so the ordering is the one that can only over-deliver.
drain_wake_queue_on_exit() {
  local rows records
  rows=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  # Only the wake RECORDS are kept for replay. The drain also prints annotations
  # and whatever the liveness assertion it ends with has to say, which are useful
  # to read once and meaningless to hand a later session as unread wakes. A record
  # is "<epoch>\t<seq>\t..." by construction (bin/fm-wake-lib.sh's fm_wake_append),
  # and nothing else the drain prints starts with two numeric tab-separated fields.
  records=$(printf '%s\n' "$rows" | grep -E '^[0-9]+	[0-9]+	' || true)
  if [ -n "$records" ]; then
    "$SCRIPT_DIR/fm-wake-pending.sh" --record <<EOF 2>/dev/null || true
$records
EOF
  fi
  printf '%s\n' "$rows"
}

# What the crewmate actually SAID, out of the watcher's own reason output. The
# reason's first line is the watcher's own classification - `signal: <paths>`, or
# a whole stale/check/heartbeat reason - and the indented lines under it are the
# crewmate's appended words. The words are what the captain reads, so they are
# preferred; a wake that carries none (a stale, a check, a heartbeat) falls back
# to the reason line, which is itself the thing to act on.
# Flattened to ONE line, because every line an arm prints is its own
# notification and the whole point of this report is that a wake costs exactly
# one of them.
wake_words() {
  local out=$1 words
  words=$(grep -E '^[[:space:]]+[^[:space:]]' "$out" 2>/dev/null || true)
  [ -n "$words" ] || words=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  printf '%s' "$words" | awk 'NF { sub(/^[[:space:]]+/, ""); if (out != "") out = out " | "; out = out $0 } END { printf "%s", out }'
}

# The ONE notification a pool member is worth: the wake it was waiting for, in
# the captain's own words for it (2026-09-17). One crewmate status append used
# to arrive as five notifications - this line, the same records again from the
# drain below, the successor's start, a stray attach-follow arm's line, and the
# harness's own stream-end notice - of which only this one said anything.
# The successor is CONFIRMED before the line claims it, so "replenished from the
# pool" is a fact this arm checked rather than a hope, and N is counted after
# that handover so it names the ears actually left asleep.
report_pool_wake() {
  local out=$1 words others
  # COUNTED, never waited for. A member takes the free lock within DORMANT_POLL
  # but then forks and confirms a watcher, which is seconds; the captain's budget
  # between the watcher firing and the model reading it is a fraction of one, so
  # an arm that stopped to watch that confirmation would spend the whole budget
  # proving what the pool's own membership already says.
  others=$(pool_others_count)
  # Named by its own slot, the same number the Monitor running it is labelled
  # with, so a wake in the captain's chat is traceable to the arm that produced
  # it instead of to one of six identical lines.
  printf 'dormant arm %s: ' "${FM_ARM_POOL_SLOT:-?}"
  if [ "$others" -ge 1 ]; then
    # One of those others becomes the watcher; the rest keep lurking.
    printf 'watcher exited, firstmate woken, watcher replenished from the pool, %s dormant watchers lurking' "$((others - 1))"
  else
    # Not the captain's line, deliberately: an empty pool means the next wake
    # has no taker waiting, and a line that says it was replenished would be the
    # one thing worse than a line nobody needed.
    printf 'watcher exited, firstmate woken, NO watcher left in the pool, 0 dormant watchers lurking - re-arm'
  fi
  words=$(wake_words "$out")
  [ -z "$words" ] || printf ' - %s' "$words"
  printf '\n'
  # The queue still drains - the records reach the durable pending log and the
  # queue file is emptied exactly as before - but its output is NOT printed. Every
  # record it holds carries the same payload already on the line above, so
  # printing it put the same event in front of the model a second time.
  drain_wake_queue_on_exit >/dev/null 2>&1 || true
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

# A DORMANT arm is an ordinary arm that waits its turn. It joins the pool, sleeps
# until the watcher singleton is genuinely free, and then runs the arm flow below
# completely unchanged. Everything that makes an arm safe - the session-lock
# gate, the singleton, the confirmation, the ledger - applies to it exactly as it
# always did; dormancy only decides WHEN the flow starts.
# It also decides what happens at the two endings that are not this arm's own
# wake: already-held and lost-the-race both send it back to sleep instead of
# attaching, so the pool keeps the shape the captain asked for - one member
# watching, the others waiting - rather than collapsing into a queue of followers
# that all die together when the holder fires.
mode=arm
# The slot number this member asks the pool for. The model labels each Monitor
# `dormant arm <N>` and passes the same N here, so the label on the task and the
# number in the wake line are one number rather than two guesses. Omitting it is
# still valid - bin/fm-send.sh --refill and bin/fm-ack.sh --refill become members
# without one - and the pool then hands out the lowest free number.
slot_request=
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --dormant)
    mode=arm
    dormant=1
    case "${2:-}" in
      '') ;;
      *[!0-9]*|0) echo "usage: $(basename "$0") [--dormant [<slot>]|--restart]" >&2; exit 2 ;;
      *) slot_request=$2 ;;
    esac
    ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--dormant [<slot>]|--restart]" >&2; exit 2 ;;
esac

# Leaving the pool is tied to the process ending rather than to any one exit
# path, because a member that dies without withdrawing its record is counted as
# an ear this session does not have, and the guard would then pass a turn on a
# pool that is smaller than it reads. `exec` deliberately does NOT run this: a
# re-entering dormant arm keeps its pid, so its record stays true across the
# re-entry and the pool never dips through it.
trap 'fm_arm_pool_leave' EXIT

# Wait until no healthy watcher holds the singleton. The cheap test is the whole
# point: it is a shell builtin on the lock path, so an idle member costs
# essentially nothing, and the expensive identity-and-beacon check runs only when
# the lock looks gone or on the periodic sweep that catches a lock left behind by
# a watcher that died holding it.
dormant_wait_for_free_lock() {
  local i=0
  while :; do
    if [ ! -e "$WATCH_LOCK" ] || [ "$((i % DORMANT_DEEP_EVERY))" -eq 0 ]; then
      healthy_watcher || return 0
    fi
    sleep "$DORMANT_POLL"
    i=$((i + 1))
  done
}

# Go back to sleep by starting this script over. Re-entry is an exec rather than
# a loop around the arm flow because the flow is a long straight line that sets
# traps, forks a child, and holds a temp file: unwinding all of that correctly on
# every path is exactly the kind of state a fresh process gets right for free.
# The pid does not change, so the pool membership and the ledger identities
# survive it.
dormant_reenter() {
  cycle_active=0
  trap - HUP TERM INT
  if [ -n "${child_out:-}" ]; then
    command rm -f -- "$child_out" 2>/dev/null || true
    child_out=
  fi
  exec "$0" --dormant "${FM_ARM_POOL_SLOT:-}"
}

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
  owned)
    # Converge the lock onto this session's OWN harness process. The gate has
    # just established that this session owns the home, so the only thing this
    # can change is WHICH process in this session's lineage the lock names, and
    # the only pid it can ever write is one found by walking up from here. It
    # cannot take a home from a rival: a live holder outside this ancestry still
    # refuses.
    #
    # For a lock that already names this session's harness it is a no-op refresh.
    # For a lock written before the finder learned to record the session's own
    # process - one that names an ANCESTOR, typically the interactive session a
    # background one was forked from, or the Claude Code daemon between them - it
    # is the migration, so every running home converges at its first arm after
    # this lands, with no operator step, and stops depending on a process Claude
    # Code restarts on every auto-update - the 2026-09-15 lock-loss incident.
    #
    # A failure is deliberately silent. Ownership is already intact by the
    # verdict above, so an unconvergeable home loses only the improvement; a
    # session whose harness process this library cannot recognise and that sets
    # no marker would otherwise print the finder's error on every single arm.
    FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || true
    ;;
  other)
    echo "watcher: read-only - another firstmate session holds this home's session lock; not arming"
    exit 0
    ;;
  *)
    echo "watcher: no live session holds this home's session lock - arming anyway; run bin/fm-session-start.sh to claim it"
    ;;
esac

# Joining AFTER the gate, never before: an arm a non-owning session issued has
# already declined above, and counting it would let that session's idle shells
# stand in for ears the owning session does not have.
if [ "$dormant" -eq 1 ]; then
  fm_arm_pool_join dormant "$slot_request" || true
  dormant_wait_for_free_lock
fi

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
  # A dormant arm only reaches this if another member took the lock in the
  # moment between its last look and this one. It is not a follower, so it goes
  # back to sleep rather than attaching.
  [ "$dormant" -eq 0 ] || dormant_reenter
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  cycle_begin "$HEALTHY_PID" attached
  report_attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
fi

# Start a watcher as a tracked but DETACHED child and confirm it before settling
# in. It stays our child for its whole life - we wait on it, and its eventual wake
# exit propagates out so the harness re-notifies firstmate - but it lives in its
# own session and process group, so a signal aimed at this arm task's group does
# not reach it. See the detach paragraph in the header for why that matters.
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

# Before confirmation the child is still reaped on an interrupt: a watcher that
# never proved itself live and fresh is not supervision worth preserving, and
# leaving it behind would only contend for the singleton with the next arm's child.
#
# HUP keeps reaping this arm's OWN child even after confirmation, and that split
# is measured rather than assumed. In the captain's live home the cycle ledger
# holds 778 records, 37 of them a catchable arm interrupt, and every single one is
# `signal=TERM` - including the five overnight kills on 2026-09-08 at 01:02, 01:32,
# 01:36, 01:46 and 01:58. `signal=HUP` has never been recorded once. So the
# harness kill this whole change exists to survive is TERM, and keeping HUP lethal
# costs the fix nothing.
# It also means something different. TERM says someone is stopping this task while
# the session lives on, so a re-arm will follow; HUP says the session that owned
# this arm is gone, and the watcher now sits in its own session where a real
# hangup can never reach it, so nothing would ever follow it. Reaping the child
# this arm started is the honest close there, and it is exactly what the arm did
# before the detach.
# If a harness kill ever arrives as HUP, this is the branch to revisit: the fix
# depends on it, and the ledger's `signal=` field is where that shows up.
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

# The FOLLOWING posture, entered once this arm's own child is confirmed. TERM and
# INT stop reaping it, because those are the harness stopping the task and the
# watcher must outlive that. HUP deliberately stays on handle_arm_signal above.
follow_own_confirmed_watcher() {
  trap 'handle_following_signal TERM 143' TERM
  trap 'handle_following_signal INT 130' INT
}

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
# stdio is fully off the harness task's pipe: stdout and stderr both land in the
# arm's own output file and stdin is closed. A surviving watcher writing to a pipe
# whose reader the harness has already killed would take SIGPIPE and die, which is
# exactly the death the detach exists to prevent.
if [ -n "$SETSID" ]; then
  "$SETSID" "$WATCH" >"$child_out" 2>&1 </dev/null &
else
  "$WATCH" >"$child_out" 2>&1 </dev/null &
fi
child=$!
cycle_begin "$child" started
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status
  signal=$(cycle_signal_name "$rc")
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    if [ "$dormant" -eq 1 ]; then
      report_pool_wake "$child_out"
    else
      # A plain arm keeps both, unchanged: it has no pool behind it, so there is
      # no successor to report and the raw drained records are the only copy its
      # operator gets. Arming one alongside a live pool is what the protocol
      # doc forbids, for exactly the duplication this branch preserves.
      print_watch_output "$child_out"
      drain_wake_queue_on_exit
    fi
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$HEALTHY_PID"
      # A dormant arm that lost the singleton race says nothing. Its child's
      # "watcher: already running pid N" is the CORRECT and expected outcome for
      # five arms out of six, and every line an arm prints is a notification the
      # model has to read: printing it would put five non-events in front of the
      # captain's supervisor on every single handover. The ledger still records
      # the cycle, so nothing is lost to anyone looking for it.
      [ "$dormant" -eq 0 ] && print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
      # A dormant arm that lost the singleton race has done nothing wrong and is
      # not out of the pool: another member is now the watcher, so this one
      # returns to waiting. Attaching instead would spend a member as a follower
      # of a cycle it does not own, and every follower ends when that cycle does.
      [ "$dormant" -eq 0 ] || dormant_reenter
      cycle_begin "$HEALTHY_PID" attached
      report_attached
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
      follow_own_confirmed_watcher
      announce "watcher: started pid=$child (beacon fresh)"
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
