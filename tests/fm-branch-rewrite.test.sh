#!/usr/bin/env bash
# Behavior tests for bin/fm-branch-rewrite.sh, the rewritten-branch predicate.
#
# The condition under test: an in-flight task whose PUSHED branch no longer
# contains the head firstmate recorded for its PR. A rebase, an amend or a
# force-push leaves that shape, and it matters because any conflict resolved in
# the commits that were replaced left no merge commit for bin/fm-pr-merge.sh's
# additive gate to read.
#
# Both directions are covered deliberately. A sweep verified only on the
# "nothing was rewritten" path has verified nothing, so every silent case here
# is paired with a firing case built from the same fixture.
#
# The STALE-CLONE case is the one worth stating on its own. This sweep reads
# local refs, so a clone nobody has fetched is OLDER than the recorded head, and
# an ancestry test in one direction alone would call that a rewrite. It is not
# one, and reporting it as one would make the sweep fire on every unrefreshed
# clone in the fleet.
#
# Hermetic: every world is a bare origin, a clone of it, real linked worktrees,
# and a state/ dir under one temp root. No network, no real fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-branch-rewrite)
SWEEP="$ROOT/bin/fm-branch-rewrite.sh"

# assert_silent <output> <msg>: the sweep must print nothing at all. Every
# caller captures this hook's output, so a healthy sweep that prints anything is
# indistinguishable from a finding.
assert_silent() {
  [ -z "$1" ] || fail "$2"$'\n'"--- output ---"$'\n'"$1"
}

# --- fixtures ---------------------------------------------------------------

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# new_world <slug>: echo a fresh home dir holding state/, projects/, a bare
# origin with one commit on main, and a clone of it. The slug is caller-supplied
# rather than a counter because every caller uses `w=$(new_world ...)`, and a
# counter incremented inside that command substitution never reaches this shell,
# so all worlds would collide on one dir.
new_world() {
  local slug=$1 w remote_abs
  w="$TMP_ROOT/world-$slug"
  mkdir -p "$w/state" "$w/projects" "$w/remotes"

  git init -q "$w/work-proj"
  git -C "$w/work-proj" symbolic-ref HEAD refs/heads/main
  commit_file "$w/work-proj" file.txt v0 C0

  git clone --quiet --bare "$w/work-proj" "$w/remotes/proj.git"
  remote_abs=$(cd "$w/remotes/proj.git" && pwd)
  git -C "$w/work-proj" remote add origin "file://$remote_abs"
  git -C "$w/work-proj" push -q -u origin main
  git clone --quiet "file://$remote_abs" "$w/projects/proj"
  printf '%s\n' "$w"
}

# add_task <world> <id> <branch> [kind]: branch a real linked worktree off the
# clone's origin/main and record the task meta fm-spawn would write. No pr_head
# yet - that is what bin/fm-pr-check.sh appends once a PR has been checked.
add_task() {
  local w=$1 id=$2 branch=$3 kind=${4:-ship} proj wt
  proj="$w/projects/proj"
  wt="$w/wt-$id"
  git -C "$proj" worktree add -q -b "$branch" "$wt" origin/main
  fm_write_meta "$w/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=echo" \
    "kind=$kind" \
    "mode=direct-PR" \
    "yolo=off"
  printf '%s\n' "$wt"
}

# push_branch <worktree> <branch> [file]: commit one change and publish it.
push_branch() {
  local wt=$1 branch=$2 file=${3:-work.txt}
  commit_file "$wt" "$file" work "work on $branch"
  git -C "$wt" push -q -u origin "$branch"
}

# record_pr_head <world> <id> <worktree>: append the pr= and pr_head= lines
# bin/fm-pr-check.sh writes once a PR has been checked, naming the branch's
# CURRENT head.
record_pr_head() {
  local w=$1 id=$2 wt=$3 sha
  sha=$(git -C "$wt" rev-parse HEAD)
  {
    printf 'pr=https://example.invalid/pull/1\n'
    printf 'pr_head=%s\n' "$sha"
  } >> "$w/state/$id.meta"
}

# rewrite_branch <worktree> <branch>: replace the branch tip with a commit that
# does NOT descend from it, then force-push - the shape a rebase, an amend, or a
# hand-run force-push leaves behind.
rewrite_branch() {
  local wt=$1 branch=$2
  git -C "$wt" reset -q --hard HEAD~1
  commit_file "$wt" work.txt rewritten "rewritten work on $branch"
  git -C "$wt" push -q --force origin "$branch"
}

# refresh_clone <world>: advance the clone's remote-tracking refs exactly as a
# fleet sync would.
refresh_clone() {
  git -C "$1/projects/proj" fetch -q --prune origin '+refs/heads/*:refs/remotes/origin/*'
}

