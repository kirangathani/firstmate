#!/usr/bin/env bash
# tests/fm-session-lock-gate.test.sh - the SESSION lock (state/.lock) decides
# which session controls a home's fleet, and this suite pins the places that
# consume that decision:
#   bin/fm-session-lock-lib.sh  the single ownership resolver (ancestry walk)
#   bin/fm-lock.sh ownership    the read-only entry point the OpenCode and Pi
#                               adapters call instead of their own copies
#   bin/fm-watch-arm.sh         refuses to arm from a session that does not own
#                               the fleet, and still arms for one that does
#   bin/fm-watch-checkpoint.sh  Codex's bounded foreground protocol, the second
#                               entry point that takes the watcher singleton
#   bin/fm-statusline.sh        the persistent in/not-in-control indicator,
#                               composed beneath the operator's own status line
#
# The regression these guard: before the gate existed, only the OpenCode and Pi
# adapters checked ownership. A second Claude Code session could arm a watcher
# for a home whose session lock named a different session, take the watcher
# singleton, and supervise a fleet it was not responsible for while the owning
# session's arm quietly attached to it.
#
# state/.lock (session lock) and state/.watch.lock (watcher singleton) are
# different locks with similar names; assertions here name which one they mean.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
WATCH_CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
LOCK_CLI="$ROOT/bin/fm-lock.sh"
STATUSLINE="$ROOT/bin/fm-statusline.sh"

# The kernel start ticks that identify a lock holder are Linux-only (/proc), and
# every code path treats them as optional. Where they are unavailable, the
# pid-reuse assertions below do not apply and the legacy pid-only behavior is
# what is asserted instead.
start_ticks_available() {
  [ -r "/proc/$$/stat" ]
}

TMP_ROOT=$(fm_test_tmproot fm-session-lock-gate)

# The watcher's one-shot PR-check migration would otherwise run inside these
# fixtures; the watcher-lock suite marks it complete the same way.
mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

# A live process that is NOT in this test's ancestry, standing in for a rival
# firstmate session that holds the session lock.
start_other_session() {
  # Both output descriptors are redirected: this runs inside a command
  # substitution, and a background job holding that pipe open would block the
  # substitution until the sleep finished.
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

watch_singleton_present() {
  local state=$1
  [ -L "$state/.watch.lock" ] || [ -e "$state/.watch.lock" ]
}

# Used only where the arm is expected to REFUSE, so it must return immediately.
# The bound keeps an ungated arm (which would sit in a real watcher cycle
# waiting for a wake that never comes) a fast, legible failure.
run_arm_foreground() {  # <state> [args...]
  local state=$1
  shift
  timeout 30 env PATH="$(dirname "$state")/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=2 \
    "$WATCH_ARM" "$@" 2>&1
}

# Arm in the background and wait for it to report a started watcher; echoes the
# arm pid. Used where the arm is expected to pass the gate and keep running.
start_arm_background() {  # <state> <output file>
  local state=$1 out=$2 armpid i
  PATH="$(dirname "$state")/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 \
    "$WATCH_ARM" > "$out" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$armpid"
}

stop_arm_background() {  # <arm pid> <state>
  local armpid=$1 state=$2 watcher
  watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -TERM "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  [ -n "$watcher" ] && kill -TERM "$watcher" 2>/dev/null
  return 0
}

# --- bin/fm-lock.sh ownership -----------------------------------------------

test_ownership_cli_classifies_and_writes_nothing() {
  local dir state other out
  dir="$TMP_ROOT/ownership-cli"
  state="$dir/state"
  mkdir -p "$dir"

  # Absent state dir: the query must classify, never create anything.
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership) \
    || fail "fm-lock.sh ownership must always exit 0"
  [ "$out" = missing ] || fail "absent session lock must classify as missing, got: $out"
  [ ! -d "$state" ] || fail "fm-lock.sh ownership created the state dir; it must be read-only"

  mkdir -p "$state"
  printf '%s\n' "$$" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = owned ] || fail "session lock naming an ancestor must classify as owned, got: $out"

  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ "$out" = other ] || fail "a live non-ancestor holder must classify as other, got: $out"

  printf '%s\n' "$(dead_pid)" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = missing ] || fail "a dead holder must classify as missing, got: $out"

  printf 'not-a-pid\n' > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = missing ] || fail "a malformed session lock must classify as missing, got: $out"

  pass "fm-lock.sh ownership: classifies owned/other/missing and never writes state"
}

