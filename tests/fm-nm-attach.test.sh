#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-nm-attach.sh, the one owner of attaching to a
# no-mistakes run, and for the PreToolUse denial of the raw attach command that
# makes it the only route (bin/fm-fix-instructions-policy.mjs, transported by
# bin/fm-fix-instructions-check.sh).
# See docs/fix-instructions-gate.md for the contract.
#
# WHAT THESE TESTS ARE GUARDING. The wrapper exists because a foreground
# `no-mistakes axi run --wait 8m` returns `error: wait of 8m0s elapsed` several
# times per 25-35 minute run, each return costing a turn and carrying no news,
# and because a run that parks at a gate waits indefinitely with nobody told.
# So the two properties that matter are exactly the two asserted hardest here:
# the caller gets control back immediately even though the hold is still
# blocking, and the hold's eventual return lands as a status line the fleet
# classifier can triage.
#
# THE FIXTURES ARE THE REAL TOOL. tests/fixtures/nm-attach/PROVENANCE.md records,
# per fixture, which bytes were captured from the installed no-mistakes and which
# two shapes could not be captured on this machine (a gate state is not durable -
# no `awaiting_approval` row exists in the daemon database across all 73 recorded
# runs), along with the exact source assertions each composed line is taken from.
# Read that file before editing any .toon here.
#
# Hermetic: real throwaway git repos, a fake `no-mistakes` on PATH serving those
# fixture bytes, and a temp firstmate home. No daemon is contacted and no harness
# binary is spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-attach)
ATTACH="$ROOT/bin/fm-nm-attach.sh"
CHECK="$ROOT/bin/fm-fix-instructions-check.sh"
POLICY="$ROOT/bin/fm-fix-instructions-policy.mjs"
FIXTURES="$ROOT/tests/fixtures/nm-attach"
NM_STALL_FIXTURES="$ROOT/tests/fixtures/nm-stall"

# The branch the four on-branch fixtures were captured on, so a case that serves
# them has to be that task for the wrapper's own branch guard to accept them.
FIXTURE_TASK=eln-drop-variables-w7

# --- case builder -----------------------------------------------------------
#
# Builds a case directory holding a firstmate home (data/<id>/brief.md +
# state/), a real git worktree checked out on fm/<id>, and a fakebin with a
# `no-mistakes` stub. Echoes the case dir.
#
# <slug> <task-id> <status-fixture-or-empty> [attach-sleep-secs] [attach-rc]
make_case() {
  local slug=$1 id=$2 fixture=${3:-} sleep_secs=${4:-0} attach_rc=${5:-0} dir
  dir="$TMP_ROOT/$slug"
  mkdir -p "$dir/home/data/$id" "$dir/home/state" "$dir/bin" "$dir/tmp"

  cat > "$dir/home/data/$id/brief.md" <<EOF
You are a crewmate.

# Task
Make the uploader retry a transient 503 so a batch is never lost.

# Setup
Not part of the intent.
EOF

  git init -q "$dir/repo"
  fm_git_identity "$dir/repo"
  ( cd "$dir/repo" \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -qm seed \
    && git checkout -qb "fm/$id" )

  # The fake no-mistakes. It records every invocation, sleeps for the attach so
  # the caller's immediate return is measurable against a hold that is provably
  # still blocking, and serves the fixture bytes for `axi status`.
  cat > "$dir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/invocations"
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ]; then
  [ -n "$fixture" ] && cat "$fixture"
  exit 0
fi
sleep $sleep_secs
exit $attach_rc
EOF
  chmod +x "$dir/bin/no-mistakes"
  printf '%s\n' "$dir"
}

# Run the wrapper from inside a case's worktree with its fake tool on PATH.
run_attach() {  # <case-dir> <task-id> [args...]
  local dir=$1 id=$2
  shift 2
  ( cd "$dir/repo" \
    && PATH="$dir/bin:$PATH" \
       FM_HOME="$dir/home" \
       FM_TASK_TMP_OVERRIDE="$dir/tmp" \
       FM_NM_ATTACH_WAIT="${FM_NM_ATTACH_WAIT:-3h}" \
       "$ATTACH" "$id" "$@" )
}

status_of() {  # <case-dir> <task-id>
  cat "$1/home/state/$2.status" 2>/dev/null || true
}

