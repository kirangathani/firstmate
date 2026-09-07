#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-green.sh and for the rollup reading and
# classification it shares with bin/fm-pr-merge.sh (bin/fm-pr-lib.sh:
# fm_pr_rollup_read, fm_pr_rollup_classify, fm_pr_rollup_each).
#
# Why this suite exists at all: the no-mistakes pipeline's own `ci` step polls
# `gh pr checks` with no PR number from a detached-HEAD worktree, so gh exits 1
# on every poll and the step never sees a green PR. bin/fm-pr-green.sh is what a
# ship worker runs instead, so the property that matters most here is that it is
# addressed by PR URL and answers correctly from a detached HEAD and from a
# directory that is no git repository at all.
#
# The classification cases below are deliberately the same cases
# tests/fm-pr-merge.test.sh drives through the merge gate. They are asserted
# here against the extracted function directly, so a change to the table is
# caught at the one owner rather than only through one of its two callers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-green)

# --- the extracted classification table -------------------------------------

# classify <exempt-name> <tsv line>...: run fm_pr_rollup_classify in a subshell
# that sources the library, and echo the counts as a single scannable line plus
# the collected names. Run in a subshell so one case's globals cannot leak into
# the next.
classify() {
  local exempt=$1
  shift
  local tsv
  tsv=$(printf '%s\n' "$@")
  (
    # shellcheck source=bin/fm-pr-lib.sh
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_rollup_classify "$tsv" "$exempt"
    printf 'total=%s failing=%s pending=%s unknown=%s exempt=%s\n' \
      "$FM_PR_ROLLUP_TOTAL" "$FM_PR_ROLLUP_FAILING" "$FM_PR_ROLLUP_PENDING" \
      "$FM_PR_ROLLUP_UNKNOWN" "$FM_PR_ROLLUP_EXEMPT_FAILING"
    fm_pr_rollup_each "$FM_PR_ROLLUP_FAILING_NAMES" | sed 's/^/failing: /'
    fm_pr_rollup_each "$FM_PR_ROLLUP_PENDING_NAMES" | sed 's/^/pending: /'
    fm_pr_rollup_each "$FM_PR_ROLLUP_UNKNOWN_NAMES" | sed 's/^/unknown: /'
  )
}