test_lock_holder_identity_and_file_format() {
  local dir state other out ticks
  dir="$TMP_ROOT/lock-identity"
  state="$dir/state"
  mkdir -p "$state"

  # A lock whose only line carries NO trailing newline still names a holder.
  # Validating on read's exit status instead of the parsed value read it as
  # "missing", which would arm over a live rival owner.
  other=$(start_other_session)
  printf '%s' "$other" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = other ] || fail "a newline-free session lock must still name its holder, got: $out"

  # A LEGACY pid-only lock (no recorded ticks) keeps working on the pid alone.
  printf '%s\n' "$other" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = other ] || fail "a legacy pid-only lock must still resolve a live rival as other, got: $out"
  printf '%s\n' "$$" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = owned ] || fail "a legacy pid-only lock must still resolve an ancestor as owned, got: $out"

  if start_ticks_available; then
    ticks=$(bash -c '. "$1"; fm_pid_start_ticks "$2"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$$") \
      || fail "could not read this process's start ticks"
    printf '%s\n%s\n' "$$" "$ticks" > "$state/.lock"
    out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
    [ "$out" = owned ] || fail "matching start ticks must still resolve as owned, got: $out"

    # The pid is live, but the kernel says it started at a different time, so it
    # is a REUSED pid rather than the session that took the lock. That must read
    # as a stale lock, not as a live rival: refusing there would leave the home
    # unsupervised with the blind-turn alarm silenced.
    printf '%s\n%s\n' "$other" 1 > "$state/.lock"
    out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
    [ "$out" = missing ] || fail "a live pid with mismatched start ticks must resolve as missing, got: $out"
  fi

  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  pass "fm-session-lock-lib: holder identity is pid plus optional start ticks, parsed from the value not the read status"
}

# --- bin/fm-watch-arm.sh gate ------------------------------------------------

test_arm_refuses_when_another_session_owns_the_fleet() {
  local dir state other out status
  dir=$(make_case gate-arm-other)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"

  out=$(run_arm_foreground "$state"); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true

  [ "$status" -ne 124 ] || fail "the non-owning arm did not return; it ran a watcher cycle instead of declining"
  expect_code 0 "$status" "a non-owning session declining to arm is correct, not a failure"
  assert_contains "$out" "read-only" "the refusal must say the session is read-only"
  assert_contains "$out" "not arming" "the refusal must say it did not arm"
  assert_not_contains "$out" "watcher: FAILED" "declining to arm must not be reported as a supervision failure"
  assert_not_contains "$out" "watcher: started" "a non-owning session must not start a watcher"
  if watch_singleton_present "$state"; then
    fail "a non-owning arm took the watcher singleton (state/.watch.lock)"
  fi
  [ ! -e "$state/.last-watcher-beat" ] || fail "a non-owning arm ran a watcher (beacon was touched)"
  pass "fm-watch-arm: refuses quietly (exit 0) when another live session holds the session lock"
}

