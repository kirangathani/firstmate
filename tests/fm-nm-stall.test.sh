#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-stall.sh and bin/fm-crew-state.sh --progress -
# the "a validation step has stopped advancing" predicate.
#
# The condition under test: a task whose no-mistakes pipeline step has stopped
# CHANGING, while the worker itself is alive and busy so no existing path looks
# at it. Firstmate could always detect a stopped WORKER; it had no notion of a
# stopped pipeline STEP, so a step running for two minutes and a step frozen for
# twenty hours read identically.
#
# Both directions are covered deliberately. A predicate verified only on the
# firing path has verified nothing worth having - the whole cost of this alarm
# is the turns it would waste if it cried wolf - so every firing case here is
# paired with a silent one built from the same fixture: a run that advances, a
# freeze still inside the threshold, an acknowledged finding, a task nobody
# could read, and the kinds that never validate at all.
#
# THE FIXTURES ARE THE REAL INCIDENT. tests/fixtures/nm-stall/ holds two
# verbatim captures of ONE real run - task eln-drop-variables-w7, the run whose
# CI step sat frozen for over twenty hours on `could not check CI: gh pr checks:
# exit status 1` while its PR was green. Both are the exact stdout of
#   no-mistakes axi status --run 01KZRQJJ2JX66ECFBTNPKPSKGH
# on no-mistakes v1.37.0 (78e4dcb) on 2026-08-12, with only the capture
# harness's own trailing marker line removed.
# `axi-status-ci-wedged.toon` was taken while the run was still frozen
# (`ci,running`, and its own active_steps row reading `active_for 23h11m` beside
# a `19s ago` last-activity); `axi-status-ci-advanced.toon` was taken about
# fifteen minutes later, after it finally advanced and passed. That pair is what
# a frozen reading and an advanced reading of one run actually look like, so the
# token is pinned against real bytes rather than an idea of them.
#
# Hermetic: real throwaway git repos, a fake `no-mistakes` serving those captured
# bytes, and a state/ dir under one temp root. No network, no real fleet, and no
# real no-mistakes call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-nm-stall)
STALL="$ROOT/bin/fm-nm-stall.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
FIXTURES="$ROOT/tests/fixtures/nm-stall"

# Every offset is derived from the shipped default at run time, never written
# down, so widening or tightening the threshold cannot leave these cases passing
# against a predicate that no longer fires where they say it does.
DEFAULT_STALL_SECS=$(env -u FM_NM_STALL_SECS "$STALL" --threshold)
case "$DEFAULT_STALL_SECS" in
  ''|*[!0-9]*) fail "could not read the shipped stall threshold out of $STALL" ;;
esac
PAST_THRESHOLD=$((DEFAULT_STALL_SECS * 2))
INSIDE_THRESHOLD=$((DEFAULT_STALL_SECS / 2))

# --- worlds -----------------------------------------------------------------

# A home with a state/ dir and a stub current-state reader whose two output
# lines the caller drives by environment. Stubbing THIS reader rather than
# no-mistakes is deliberate for the record/threshold cases: the format it emits
# is firstmate's own, and it is pinned against the real captured bytes by the
# token cases further down.
new_home() {  # <slug> -> echoes home dir
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state"
  cat > "$h/crew-state-stub" <<'SH'
#!/usr/bin/env bash
set -u
# One canned answer per task id, via STUB_<id> style env, else the shared one.
printf 'state: %s · source: %s · detail\n' "${STUB_STATE:-working}" "${STUB_SOURCE:-run-step}"
[ -n "${STUB_TOKEN:-}" ] && printf 'progress: %s\t%s\n' "${STUB_STEP:--}" "$STUB_TOKEN"
exit 0
SH
  chmod +x "$h/crew-state-stub"
  printf '%s\n' "$h"
}

add_task() {  # <home> <id> [kind]
  fm_write_meta "$1/state/$2.meta" "kind=${3:-ship}" "worktree=$1/wt-$2" "window=fm:fm-$2"
}

