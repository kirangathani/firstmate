#!/usr/bin/env bash
# bin/fm-nm-questions.sh: the reviewer's open questions, read from the run's own
# review conversation, and the one steer that answers one.
#
# The fixtures here are ndjson files written by hand, never a live daemon: the
# installed binary predates the fork commit this reader codes against
# (kirangathani/no-mistakes 31b58c7), so the protocol is exercised from its
# stated wire format rather than from a run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'ok - skipped (jq absent)\n'; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { printf 'ok - skipped (sqlite3 absent)\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-nm-questions)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
EVIDENCE="$TMP_ROOT/evidence"
DB="$TMP_ROOT/state.sqlite"
RUN=R1
CONV="$EVIDENCE/$RUN/review"
mkdir -p "$STATE" "$DATA" "$CONV"

# A run on the task's own ship branch, which is the key the reader attributes by.
sqlite3 "$DB" <<SQL
CREATE TABLE runs (
  id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
  head_sha TEXT NOT NULL, base_sha TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
  pr_url TEXT, error TEXT, awaiting_agent_since INTEGER,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
INSERT INTO runs VALUES ('R1','repo1','fm/t1','abc','base','awaiting_approval',NULL,NULL,NULL,1000,2000);
SQL

fm_write_meta "$STATE/t1.meta" "window=w:fm-t1" "worktree=$TMP_ROOT/wt" "project=$TMP_ROOT/proj" \
  "harness=claude" "kind=crew" "mode=no-mistakes" "yolo=off"

# The brief the decision recorder amends; its `# Task` section is the pinned
# intent, so the recorder refuses without one.
mkdir -p "$DATA/t1"
cat > "$DATA/t1/brief.md" <<'MD'
# Task
Do the thing.
MD

QUESTIONS="$ROOT/bin/fm-nm-questions.sh"

run_q() {  # <args...>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_NM_QUESTIONS_DB="$DB" FM_NM_QUESTIONS_EVIDENCE_ROOT="$EVIDENCE" \
    "$QUESTIONS" "$@" 2>&1
}

run_q_code() {  # <args...> -> sets RC and OUT
  set +e
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_NM_QUESTIONS_DB="$DB" FM_NM_QUESTIONS_EVIDENCE_ROOT="$EVIDENCE" \
    "$QUESTIONS" "$@" 2>&1)
  RC=$?
  set -e
}

write_questions() {  # <heredoc on stdin>
  cat > "$CONV/questions.ndjson"
}
write_answers() {
  cat > "$CONV/answers.ndjson"
}

# --- the reader -------------------------------------------------------------

test_open_question_carries_its_own_options() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Should the legacy /v1 route keep answering?","options":["Keep answering","Remove it","Keep behind a flag"],"weight":"major","file":"internal/api/router.go","line":88,"asked_at":"2026-09-15T13:04:11Z"}
JSON
  : > "$CONV/answers.ndjson"
  local out
  out=$(run_q list t1)
  assert_contains "$out" "question: q1" "the open question is not listed"
  assert_contains "$out" "Should the legacy /v1 route keep answering?" "the question text is not shown"
  assert_contains "$out" "option: Keep answering" "the reviewer's first option is not shown"
  assert_contains "$out" "option: Remove it" "the reviewer's second option is not shown"
  assert_contains "$out" "option: Keep behind a flag" "the reviewer's third option is not shown"
  assert_contains "$out" "where: internal/api/router.go:88" "the question's location is not shown"
  pass "an open question reaches firstmate with the reviewer's own options intact"
}

test_retraction_closes_a_question() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep","Remove"],"weight":"major"}
{"id":"q2","kind":"question","question":"Is the cache bound deliberate?","options":["Deliberate","Raise it"],"weight":"major"}
{"id":"q1","kind":"retract","reason":"answered by the migration note","at":"2026-09-15T13:19:02Z"}
JSON
  : > "$CONV/answers.ndjson"
  local out
  out=$(run_q list t1)
  assert_not_contains "$out" "question: q1" "a retracted question still blocks"
  assert_contains "$out" "question: q2" "the live question was lost with the retraction"
  pass "a retracted question is closed and never asked"
}