test_arm_refuses_restart_when_another_session_owns_the_fleet() {
  local dir state other out status
  dir=$(make_case gate-arm-other-restart)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"

  # --restart stops this home's watcher before starting one, so the gate has to
  # come first: a read-only session must never be able to stop the owner's
  # watcher.
  out=$(run_arm_foreground "$state" --restart); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true

  [ "$status" -ne 124 ] || fail "the non-owning --restart did not return; it ran a watcher cycle instead of declining"
  expect_code 0 "$status" "a non-owning --restart must decline, not fail"
  assert_contains "$out" "read-only" "the --restart refusal must say the session is read-only"
  if watch_singleton_present "$state"; then
    fail "a non-owning --restart touched the watcher singleton (state/.watch.lock)"
  fi
  pass "fm-watch-arm: --restart is gated too, so a read-only session cannot stop the owner's watcher"
}

test_arm_starts_for_the_owning_session() {
  local dir state out armpid
  dir=$(make_case gate-arm-owned)
  state="$dir/state"
  out="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  printf '%s\n' "$$" > "$state/.lock"

  armpid=$(start_arm_background "$state" "$out")
  grep -qF 'watcher: started pid=' "$out" || {
    stop_arm_background "$armpid" "$state"
    fail "the owning session did not arm: $(cat "$out")"
  }
  assert_not_contains "$(cat "$out")" "read-only" "the owning session must not be refused"
  watch_singleton_present "$state" || {
    stop_arm_background "$armpid" "$state"
    fail "the owning session's arm did not take the watcher singleton"
  }
  stop_arm_background "$armpid" "$state"
  pass "fm-watch-arm: the session that owns the session lock arms exactly as before"
}

test_arm_recognises_ownership_several_process_levels_down() {
  local dir state out out2 status other level1 level2 level3 armpid i
  dir=$(make_case gate-arm-depth)
  state="$dir/state"
  out="$dir/arm.out"
  level1="$dir/level1.sh"
  level2="$dir/level2.sh"
  level3="$dir/level3.sh"
  mark_pr_check_migration_complete "$state"
  printf '%s\n' "$$" > "$state/.lock"

  # A real watcher sits at least three shell levels below its session
  # (watcher <- bash <- bash <- claude), so ownership must be resolved by
  # ancestry. Each level runs the next WITHOUT exec, so every one is a genuine
  # extra process: the arm's own parent is level3, never the lock holder.
  printf '#!/usr/bin/env bash\nbash "%s"\nexit $?\n' "$level2" > "$level1"
  printf '#!/usr/bin/env bash\nbash "%s"\nexit $?\n' "$level3" > "$level2"
  printf '#!/usr/bin/env bash\n"%s"\nexit $?\n' "$WATCH_ARM" > "$level3"
  chmod +x "$level1" "$level2" "$level3"

  PATH="$dir/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 \
    bash "$level1" > "$out" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || {
    stop_arm_background "$armpid" "$state"
    fail "ownership was not recognised three process levels below the lock holder: $(cat "$out")"
  }
  stop_arm_background "$armpid" "$state"

  # The same depth must still refuse a rival holder, so the walk is genuinely
  # deciding rather than the depth simply making everything look owned.
  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"
  rm -f "$state/.last-watcher-beat"
  out2=$(timeout 30 env PATH="$dir/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=2 \
    bash "$level1" 2>&1); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ "$status" -ne 124 ] || fail "the deep non-owning arm did not return; it ran a watcher cycle instead of declining"
  assert_contains "$out2" "read-only" "the same ancestry depth must still refuse a rival session lock holder"
  pass "fm-watch-arm: ownership is resolved by ancestry, not by the immediate parent"
}