# Run the sweep at a frozen clock. Extra args go to the script.
sweep() {  # <home> <now-epoch> [args...]
  local home=$1 at=$2
  shift 2
  FM_STATE_OVERRIDE="$home/state" FM_CREW_STATE_BIN="$home/crew-state-stub" \
    FM_NM_STALL_NOW="$at" "$STALL" "$@"
}

# --- the predicate: progress, not elapsed time ------------------------------

# The silent half, and the reason the threshold is generous: across the 61 most
# recent real runs on this machine a single step legitimately occupied up to 96
# minutes, so a run that is merely SLOW must never fire.
test_a_run_that_keeps_advancing_never_fires() {
  local home out status t
  home=$(new_home advancing)
  add_task "$home" adv
  t=1000
  # Five observations spread over well past the threshold, each seeing a step
  # the previous one did not. Elapsed time is irrelevant; movement is not.
  for step in intent review test lint ci; do
    out=$(STUB_STEP="$step" STUB_TOKEN="run=A;status=running;steps=$step:running:0" \
      sweep "$home" "$t" --observe); status=$?
    expect_code 0 "$status" "an advancing run fired at step $step"
    [ -z "$out" ] || fail "an advancing run printed at step $step: $out"
    t=$((t + PAST_THRESHOLD))
  done
  pass "fm-nm-stall: a long run that keeps advancing never fires, however long it takes"
}

test_a_step_frozen_past_the_threshold_alarms() {
  local home out status
  home=$(new_home frozen)
  add_task "$home" eln-drop-variables-w7
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  out=$(sweep "$home" 1000 --observe); status=$?
  expect_code 0 "$status" "the first sighting of a step must not fire"
  [ -z "$out" ] || fail "the first sighting printed: $out"

  out=$(sweep "$home" $((1000 + INSIDE_THRESHOLD)) --observe); status=$?
  expect_code 0 "$status" "a freeze still inside the threshold must not fire"
  [ -z "$out" ] || fail "a freeze inside the threshold printed: $out"

  out=$(sweep "$home" $((1000 + PAST_THRESHOLD)) --observe); status=$?
  unset STUB_STEP STUB_TOKEN
  expect_code 1 "$status" "a step frozen past the threshold did not fire"
  assert_contains "$out" "eln-drop-variables-w7" "the alarm did not name the task"
  assert_contains "$out" '"ci" step' "the alarm did not name the frozen step"
  assert_contains "$out" "without advancing" "the alarm did not say what was wrong"
  assert_contains "$out" "bin/fm-nm-stall.sh --ack" "the alarm did not say how to silence it"
  pass "fm-nm-stall: a frozen step alarms past the threshold and names the task and the step"
}

# The alarm has to state HOW LONG, or it reads the same at ten minutes and at
# twenty hours - which is exactly the reading that let the incident run all night.
test_the_alarm_states_how_long_the_step_has_been_frozen() {
  local home out
  home=$(new_home duration)
  add_task "$home" t1
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  sweep "$home" 0 --observe >/dev/null
  out=$(sweep "$home" $((20 * 3600 + 14 * 60)) --observe) || true
  unset STUB_STEP STUB_TOKEN
  assert_contains "$out" "20h14m" "the alarm did not state the frozen span it measured"
  pass "fm-nm-stall: the alarm states how long the step has been frozen"
}

# --- durability -------------------------------------------------------------

# A restart must not hand a frozen run a fresh clock. The record is a state file
# for exactly this reason, and the span is measured between OBSERVATIONS rather
# than from a start time, so nothing about firstmate's own lifetime can reset it.
test_the_frozen_span_survives_a_restart() {
  local home out status
  home=$(new_home restart)
  add_task "$home" t1
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  sweep "$home" 1000 --observe >/dev/null
  sweep "$home" $((1000 + PAST_THRESHOLD)) --observe >/dev/null 2>&1 || true

  # Everything volatile is gone; only state/ survives, exactly as it does across
  # a session restart. Reporting reads the record and makes no call at all.
  out=$(FM_STATE_OVERRIDE="$home/state" FM_CREW_STATE_BIN=/nonexistent \
    FM_NM_STALL_NOW=$((1000 + PAST_THRESHOLD)) "$STALL"); status=$?
  unset STUB_STEP STUB_TOKEN
  expect_code 1 "$status" "the finding did not survive a restart with no reader available"
  assert_contains "$out" "t1" "the surviving finding did not name the task"
  pass "fm-nm-stall: a frozen span survives a restart and needs no reader to report"
}

