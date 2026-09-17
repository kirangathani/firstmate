#!/usr/bin/env bash
# Behaviour tests for bin/fm-detach-lib.sh and bin/fm-detach-run.sh.
#
# The subject is a command that hands its work to a child and returns at once, so
# every assertion here is about a process the harness is no longer holding: that
# the caller gets control back immediately, that the work still finishes, that
# its verdict arrives whatever the outcome, and that killing the caller's process
# group does not take the work with it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# One shim bin/ per run, holding a symlink to EVERY entry of the real bin/ plus
# the fixture. Symlinking the whole directory rather than naming dependencies is
# deliberate: a hand-maintained list is a second copy of the dependency set that
# rots the moment a script gains a sibling, and the failure surfaces as an
# abort before the first command rather than as a missing file.
setup_home() {
  local tmproot home
  tmproot=$(fm_test_tmproot fm-detach)
  home="$tmproot/home"
  mkdir -p "$home/state" "$home/bin"
  local entry
  for entry in "$ROOT"/bin/*; do
    ln -sf "$entry" "$home/bin/$(basename "$entry")"
  done
  cat > "$home/bin/fixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:?}"
STATE="$FM_HOME/state"
[ -z "${FIXTURE_READS_STDIN:-}" ] || FM_DETACH_STDIN=1
# shellcheck source=bin/fm-detach-lib.sh
. "$SCRIPT_DIR/fm-detach-lib.sh"
fm_detach "$@"
case "${1:-}" in
  slow)   sleep 3; echo "merged: slow finished" ;;
  crash)  echo "error: deliberate failure"; exit 7 ;;
  signal) kill -TERM $$; sleep 5 ;;
  stdin)  printf 'merged: read [%s]\n' "$(cat)" ;;
  *)      echo "merged: https://example/pr/1" ;;
esac
FIXTURE
  chmod +x "$home/bin/fixture.sh"
  printf '%s\n' "$home"
}

results_of() { cat "$1/state/.wake-results" 2>/dev/null || true; }

# Wait until the results log has content, bounded so a hang fails rather than
# stalling the suite. The bound is wall-clock patience, not a behaviour claim.
await_result() {
  local home=$1 waited=0
  while [ ! -s "$home/state/.wake-results" ]; do
    [ "$waited" -lt 150 ] || return 1
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

test_a_plain_call_returns_before_the_work_can_finish() {
  local home started ended elapsed
  home=$(setup_home)
  # The fixture's work sleeps three seconds. A caller that comes back inside one
  # is one that did not wait for it.
  started=$(date +%s%N)
  FM_HOME="$home" "$home/bin/fixture.sh" slow
  ended=$(date +%s%N)
  elapsed=$(( (ended - started) / 1000000 ))
  printf 'parent returned in %sms\n' "$elapsed"
  [ "$elapsed" -lt 1000 ] || fail "the parent waited ${elapsed}ms for work it was supposed to hand off"
  pass "a plain call returns before the detached work can finish"
}

test_a_plain_call_prints_nothing() {
  local home out
  home=$(setup_home)
  out=$(FM_HOME="$home" "$home/bin/fixture.sh" ok 2>&1)
  [ -z "$out" ] || fail "the parent printed '$out' when it should have printed nothing"
  pass "a plain call prints nothing for firstmate to read"
}

test_the_detached_child_finishes_and_records_its_verdict() {
  local home
  home=$(setup_home)
  FM_HOME="$home" "$home/bin/fixture.sh" ok
  await_result "$home" || fail "no verdict ever reached the results channel"
  assert_contains "$(results_of "$home")" "merged: https://example/pr/1" \
    "the child's own verdict line did not reach the results channel"
  pass "the detached child finishes and records its verdict"
}

test_a_successful_verdict_carries_no_log_path() {
  local home
  home=$(setup_home)
  FM_HOME="$home" "$home/bin/fixture.sh" ok
  await_result "$home" || fail "no verdict ever reached the results channel"
  assert_not_contains "$(results_of "$home")" "log:" \
    "a successful verdict carried a log path, which is noise on the common outcome"
  pass "a successful verdict carries no log path"
}

test_a_crashing_child_still_records_a_line() {
  local home out
  home=$(setup_home)
  FM_HOME="$home" "$home/bin/fixture.sh" crash
  await_result "$home" || fail "a failing child recorded nothing, which reads as success"
  out=$(results_of "$home")
  assert_contains "$out" "exit 7" "the failure line did not carry the exit code"
  assert_contains "$out" "log:" "the failure line did not carry its log path"
  assert_contains "$out" "error: deliberate failure" \
    "the failure line did not inline the reason, so firstmate would need a read call"
  pass "a crashing child still records a line with its code, log and reason"
}

test_a_child_killed_by_a_signal_still_records_a_line() {
  local home
  home=$(setup_home)
  FM_HOME="$home" "$home/bin/fixture.sh" signal
  await_result "$home" || fail "a signalled child recorded nothing, which reads as success"
  assert_contains "$(results_of "$home")" "exit " \
    "a child that died on a signal left no exit code behind"
  pass "a child killed by a signal still records a line"
}

test_the_child_survives_a_kill_of_its_parents_process_group() {
  local home leader
  home=$(setup_home)
  # The parent runs as its own process-group leader so the group can be signalled
  # without touching the test runner. If the child were still in that group - the
  # pre-setsid shape that cost the watcher 107 kills - this would take it too.
  setsid env FM_HOME="$home" "$home/bin/fixture.sh" slow &
  leader=$!
  sleep 0.5
  kill -TERM -"$leader" 2>/dev/null || true
  await_result "$home" || fail "killing the parent's process group killed the detached work"
  assert_contains "$(results_of "$home")" "merged: slow finished" \
    "the detached work did not run to completion after its parent's group was killed"
  pass "the child survives a kill of its parent's process group"
}

test_the_inline_marker_runs_the_body_in_place() {
  local home out
  home=$(setup_home)
  out=$(FM_INLINE=1 FM_HOME="$home" "$home/bin/fixture.sh" ok 2>&1)
  assert_contains "$out" "merged: https://example/pr/1" \
    "the inline marker did not run the body in the caller's own process"
  [ ! -s "$home/state/.wake-results" ] \
    || fail "an inline run recorded a results line, which belongs to the detached child alone"
  pass "the inline marker runs the body in place and records nothing"
}

test_stdin_reaches_the_child_only_when_the_script_asks_for_it() {
  local home
  home=$(setup_home)
  printf 'piped instruction\n' | FIXTURE_READS_STDIN=1 FM_HOME="$home" "$home/bin/fixture.sh" stdin
  await_result "$home" || fail "the stdin-reading child recorded nothing"
  assert_contains "$(results_of "$home")" "merged: read [piped instruction]" \
    "the piped input did not survive the handover to the detached child"
  pass "stdin reaches the child when the script asks for it"
}

test_logs_are_pruned_to_the_configured_limit() {
  local home keep count i
  home=$(setup_home)
  keep=3
  mkdir -p "$home/state/.detach"
  # More stale logs than the limit, so pruning has to remove some.
  for i in $(seq 1 $((keep * 3))); do
    : > "$home/state/.detach/stale-$i.log"
  done
  FM_DETACH_LOG_KEEP="$keep" FM_HOME="$home" "$home/bin/fixture.sh" ok
  await_result "$home" || fail "the pruning run recorded no verdict"
  count=$(find "$home/state/.detach" -maxdepth 1 -type f -name '*.log' | wc -l | tr -d '[:space:]')
  # The limit is whatever was configured for this run, never a number that
  # happened to work: the run's own log is written after pruning, so the ceiling
  # is the limit plus that one.
  [ "$count" -le "$((keep + 1))" ] \
    || fail "pruning left $count logs with the limit set to $keep"
  pass "logs are pruned to the configured limit"
}

test_a_plain_call_returns_before_the_work_can_finish
test_a_plain_call_prints_nothing
test_the_detached_child_finishes_and_records_its_verdict
test_a_successful_verdict_carries_no_log_path
test_a_crashing_child_still_records_a_line
test_a_child_killed_by_a_signal_still_records_a_line
test_the_child_survives_a_kill_of_its_parents_process_group
test_the_inline_marker_runs_the_body_in_place
test_stdin_reaches_the_child_only_when_the_script_asks_for_it
test_logs_are_pruned_to_the_configured_limit
