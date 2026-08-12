#!/usr/bin/env bash
# Behavior tests for the unactioned-direct-report guard.
#
# The failure this guards against, measured on 2026-07-30: crew
# fm-handoff-skill-h6 wrote `done:` at 14:57, its wake was durably queued and
# correctly drained at 15:08, firstmate read it, and then did not act on it until
# 15:17. Twenty minutes with a finished ship task sitting unanswered and no alarm
# of any kind, because a DRAINED wake leaves no trace - draining is what destroys
# the evidence - and both existing guards only assert that supervision machinery
# is alive, never that a delivered state was handled.
#
# So the cases below are written as the incident and its false-alarm twin, not as
# code-path assertions:
#   INCIDENT   - an unacked `done:` past the grace window must alarm, by id.
#   CAPTAIN    - a `needs-decision:` firstmate has already relayed must stay
#                silent forever, because it is legitimately waiting on the
#                captain. This is the case that decides whether the guard is
#                worth having: data/learnings.md records a banner that became
#                noise, was learned past, and missed the next genuine one.
# The rest pin the mechanism that separates those two: the ack fingerprint
# re-arming on any new status append, the crew-state confirm clearing a stale
# log, `unknown` NOT clearing, and the auto-ack points that keep firstmate from
# having to remember a second command.
#
# Hermetic: a temp firstmate home, a stub crew-state reader, and FM_ACK_NOW to
# move the clock instead of sleeping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-ack-lib.sh
. "$ROOT/bin/fm-ack-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-unactioned-guard)

# Twenty minutes, the incident's own duration, is the clock offset every case
# uses: far past the 600s default grace, so "did it alarm" is never a timing race.
INCIDENT_SECS=1200

# A firstmate home with one in-flight task. Echoes the home path.
# The stub crew-state reader answers from FM_TEST_CREW_STATE so a case can say
# what the authoritative current-state read reports without a real worktree,
# no-mistakes install, or live pane.
make_home() {  # <name> <task-id>
  local home="$TMP_ROOT/$1" id=$2
  mkdir -p "$home/state"
  cat > "$home/crew-state-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_CREW_STATE:-state: done · source: status-log · finished}"
SH
  chmod +x "$home/crew-state-stub"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '%s\n' "$home"
}

# Append one status line, exactly as a crewmate does.
crew_reports() {  # <home> <task-id> <line>
  printf '%s\n' "$3" >> "$1/state/$2.status"
}

# Run fm-guard.sh with the clock advanced <age> seconds past now.
run_guard() {  # <home> <age-seconds> [extra env assignments...]
  local home=$1 age=$2
  shift 2
  env "$@" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_ACK_NOW="$(( $(date +%s) + age ))" \
    FM_CREW_STATE_BIN="$home/crew-state-stub" \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_ack() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_CREW_STATE_BIN="$home/crew-state-stub" \
    "$ROOT/bin/fm-ack.sh" "$@" 2>&1
}

# --- the incident ------------------------------------------------------------

# Reproduce 2026-07-30 end to end: the crew reports done, the wake is delivered
# and drained (modelled by there being nothing left in the queue), firstmate does
# nothing, and twenty minutes later the very next fleet command must alarm.
test_incident_reproduction() {
  local home id out
  id=fm-handoff-skill-h6
  home=$(make_home incident "$id")
  crew_reports "$home" "$id" "working: picked up the brief"
  crew_reports "$home" "$id" "done: implementation committed on fm/$id"

  # The wake was drained, so the queue is empty and the watcher is irrelevant to
  # this alarm. Nothing else in the fleet has any evidence left.
  assert_absent "$home/state/.wake-queue" "the drained-wake precondition must leave no queue record"

  # At the moment of the report, firstmate has not had a chance yet: silent.
  out=$(run_guard "$home" 0)
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" \
    "guard alarmed on a done: that had only just landed - inside the grace window it must stay silent"

  # Twenty minutes later, unacted on: this is the alarm that did not exist.
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "guard did not alarm on a finished ship task left unactioned for twenty minutes"
  assert_contains "$out" "$id" "unactioned banner did not name the task"
  assert_contains "$out" "done" "unactioned banner did not name the reported state"
  assert_contains "$out" "implementation committed" \
    "unactioned banner did not quote the crew's own status line as evidence"
  assert_contains "$out" "wake was delivered and then dropped" \
    "banner must distinguish itself from a watcher-liveness problem"
  assert_contains "$out" "bin/fm-ack.sh" "banner did not print how to record the action"

  # And it must keep alarming, not fire once and forget.
  out=$(run_guard "$home" $((INCIDENT_SECS * 3)))
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "the alarm must persist while the state stays unactioned, not fire once"
  pass "fm-guard: a done: left unactioned for twenty minutes alarms by id, with the crew's own line as evidence"
}