# A span may only grow on evidence. A watcher outage, a sleeping machine, or a
# reader that cannot answer must not age a task toward the alarm, or every
# outage would end in a wave of false findings.
test_an_unreadable_task_does_not_age_toward_the_alarm() {
  local home out status
  home=$(new_home unreadable)
  add_task "$home" t1
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  sweep "$home" 1000 --observe >/dev/null
  unset STUB_STEP STUB_TOKEN

  # The reader can no longer attribute a run: no progress line, and a source
  # that proves nothing either way.
  out=$(STUB_STATE=unknown STUB_SOURCE=none sweep "$home" $((1000 + PAST_THRESHOLD)) --observe)
  status=$?
  expect_code 0 "$status" "a task nobody could read aged toward the alarm anyway"
  [ -z "$out" ] || fail "an unreadable task printed: $out"
  pass "fm-nm-stall: a task that could not be read does not age toward the alarm"
}

# --- silencing and re-arming ------------------------------------------------

test_acknowledging_a_finding_silences_it_and_a_later_freeze_re_arms() {
  local home out status
  home=$(new_home ack)
  add_task "$home" t1
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  sweep "$home" 1000 --observe >/dev/null
  sweep "$home" $((1000 + PAST_THRESHOLD)) --observe >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "precondition: a frozen step past the threshold must fire"

  sweep "$home" $((1000 + PAST_THRESHOLD)) --ack t1 >/dev/null \
    || fail "could not acknowledge the finding"
  out=$(sweep "$home" $((1000 + PAST_THRESHOLD)) --observe); status=$?
  expect_code 0 "$status" "an acknowledged finding kept firing"
  [ -z "$out" ] || fail "an acknowledged finding printed: $out"

  # The run advances, then freezes again on the next step. The acknowledgement
  # was scoped to the step it was made at, so this is a new finding.
  local t2=$((1000 + PAST_THRESHOLD + 10))
  STUB_STEP=test STUB_TOKEN="run=A;status=running;steps=test:running:0" \
    sweep "$home" "$t2" --observe >/dev/null
  out=$(STUB_STEP=test STUB_TOKEN="run=A;status=running;steps=test:running:0" \
    sweep "$home" $((t2 + PAST_THRESHOLD)) --observe); status=$?
  unset STUB_STEP STUB_TOKEN
  expect_code 1 "$status" "a later freeze did not re-arm after an acknowledgement"
  assert_contains "$out" '"test" step' "the re-armed alarm did not name the newly frozen step"
  pass "fm-nm-stall: acknowledging silences a finding, and a later freeze re-arms it"
}

# --surface is what wakes firstmate, so it must fire ONCE per freeze rather than
# on every sweep: a wake repeated every ten minutes is how an alarm gets learned
# past. The durable record still blocks at turn end until it is acted on.
test_surface_wakes_once_per_freeze() {
  local home out
  home=$(new_home surface)
  add_task "$home" t1
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  sweep "$home" 1000 --observe >/dev/null
  out=$(sweep "$home" $((1000 + PAST_THRESHOLD)) --surface)
  assert_contains "$out" "NM STALL" "--surface did not report a new finding"
  assert_contains "$out" "t1" "--surface did not name the task"

  out=$(sweep "$home" $((1000 + PAST_THRESHOLD + 600)) --surface)
  [ -z "$out" ] || fail "--surface re-woke firstmate for a finding it had already surfaced: $out"

  # Still blocking, though: surfacing is not acting.
  out=$(sweep "$home" $((1000 + PAST_THRESHOLD + 600)))
  unset STUB_STEP STUB_TOKEN
  assert_contains "$out" "NM STALL" "a surfaced-but-unacknowledged finding stopped reporting"
  pass "fm-nm-stall: --surface wakes once per freeze while the finding keeps reporting"
}

# --- domain -----------------------------------------------------------------

