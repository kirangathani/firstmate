#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-check.sh's unpushed-work refusal, for the
# already-merged warning beside it, and for the multi-PR case that made the
# recorded fact follow the task: re-recording must MOVE the `pr=` and re-arm the
# merge poll against the new PR, retiring the previous PR's poll rather than
# leaving it firing `merged` at a PR nobody is waiting for.
#
# Recording a PR-ready task must REFUSE when the PR does not carry work the task
# has already committed. Measured 2026-09-16 on fm-brief-attach-ownership-a3: the
# worker made its fix commit 0b16c1b3, reported `done: PR .../97`, and stopped
# with the PR's head still at the pre-fix 8b2da7d5, so the red firstmate then
# read was CI's verdict on the version BEFORE the fix - it said nothing about the
# branch, and only a hand comparison of the two shas caught it.
#
# This is the moment both shas are in hand, and it is before the merge poll is
# armed, which is what makes it the right refusal point: under the standing merge
# rule a poll armed on a PR missing the fix is an auto-merge of the wrong commit.
#
# THE SILENT CASES ARE THE POINT, not padding. `behind` above all: a no-mistakes
# PR is pushed by the pipeline from its own worktree under ~/.no-mistakes/, so
# the task's own copy legitimately lags the PR head. Refusing on that would break
# every pipeline task. The refusal asks one ancestry question in the direction
# that needs no second fact - is the PR head a strict ancestor of this copy's
# tip - so a moved-on branch refuses while behind and unrelated stay silent.
#
# These live in their own file rather than in tests/fm-pr-check-security.test.sh,
# which owns URL/ID safety: that suite runs concurrency and watcher cases and
# takes minutes, and appending to it coupled these cheap git-fixture checks to
# its runtime.
set -u

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SUITE_DIR/lib.sh"
fm_git_identity

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-pr-check-head)

# A case is a task home, a fake gh answering the two projections fm-pr-check.sh
# reads, a real project repo, and a task worktree on fm/<id> carrying one commit
# that was never pushed. Echoes "<dir> <local-tip>".
make_head_case() {
  local name=$1 id=task-a dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$fakebin" "$dir/root/bin"

  # fm-pr-check.sh calls the guard; it is not under test here.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/root/bin/fm-guard.sh"
  chmod +x "$dir/root/bin/fm-guard.sh"

  # The two reads are separate calls on purpose (see fm-pr-check.sh), so the
  # stub answers each projection on its own, exactly as gh does.
  # fm-pr-check.sh reads exactly one projection, the same headRefOid every other
  # suite's mock already answers. Nothing here has to know a branch name.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:?}" ;;
  *" state "*) [ -z "${FM_TEST_GH_STATE:-}" ] || printf '%s\n' "$FM_TEST_GH_STATE" ;;
esac
SH
  chmod +x "$fakebin/gh"

  git init -q -b main "$dir/project" 2>/dev/null || {
    git init -q "$dir/project"
    git -C "$dir/project" checkout -q -b main
  }
  printf 'baseline\n' > "$dir/project/file.txt"
  git -C "$dir/project" add -A
  git -C "$dir/project" commit -qm baseline
  git -C "$dir/project" worktree add -q -b "fm/$id" "$dir/wt" main

  printf 'a fix nobody pushed\n' >> "$dir/wt/file.txt"
  git -C "$dir/wt" commit -qam "local fix"

  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "worktree=$dir/wt" "project=$dir/project" \
    "kind=ship" "mode=no-mistakes"

  printf '%s %s\n' "$dir" "$(git -C "$dir/wt" rev-parse HEAD)"
}

run_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

test_refuses_a_pr_that_predates_the_tasks_commit() {
  local dir tip base out status
  read -r dir tip < <(make_head_case ahead)
  base=$(git -C "$dir/wt" rev-parse HEAD~1)

  set +e
  out=$(FM_TEST_GH_HEAD="$base" \
    run_check "$dir" task-a "https://github.com/o/r/pull/1" 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "a PR whose head predates the task's commit must be refused"
  case "$out" in
    *"does not carry this task's committed work"*) ;;
    *) fail "the refusal must name the defect; got: $out" ;;
  esac
  case "$out" in
    *"$tip"*) ;;
    *) fail "the refusal must name the unpushed branch tip; got: $out" ;;
  esac
  assert_absent "$dir/home/state/task-a.check.sh" "a refused PR must arm no merge poll"
  assert_no_grep "pr=" "$dir/home/state/task-a.meta" "a refused PR must record nothing"
  pass "fm-pr-check.sh: refuses a PR that does not carry the task's committed work"
}