# --- the false-alarm twin ----------------------------------------------------

# A needs-decision legitimately sits for as long as the captain takes to answer.
# Once firstmate has relayed it, the ball is with the captain and the guard must
# be silent indefinitely. If this case fails the guard is worthless: it would fire
# on every open captain decision in the fleet until it was learned past.
test_captain_wait_never_alarms() {
  local home id out
  id=api-shape-k4
  home=$(make_home captain-wait "$id")
  crew_reports "$home" "$id" "needs-decision: sync or async client - both compile"

  # Unrelayed and past grace, it correctly alarms: firstmate owes the relay.
  out=$(FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) (ask-user: captain decision)' \
    run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "an unrelayed needs-decision past grace must alarm - firstmate still owes the relay"

  # Firstmate relays it to the captain and records that.
  out=$(run_ack "$home" "$id" "relayed to captain")
  assert_contains "$out" "acked: $id" "fm-ack did not confirm the record"

  # Now it is the captain's turn. Silent at twenty minutes, at an hour, and at a
  # full day - raw elapsed time must never resurrect it.
  local age
  for age in "$INCIDENT_SECS" 3600 86400; do
    out=$(FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) (ask-user: captain decision)' \
      run_guard "$home" "$age")
    assert_not_contains "$out" "UNACTIONED DIRECT REPORT" \
      "guard alarmed on a decision already relayed to the captain after ${age}s - false alarms make this guard worthless"
  done
  pass "fm-guard: a decision already relayed to the captain never alarms, however long the captain takes"
}

# --- what re-arms the ack ----------------------------------------------------

# The ack covers one situation, not the task forever. A crew that appends a NEW
# event owes a NEW action, so the fingerprint must go stale on any append. This is
# the difference between a marker and a mute button.
test_ack_rearms_on_new_status() {
  local home id out
  id=ship-flow-m2
  home=$(make_home rearm "$id")
  crew_reports "$home" "$id" "done: implementation committed"
  run_ack "$home" "$id" "triggered validation" >/dev/null

  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" "ack did not silence the state it was recorded for"

  # Validation finishes; the crew reports a materially different done that owes
  # a different action (record the PR, relay it to the captain).
  crew_reports "$home" "$id" "done: PR https://github.com/o/r/pull/7 checks green"
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "a new status event must re-arm the alarm - an ack must not mute the task permanently"
  assert_contains "$out" "checks green" "re-armed banner did not quote the new event"
  pass "fm-ack: an ack covers one reported situation; the next status append re-arms the alarm"
}

# --- what the crew-state confirm is for --------------------------------------

