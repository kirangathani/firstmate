#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the two firstmate-side channels that carry a worker's own
# context through a no-mistakes run: the pinned run intent
# (bin/fm-nm-intent.sh) and the durable gate-decision record
# (bin/fm-nm-decision.sh), plus the generated ship brief that drives both.
# See docs/fix-instructions-gate.md for the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-gate-context)
INTENT="$ROOT/bin/fm-nm-intent.sh"
DECISION="$ROOT/bin/fm-nm-decision.sh"
BRIEF="$ROOT/bin/fm-brief.sh"

# Builds an isolated firstmate home with one brief whose `# Task` section holds
# the supplied body, and echoes the home path.
make_home_with_brief() {
  local name=$1 id=$2 body=$3 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate.

# Task
$body

# Herdr lifecycle declaration - NOT ENABLED
This section must never leak into the intent.

# Setup
Neither must this.
EOF
  printf '%s\n' "$home"
}

# --- bin/fm-nm-intent.sh ----------------------------------------------------

test_intent_is_the_brief_task_section() {
  local home out
  home=$(make_home_with_brief intent-basic t1 'Add a retry to the uploader so a transient 503 does not lose the batch.')
  out=$(FM_HOME="$home" "$INTENT" t1) || fail "intent extraction failed"
  [ "$out" = 'Add a retry to the uploader so a transient 503 does not lose the batch.' ] \
    || fail "intent must be the Task section verbatim, got: $out"
  pass "intent: emits the brief's Task section"
}

test_intent_stops_at_the_next_heading() {
  local home out
  home=$(make_home_with_brief intent-bounded t1 'The goal line.')
  out=$(FM_HOME="$home" "$INTENT" t1)
  assert_not_contains "$out" 'Herdr' "intent must stop at the next heading"
  assert_not_contains "$out" 'Neither must this' "intent must not run past later sections"
  assert_not_contains "$out" 'You are a crewmate' "intent must not include the preamble above the Task heading"
  pass "intent: bounded to the Task section, excluding the preamble and later sections"
}

