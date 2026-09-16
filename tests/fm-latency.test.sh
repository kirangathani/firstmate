#!/usr/bin/env bash
# tests/fm-latency.test.sh - firstmate's own latency ledger
# (bin/fm-latency-lib.sh, bin/fm-latency.sh, and the two hooks that feed them).
#
# Two things are being guarded, and only one of them is the numbers.
#
# The FIRST is that instrumentation can never break a fleet command. Every
# write is a silent no-op on failure and the exit status of the measured
# command is untouched, because the alternative is a merge that fails for want
# of a writable ledger. The cases below make the ledger unwritable in three
# different ways and assert the command still succeeds, and assert that both
# instrumented hooks still deny and block exactly what they denied and blocked
# before - by running them, not by reading them.
#
# The SECOND is that the numbers are the right numbers: the crew's own report
# time comes off its status line whether or not that line carries the
# "[t=<epoch>] " stamp, the enqueue epochs survive the drain that deletes the
# queue they came from, and a measured command's real exit status is recorded.
#
# tests/lib.sh exports FM_LATENCY_OFF=1 as a baseline for the whole suite, so
# every case here clears it for its own invocation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-latency-lib.sh
. "$ROOT/bin/fm-latency-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-latency)
# fm_test_tmproot's own header: called from a command substitution it installs
# its cleanup trap in that subshell, which fires and removes the directory
# before the caller sees it. Cases here write straight into the root.
mkdir -p "$TMP_ROOT"

unset FM_LATENCY_OFF

LIB="$ROOT/bin/fm-latency-lib.sh"
CLI="$ROOT/bin/fm-latency.sh"

expect_eq() {  # <expected> <actual> <label>
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

# A home with the data/ directory the ledger writes into and the state/ dir the
# hook markers live in.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

# Run <code> in a subshell with the library sourced against <home>, so a case
# cannot leak FM_LATENCY_CMD_* state into the next one.
in_home() {  # <home> <bash code>
  # A real child process, not a ( ) subshell: the library keeps per-invocation
  # state in FM_LATENCY_CMD_*, and a case must not be able to inherit the
  # previous case's half-finished measurement.
  FM_HOME="$1" FM_LATENCY_OFF='' bash -c 'set -u; . "$1"; shift; eval "$1"' _ "$LIB" "$2"
}

cell() {  # <ledger> <row-number-after-header> <column-name>
  LC_ALL=C awk -F'\t' -v want="$2" -v name="$3" '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    NR - 1 == want { print $(col[name]) }' "$1"
}

# --- the columns and the report ---------------------------------------------

test_the_header_is_written_once_and_columns_are_bare_numbers() {
  local home ledger
  home=$(make_home header)
  ledger="$home/data/latency.tsv"
  in_home "$home" 'fm_latency_cmd_start fm-x.sh t1; fm_latency_cmd_end 0'
  in_home "$home" 'fm_latency_cmd_start fm-y.sh t2; fm_latency_cmd_end 3'
  expect_eq 1 "$(grep -c '^epoch_ms' "$ledger")" "the header was written more than once"
  expect_eq 3 "$(grep -c . "$ledger")" "expected a header and two rows"
  expect_eq 11 "$(head -1 "$ledger" | awk -F'\t' '{print NF}')" "the header column count changed"
  expect_eq 3 "$(cell "$ledger" 2 exit_code)" "a measured command's real exit status was not recorded"
  # Every numeric cell is one bare number or empty: no units, no ranges, no
  # approximation marks, so the file stays analysable without a parser.
  LC_ALL=C awk -F'\t' '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    {
      split("epoch_ms duration_ms think_ms reported_epoch_ms enqueued_epoch_ms exit_code tools", n, " ")
      for (i in n) if ($(col[n[i]]) !~ /^([0-9]+)?$/) { print n[i] ": " $(col[n[i]]); bad = 1 }
    }
    END { exit bad ? 1 : 0 }' "$ledger" || fail "a numeric column holds something other than a bare number"
  pass "ledger: one header, eleven columns, and every numeric cell a bare number or empty"
}