# Block until the detached follower has written its status line, or give up.
# <want-lines> defaults to 1. A --respond attach writes its own gate-closing line
# at send time, so a case that drives one must wait for TWO lines or it races the
# follower it is asserting about.
await_status() {  # <case-dir> <task-id> <deadline-secs> [want-lines]
  local dir=$1 id=$2 deadline=$3 want=${4:-1} waited=0 have
  while [ "$waited" -lt "$deadline" ]; do
    have=$(grep -c . "$dir/home/state/$id.status" 2>/dev/null || echo 0)
    [ "$have" -ge "$want" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# --- it detaches, and it comes back now -------------------------------------

test_returns_immediately_while_the_hold_still_blocks() {
  local dir out started elapsed
  # The hold sleeps well past any plausible tool-call budget. A wrapper that
  # waited for it - the exact shape this whole change exists to remove - could
  # not finish inside the 2s assertion below.
  dir=$(make_case detaches "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 30)
  started=$(date +%s)
  out=$(run_attach "$dir" "$FIXTURE_TASK") || fail "the wrapper refused a valid attach: $out"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 2 ] || fail "the wrapper took ${elapsed}s to return; it must detach and return immediately"

  assert_contains "$out" 'attached in the background' "the caller was not told the hold is in the background"
  assert_contains "$out" "$dir/tmp/nm-attach-" "the caller was not given the log path"
  assert_contains "$out" 'Returning now on purpose' "the caller was not told the immediate return is deliberate"

  # The hold is genuinely still running: its marker names a live pid.
  local pid
  pid=$(sed -n '1p' "$dir/home/state/$FIXTURE_TASK.nm-attach")
  kill -0 "$pid" 2>/dev/null || fail "no live detached hold after the wrapper returned"
  kill "$pid" 2>/dev/null || true
  pass "attach: detaches the hold and returns within 2s while it is still blocking"
}

test_the_hold_uses_a_long_wait_and_the_pinned_intent() {
  local dir invocations
  dir=$(make_case long-wait "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 0)
  run_attach "$dir" "$FIXTURE_TASK" >/dev/null || fail "attach refused"
  await_status "$dir" "$FIXTURE_TASK" 15 || fail "the hold never classified its return"
  invocations=$(cat "$dir/invocations")

  assert_contains "$invocations" '--wait 3h' "the hold did not carry the multi-hour default wait"
  assert_not_contains "$invocations" '--wait 8m' "the hold must never fall back to the 8m default"
  # The pinned intent, verbatim from bin/fm-nm-intent.sh's one owner, never a
  # paraphrase: the pipeline's final review scores the diff against it.
  assert_contains "$invocations" 'Make the uploader retry a transient 503 so a batch is never lost.' \
    "the run did not carry the brief's own Task section as its intent"
  assert_not_contains "$invocations" 'Not part of the intent' "the intent ran past the Task section"
  assert_not_contains "$invocations" '--yes' "the hold must never pass --yes"
  pass "attach: the hold runs with a multi-hour wait, the pinned intent, and no --yes"
}

test_the_recorded_pid_is_the_hold_even_with_job_control_on() {
  local dir pid cmdline
  # With bash's `monitor` option on, a background job becomes its own
  # process-group leader, which makes setsid(1) fork instead of exec - and then
  # `$!` is the short-lived setsid process, not the hold. The marker would record
  # a pid that dies at once, and because the idempotency guard reads that pid's
  # liveness, a second attach would be allowed to race a hold still running.
  # Non-interactive bash defaults `monitor` off, so this is only reachable
  # through an inherited SHELLOPTS - which is exactly why the script sets it off
  # itself, and why this case drives it through that inheritance.
  dir=$(make_case job-control "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 30)
  # Through `env`, not a command-prefix assignment: SHELLOPTS is readonly in an
  # already-running bash, so a prefix would print "readonly variable" and leave
  # monitor OFF - which would make this case pass without ever exercising the
  # hazard. bash reads SHELLOPTS from its environment at startup, so `env` is the
  # seam. Confirmed: `env SHELLOPTS=monitor bash -c 'case "$-" in *m*)'` reports
  # monitor on, a bare run reports it off.
  ( cd "$dir/repo" \
    && env SHELLOPTS=monitor \
       PATH="$dir/bin:$PATH" \
       FM_HOME="$dir/home" \
       FM_TASK_TMP_OVERRIDE="$dir/tmp" \
       "$ATTACH" "$FIXTURE_TASK" >/dev/null ) || fail "attach refused under job control"
  pid=$(sed -n '1p' "$dir/home/state/$FIXTURE_TASK.nm-attach")
  kill -0 "$pid" 2>/dev/null || fail "the recorded pid is already dead; setsid forked and \$! named the wrong process"
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || ps -o args= -p "$pid" 2>/dev/null)
  assert_contains "$cmdline" '--follow-internal' \
    "the recorded pid is not the hold itself: $cmdline"
  kill -TERM -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  pass "attach: the recorded pid is the hold itself, even with job control inherited on"
}

test_the_wait_is_overridable() {
  local dir
  dir=$(make_case wait-override "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 0)
  FM_NM_ATTACH_WAIT=90m run_attach "$dir" "$FIXTURE_TASK" >/dev/null || fail "attach refused"
  await_status "$dir" "$FIXTURE_TASK" 15 || fail "the hold never classified its return"
  assert_contains "$(cat "$dir/invocations")" '--wait 90m' "FM_NM_ATTACH_WAIT did not reach the hold"
  pass "attach: FM_NM_ATTACH_WAIT sets the hold's bound"
}

# --- the four return shapes -------------------------------------------------
#
# Each asserts the VERB, because that is what bin/fm-classify-lib.sh triages on,
# and the key, because the keyed fold is what keeps a parked gate from being
# masked by a later append.

classify_case() {  # <slug> <fixture> [attach-rc] -> echoes the status line
  local dir
  dir=$(make_case "$1" "$FIXTURE_TASK" "$2" 0 "${3:-0}")
  run_attach "$dir" "$FIXTURE_TASK" >/dev/null || fail "attach refused in case $1"
  await_status "$dir" "$FIXTURE_TASK" 15 || fail "case $1 never classified its return"
  status_of "$dir" "$FIXTURE_TASK"
}

test_a_parked_gate_opens_a_keyed_decision() {
  local line
  line=$(classify_case parked "$FIXTURES/axi-status-parked.toon")
  [ "$(printf '%s\n' "$line" | wc -l)" = 1 ] || fail "the hold appended more than one line: $line"
  case "$line" in
    "needs-decision [key=nm-run]: "*) ;;
    *) fail "a parked gate must open a keyed needs-decision, got: $line" ;;
  esac
  assert_contains "$line" 'parked at review (awaiting_approval)' "the line did not name the gate step and its state"
  assert_contains "$line" '01KZRQJJ2JX66ECFBTNPKPSKGH' "the line did not name the run"
  assert_contains "$line" '--respond' "the line did not say how to answer the gate"
  pass "attach: a parked gate becomes one keyed needs-decision naming the step"
}

test_a_passed_run_closes_the_key() {
  local line
  line=$(classify_case passed "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon")
  [ "$(printf '%s\n' "$line" | wc -l)" = 1 ] || fail "more than one line: $line"
  case "$line" in
    "resolved [key=nm-run]: "*) ;;
    *) fail "a passed run must close the keyed decision with resolved, got: $line" ;;
  esac
  assert_contains "$line" 'passed' "the line did not name the outcome"
  pass "attach: a passed run closes the keyed decision"
}