test_intent_keeps_the_whole_task_section() {
  local home out
  # Acceptance criteria and constraints are part of the stated goal and must
  # reach the pipeline's final review, so nothing is truncated.
  home=$(make_home_with_brief intent-full t1 'Ship the parser.

## Acceptance criteria
- Rejects a trailing comma.
- Keeps the existing error codes.')
  out=$(FM_HOME="$home" "$INTENT" t1)
  assert_contains "$out" 'Ship the parser.' "intent must keep the goal"
  assert_contains "$out" 'Rejects a trailing comma.' "intent must keep the acceptance criteria"
  assert_contains "$out" 'Keeps the existing error codes.' "intent must keep every criterion"
  pass "intent: carries the whole Task section, acceptance criteria included"
}

test_intent_is_a_single_line() {
  local home out lines
  home=$(make_home_with_brief intent-oneline t1 'First line.

Second line after a blank.
Third	line with a tab.')
  out=$(FM_HOME="$home" "$INTENT" t1)
  lines=$(printf '%s\n' "$out" | wc -l)
  [ "$lines" -eq 1 ] || fail "intent must collapse to one line, got $lines"
  assert_not_contains "$out" '  ' "intent must collapse whitespace runs"
  pass "intent: whitespace-normalized to a single CLI-safe line"
}

test_intent_refuses_a_missing_brief() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/nonexistent-home" "$INTENT" ghost 2>&1); rc=$?
  expect_code 1 "$rc" "a missing brief must refuse, not emit an empty intent"
  assert_contains "$out" 'no brief at' "the refusal must name the missing brief"
  pass "intent: refuses loudly when the brief is missing"
}

test_intent_refuses_an_unreplaced_placeholder() {
  local home out rc
  home=$(make_home_with_brief intent-placeholder t1 '{TASK}')
  out=$(FM_HOME="$home" "$INTENT" t1 2>&1); rc=$?
  expect_code 1 "$rc" "an unreplaced {TASK} placeholder must refuse"
  assert_contains "$out" '{TASK}' "the refusal must name the placeholder"
  pass "intent: refuses an unreplaced {TASK} placeholder"
}

test_intent_refuses_an_empty_task_section() {
  local home out rc
  home="$TMP_ROOT/intent-empty"
  mkdir -p "$home/data/t1"
  printf '# Task\n\n# Setup\nnothing\n' > "$home/data/t1/brief.md"
  out=$(FM_HOME="$home" "$INTENT" t1 2>&1); rc=$?
  expect_code 1 "$rc" "an empty Task section must refuse"
  assert_contains "$out" "no '# Task' section content" "the refusal must name the empty section"
  pass "intent: refuses an empty Task section"
}

# --- bin/fm-nm-decision.sh --------------------------------------------------

decision_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

test_decision_check_passes_with_no_decisions() {
  local home out rc
  home=$(decision_home dec-none)
  out=$(FM_HOME="$home" "$DECISION" check t1 2>&1); rc=$?
  expect_code 0 "$rc" "a run with no gate decisions has nothing to survive"
  assert_contains "$out" 'nothing to verify' "the empty case must say so plainly"
  pass "decision: check passes when no decision was ever recorded"
}

test_decision_record_then_check_refuses() {
  local home out rc
  home=$(decision_home dec-pending)
  FM_HOME="$home" "$DECISION" record t1 --finding F1 --key marker-kept \
    --requires 'Every unchecked row keeps the explicit unverified marker.' --step review >/dev/null \
    || fail "recording a decision failed"
  assert_present "$home/data/t1/decisions.md" "the decision record must be written under data/<id>/"
  out=$(FM_HOME="$home" "$DECISION" check t1 2>&1); rc=$?
  expect_code 1 "$rc" "an unverified decision must refuse the done gate"
  assert_contains "$out" 'pending' "the refusal must name the pending decision"
  assert_contains "$out" 'F1' "the refusal must name the finding"
  assert_contains "$out" 'Do not report done' "the refusal must say what to do instead"
  pass "decision: a recorded but unverified decision refuses the done gate"
}

test_decision_verify_then_check_passes() {
  local home out rc
  home=$(decision_home dec-verified)
  FM_HOME="$home" "$DECISION" record t1 --finding F1 --key marker-kept --requires 'Marker kept.' >/dev/null
  FM_HOME="$home" "$DECISION" record t1 --finding F2 --key prefix-kept --requires 'fm- prefix kept.' >/dev/null
  out=$(FM_HOME="$home" "$DECISION" check t1 2>&1); rc=$?
  expect_code 1 "$rc" "two pending decisions must still refuse"
  FM_HOME="$home" "$DECISION" verify t1 --finding F1 --evidence 'bin/x.sh:44 still prints unverified' >/dev/null
  out=$(FM_HOME="$home" "$DECISION" check t1 2>&1); rc=$?
  expect_code 1 "$rc" "one verified of two must still refuse"
  FM_HOME="$home" "$DECISION" verify t1 --finding F2 --evidence 'grep confirms the prefix' >/dev/null
  out=$(FM_HOME="$home" "$DECISION" check t1 2>&1); rc=$?
  expect_code 0 "$rc" "every decision verified must pass: $out"
  assert_contains "$out" 'all 2 recorded gate decisions verified' "the pass line must state the count"
  pass "decision: check passes only once every recorded decision is verified"
}

test_decision_reverted_always_refuses() {
  local home out rc
  home=$(decision_home dec-reverted)
  FM_HOME="$home" "$DECISION" record t1 --finding F1 --key prefix-kept --requires 'fm- prefix kept.' >/dev/null
  FM_HOME="$home" "$DECISION" verify t1 --finding F1 --evidence 'held at the time' >/dev/null
  FM_HOME="$home" "$DECISION" check t1 >/dev/null || fail "a verified decision should pass before the revert"
  FM_HOME="$home" "$DECISION" reverted t1 --finding F1 --evidence 'commit def456 removed it and pinned the reversal in a test' >/dev/null
  out=$(FM_HOME="$home" "$DECISION" check t1 2>&1); rc=$?
  expect_code 1 "$rc" "a contradicted decision must refuse even after an earlier verify"
  assert_contains "$out" 'contradicted' "the refusal must name the contradicted state"
  pass "decision: a contradicted decision refuses the done gate for good"
}

test_decision_requires_text_is_not_rewritten() {
  local home before after
  home=$(decision_home dec-immutable)
  FM_HOME="$home" "$DECISION" record t1 --finding F1 --key marker-kept \
    --requires 'Every unchecked row keeps the explicit unverified marker.' >/dev/null
  before=$(grep '^- requires: ' "$home/data/t1/decisions.md")
  FM_HOME="$home" "$DECISION" verify t1 --finding F1 --evidence 'proof' >/dev/null
  after=$(grep '^- requires: ' "$home/data/t1/decisions.md")
  [ "$before" = "$after" ] || fail "verify must not rewrite what the decision required: $before -> $after"
  pass "decision: verify never edits the recorded requirement"
}

test_decision_marks_only_the_named_block() {
  local home
  home=$(decision_home dec-scoped)
  FM_HOME="$home" "$DECISION" record t1 --finding F1 --key a --requires 'first' >/dev/null
  FM_HOME="$home" "$DECISION" record t1 --finding F2 --key b --requires 'second' >/dev/null
  FM_HOME="$home" "$DECISION" record t1 --finding F3 --key c --requires 'third' >/dev/null
  FM_HOME="$home" "$DECISION" verify t1 --finding F2 --evidence 'only this one' >/dev/null
  [ "$(grep -c '^- state: satisfied$' "$home/data/t1/decisions.md")" -eq 1 ] \
    || fail "verify must mark exactly one decision"
  [ "$(grep -c '^- state: pending$' "$home/data/t1/decisions.md")" -eq 2 ] \
    || fail "verify must leave the other decisions pending"
  assert_grep 'only this one' "$home/data/t1/decisions.md" "the evidence must be recorded"
  pass "decision: verify touches only the named finding's block"
}

test_decision_usage_errors() {
  local home out rc
  home=$(decision_home dec-usage)
  out=$(FM_HOME="$home" "$DECISION" record t1 --finding F1 --key k 2>&1); rc=$?
  expect_code 2 "$rc" "record without --requires must be a usage error"
  assert_contains "$out" 'requires --requires' "the usage error must name the missing flag"

  FM_HOME="$home" "$DECISION" record t1 --finding F1 --key k --requires 'x' >/dev/null
  out=$(FM_HOME="$home" "$DECISION" record t1 --finding F1 --key k --requires 'y' 2>&1); rc=$?
  expect_code 2 "$rc" "recording the same finding twice must refuse"
  assert_contains "$out" 'already recorded' "the duplicate refusal must say so"

  out=$(FM_HOME="$home" "$DECISION" verify t1 --finding F9 --evidence 'z' 2>&1); rc=$?
  expect_code 2 "$rc" "verifying an unrecorded finding must refuse"
  assert_contains "$out" 'not recorded' "the unknown-finding refusal must say so"

  out=$(FM_HOME="$home" "$DECISION" bogus t1 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown action must be a usage error"
  pass "decision: usage errors refuse with a named cause"
}

test_decision_list_and_path() {
  local home out
  home=$(decision_home dec-list)
  out=$(FM_HOME="$home" "$DECISION" path t1)
  [ "$out" = "$home/data/t1/decisions.md" ] || fail "path must point under data/<id>/: $out"
  out=$(FM_HOME="$home" "$DECISION" list t1)
  assert_contains "$out" 'no decision record' "list must be safe before anything is recorded"
  FM_HOME="$home" "$DECISION" record t1 --finding F1 --key k --requires 'the requirement' >/dev/null
  out=$(FM_HOME="$home" "$DECISION" list t1)
  assert_contains "$out" 'the requirement' "list must print the recorded requirement"
  assert_contains "$out" '#591' "the record must point at the upstream evidence for why it exists"
  pass "decision: list and path behave before and after the first record"
}

# --- the generated ship brief drives both -----------------------------------

# fm-brief.sh refuses to overwrite an existing brief, so the no-mistakes ship
# brief every assertion below reads is scaffolded exactly once.
NM_BRIEF_HOME="$TMP_ROOT/brief-home"
mkdir -p "$NM_BRIEF_HOME/data" "$NM_BRIEF_HOME/projects/demo"
FM_HOME="$NM_BRIEF_HOME" "$BRIEF" gate-demo demo >/dev/null 2>&1 || fail "brief scaffold failed"
NM_BRIEF="$NM_BRIEF_HOME/data/gate-demo/brief.md"

generated_no_mistakes_brief() {
  printf '%s\n' "$NM_BRIEF"
}

test_ship_brief_pins_the_intent_to_its_one_owner() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep 'fm-nm-intent.sh gate-demo' "$brief" "the brief must name the intent owner with this task's id"
  assert_grep 'no-mistakes axi run --intent' "$brief" "the brief must show the pinned run command"
  assert_grep 'never a paraphrase' "$brief" "the brief must say why the intent is pinned"
  pass "brief: pins --intent to bin/fm-nm-intent.sh, the one owner of that string"
}

test_ship_brief_states_the_fix_instructions_rule() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep 'design reasoning' "$brief" "the brief must state what --instructions has to carry"
  assert_grep 'principle the fix must preserve' "$brief" "the brief must state the preserve clause"
  assert_grep 'not break or reintroduce' "$brief" "the brief must state the do-not-reintroduce clause"
  assert_grep 'refused before it runs' "$brief" "the brief must say the refusal is mechanical"
  pass "brief: states the fix-instructions requirement the seatbelt enforces"
}