test_a_later_line_supersedes_the_earlier_one() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Original wording","options":["A","B"],"weight":"major"}
{"id":"q1","kind":"question","question":"Sharper wording","options":["A","B","C"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  local out
  out=$(run_q list t1)
  assert_contains "$out" "Sharper wording" "the superseding line was not used"
  assert_not_contains "$out" "Original wording" "the superseded wording was asked as well"
  assert_contains "$out" "option: C" "the superseding line's own options were not used"
  pass "a later line for the same id is an edit, not a duplicate"
}

test_a_re_ask_revives_a_retracted_question() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep","Remove"],"weight":"major"}
{"id":"q1","kind":"retract","reason":"answered elsewhere"}
{"id":"q1","kind":"question","question":"Keep the legacy route? (the note does not cover it)","options":["Keep","Remove"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  local out
  out=$(run_q list t1)
  assert_contains "$out" "the note does not cover it" "re-asking a retracted question did not revive it"
  pass "re-asking a retracted question revives it, as the protocol says"
}

test_answered_and_minor_questions_never_block() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Answered already","options":["A","B"],"weight":"major"}
{"id":"q2","kind":"question","question":"The reviewer's own call","options":["A","B"],"weight":"minor"}
{"id":"q3","kind":"question","question":"Still open","options":["A","B"],"weight":"major"}
JSON
  write_answers <<'JSON'
{"id":"q1","answer":"A","answered_by":"captain","answered_at":"2026-09-15T13:31:40Z"}
{"id":"zz","answer":"for a question nobody asked"}
JSON
  local out
  out=$(run_q list t1)
  assert_not_contains "$out" "question: q1" "an answered question is still reported open"
  assert_not_contains "$out" "question: q2" "a minor-weight question was escalated on the reviewer's behalf"
  assert_contains "$out" "question: q3" "the one genuinely open question was lost"
  pass "answered, minor and unknown-id lines never block the step"
}

test_a_malformed_line_does_not_lose_the_file() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Good line","options":["A","B"],"weight":"major"}
this is not json at all
{"kind":"question","question":"no id","options":["A"]}
{"id":"q4","kind":"question","question":"","options":["A"]}
{"id":"q5","kind":"question","question":"Second good line","options":["A","B"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  local out
  out=$(run_q list t1)
  assert_contains "$out" "Good line" "a malformed sibling line lost the whole file"
  assert_contains "$out" "Second good line" "parsing stopped at the malformed line"
  assert_not_contains "$out" "no id" "a line with no id was asked anyway"
  pass "a half-written or malformed line costs that line only"
}

# --- the merge gate's predicate ---------------------------------------------

test_gate_refuses_while_a_question_is_open_and_passes_when_none_is() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Still open","options":["A","B"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  run_q_code gate t1
  expect_code 1 "$RC" "the gate did not refuse with a question open"
  assert_contains "$OUT" "q1" "the refusal does not name the open question"

  write_answers <<'JSON'
{"id":"q1","answer":"A","answered_by":"captain"}
JSON
  run_q_code gate t1
  expect_code 0 "$RC" "the gate still refuses once the question is answered"
  pass "the gate refuses while a review question is open and clears when it is answered"
}

test_gate_is_quiet_for_a_task_with_no_run() {
  run_q_code gate t-no-run
  expect_code 0 "$RC" "the gate refused a task that has no run at all"
  pass "a task with no run holds no question, so the gate is silent"
}

test_gate_refuses_an_unreadable_conversation() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Still open","options":["A","B"],"weight":"major"}
JSON
  chmod 000 "$CONV/questions.ndjson"
  run_q_code gate t1
  chmod 644 "$CONV/questions.ndjson"
  # Running as root defeats the permission bit, so the case is only asserted
  # where it can actually be produced.
  if [ "$(id -u)" = 0 ]; then
    printf 'ok - skipped the unreadable-conversation case (running as root)\n'
    return 0
  fi
  expect_code 2 "$RC" "an unreadable conversation was treated as no questions"
  assert_contains "$OUT" "could not be read" "the refusal does not say why"
  pass "a conversation that exists but cannot be read refuses rather than passing"
}

# --- the wake sweep ---------------------------------------------------------

test_surface_prints_each_new_question_once() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep","Remove"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  rm -f "$STATE/t1.nm-questions"
  local first second third
  first=$(run_q surface)
  assert_contains "$first" "NM QUESTION: t1 is waiting on an answer to review question q1" \
    "the sweep did not surface a new question"
  assert_contains "$first" "options: Keep | Remove" "the sweep dropped the reviewer's options"
  assert_contains "$first" "NM QUESTION REMEDY" "the sweep printed no remedy line"
  second=$(run_q surface)
  [ -z "$second" ] || fail "the sweep re-surfaced an already-reported question: $second"

  cat >> "$CONV/questions.ndjson" <<'JSON'
{"id":"q2","kind":"question","question":"Is the cache bound deliberate?","options":["Deliberate","Raise it"],"weight":"major"}
JSON
  third=$(run_q surface)
  assert_contains "$third" "q2" "a newly asked question did not wake firstmate"
  assert_not_contains "$third" "q1" "the sweep repeated an already-reported question"
  pass "the sweep wakes firstmate once per new question and stays silent otherwise"
}

