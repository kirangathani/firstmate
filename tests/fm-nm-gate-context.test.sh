#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the two firstmate-side channels that carry a worker's own
# context through a no-mistakes run: the pinned run intent
# (bin/fm-nm-intent.sh) and the durable gate-decision record
# (bin/fm-nm-decision.sh), which amends that intent as decisions are made, plus
# the generated ship brief that drives both.
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

# `record` amends the brief's `# Task` section, so a decision fixture needs a
# real brief, and it reads the current run id from `no-mistakes axi status`, so
# the fixture also puts a stub on PATH whose answer the test controls. The stub's
# output is the exact TOON shape captured from the real `no-mistakes axi status`
# in this repo on 2026-09-07 (v1.37.0), trimmed to the fields this reader parses.
decision_home() {
  local name=$1 id=${2:-t1} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data/$id" "$home/bin"
  cat > "$home/data/$id/brief.md" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate.

# Task
Ship the thing the captain asked for.

# Setup
Later sections must never be touched.
EOF
  printf 'RUN_A\n' > "$home/run-id"
  cat > "$home/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
printf 'run:\\n  id: "%s"\\n  branch: fm/demo\\n  status: completed\\n' "\$(cat '$home/run-id')"
EOF
  chmod 755 "$home/bin/no-mistakes"
  printf '%s\n' "$home"
}

# Points the stub at a different run id, which is what a fresh pipeline run looks
# like to `rerun-check`.
set_run_id() {
  printf '%s\n' "$2" > "$1/run-id"
}

# Runs bin/fm-nm-decision.sh against a decision fixture, with its stub first on
# PATH so the real `no-mistakes` on the operator's machine is never consulted.
dec() {
  local home=$1
  shift
  PATH="$home/bin:$PATH" FM_HOME="$home" "$DECISION" "$@"
}

# --- record amends the pinned intent ----------------------------------------

test_decision_record_amends_the_task_section() {
  local home brief intent
  home=$(decision_home dec-amend)
  dec "$home" record t1 --finding F1 --key marker-kept \
    --requires 'Every unchecked row keeps the explicit unverified marker.' --step review >/dev/null \
    || fail "recording a decision failed"
  brief="$home/data/t1/brief.md"
  assert_grep '## Gate decisions' "$brief" "record must open the gate-decisions subsection"
  assert_grep '- F1 [marker-kept]: Every unchecked row keeps' "$brief" \
    "record must write the finding, the key, and the requirement as one line"
  # The subsection has to sit INSIDE the `# Task` section, because that is the
  # only part of the brief bin/fm-nm-intent.sh emits.
  intent=$(FM_HOME="$home" "$INTENT" t1) || fail "intent extraction failed after recording"
  assert_contains "$intent" '- F1 [marker-kept]: Every unchecked row keeps' \
    "the very next intent call must already carry the decision"
  assert_contains "$intent" 'Ship the thing the captain asked for.' "the intent must keep the original goal"
  assert_not_contains "$intent" 'Later sections must never be touched' \
    "the amendment must not push the subsection past the end of the Task section"
  pass "decision: record amends the brief's Task section, so the next intent carries the decision"
}

test_decision_record_rewrites_the_same_key() {
  local home brief
  home=$(decision_home dec-rerecord)
  dec "$home" record t1 --finding F1 --key marker-kept --requires 'Marker on every row.' >/dev/null
  dec "$home" record t1 --finding F2 --key prefix-kept --requires 'fm- prefix kept.' >/dev/null
  dec "$home" record t1 --finding F1 --key marker-kept --requires 'Marker moves to the header row.' >/dev/null \
    || fail "re-recording the same key must be allowed, not refused"
  brief="$home/data/t1/brief.md"
  [ "$(grep -c '^- F1 \[marker-kept\]: ' "$brief")" -eq 1 ] \
    || fail "re-recording a key must rewrite its line, not add a second one"
  assert_grep '- F1 [marker-kept]: Marker moves to the header row.' "$brief" \
    "the rewritten line must carry the revised requirement"
  assert_grep '- F2 [prefix-kept]: fm- prefix kept.' "$brief" \
    "re-recording one key must leave every other decision alone"
  [ "$(grep -c '^## Gate decisions$' "$brief")" -eq 1 ] \
    || fail "the subsection heading must be written exactly once"
  [ "$(grep -c '^- key: marker-kept$' "$home/data/t1/decisions.md")" -eq 1 ] \
    || fail "re-recording a key must leave one block for it in the durable record too"
  assert_grep '- requires: Marker moves to the header row.' "$home/data/t1/decisions.md" \
    "the durable record must carry the revised requirement"
  pass "decision: re-recording a key rewrites its statement in both places"
}

