#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

# --- timing discipline ------------------------------------------------------
#
# Every case here drives REAL forked processes, so every wait must be gated on an
# OBSERVABLE condition the code publishes - a line in the arm's output, the lock
# naming a pid, the beacon existing, a process being gone, a contender recording
# its attempt - never on "sleep a while and then assert". A fixed wall-clock
# budget racing a real process on a loaded box made this file the repo's biggest
# source of false red, and widening the budget only lengthens the fuse: it is the
# same bug with more rope. The rule is therefore structural, not numeric.
#
# Two consequences that must be preserved by anything added here:
#
#   * An exhausted ceiling means the condition GENUINELY never happened, so it is
#     always safe to report as a real failure. The ceiling is deliberately far
#     larger than any plausible startup so it cannot be reached by slowness alone.
#   * Where a case needs a PRECONDITION before the real assertion can mean
#     anything (a peer that is definitely healthy, a lock that is definitely still
#     held), the precondition is established and VERIFIED here, and failing to
#     establish it is reported as its own named test-setup failure. It never
#     silently falls through into the assertion, where it would read as the
#     production code misbehaving.
WAIT_TICKS=${FM_WATCHER_LOCK_WAIT_TICKS:-600}

# The arm's own confirmation budget (FM_ARM_CONFIRM_TIMEOUT). This is the one
# number a test cannot poll away, because it is an INPUT to the code under test
# rather than an observation this file makes: the arm is being told how long it
# may spend. So it is always passed explicitly rather than left to the default,
# in two deliberately different sizes, because the two things it bounds are not
# the same thing:
#
#   ARM_CONFIRM_ATTACH - used wherever this file has ALREADY verified that a
#     healthy peer holds the lock before the arm starts. The arm's very first
#     confirmation poll then succeeds no matter how loaded the box is, so this
#     value never bounds the attach at all; it bounds only the later "the
#     attached cycle ended with no successor" close, which those cases genuinely
#     assert. Small on purpose, so that assertion stays cheap. Verifying the peer
#     first is what removed the timing dependence here - not the number.
#   ARM_CONFIRM_START - the two cases where the arm must FORK a real watcher and
#     confirm it (process start, lock acquire, first beacon) have no peer to
#     verify, so this budget does bound real work and has to exceed it. Measured
#     fork-to-confirmed latency for that path on this codebase: ~0.75s idle,
#     ~1.4s at 3x CPU oversubscription, ~2.85s at 8x. The old value of 1 second
#     sat BELOW the median at even mild load, which is exactly why a correct
#     "started" kept being reported as "arm did not start before ...". 15s is
#     roughly five times the worst measured value.
#
# If either case ever fails again, widening these is the wrong move and will not
# work twice: check first that the case still verifies its precondition, because
# a budget that has to be raised is a sign the wait stopped being an observation.
ARM_CONFIRM_START=${FM_WATCHER_LOCK_ARM_CONFIRM_START:-15}
ARM_CONFIRM_ATTACH=${FM_WATCHER_LOCK_ARM_CONFIRM_ATTACH:-2}