test_arm_still_arms_without_a_lock_holder_and_says_so() {
  local row dir state out armpid
  # Startup and recovery can legitimately arm before any session lock exists, and
  # a dead holder means nobody is being displaced. Both must still arm - refusing
  # would leave the home unsupervised - but neither may do it silently.
  for row in absent dead malformed; do
    dir=$(make_case "gate-arm-$row")
    state="$dir/state"
    out="$dir/arm.out"
    mark_pr_check_migration_complete "$state"
    case "$row" in
      absent) rm -f "$state/.lock" ;;
      dead) printf '%s\n' "$(dead_pid)" > "$state/.lock" ;;
      malformed) printf 'garbage\n' > "$state/.lock" ;;
    esac

    armpid=$(start_arm_background "$state" "$out")
    grep -qF 'watcher: started pid=' "$out" || {
      stop_arm_background "$armpid" "$state"
      fail "$row session lock blocked a legitimate arm: $(cat "$out")"
    }
    assert_contains "$(cat "$out")" "no live session holds this home's session lock" \
      "$row session lock must be announced, never a silent grant"
    assert_contains "$(cat "$out")" "bin/fm-session-start.sh" \
      "$row session lock notice must name the command that claims the lock"
    stop_arm_background "$armpid" "$state"
  done
  pass "fm-watch-arm: an absent, dead-holder, or malformed session lock arms but is announced"
}

test_arm_arms_when_the_lock_holder_pid_was_reused() {
  local dir state other out armpid
  # After a reboot state/.lock survives (state/ is not tmpfs) and its pid is
  # very likely handed to an unrelated live process. Reading that as a live rival
  # would refuse to arm AND silence the blind-turn alarm at the same time, so the
  # home would run unsupervised with nothing complaining.
  start_ticks_available || {
    pass "fm-watch-arm: pid-reuse detection needs /proc start ticks; not available here"
    return 0
  }
  dir=$(make_case gate-arm-reused-pid)
  state="$dir/state"
  out="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  other=$(start_other_session)
  printf '%s\n%s\n' "$other" 1 > "$state/.lock"

  armpid=$(start_arm_background "$state" "$out")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  grep -qF 'watcher: started pid=' "$out" || {
    stop_arm_background "$armpid" "$state"
    fail "a reused holder pid blocked a legitimate arm: $(cat "$out")"
  }
  assert_contains "$(cat "$out")" "no live session holds this home's session lock" \
    "a reused holder pid must be announced as a stale lock, never a silent grant"
  assert_not_contains "$(cat "$out")" "read-only" "a reused holder pid must not read as a live rival"
  stop_arm_background "$armpid" "$state"
  pass "fm-watch-arm: a live pid the kernel says is a different process is a stale lock, so the home still arms"
}

# --- bin/fm-watch-checkpoint.sh gate -----------------------------------------
# Codex's documented watcher protocol is the second entry point that takes the
# watcher singleton, so it carries the same gate. bin/fm-watch.sh itself is NOT
# gated: the arm and the away-mode daemon fork it as a legitimate child.

run_checkpoint() {  # <state> [args...]
  local state=$1
  shift
  timeout 30 env PATH="$(dirname "$state")/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_CHECKPOINT" --seconds 1 "$@" 2>&1
}

test_checkpoint_is_gated_on_the_session_lock() {
  local dir state other out status
  dir=$(make_case gate-checkpoint)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"

  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"
  out=$(run_checkpoint "$state"); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "a non-owning checkpoint declining is correct, not a failure"
  assert_contains "$out" "read-only" "the checkpoint refusal must say the session is read-only"
  assert_contains "$out" "not arming" "the checkpoint refusal must say it did not arm"
  assert_not_contains "$out" "watcher: FAILED" "declining a checkpoint must not be a supervision failure"
  if watch_singleton_present "$state"; then
    fail "a non-owning checkpoint took the watcher singleton (state/.watch.lock)"
  fi
  [ ! -e "$state/.last-watcher-beat" ] || fail "a non-owning checkpoint ran a watcher (beacon was touched)"

  # The owning session runs its checkpoint exactly as before.
  printf '%s\n' "$$" > "$state/.lock"
  out=$(run_checkpoint "$state"); status=$?
  expect_code 124 "$status" "the owning session's quiet checkpoint must still time out normally"
  assert_contains "$out" "checkpoint: no actionable wake within 1s" "the owning session's checkpoint did not run"
  assert_not_contains "$out" "read-only" "the owning session's checkpoint must not be refused"
  pass "fm-watch-checkpoint: gated on the session lock the same way, so Codex inherits the rule too"
}

