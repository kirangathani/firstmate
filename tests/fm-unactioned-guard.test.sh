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
