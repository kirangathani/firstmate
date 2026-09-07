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
    printf 'total=%s failing=%s infra=%s pending=%s unknown=%s exempt=%s\n' \
      "$FM_PR_ROLLUP_TOTAL" "$FM_PR_ROLLUP_FAILING" "$FM_PR_ROLLUP_INFRA" \
      "$FM_PR_ROLLUP_PENDING" "$FM_PR_ROLLUP_UNKNOWN" "$FM_PR_ROLLUP_EXEMPT_FAILING"
    fm_pr_rollup_each "$FM_PR_ROLLUP_INFRA_NAMES" | sed 's/^/infra: /'
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
  assert_contains "$out" 'total=4 failing=0 infra=0 pending=0 unknown=0 exempt=0' \
    "SUCCESS/NEUTRAL/SKIPPED conclusions and a SUCCESS status context must all classify as passing"
  pass "classification: every passing shape counts as passing and nothing else"
}

# A check that reached a verdict about the code and said no. Somebody fixes the
# branch, so it is FAILING.
test_classify_failing_conclusions() {
  local out conclusion
  for conclusion in FAILURE ACTION_REQUIRED; do
    out=$(classify '' "$(printf 'CheckRun\tCOMPLETED\t%s\t-\tlint' "$conclusion")")
    assert_contains "$out" 'total=1 failing=1 infra=0 pending=0 unknown=0 exempt=0' \
      "a COMPLETED CheckRun with conclusion $conclusion must classify as failing"
    assert_contains "$out" 'failing: lint' "the $conclusion check was not named"
  done
  for conclusion in FAILURE ERROR; do
    out=$(classify '' "$(printf 'StatusContext\t-\t-\t%s\texternal-gate' "$conclusion")")
    assert_contains "$out" 'total=1 failing=1 infra=0 pending=0 unknown=0 exempt=0' \
      "a StatusContext in state $conclusion must classify as failing"
  done
  pass "classification: a check that reached a no verdict counts as failing"
}