# --- bin/fm-statusline.sh ----------------------------------------------------

# With nothing configured locally, base-command resolution falls back to the
# harness's own user-level status line (docs/configuration.md "Status-line
# composition"). These cases are about the fleet line and about the configured
# sources, so they pin that fallback at an empty config dir - otherwise they
# would read whatever status line the developer running the suite happens to have
# installed, and assert on it. tests/fm-statusline-render.test.sh owns the
# fallback itself, and renders it end to end.
STATUSLINE_EMPTY_CONFIG="$TMP_ROOT/statusline-empty-claude-config"
mkdir -p "$STATUSLINE_EMPTY_CONFIG"

# FM_STATUSLINE_BASE is stripped for the same reason: bin/fm-spawn.sh exports it
# into every crewmate worktree, so a suite that inherited it would compose the
# dispatching home's real status line into cases that assert on silence.
run_statusline() {  # <home>
  printf '{"session_id":"test"}' |
    env -u FM_STATUSLINE_BASE FM_HOME="$1" CLAUDE_CONFIG_DIR="$STATUSLINE_EMPTY_CONFIG" \
      "$STATUSLINE" 2>&1
}

test_statusline_reports_fleet_control() {
  local home out other status
  home="$TMP_ROOT/statusline-home"
  mkdir -p "$home/state"

  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "the status line must always exit 0"
  assert_contains "$out" "in control of fleet" "the owning session must be shown as in control"
  assert_not_contains "$out" "not in control of fleet" "the owning session must not be shown as out of control"

  other=$(start_other_session)
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(run_statusline "$home")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_contains "$out" "not in control of fleet" "a session that does not hold the lock must be shown as not in control"

  rm -f "$home/state/.lock"
  out=$(run_statusline "$home")
  assert_contains "$out" "not in control of fleet" "no lock holder means no session is in control"
  assert_contains "$out" "bin/fm-session-start.sh" "the no-holder line must name how to take control"
  pass "fm-statusline: reports fleet control for the current home"
}

test_statusline_is_silent_and_writes_nothing_without_fleet_state() {
  local home out status
  # Every crewmate and scout task worktree of this repo carries the tracked
  # script but no state dir; the indicator must degrade to silence there.
  home="$TMP_ROOT/statusline-no-state"
  mkdir -p "$home"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "the status line must exit 0 with no fleet state"
  [ -z "$out" ] || fail "the status line spoke without fleet state: $out"
  [ ! -d "$home/state" ] || fail "the status line created the state dir; it must never write to state"
  pass "fm-statusline: silent, and creates nothing, where there is no fleet state"
}

install_statusline_base() {  # <home> <base path>
  local home=$1 base=$2
  mkdir -p "$home/config"
  cat > "$base" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf 'base line payload=%s\n' "$payload"
SH
  chmod +x "$base"
  printf '%s\n' "$base" > "$home/config/statusline-base"
}