test_a_failed_run_replaces_the_key_with_a_blocker() {
  local line
  line=$(classify_case failed "$FIXTURES/axi-status-failed.toon" 1)
  [ "$(printf '%s\n' "$line" | wc -l)" = 1 ] || fail "more than one line: $line"
  case "$line" in
    "blocked [key=nm-run]: "*) ;;
    *) fail "a failed run must report blocked under the same key, got: $line" ;;
  esac
  assert_contains "$line" 'failed' "the line did not name the outcome"
  assert_contains "$line" 'step review failed' "the line did not carry the run's own error"
  pass "attach: a failed run replaces the keyed decision with a blocker carrying the error"
}

test_an_elapsed_wait_is_a_declared_pause() {
  local line
  # The real capture of a run still live on its ci step: the shape an elapsed
  # --wait returns on. This must NOT escalate - the daemon is still working.
  line=$(classify_case elapsed "$NM_STALL_FIXTURES/axi-status-ci-wedged.toon" 1)
  [ "$(printf '%s\n' "$line" | wc -l)" = 1 ] || fail "more than one line: $line"
  case "$line" in
    "paused [key=nm-run]: "*) ;;
    *) fail "an elapsed wait on a live run must be a declared pause, got: $line" ;;
  esac
  assert_contains "$line" 'still running at ci' "the line did not name the status and the live step"
  assert_contains "$line" 'after 3h' "the line did not say how long the hold waited"
  assert_contains "$line" 'reattach' "the line did not say what to do next"
  pass "attach: an elapsed wait on a live run is a declared pause naming the step"
}

test_an_unreachable_daemon_blocks_under_its_own_key() {
  local dir line
  # No fixture: `axi status` prints nothing recognizable, which is the shape a
  # daemon that is not answering produces.
  dir=$(make_case daemon-dead "$FIXTURE_TASK" "" 0 1)
  run_attach "$dir" "$FIXTURE_TASK" >/dev/null || fail "attach refused"
  await_status "$dir" "$FIXTURE_TASK" 15 || fail "never classified"
  line=$(status_of "$dir" "$FIXTURE_TASK")
  case "$line" in
    "blocked [key=nm-daemon]: "*) ;;
    *) fail "an unreachable daemon must block under its own key, got: $line" ;;
  esac
  pass "attach: an unreachable daemon blocks under a key of its own, not the run's"
}