test_records_a_pr_at_the_branch_tip() {
  local dir tip status
  read -r dir tip < <(make_head_case equal)
  set +e
  FM_TEST_GH_HEAD="$tip" \
    run_check "$dir" task-a "https://github.com/o/r/pull/1" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "a PR at the branch tip must be recorded"
  assert_grep "pr_head=$tip" "$dir/home/state/task-a.meta" \
    "the healthy case must still record the exact PR head"
  pass "fm-pr-check.sh: records a PR sitting at the branch tip"
}

# The pipeline pushes a no-mistakes PR from its own worktree, so the task's copy
# lags the PR head. Refusing on that would break every pipeline task.
test_records_a_pr_ahead_of_the_tasks_own_copy() {
  local dir tip status
  read -r dir tip < <(make_head_case behind)
  git -C "$dir/wt" reset -q --hard HEAD~1
  set +e
  FM_TEST_GH_HEAD="$tip" \
    run_check "$dir" task-a "https://github.com/o/r/pull/1" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "a PR ahead of the task's own copy must be recorded, not refused"
  pass "fm-pr-check.sh: a PR ahead of the task's own copy is recorded"
}

# The upstream-PR shape: the worktree drives a branch that is not what this PR
# carries, so neither tip contains the other and nothing may be concluded from
# the pair. An unrelated head is the honest fixture for it - a branch NAME would
# not be, because the refusal never reads one.
test_does_not_compare_an_unrelated_pr_head() {
  local dir tip unrelated status
  read -r dir tip < <(make_head_case unrelated)
  # A commit on its own root, sharing no history with the task's branch.
  git -C "$dir/project" checkout -q --orphan other
  git -C "$dir/project" rm -rq --cached . 2>/dev/null || true
  printf 'elsewhere\n' > "$dir/project/other.txt"
  git -C "$dir/project" add other.txt
  git -C "$dir/project" commit -qm "unrelated history"
  unrelated=$(git -C "$dir/project" rev-parse HEAD)

  set +e
  FM_TEST_GH_HEAD="$unrelated" \
    run_check "$dir" task-a "https://github.com/o/r/pull/1" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "an unrelated PR head must not be compared to this branch"
  pass "fm-pr-check.sh: an unrelated PR head is never compared to this branch"
}

# A RE-RUN AGAINST A PR THIS TASK ALREADY RECORDED IS A SUPPORTED NO-OP, and the
# moved-head case on that path is already refused one step later, at teardown
# (tests/fm-teardown.test.sh: "merged PR does not allow teardown after a later
# local commit", and its pr-check-stale case, which re-runs this command after a
# later local commit and expects it to succeed without refreshing pr_head).
# Refusing here too would break that re-run for a case already covered, so the
# guard applies only to the FIRST recording - which is where the incident
# happened and where nothing else looks.
test_a_rerun_of_an_already_recorded_pr_is_left_alone() {
  local dir tip base status
  read -r dir tip < <(make_head_case rerun)
  base=$(git -C "$dir/wt" rev-parse HEAD~1)
  printf 'pr=%s\n' "https://github.com/o/r/pull/1" >> "$dir/home/state/task-a.meta"

  set +e
  FM_TEST_GH_HEAD="$base" \
    run_check "$dir" task-a "https://github.com/o/r/pull/1" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" \
    "a re-run against an already-recorded PR must stay the no-op the base defines"
  pass "fm-pr-check.sh: a re-run of an already-recorded PR is left to teardown's gate"
}

