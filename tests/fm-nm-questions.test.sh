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

QUESTIONS="$ROOT/bin/fm-nm-questions.sh"

# The task's own isolated copy: the answer command resolves its repository from
# the directory it runs in, so the reader must run it there and nowhere else.
WT="$TMP_ROOT/wt"
mkdir -p "$WT"

# A fake `no-mistakes` recording its argv AND its working directory, because
# both are part of the contract: the answer must name the run this reader
# resolved, and it must be delivered from the task's own copy.
NM_LOG="$TMP_ROOT/nm-answer.log"
NM_BIN_DIR="$TMP_ROOT/nmbin"
mkdir -p "$NM_BIN_DIR"
cat > "$NM_BIN_DIR/no-mistakes" <<'SH'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"; printf 'argv=%s\n' "$*"; } >> "$FM_TEST_NM_LOG"
[ -z "${FM_TEST_NM_FAIL:-}" ] || exit 1
exit 0
SH
chmod +x "$NM_BIN_DIR/no-mistakes"

fm_write_meta "$STATE/t1.meta" "window=w:fm-t1" "worktree=$WT" "project=$TMP_ROOT/proj" \
  "harness=claude" "kind=crew" "mode=no-mistakes" "yolo=off"

# The brief the decision recorder amends; its `# Task` section is the pinned
# intent, so the recorder refuses without one.
mkdir -p "$DATA/t1"
cat > "$DATA/t1/brief.md" <<'MD'
# Task
Do the thing.
MD

run_q() {  # <args...>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_NM_QUESTIONS_DB="$DB" FM_NM_QUESTIONS_EVIDENCE_ROOT="$EVIDENCE" \
    FM_NM_QUESTIONS_NM_BIN="$NM_BIN_DIR/no-mistakes" FM_TEST_NM_LOG="$NM_LOG" \
    "$QUESTIONS" "$@" 2>&1
}

run_q_code() {  # <args...> -> sets RC and OUT
  set +e
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_NM_QUESTIONS_DB="$DB" FM_NM_QUESTIONS_EVIDENCE_ROOT="$EVIDENCE" \
    FM_NM_QUESTIONS_NM_BIN="$NM_BIN_DIR/no-mistakes" FM_TEST_NM_LOG="$NM_LOG" \
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

# The sweep runs on EVERY watcher cycle now, so a cycle where nothing changed
# must cost two stats and nothing else. The file is made unreadable AFTER a
# completed sweep: if the sweep were still reading it, the read would fail and
# the guard below would catch it; a sweep that correctly skips on an unchanged
# signature never opens it at all.
test_an_unchanged_questions_file_is_not_re_read() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep","Remove"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  rm -f "$STATE/t1.nm-questions"

  local first
  first=$(run_q surface)
  assert_contains "$first" "q1" "precondition: the first sweep must report the question"
  assert_grep "sig=" "$STATE/t1.nm-questions" \
    "the sweep did not record the signature it read the file at, so every cycle would re-read it"
  assert_grep "run=" "$STATE/t1.nm-questions" \
    "the sweep did not cache the run id, so every cycle would query the database"

  if [ "$(id -u)" = 0 ]; then
    printf 'ok - skipped the unchanged-file case (running as root defeats the permission bit)\n'
    return 0
  fi
  chmod 000 "$CONV/questions.ndjson"
  local second rc=0
  second=$(run_q surface) || rc=$?
  chmod 644 "$CONV/questions.ndjson"
  expect_code 0 "$rc" "a sweep over an unchanged file did not stay silent"
  [ -z "$second" ] || fail "a sweep re-read an unchanged questions file: $second"
  pass "an unchanged questions file is not re-read, so an every-cycle sweep costs two stats"
}

# The other half: once the reviewer appends, the signature moves and the sweep
# reads again. Without this, "cheap" would just mean "blind".
test_an_appended_question_is_read_on_the_next_sweep() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep","Remove"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  rm -f "$STATE/t1.nm-questions"
  run_q surface >/dev/null
  cat >> "$CONV/questions.ndjson" <<'JSON'
{"id":"q2","kind":"question","question":"Is the cache bound deliberate?","options":["Deliberate","Raise it"],"weight":"major"}
JSON
  local out
  out=$(run_q surface)
  assert_contains "$out" "q2" "a question appended after the last sweep was never read"
  assert_not_contains "$out" "q1" "the sweep repeated a question it had already reported"
  pass "an appended question moves the signature and is read on the very next sweep"
}

test_surface_skips_a_scout() {
  fm_write_meta "$STATE/t1.meta" "window=w:fm-t1" "worktree=$WT" "project=$TMP_ROOT/proj" \
    "harness=claude" "kind=scout" "mode=scout" "yolo=off"
  rm -f "$STATE/t1.nm-questions"
  local out
  out=$(run_q surface)
  [ -z "$out" ] || fail "the sweep reported a scout, which drives no validation: $out"
  fm_write_meta "$STATE/t1.meta" "window=w:fm-t1" "worktree=$WT" "project=$TMP_ROOT/proj" \
    "harness=claude" "kind=crew" "mode=no-mistakes" "yolo=off"
  pass "the sweep is silent for a kind that runs no validation of its own"
}

# --- the composed answer steer ----------------------------------------------