test_decision_record_when_task_is_the_last_section() {
  local home brief
  home=$(decision_home dec-tail)
  printf '# Task\nThe whole brief is one section.\n' > "$home/data/t1/brief.md"
  dec "$home" record t1 --finding F1 --key k --requires 'The requirement.' >/dev/null \
    || fail "recording against a brief whose Task section runs to EOF failed"
  brief="$home/data/t1/brief.md"
  assert_grep '## Gate decisions' "$brief" "the subsection must be appended at the end of the file too"
  assert_grep '- F1 [k]: The requirement.' "$brief" "the decision line must be written"
  assert_contains "$(FM_HOME="$home" "$INTENT" t1)" '- F1 [k]: The requirement.' \
    "the intent must carry a decision appended at EOF"
  pass "decision: record appends correctly when the Task section runs to the end of the brief"
}

test_decision_record_refuses_without_a_task_section() {
  local home out rc
  home=$(decision_home dec-notask)
  printf '# Setup\nno task section here\n' > "$home/data/t1/brief.md"
  out=$(dec "$home" record t1 --finding F1 --key k --requires 'x' 2>&1); rc=$?
  expect_code 2 "$rc" "a brief with no Task section must refuse, not record half the amendment"
  assert_contains "$out" "no '# Task' section" "the refusal must name the missing section"
  assert_absent "$home/data/t1/decisions.md" "a refused record must not write the durable record either"

  rm -f "$home/data/t1/brief.md"
  out=$(dec "$home" record t1 --finding F1 --key k --requires 'x' 2>&1); rc=$?
  expect_code 2 "$rc" "a missing brief must refuse"
  assert_contains "$out" 'no brief at' "the refusal must name the missing brief"
  pass "decision: record refuses when the decision cannot reach the intent"
}

# --- rerun-check is the done gate -------------------------------------------

test_rerun_check_passes_with_no_decisions() {
  local home out rc
  home=$(decision_home rerun-none)
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 0 "$rc" "an unamended intent needs no re-run"
  assert_contains "$out" 'no re-run is owed' "the empty case must say so plainly"
  pass "rerun-check: passes when no decision was ever recorded"
}

test_rerun_check_refuses_until_a_fresh_run() {
  local home out rc
  home=$(decision_home rerun-gate)
  dec "$home" record t1 --finding F1 --key marker-kept --requires 'Marker kept.' >/dev/null
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 1 "$rc" "a decision recorded during the most recent run has not been re-scored yet"
  assert_contains "$out" 'RUN_A' "the refusal must name the run the decision was recorded during"
  assert_contains "$out" 'F1' "the refusal must name the decision still waiting"
  assert_contains "$out" 'Start a fresh run' "the refusal must say what to do instead"

  set_run_id "$home" RUN_B
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 0 "$rc" "a fresh run after the decision must clear the gate: $out"
  assert_contains "$out" 'RUN_B' "the pass line must name the run that did the re-scoring"

  # A second decision round re-arms the gate: the fresh run is now the run that
  # produced the decision, so another one is owed.
  dec "$home" record t1 --finding F2 --key prefix-kept --requires 'Prefix kept.' >/dev/null
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 1 "$rc" "a decision recorded during the re-run must demand another re-run"
  assert_contains "$out" 'F2' "the refusal must name the newly recorded decision"
  pass "rerun-check: refuses until a run started after the last decision"
}

test_rerun_check_refuses_an_unreadable_run() {
  local home out rc
  home=$(decision_home rerun-blind)
  dec "$home" record t1 --finding F1 --key k --requires 'x' >/dev/null
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/bin/no-mistakes"
  chmod 755 "$home/bin/no-mistakes"
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 1 "$rc" "an unreadable run confirms nothing, so it must not pass the gate"
  assert_contains "$out" 'could not read the current no-mistakes run id' "the refusal must name the cause"
  pass "rerun-check: refuses when the current run id cannot be read"
}