# wait_for <predicate> [args...]: poll the predicate until it holds. Returns
# non-zero only when the ceiling is genuinely exhausted.
wait_for() {
  local i=0
  while [ "$i" -lt "$WAIT_TICKS" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

have_line() {  # <file> <fixed substring>
  grep -qF "$2" "$1" 2>/dev/null
}

have_line_any() {  # <fixed substring> <file>...
  local needle=$1
  shift
  grep -qhF "$needle" "$@" 2>/dev/null
}

arm_child_said() {  # <state> <fixed substring> - the owned child's temp output
  grep -qF "$2" "$1"/.watch-arm-output.* 2>/dev/null
}

lock_pid_is() {  # <lockdir> <pid>
  [ "$(cat "$1/pid" 2>/dev/null || true)" = "$2" ]
}

lock_pid_replaced() {  # <lockdir> <old pid> - a live successor took the lock
  local now
  now=$(cat "$1/pid" 2>/dev/null || true)
  [ -n "$now" ] && [ "$now" != "$2" ] && kill -0 "$now" 2>/dev/null
}

seed_watcher_ready() {  # <state> <pid> - holds the singleton AND has beaten once
  lock_pid_is "$1/.watch.lock" "$2" && [ -e "$1/.last-watcher-beat" ]
}

exactly_one_live() {  # <pid> <pid>
  local live=0
  is_live_non_zombie "$1" && live=$((live + 1))
  is_live_non_zombie "$2" && live=$((live + 1))
  [ "$live" -eq 1 ]
}

path_nonempty() {
  [ -s "$1" ]
}

pid_gone() {
  ! is_live_non_zombie "$1"
}

# Inner contender shared by the two lock-concurrency cases. The winner holds the
# lock until EVERY contender has recorded that it finished its attempt, then
# records that it held for the whole window. The previous "hold for one fixed
# second" let a contender scheduled more than a second late meet a lock whose
# winner had already exited - a dead-pid lock it may then legitimately reclaim,
# scoring a second "win" that is correct behavior wrongly reported as a race bug.
# Args: $1 lib, $2 lockdir, $3 wins file, $4 attempts file, $5 held-proof file,
#       $6 contender count, $7 poll ceiling.
# The single quotes are required: this body is handed to `bash -c` and its $N are
# that inner shell's positional arguments, so expanding them here would be wrong.
# shellcheck disable=SC2016
CONTENDER_BODY='
  . "$1"
  if fm_lock_try_acquire "$2"; then
    printf "%s\n" "${BASHPID:-$$}" >> "$3"
    printf "%s\n" attempt >> "$4"
    i=0
    while [ "$i" -lt "$7" ]; do
      if [ "$(grep -c . "$4" 2>/dev/null || printf 0)" -ge "$6" ]; then
        printf "%s\n" complete >> "$5"
        break
      fi
      sleep 0.1
      i=$((i + 1))
    done
  else
    printf "%s\n" attempt >> "$4"
  fi
'

# Shared post-conditions for those two cases: the contention window the assertion
# depends on must have actually existed before the win count means anything.
assert_contention_window() {  # <attempts file> <held-proof file> <count>
  local attempted
  attempted=$(awk 'NF { c++ } END { print c + 0 }' "$1")
  [ "$attempted" -eq "$3" ] \
    || fail "test setup: only $attempted of $3 contenders recorded a lock attempt"
  [ -s "$2" ] \
    || fail "test setup: the lock winner stopped holding the lock before every contender had attempted"
}


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  # Wait for the singleton to actually resolve, then read the live count for the
  # assertion. The old 5s budget could expire while both were still starting.
  wait_for exactly_one_live "$pid1" "$pid2" || true
  live=0
  is_live_non_zombie "$pid1" && live=$((live + 1))
  is_live_non_zombie "$pid2" && live=$((live + 1))
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  wait_for have_line_any 'watcher: already running pid ' "$out1" "$out2" || true
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Gate on the reclaim actually being published, not on a 5s budget elapsing.
  wait_for lock_pid_replaced "$state/.watch.lock" "$dead_pid" || true
  live=0
  is_live_non_zombie "$pid" && live=1
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mark_pr_check_migration_complete "$state"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'repair missing watcher supervision' "$err" >/dev/null || fail "guard banner missing the harness-aware fix command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, repair missing watcher supervision' "$err" >/dev/null || fail "guard did not order supervision repair after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker attempts held i pids pid wins contenders
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  attempts="$dir/attempts"
  held="$dir/held"
  contenders=40
  : > "$marker"
  : > "$attempts"
  : > "$held"
  pids=
  i=1
  while [ "$i" -le "$contenders" ]; do
    FM_STATE_OVERRIDE="$state" bash -c "$CONTENDER_BODY" \
      _ "$LIB" "$lockdir" "$marker" "$attempts" "$held" "$contenders" "$WAIT_TICKS" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  assert_contention_window "$attempts" "$held" "$contenders"
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker attempts held i pids pid wins contenders
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  attempts="$dir/attempts"
  held="$dir/held"
  contenders=40
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  : > "$attempts"
  : > "$held"
  pids=
  i=1
  while [ "$i" -le "$contenders" ]; do
    FM_STATE_OVERRIDE="$state" bash -c "$CONTENDER_BODY" \
      _ "$LIB" "$lockdir" "$marker" "$attempts" "$held" "$contenders" "$WAIT_TICKS" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  assert_contention_window "$attempts" "$held" "$contenders"
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file release holder out lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  release="$dir/release"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  # The holder keeps the steal mutex until this test says the acquire attempt has
  # run, instead of holding it for a fixed two seconds. Under load the attempt
  # could start after that window closed, and the stale lock was then reclaimed
  # legitimately - reported as "stolen while a live stealer held the mutex".
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    i=0
    while [ ! -e "$4" ] && [ "$i" -lt "$5" ]; do
      sleep 0.1
      i=$((i + 1))
    done
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" "$release" "$WAIT_TICKS" &
  holder=$!
  wait_for path_nonempty "$holder_file" || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  is_live_non_zombie "$holder" \
    || fail "test setup: the live steal mutex holder exited before the acquire attempt was observed"
  : > "$release"
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out attempt age
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  # The grace floor is two seconds of REAL time measured from the lock dir's
  # mtime, so the window can close before a slow fork even reaches the acquire.
  # That is a fixture that aged out, not a production defect, and it must never
  # be reported as one. Each attempt therefore reports the age the acquire
  # actually saw: an aged-out fixture is rebuilt and retried, a fresh fixture
  # that WAS stolen is the real failure, and only a genuinely exhausted retry
  # budget fails - as a named setup failure.
  attempt=0
  out=
  while [ "$attempt" -lt 20 ]; do
    rm -rf "$lockdir" "$lockdir.steal"
    mkdir "$lockdir"
    out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
      printf "rc=%s held=%s age=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(fm_path_age "$2")"
    ' _ "$LIB" "$lockdir")
    age=${out#*age=}
    age=${age%% *}
    case "$out" in
      *"rc=1"*) break ;;
    esac
    case "$age" in
      ''|*[!0-9]*) age=999999 ;;
    esac
    [ "$age" -ge 2 ] || break
    attempt=$((attempt + 1))
  done
  case "$out" in
    *"rc=1"*) ;;
    *)
      [ "$attempt" -lt 20 ] \
        || fail "test setup: the mid-acquire fixture aged past the 2s floor on every attempt (last: $out)"
      fail "empty mid-acquire lock was stolen with zero stale threshold: $out"
      ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    # Age the lock link past the mid-acquire floor. Where lutimes is available
    # this is instant; where it is not, wait for the age to be OBSERVABLY past
    # the floor rather than sleeping a fixed budget and hoping.
    if ! touch -h -t 200001010000 "$2" 2>/dev/null; then
      i=0
      while [ "$(fm_path_age "$2")" -lt 3 ] && [ "$i" -lt "$3" ]; do
        sleep 0.1
        i=$((i + 1))
      done
    fi
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir" "$WAIT_TICKS")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm forks the fresh watcher as a tracked child and waits on it, so
  # the lock now names that child, not the arm invocation. The property is the
  # same: the stale reused-pid lock is replaced by a genuinely live watcher, which
  # the arm confirms before reporting it. Wait for that confirmation, not just for
  # the lock pid to appear (identity and beacon land a beat later).
  wait_for have_line "$out" 'watcher: started pid=' || true
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$out" >/dev/null || fail "restart did not report the fresh watcher it confirmed"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_watch_restart_attaches_to_healthy_peer() {
  local dir state fakebin out peer identity armpid status ready
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  ready="$dir/peer-ready"
  mark_pr_check_migration_complete "$state"
  # The peer must ALREADY be TERM-resistant when --restart sends it a TERM,
  # otherwise the peer dies, the fresh child correctly reclaims a now-dead lock,
  # and the arm correctly reports "started" - a production behavior that this
  # case then reports as "restart did not attach to the verified healthy peer".
  # node installs the handler during startup, which on a loaded box can lose to
  # the arm. So the peer publishes readiness AFTER installing the handler and
  # this test waits for that observable state, making the precondition something
  # the test controls rather than a fork it hopes has finished.
  node -e 'process.on("SIGTERM", () => {}); require("fs").writeFileSync(process.argv[1], "ready"); setTimeout(() => {}, 300000)' "$ready" &
  peer=$!
  wait_for path_nonempty "$ready" \
    || fail "test setup: the TERM-resistant peer never confirmed its SIGTERM handler was installed"
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  # With the peer verified healthy before the arm starts, the arm's very first
  # confirmation poll attaches regardless of load, so ARM_CONFIRM_ATTACH bounds
  # only the successor-gap close asserted at the end of this case.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_ATTACH" "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  wait_for have_line "$out" "watcher: attached pid=$peer" || true
  grep -qF "watcher: attached pid=$peer" "$out" || fail "restart did not attach to the verified healthy peer: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "restart arm exited instead of following the healthy peer"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "restart arm did not fail after its attached peer ended without a successor (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$out" || fail "restart arm did not surface the attached cycle end"
  pass "watch restart attaches to a verified healthy peer and later surfaces a successor gap"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for lock_pid_is "$state/.watch.lock" "$pid" || true
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" "$WAIT_TICKS" || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_self_eviction_is_loud_without_successor() {
  local dir state fakebin armout armpid watcher_pid status
  dir=$(make_case arm-self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  # The arm forks and confirms a REAL watcher here, so it needs the start budget.
  # With the old one-second budget a loaded box made the arm give up before its
  # own healthy child was confirmed, and the case reported the arm as never
  # having started.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for have_line "$armout" 'watcher: started pid=' || true
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "arm did not start before self-eviction check"

  # A live but identity-mismatched replacement lock makes the owned watcher
  # self-evict normally. With no verified successor, the arm must turn that
  # otherwise clean empty close into the typed nonzero failure.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "self-evicted arm did not fail nonzero (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "self-evicted arm omitted the typed cycle-end failure"
  grep -q "reason=unexpected-clean-exit" "$state/.watch-cycle-exits.log" || fail "self-evicted cycle was not classified in the lifecycle ledger"
  pass "arm turns clean self-eviction without a successor into a typed failure"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  # Both halves of "seeded and healthy" - lock ownership AND a published beacon -
  # must hold before arming, or the arm would be asked to attach to something
  # this case has not yet made attachable.
  wait_for seed_watcher_ready "$state" "$wpid" || true
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  [ -e "$state/.last-watcher-beat" ] \
    || fail "test setup: the seed watcher took the lock but never published a beacon to attach to"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock. The seed is verified
  # healthy above, so the arm attaches on its first poll and ARM_CONFIRM_ATTACH
  # bounds only the successor-gap close asserted below.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_ATTACH" "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for have_line "$armout" "watcher: attached pid=$wpid" || true
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies without a successor, the attached arm must fail loudly.
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after seed died (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a live fresh watcher and fails loudly when that cycle has no successor"
}

test_attached_arm_signal_is_recorded_in_cycle_ledger() {
  local dir state fakebin out armout wpid armpid status
  dir=$(make_case attached-arm-signal-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  wait_for seed_watcher_ready "$state" "$wpid" || true
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  [ -e "$state/.last-watcher-beat" ] \
    || fail "test setup: the seed watcher took the lock but never published a beacon to attach to"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_ATTACH" "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for have_line "$armout" "watcher: attached pid=$wpid" || true
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before signal"
  kill -TERM "$armpid" 2>/dev/null || fail "could not signal the attached arm"
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -eq 143 ] || fail "attached arm did not exit with TERM status (got $status)"
  grep -q "arm_pid=$armpid.*watcher_pid=$wpid.*origin=attached.*exit_code=143.*signal=TERM.*reason=arm-interrupted" "$state/.watch-cycle-exits.log" \
    || fail "attached arm signal was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "signaling an attached arm terminated the peer watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm signals record a classified lifecycle entry"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" "$WATCH_ARM" > "$armout" &
    armpid=$!
    wait_for have_line "$armout" 'watcher: started pid=' || true
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    [ -z "$dead_pid" ] || [ "$lock_pid" != "$dead_pid" ] || fail "arm ($row) did not replace the dead-pid lock with a live watcher"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts+confirms a fresh watcher on a clean lock and self-heals a dead-pid lock (never healthy off a dead pid)"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for have_line "$armout" 'watcher: started pid=' || true
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  wait_for pid_gone "$lock_pid" || true
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register immediate-wake custom check"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate check wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer identity armpid status
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # This case deliberately makes the peer healthy LATE, so the arm has to still
  # be waiting when the beacon lands. The window it waits in is its own confirm
  # budget, counted from the fork - which means the budget has to cover the
  # child's real startup plus this handshake. At one second it did not, and the
  # arm gave up before the fixture could complete. It is driven explicitly here
  # and sized for a loaded box; the handshake itself is gated on observed output,
  # not on a sleep.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  # Synchronize on the owned child declining the live peer lock before making
  # the peer healthy, so the successor handshake is what is being exercised.
  wait_for arm_child_said "$state" "watcher: already running pid $peer" || true
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "arm child did not stand down behind the peer watcher"
  is_live_non_zombie "$armpid" \
    || fail "test setup: the arm gave up before the peer could be made healthy, so the handshake was never exercised"
  touch "$state/.last-watcher-beat"
  wait_for have_line "$armout" "watcher: attached pid=$peer" || true
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies without a successor, the attached arm must fail loudly.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after peer died (status $status): $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "peer-attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a peer watcher after child stands down and surfaces a missing successor"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  # Here the confirmation budget IS the thing under test: no watcher can ever be
  # confirmed, so the arm must spend the budget and then report FAILED. It is
  # driven explicitly and kept short, while the wait for the arm to return is the
  # usual generous observed-exit poll rather than a matching fixed budget.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED' "$armout" >/dev/null || fail "arm did not print a typed FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_cycle_exit_ledger_links_successor_and_stays_bounded() {
  local dir state fakebin armout check_file first_arm successor_arm successor_pid i size iteration
  local first_bytes steady_bytes cap keep_lines bounded_cycles records
  dir=$(make_case cycle-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/first-arm.out"
  check_file="$state/task.check.sh"
  mark_pr_check_migration_complete "$state"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'done: synthetic cycle\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register cycle-ledger check"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  first_arm=$!
  wait "$first_arm" || fail "first ledger cycle did not surface its actionable wake"
  grep -q "arm_pid=$first_arm.*reason=actionable-check.*successor=none" "$state/.watch-cycle-exits.log" \
    || fail "first ledger record omitted its actionable classification"

  rm -f "$check_file" "$state/task.check-trust"
  armout="$dir/successor-arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_PREDECESSOR_ARM_PID="$first_arm" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" "$WATCH_ARM" > "$armout" &
  successor_arm=$!
  wait_for have_line "$armout" 'watcher: started pid=' || true
  successor_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$successor_pid" "$armout" || fail "successor ledger cycle did not start"
  grep -q "arm_pid=$first_arm.*successor=started:$successor_pid" "$state/.watch-cycle-exits.log" \
    || fail "predecessor ledger record was not linked to its verified successor"
  kill -HUP "$successor_arm" 2>/dev/null || true
  wait "$successor_arm" 2>/dev/null || true

  # Cross a deliberately small cap. The cap is applied by the arm layer itself:
  # it keeps the last FM_WATCH_CYCLE_LOG_KEEP_LINES records, cuts that to
  # FM_WATCH_CYCLE_LOG_MAX_BYTES, and then drops the record the byte cut
  # truncated. Both properties have to stay observable, so the cap is DERIVED
  # from this run's own record sizes rather than hardcoded: record width carries
  # the absolute worktree path and live pid widths, so a fixed literal drifts
  # between checkouts and silently stops forcing a cut.
  #
  # Two records exist now: the linked actionable record and the successor's.
  # One more cycle makes three, and the cap is placed midway between "two
  # records fit" and "three records fit", so the trim keeps three lines, the
  # byte cut lands inside the oldest, and exactly two complete records survive.
  # That is the minimum work that leaves the assertion non-vacuous: fewer
  # surviving records and "only complete records survive" would prove nothing.
  first_bytes=$(sed -n '1p' "$state/.watch-cycle-exits.log" | wc -c | tr -d '[:space:]')
  steady_bytes=$(sed -n '2p' "$state/.watch-cycle-exits.log" | wc -c | tr -d '[:space:]')
  [ "${first_bytes:-0}" -gt 1 ] && [ "${steady_bytes:-0}" -gt 1 ] \
    || fail "could not measure ledger record widths to derive a cap ($first_bytes/$steady_bytes)"
  cap=$((first_bytes / 2 + steady_bytes * 2))
  keep_lines=3
  bounded_cycles=1
  iteration=0
  while [ "$iteration" -lt "$bounded_cycles" ]; do
    armout="$dir/bounded-$iteration.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_LOG_MAX_BYTES="$cap" FM_WATCH_CYCLE_LOG_KEEP_LINES="$keep_lines" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" "$WATCH_ARM" > "$armout" &
    successor_arm=$!
    wait_for have_line "$armout" 'watcher: started pid=' || true
    grep -qF 'watcher: started pid=' "$armout" || fail "bounded ledger cycle $iteration did not start"
    kill -HUP "$successor_arm" 2>/dev/null || true
    wait "$successor_arm" 2>/dev/null || true
    iteration=$((iteration + 1))
  done
  size=$(wc -c < "$state/.watch-cycle-exits.log" | tr -d '[:space:]')
  [ "$size" -le "$cap" ] || fail "cycle ledger exceeded its configured cap ($size bytes > $cap)"
  ! grep -v '^arm_pid=.*watcher_pid=.*started_at=.*ended_at=.*exit_code=.*signal=.*reason=.*beacon_age=.*lock_before=.*lock_after=.*successor=' "$state/.watch-cycle-exits.log" | grep . >/dev/null \
    || fail "bounded lifecycle ledger contains a partial or malformed record"
  # Anti-vacuity pins. The trim kept $keep_lines records and the byte cut
  # truncated the oldest of them, so exactly $keep_lines-1 COMPLETE records must
  # remain: any fewer and "only complete records survive" is asserted over a set
  # too small to mean anything, any more and the byte cut never truncated a
  # record so the exclusion path was never exercised at all.
  records=$(grep -c '^arm_pid=' "$state/.watch-cycle-exits.log" 2>/dev/null || true)
  [ "${records:-0}" -eq $((keep_lines - 1)) ] \
    || fail "expected exactly $((keep_lines - 1)) complete ledger records after trimming, got $records"
  ! grep -qE "^arm_pid=${first_arm}[[:space:]]" "$state/.watch-cycle-exits.log" \
    || fail "cap did not evict the oldest ledger record, so nothing was actually trimmed"
  pass "cycle-exit ledger links a verified successor and remains size-capped"
}

test_stopped_watcher_is_live_but_stale_then_exit_is_classified() {
  local dir state fakebin armout armpid watcher_pid status
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT="$ARM_CONFIRM_START" "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for have_line "$armout" 'watcher: started pid=' || true
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  kill -CONT "$watcher_pid" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$armpid" "$WAIT_TICKS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated stopped-watcher cycle did not surface nonzero (status $status)"
  grep -Eq 'reason=(nonzero-exit|signal-exit)' "$state/.watch-cycle-exits.log" \
    || fail "terminated watcher exit was not classified in the lifecycle ledger"
  pass "SIGSTOP distinguishes live PID from stale beacon and termination records the exit class"
}

test_pid_identity_is_locale_invariant() {
  # The watcher records its process identity under one locale; arm/guard/turn-end
  # re-read it under the machine's ambient locale. ps's lstart date format follows
  # LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR) would differ only
  # in the date portion and reject a genuinely live watcher. The pin lives in
  # fm_pid_identity_lstart, which on Linux is only reached when /proc/<pid>/stat is
  # unreadable - so the /proc reader is stubbed to fail here, exactly as in
  # test_pid_identity_falls_back_without_proc_stat, or fm_pid_identity would never
  # call ps and every sample would be the locale-independent proc form, making the
  # assertions vacuous. With the fallback forced, the output must be byte-identical
  # regardless of the caller's exported LC_ALL/LC_TIME. That invariant holds on any
  # host because the pin is internal, so this stays deterministic on CI even where
  # an alternate locale like ko_KR.UTF-8 is not installed (the equality then holds
  # trivially).
  local live baseline via_lc_all via_lc_time force_lstart
  # shellcheck disable=SC2016 # Inner-shell script body for 'bash -c'; $1/$2 must stay unexpanded here.
  force_lstart='
    . "$1"
    fm_pid_start_ticks() { return 1; }
    fm_pid_identity "$2"
  '
  sleep 300 &
  live=$!
  baseline=$(LC_ALL=C bash -c "$force_lstart" _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(LC_ALL=ko_KR.UTF-8 bash -c "$force_lstart" _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(LC_TIME=ko_KR.UTF-8 bash -c "unset LC_ALL; $force_lstart" _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  case "$baseline" in
    proc-starttime:*) fail "fm_pid_identity took the /proc path despite the stubbed reader, so the LC_ALL=C pin was never exercised" ;;
  esac
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

test_pid_identity_is_stable_across_repeated_reads() {
  # The WSL2 regression. ps computes lstart as boot time plus the process's start
  # ticks; WSL2 continually re-syncs its boot-time estimate against the Windows
  # host clock, so the SAME live pid yielded a DIFFERENT lstart string seconds
  # apart and every identity check rejected a healthy watcher as dead. The kernel
  # start-tick counter cannot move for a live process, so repeated reads of one
  # live pid must be byte-identical on every host.
  #
  # The sleep below is deliberately NOT a wait for anything and must not be
  # converted into one: elapsed wall-clock time between samples is the very thing
  # the drift regression needs, because the host's boot-time estimate is what
  # moves. Nothing here is gated on a budget - every sample is taken and then
  # compared - so load cannot turn this into a false failure.
  local live i seen count
  sleep 300 &
  live=$!
  seen="$TMP_ROOT/identity-samples"
  : > "$seen"
  for i in 1 2 3 4 5 6; do
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" >> "$seen" 2>/dev/null
    sleep 1
  done
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  count=$(sort -u "$seen" | wc -l | tr -d ' ')
  [ "$(wc -l < "$seen" | tr -d ' ')" -eq 6 ] || fail "fm_pid_identity did not produce an identity on every read"
  [ "$count" -eq 1 ] || fail "fm_pid_identity drifted for one live pid across 6 reads ($count distinct values: $(sort -u "$seen" | tr '\n' '|'))"
  pass "fm_pid_identity is stable across repeated reads of one live pid"
}

test_pid_identity_parses_odd_proc_stat_comm() {
  # /proc/<pid>/stat field 2 (comm) is parenthesized and may itself contain
  # spaces or parentheses, which shifts every positional field, so a naive
  # awk '{print $22}' reads the wrong number. These synthetic lines pin the
  # split-on-last-')' parse against exactly that. Each line carries fields 3..52
  # after the comm, with field 22 (the 20th of those) set to 4242.
  local tail_fields got comm
  tail_fields="S 1 1 1 0 -1 4194560 100 0 0 0 5 6 0 0 20 0 1 0 4242"
  tail_fields="$tail_fields 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
  for comm in 'sleep' 'we ird' 'pa)ren' 'od) d (one'; do
    got=$(bash -c '. "$1"; fm_pid_parse_start_ticks "$2"' _ "$LIB" "77 ($comm) $tail_fields") \
      || fail "fm_pid_parse_start_ticks failed on comm '$comm'"
    [ "$got" = 4242 ] || fail "fm_pid_parse_start_ticks read '$got' for comm '$comm', want 4242"
  done
  bash -c '. "$1"; fm_pid_parse_start_ticks "$2"' _ "$LIB" "77 (sleep) S 1 1" >/dev/null 2>&1 \
    && fail "fm_pid_parse_start_ticks accepted a truncated stat line"
  bash -c '. "$1"; fm_pid_parse_start_ticks "$2"' _ "$LIB" "77 sleep $tail_fields" >/dev/null 2>&1 \
    && fail "fm_pid_parse_start_ticks accepted a stat line with no comm parenthesis"
  bash -c '. "$1"; fm_pid_parse_start_ticks "$2"' _ "$LIB" "" >/dev/null 2>&1 \
    && fail "fm_pid_parse_start_ticks accepted an empty stat line"
  pass "fm_pid_parse_start_ticks handles comm containing spaces and parentheses"
}

test_pid_identity_parses_real_process_with_odd_comm() {
  # The synthetic parse above, against a genuine kernel-written stat line: comm is
  # the executable's basename, so a copy named 'a b)c' reproduces both hazards at
  # once. Skipped off Linux, where there is no /proc for the parse to run against.
  local dir odd live identity ticks
  if [ ! -r /proc/self/stat ]; then
    pass "real-process odd-comm parse skipped: host has no /proc/<pid>/stat"
    return
  fi
  dir=$(make_case odd-comm)
  odd="$dir/a b)c"
  cp "$(command -v sleep)" "$odd" || fail "could not stage an odd-comm executable"
  "$odd" 300 &
  live=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  ticks=$(bash -c '. "$1"; fm_pid_start_ticks "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$ticks" ] || fail "fm_pid_start_ticks read nothing for a process whose comm holds a space and a paren"
  case "$ticks" in ''|*[!0-9]*) fail "fm_pid_start_ticks returned a non-numeric value '$ticks'" ;; esac
  [ "$identity" = "proc-starttime:$ticks $odd 300" ] || fail "fm_pid_identity built '$identity', want 'proc-starttime:$ticks $odd 300'"
  pass "fm_pid_identity parses a real process whose comm holds a space and a paren"
}

test_pid_identity_falls_back_without_proc_stat() {
  # macOS has no /proc, so the lstart form stays the fallback there. Simulate an
  # unreadable /proc/<pid>/stat by making the reader fail, and require the result
  # to be the legacy form rather than an error.
  local live identity legacy
  sleep 300 &
  live=$!
  identity=$(bash -c '
    . "$1"
    fm_pid_start_ticks() { return 1; }
    fm_pid_identity "$2"
  ' _ "$LIB" "$live" 2>/dev/null)
  legacy=$(bash -c '. "$1"; fm_pid_identity_lstart "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$identity" ] || fail "fm_pid_identity produced nothing when /proc/<pid>/stat is unreadable"
  case "$identity" in
    proc-starttime:*) fail "fm_pid_identity used the /proc format when /proc/<pid>/stat is unreadable" ;;
  esac
  [ "$identity" = "$legacy" ] || fail "fallback identity '$identity' is not the lstart form '$legacy'"
  pass "fm_pid_identity falls back to the lstart form when /proc/<pid>/stat is unreadable"
}

test_pid_identity_matches_legacy_record() {
  # A lock written before the format change holds an lstart-format identity, so a
  # bare string equality would declare a genuinely live watcher dead exactly once.
  # fm_pid_identity_matches re-derives the legacy form and compares it exactly.
  # fm_pid_identity_lstart is stubbed so the assertion cannot itself be defeated by
  # the WSL2 clock drift this whole change exists to survive.
  local live legacy verdict
  legacy='Thu Jul 30 10:00:00 2026 sleep 300'
  sleep 300 &
  live=$!
  verdict=$(bash -c '
    . "$1"
    fm_test_stub_lstart=$3
    fm_pid_identity_lstart() { printf "%s\n" "$fm_test_stub_lstart"; }
    if fm_pid_identity_matches "$2" "$3"; then echo MATCH; else echo NOMATCH; fi
  ' _ "$LIB" "$live" "$legacy")
  [ "$verdict" = MATCH ] || fail "fm_pid_identity_matches rejected a live pid on a legacy-format record"
  verdict=$(bash -c '
    . "$1"
    fm_pid_identity_lstart() { printf "%s\n" "Thu Jul 30 09:00:00 2026 some other process"; }
    if fm_pid_identity_matches "$2" "$3"; then echo MATCH; else echo NOMATCH; fi
  ' _ "$LIB" "$live" "$legacy")
  [ "$verdict" = NOMATCH ] || fail "fm_pid_identity_matches accepted a legacy record that does not describe this pid"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "fm_pid_identity_matches accepts a live pid's legacy record and rejects a foreign one"
}

test_pid_identity_matches_rejects_dead_and_other_processes() {
  # The safety property: the drift fix must not make the check more permissive. A
  # dead pid, a pid now running a different process, and a same-command record
  # carrying a different start time must all still be rejected.
  local live other identity forged dead_pid
  sleep 300 &
  live=$!
  sleep 301 &
  other=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  [ -n "$identity" ] || fail "could not identify the live pid"
  bash -c '. "$1"; fm_pid_identity_matches "$2" "$3"' _ "$LIB" "$live" "$identity" \
    || fail "fm_pid_identity_matches rejected a pid against its own identity"
  bash -c '. "$1"; fm_pid_identity_matches "$2" "$3"' _ "$LIB" "$other" "$identity" \
    && fail "fm_pid_identity_matches accepted a different process at a recycled pid"
  # Same command, different start marker: the start time alone must reject it.
  case "$identity" in
    proc-starttime:*) forged="proc-starttime:1 ${identity#proc-starttime:* }" ;;
    *) forged="Thu Jan 1 00:00:00 2001 ${identity#* 20[0-9][0-9] }" ;;
  esac
  bash -c '. "$1"; fm_pid_identity_matches "$2" "$3"' _ "$LIB" "$live" "$forged" \
    && fail "fm_pid_identity_matches accepted a record whose start marker differs"
  bash -c '. "$1"; fm_pid_identity_matches "$2" ""' _ "$LIB" "$live" \
    && fail "fm_pid_identity_matches accepted an empty recorded identity"
  kill "$live" "$other" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  dead_pid=$live
  bash -c '. "$1"; fm_pid_identity_matches "$2" "$3"' _ "$LIB" "$dead_pid" "$identity" \
    && fail "fm_pid_identity_matches accepted a dead pid"
  bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$dead_pid" >/dev/null 2>&1 \
    && fail "fm_pid_identity produced an identity for a dead pid"
  pass "fm_pid_identity_matches still rejects dead, recycled, and start-marker-mismatched pids"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_pid_identity_is_stable_across_repeated_reads
test_pid_identity_parses_odd_proc_stat_comm
test_pid_identity_parses_real_process_with_odd_comm
test_pid_identity_falls_back_without_proc_stat
test_pid_identity_matches_legacy_record
test_pid_identity_matches_rejects_dead_and_other_processes
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_attaches_to_healthy_peer
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