test_statusline_composes_with_the_operators_own_status_line() {
  local home base out status
  # .claude/settings.json is tracked and shared, so wiring this script there
  # would otherwise REPLACE whatever status line the operator already runs, in
  # every worktree of this repo. It composes instead: the operator's line first,
  # the fleet line beneath it.
  home="$TMP_ROOT/statusline-compose"
  base="$TMP_ROOT/statusline-base.sh"
  mkdir -p "$home/state"
  install_statusline_base "$home" "$base"
  printf '%s\n' "$$" > "$home/state/.lock"

  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "composing must still always exit 0"
  assert_contains "$out" "base line" "the operator's own status line must still be printed"
  assert_contains "$out" "in control of fleet" "the fleet line must still be printed"
  assert_contains "$out" 'payload={"session_id":"test"}' "the harness payload must be forwarded to the base command"
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = 'base line payload={"session_id":"test"}' ] \
    || fail "the base line must come first, got: $out"
  printf '%s\n' "$out" | sed -n '2p' | grep -qF 'in control of fleet' \
    || fail "the fleet line must come second, got: $out"

  # A crewmate or scout task worktree carries the tracked script but no fleet
  # state. The fleet line is silent there, and going blank instead of showing the
  # operator's own line is the complaint this composition answers.
  home="$TMP_ROOT/statusline-compose-no-state"
  mkdir -p "$home"
  install_statusline_base "$home" "$base"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "composing without fleet state must exit 0"
  assert_contains "$out" "base line" "the operator's line must print even where there is no fleet state"
  assert_not_contains "$out" "control of fleet" "there is no fleet here, so there must be no fleet line"
  [ ! -d "$home/state" ] || fail "composing created the state dir; it must never write to state"

  # An absent, empty, or non-executable base command in the configured source
  # means no base line from it, quietly. The user-level fallback is pinned empty
  # here (see run_statusline), so what is left is the fleet line alone.
  home="$TMP_ROOT/statusline-base-unusable"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$TMP_ROOT/statusline-base-does-not-exist.sh" > "$home/config/statusline-base"
  out=$(run_statusline "$home")
  assert_contains "$out" "in control of fleet" "a missing base command must not suppress the fleet line"
  assert_not_contains "$out" "base line" "a missing base command must print nothing of its own"

  printf '%s\n' "$TMP_ROOT/statusline-base-not-executable.sh" > "$home/config/statusline-base"
  printf '#!/usr/bin/env bash\nprintf "base line\\n"\n' > "$TMP_ROOT/statusline-base-not-executable.sh"
  chmod 0644 "$TMP_ROOT/statusline-base-not-executable.sh"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "a non-executable base command must not fail the status line"
  assert_contains "$out" "in control of fleet" "a non-executable base command must not suppress the fleet line"
  assert_not_contains "$out" "base line" "a non-executable base command must not be run"

  : > "$home/config/statusline-base"
  out=$(run_statusline "$home")
  assert_contains "$out" "in control of fleet" "an empty base setting must not suppress the fleet line"
  pass "fm-statusline: composes beneath the operator's own status line, and degrades to the fleet line alone"
}

test_statusline_base_reaches_a_worktree_that_has_no_config_dir() {
  local worktree base out status
  # This is the shape a real crewmate or scout task worktree has: a plain git
  # worktree carrying the tracked .claude/settings.json wiring, with NO config/
  # and NO state/. There is no file for the composition to read there, so a
  # deliberate per-home setting reaches it only through the FM_STATUSLINE_BASE
  # env override that bin/fm-spawn.sh forwards from the dispatching home. A
  # worktree that inherits no override falls back to the operator's own
  # user-level status line instead of going blank; that case is rendered end to
  # end in tests/fm-statusline-render.test.sh.
  worktree="$TMP_ROOT/statusline-task-worktree"
  base="$TMP_ROOT/statusline-task-base.sh"
  mkdir -p "$worktree"
  cat > "$base" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf 'base line payload=%s\n' "$payload"
SH
  chmod +x "$base"
  [ ! -d "$worktree/config" ] || fail "the task-worktree fixture must have no config dir"

  out=$(printf '{"session_id":"test"}' | FM_HOME="$worktree" FM_STATUSLINE_BASE="$base" "$STATUSLINE" 2>&1); status=$?
  expect_code 0 "$status" "the env override must not fail the status line"
  assert_contains "$out" 'base line payload={"session_id":"test"}' \
    "the forwarded base command must run, and receive the harness payload, where there is no config dir"
  assert_not_contains "$out" "control of fleet" "a task worktree has no fleet, so there must be no fleet line"
  [ ! -d "$worktree/state" ] || fail "the status line created the state dir; it must never write to state"
  pass "fm-statusline: FM_STATUSLINE_BASE reaches a task worktree that has no config dir of its own"
}