test_the_report_prints_all_three_summaries() {
  local home out
  home=$(make_home report)
  in_home "$home" '
    fm_latency_cmd_start fm-send.sh t1; fm_latency_cmd_end 0
    fm_latency_tool_event bash
    fm_latency_turn_event'
  out=$(FM_HOME="$home" FM_LATENCY_OFF='' "$CLI" report 2>&1) || fail "report exited non-zero"
  assert_contains "$out" "response chain" "the report is missing the response-chain summary"
  assert_contains "$out" "model time" "the report is missing the model-time summary"
  assert_contains "$out" "measured commands" "the report is missing the per-command summary"
  assert_contains "$out" "fm-send.sh" "the report did not name the measured command"
  out=$(FM_HOME="$(make_home report-empty)" FM_LATENCY_OFF='' "$CLI" report 2>&1) || fail "report on an absent ledger exited non-zero"
  assert_contains "$out" "no ledger yet" "an absent ledger must say so rather than printing an empty report"
  pass "report: prints the response chain, model time, and per-command tables"
}

# --- the crew's report time, from both status-line forms ---------------------

test_wake_rows_read_both_status_forms_and_keep_the_enqueue_epoch() {
  local home ledger now
  home=$(make_home wake)
  ledger="$home/data/latency.tsv"
  now=$(date +%s)
  printf '[t=%s] done: PR up, checks green\n' "$((now - 40))" > "$home/state/timed.status"
  printf 'done: PR up, checks green\n' > "$home/state/legacy.status"
  in_home "$home" "printf '%s\\t1\\tsignal\\ttimed.status\\tchanged\\n%s\\t2\\tsignal\\tlegacy.status\\tchanged\\n' \
    $((now - 30)) $((now - 25)) | fm_latency_wake_rows"
  expect_eq "$((now - 40))000" "$(cell "$ledger" 1 reported_epoch_ms)" \
    "a timestamped crew report did not reach the ledger"
  expect_eq "$((now - 30))000" "$(cell "$ledger" 1 enqueued_epoch_ms)" \
    "the wake's enqueue epoch was lost"
  # An untimestamped line is the normal case for every status file that existed
  # before the stamp did. Empty means "not known", which is the correct answer:
  # a zero or a substituted drain time would read as an instant report and drag
  # every median that touches it.
  expect_eq "" "$(cell "$ledger" 2 reported_epoch_ms)" \
    "an untimestamped crew report must leave the cell empty, not invent a time"
  expect_eq "$((now - 25))000" "$(cell "$ledger" 2 enqueued_epoch_ms)" \
    "the second wake's enqueue epoch was lost"
  pass "wake rows: the crew's report time when it is known, empty when it is not, and always the enqueue epoch"
}