test_ship_brief_requires_decision_survival() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep 'fm-nm-decision.sh record gate-demo' "$brief" "the brief must require recording each gate decision"
  assert_grep 'fm-nm-decision.sh verify gate-demo' "$brief" "the brief must require verifying each decision against the final diff"
  assert_grep 'fm-nm-decision.sh reverted gate-demo' "$brief" "the brief must give the reverted path"
  assert_grep 'fm-nm-decision.sh check gate-demo' "$brief" "the brief must require the check before done"
  assert_grep 'Do NOT report done' "$brief" "the brief must hard-stop on a reverted decision"
  assert_grep '#591' "$brief" "the brief must cite the upstream evidence"
  pass "brief: requires recording, verifying, and hard-stopping on gate decisions"
}

test_ship_brief_denies_checks_passed_as_evidence() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep 'is NOT evidence that a decision survived' "$brief" \
    "the brief must state that checks-passed alone proves nothing about a decision"
  assert_grep 'checks-passed' "$brief" "the brief must name checks-passed as the thing that is not evidence"
  assert_grep 'Only the final diff is evidence' "$brief" "the brief must name what does count as evidence"
  pass "brief: states that checks-passed alone is not evidence a decision survived"
}

test_scout_and_local_only_briefs_are_untouched() {
  local home scout local_only
  home="$TMP_ROOT/brief-other"
  mkdir -p "$home/data" "$home/projects/demo"
  printf -- '- demo [local-only] - fixture (added 2026-08-03)\n' > "$home/data/projects.md"
  FM_HOME="$home" "$BRIEF" scout-demo demo --scout >/dev/null 2>&1 || fail "scout scaffold failed"
  scout="$home/data/scout-demo/brief.md"
  assert_no_grep 'fm-nm-intent.sh' "$scout" "a scout brief runs no pipeline and needs no run intent"
  assert_no_grep 'fm-nm-decision.sh' "$scout" "a scout brief has no gates to record decisions for"
  FM_HOME="$home" "$BRIEF" local-demo demo >/dev/null 2>&1 || fail "local-only scaffold failed"
  local_only="$home/data/local-demo/brief.md"
  assert_grep 'local-only' "$local_only" "the local-only fixture must actually resolve to local-only mode"
  assert_no_grep 'fm-nm-intent.sh' "$local_only" "a local-only brief runs no pipeline and needs no run intent"
  pass "brief: only the no-mistakes ship brief carries the gate-context contract"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$INTENT" >/dev/null 2>&1 || fail "bin/fm-nm-intent.sh is not shellcheck-clean"
  shellcheck "$DECISION" >/dev/null 2>&1 || fail "bin/fm-nm-decision.sh is not shellcheck-clean"
  pass "bin/fm-nm-intent.sh and bin/fm-nm-decision.sh are shellcheck-clean"
}

test_intent_is_the_brief_task_section
test_intent_stops_at_the_next_heading
test_intent_keeps_the_whole_task_section
test_intent_is_a_single_line
test_intent_refuses_a_missing_brief
test_intent_refuses_an_unreplaced_placeholder
test_intent_refuses_an_empty_task_section
test_decision_check_passes_with_no_decisions
test_decision_record_then_check_refuses
test_decision_verify_then_check_passes
test_decision_reverted_always_refuses
test_decision_requires_text_is_not_rewritten
test_decision_marks_only_the_named_block
test_decision_usage_errors
test_decision_list_and_path
test_ship_brief_pins_the_intent_to_its_one_owner
test_ship_brief_states_the_fix_instructions_rule
test_ship_brief_requires_decision_survival
test_ship_brief_denies_checks_passed_as_evidence
test_scout_and_local_only_briefs_are_untouched
test_scripts_are_shellcheck_clean