run_sweep() {  # <world> [args...]
  local w=$1
  shift
  FM_HOME="$w" bash "$SWEEP" "$@"
}

# --- the branch WAS rewritten: the sweep must fire --------------------------

test_force_pushed_branch_fires_and_names_both_heads() {
  local w wt out status recorded
  w=$(new_world force-pushed-branch-fires)
  wt=$(add_task "$w" t-rw fm/t-rw)
  push_branch "$wt" fm/t-rw
  record_pr_head "$w" t-rw "$wt"
  recorded=$(git -C "$wt" rev-parse HEAD)
  rewrite_branch "$wt" fm/t-rw
  refresh_clone "$w"

  out=$(run_sweep "$w"); status=$?

  expect_code 1 "$status" "a rewritten branch must report a finding"
  assert_contains "$out" "BRANCH REWRITTEN: t-rw" "the finding must name the task"
  assert_contains "$out" "fm/t-rw" "the finding must name the branch"
  assert_contains "$out" "${recorded:0:12}" "the finding must name the head firstmate recorded"
  assert_contains "$out" "no merge commit for the landing gate to check" \
    "the finding must say why a rewrite matters, not merely that one happened"
  pass "fm-branch-rewrite: a force-pushed branch fires and names both heads"
}

# --- the branch only moved forward: silence ---------------------------------

test_branch_that_only_advanced_is_silent() {
  local w wt out status
  w=$(new_world branch-that-only-advanced)
  wt=$(add_task "$w" t-fwd fm/t-fwd)
  push_branch "$wt" fm/t-fwd
  record_pr_head "$w" t-fwd "$wt"
  push_branch "$wt" fm/t-fwd second.txt
  refresh_clone "$w"

  out=$(run_sweep "$w"); status=$?

  expect_code 0 "$status" "a branch that only gained commits must be silent"
  assert_silent "$out" "a forward-only branch must print nothing"
  pass "fm-branch-rewrite: a branch that only advanced is silent"
}

# --- the STALE CLONE case: never reported as a rewrite ----------------------

test_clone_older_than_the_recorded_head_is_undeterminable_not_a_rewrite() {
  local w wt out status
  local first
  w=$(new_world clone-older-than-recorded-head)
  wt=$(add_task "$w" t-stale fm/t-stale)
  push_branch "$wt" fm/t-stale
  first=$(git -C "$wt" rev-parse HEAD)
  push_branch "$wt" fm/t-stale second.txt
  record_pr_head "$w" t-stale "$wt"
  # A linked worktree SHARES its clone's ref store, so pushing from one already
  # advanced refs/remotes/origin/*. Wind that ref back to model the real case
  # this branch exists for: a PR head recorded from the remote, against a clone
  # nobody has fetched since.
  git -C "$w/projects/proj" update-ref "refs/remotes/origin/fm/t-stale" "$first"

  out=$(run_sweep "$w"); status=$?

  expect_code 1 "$status" "an unrefreshed clone must be reported, not folded into silence"
  assert_contains "$out" "REWRITE UNDETERMINABLE: t-stale" \
    "an unrefreshed clone must be undeterminable"
  assert_contains "$out" "have not been refreshed" "it must name the refresh as the cause"
  assert_not_contains "$out" "BRANCH REWRITTEN" \
    "an unrefreshed clone must NEVER be reported as a rewrite"
  pass "fm-branch-rewrite: a clone older than the recorded head is undeterminable, never a rewrite"
}

# --- silent cases -----------------------------------------------------------

test_task_without_a_recorded_pr_head_is_silent() {
  local w wt out status
  w=$(new_world task-without-recorded-pr-head)
  wt=$(add_task "$w" t-nopr fm/t-nopr)
  push_branch "$wt" fm/t-nopr
  rewrite_branch "$wt" fm/t-nopr
  refresh_clone "$w"

  out=$(run_sweep "$w"); status=$?

  expect_code 0 "$status" "a task with no recorded PR head has no head to have been rewritten away"
  assert_silent "$out" "a task with no recorded PR head must print nothing"
  pass "fm-branch-rewrite: a task with no recorded PR head is silent"
}

test_scout_record_is_silent() {
  local w wt out status
  w=$(new_world scout-record-is-silent)
  wt=$(add_task "$w" t-scout fm/t-scout scout)
  push_branch "$wt" fm/t-scout
  record_pr_head "$w" t-scout "$wt"
  rewrite_branch "$wt" fm/t-scout
  refresh_clone "$w"

  out=$(run_sweep "$w"); status=$?

  expect_code 0 "$status" "a scout produces a report and no PR"
  assert_silent "$out" "a scout record must print nothing"
  pass "fm-branch-rewrite: a scout record is silent"
}