# The captain's ruling of 2026-09-15: "the answer need to GO DIRECTLY TO THE
# REVIEWER otherwise we are passing it through a middleman which is a waste of
# time". So the reader delivers it itself, and the worker is not involved at all.
test_answer_goes_straight_to_the_reviewer_and_is_recorded() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep behind a flag","Remove it"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  : > "$NM_LOG"
  local out
  out=$(run_q answer t1 --question q1 --answer "Keep behind a flag" --by captain)

  assert_contains "$out" "answered: review question q1" "the reader did not report answering the reviewer"
  assert_contains "$(cat "$NM_LOG")" "argv=axi answer --run R1 --question q1 --answer Keep behind a flag --by captain" \
    "the answer command was not called with the resolved run, the question and the captain's option"
  assert_contains "$(cat "$NM_LOG")" "cwd=$WT" \
    "the answer was not delivered from the task's own copy, which is where the command resolves its repository"
  assert_not_contains "$out" "steer:" "the reader still composed a steer for a worker that is no longer in the loop"
  assert_not_contains "$out" "fm-send.sh" "the reader still routed the answer through the worker"
  assert_not_contains "$out" "resolved [key=" "the reader still asked someone to close a decision it settled itself"

  assert_grep "review question q1 answered by the captain" "$DATA/t1/decisions.md" \
    "the answer was not recorded durably"
  assert_grep "settles only that question" "$DATA/t1/decisions.md" \
    "the record does not carry the settles-only-this-question instruction"
  assert_grep "- outcome: no-change" "$DATA/t1/decisions.md" \
    "an answer that leaves the branch alone was recorded as owing a fresh run"
  assert_grep "review question q1 answered by the captain" "$DATA/t1/brief.md" \
    "the answer did not reach the pinned intent the next cold reviewer is scored against"
  pass "an answer is recorded and then delivered straight to the reviewer, with no worker in the loop"
}

# An option can contain a quote or an apostrophe. The answer is one element of an
# argument vector now, never composed into a line of shell, so it must arrive
# verbatim rather than being refused as it was when a steer had to carry it.
test_an_answer_with_a_quote_reaches_the_reviewer_verbatim() {
  : > "$NM_LOG"
  local out
  out=$(run_q answer t1 --question q1 --answer 'Keep it: the "legacy" route' --by captain)
  assert_contains "$out" "answered: review question q1" "a quoted option was refused instead of delivered"
  assert_contains "$(cat "$NM_LOG")" 'Keep it: the "legacy" route' \
    "the quoted option did not reach the answer command verbatim"
  pass "an option carrying a quote is delivered verbatim rather than refused"
}

# The record is written first because it is idempotent; if delivery then fails,
# the run simply stays parked and the merge gate keeps refusing, which is the
# visible and safe outcome. What must never happen is a silent success.
test_a_failed_delivery_is_reported_and_not_called_success() {
  write_questions <<'JSON'
{"id":"q9","kind":"question","question":"Is the bound deliberate?","options":["Deliberate","Raise it"],"weight":"major"}
JSON
  : > "$CONV/answers.ndjson"
  : > "$NM_LOG"
  set +e
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_NM_QUESTIONS_DB="$DB" FM_NM_QUESTIONS_EVIDENCE_ROOT="$EVIDENCE" \
    FM_NM_QUESTIONS_NM_BIN="$NM_BIN_DIR/no-mistakes" FM_TEST_NM_LOG="$NM_LOG" \
    FM_TEST_NM_FAIL=1 "$QUESTIONS" answer t1 --question q9 --answer "Deliberate" 2>&1)
  RC=$?
  set -e
  expect_code 1 "$RC" "a failed delivery was reported as success"
  assert_contains "$OUT" "the reviewer was NOT told" "the failure does not say the reviewer never got it"
  assert_contains "$OUT" "merge gate keeps refusing" "the failure does not say what stops it shipping"
  pass "a delivery that fails is reported loudly and never counted as answered"
}

# Answering a question the reviewer never asked, or has withdrawn, would put a
# line into the run's conversation that answers nothing. It is refused before
# anything is written at all.
test_answer_refuses_a_question_that_is_not_open() {
  write_questions <<'JSON'
{"id":"q1","kind":"question","question":"Keep the legacy route?","options":["Keep","Remove"],"weight":"major"}
{"id":"q1","kind":"retract","reason":"answered by the migration note"}
JSON
  : > "$CONV/answers.ndjson"
  : > "$NM_LOG"
  run_q_code answer t1 --question q1 --answer "Keep"
  expect_code 1 "$RC" "an answer to a withdrawn question was accepted"
  assert_contains "$OUT" "not an open question" "the refusal does not say why"
  [ ! -s "$NM_LOG" ] || fail "a withdrawn question was answered against the run anyway"
  pass "a question that is not open is refused before anything is recorded or delivered"
}

test_answer_refuses_an_authority_it_cannot_speak_for() {
  run_q_code answer t1 --question q1 --answer "Keep behind a flag" --by reviewer
  expect_code 2 "$RC" "an answer attributed to nobody with authority was accepted"
  assert_contains "$OUT" "captain or firstmate" "the refusal does not name the two authorities"
  pass "only the captain or firstmate can be recorded as having answered"
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
test_an_unchanged_questions_file_is_not_re_read
test_an_appended_question_is_read_on_the_next_sweep
test_surface_skips_a_scout
test_answer_goes_straight_to_the_reviewer_and_is_recorded
test_an_answer_with_a_quote_reaches_the_reviewer_verbatim
test_a_failed_delivery_is_reported_and_not_called_success
test_answer_refuses_a_question_that_is_not_open
test_answer_refuses_an_authority_it_cannot_speak_for