# --- a no-change decision does not buy a fresh run --------------------------

test_no_change_decision_needs_no_re_run() {
  local home out rc brief
  home=$(decision_home dec-nochange)
  dec "$home" record t1 --finding F1 --key soft-deleted-count --outcome no-change \
    --requires 'The soft-deleted-rater count stays as it is; the answer changed nothing.' >/dev/null \
    || fail "recording a no-change decision failed"
  brief="$home/data/t1/brief.md"
  assert_grep '- F1 [soft-deleted-count] (no-change): The soft-deleted-rater count stays' "$brief" \
    "the brief line must carry the outcome, so a reviewer can see why no re-run followed"
  assert_grep '- outcome: no-change' "$home/data/t1/decisions.md" \
    "the durable record must carry the outcome too"
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 0 "$rc" "a decision that changed nothing must not demand a 25-35 minute re-run: $out"
  assert_contains "$out" 'F1' "the pass must still list the no-change decision rather than hide it"
  assert_contains "$out" 'changed nothing on the branch' "the pass must say why no re-run was owed"
  pass "rerun-check: a no-change decision alone passes with no fresh run"
}

test_change_decision_still_demands_a_re_run() {
  local home out rc
  home=$(decision_home dec-explicit-change)
  dec "$home" record t1 --finding F1 --key marker-kept --outcome change \
    --requires 'Every unchecked row keeps the marker.' >/dev/null
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 1 "$rc" "an explicit change decision must keep the original re-run gate"
  assert_contains "$out" 'F1' "the refusal must name the change decision"
  set_run_id "$home" RUN_B
  dec "$home" rerun-check t1 >/dev/null 2>&1 || fail "a fresh run must clear a change decision"
  pass "rerun-check: --outcome change keeps today's behavior"
}