test_classify_passing_conclusions() {
  local out
  out=$(classify '' \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tNEUTRAL\t-\toptional-scan' \
    $'CheckRun\tCOMPLETED\tSKIPPED\t-\tpath-filtered' \
    $'StatusContext\t-\t-\tSUCCESS\texternal-gate')
  assert_contains "$out" 'total=4 failing=0 pending=0 unknown=0 exempt=0' \
    "SUCCESS/NEUTRAL/SKIPPED conclusions and a SUCCESS status context must all classify as passing"
  pass "classification: every passing shape counts as passing and nothing else"
}

test_classify_failing_conclusions() {
  local out conclusion
  for conclusion in FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STALE STARTUP_FAILURE; do
    out=$(classify '' "$(printf 'CheckRun\tCOMPLETED\t%s\t-\tlint' "$conclusion")")
    assert_contains "$out" 'total=1 failing=1 pending=0 unknown=0 exempt=0' \
      "a COMPLETED CheckRun with conclusion $conclusion must classify as failing"
    assert_contains "$out" 'failing: lint' "the $conclusion check was not named"
  done
  for conclusion in FAILURE ERROR; do
    out=$(classify '' "$(printf 'StatusContext\t-\t-\t%s\texternal-gate' "$conclusion")")
    assert_contains "$out" 'total=1 failing=1 pending=0 unknown=0 exempt=0' \
      "a StatusContext in state $conclusion must classify as failing"
  done
  pass "classification: every failing conclusion and status-context state counts as failing"
}

test_classify_pending_states() {
  local out status
  for status in QUEUED IN_PROGRESS PENDING WAITING REQUESTED; do
    out=$(classify '' "$(printf 'CheckRun\t%s\t-\t-\tslow-suite' "$status")")
    assert_contains "$out" 'total=1 failing=0 pending=1 unknown=0 exempt=0' \
      "a CheckRun with status $status must classify as pending"
  done
  for status in PENDING EXPECTED; do
    out=$(classify '' "$(printf 'StatusContext\t-\t-\t%s\texternal-gate' "$status")")
    assert_contains "$out" 'total=1 failing=0 pending=1 unknown=0 exempt=0' \
      "a StatusContext in state $status must classify as pending"
  done
  pass "classification: every queued or running shape counts as pending"
}

# An entry the table cannot read is counted UNKNOWN, never quietly passing: a
# verdict that cannot be reached must not read as green.
test_classify_unclassifiable_entry_is_unknown() {
  local out
  out=$(classify '' \
    $'CheckRun\tCOMPLETED\tMYSTERY\t-\tnovel-conclusion' \
    $'Wormhole\t-\t-\t-\tnovel-typename')
  assert_contains "$out" 'total=2 failing=0 pending=0 unknown=2 exempt=0' \
    "an unrecognized conclusion or typename must count as unknown, not passing"
  assert_contains "$out" 'unknown: novel-conclusion (type=CheckRun status=COMPLETED conclusion=MYSTERY state=-)' \
    "an unknown entry must be reported with the fields that could not be read"
  pass "classification: an entry the table cannot read counts as unknown"
}

# The exempt name is matched by EXACT equality, so a renamed job falls straight
# through to the ordinary failing count. A rename can only ever cost a merge.
test_classify_exempt_name_is_exact_and_diverts_only_failures() {
  local out
  out=$(classify 'PR must be raised via no-mistakes' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via no-mistakes' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via no-mistakes' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tlint')
  assert_contains "$out" 'total=3 failing=1 pending=0 unknown=0 exempt=2' \
    "each occurrence of the exempt name must divert, and every other failure must still count"
  assert_contains "$out" 'failing: lint' "a failure with another name was diverted by the exemption"

  out=$(classify 'PR must be raised via no-mistakes' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via no-mistakes (renamed)' \
    $'CheckRun\tIN_PROGRESS\t-\t-\tPR must be raised via no-mistakes')
  assert_contains "$out" 'total=2 failing=1 pending=1 unknown=0 exempt=0' \
    "the exemption must match by exact name and must divert only a FAILING check"
  pass "classification: the exempt name is matched exactly and diverts only failures"
}

test_classify_empty_rollup_counts_nothing() {
  local out
  out=$(classify '')
  assert_contains "$out" 'total=0 failing=0 pending=0 unknown=0 exempt=0' \
    "an empty rollup must count no checks at all"
  pass "classification: an empty rollup counts nothing"
}

# --- bin/fm-pr-green.sh ------------------------------------------------------

PR_URL=https://github.com/example/repo/pull/91
GREEN_SHA=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678

# make_green_case <name>: a case dir holding fmhome/state with a task meta that
# records PR_URL, plus a fakebin. Echoes the case dir.
make_green_case() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/fmhome/state" "$case_dir/fakebin" "$case_dir/cwd"
  fm_write_meta "$case_dir/fmhome/state/task-g1.meta" \
    "window=firstmate:fm-task-g1" \
    "worktree=$case_dir/cwd" \
    "project=$case_dir/project" \
    "pr=$PR_URL"
  printf '%s\n' "$case_dir"
}

# add_gh_mock <case_dir> [head_sha]: a gh mock answering headRefOid with
# <head_sha> (or the case's head.txt when present, re-read on every call so a
# case can make the head MOVE between the two reads) and statusCheckRollup from
# the case's pr-checks.tsv. The rollup read fails when pr-checks-unreadable
# exists, and the head read fails when head-unreadable exists.
add_gh_mock() {
  local case_dir=$1 head=${2:-$GREEN_SHA}
  printf '%s\n' "$head" > "$case_dir/head.txt"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *headRefOid*)
    if [ -e '$case_dir/head-unreadable' ]; then
      echo 'mock: head query failed' >&2
      exit 1
    fi
    # A case that needs the head to MOVE swaps head.txt for head-next.txt after
    # the first read, which is what the mid-read race case drives.
    cat '$case_dir/head.txt'
    if [ -f '$case_dir/head-next.txt' ]; then
      mv '$case_dir/head-next.txt' '$case_dir/head.txt'
    fi
    exit 0
    ;;
  *statusCheckRollup*)
    if [ -e '$case_dir/pr-checks-unreadable' ]; then
      echo 'mock: rollup query failed' >&2
      exit 1
    fi
    if [ -f '$case_dir/pr-checks.tsv' ]; then
      cat '$case_dir/pr-checks.tsv'
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# write_checks <case_dir> <tsv line>...: the mocked rollup answer, in the
# classifier's own TSV shape. Pass none for a zero-check PR.
write_checks() {
  local case_dir=$1
  shift
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$case_dir/pr-checks.tsv"
  else
    : > "$case_dir/pr-checks.tsv"
  fi
}

# run_green <case_dir> <cwd> <args...>: run bin/fm-pr-green.sh from <cwd> with
# the case's fakebin ahead of PATH and its FM_HOME pinned.
run_green() {
  local case_dir=$1 cwd=$2
  shift 2
  ( cd "$cwd" && PATH="$case_dir/fakebin:$PATH" FM_HOME="$case_dir/fmhome" \
    "$ROOT/bin/fm-pr-green.sh" "$@" )
}

test_green_pr_reports_green_with_the_verified_head() {
  local case_dir out rc
  case_dir=$(make_green_case green-ok)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tSKIPPED\t-\tpath-filtered' \
    $'StatusContext\t-\t-\tSUCCESS\texternal-gate'

  out=$(run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" 2>"$case_dir/stderr"); rc=$?
  expect_code 0 "$rc" "green-ok: a green PR must exit 0 (stderr: $(cat "$case_dir/stderr"))"
  [ "$out" = "green: $PR_URL $GREEN_SHA 3 checks" ] \
    || fail "green-ok: expected the one-line green report with the verified head, got: $out"
  pass "fm-pr-green.sh: a green PR reports green with its verified head commit and check count"
}

test_failing_check_is_named_and_not_green() {
  local case_dir rc
  case_dir=$(make_green_case green-red)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tlint'

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-red: a red PR must not report green"
  assert_grep 'error: PR check is failing: lint' "$case_dir/stderr" \
    "green-red: the failing check was not named"
  assert_no_grep 'green:' "$case_dir/stdout" "green-red: a red PR printed a green line"
  pass "fm-pr-green.sh: a failing check is named and never reports green"
}

test_pending_check_is_distinct_from_red() {
  local case_dir rc
  case_dir=$(make_green_case green-pending)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tIN_PROGRESS\t-\t-\tslow-suite'

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-pending: an unfinished PR must not report green"
  assert_grep 'note: PR check has not finished: slow-suite' "$case_dir/stderr" \
    "green-pending: the pending check was not named"
  assert_grep 'not red, it is unfinished' "$case_dir/stderr" \
    "green-pending: the outcome did not distinguish pending from red"
  assert_no_grep 'this PR is red' "$case_dir/stderr" \
    "green-pending: a merely-pending PR was reported as red"
  pass "fm-pr-green.sh: a pending check reads as unfinished, distinctly from red"
}

# Zero checks is never green here, with no marker and no waiver route: this
# command asks whether CI actually went green, and an empty rollup is
# indistinguishable from CI that has not reported yet.
test_zero_checks_is_never_green() {
  local case_dir rc
  case_dir=$(make_green_case green-zero)
  add_gh_mock "$case_dir"
  write_checks "$case_dir"

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-zero: a PR reporting no checks must not report green"
  assert_grep 'no checks at all' "$case_dir/stderr" \
    "green-zero: the refusal did not say the PR reported no checks"
  assert_no_grep 'green:' "$case_dir/stdout" "green-zero: an empty rollup printed a green line"
  pass "fm-pr-green.sh: a PR reporting zero checks is never green"
}

# This command excuses nothing, so its green is strictly the stronger reading:
# the one check the merge gate may excuse under a captain's authority is an
# ordinary failure here.
test_the_attestation_check_is_not_excused_here() {
  local case_dir rc
  case_dir=$(make_green_case green-attestation)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via no-mistakes'

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-attestation: no check is excused by this command"
  assert_grep 'error: PR check is failing: PR must be raised via no-mistakes' "$case_dir/stderr" \
    "green-attestation: the failing attestation check was not named"
  pass "fm-pr-green.sh: it excuses no check, so its green is the stronger reading"
}

test_unreadable_rollup_is_not_green() {
  local case_dir rc
  case_dir=$(make_green_case green-unreadable)
  add_gh_mock "$case_dir"
  touch "$case_dir/pr-checks-unreadable"

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-unreadable: a rollup that cannot be read must not report green"
  assert_grep 'could not read' "$case_dir/stderr" \
    "green-unreadable: the failure did not say the checks could not be read"
  assert_grep 'mock: rollup query failed' "$case_dir/stderr" \
    "green-unreadable: the underlying gh error was swallowed"
  pass "fm-pr-green.sh: a rollup that cannot be read is not green"
}

# A head that moved between the two reads means the rollup and the SHA describe
# different commits, which is exactly the false-green this command prevents.
test_head_moving_mid_read_is_not_green() {
  local case_dir rc
  case_dir=$(make_green_case green-head-moved)
  add_gh_mock "$case_dir"
  printf '%s\n' 0000000000000000000000000000000000000abc > "$case_dir/head-next.txt"
  write_checks "$case_dir" $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests'

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-head-moved: a head that moved mid-read must not report green"
  assert_grep "head moved from $GREEN_SHA" "$case_dir/stderr" \
    "green-head-moved: the outcome did not name both heads"
  assert_no_grep 'green:' "$case_dir/stdout" "green-head-moved: a moved head printed a green line"
  pass "fm-pr-green.sh: checks read across a head that moved are not green"
}

# The recorded pr= is the fallback, used when no URL is given. That is
# firstmate's case, after bin/fm-pr-check.sh has recorded the link.
test_recorded_pr_is_used_when_no_url_is_given() {
  local case_dir out rc
  case_dir=$(make_green_case green-recorded)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests'

  out=$(run_green "$case_dir" "$case_dir/cwd" task-g1 2>"$case_dir/stderr"); rc=$?
  expect_code 0 "$rc" "green-recorded: the recorded pr= must be used (stderr: $(cat "$case_dir/stderr"))"
  [ "$out" = "green: $PR_URL $GREEN_SHA 1 checks" ] \
    || fail "green-recorded: the recorded PR link was not used, got: $out"
  pass "fm-pr-green.sh: with no URL given it uses the task's recorded PR link"
}

# With neither a URL nor a recorded pr=, it refuses and says how to call it. A
# worker polling right after the pipeline opened the PR is exactly this case:
# firstmate has not recorded the link yet.
test_no_recorded_pr_and_no_url_refuses_with_the_call_to_make() {
  local case_dir rc
  case_dir=$(make_green_case green-no-pr)
  add_gh_mock "$case_dir"
  fm_write_meta "$case_dir/fmhome/state/task-g1.meta" \
    "window=firstmate:fm-task-g1" \
    "worktree=$case_dir/cwd"

  run_green "$case_dir" "$case_dir/cwd" task-g1 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 2 "$rc" "green-no-pr: an unusable PR reference must be a malformed request"
  assert_grep 'no PR is recorded' "$case_dir/stderr" \
    "green-no-pr: the refusal did not say no PR was recorded"
  assert_grep 'fm-pr-green.sh task-g1 <pr-url>' "$case_dir/stderr" \
    "green-no-pr: the refusal did not print the call to make instead"
  pass "fm-pr-green.sh: with no recorded PR and no URL it refuses and names the call to make"
}

# THE POINT OF THE COMMAND. The pipeline's own ci step fails from a detached
# HEAD because it shells out to `gh pr checks` with no PR number. This command
# is addressed by URL, so it must answer identically from a detached HEAD and
# from a directory that is no git repository at all.
test_answers_from_a_detached_head_and_from_no_repository() {
  local case_dir out rc
  case_dir=$(make_green_case green-detached)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests'

  fm_git_init_commit "$case_dir/detached"
  git -C "$case_dir/detached" checkout -q --detach HEAD
  git -C "$case_dir/detached" symbolic-ref HEAD >/dev/null 2>&1 \
    && fail "green-detached: the fixture repo is not actually at a detached HEAD"

  out=$(run_green "$case_dir" "$case_dir/detached" task-g1 "$PR_URL" 2>"$case_dir/stderr"); rc=$?
  expect_code 0 "$rc" "green-detached: a detached HEAD must not stop the read (stderr: $(cat "$case_dir/stderr"))"
  [ "$out" = "green: $PR_URL $GREEN_SHA 1 checks" ] \
    || fail "green-detached: wrong answer from a detached HEAD: $out"

  mkdir -p "$case_dir/norepo"
  out=$(run_green "$case_dir" "$case_dir/norepo" task-g1 "$PR_URL" 2>"$case_dir/stderr2"); rc=$?
  expect_code 0 "$rc" "green-norepo: a non-repository cwd must not stop the read (stderr: $(cat "$case_dir/stderr2"))"
  [ "$out" = "green: $PR_URL $GREEN_SHA 1 checks" ] \
    || fail "green-norepo: wrong answer from a directory that is no git repository: $out"
  pass "fm-pr-green.sh: it answers from a detached HEAD and from no repository at all"
}

test_malformed_request_is_refused() {
  local case_dir rc
  case_dir=$(make_green_case green-malformed)
  add_gh_mock "$case_dir"

  run_green "$case_dir" "$case_dir/cwd" ../escape "$PR_URL" \
    > /dev/null 2> "$case_dir/stderr"; rc=$?
  expect_code 2 "$rc" "green-malformed: a path-unsafe task id must be refused"

  run_green "$case_dir" "$case_dir/cwd" task-g1 https://example.com/not/a/pr \
    > /dev/null 2> "$case_dir/stderr2"; rc=$?
  expect_code 2 "$rc" "green-malformed: a link that is not a GitHub PR must be refused"
  assert_grep 'not a GitHub pull request link' "$case_dir/stderr2" \
    "green-malformed: the refusal did not name the bad link"
  pass "fm-pr-green.sh: a path-unsafe task id and a non-PR link are both refused"
}

# The merge gate and this command must keep ONE verdict-bearing reading of the
# rollup, not two. The classification table is what carries that verdict, so a
# second copy of it under bin/ is the drift this extraction removed reappearing
# - and a table that lived in two places would let a worker report green on a
# PR the merge gate then refuses, or the reverse.
# STARTUP_FAILURE stands in for the table: it appears in no other context.
# bin/fm-pr-merge.sh keeps it in its POLICY HEADER, which is where the contract
# is owned; only a non-comment occurrence is a second implementation.
# bin/fm-flow-snapshot.sh is deliberately NOT covered: it answers a different
# question - a display count that must agree with what `gh pr checks` prints for
# the captain - and docs/flow-tui.md owns that contract.
test_the_classification_table_has_exactly_one_implementation() {
  local hits
  hits=$(grep -rl -- 'STARTUP_FAILURE' "$ROOT/bin" \
    | while IFS= read -r f; do
        grep -q '^[[:space:]]*[^#[:space:]].*STARTUP_FAILURE' "$f" && printf '%s\n' "$f"
      done)
  [ "$hits" = "$ROOT/bin/fm-pr-lib.sh" ] \
    || fail "the check classification table must be implemented only in bin/fm-pr-lib.sh, found it in: ${hits:-nothing}"
  pass "one owner: the check classification table is implemented in bin/fm-pr-lib.sh and nowhere else"
}

test_classify_passing_conclusions
test_classify_failing_conclusions
test_classify_pending_states
test_classify_unclassifiable_entry_is_unknown
test_classify_exempt_name_is_exact_and_diverts_only_failures
test_classify_empty_rollup_counts_nothing
test_green_pr_reports_green_with_the_verified_head
test_failing_check_is_named_and_not_green
test_pending_check_is_distinct_from_red
test_zero_checks_is_never_green
test_the_attestation_check_is_not_excused_here
test_unreadable_rollup_is_not_green
test_head_moving_mid_read_is_not_green
test_recorded_pr_is_used_when_no_url_is_given
test_no_recorded_pr_and_no_url_refuses_with_the_call_to_make
test_answers_from_a_detached_head_and_from_no_repository
test_malformed_request_is_refused
test_the_classification_table_has_exactly_one_implementation