test_another_branchs_run_is_never_reported_as_this_task() {
  local dir line
  # The real `other_branch_run:` capture. Its body carries an id and an
  # `outcome: failed`, so a follower that read it positionally would pin another
  # task's failure on this one.
  dir=$(make_case foreign-run other-task "$FIXTURES/axi-status-other-branch.toon" 0 0)
  run_attach "$dir" other-task >/dev/null || fail "attach refused"
  await_status "$dir" other-task 15 || fail "never classified"
  line=$(status_of "$dir" other-task)
  assert_not_contains "$line" '01KZH6AZ75WXZG5JKQEMFBK6EJ' "the foreign run's id was reported as this task's"
  assert_contains "$line" 'no run exists for fm/other-task' "a record for another branch must read as no run of our own"
  pass "attach: a record for another branch is discarded, not reported as this task's run"
}

test_no_run_at_all_blocks_rather_than_pausing() {
  local dir line
  dir=$(make_case no-run other-task "$FIXTURES/axi-status-no-run.toon" 0 0)
  run_attach "$dir" other-task >/dev/null || fail "attach refused"
  await_status "$dir" other-task 15 || fail "never classified"
  line=$(status_of "$dir" other-task)
  case "$line" in
    "blocked [key=nm-run]: "*) ;;
    *) fail "an attach that started no run must block, not pause, got: $line" ;;
  esac
  pass "attach: an attach that left no run blocks rather than pausing on nothing"
}

test_a_killed_follower_still_reports() {
  local dir pid line waited
  # The wrapper's whole value is that the hold's return becomes a wake. A hold
  # that dies without classifying would take that wake with it silently, and the
  # worker's turn is long over, so nothing else would notice. A hold killed
  # mid-attach is the plausible version of that (a sweep, the OOM killer, a
  # teardown racing the run) and bash runs an EXIT trap on SIGTERM, so it is the
  # one form of that death a test can actually observe.
  dir=$(make_case follower-killed "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 60)
  run_attach "$dir" "$FIXTURE_TASK" >/dev/null || fail "attach refused"
  pid=$(sed -n '1p' "$dir/home/state/$FIXTURE_TASK.nm-attach")
  # Wait for the hold to have actually begun before signalling it. The parent
  # returns before the re-executed follower has installed its handler, and a
  # signal landing inside that window kills a hold that has not started the
  # attach and so has nothing to report - which is not the case under test.
  waited=0
  while [ -z "$(find "$dir/tmp" -name 'nm-attach-*.log' -size +0 2>/dev/null)" ]; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -lt 10 ] || fail "the hold never started; no attach log was written"
  done
  # The whole process GROUP, which setsid made the hold the leader of. Signalling
  # only the bash pid would be deferred until the attach it is blocked on returns,
  # because bash finishes a foreground command before it runs a trap - and killing
  # the group is what a sweep or the OOM killer does anyway.
  kill -TERM -"$pid" 2>/dev/null || fail "could not signal the hold's process group at $pid"
  await_status "$dir" "$FIXTURE_TASK" 15 || fail "a killed hold reported nothing at all"
  line=$(status_of "$dir" "$FIXTURE_TASK")
  case "$line" in
    "blocked [key=nm-run]: "*) ;;
    *) fail "a hold killed before it classified must still block, got: $line" ;;
  esac
  assert_contains "$line" 'stopped before it could report' "the line did not say the hold never reported"
  [ ! -e "$dir/home/state/$FIXTURE_TASK.nm-attach" ] \
    || fail "the killed hold left its liveness marker behind"
  pass "attach: a hold killed before it classified still reports, and clears its marker"
}

test_a_vanished_tool_still_reports() {
  local dir line
  # The other half of the same guarantee, on the path that does reach the
  # classifier: the tool itself is gone by the time `axi status` is read, so
  # nothing can be learned about the run - and that still has to wake firstmate
  # rather than go quiet.
  dir=$(make_case tool-vanishes "$FIXTURE_TASK" "" 0 0)
  cat > "$dir/bin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/invocations"
find "$dir/bin" -name no-mistakes -delete
exit 0
SH
  chmod +x "$dir/bin/no-mistakes"
  run_attach "$dir" "$FIXTURE_TASK" >/dev/null || fail "attach refused"
  await_status "$dir" "$FIXTURE_TASK" 15 || fail "a vanished tool reported nothing at all"
  line=$(status_of "$dir" "$FIXTURE_TASK")
  case "$line" in
    blocked*) ;;
    *) fail "a hold that could learn nothing about the run must block, got: $line" ;;
  esac
  [ ! -e "$dir/home/state/$FIXTURE_TASK.nm-attach" ] \
    || fail "the hold left its liveness marker behind"
  pass "attach: a hold that could not read the run at all still blocks, and clears its marker"
}