# A check that never delivered a verdict about the code at all. The branch may be
# fine; the machinery is not. Re-running it hides the alarm, so it is its own
# class - the captain's standing rule of 2026-09-07.
test_classify_infrastructure_conclusions() {
  local out conclusion
  for conclusion in CANCELLED TIMED_OUT STALE STARTUP_FAILURE; do
    out=$(classify '' "$(printf 'CheckRun\tCOMPLETED\t%s\t-\tslow-suite' "$conclusion")")
    assert_contains "$out" 'total=1 failing=0 infra=1 pending=0 unknown=0 exempt=0' \
      "a COMPLETED CheckRun with conclusion $conclusion must classify as infrastructure, not as a red"
    assert_contains "$out" 'infra: slow-suite' "the $conclusion check was not named as infrastructure"
  done
  # The split must never make a non-green PR green: both classes are counted.
  out=$(classify '' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tlint' \
    $'CheckRun\tCOMPLETED\tTIMED_OUT\t-\tslow-suite')
  assert_contains "$out" 'total=2 failing=1 infra=1 pending=0 unknown=0 exempt=0' \
    "a PR carrying both a red and an infrastructure check must count both"
  pass "classification: a check that never reached a verdict counts as infrastructure, separately from a red"
}

# An excused check is excused whichever shape its failure took, so an exemption
# can never reappear as an infrastructure finding.
test_classify_exemption_covers_an_infrastructure_shape() {
  local out
  out=$(classify 'PR must be raised via no-mistakes' \
    $'CheckRun\tCOMPLETED\tTIMED_OUT\t-\tPR must be raised via no-mistakes')
  assert_contains "$out" 'total=1 failing=0 infra=0 pending=0 unknown=0 exempt=1' \
    "an exempt check that timed out must divert, not surface as an infrastructure finding"
  pass "classification: the exemption covers an infrastructure-shaped failure too"
}

test_classify_pending_states() {
  local out status
  for status in QUEUED IN_PROGRESS PENDING WAITING REQUESTED; do
    out=$(classify '' "$(printf 'CheckRun\t%s\t-\t-\tslow-suite' "$status")")
    assert_contains "$out" 'total=1 failing=0 infra=0 pending=1 unknown=0 exempt=0' \
      "a CheckRun with status $status must classify as pending"
  done
  for status in PENDING EXPECTED; do
    out=$(classify '' "$(printf 'StatusContext\t-\t-\t%s\texternal-gate' "$status")")
    assert_contains "$out" 'total=1 failing=0 infra=0 pending=1 unknown=0 exempt=0' \
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
  assert_contains "$out" 'total=2 failing=0 infra=0 pending=0 unknown=2 exempt=0' \
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
  assert_contains "$out" 'total=3 failing=1 infra=0 pending=0 unknown=0 exempt=2' \
    "each occurrence of the exempt name must divert, and every other failure must still count"
  assert_contains "$out" 'failing: lint' "a failure with another name was diverted by the exemption"

  out=$(classify 'PR must be raised via no-mistakes' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via no-mistakes (renamed)' \
    $'CheckRun\tIN_PROGRESS\t-\t-\tPR must be raised via no-mistakes')
  assert_contains "$out" 'total=2 failing=1 infra=0 pending=1 unknown=0 exempt=0' \
    "the exemption must match by exact name and must divert only a FAILING check"
  pass "classification: the exempt name is matched exactly and diverts only failures"
}

test_classify_empty_rollup_counts_nothing() {
  local out
  out=$(classify '')
  assert_contains "$out" 'total=0 failing=0 infra=0 pending=0 unknown=0 exempt=0' \
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
  *check-runs*)
    # The infrastructure-enrichment call. The case's infra-hints.tsv stands in
    # for what the jq over repos/<o>/<r>/commits/<sha>/check-runs would print:
    # "<name><TAB><reason>" per check run that looks like machinery. Absent
    # means the enrichment found nothing, and the unreadable marker makes the
    # call FAIL, which must degrade to the conclusion-only rule rather than
    # weakening any verdict.
    if [ -e '$case_dir/infra-unreadable' ]; then
      echo 'mock: check-runs query failed' >&2
      exit 1
    fi
    if [ -f '$case_dir/infra-hints.tsv' ]; then
      cat '$case_dir/infra-hints.tsv'
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

# The one excusable check is resolved through bin/fm-attestation-lib.sh, the
# owner the merge gate and the pipeline view already share, so this command
# cannot answer it differently from the merge that follows. With NO authority it
# is an ordinary failure. Without this, firstmate's own PRs - the project is
# registered direct-PR, so that check fails on every one by construction - would
# report red on every poll forever.
test_the_attestation_check_follows_the_shared_authority() {
  local case_dir rc out
  case_dir=$(make_green_case green-attestation)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via no-mistakes'

  # No registry, no signed skip: nothing excuses it, so it is an ordinary red.
  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-attestation: with no authority the check must count as failing"
  assert_grep 'error: PR check is failing: PR must be raised via no-mistakes' "$case_dir/stderr" \
    "green-attestation: the unexcused attestation check was not named"

  # Registering the project direct-PR is one of the two authorities the shared
  # owner recognizes, and that mode's PRs cannot carry the attestation at all.
  mkdir -p "$case_dir/fmhome/data" "$case_dir/project"
  printf -- '- project [direct-PR] - fixture (added 2026-09-07)\n' > "$case_dir/fmhome/data/projects.md"
  out=$(run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" 2>"$case_dir/stderr2"); rc=$?
  expect_code 0 "$rc" "green-attestation: a direct-PR project's PR must not be red for that check alone (stderr: $(cat "$case_dir/stderr2"))"
  assert_grep 'PR check excused' "$case_dir/stderr2" \
    "green-attestation: the excusal was not disclosed"
  # The count is what proves the excused check was not counted as evidence; the
  # trailing clause is what carries the reason into the worker's done line and
  # firstmate's confirmation, so a green with one excused red is auditable
  # rather than bare.
  [ "$out" = "green: $PR_URL $GREEN_SHA 1 checks (1 check excused: PR must be raised via no-mistakes - project is registered as a direct-PR project, whose PRs are raised without the pipeline by design)" ] \
    || fail "green-attestation: an excused check must not count as evidence and the green line must name why, got: $out"
  pass "fm-pr-green.sh: the one excusable check follows the shared authority, never counts as evidence, and names why it was excused"
}

# An excused check is an authorized red, not proof anything ran, so a rollup
# holding nothing else is the same false-green shape as an empty one. The merge
# gate has captain authorities that let that through; this command has none.
test_an_excused_only_rollup_is_not_green() {
  local case_dir rc
  case_dir=$(make_green_case green-attestation-only)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via no-mistakes'
  mkdir -p "$case_dir/fmhome/data" "$case_dir/project"
  printf -- '- project [direct-PR] - fixture (added 2026-09-07)\n' > "$case_dir/fmhome/data/projects.md"

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-attestation-only: a rollup left empty by discounting must not report green"
  assert_grep 'only check(s) were excused' "$case_dir/stderr" \
    "green-attestation-only: the outcome did not say the rollup was left with no evidence"
  assert_no_grep 'green:' "$case_dir/stdout" \
    "green-attestation-only: a rollup with no evidence printed a green line"
  pass "fm-pr-green.sh: a rollup left empty by discounting an excused check is not green"
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

# A check that timed out is an ALARM, not a red, and the outcome must say so in
# that word with the check named. The captain's standing rule of 2026-09-07: a
# timed-out review is never re-run.
test_a_timed_out_check_is_an_infrastructure_outcome_not_a_red() {
  local case_dir rc
  case_dir=$(make_green_case green-infra-conclusion)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tTIMED_OUT\t-\tbehaviour tests'

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-infra-conclusion: a timed-out check must not report green"
  assert_grep 'infrastructure: behaviour tests' "$case_dir/stderr" \
    "green-infra-conclusion: the timed-out check was not reported under the word infrastructure with its name"
  assert_grep 'not a red PR' "$case_dir/stderr" \
    "green-infra-conclusion: the outcome did not distinguish infrastructure from a red PR"
  assert_grep 'do NOT re-run them' "$case_dir/stderr" \
    "green-infra-conclusion: the outcome did not forbid re-running the check"
  assert_no_grep 'error: PR check is failing: behaviour tests' "$case_dir/stderr" \
    "green-infra-conclusion: a check that never reached a verdict was reported as a red"
  assert_no_grep 'green:' "$case_dir/stdout" "green-infra-conclusion: an infrastructure outcome printed a green line"
  pass "fm-pr-green.sh: a timed-out check is an infrastructure outcome, named and never a red"
}

# Rule 2: a check whose own report says it could not run. The rollup carries no
# report text at all, so this comes from the enrichment call on the head SHA.
test_a_check_reporting_it_could_not_run_is_infrastructure() {
  local case_dir rc
  case_dir=$(make_green_case green-infra-text)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" $'CheckRun\tCOMPLETED\tFAILURE\t-\tintegration'
  printf 'integration\tits report says the job did not run to a verdict\n' \
    > "$case_dir/infra-hints.tsv"

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-infra-text: a check that could not run must not report green"
  assert_grep 'infrastructure: integration - its report says the job did not run to a verdict' "$case_dir/stderr" \
    "green-infra-text: the check was not moved to infrastructure with its reason attached"
  assert_no_grep 'error: PR check is failing: integration' "$case_dir/stderr" \
    "green-infra-text: the check was still reported as a red"
  pass "fm-pr-green.sh: a check whose own report says it could not run is infrastructure, with the reason attached"
}

# The enrichment may only ever move a check from red to infrastructure. When its
# call FAILS, the conclusion-only rule still stands and the verdict is unchanged
# - a failed enrichment must never soften a red or produce a green.
test_a_failed_enrichment_degrades_without_weakening_the_verdict() {
  local case_dir rc
  case_dir=$(make_green_case green-infra-degraded)
  add_gh_mock "$case_dir"
  touch "$case_dir/infra-unreadable"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tlint' \
    $'CheckRun\tCOMPLETED\tSTARTUP_FAILURE\t-\tbehaviour tests'

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-infra-degraded: a failed enrichment must not report green"
  assert_grep 'infrastructure: behaviour tests' "$case_dir/stderr" \
    "green-infra-degraded: the conclusion-only infrastructure rule stopped working without the enrichment"
  assert_grep 'error: PR check is failing: lint' "$case_dir/stderr" \
    "green-infra-degraded: a red was softened by the enrichment failing"
  assert_no_grep 'green:' "$case_dir/stdout" "green-infra-degraded: a failed enrichment produced a green line"
  pass "fm-pr-green.sh: a failed enrichment degrades to the conclusion-only rule and weakens no verdict"
}

# A PR carrying both must report both, because the two have different remedies
# and reporting only one would send the reader at the wrong half.
test_a_red_and_an_infrastructure_check_are_both_reported() {
  local case_dir rc
  case_dir=$(make_green_case green-infra-and-red)
  add_gh_mock "$case_dir"
  write_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tlint' \
    $'CheckRun\tCOMPLETED\tCANCELLED\t-\tslow-suite'

  run_green "$case_dir" "$case_dir/cwd" task-g1 "$PR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 1 "$rc" "green-infra-and-red: a PR with both must not report green"
  assert_grep 'infrastructure: slow-suite' "$case_dir/stderr" \
    "green-infra-and-red: the infrastructure check was not reported"
  assert_grep 'error: PR check is failing: lint' "$case_dir/stderr" \
    "green-infra-and-red: the red check was not reported"
  assert_grep 'this PR is red' "$case_dir/stderr" \
    "green-infra-and-red: the red outcome was swallowed by the infrastructure one"
  pass "fm-pr-green.sh: a PR carrying both a red and an infrastructure check reports both"
}

# The enrichment jq must be a VALID PROGRAM, compiled from the script's own
# bytes. Every case above mocks gh, so all of them pass over a jq program that
# does not compile - which is exactly what shipped once: the program was built
# inside a double-quoted string, the shell mangled it into "unexpected token
# then", and the fallback swallowed the error, so the enrichment never ran
# against real GitHub while the suite stayed green. This test runs the real jq.
test_the_enrichment_jq_compiles_and_classifies() {
  local prog fixture out
  command -v jq >/dev/null 2>&1 || { pass "fm-pr-green.sh: enrichment jq check skipped (no jq)"; return; }
  prog="$TMP_ROOT/infra.jq"
  # Extract the single-quoted INFRA_JQ program from the script itself, so this
  # measures the shipped bytes rather than a copy that could drift.
  awk "/^INFRA_JQ='\$/ { grab = 1; next } grab && /^'\$/ { exit } grab { print }" \
    "$ROOT/bin/fm-pr-green.sh" > "$prog"
  [ -s "$prog" ] || fail "could not extract INFRA_JQ from bin/fm-pr-green.sh"

  fixture="$TMP_ROOT/check-runs.json"
  cat > "$fixture" <<'JSON'
{"check_runs":[
 {"name":"died-fast","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:02Z","output":{"title":null,"summary":null}},
 {"name":"said-timeout","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T01:00:00Z","output":{"title":"Job failed","summary":"The runner timed out waiting for the job"}},
 {"name":"honest-red","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:30:00Z","output":{"title":"3 tests failed","summary":"assertion x did not hold"}},
 {"name":"green-one","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:10:00Z","output":{"title":null,"summary":null}}
]}
JSON

  out=$(FM_PR_INFRA_SECONDS=10 jq -r -f "$prog" "$fixture" 2>&1) \
    || fail "the enrichment jq does not compile or run: $out"

  assert_contains "$out" "said-timeout" \
    "the enrichment did not catch a check whose own report says it timed out"
  assert_contains "$out" "died-fast" \
    "the enrichment did not catch a check that ended in seconds having written no report"
  assert_contains "$out" "may instead be a gate that refused fast" \
    "a fast-death finding must disclose that it may be a gate refusing fast, not a dead job"
  assert_not_contains "$out" "honest-red" \
    "the enrichment moved a genuine red with a real report into infrastructure"
  assert_not_contains "$out" "green-one" \
    "the enrichment moved a passing check into infrastructure"
  pass "fm-pr-green.sh: the enrichment jq compiles and separates dead machinery from a genuine red"
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
test_classify_infrastructure_conclusions
test_classify_exemption_covers_an_infrastructure_shape
test_classify_pending_states
test_classify_unclassifiable_entry_is_unknown
test_classify_exempt_name_is_exact_and_diverts_only_failures
test_classify_empty_rollup_counts_nothing
test_green_pr_reports_green_with_the_verified_head
test_failing_check_is_named_and_not_green
test_pending_check_is_distinct_from_red
test_zero_checks_is_never_green
test_the_enrichment_jq_compiles_and_classifies
test_a_timed_out_check_is_an_infrastructure_outcome_not_a_red
test_a_check_reporting_it_could_not_run_is_infrastructure
test_a_failed_enrichment_degrades_without_weakening_the_verdict
test_a_red_and_an_infrastructure_check_are_both_reported
test_the_attestation_check_follows_the_shared_authority
test_an_excused_only_rollup_is_not_green
test_unreadable_rollup_is_not_green
test_head_moving_mid_read_is_not_green
test_recorded_pr_is_used_when_no_url_is_given
test_no_recorded_pr_and_no_url_refuses_with_the_call_to_make
test_answers_from_a_detached_head_and_from_no_repository
test_malformed_request_is_refused
test_the_classification_table_has_exactly_one_implementation