test_mixed_outcomes_gate_on_the_change_decision_only() {
  local home out rc
  home=$(decision_home dec-mixed)
  dec "$home" record t1 --finding F1 --key blocked-users --outcome no-change \
    --requires 'Already decided at blocked-users; nothing on the branch moves.' >/dev/null
  dec "$home" record t1 --finding F2 --key retry-limit --outcome change \
    --requires 'The uploader retries at most three times.' >/dev/null
  # Only stderr carries the refusal and the list of decisions blocking the gate;
  # the no-change line is on stdout, so reading the streams apart is what proves
  # F1 is listed without being counted against the gate.
  out=$(dec "$home" rerun-check t1 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "one change decision in the round still demands the fresh run"
  assert_contains "$out" 'F2' "the refusal must name the change decision"
  assert_not_contains "$out" 'F1' "the no-change decision must not be listed among the blockers"
  set_run_id "$home" RUN_B
  out=$(dec "$home" rerun-check t1 2>&1); rc=$?
  expect_code 0 "$rc" "the fresh run must clear the mixed round: $out"
  assert_contains "$out" 'F1' "the pass must still list the no-change decision"
  pass "rerun-check: a mixed round gates on its change decision, then clears"
}

test_no_change_is_refused_for_a_finding_this_round_fixed() {
  local home out rc
  home=$(decision_home dec-launder)
  out=$(dec "$home" record t1 --finding F2 --key wording --outcome no-change \
    --requires 'The wording is accepted as written.' --fixed 'F1 F2 F3' 2>&1); rc=$?
  expect_code 2 "$rc" "a finding this round submitted a fix for cannot be recorded as changing nothing"
  assert_contains "$out" "in this round's fixed set" "the refusal must name the cause"
  assert_absent "$home/data/t1/decisions.md" "a refused record must write nothing"
  dec "$home" record t1 --finding F2 --key wording --outcome no-change \
    --requires 'The wording is accepted as written.' --fixed 'F1,F3' >/dev/null \
    || fail "a finding outside the round's fixed set must still record as no-change"
  pass "record: --outcome no-change cannot launder a fix this round submitted"
}

test_re_recording_switches_the_outcome_in_place() {
  local home brief
  home=$(decision_home dec-outcome-switch)
  dec "$home" record t1 --finding F1 --key k --outcome no-change --requires 'Nothing moves.' >/dev/null
  dec "$home" record t1 --finding F1 --key k --outcome change --requires 'The guard moves to the caller.' >/dev/null \
    || fail "re-recording with a different outcome must be allowed"
  brief="$home/data/t1/brief.md"
  [ "$(grep -c '^- F1 \[k\]' "$brief")" -eq 1 ] \
    || fail "switching the outcome must rewrite the one line, not leave both shapes behind"
  assert_grep '- F1 [k]: The guard moves to the caller.' "$brief" "the rewritten line must drop the no-change annotation"
  pass "record: a re-recorded decision switches outcome in place, leaving one line"
}

# --- the optional diagnostics still work ------------------------------------

test_decision_check_passes_with_no_decisions() {
  local home out rc
  home=$(decision_home dec-none)
  out=$(dec "$home" check t1 2>&1); rc=$?
  expect_code 0 "$rc" "a task with no gate decisions has nothing to inspect"
  assert_contains "$out" 'nothing to verify' "the empty case must say so plainly"
  pass "decision: the optional check passes when no decision was ever recorded"
}

test_decision_verify_then_check_passes() {
  local home out rc
  home=$(decision_home dec-verified)
  dec "$home" record t1 --finding F1 --key marker-kept --requires 'Marker kept.' >/dev/null
  dec "$home" record t1 --finding F2 --key prefix-kept --requires 'fm- prefix kept.' >/dev/null
  out=$(dec "$home" check t1 2>&1); rc=$?
  expect_code 1 "$rc" "two decisions with no by-hand verification must report so"
  dec "$home" verify t1 --finding F1 --evidence 'bin/x.sh:44 still prints unverified' >/dev/null
  out=$(dec "$home" check t1 2>&1); rc=$?
  expect_code 1 "$rc" "one verified of two must still report the other"
  dec "$home" verify t1 --finding F2 --evidence 'grep confirms the prefix' >/dev/null
  out=$(dec "$home" check t1 2>&1); rc=$?
  expect_code 0 "$rc" "every decision verified must pass: $out"
  assert_contains "$out" 'all 2 recorded gate decisions carry a by-hand verification' \
    "the pass line must state the count"
  pass "decision: the optional check tracks by-hand verification"
}

test_decision_reverted_always_refuses() {
  local home out rc
  home=$(decision_home dec-reverted)
  dec "$home" record t1 --finding F1 --key prefix-kept --requires 'fm- prefix kept.' >/dev/null
  dec "$home" verify t1 --finding F1 --evidence 'held at the time' >/dev/null
  dec "$home" check t1 >/dev/null || fail "a verified decision should pass before the revert"
  dec "$home" reverted t1 --finding F1 --evidence 'commit def456 removed it and pinned the reversal in a test' >/dev/null
  out=$(dec "$home" check t1 2>&1); rc=$?
  expect_code 1 "$rc" "a contradicted decision must report even after an earlier verify"
  assert_contains "$out" 'contradicted' "the report must name the contradicted state"
  pass "decision: a contradicted decision keeps reporting for good"
}

test_decision_requires_text_is_not_rewritten() {
  local home before after
  home=$(decision_home dec-immutable)
  dec "$home" record t1 --finding F1 --key marker-kept \
    --requires 'Every unchecked row keeps the explicit unverified marker.' >/dev/null
  before=$(grep '^- requires: ' "$home/data/t1/decisions.md")
  dec "$home" verify t1 --finding F1 --evidence 'proof' >/dev/null
  after=$(grep '^- requires: ' "$home/data/t1/decisions.md")
  [ "$before" = "$after" ] || fail "verify must not rewrite what the decision required: $before -> $after"
  pass "decision: verify never edits the recorded requirement"
}

test_decision_marks_only_the_named_block() {
  local home
  home=$(decision_home dec-scoped)
  dec "$home" record t1 --finding F1 --key a --requires 'first' >/dev/null
  dec "$home" record t1 --finding F2 --key b --requires 'second' >/dev/null
  dec "$home" record t1 --finding F3 --key c --requires 'third' >/dev/null
  dec "$home" verify t1 --finding F2 --evidence 'only this one' >/dev/null
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
  out=$(dec "$home" record t1 --finding F1 --key k 2>&1); rc=$?
  expect_code 2 "$rc" "record without --requires must be a usage error"
  assert_contains "$out" 'requires --requires' "the usage error must name the missing flag"

  dec "$home" record t1 --finding F1 --key k --requires 'x' >/dev/null
  out=$(dec "$home" verify t1 --finding F9 --evidence 'z' 2>&1); rc=$?
  expect_code 2 "$rc" "verifying an unrecorded finding must refuse"
  assert_contains "$out" 'not recorded' "the unknown-finding refusal must say so"

  out=$(dec "$home" bogus t1 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown action must be a usage error"
  pass "decision: usage errors refuse with a named cause"
}

test_decision_list_and_path() {
  local home out
  home=$(decision_home dec-list)
  out=$(dec "$home" path t1)
  [ "$out" = "$home/data/t1/decisions.md" ] || fail "path must point under data/<id>/: $out"
  out=$(dec "$home" list t1)
  assert_contains "$out" 'no decision record' "list must be safe before anything is recorded"
  dec "$home" record t1 --finding F1 --key k --requires 'the requirement' >/dev/null
  out=$(dec "$home" list t1)
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
  assert_grep "fm-nm-intent.sh' gate-demo" "$brief" "the brief must name the intent owner with this task's id"
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

test_ship_brief_requires_recording_and_a_re_run() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep "fm-nm-decision.sh' record gate-demo" "$brief" "the brief must require recording each gate decision"
  assert_grep "fm-nm-decision.sh' rerun-check gate-demo" "$brief" "the brief must require the re-run gate before done"
  assert_grep 'start a fresh run with the same pinned-intent command' "$brief" \
    "the brief must require a re-run after any round that produced a decision"
  assert_grep 'must exit 0 before you report done' "$brief" "the re-run gate must be a precondition, not advice"
  assert_grep '#591' "$brief" "the brief must cite the upstream evidence"
  pass "brief: requires recording each decision and re-running on the amended intent"
}

test_ship_brief_lets_the_worker_answer_info_findings() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep 'An ask-user finding of severity `info` or `suggestion` is YOURS to answer.' "$brief" \
    "the brief must hand info-severity findings to the worker"
  assert_grep 'Decisions taken by the worker (info severity)' "$brief" \
    "the brief must name the PR-description heading those answers are listed under"
  assert_grep 'is answered by citing that key, and recorded `--outcome no-change`' "$brief" \
    "a re-raised decision must be answered from the record, not re-opened"
  assert_grep 'A finding about a security, credential, or data-loss risk escalates no matter what severity it carries.' "$brief" \
    "the security carve-out must survive the info-severity rule"
  assert_grep 'Ask-user findings of severity `warning` or `error` are not yours to answer' "$brief" \
    "warning and error findings must still reach firstmate"
  pass "brief: the worker answers info-severity findings and escalates the rest"
}

test_ship_brief_caps_the_fix_rounds() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep 'After the first review of a run, you get at most TWO further fix rounds on the same set of findings.' "$brief" \
    "the brief must state the fix-round cap"
  assert_grep 'becomes a follow-up instead of a third attempt' "$brief" \
    "a capped finding must become a follow-up"
  assert_grep '--mint --blocked-by gate-demo' "$brief" \
    "the follow-up must be filed blocked by this task"
  assert_grep 'Deferred to follow-up' "$brief" \
    "the brief must name the PR-description heading capped findings are listed under"
  assert_grep 'This is a normal outcome, not a failure: do not append `failed:` or `blocked:` for a capped finding' "$brief" \
    "a capped round must not be reported as a failure"
  pass "brief: at most two further fix rounds, then a follow-up"
}

