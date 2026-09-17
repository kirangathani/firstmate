# shellcheck shell=bash
# Single owner of the DORMANT-ARM POOL: its target size, its floor, the
# membership records, and the "refill or exit" decision.
# Usage: . bin/fm-arm-pool-lib.sh   (AFTER bin/fm-wake-lib.sh)
#
# The pool is what keeps firstmate's ear open without firstmate spending a model
# call on it. At session start the model issues FM_ARM_POOL_TARGET dormant arms
# as background tasks in one reply. Each one waits for the watcher singleton to
# be free, takes it, and becomes the watcher; the rest stay asleep. When the
# holder fires it exits and wakes the model, and the next dormant member has the
# lock within a fraction of a second with NO model call in between. The model's
# only remaining watcher duty is a refill, and that happens at turn end (the
# turn-end guard's pool-below-floor block) or as a side effect of an ordinary
# background send or ack, never on the captain's critical path.
#
# Three callers make the same "am I needed in the pool?" decision - the dormant
# mode of bin/fm-watch-arm.sh, bin/fm-send.sh, and bin/fm-ack.sh - so the count,
# the target, and the floor are defined here once and nowhere else. Two copies of
# a floor drift the moment one is edited, and a pool that believes it is full
# when it is empty is a fleet nobody is watching.
#
# Pid liveness, pid identity, and $STATE come from bin/fm-wake-lib.sh and are
# deliberately not redefined here.

# Six is the captain's chosen pool size and two is his chosen floor
# (2026-09-16 rulings 6 and 8). A member is cheap - an idle shell polling a
# symlink - so the size is about how many wakes one model refill covers, not
# about machine cost.
FM_ARM_POOL_TARGET=${FM_ARM_POOL_TARGET:-6}
FM_ARM_POOL_FLOOR=${FM_ARM_POOL_FLOOR:-2}
FM_ARM_POOL_JOINED=${FM_ARM_POOL_JOINED:-}
# The record separator, held as a value so the splitting below reads as an
# ordinary expansion rather than an escape a future edit can mangle.
fm_arm_pool_tab=$(printf '\t')

# Resolved per call rather than at source time: bin/fm-turnend-guard.sh and
# bin/fm-statusline.sh set $STATE themselves, and sourcing order between this
# library and that assignment is not something a caller should have to know.
fm_arm_pool_dir() {
  printf '%s\n' "${FM_ARM_POOL_DIR:-${STATE:-${FM_HOME:-.}/state}/.arm-pool}"
}

# Which session a member belongs to. A pool member is a background task of one
# firstmate session, and a member left over from a session that has ended is not
# an ear this session has: counting it would let the guard pass a turn on a pool
# of ghosts. The session lock's pid plus its start ticks is the same identity
# bin/fm-session-lock-lib.sh already resolves ownership with.
# An absent or dead session lock yields an empty string, and every live member
# then counts: a home whose session lock was never claimed still arms (see the
# session-lock gate in bin/fm-watch-arm.sh), so its arms are real ears.
fm_arm_pool_session() {
  if fm_session_lock_read "${STATE:-${FM_HOME:-.}/state}"; then
    printf '%s:%s\n' "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_TICKS"
  else
    printf '\n'
  fi
}

# A member's anti-recycling identity: the kernel's own start time for the pid, in
# clock ticks, and nothing else.
#
# Deliberately NOT fm_pid_identity, whose string carries the process's COMMAND
# LINE. A record here is one tab-separated line, and a command line may contain
# tabs and newlines - a `bash -c` with an embedded script does - so that identity
# splits a record across lines, the read of it comes back truncated, the member
# fails its own identity check, and the pool prunes a live ear. Ticks are digits,
# so they cannot break the format they are stored in.
# Empty on any host that does not offer them, which every caller already treats
# as "this host records no identity" rather than as a mismatch.
fm_arm_pool_identity() {
  local ticks
  ticks=$(fm_pid_start_ticks "$1" 2>/dev/null) || ticks=
  case "$ticks" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$ticks" ;;
  esac
}

fm_arm_pool_identity_matches() {
  local pid=$1 recorded=$2
  [ -n "$recorded" ] || return 0
  [ "$(fm_arm_pool_identity "$pid")" = "$recorded" ]
}

# Discard one membership record. Wrapped so the removal lives in exactly one
# place: every caller below reaches a dead or foreign record by a different
# route, and a stray removal of a LIVE member's record is how a full pool starts
# reporting itself empty.
fm_arm_pool_discard_record() {
  command rm -f -- "$1" 2>/dev/null || true
}