test_statusline_other_branch_names_a_remedy() {
  local home other out
  home="$TMP_ROOT/statusline-other-remedy"
  mkdir -p "$home/state"
  other=$(start_other_session)
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(run_statusline "$home")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_contains "$out" "not in control of fleet" "a rival holder must be shown as not in control"
  assert_contains "$out" "bin/fm-session-start.sh" "the rival-holder line must name a remedy, like the no-holder line does"
  pass "fm-statusline: the rival-holder line names a remedy instead of leaving the session with none"
}

test_statusline_is_wired_into_claude_settings() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  command=$(jq -r '.statusLine.command // empty' "$settings")
  [ -n "$command" ] || fail "no statusLine command in .claude/settings.json"
  assert_contains "$command" 'fm-statusline.sh' "the Claude status line must run the firstmate indicator"
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "the status line must resolve from the project dir, not a bare relative path"
  [ "$(jq -r '.statusLine.type // empty' "$settings")" = command ] \
    || fail "the Claude status line must be a command status line"
  pass ".claude/settings.json: the fleet-control indicator is wired for Claude Code"
}

# --- one implementation only -------------------------------------------------

test_ownership_walk_has_exactly_one_implementation() {
  local definitions file text adapter
  # Four near-identical private copies of this walk are how the current drift
  # arose: the adapters each had one, and the Claude path had none. Everything
  # must go through bin/fm-session-lock-lib.sh, directly or through
  # `bin/fm-lock.sh ownership`.
  definitions=$(grep -rl 'fm_session_lock_ownership()' "$ROOT/bin" 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$definitions" = 1 ] || fail "expected exactly one ownership resolver, found $definitions"

  for file in fm-lock.sh fm-watch-arm.sh fm-watch-checkpoint.sh fm-turnend-guard.sh \
    fm-continuity-pretool-check.sh fm-sessionstart-nudge.sh fm-statusline.sh; do
    text=$(cat "$ROOT/bin/$file")
    assert_contains "$text" 'fm-session-lock-lib.sh' "bin/$file must resolve ownership through the shared library"
    assert_not_contains "$text" 'ps -o ppid=' "bin/$file carries its own session-lock ancestry walk"
  done

  for adapter in .opencode/plugins/fm-primary-watch-arm.js .pi/extensions/fm-primary-pi-watch.ts .pi/extensions/fm-primary-turnend-guard.ts; do
    text=$(cat "$ROOT/$adapter")
    assert_contains "$text" 'fm-lock.sh' "$adapter must delegate ownership to the shared entry point"
    assert_contains "$text" '"ownership"' "$adapter must call the ownership subcommand"
    assert_not_contains "$text" 'ps -o ppid=' "$adapter still walks the process ancestry itself"
    assert_not_contains "$text" '.lock`, "utf8"' "$adapter still reads the session lock directly"
  done
  pass "session-lock ownership has exactly one implementation (bin/fm-session-lock-lib.sh)"
}

test_ownership_cli_classifies_and_writes_nothing
test_lock_holder_identity_and_file_format
test_arm_refuses_when_another_session_owns_the_fleet
test_arm_refuses_restart_when_another_session_owns_the_fleet
test_arm_starts_for_the_owning_session
test_arm_recognises_ownership_several_process_levels_down
test_arm_still_arms_without_a_lock_holder_and_says_so
test_arm_arms_when_the_lock_holder_pid_was_reused
test_checkpoint_is_gated_on_the_session_lock
test_statusline_reports_fleet_control
test_statusline_is_silent_and_writes_nothing_without_fleet_state
test_statusline_composes_with_the_operators_own_status_line
test_statusline_base_reaches_a_worktree_that_has_no_config_dir
test_statusline_other_branch_names_a_remedy
test_statusline_is_wired_into_claude_settings
test_ownership_walk_has_exactly_one_implementation