test_unpushed_branch_is_silent() {
  local w wt out status
  w=$(new_world unpushed-branch-is-silent)
  wt=$(add_task "$w" t-local fm/t-local)
  commit_file "$wt" work.txt work "local only"
  record_pr_head "$w" t-local "$wt"

  out=$(run_sweep "$w"); status=$?

  expect_code 0 "$status" "a branch with no origin ref has published nothing to rewrite"
  assert_silent "$out" "an unpushed branch must print nothing"
  pass "fm-branch-rewrite: an unpushed branch is silent"
}

test_empty_home_is_silent() {
  local w out status
  w=$(new_world empty-home-is-silent)

  out=$(run_sweep "$w"); status=$?

  expect_code 0 "$status" "a home with no tasks must be silent"
  assert_silent "$out" "an empty home must print nothing"
  pass "fm-branch-rewrite: an empty home is silent"
}

# --- undeterminable cases: never folded into silence ------------------------

test_missing_project_clone_is_undeterminable() {
  local w wt out status
  w=$(new_world missing-project-clone)
  wt=$(add_task "$w" t-gone fm/t-gone)
  push_branch "$wt" fm/t-gone
  record_pr_head "$w" t-gone "$wt"
  mv "$w/projects/proj" "$w/projects/proj-moved-away"

  out=$(run_sweep "$w"); status=$?

  expect_code 1 "$status" "a missing clone must be reported, not silently passed"
  assert_contains "$out" "REWRITE UNDETERMINABLE: t-gone" "a missing clone must be undeterminable"
  pass "fm-branch-rewrite: a missing project clone is undeterminable"
}

test_recorded_head_absent_from_the_clone_is_undeterminable() {
  local w wt out status
  w=$(new_world recorded-head-absent-from-clone)
  wt=$(add_task "$w" t-unknown fm/t-unknown)
  push_branch "$wt" fm/t-unknown
  refresh_clone "$w"
  # A head this clone has never had any way to see.
  printf 'pr_head=%s\n' 0000000000000000000000000000000000000001 >> "$w/state/t-unknown.meta"

  out=$(run_sweep "$w"); status=$?

  expect_code 1 "$status" "a recorded head this clone lacks must be reported"
  assert_contains "$out" "REWRITE UNDETERMINABLE: t-unknown" \
    "an unknown recorded head must be undeterminable"
  assert_contains "$out" "does not have the recorded PR head" "it must name the missing object"
  assert_not_contains "$out" "BRANCH REWRITTEN" \
    "an object this clone never fetched must NEVER be reported as a rewrite"
  pass "fm-branch-rewrite: a recorded head absent from the clone is undeterminable"
}

test_worktree_git_does_not_know_is_undeterminable() {
  local w wt out status
  w=$(new_world worktree-git-does-not-know)
  wt=$(add_task "$w" t-lost fm/t-lost)
  push_branch "$wt" fm/t-lost
  record_pr_head "$w" t-lost "$wt"
  # Point the record at a path that is not one of this clone's worktrees.
  sed -i "s#^worktree=.*#worktree=$w/not-a-worktree#" "$w/state/t-lost.meta"

  out=$(run_sweep "$w"); status=$?

  expect_code 1 "$status" "a local copy git does not know must be reported"
  assert_contains "$out" "REWRITE UNDETERMINABLE: t-lost" "an unknown local copy must be undeterminable"
  pass "fm-branch-rewrite: a local copy git does not know is undeterminable"
}

# --- the project filter -----------------------------------------------------

test_project_filter_limits_the_sweep() {
  local w wt out status
  w=$(new_world project-filter-limits-the-sweep)
  wt=$(add_task "$w" t-filt fm/t-filt)
  push_branch "$wt" fm/t-filt
  record_pr_head "$w" t-filt "$wt"
  rewrite_branch "$wt" fm/t-filt
  refresh_clone "$w"

  out=$(run_sweep "$w" --project "$w/projects/proj"); status=$?
  expect_code 1 "$status" "the task's own project must still be swept"
  assert_contains "$out" "BRANCH REWRITTEN: t-filt" "the matching project must report"

  out=$(run_sweep "$w" --project "$w/projects/other"); status=$?
  expect_code 0 "$status" "a different project must sweep nothing"
  assert_silent "$out" "a non-matching project filter must print nothing"
  pass "fm-branch-rewrite: the project filter limits the sweep"
}

test_force_pushed_branch_fires_and_names_both_heads
test_branch_that_only_advanced_is_silent
test_clone_older_than_the_recorded_head_is_undeterminable_not_a_rewrite
test_task_without_a_recorded_pr_head_is_silent
test_scout_record_is_silent
test_unpushed_branch_is_silent
test_empty_home_is_silent
test_missing_project_clone_is_undeterminable
test_recorded_head_absent_from_the_clone_is_undeterminable
test_worktree_git_does_not_know_is_undeterminable
test_project_filter_limits_the_sweep