# Join the pool as $1 (a role word, recorded for the ledger only) and record the
# membership so the counters below can see it. The record is named by pid and
# carries the pid's own identity, so a recycled pid can never be mistaken for a
# live member that never cleaned up after itself.
fm_arm_pool_join() {
  local role=${1:-dormant} dir pid identity
  dir=$(fm_arm_pool_dir)
  mkdir -p "$dir" 2>/dev/null || return 1
  # Read BASHPID directly, NEVER through a command substitution. Inside `$( )`
  # bash sets BASHPID to the substitution subshell's own pid, so `$(fm_current_pid)`
  # names a process that is already gone by the time the assignment completes:
  # the member would then record a dead pid, prune itself on the very next count,
  # and the pool would read empty however many arms were really waiting.
  pid=${BASHPID:-$$}
  identity=$(fm_arm_pool_identity "$pid")
  printf '%s\t%s\t%s\t%s\n' "$identity" "$(fm_arm_pool_session)" "$(date +%s)" "$role" \
    > "$dir/$pid" 2>/dev/null || return 1
  FM_ARM_POOL_JOINED=$pid
  return 0
}

fm_arm_pool_leave() {
  local dir
  [ -n "${FM_ARM_POOL_JOINED:-}" ] || return 0
  dir=$(fm_arm_pool_dir)
  fm_arm_pool_discard_record "$dir/$FM_ARM_POOL_JOINED"
  FM_ARM_POOL_JOINED=
}

# How many live members this session has, pruning the records that no longer
# name one. Pruning needs no lock because it only ever discards a record whose
# pid is dead or whose identity no longer matches, and the process that would
# have rewritten it is by definition gone.
fm_arm_pool_count() {
  local dir session record pid record_line record_rest recorded_identity recorded_session count=0
  dir=$(fm_arm_pool_dir)
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  session=$(fm_arm_pool_session)
  for record in "$dir"/*; do
    [ -f "$record" ] || continue
    pid=$(basename "$record")
    case "$pid" in
      ''|*[!0-9]*) fm_arm_pool_discard_record "$record"; continue ;;
    esac
    # Split by parameter expansion, never by `read -r` with IFS set to a tab.
    # Bash treats tab as IFS WHITESPACE even when IFS names only a tab, so it
    # collapses runs of them and ignores leading ones: a record whose identity
    # field is legitimately empty - every host that offers no pid identity - would
    # be read with the session field shifted out of place, fail the identity check
    # against a value that is not an identity, and be pruned as dead. That
    # discards live members, which is the one failure this file must not have.
    record_line=$(head -n 1 "$record" 2>/dev/null || true)
    recorded_identity=${record_line%%"$fm_arm_pool_tab"*}
    record_rest=${record_line#*"$fm_arm_pool_tab"}
    recorded_session=${record_rest%%"$fm_arm_pool_tab"*}
    if ! fm_pid_alive "$pid"; then
      fm_arm_pool_discard_record "$record"
      continue
    fi
    # An identity was recorded on a host that offers one; where it was, it must
    # still match, or this pid is a different process wearing a dead member's
    # number.
    if ! fm_arm_pool_identity_matches "$pid" "$recorded_identity"; then
      fm_arm_pool_discard_record "$record"
      continue
    fi
    # A member of a session that has ended is not this session's ear. It is left
    # on disk rather than discarded: it is not ours to reap, and its own process
    # removes it when it exits.
    [ "$recorded_session" = "$session" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# True when the pool has room, i.e. when a command that has finished its real
# job should stay alive as a dormant arm instead of exiting. The one place this
# question is answered, so send, ack, and the dormant arm cannot disagree about
# what "full" means.
fm_arm_pool_has_room() {
  [ "$(fm_arm_pool_count)" -lt "$FM_ARM_POOL_TARGET" ]
}

fm_arm_pool_below_floor() {
  [ "$(fm_arm_pool_count)" -lt "$FM_ARM_POOL_FLOOR" ]
}
<<<<<<< HEAD

# The refill that costs no model call: a command that has finished its real job,
# and whose result the model does not need to act on, either exits now because the
# pool is full or stays alive as a dormant arm because it is not. Either way the
# model already paid for this call, so the ear is free.
#
# It REPLACES this process, so a caller must have finished everything it owes -
# printed its result, written its records - before calling. It must also have run
# as the harness's own background task, because the whole point is that this
# process becomes the thing that waits, and a foreground caller would simply never
# return. That is why it is opt-in per invocation rather than automatic: a command
# line that does not ask for it behaves exactly as it always has, so running one
# of these in the foreground by habit can never wedge a turn.
#
# A caller that has its own EXIT trap must settle it first (see bin/fm-send.sh):
# exec does not run EXIT traps.
fm_arm_pool_refill_or_exit() {
  local arm=$1
  fm_arm_pool_has_room || exit 0
  [ -x "$arm" ] || exit 0
  exec "$arm" --dormant
}
=======
>>>>>>> origin/main