# THE MULTI-PR CASE. One task ships several PRs under one id
# (fm-lock-lineage-fix-l8 ships seven), and every landing-and-next-PR cycle
# re-opens the same window: the recorded fact is what the fleet view draws and
# what the merge poll watches, so a fact left on the previous PR draws a merged
# PR beside a task that has moved on AND leaves a poll reporting that PR merged
# on every sweep. Re-recording must move BOTH, and the previous PR's poll must be
# gone rather than firing beside the new one.
test_recording_a_second_pr_moves_the_fact_and_the_poll() {
  local dir tip status
  read -r dir tip < <(make_head_case second-pr)

  set +e
  FM_TEST_GH_HEAD="$tip" run_check "$dir" task-a "https://github.com/o/r/pull/1" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "the first PR must be recorded"
  assert_grep "pull/1" "$dir/home/state/task-a.pr-poll" \
    "the first recording must arm a poll watching the first PR"

  set +e
  FM_TEST_GH_HEAD="$tip" run_check "$dir" task-a "https://github.com/o/r/pull/2" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "a later PR reported by the same task must be recorded"
  assert_grep "pr=https://github.com/o/r/pull/2" "$dir/home/state/task-a.meta" \
    "the recorded PR must move to the PR the task has moved on to"
  assert_no_grep "pr=https://github.com/o/r/pull/1" "$dir/home/state/task-a.meta" \
    "the previous PR must not stay on the record beside the new one"
  assert_present "$dir/home/state/task-a.check.sh" "the merge poll must stay armed"
  assert_grep "pull/2" "$dir/home/state/task-a.pr-poll" \
    "the merge poll must watch the new PR"
  assert_no_grep "pull/1" "$dir/home/state/task-a.pr-poll" \
    "the previous PR's poll must be retired, not left firing beside the new one"
  pass "fm-pr-check.sh: a second PR moves the recorded fact and the merge poll"
}

# WARN, NEVER REFUSE. bin/fm-pr-merge.sh records before it merges and a re-run
# after landing is a supported no-op, so a refusal would break both paths.
test_warns_when_recording_an_already_merged_pr() {
  local dir tip out status
  read -r dir tip < <(make_head_case merged)
  set +e
  out=$(FM_TEST_GH_HEAD="$tip" FM_TEST_GH_STATE=MERGED \
    run_check "$dir" task-a "https://github.com/o/r/pull/1" 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "an already-merged PR must be recorded, not refused"
  case "$out" in
    *"is already merged"*) ;;
    *) fail "recording a merged PR must warn; got: $out" ;;
  esac
  assert_grep "pr=https://github.com/o/r/pull/1" "$dir/home/state/task-a.meta" \
    "the warning must not stop the PR being recorded"
  pass "fm-pr-check.sh: warns, without refusing, when the PR is already merged"
}

# The automatic recorder (bin/fm-watch.sh) discharges the MACHINE half of what a
# PR report owes. Acking there would take the captain-facing relay into silence
# with nothing left to re-arm it, so --no-ack must leave the alarm standing.
test_no_ack_records_without_silencing_the_alarm() {
  local dir tip status
  read -r dir tip < <(make_head_case no-ack)
  printf 'done: PR https://github.com/o/r/pull/1\n' > "$dir/home/state/task-a.status"
  set +e
  FM_TEST_GH_HEAD="$tip" \
    run_check "$dir" --no-ack task-a "https://github.com/o/r/pull/1" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "--no-ack must still record the PR"
  assert_grep "pr=https://github.com/o/r/pull/1" "$dir/home/state/task-a.meta" \
    "--no-ack must record the PR exactly as the acking path does"
  assert_absent "$dir/home/state/task-a.acted" \
    "--no-ack must leave the unactioned alarm standing for the captain-facing relay"
  pass "fm-pr-check.sh: --no-ack records the PR without acking the report"
}

test_refuses_a_pr_that_predates_the_tasks_commit
test_records_a_pr_at_the_branch_tip
test_records_a_pr_ahead_of_the_tasks_own_copy
test_does_not_compare_an_unrelated_pr_head
test_a_rerun_of_an_already_recorded_pr_is_left_alone
test_recording_a_second_pr_moves_the_fact_and_the_poll
test_warns_when_recording_an_already_merged_pr
test_no_ack_records_without_silencing_the_alarm