# fm-crew-state.sh documents the status log going stale exactly one way: a
# needs-decision/blocked line stays behind after the gate resolved and the run
# resumed. Confirming against the authoritative run-step is what stops that
# becoming a standing false alarm.
test_confirm_clears_a_resumed_crew() {
  local home id out
  id=stale-log-p9
  home=$(make_home confirm "$id")
  crew_reports "$home" "$id" "blocked: needs a credential"

  out=$(FM_TEST_CREW_STATE='state: working · source: run-step · validating (running)' \
    run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" \
    "guard alarmed on a stale blocked: line whose run has provably resumed"

  out=$(FM_TEST_CREW_STATE='state: paused · source: status-log · upstream release lands Friday' \
    run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" \
    "guard alarmed on a crew whose current state is a declared external wait"
  pass "fm-crew-state confirm: a provably resumed or deliberately paused crew clears the candidate"
}

# An unreadable or unknown current state is inconclusive, NOT exoneration. A crew
# whose pane died after reporting done: reads `unknown`, and that is precisely the
# abandoned-work case this guard exists for; clearing on it would reintroduce the
# incident with extra steps.
test_unknown_state_does_not_clear() {
  local home id out
  id=dead-pane-t3
  home=$(make_home unknown "$id")
  crew_reports "$home" "$id" "done: fix implemented"

  out=$(FM_TEST_CREW_STATE='state: unknown · source: none · worktree gone (torn down?)' \
    run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "an unknown current state must not clear an unactioned done: - it is inconclusive, not proof the work was handled"

  # A crew-state reader that fails outright is inconclusive the same way.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/crew-state-stub"
  chmod +x "$home/crew-state-stub"
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "a failed current-state read must not clear an unactioned done:"
  pass "fm-ack-lib: only working/paused clear a candidate; unknown and unreadable stay alarming"
}

# --- states that owe firstmate nothing ---------------------------------------

test_non_owed_states_stay_silent() {
  local home id out line
  id=quiet-w1
  home=$(make_home quiet "$id")
  # Each of these is either firstmate-irrelevant or explicitly "leave me alone".
  while IFS='|' read -r line label; do
    [ -n "$line" ] || continue
    : > "$home/state/$id.status"
    crew_reports "$home" "$id" "$line"
    out=$(FM_TEST_CREW_STATE='state: working · source: pane · harness busy' \
      run_guard "$home" "$INCIDENT_SECS")
    assert_not_contains "$out" "UNACTIONED DIRECT REPORT" "guard alarmed on $label"
  done <<'ROWS'
working: rebasing onto main|an ordinary progress note
paused: waiting on the upstream 2.0 release|a declared external wait
resolved: captain chose the async client|a decision-closing event
ROWS
  pass "fm-guard: working, declared pauses, and decision-closing events owe firstmate nothing and stay silent"
}

# --- auto-ack: firstmate must not have to remember a second command ----------

# Delivering an instruction to a task IS acting on it. fm-send acks so the common
# path (trigger validation, relay a decision back to a crew, steer a blocker)
# needs no discipline at all.
test_fm_send_auto_acks() {
  local home id fakebin out
  id=steered-v5
  home=$(make_home send "$id")
  crew_reports "$home" "$id" "blocked: which config file wins"
  fakebin=$(fm_fakebin "$home")
  # A tmux that answers every probe affirmatively and reports an empty composer,
  # so the send path completes without a real terminal.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *pane_id*|*window_id*) printf '%%1\n'; exit 0 ;;
  *capture-pane*) printf '> \n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 \
    FM_CREW_STATE_BIN="$home/crew-state-stub" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-send.sh" "fm-$id" "the repo-level config wins" 2>&1 || true)
  assert_present "$home/state/$id.acted" \
    "fm-send did not record an ack after delivering an instruction to the task (out: $out)"

  out=$(FM_TEST_CREW_STATE='state: blocked · source: status-log · which config file wins' \
    run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" \
    "guard alarmed on a blocker firstmate had already steered through fm-send"
  pass "fm-send: delivering an instruction to a task auto-acks its current state"
}

# Recording the PR and arming the merge poll is the action a PR-ready done: owes,
# so the task must go quiet while it legitimately waits on review or merge.
test_fm_pr_check_auto_acks() {
  local home id out
  id=pr-ready-z8
  home=$(make_home prcheck "$id")
  crew_reports "$home" "$id" "done: PR https://github.com/o/r/pull/3 checks green"

  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CREW_STATE_BIN="$home/crew-state-stub" \
    "$ROOT/bin/fm-pr-check.sh" "$id" "https://github.com/o/r/pull/3" >/dev/null 2>&1
  assert_present "$home/state/$id.acted" "fm-pr-check did not ack the PR-ready state it just armed"

  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" \
    "guard alarmed on a PR-ready task already recorded and armed for merge polling"
  pass "fm-pr-check: arming the merge poll acks the PR-ready state"
}

# --- read-only sessions ------------------------------------------------------

# Another session holds the fleet lock: report the condition, never hand this
# session a repair command, and leave no cache file behind for the lock holder.
test_read_only_mode() {
  local home id out
  id=readonly-q2
  home=$(make_home readonly "$id")
  crew_reports "$home" "$id" "failed: pipeline could not push"

  out=$(run_guard "$home" "$INCIDENT_SECS" FM_GUARD_READ_ONLY=1)
  assert_contains "$out" "UNACTIONED DIRECT REPORT" "read-only guard dropped the unactioned alarm"
  assert_contains "$out" "read-only session should report it" \
    "read-only guard did not explain who owns the action"
  assert_not_contains "$out" "bin/fm-ack.sh" "read-only guard offered a state-changing repair command"
  assert_absent "$home/state/.unactioned-$id" \
    "read-only guard wrote a confirm cache into state owned by the locking session"
  pass "fm-guard: read-only sessions report the unactioned state without repair commands or cache writes"
}

# --- the confirm is not paid in a healthy fleet ------------------------------

# The cheap filter (last status line, verb, mtime, size, ack file) gates every
# subprocess. A healthy fleet must never fork the crew-state reader, or this
# guard would tax fm-send on every call.
test_confirm_is_gated_by_the_cheap_filter() {
  local home id calls
  id=cheap-n7
  home=$(make_home cheap "$id")
  cat > "$home/crew-state-stub" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "$home/confirm-calls"
printf '%s\n' "\${FM_TEST_CREW_STATE:-state: done · source: status-log · finished}"
SH
  chmod +x "$home/crew-state-stub"
  : > "$home/confirm-calls"

  # Owed verb but inside the grace window: no confirm.
  crew_reports "$home" "$id" "done: implementation committed"
  run_guard "$home" 0 >/dev/null
  calls=$(wc -l < "$home/confirm-calls")
  [ "$calls" -eq 0 ] || fail "guard forked the current-state reader inside the grace window ($calls calls)"

  # Past grace and unacked: exactly the case worth paying for.
  run_guard "$home" "$INCIDENT_SECS" >/dev/null
  calls=$(wc -l < "$home/confirm-calls")
  [ "$calls" -ge 1 ] || fail "guard never confirmed a genuinely unactioned candidate"

  # Acked: back to zero forks however long it sits.
  : > "$home/confirm-calls"
  run_ack "$home" "$id" "triggered validation" >/dev/null
  run_guard "$home" $((INCIDENT_SECS * 5)) >/dev/null
  calls=$(wc -l < "$home/confirm-calls")
  [ "$calls" -eq 0 ] || fail "guard forked the current-state reader for an acked task ($calls calls)"
  pass "fm-ack-lib: the crew-state confirm is paid only for a candidate that already passed the cheap filter"
}

# --- fm-ack surface ----------------------------------------------------------

test_ack_cli() {
  local home id out status
  id=cli-r6
  home=$(make_home ackcli "$id")
  crew_reports "$home" "$id" "done: implementation committed"
  # --list answers the same question the banner does, so it needs the same clock.
  export FM_ACK_NOW=$(( $(date +%s) + INCIDENT_SECS ))

  out=$(run_ack "$home" --list)
  assert_contains "$out" "$id" "--list did not report the unactioned task"

  out=$(run_ack "$home" no-such-task-x9 "whatever") && status=0 || status=$?
  expect_code 1 "$status" "fm-ack must refuse an id with no metadata"
  assert_contains "$out" "no metadata" "fm-ack refusal did not explain why"
  assert_absent "$home/state/no-such-task-x9.acted" "fm-ack wrote a record for an unknown task"

  run_ack "$home" "$id" "triggered validation" >/dev/null
  out=$(run_ack "$home" --list)
  assert_contains "$out" "no unactioned direct reports" "--list still reported an acked task"
  unset FM_ACK_NOW
  pass "fm-ack: records by id, refuses unknown ids, and lists what is still owed"
}

# --- teardown leaves nothing behind ------------------------------------------

test_teardown_removes_the_record() {
  local home id
  id=cleanup-y4
  home=$(make_home teardown "$id")
  crew_reports "$home" "$id" "done: implementation committed"
  run_guard "$home" "$INCIDENT_SECS" >/dev/null   # populates the confirm cache
  run_ack "$home" "$id" "triggered validation" >/dev/null
  assert_present "$home/state/$id.acted" "precondition: the ack record must exist"

  # fm-teardown's own state sweep is the contract under test; drive just that
  # line's effect the way teardown does, then assert both artifacts are named.
  assert_grep "\$ID.acted" "$ROOT/bin/fm-teardown.sh" \
    "fm-teardown must remove the per-task ack record with the rest of the task's state"
  assert_grep ".unactioned-\$ID" "$ROOT/bin/fm-teardown.sh" \
    "fm-teardown must remove the per-task confirm cache with the rest of the task's state"
  assert_grep "\$child_id.acted" "$ROOT/bin/fm-teardown.sh" \
    "secondmate teardown must remove each child's ack record too"
  pass "fm-teardown: the ack record and confirm cache are cleaned up with the task's other state"
}

# --- the remaining ack site --------------------------------------------------

# The local-only merge is the action a `done: ready in branch` owes. It is
# asserted at the source level rather than driven end to end: exercising it needs
# a real project repo, worktree, and fast-forwardable branch, which
# tests/fm-teardown.test.sh already owns, and the ack behavior itself is proven
# functionally by the fm-send and fm-pr-check cases above.
# bin/fm-pr-merge.sh deliberately has no ack: bin/fm-pr-check.sh already acked
# the PR-ready state before it, and teardown removes the record after.
test_merge_local_acks() {
  assert_grep "fm_ack_record \"\$STATE\" \"\$ID\"" "$ROOT/bin/fm-merge-local.sh" \
    "the approved local-only merge must ack the state it just satisfied"
  assert_grep 'fm-ack-lib.sh' "$ROOT/bin/fm-merge-local.sh" \
    "fm-merge-local must source the ack library it calls"
  pass "fm-merge-local: an approved local merge acks the ready-in-branch state"
}

# --- the confirm cannot wedge a turn, and cannot silence one -----------------

# This predicate now runs at turn end, and that hook is the one place a hang
# wedges a whole session. The current-state reader shells out to panes and to
# no-mistakes, so it is not a call that can be assumed to return.
#
# The bound must fail the SAFE way. A timeout is not evidence the worker moved
# on, so it has to read as unconfirmed and still alarm - a bound that swallowed
# the finding would end turns silently on exactly the case it was added for.
test_a_wedged_current_state_read_still_alarms_and_still_returns() {
  local home id out start elapsed
  id=wedge-w8
  home=$(make_home wedge "$id")
  crew_reports "$home" "$id" "done: implementation committed"
  # A reader that never returns, which is what a wedged pane probe looks like.
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$home/crew-state-stub"
  chmod +x "$home/crew-state-stub"

  start=$(date +%s)
  out=$(run_guard "$home" "$INCIDENT_SECS" FM_ACK_CONFIRM_TIMEOUT=2)
  elapsed=$(( $(date +%s) - start ))

  [ "$elapsed" -lt 60 ] || fail "the guard hung for ${elapsed}s on a wedged current-state read - at turn end that wedges the session"
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "a current-state read that timed out silenced the alarm - a bound may cost accuracy about the worker, never the finding"
  assert_contains "$out" "$id" "the alarm did not name the task whose confirm timed out"
  pass "fm-ack-lib: a wedged current-state read is bounded, and times out into alarming rather than into silence"
}

# --- the forced sweep --------------------------------------------------------

# Give <home> a signing key, so exemptions can be minted there.
give_key() {  # <home>
  mkdir -p "$1/config"
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$1/config/ci-waiver-secret"
  chmod 600 "$1/config/ci-waiver-secret"
}

run_monitor() {  # <home> <age-seconds> [args...]
  local home=$1 age=$2
  shift 2
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_ACK_NOW="$(( $(date +%s) + age ))" \
    FM_CREW_STATE_BIN="$home/crew-state-stub" \
    "$ROOT/bin/fm-monitor.sh" "$@" 2>&1
}

# The captain's question is "have you gone over everything", and only a render
# that accounts for every task can answer it. A surface that printed just the
# problems is indistinguishable from one that did not look, which is the failure
# the captain ruled on when he required every class named on every render
# including zeros.
test_sweep_accounts_for_every_task_and_every_class() {
  local home out status
  home=$(make_home sweep-all quiet-one)
  fm_write_meta "$home/state/owed-two.meta" "window=x" "kind=ship"
  fm_write_meta "$home/state/acked-three.meta" "window=x" "kind=ship"
  crew_reports "$home" quiet-one "working: still going"
  crew_reports "$home" owed-two "done: implementation committed"
  crew_reports "$home" acked-three "needs-decision: sync or async"
  run_ack "$home" acked-three "relayed to captain" >/dev/null

  out=$(run_monitor "$home" "$INCIDENT_SECS") && status=0 || status=$?
  expect_code 1 "$status" "a sweep that found an unactioned report must not exit 0"

  # Every task named, whatever class it fell in.
  assert_contains "$out" "quiet-one" "sweep omitted a task that owed nothing - then it did not go over everything"
  assert_contains "$out" "owed-two" "sweep omitted the unactioned task"
  assert_contains "$out" "acked-three" "sweep omitted the task firstmate had already acted on"
  assert_contains "$out" "3 task(s) supervised" "sweep did not state how many tasks it covered"

  # Every class named on the counts line, including the ones that are zero.
  local class
  for class in needs-action just-reported acted moved-on exempt nothing-owed; do
    assert_contains "$out" "$class" "counts line dropped the '$class' class - an absent class reads as 'none' and as 'not checked' identically"
  done
  assert_contains "$out" "exempt 0" "a zero class must be printed as a zero, not omitted"
  pass "fm-monitor: the sweep names every supervised task and every class, zeros included"
}

# The sweep and the turn-end block must never disagree, which is only guaranteed
# if they read the same predicate. Assert they agree on the same fleet rather
# than that each is individually plausible.
test_sweep_and_alarm_agree() {
  local home id sweep alarm
  id=agree-a1
  home=$(make_home agree "$id")
  crew_reports "$home" "$id" "done: implementation committed"

  sweep=$(run_monitor "$home" "$INCIDENT_SECS")
  alarm=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$sweep" "NEEDS ACTION" "sweep did not flag what the alarm flags"
  assert_contains "$alarm" "UNACTIONED DIRECT REPORT" "alarm did not fire on what the sweep flags"

  run_ack "$home" "$id" "triggered validation" >/dev/null
  sweep=$(run_monitor "$home" "$INCIDENT_SECS")
  alarm=$(run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$sweep" "NEEDS ACTION" "sweep still demanded action on an acked task the alarm had gone quiet on"
  assert_not_contains "$alarm" "UNACTIONED DIRECT REPORT" "alarm fired on a task the sweep called clear"
  pass "fm-monitor: the render and the alarm answer from one predicate and cannot disagree"
}

# The same agreement, for the one condition no reported state can express. A
# frozen validation reports NOTHING - its worker is alive and busy and its status
# log gains no line - so every class above calls that task quiet while the
# turn-end guard blocks on it. A render that answered "have you gone over
# everything" with silence there would be answering wrongly, so it names the
# count on every run, zero included.
test_sweep_names_a_stalled_validation_the_guard_blocks_on() {
  local home id sweep status threshold frozen now
  id=stalled-s1
  home=$(make_home stalled "$id")
  threshold=$(env -u FM_NM_STALL_SECS "$ROOT/bin/fm-nm-stall.sh" --threshold)
  now=$(date +%s)
  frozen=$((threshold * 2))

  sweep=$(run_monitor "$home" 0) && status=0 || status=$?
  expect_code 0 "$status" "precondition: a fleet with nothing frozen must sweep clean"
  assert_contains "$sweep" "MONITOR VALIDATIONS: 0 stalled" \
    "the render omitted the stalled-validation count when there were none - absent reads the same as unchecked"

  printf '%s\t%s\t0\tci\trun=A;status=running;steps=ci:running:0\n' \
    "$((now - frozen))" "$now" > "$home/state/$id.nm-progress"

  sweep=$(run_monitor "$home" 0) && status=0 || status=$?
  expect_code 1 "$status" "a sweep that found a stalled validation must not exit 0"
  assert_contains "$sweep" "MONITOR VALIDATIONS: 1 stalled" "the render did not count the stalled validation"
  assert_contains "$sweep" "$id" "the render did not name the task whose validation is frozen"
  assert_contains "$sweep" '"ci" step' "the render did not name the frozen step"
  pass "fm-monitor: a stalled validation is named and counted, never rendered as a quiet task"
}

# --- the per-task exemption --------------------------------------------------

# The captain was explicit that a blanket on/off is not enough: he must be able
# to say "don't monitor this one".
test_signed_exemption_silences_one_task_only() {
  local home out
  home=$(make_home exempt-one exempt-me)
  give_key "$home"
  fm_write_meta "$home/state/watch-me.meta" "window=x" "kind=ship"
  crew_reports "$home" exempt-me "blocked: vendor outage, captain is handling it"
  crew_reports "$home" watch-me "done: implementation committed"

  run_monitor "$home" 0 --exempt exempt-me --reason "captain is chasing the vendor by hand" >/dev/null

  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "exempt-me" "an exempted task must not alarm"
  assert_contains "$out" "watch-me" "an exemption on one task silenced another - it must be per task, not a blanket switch"
  pass "fm-monitor: a signed exemption silences exactly the one task it names"
}

# The captain's own test: could the entity being checked have produced the thing
# being checked. A worker appends its own status lines into this same directory
# and firstmate writes here constantly, so a plain marker file would be
# self-exemption by one append.
test_an_unsigned_record_is_not_an_exemption() {
  local home id out f
  id=forge-f1
  home=$(make_home forge "$id")
  give_key "$home"
  crew_reports "$home" "$id" "done: implementation committed"
  f="$home/state/$id.monitor-exempt"

  # Every shape something without the key could plausibly write.
  local rec label
  while IFS='|' read -r rec label; do
    [ -n "$label" ] || continue
    printf '%s\n' "$rec" > "$f"
    out=$(run_guard "$home" "$INCIDENT_SECS")
    assert_contains "$out" "UNACTIONED DIRECT REPORT" \
      "guard was silenced by $label - anything firstmate or a worker can type must not grant an exemption"
  done <<'ROWS'
exempt|a bare word
1	deadbeef	because I said so|a short, obviously invalid signature
1	00000000000000000000000000000000000000000000000000000000000000ff	because I said so|a well-formed but wrong 64-hex signature
ROWS

  # And a real signature lifted from a DIFFERENT task cannot be replayed here,
  # because the task id is inside the signed payload.
  fm_write_meta "$home/state/other-o2.meta" "window=x" "kind=ship"
  run_monitor "$home" 0 --exempt other-o2 --reason "a genuine exemption elsewhere" >/dev/null
  cp "$home/state/other-o2.monitor-exempt" "$f"
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "a real exemption copied from another task silenced this one - the task id must be bound into the signature"
  pass "fm-ack-lib: only a record signed for THIS task with this home's key is an exemption"
}

# The stated reason is what the captain will read months later and what session
# start announces. If it could be rewritten after signing, the record would
# claim an authorization the captain never gave.
test_the_reason_is_bound_to_the_signature() {
  local home id out rec sig
  id='reason-r2'
  home=$(make_home reason "$id")
  give_key "$home"
  crew_reports "$home" "$id" "done: implementation committed"
  run_monitor "$home" 0 --exempt "$id" --reason "vendor outage until Friday" >/dev/null
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" "precondition: the genuine exemption must hold"

  # Keep the signature, rewrite what it claims to authorize.
  IFS= read -r rec < "$home/state/$id.monitor-exempt"
  sig=$(printf '%s' "$rec" | cut -f2)
  printf '1\t%s\t%s\n' "$sig" "permanently exempt, no reason needed" > "$home/state/$id.monitor-exempt"
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "the reason was rewritten under a valid signature and the exemption still held"
  pass "fm-monitor: an exemption's stated reason cannot be edited after it was granted"
}

# An exemption is durable state, not a session's memory: it has to survive a
# restart, which here means a completely fresh process reading only what is on
# disk. Every invocation in this suite is already a fresh process, so this asserts
# the record is what carries it - and that no in-memory clock or cache is needed.
test_exemption_survives_a_restart() {
  local home id out age
  id=restart-s3
  home=$(make_home restart "$id")
  give_key "$home"
  crew_reports "$home" "$id" "blocked: waiting on the captain's vendor call"
  run_monitor "$home" 0 --exempt "$id" --reason "captain is handling this one directly" >/dev/null

  # Far past any window, across many separate processes.
  for age in "$INCIDENT_SECS" 86400 604800; do
    out=$(run_guard "$home" "$age")
    assert_not_contains "$out" "UNACTIONED DIRECT REPORT" \
      "the exemption stopped holding after ${age}s in a fresh process - it must be carried by the record, not by a live session"
  done
  out=$(run_monitor "$home" 604800 --list-exempt)
  assert_contains "$out" "$id" "--list-exempt lost a standing exemption"
  assert_contains "$out" "captain is handling this one directly" "--list-exempt dropped the signed reason"
  pass "fm-monitor: an exemption is durable and holds across restarts until it is cleared"
}

# Without a key nothing can be signed. Writing an unsigned record anyway would
# be strictly worse than refusing: it would look like an exemption to a human
# reading state/ and be exactly the self-granted marker the design forbids.
test_exemption_refused_without_a_key() {
  local home id out status
  id=nokey-n4
  home=$(make_home nokey "$id")
  crew_reports "$home" "$id" "done: implementation committed"

  out=$(run_monitor "$home" 0 --exempt "$id" --reason "no key here") && status=0 || status=$?
  expect_code 2 "$status" "fm-monitor must refuse to exempt when it cannot sign"
  assert_contains "$out" "cannot be signed" "the refusal did not say why"
  assert_absent "$home/state/$id.monitor-exempt" "a refused exemption still wrote a record"

  # And a key that disappears later does not silence the fleet: an exemption that
  # cannot be verified is not an exemption.
  give_key "$home"
  run_monitor "$home" 0 --exempt "$id" --reason "signed while the key existed" >/dev/null
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" "precondition: the signed exemption must hold"
  mv "$home/config/ci-waiver-secret" "$home/config/ci-waiver-secret.gone"
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" \
    "removing the key silenced the alarm - an unverifiable exemption must fall back to NOT exempt"
  pass "fm-monitor: no key means no exemption can be granted, and no key means none can be believed"
}

# An exemption suppresses an alarm. It must not remove the task from the
# accounting, or a self-granted one could quietly drop a task out of supervision.
test_an_exemption_is_never_silent() {
  local home id out
  id=loud-l5
  home=$(make_home loud "$id")
  give_key "$home"
  crew_reports "$home" "$id" "blocked: vendor outage"
  run_monitor "$home" 0 --exempt "$id" --reason "captain is chasing the vendor" >/dev/null

  # Still on the render, with its reason, even in the trimmed view.
  out=$(run_monitor "$home" "$INCIDENT_SECS")
  assert_contains "$out" "EXEMPT by the captain" "the sweep hid an exempted task"
  assert_contains "$out" "captain is chasing the vendor" "the sweep hid the exemption's stated reason"
  out=$(run_monitor "$home" "$INCIDENT_SECS" --quiet)
  assert_contains "$out" "EXEMPT by the captain" \
    "the trimmed view hid the exemption - a standing suppression of a safety check must stay in front of the captain"

  # And announced at session start without anyone asking for it.
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_contains "$out" "MONITOR_EXEMPT: $id" "session start did not announce a standing exemption"
  assert_contains "$out" "captain is chasing the vendor" "the session-start announcement dropped the reason"
  pass "fm-monitor: an exemption is announced on every sweep and at every session start, never silent"
}

test_unexempt_restores_monitoring() {
  local home id out
  id=undo-u6
  home=$(make_home undo "$id")
  give_key "$home"
  crew_reports "$home" "$id" "done: implementation committed"
  run_monitor "$home" 0 --exempt "$id" --reason "temporarily out of scope" >/dev/null
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_not_contains "$out" "UNACTIONED DIRECT REPORT" "precondition: the exemption must hold"

  run_monitor "$home" 0 --unexempt "$id" >/dev/null
  assert_absent "$home/state/$id.monitor-exempt" "--unexempt left the record in place"
  out=$(run_guard "$home" "$INCIDENT_SECS")
  assert_contains "$out" "UNACTIONED DIRECT REPORT" "--unexempt did not restore the alarm"
  pass "fm-monitor: clearing an exemption puts the task straight back under the alarm"
}

test_exemption_record_is_torn_down_with_the_task() {
  assert_grep "\$ID.monitor-exempt" "$ROOT/bin/fm-teardown.sh" \
    "fm-teardown must remove the per-task monitoring exemption with the rest of the task's state"
  assert_grep "\$child_id.monitor-exempt" "$ROOT/bin/fm-teardown.sh" \
    "secondmate teardown must remove each child's exemption record too"
  pass "fm-teardown: a finished task's exemption is cleaned up with its other state"
}

test_incident_reproduction
test_captain_wait_never_alarms
test_ack_rearms_on_new_status
test_confirm_clears_a_resumed_crew
test_unknown_state_does_not_clear
test_non_owed_states_stay_silent
test_fm_send_auto_acks
test_fm_pr_check_auto_acks
test_read_only_mode
test_confirm_is_gated_by_the_cheap_filter
test_ack_cli
test_teardown_removes_the_record
test_merge_local_acks
test_a_wedged_current_state_read_still_alarms_and_still_returns
test_sweep_accounts_for_every_task_and_every_class
test_sweep_and_alarm_agree
test_sweep_names_a_stalled_validation_the_guard_blocks_on
test_signed_exemption_silences_one_task_only
test_an_unsigned_record_is_not_an_exemption
test_the_reason_is_bound_to_the_signature
test_exemption_survives_a_restart
test_exemption_refused_without_a_key
test_an_exemption_is_never_silent
test_unexempt_restores_monitoring
test_exemption_record_is_torn_down_with_the_task