test_the_drain_records_wakes_without_changing_what_it_prints() {
  local home out rows
  home=$(make_home drain)
  printf '%s\t1\tsignal\tdrain-t1.status\tchanged\n' "$(date +%s)" > "$home/state/.wake-queue"
  printf 'working: going\n' > "$home/state/drain-t1.status"
  out=$(FM_HOME="$home" FM_LATENCY_OFF='' "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null) \
    || fail "the drain exited non-zero"
  assert_contains "$out" "signal" "the drain's raw output changed"
  assert_contains "$out" "drain-t1.status" "the drain no longer prints the consumed record"
  [ ! -s "$home/state/.wake-queue" ] || fail "the drain left records in the queue"
  rows=$(grep -c "	wake	" "$home/data/latency.tsv" 2>/dev/null || echo 0)
  expect_eq 1 "$rows" "the drain did not record its consumed wake"
  assert_grep "fm-wake-drain.sh" "$home/data/latency.tsv" "the drain did not measure itself"
  pass "drain: records the wake and its own time, and prints exactly what it printed before"
}

# --- instrumentation can never break a fleet command ------------------------

# Three genuinely different ways for a write to fail, because they fail at
# three different points: no data directory at all (the ledger is never
# created), the ledger present but unwritable, and the ledger's directory
# unwritable so the header append fails.
test_an_unwritable_ledger_is_a_silent_no_op() {
  local home rc out
  home="$TMP_ROOT/nodata"
  mkdir -p "$home/state"
  rc=0
  out=$(in_home "$home" 'fm_latency_cmd_start fm-x.sh; fm_latency_cmd_end 0; fm_latency_tool_event bash; fm_latency_turn_event; echo survived' 2>&1) || rc=$?
  expect_eq 0 "$rc" "a home with no data/ directory made the library fail"
  assert_contains "$out" survived "the library stopped the caller when it could not write"
  [ ! -e "$home/data" ] || fail "the library created the home's data directory; it must only write where one exists"

  home=$(make_home unwritable-file)
  : > "$home/data/latency.tsv"
  chmod 0444 "$home/data/latency.tsv"
  rc=0
  out=$(in_home "$home" 'fm_latency_cmd_start fm-x.sh; fm_latency_cmd_end 0; echo survived' 2>&1) || rc=$?
  chmod 0644 "$home/data/latency.tsv"
  expect_eq 0 "$rc" "an unwritable ledger made the library fail"
  assert_contains "$out" survived "an unwritable ledger stopped the caller"
  assert_not_contains "$out" "Permission denied" "the library leaked a write error to the caller's output"

  home=$(make_home unwritable-dir)
  chmod 0555 "$home/data"
  rc=0
  out=$(in_home "$home" 'fm_latency_cmd_start fm-x.sh; fm_latency_cmd_end 0; echo survived' 2>&1) || rc=$?
  chmod 0755 "$home/data"
  expect_eq 0 "$rc" "an unwritable data directory made the library fail"
  assert_contains "$out" survived "an unwritable data directory stopped the caller"
  pass "instrumentation: an unwritable ledger is a silent no-op, never a failure of the caller"
}

# The measured commands themselves, end to end: the exit status a caller sees
# must be the command's own, with the ledger broken underneath it.
test_a_measured_command_keeps_its_own_exit_status() {
  local home rc
  home=$(make_home exit-status)
  chmod 0555 "$home/data"
  rc=0
  FM_HOME="$home" FM_LATENCY_OFF='' "$ROOT/bin/fm-ack.sh" --list >/dev/null 2>&1 || rc=$?
  expect_eq 0 "$rc" "fm-ack.sh --list failed with an unwritable ledger"
  rc=0
  FM_HOME="$home" FM_LATENCY_OFF='' "$ROOT/bin/fm-ack.sh" no-such-task "note" >/dev/null 2>&1 || rc=$?
  expect_eq 1 "$rc" "fm-ack.sh lost its own refusal exit status to the instrumentation"
  chmod 0755 "$home/data"
  # And with a WORKING ledger, the same refusal still exits 1 and is recorded
  # with that status rather than as a success.
  rc=0
  FM_HOME="$home" FM_LATENCY_OFF='' "$ROOT/bin/fm-ack.sh" no-such-task "note" >/dev/null 2>&1 || rc=$?
  expect_eq 1 "$rc" "fm-ack.sh lost its refusal exit status once the ledger worked"
  assert_grep "fm-ack.sh" "$home/data/latency.tsv" "the refused ack was not measured"
  pass "instrumentation: a measured command's own exit status reaches its caller either way"
}

test_the_off_switch_records_nothing() {
  local home
  home=$(make_home off)
  FM_HOME="$home" FM_LATENCY_OFF=1 bash -c '
    set -u
    . "$1"
    fm_latency_cmd_start fm-x.sh; fm_latency_cmd_end 0
    fm_latency_tool_event bash
    fm_latency_turn_event
    printf "x\t1\tsignal\tt.status\tn\n" | fm_latency_wake_rows
  ' _ "$LIB"
  [ ! -e "$home/data/latency.tsv" ] || fail "FM_LATENCY_OFF still wrote to the ledger"
  pass "instrumentation: FM_LATENCY_OFF records nothing at all"
}

# --- the hooks still block exactly what they blocked ------------------------

# A primary-shaped checkout: a real plain (non-worktree) git repo, so BOTH the
# turn-end guard's git-based fm_primary_scope_matches and the pre-tool hook's
# cheap stat-only approximation of it accept the same directory. A hand-made
# .git directory would satisfy the cheap test and fail the real one, which is
# the disagreement these cases exist to rule out.
#
# The scenario's bin/ is derived from the real bin/ at run time, never a
# hand-listed set of the hooks' dependencies: such a list rots the moment a
# hook gains a sibling, and it took main red once before (tests/lib.sh's own
# notes, #44).
make_scoped_root() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/bin" "$dir/data" "$dir/state"
  cp -R "$ROOT"/bin/. "$dir/bin/"
  cp -R "$ROOT/docs" "$dir/docs"
  printf '# scratch\n' > "$dir/AGENTS.md"
  git init -q "$dir"
  printf '%s\n' "$dir"
}