test_kinds_that_never_validate_are_outside_the_sweep() {
  local home out status kind
  home=$(new_home kinds)
  add_task "$home" sc scout
  add_task "$home" sm secondmate
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  sweep "$home" 1000 --observe >/dev/null
  out=$(sweep "$home" $((1000 + PAST_THRESHOLD)) --observe); status=$?
  unset STUB_STEP STUB_TOKEN
  expect_code 0 "$status" "a scout or secondmate record fired a validation-stall finding"
  [ -z "$out" ] || fail "a non-validating kind printed: $out"
  for kind in sc sm; do
    [ -e "$home/state/$kind.nm-progress" ] && fail "$kind was given a progress record it can never use"
  done
  pass "fm-nm-stall: scout and secondmate records are outside the sweep"
}

test_a_run_that_reaches_a_settled_verdict_drops_its_record() {
  local home out status
  home=$(new_home settled)
  add_task "$home" t1
  export STUB_STEP=ci STUB_TOKEN="run=A;status=running;steps=ci:running:0"
  sweep "$home" 1000 --observe >/dev/null
  [ -e "$home/state/t1.nm-progress" ] || fail "precondition: the observation was not recorded"
  unset STUB_STEP STUB_TOKEN

  # The run finished, or parked at a gate: there is no step left to be frozen
  # on, and what it now owes is the unanswered-report alarm's to raise.
  out=$(STUB_STATE="done" STUB_SOURCE=run-step sweep "$home" $((1000 + PAST_THRESHOLD)) --observe)
  status=$?
  expect_code 0 "$status" "a finished run kept a stall finding alive"
  [ -z "$out" ] || fail "a finished run printed: $out"
  [ -e "$home/state/t1.nm-progress" ] && fail "a finished run kept its progress record"
  pass "fm-nm-stall: a run that reaches a settled verdict drops its record"
}

# --- the token, against the real captured bytes -----------------------------

# A repo checked out on the branch the captured run belongs to, so the reader's
# own branch attribution resolves the way it would for a live worker.
make_wedged_case() {  # <slug> <fixture> -> echoes case dir
  local d="$TMP_ROOT/$1" fb
  mkdir -p "$d/state"
  git -C "$d" init -q wt
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b fm/eln-drop-variables-w7
  fm_write_meta "$d/state/eln-drop-variables-w7.meta" \
    "kind=ship" "worktree=$d/wt" "window=fm:fm-eln-drop-variables-w7" "backend=tmux"
  fb=$(fm_fakebin "$d")
  # The captured bytes, served verbatim. The ci-step log tail is the real
  # warning line the frozen run kept emitting, which matches no green marker, so
  # the reader correctly declines to call this PR ready.
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi)
    shift
    case "\${1:-}" in
      status) cat "$2" ;;
      logs) printf '%s\n' 'warning: could not check CI: gh pr checks: exit status 1' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-panes) printf 'fm-eln-drop-variables-w7\n' ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$d"
}

read_progress() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" --progress "$2"
}

test_the_real_frozen_capture_reports_working_and_names_its_step() {
  local d out
  d=$(make_wedged_case token-wedged "$FIXTURES/axi-status-ci-wedged.toon")
  out=$(read_progress "$d" eln-drop-variables-w7)
  assert_contains "$out" "state: working" \
    "the reader stopped calling the incident's own capture a working run - the whole point is that it looks healthy"
  assert_contains "$out" "source: run-step" "the verdict did not come from the run step"
  assert_contains "$out" "progress: ci	" "the progress line did not name ci as the active step"
  pass "fm-nm-stall: the real frozen capture still reads as working and names its active step"
}

# The trap this token exists to avoid. The same live run also renders an
# active_steps row carrying `active_for` and `last_activity`, both of which
# no-mistakes re-renders on every single read - the captured row literally says
# `23h11m` and `19s ago`. A fingerprint that admitted either would have changed
# on every observation and could never have exposed a frozen step.
test_the_token_excludes_every_field_that_ticks_on_its_own() {
  local d out token
  d=$(make_wedged_case token-ticking "$FIXTURES/axi-status-ci-wedged.toon")
  out=$(read_progress "$d" eln-drop-variables-w7)
  token=$(printf '%s\n' "$out" | sed -n 's/^progress: //p')
  assert_not_contains "$token" "23h11m" "the step's own elapsed time reached the progress token"
  assert_not_contains "$token" "19s ago" "the run's last-activity text reached the progress token"
  assert_not_contains "$token" "could not check CI" "a log line reached the progress token"
  assert_not_contains "$token" "553153" "a step duration reached the progress token"
  assert_contains "$token" "ci:running" "the token dropped the step state it exists to fingerprint"
  pass "fm-nm-stall: the progress token excludes every field that ticks on its own"
}

