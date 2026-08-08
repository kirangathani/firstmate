#!/usr/bin/env bash
# tests/fm-session-lock-gate.test.sh - the SESSION lock (state/.lock) decides
# which session controls a home's fleet, and this suite pins the places that
# consume that decision:
#   bin/fm-session-lock-lib.sh  the single ownership resolver (ancestry walk)
#   bin/fm-lock.sh ownership    the read-only entry point the OpenCode and Pi
#                               adapters call instead of their own copies
#   bin/fm-watch-arm.sh         refuses to arm from a session that does not own
#                               the fleet, and still arms for one that does
#   bin/fm-statusline.sh        the persistent in/not-in-control indicator
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
LOCK_CLI="$ROOT/bin/fm-lock.sh"
STATUSLINE="$ROOT/bin/fm-statusline.sh"

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

# --- bin/fm-statusline.sh ----------------------------------------------------

run_statusline() {  # <home>
  printf '{"session_id":"test"}' | FM_HOME="$1" "$STATUSLINE" 2>&1
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

  for file in fm-lock.sh fm-watch-arm.sh fm-turnend-guard.sh fm-sessionstart-nudge.sh fm-statusline.sh; do
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
test_arm_refuses_when_another_session_owns_the_fleet
test_arm_refuses_restart_when_another_session_owns_the_fleet
test_arm_starts_for_the_owning_session
test_arm_recognises_ownership_several_process_levels_down
test_arm_still_arms_without_a_lock_holder_and_says_so
test_statusline_reports_fleet_control
test_statusline_is_silent_and_writes_nothing_without_fleet_state
test_statusline_is_wired_into_claude_settings
test_ownership_walk_has_exactly_one_implementation