test_the_pretool_seatbelt_still_denies_with_the_ledger_recording() {
  local dir rc out err
  dir=$(make_scoped_root arm-scoped)
  # A denied watcher-arm anti-pattern and an allowed standalone arm, run
  # through the real transport with the ledger live underneath it.
  rc=0
  err=$(FM_HOME="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-arm-pretool-check.sh" --claude \
    --command 'bin/fm-watch-arm.sh &' 2>&1 >/dev/null) || rc=$?
  expect_eq 2 "$rc" "the seatbelt stopped denying a backgrounded arm"
  assert_contains "$err" '"permissionDecision":"deny"' "the deny object changed shape"
  rc=0
  out=$(FM_HOME="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-arm-pretool-check.sh" --claude \
    --command 'bin/fm-watch-arm.sh' 2>&1) || rc=$?
  expect_eq 0 "$rc" "the seatbelt stopped allowing a standalone arm"
  expect_eq "" "$out" "an allowed command must produce no output"
  # Both calls were recorded, which is the point of putting the measurement
  # before the fast-allow path rather than after it.
  expect_eq 2 "$(grep -c "	tool	" "$dir/data/latency.tsv")" \
    "the pre-tool hook did not record both calls"
  pass "hooks: the pre-tool seatbelt denies and allows exactly as before while recording"
}

test_the_pretool_seatbelt_still_denies_when_the_ledger_cannot_be_written() {
  local dir rc err
  dir=$(make_scoped_root arm-broken)
  chmod 0555 "$dir/data"
  rc=0
  err=$(FM_HOME="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-arm-pretool-check.sh" --claude \
    --command 'bin/fm-watch-arm.sh &' 2>&1 >/dev/null) || rc=$?
  chmod 0755 "$dir/data"
  expect_eq 2 "$rc" "a broken ledger changed what the seatbelt denies"
  assert_contains "$err" '"permissionDecision":"deny"' "a broken ledger changed the deny object"
  assert_not_contains "$err" "Permission denied" "the hook leaked a ledger write error into its deny output"
  pass "hooks: a ledger that cannot be written does not change what the seatbelt denies"
}

# The measurement must not touch the payload this hook consumes later. A stdin
# transport case proves it end to end: if the block above read stdin, the
# command would never reach the classifier and the deny would silently vanish.
test_the_pretool_measurement_leaves_stdin_for_the_transport() {
  local dir rc err
  dir=$(make_scoped_root arm-stdin)
  command -v jq >/dev/null 2>&1 || { pass "hooks: stdin transport case skipped, jq absent"; return 0; }
  rc=0
  err=$(printf '{"tool_input":{"command":"bin/fm-watch-arm.sh &"}}' \
    | FM_HOME="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-arm-pretool-check.sh" --claude 2>&1 >/dev/null) || rc=$?
  expect_eq 2 "$rc" "the measurement consumed the payload the stdin transport needs"
  assert_contains "$err" '"permissionDecision":"deny"' "the stdin transport's deny object changed"
  pass "hooks: the measurement leaves the PreToolUse payload on stdin for the transport"
}