# --- the refusals -----------------------------------------------------------

test_refuses_an_off_branch_working_directory() {
  local dir out rc=0
  dir=$(make_case off-branch "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 0)
  ( cd "$dir/repo" && git checkout -q -b some/other-branch )
  out=$(run_attach "$dir" "$FIXTURE_TASK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the wrapper accepted a working directory on the wrong branch"
  assert_contains "$out" "not fm/$FIXTURE_TASK" "the refusal did not name the branch it expected"
  [ ! -e "$dir/invocations" ] || fail "the wrapper attached anyway from the wrong branch"
  pass "attach: refuses a working directory that is not the task's own branch"
}

test_refuses_outside_a_git_worktree() {
  local dir out rc=0
  dir=$(make_case no-worktree "$FIXTURE_TASK" "" 0)
  out=$( cd "$dir/tmp" \
    && PATH="$dir/bin:$PATH" FM_HOME="$dir/home" FM_TASK_TMP_OVERRIDE="$dir/tmp" \
       "$ATTACH" "$FIXTURE_TASK" 2>&1 ) || rc=$?
  [ "$rc" -ne 0 ] || fail "the wrapper accepted a non-worktree working directory"
  assert_contains "$out" 'not a git worktree' "the refusal did not say why"
  pass "attach: refuses a working directory that is not a git worktree"
}

test_refuses_a_second_live_attach() {
  local dir out rc=0 pid
  dir=$(make_case second-attach "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 30)
  run_attach "$dir" "$FIXTURE_TASK" >/dev/null || fail "the first attach refused"
  pid=$(sed -n '1p' "$dir/home/state/$FIXTURE_TASK.nm-attach")
  out=$(run_attach "$dir" "$FIXTURE_TASK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a second attach was accepted while one was still live"
  assert_contains "$out" 'already running' "the refusal did not say a hold is already driving the run"
  assert_contains "$out" "$dir/tmp/nm-attach-" "the refusal did not point at the live log"
  kill "$pid" 2>/dev/null || true
  pass "attach: refuses a second attach while one is live, and points at its log"
}

test_a_dead_marker_does_not_block_a_fresh_attach() {
  local dir out
  dir=$(make_case stale-marker "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 0)
  # A pid that cannot be alive: the marker is the record of a hold that died
  # without cleaning up, and it must not strand the task.
  printf '%s\n%s\n' 999999999 "$dir/tmp/old.log" > "$dir/home/state/$FIXTURE_TASK.nm-attach"
  out=$(run_attach "$dir" "$FIXTURE_TASK" 2>&1) || fail "a dead marker blocked a fresh attach: $out"
  assert_contains "$out" 'attached in the background' "the fresh attach did not start"
  pass "attach: a marker left by a dead hold does not strand the task"
}

test_refuses_an_oversized_intent_with_the_measured_size() {
  local dir out rc=0 limit body raw
  dir=$(make_case oversize "$FIXTURE_TASK" "" 0)
  # Sized from the limit the wrapper reads, not from a number that happens to be
  # big today: one raw byte past the largest intent that fits in the base64 cap.
  limit=$(sed -n 's/^INTENT_B64_LIMIT=\([0-9]*\)$/\1/p' "$ATTACH")
  [ -n "$limit" ] || fail "could not read INTENT_B64_LIMIT from $ATTACH"
  raw=$(( limit / 4 ))
  body=$(head -c $(( raw * 3 + 1 )) /dev/zero | tr '\0' 'x')
  printf 'You are a crewmate.\n\n# Task\n%s\n\n# Setup\nnope.\n' "$body" \
    > "$dir/home/data/$FIXTURE_TASK/brief.md"
  out=$(run_attach "$dir" "$FIXTURE_TASK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an intent over the push-option limit was accepted"
  assert_contains "$out" "over the $limit-byte push-option limit" "the refusal did not name the limit"
  assert_contains "$out" 'bytes base64' "the refusal did not give the measured size"
  assert_contains "$out" '## Gate decisions' "the refusal did not name what to compact"
  [ ! -e "$dir/invocations" ] || fail "the wrapper started a run with an oversized intent"
  pass "attach: refuses an oversized intent with the measured size and what to compact"
}

test_an_intent_at_the_limit_is_accepted() {
  local dir out limit body raw
  dir=$(make_case at-limit "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 0)
  limit=$(sed -n 's/^INTENT_B64_LIMIT=\([0-9]*\)$/\1/p' "$ATTACH")
  raw=$(( limit / 4 ))
  body=$(head -c $(( raw * 3 )) /dev/zero | tr '\0' 'x')
  printf 'You are a crewmate.\n\n# Task\n%s\n\n# Setup\nnope.\n' "$body" \
    > "$dir/home/data/$FIXTURE_TASK/brief.md"
  out=$(run_attach "$dir" "$FIXTURE_TASK" 2>&1) || fail "an intent exactly at the limit was refused: $out"
  assert_contains "$out" 'attached in the background' "the boundary intent did not attach"
  pass "attach: an intent exactly at the limit is accepted, so the cap is not off by one"
}

test_the_intent_cap_stays_under_the_kernels_argv_limit() {
  local limit groups raw probe n
  # The intent reaches the detached half as ONE argv entry, and an argv payload
  # dies at its threshold rather than degrading. So the cap has to stay under the
  # kernel's per-argument limit, and that limit is MEASURED here rather than
  # written down: a hardcoded number would keep passing on exactly the day a cap
  # raise crossed the real one.
  limit=$(sed -n 's/^INTENT_B64_LIMIT=\([0-9]*\)$/\1/p' "$ATTACH")
  groups=$(( limit / 4 ))
  raw=$(( groups * 3 ))
  probe=0
  for n in 8192 16384 32768 65536 131072 262144; do
    /bin/true "$(head -c "$n" /dev/zero | tr '\0' 'x')" 2>/dev/null || break
    probe=$n
  done
  [ "$probe" -gt 0 ] || fail "could not measure this kernel's per-argument limit at all"
  [ "$raw" -lt "$probe" ] \
    || fail "the intent cap allows $raw raw bytes, which this kernel cannot pass on argv (measured safe at $probe)"
  pass "attach: the intent cap ($raw raw bytes) stays under this kernel's argv limit (measured safe at $probe)"
}

test_refuses_yes_in_a_respond() {
  local dir out rc spelling
  dir=$(make_case respond-yes "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 0)
  # Every spelling Cobra accepts. Missing one silently auto-resolves the ask-user
  # findings the captain owns, which is the whole reason it is refused here.
  for spelling in --yes --yes=true -y -yh; do
    rc=0
    out=$(run_attach "$dir" "$FIXTURE_TASK" --respond --action approve "$spelling" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$spelling was accepted"
    assert_contains "$out" 'auto-resolves every ask-user finding' \
      "the refusal of $spelling did not say why"
    [ ! -e "$dir/invocations" ] || fail "the wrapper responded anyway on $spelling"
  done
  # And an ordinary instruction value is not mistaken for one, even when it
  # contains the letter.
  rc=0
  out=$(run_attach "$dir" "$FIXTURE_TASK" --respond --action fix --findings r1 \
    --instructions 'Keep the 503-only retry: a 4xx is a caller bug and retrying it hides the bug, so yes to the split and no to a blanket retry-all.' 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a legitimate instruction containing 'yes' was refused: $out"
  pass "attach: refuses every --yes spelling, and does not mistake an instruction value for one"
}

test_refuses_a_fix_round_with_no_substantive_instructions() {
  local dir out rc=0
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping the instructions floor"; return; }
  dir=$(make_case respond-thin "$FIXTURE_TASK" "$NM_STALL_FIXTURES/axi-status-ci-advanced.toon" 0)
  out=$(run_attach "$dir" "$FIXTURE_TASK" --respond --action fix --findings r1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a fix round with no --instructions was accepted"
  assert_contains "$out" 'no --instructions' "the refusal was not the fix-instructions one"
  [ ! -e "$dir/invocations" ] || fail "the wrapper responded anyway"
  pass "attach: the fix-instructions floor still applies through the wrapper"
}

test_a_substantive_fix_round_is_sent_and_closes_the_gate() {
  local dir invocations status instructions
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  dir=$(make_case respond-ok "$FIXTURE_TASK" "$FIXTURES/axi-status-parked.toon" 0)
  instructions='The uploader deliberately retries only on 503 because a 4xx is a caller bug and retrying it hides the caller bug; keep that split, and do not reintroduce a blanket retry-all.'
  run_attach "$dir" "$FIXTURE_TASK" --respond --action fix --findings r1 --instructions "$instructions" >/dev/null \
    || fail "a substantive fix round was refused"
  await_status "$dir" "$FIXTURE_TASK" 15 2 || fail "the hold never classified its return"

  invocations=$(cat "$dir/invocations")
  assert_contains "$invocations" 'axi respond --action fix --findings r1' "the response did not reach the tool"
  assert_contains "$invocations" '--wait 3h' "the response hold did not carry the long wait"
  assert_not_contains "$invocations" 'axi run' "a response must not also start a run"

  # Sending the response is what answers the gate the previous hold opened, so
  # the keyed decision is closed at send time rather than left open behind the
  # new hold's own line.
  status=$(status_of "$dir" "$FIXTURE_TASK")
  case "$(printf '%s\n' "$status" | head -1)" in
    "resolved [key=nm-run]: responded to the gate"*) ;;
    *) fail "the send did not close the keyed gate decision, got: $(printf '%s\n' "$status" | head -1)" ;;
  esac
  pass "attach: a substantive fix round is sent with the long wait and closes the keyed gate"
}

test_rejects_an_unknown_argument() {
  local dir out rc=0
  dir=$(make_case bad-arg "$FIXTURE_TASK" "" 0)
  out=$(run_attach "$dir" "$FIXTURE_TASK" --wait 8m 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown argument was accepted"
  assert_contains "$out" 'expected --respond' "the refusal did not name the only accepted flag"
  pass "attach: rejects an unknown argument rather than passing it through"
}

# --- the PreToolUse denial that makes the wrapper the only route ------------

deny_code() {  # <command> -> the deny code, or "allow"
  local out
  out=$(node "$POLICY" --command "$1" 2>/dev/null) || { printf 'error'; return; }
  case "$out" in
    deny*) printf '%s' "$out" | cut -f2 ;;
    *) printf 'allow' ;;
  esac
}

test_the_gate_denies_every_raw_attach_form() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  local cmd
  # Leading env assignments, chained commands, a nested shell, and a
  # path-qualified program name are all forms a worker actually types, and each
  # is one the shell classifier has to see through.
  for cmd in \
    'no-mistakes axi run --intent x' \
    'no-mistakes axi run --intent x --wait 8m' \
    'no-mistakes axi respond --action approve' \
    'no-mistakes axi respond --action skip --step review' \
    'no-mistakes axi respond --action fix --findings r1 --instructions "a genuinely long instruction that clears the substance floor comfortably, naming the design reasoning and the principle to preserve"' \
    'FOO=1 no-mistakes axi run --intent x' \
    'cd /tmp && no-mistakes axi run --intent x' \
    'git status && no-mistakes axi respond --action approve' \
    'bash -c "no-mistakes axi run --intent x"' \
    '/usr/local/bin/no-mistakes axi run --intent x' \
    'no-mistakes axi run --intent="x"' \
    'no-mistakes axi run --intent "x --help y"'
  do
    [ "$(deny_code "$cmd")" = nm-raw-attach ] \
      || fail "the gate did not deny a raw attach: $cmd"
  done
  pass "gate: denies every raw axi run/respond form, including env prefixes, chains and nested shells"
}

test_the_gate_leaves_the_read_only_subcommands_alone() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  local cmd
  for cmd in \
    'no-mistakes axi status' \
    'no-mistakes axi status --run 01KZH6AZ75WXZG5JKQEMFBK6EJ' \
    'no-mistakes axi logs --step review --full' \
    'no-mistakes axi sync' \
    'no-mistakes axi abort' \
    'no-mistakes --help' \
    'no-mistakes --version' \
    'no-mistakes doctor' \
    'no-mistakes init' \
    'no-mistakes axi run --help' \
    'no-mistakes axi respond --help' \
    'no-mistakes axi run --intent x --help'
  do
    [ "$(deny_code "$cmd")" = allow ] || fail "the gate denied a command it must allow: $cmd"
  done
  pass "gate: axi status/logs/sync/abort, doctor, init and every --help stay allowed"
}

test_the_gate_never_denies_the_wrapper_itself() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  local cmd rc=0
  # The wrapper runs the raw command as a subprocess of a SCRIPT, which the hook
  # never sees: the payload it reads is the model's own command string. So the
  # only thing that has to hold is that the wrapper's own command string allows.
  for cmd in \
    "$ATTACH $FIXTURE_TASK" \
    "$ATTACH $FIXTURE_TASK --respond --action approve" \
    "$ATTACH $FIXTURE_TASK --respond --action fix --findings r1 --instructions 'why'"
  do
    [ "$(deny_code "$cmd")" = allow ] || fail "the gate denied the sanctioned wrapper: $cmd"
    "$CHECK" --command "$cmd" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "the transport denied the sanctioned wrapper: $cmd"
  done
  pass "gate: the wrapper's own command is never denied"
}

test_the_denial_names_the_exact_wrapper_command() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  local reason
  reason=$(node "$POLICY" --command 'no-mistakes axi run --intent x' | cut -f3-)
  assert_contains "$reason" "$ROOT/bin/fm-nm-attach.sh <task-id>" \
    "the denial did not give the absolute wrapper command for starting a run"
  assert_contains "$reason" '--respond --action <approve|fix|skip>' \
    "the denial did not give the wrapper command for answering a gate"
  assert_contains "$reason" 'axi status' "the denial did not say which subcommands remain allowed"
  pass "gate: the denial hands back the exact wrapper command, by absolute path"
}

test_the_fix_instructions_only_mode_allows_the_raw_attach() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  local out
  # The mode the wrapper calls: the raw-attach rule must not refuse the very
  # command the wrapper exists to run, while the substance floor still applies.
  out=$(node "$POLICY" --fix-instructions-only --command 'no-mistakes axi run --intent x')
  [ "$out" = allow ] || fail "--fix-instructions-only denied a raw run: $out"
  out=$(node "$POLICY" --fix-instructions-only --command 'no-mistakes axi respond --action approve')
  [ "$out" = allow ] || fail "--fix-instructions-only denied a non-fix response: $out"
  out=$(node "$POLICY" --fix-instructions-only --command 'no-mistakes axi respond --action fix --instructions short' | cut -f2)
  [ "$out" = fix-instructions-thin ] || fail "--fix-instructions-only lost the substance floor: $out"
  pass "gate: --fix-instructions-only keeps the floor without refusing the sanctioned attach"
}

test_the_transport_denies_on_the_claude_payload() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  command -v jq >/dev/null 2>&1 || { pass "jq not installed, skipping the stdin transport"; return; }
  local err out rc=0
  # Claude is the harness this fleet runs, and it ignores a PreToolUse deny when
  # stdout is non-empty, so --claude must keep stdout empty.
  err="$TMP_ROOT/claude-deny.err"
  out=$(printf '{"tool_input":{"command":"no-mistakes axi run --intent x"}}' \
    | "$CHECK" --claude 2>"$err") || rc=$?
  [ "$rc" -eq 2 ] || fail "the claude transport did not deny with exit 2, got $rc"
  [ -z "$out" ] || fail "the claude transport wrote to stdout on deny: $out"
  assert_contains "$(cat "$err")" '"permissionDecision":"deny"' "stderr did not carry the claude deny object"
  assert_contains "$(cat "$err")" 'nm-raw-attach' "the deny object did not carry the reason code"
  pass "gate: denies through the real claude stdin transport with stdout empty"
}

test_the_transport_denies_on_the_grok_payload() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  command -v jq >/dev/null 2>&1 || { pass "jq not installed, skipping the stdin transport"; return; }
  local out rc=0
  out=$(printf '{"toolInput":{"command":"no-mistakes axi respond --action approve"}}' \
    | "$CHECK" 2>/dev/null) || rc=$?
  [ "$rc" -eq 2 ] || fail "the grok transport did not deny with exit 2, got $rc"
  assert_contains "$out" '"decision":"deny"' "stdout did not carry the grok decision object"
  pass "gate: denies through the grok stdin transport"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$ATTACH" >/dev/null 2>&1 || fail "bin/fm-nm-attach.sh is not shellcheck-clean"
  pass "bin/fm-nm-attach.sh is shellcheck-clean"
}

test_returns_immediately_while_the_hold_still_blocks
test_the_hold_uses_a_long_wait_and_the_pinned_intent
test_the_recorded_pid_is_the_hold_even_with_job_control_on
test_the_wait_is_overridable
test_a_parked_gate_opens_a_keyed_decision
test_a_passed_run_closes_the_key
test_a_failed_run_replaces_the_key_with_a_blocker
test_an_elapsed_wait_is_a_declared_pause
test_an_unreachable_daemon_blocks_under_its_own_key
test_another_branchs_run_is_never_reported_as_this_task
test_no_run_at_all_blocks_rather_than_pausing
test_a_killed_follower_still_reports
test_a_vanished_tool_still_reports
test_refuses_an_off_branch_working_directory
test_refuses_outside_a_git_worktree
test_refuses_a_second_live_attach
test_a_dead_marker_does_not_block_a_fresh_attach
test_refuses_an_oversized_intent_with_the_measured_size
test_an_intent_at_the_limit_is_accepted
test_the_intent_cap_stays_under_the_kernels_argv_limit
test_refuses_yes_in_a_respond
test_refuses_a_fix_round_with_no_substantive_instructions
test_a_substantive_fix_round_is_sent_and_closes_the_gate
test_rejects_an_unknown_argument
test_the_gate_denies_every_raw_attach_form
test_the_gate_leaves_the_read_only_subcommands_alone
test_the_gate_never_denies_the_wrapper_itself
test_the_denial_names_the_exact_wrapper_command
test_the_fix_instructions_only_mode_allows_the_raw_attach
test_the_transport_denies_on_the_claude_payload
test_the_transport_denies_on_the_grok_payload
test_scripts_are_shellcheck_clean