# The other half of the same real run, fifteen minutes later. A reading that
# genuinely advanced must be a DIFFERENT token, or an advancing run would alarm.
test_the_real_advanced_capture_is_a_different_reading() {
  local wedged advanced out_w out_a
  wedged=$(make_wedged_case token-adv-a "$FIXTURES/axi-status-ci-wedged.toon")
  advanced=$(make_wedged_case token-adv-b "$FIXTURES/axi-status-ci-advanced.toon")
  out_w=$(read_progress "$wedged" eln-drop-variables-w7)
  out_a=$(read_progress "$advanced" eln-drop-variables-w7)

  assert_contains "$out_w" "progress: " "precondition: the frozen capture must carry a token"
  # Once the run passed, there is no step left to freeze on: the reader reports a
  # settled verdict and offers no token at all, which is what drops the record.
  assert_contains "$out_a" "state: done" "the advanced capture did not read as finished"
  assert_not_contains "$out_a" "progress: " \
    "a finished run offered a progress token, which would leave a frozen clock running on it"
  pass "fm-nm-stall: the same run's advanced capture is a different reading with no frozen clock"
}

# The flag is opt-in for a reason: every existing caller of this reader parses
# its one canonical line, and a second line appearing unasked would reach all of
# them.
test_the_reader_is_unchanged_without_the_flag() {
  local d with without
  d=$(make_wedged_case token-noflag "$FIXTURES/axi-status-ci-wedged.toon")
  without=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" eln-drop-variables-w7)
  with=$(read_progress "$d" eln-drop-variables-w7)
  [ "$(printf '%s\n' "$without" | wc -l)" = 1 ] \
    || fail "the reader printed more than its canonical line without --progress: $without"
  assert_contains "$with" "$without" "--progress changed the canonical line instead of adding to it"
  pass "fm-nm-stall: the reader's output is unchanged unless --progress is asked for"
}

test_a_run_with_no_step_table_is_reported_as_unmeasurable() {
  local d out
  # A run object with no steps table at all. There is nothing to fingerprint, so
  # the honest answer is no token - never a step frozen at an unknown name.
  cat > "$TMP_ROOT/no-steps.toon" <<'EOF'
run:
  id: "01RUN"
  branch: fm/eln-drop-variables-w7
  status: running
  head: "abc1234"
  findings: none
EOF
  d=$(make_wedged_case token-nosteps "$TMP_ROOT/no-steps.toon")
  out=$(read_progress "$d" eln-drop-variables-w7)
  assert_contains "$out" "state: working" "precondition: the run must still read as working"
  assert_not_contains "$out" "progress: " "a run with no step table produced a token anyway"
  pass "fm-nm-stall: a run with no step table is reported as unmeasurable, not as a frozen step"
}

test_a_run_that_keeps_advancing_never_fires
test_a_step_frozen_past_the_threshold_alarms
test_the_alarm_states_how_long_the_step_has_been_frozen
test_the_frozen_span_survives_a_restart
test_an_unreadable_task_does_not_age_toward_the_alarm
test_acknowledging_a_finding_silences_it_and_a_later_freeze_re_arms
test_surface_wakes_once_per_freeze
test_kinds_that_never_validate_are_outside_the_sweep
test_a_run_that_reaches_a_settled_verdict_drops_its_record
test_the_real_frozen_capture_reports_working_and_names_its_step
test_the_token_excludes_every_field_that_ticks_on_its_own
test_the_real_advanced_capture_is_a_different_reading
test_the_reader_is_unchanged_without_the_flag
test_a_run_with_no_step_table_is_reported_as_unmeasurable