test_the_hooks_record_nothing_outside_a_primary_home() {
  local dir rc
  # A linked task worktree's .git is a FILE, which is what the cheap scope test
  # reads. This file is tracked, so it is checked out into every one of them.
  dir="$TMP_ROOT/child-worktree"
  mkdir -p "$dir/bin" "$dir/data" "$dir/state"
  cp -R "$ROOT"/bin/. "$dir/bin/"
  printf 'gitdir: /somewhere/.git/worktrees/child\n' > "$dir/.git"
  rc=0
  FM_HOME="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-arm-pretool-check.sh" --claude \
    --command 'echo hello' >/dev/null 2>&1 || rc=$?
  expect_eq 0 "$rc" "the seatbelt refused an ordinary command in a task worktree"
  [ ! -e "$dir/data/latency.tsv" ] || fail "a task worktree's tool calls were recorded into a ledger"
  pass "hooks: a child task worktree records nothing"
}

test_the_turnend_guard_still_blocks_with_the_ledger_recording() {
  local dir rc err
  dir=$(make_scoped_root turnend)
  # An in-flight task with no watcher beacon at all is the guard's original
  # block reason; tests/fm-turnend-guard.test.sh owns the full matrix.
  : > "$dir/state/task1.meta"
  command -v jq >/dev/null 2>&1 || { pass "hooks: turn-end case skipped, jq absent"; return 0; }
  rc=0
  err=$(printf '{"stop_hook_active":false}' \
    | FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-turnend-guard.sh" 2>&1 >/dev/null) || rc=$?
  expect_eq 2 "$rc" "the turn-end guard stopped blocking a blind turn"
  assert_contains "$err" "TURN WOULD END BLIND" "the guard's banner changed"
  expect_eq 1 "$(grep -c "	turn	" "$dir/data/latency.tsv")" "the turn-end hook recorded no turn"

  # The loop guard still short-circuits, and a re-stop inside the same turn is
  # deliberately NOT counted as a second turn.
  rc=0
  printf '{"stop_hook_active":true}' \
    | FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1 || rc=$?
  expect_eq 0 "$rc" "the loop guard stopped allowing a forced re-stop"
  expect_eq 1 "$(grep -c "	turn	" "$dir/data/latency.tsv")" "a forced re-stop was counted as another turn"
  pass "hooks: the turn-end guard blocks and short-circuits exactly as before while recording"
}

test_the_turnend_guard_stays_silent_on_a_healthy_turn() {
  local dir out rc
  dir=$(make_scoped_root turnend-quiet)
  command -v jq >/dev/null 2>&1 || { pass "hooks: quiet turn-end case skipped, jq absent"; return 0; }
  rc=0
  # No in-flight task at all, so the guard has nothing to say. Every caller
  # captures this hook's output, so a healthy turn that prints anything is
  # indistinguishable from an alarm - the measurement must not make noise.
  out=$(printf '{"stop_hook_active":false}' \
    | FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_LATENCY_OFF='' "$dir/bin/fm-turnend-guard.sh" 2>&1) || rc=$?
  expect_eq 0 "$rc" "a healthy turn was blocked"
  expect_eq "" "$out" "the measurement made a healthy turn noisy"
  expect_eq 1 "$(grep -c "	turn	" "$dir/data/latency.tsv")" "a healthy turn was not recorded"
  pass "hooks: a healthy turn stays byte-silent and is still recorded"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck absent, skipped"; return 0; }
  shellcheck -x "$LIB" "$CLI" "${BASH_SOURCE[0]}" || fail "shellcheck findings in the latency scripts"
  pass "bin/fm-latency.sh, bin/fm-latency-lib.sh and this suite are shellcheck-clean"
}

test_the_header_is_written_once_and_columns_are_bare_numbers
test_the_report_prints_all_three_summaries
test_wake_rows_read_both_status_forms_and_keep_the_enqueue_epoch
test_the_drain_records_wakes_without_changing_what_it_prints
test_an_unwritable_ledger_is_a_silent_no_op
test_a_measured_command_keeps_its_own_exit_status
test_the_off_switch_records_nothing
test_the_pretool_seatbelt_still_denies_with_the_ledger_recording
test_the_pretool_seatbelt_still_denies_when_the_ledger_cannot_be_written
test_the_pretool_measurement_leaves_stdin_for_the_transport
test_the_hooks_record_nothing_outside_a_primary_home
test_the_turnend_guard_still_blocks_with_the_ledger_recording
test_the_turnend_guard_stays_silent_on_a_healthy_turn
test_scripts_are_shellcheck_clean