test_ship_brief_states_the_no_change_outcome() {
  local brief
  brief=$(generated_no_mistakes_brief)
  assert_grep 'Pass `--outcome no-change` when the answer leaves the branch exactly as it is' "$brief" \
    "the brief must tell the worker when to record a no-change decision"
  assert_grep 'A round whose decisions were all `no-change` needs no fresh run' "$brief" \
    "the brief must say a no-change round buys no re-run"
  assert_grep 'Add `--fixed "<finding ids>"`' "$brief" \
    "the brief must require the round's fixed set, which is what makes the refusal possible"
  pass "brief: states the no-change outcome and the fixed-set guard"
}

test_ship_brief_retires_the_end_of_run_diff_check() {
  local brief
  brief=$(generated_no_mistakes_brief)
  # The hand audit of the final diff is gone: the fresh run's own review is what
  # scores the branch against the decided goal now.
  assert_no_grep "fm-nm-decision.sh' verify gate-demo" "$brief" \
    "verifying each decision against the final diff must no longer be an obligation"
  assert_no_grep "fm-nm-decision.sh' check gate-demo" "$brief" \
    "the old check precondition must be gone from the definition of done"
  assert_no_grep 'Only the final diff is evidence' "$brief" \
    "the brief must not still send the worker to audit the diff by hand"
  pass "brief: the separate end-of-run diff check is retired"
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

# A crewmate pane is launched with NO FM_HOME of its own - only a --secondmate
# launch gets that env prefix (bin/fm-spawn.sh) - while the brief and the
# decision record live under the home's data/. In the main home the home and the
# tracked code root are the same directory, so a root-anchored command happens to
# work; in a secondmate home they are not, which is the entire point of the
# FM_HOME split. Root-anchored, the helper resolved data/ to the code root, found
# no brief, and the worker could not start a run at all. This runs the brief's
# OWN emitted command with FM_HOME scrubbed from the environment, which is the
# exact shape that failed before the command carried the resolved home.
test_ship_brief_commands_carry_the_resolved_home() {
  local home brief cmd out
  home="$TMP_ROOT/brief-nohome"
  mkdir -p "$home/data" "$home/projects/demo"
  FM_HOME="$home" "$BRIEF" nohome-demo demo >/dev/null 2>&1 || fail "brief scaffold failed"
  brief="$home/data/nohome-demo/brief.md"
  sed -i 's/{TASK}/Pinned intent fixture text./' "$brief"
  assert_grep "FM_HOME='$home'" "$brief" "the brief's helper commands must carry the resolved home"
  cmd=$(grep -o "FM_HOME='[^']*' '[^']*fm-nm-intent\.sh' nohome-demo" "$brief" | head -1)
  [ -n "$cmd" ] || fail "could not extract the emitted intent command from the generated brief"
  out=$(env -u FM_HOME bash -c "$cmd") \
    || fail "the brief's own intent command failed with no inherited FM_HOME"
  case "$out" in
    *"Pinned intent fixture text."*) ;;
    *) fail "the emitted intent command did not print the task text: $out" ;;
  esac
  grep -q "FM_HOME='$home' '[^']*fm-nm-decision\.sh' record nohome-demo" "$brief" \
    || fail "the decision-record command must carry the resolved home too"
  pass "brief: emitted helper commands resolve the home themselves, with no inherited FM_HOME"
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
test_decision_record_amends_the_task_section
test_decision_record_rewrites_the_same_key
test_decision_record_refuses_without_a_task_section
test_decision_record_when_task_is_the_last_section
test_rerun_check_passes_with_no_decisions
test_rerun_check_refuses_until_a_fresh_run
test_rerun_check_refuses_an_unreadable_run
test_no_change_decision_needs_no_re_run
test_change_decision_still_demands_a_re_run
test_mixed_outcomes_gate_on_the_change_decision_only
test_no_change_is_refused_for_a_finding_this_round_fixed
test_re_recording_switches_the_outcome_in_place
test_decision_check_passes_with_no_decisions
test_decision_verify_then_check_passes
test_decision_reverted_always_refuses
test_decision_requires_text_is_not_rewritten
test_decision_marks_only_the_named_block
test_decision_usage_errors
test_decision_list_and_path
test_ship_brief_pins_the_intent_to_its_one_owner
test_ship_brief_states_the_fix_instructions_rule
test_ship_brief_requires_recording_and_a_re_run
test_ship_brief_states_the_no_change_outcome
test_ship_brief_lets_the_worker_answer_info_findings
test_ship_brief_caps_the_fix_rounds
test_ship_brief_retires_the_end_of_run_diff_check
test_scout_and_local_only_briefs_are_untouched
test_ship_brief_commands_carry_the_resolved_home
test_scripts_are_shellcheck_clean