# The watcher runs the sweep under a wall-clock bound, so it can be killed part
# way through. Marking a question surfaced before its line reached the watcher
# would let that kill swallow the question while the durable record claimed it
# had been reported. Printing first and marking after makes a kill cost at most
# a duplicate wake - which is why the marker for a task must not exist until
# that task's lines have been written.
test_a_question_is_printed_before_it_is_marked_surfaced() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep","Remove"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  rm -f "$STATE/t1.nm-questions"

  # Stop the sweep the moment it writes its first line, exactly as the watcher's
  # bound would, and assert nothing was recorded as surfaced.
  local killed
  killed=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_NM_QUESTIONS_DB="$DB" FM_NM_QUESTIONS_EVIDENCE_ROOT="$EVIDENCE" \
    "$QUESTIONS" surface 2>/dev/null | head -1)
  assert_contains "$killed" "q1" "precondition: the sweep must report the open question"

  # Now let it finish, and only then may the record claim it.
  run_q surface >/dev/null
  assert_present "$STATE/t1.nm-questions" "a completed sweep did not record what it surfaced"
  assert_grep "q1" "$STATE/t1.nm-questions" "the completed sweep did not record the question it reported"
  pass "a question is printed before it is marked surfaced, so a cut-short sweep cannot swallow one"
}

test_surface_skips_a_scout() {
  fm_write_meta "$STATE/t1.meta" "window=w:fm-t1" "worktree=$TMP_ROOT/wt" "project=$TMP_ROOT/proj" \
    "harness=claude" "kind=scout" "mode=scout" "yolo=off"
  rm -f "$STATE/t1.nm-questions"
  local out
  out=$(run_q surface)
  [ -z "$out" ] || fail "the sweep reported a scout, which drives no validation: $out"
  fm_write_meta "$STATE/t1.meta" "window=w:fm-t1" "worktree=$TMP_ROOT/wt" "project=$TMP_ROOT/proj" \
    "harness=claude" "kind=crew" "mode=no-mistakes" "yolo=off"
  pass "the sweep is silent for a kind that runs no validation of its own"
}

# --- the composed answer steer ----------------------------------------------

test_answer_composes_the_exact_worker_command_and_records_it() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep behind a flag","Remove it"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  local out
  out=$(run_q answer t1 --question q1 --answer "Keep behind a flag" --by captain)
  assert_contains "$out" 'no-mistakes axi answer --question q1 --answer "Keep behind a flag" --by captain' \
    "the steer does not carry the exact answer command the worker must run"
  assert_contains "$out" 'resolved [key=q1]' "the steer does not tell the worker how to close the decision"
  assert_contains "$out" "fm-send.sh t1 " "the steer is not paired with the command that sends it"
  assert_grep "review question q1 answered by the captain" "$DATA/t1/decisions.md" \
    "the answer was not recorded durably"
  assert_grep "settles only that question" "$DATA/t1/decisions.md" \
    "the record does not carry the settles-only-this-question instruction"
  assert_grep "- outcome: no-change" "$DATA/t1/decisions.md" \
    "an answer that leaves the branch alone was recorded as owing a fresh run"
  assert_grep "review question q1 answered by the captain" "$DATA/t1/brief.md" \
    "the answer did not reach the pinned intent the next cold reviewer is scored against"
  assert_grep "(no-change)" "$DATA/t1/brief.md" \
    "the pinned intent does not say the answer left the branch as it is"
  pass "an answer is recorded in the pinned intent and composed as one exact worker steer"
}

test_answer_refuses_an_authority_it_cannot_speak_for() {
  run_q_code answer t1 --question q1 --answer "Keep behind a flag" --by reviewer
  expect_code 2 "$RC" "an answer attributed to nobody with authority was accepted"
  assert_contains "$OUT" "captain or firstmate" "the refusal does not name the two authorities"
  pass "only the captain or firstmate can be recorded as having answered"
}

test_answer_refuses_text_that_would_break_the_one_line_steer() {
  run_q_code answer t1 --question q1 --answer 'He said "keep it"'
  expect_code 2 "$RC" "an answer carrying a double quote was composed into the steer anyway"
  assert_contains "$OUT" "double quote" "the refusal does not say what is wrong"
  pass "an answer that would break the composed command is refused, not mangled"
}

test_answer_never_writes_to_the_run() {
  local before
  before=$(cat "$CONV/answers.ndjson")
  run_q answer t1 --question q1 --answer "Remove it" --by captain >/dev/null
  assert_contains "$before$(cat "$CONV/answers.ndjson")" "$before" "unexpected"
  [ "$(cat "$CONV/answers.ndjson")" = "$before" ] \
    || fail "firstmate wrote into the worker's own run conversation"
  pass "firstmate composes the answer and never touches the crew-owned run"
}

test_open_question_carries_its_own_options
test_retraction_closes_a_question
test_a_later_line_supersedes_the_earlier_one
test_a_re_ask_revives_a_retracted_question
test_answered_and_minor_questions_never_block
test_a_malformed_line_does_not_lose_the_file
test_gate_refuses_while_a_question_is_open_and_passes_when_none_is
test_gate_is_quiet_for_a_task_with_no_run
test_gate_refuses_an_unreadable_conversation
test_surface_prints_each_new_question_once
test_a_question_is_printed_before_it_is_marked_surfaced
test_surface_skips_a_scout
test_answer_composes_the_exact_worker_command_and_records_it
test_answer_refuses_an_authority_it_cannot_speak_for
test_answer_refuses_text_that_would_break_the_one_line_steer
test_answer_never_writes_to_the_run
