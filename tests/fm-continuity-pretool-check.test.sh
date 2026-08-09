#!/usr/bin/env bash
# Behavior tests for Claude's narrowly scoped watcher-continuity PreToolUse gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CHECK="$ROOT/bin/fm-continuity-pretool-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-continuity-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_command() {
  local command=$1 rc=0
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --command "$command" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 command=$2 rc=0
  run_command "$command" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 command=$2 blocked=$3 rc=0 expected actual
  run_command "$command" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  expected="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; run bin/fm-wake-drain.sh, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: $blocked)"
  actual=$(jq -r '.systemMessage' "$ERR")
  [ "$actual" = "$expected" ] || fail "$label recovery guidance changed: $actual"
}

test_gate_scope_and_recovery_exceptions() {
  expect_allow "idle fleet command" 'bin/fm-crew-state.sh task'
  printf 'project=fixture\n' > "$STATE/task.meta"

  expect_allow "ordinary shell command" 'git status --short'
  expect_allow "fleet-script text as data" "rg -n 'bin/fm-send.sh' docs"
  expect_allow "wake drain recovery" 'bin/fm-wake-drain.sh'
  expect_allow "watch arm recovery" 'bin/fm-watch-arm.sh'
  expect_allow "drain then arm recovery" 'bin/fm-wake-drain.sh; bin/fm-watch-arm.sh'
  expect_deny "unrelated fleet command" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  expect_deny "recovery bundled with unrelated fleet command" 'bin/fm-wake-drain.sh; bin/fm-send.sh task hi' 'fm-send.sh'
  expect_deny "literal nested fleet command" "bash -lc 'bin/fm-bootstrap.sh'" 'fm-bootstrap.sh'
  pass "continuity gate allows recovery and ordinary commands but denies only other fleet execution"
}

test_live_lock_allows_fleet_command_even_with_stale_beacon() {
  local holder identity rc=0
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify live continuity fixture"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$holder" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
  touch -t 200001010000 "$STATE/.last-watcher-beat"

  run_command 'bin/fm-crew-state.sh task' || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "identity-matched live lock must allow fleet command even when its beacon is stale"
  [ ! -s "$ERR" ] || fail "live-lock allow wrote stderr: $(cat "$ERR")"
  pass "continuity gate classifies the lock by live PID identity rather than beacon age"
}

test_non_owning_session_is_exempt_but_the_lock_holder_is_not() {
  local rival rc=0
  # The deny's only remedy is bin/fm-watch-arm.sh, which correctly declines to
  # arm for a session that does not hold the SESSION lock (state/.lock), and the
  # command policy allows no other fleet script. Without this exemption a
  # non-owner is wedged out of every fleet command with no in-session escape.
  # bin/fm-turnend-guard.sh has exactly this exemption; the two hooks fire on the
  # same predicate and must agree.
  rm -rf "$STATE/.watch.lock"
  sleep 300 &
  rival=$!
  printf '%s\n' "$rival" > "$STATE/.lock"
  run_command 'bin/fm-crew-state.sh task' || rc=$?
  kill "$rival" 2>/dev/null || true
  wait "$rival" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "a session that does not hold the session lock must be allowed through, got exit $rc: $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "the non-owner exemption wrote stderr: $(cat "$ERR")"

  # The session that DOES hold the lock is the one that should repair
  # supervision, so the deny still stands for it.
  printf '%s\n' "$$" > "$STATE/.lock"
  expect_deny "lock-holding session" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'

  # A dead or absent holder also still denies: nobody is supervising the
  # in-flight work, and this session is the one that should take the lock.
  printf '%s\n' 999999999 > "$STATE/.lock"
  expect_deny "dead lock holder" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  rm -f "$STATE/.lock"
  expect_deny "absent session lock" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  pass "continuity gate exempts a non-owning session while keeping the deny for the session that owns the fleet"
}

test_child_worktree_and_malformed_input_fail_open() {
  local child="$TMP_ROOT/child" rc=0
  rm -rf "$STATE/.watch.lock"
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --command 'bin/fm-send.sh task hi' > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "linked child worktree must be out of continuity-gate scope"

  expect_allow "malformed dynamic shell" "bin/fm-send.sh 'unterminated"
  printf '%s' '{not-json' | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed Claude transport must fail open"
  pass "continuity gate excludes child worktrees and fails open on opaque input"
}

test_claude_hook_registration_preserves_stop_backstop() {
  jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
      | any(contains("fm-continuity-pretool-check.sh"))
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude settings omit the continuity PreToolUse hook"
  jq -e '
    .hooks.Stop == [{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh"}]}]
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude Stop turn-end backstop changed"
  pass "Claude wires the continuity gate while preserving the existing Stop backstop byte-for-byte"
}

test_gate_scope_and_recovery_exceptions
test_live_lock_allows_fleet_command_even_with_stale_beacon
test_non_owning_session_is_exempt_but_the_lock_holder_is_not
test_child_worktree_and_malformed_input_fail_open
test_claude_hook_registration_preserves_stop_backstop
