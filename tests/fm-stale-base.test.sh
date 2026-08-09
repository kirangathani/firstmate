#!/usr/bin/env bash
# Behavior tests for bin/fm-stale-base.sh, the stale-base predicate.
#
# The condition under test: an in-flight task whose PUSHED branch no longer
# contains its project's current origin/<default>. Every CI result on such a
# branch was measured against a base that no longer exists, so it reads as a
# verdict on the branch and is not.
#
# Both directions are covered deliberately. A sweep verified only on the
# "everything is level" path has verified nothing, so every silent case here is
# paired with a firing case built from the same fixture, and the four-branch
# shape of the 2026-08-09 incident (base moves, three of four branches behind)
# is pinned end to end.
#
# Hermetic: every world is a bare origin, a clone of it, real linked worktrees,
# and a state/ dir under one temp root. No network, no real fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-stale-base)
SWEEP="$ROOT/bin/fm-stale-base.sh"

# --- fixtures ---------------------------------------------------------------

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# new_world <slug>: echo a fresh home dir holding state/, projects/, a bare
# origin with one commit on main, a clone of it, and a side work repo used to
# advance origin later. Branch naming avoids `init -b` for older git.
# The slug is caller-supplied rather than a counter because every caller uses
# `w=$(new_world ...)`, and a counter incremented inside that command
# substitution never reaches this shell, so all worlds would collide on one dir.
new_world() {
  local slug=$1 name=proj w remote_abs
  w="$TMP_ROOT/world-$slug"
  mkdir -p "$w/state" "$w/projects" "$w/remotes"

  git init -q "$w/work-$name"
  git -C "$w/work-$name" symbolic-ref HEAD refs/heads/main
  commit_file "$w/work-$name" file.txt v0 C0

  git clone --quiet --bare "$w/work-$name" "$w/remotes/$name.git"
  remote_abs=$(cd "$w/remotes/$name.git" && pwd)
  git -C "$w/work-$name" remote add origin "file://$remote_abs"
  git -C "$w/work-$name" push -q -u origin main
  git clone --quiet "file://$remote_abs" "$w/projects/$name"
  printf '%s\n' "$w"
}

# add_project <world> <name>: a second clone in the same home, same shape.
add_project() {
  local w=$1 name=$2 remote_abs
  git init -q "$w/work-$name"
  git -C "$w/work-$name" symbolic-ref HEAD refs/heads/main
  commit_file "$w/work-$name" file.txt v0 C0
  git clone --quiet --bare "$w/work-$name" "$w/remotes/$name.git"
  remote_abs=$(cd "$w/remotes/$name.git" && pwd)
  git -C "$w/work-$name" remote add origin "file://$remote_abs"
  git -C "$w/work-$name" push -q -u origin main
  git clone --quiet "file://$remote_abs" "$w/projects/$name"
  printf '%s\n' "$w/projects/$name"
}

# advance_origin <world> [<name>]: land one more commit on that project's origin
# main, then refresh the clone's remote-tracking refs exactly as a fleet sync
# would. This is what moves the base under every open branch.
advance_origin() {
  local w=$1 name=${2:-proj} msg
  msg="base-$(git -C "$w/work-$name" rev-list --count HEAD)"
  commit_file "$w/work-$name" file.txt "$msg" "$msg"
  git -C "$w/work-$name" push -q origin main
  git -C "$w/projects/$name" fetch -q origin
}

# add_task <world> <id> <branch> [kind] [name]: branch a real linked worktree off
# the clone's CURRENT origin/main and record the task meta fm-spawn would write.
add_task() {
  local w=$1 id=$2 branch=$3 kind=${4:-ship} name=${5:-proj} proj wt
  proj="$w/projects/$name"
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

# add_detached_task <world> <id>: the shape fm-spawn hands a worker before it
# runs `git checkout -b` - a linked worktree at a detached HEAD on the base.
add_detached_task() {
  local w=$1 id=$2 proj wt
  proj="$w/projects/proj"
  wt="$w/wt-$id"
  git -C "$proj" worktree add -q --detach "$wt" origin/main
  fm_write_meta "$w/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=echo" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"
  printf '%s\n' "$wt"
}

# push_branch <worktree> <branch>: commit one change and publish it, so the
# branch has an origin ref and therefore a CI verdict that can go stale.
push_branch() {
  local wt=$1 branch=$2 flat
  flat=${branch//\//-}
  commit_file "$wt" "$flat.txt" work "work on $branch"
  git -C "$wt" push -q -u origin "$branch"
}

run_sweep() {  # <world> [args...]
  local w=$1
  shift
  FM_HOME="$w" bash "$SWEEP" "$@"
}

# --- the branch IS behind: the guard must fire ------------------------------

test_behind_pushed_branch_fires_and_names_the_remedy() {
  local w wt out status
  w=$(new_world behind-pushed-branch-fires-and-names-the-remedy)
  wt=$(add_task "$w" t-behind fm/t-behind)
  push_branch "$wt" fm/t-behind
  advance_origin "$w"

  out=$(run_sweep "$w"); status=$?

  expect_code 1 "$status" "a behind branch must report a finding"
  assert_contains "$out" "STALE BASE: t-behind" "the finding must name the task"
  assert_contains "$out" "fm/t-behind" "the finding must name the branch"
  assert_contains "$out" "1 commit(s) behind origin/main" "the finding must quantify the gap"
  assert_contains "$out" "a base that no longer exists" "the finding must say why the CI result is not a verdict"
  assert_contains "$out" "merge origin/main into fm/t-behind and re-verify" \
    "the finding must name the remedy, not just the problem"
  assert_contains "$out" "STALE BASE REMEDY: Never rebase" "the remedy must rule out rebasing"
  assert_contains "$out" 'git push --force' "the remedy must say why rebasing is not an option"
  pass "fm-stale-base: a behind pushed branch fires and names task, branch and remedy"
}

# --- the branch is NOT behind: silence --------------------------------------

test_branch_containing_the_new_base_is_silent() {
  local w wt out status
  w=$(new_world branch-containing-the-new-base-is-silent)
  advance_origin "$w"
  # Branched AFTER the base moved, so it already contains the current base.
  wt=$(add_task "$w" t-level fm/t-level)
  push_branch "$wt" fm/t-level

  out=$(run_sweep "$w"); status=$?

  expect_code 0 "$status" "a branch that contains the current base must be silent"
  [ -z "$out" ] || fail "level branch produced output: $out"
  pass "fm-stale-base: a branch already containing the new base is silent"
}

test_branch_that_merged_the_new_base_goes_quiet() {
  local w wt out status
  w=$(new_world branch-that-merged-the-new-base-goes-quiet)
  wt=$(add_task "$w" t-merged fm/t-merged)
  push_branch "$wt" fm/t-merged
  advance_origin "$w"
  run_sweep "$w" >/dev/null && fail "sweep did not fire before the remedy was applied"

  # The remedy the report names: merge, never rebase, then publish.
  git -C "$wt" merge -q --no-edit origin/main
  git -C "$wt" push -q origin fm/t-merged

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "after merging the new base the finding must clear"
  [ -z "$out" ] || fail "merged branch still reported: $out"
  pass "fm-stale-base: applying the named remedy clears the finding"
}

test_scout_task_is_silent() {
  local w wt out status
  w=$(new_world scout-task-is-silent)
  wt=$(add_task "$w" t-scout fm/t-scout scout)
  push_branch "$wt" fm/t-scout
  advance_origin "$w"

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "a scout has no ship branch by design and must never fire"
  [ -z "$out" ] || fail "scout task produced output: $out"
  pass "fm-stale-base: a scout task is silent even with a behind branch"
}

test_secondmate_record_is_silent() {
  local w wt out status
  w=$(new_world secondmate-record-is-silent)
  wt=$(add_task "$w" t-sm fm/t-sm secondmate)
  push_branch "$wt" fm/t-sm
  advance_origin "$w"

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "a persistent secondmate home is not a branch-bearing work item"
  [ -z "$out" ] || fail "secondmate record produced output: $out"
  pass "fm-stale-base: a secondmate record is silent"
}

test_unpushed_branch_is_silent() {
  local w wt out status
  w=$(new_world unpushed-branch-is-silent)
  wt=$(add_task "$w" t-unpushed fm/t-unpushed)
  commit_file "$wt" local.txt work "unpublished work"
  advance_origin "$w"

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "a branch with no origin ref has no CI verdict to misread"
  [ -z "$out" ] || fail "unpushed branch produced output: $out"
  pass "fm-stale-base: a branch that was never pushed is silent"
}

test_fresh_detached_worktree_is_silent() {
  local w out status
  w=$(new_world fresh-detached-worktree-is-silent)
  add_detached_task "$w" t-fresh >/dev/null
  advance_origin "$w"

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "a worker that has not branched yet must not alarm"
  [ -z "$out" ] || fail "freshly spawned task produced output: $out"
  pass "fm-stale-base: a task still on the pristine detached base is silent"
}

test_project_without_origin_remote_is_silent() {
  local w wt out status
  w=$(new_world project-without-origin-remote-is-silent)
  wt=$(add_task "$w" t-local fm/t-local)
  push_branch "$wt" fm/t-local
  advance_origin "$w"
  git -C "$w/projects/proj" remote remove origin

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "a clone with no origin publishes nothing and runs no CI on it"
  [ -z "$out" ] || fail "no-origin project produced output: $out"
  pass "fm-stale-base: a project with no origin remote is out of domain, not an alarm"
}

# --- cannot tell: report, never silence -------------------------------------

test_missing_project_clone_is_undeterminable() {
  local w out status reported_line
  w=$(new_world missing-project-clone-is-undeterminable)
  add_task "$w" t-gone fm/t-gone >/dev/null
  rm -rf "$w/projects/proj"

  out=$(run_sweep "$w"); status=$?
  expect_code 1 "$status" "an unreadable project must not read as clean"
  assert_contains "$out" "STALE BASE UNDETERMINABLE: cannot tell whether t-gone is behind" \
    "a missing project copy must be reported, not silently passed"
  while IFS= read -r reported_line; do
    case "$reported_line" in
      "STALE BASE"*) ;;
      *) fail "every reported line must carry the STALE BASE marker so a relay cannot split a finding from its remedy: $reported_line" ;;
    esac
  done <<< "$out"
  assert_contains "$out" "STALE BASE REMEDY: undeterminable is not clean" "the report must say cannot-tell is not an all-clear"
  pass "fm-stale-base: a missing project copy reports as undeterminable"
}

test_absent_origin_default_ref_is_undeterminable() {
  local w wt out status
  w=$(new_world absent-origin-default-ref-is-undeterminable)
  wt=$(add_task "$w" t-noref fm/t-noref)
  push_branch "$wt" fm/t-noref
  git -C "$w/projects/proj" update-ref -d refs/remotes/origin/main

  out=$(run_sweep "$w"); status=$?
  expect_code 1 "$status" "no base to measure against must not read as clean"
  assert_contains "$out" "STALE BASE UNDETERMINABLE: cannot tell whether t-noref is behind" \
    "an absent origin/main must be reported"
  assert_contains "$out" "no origin/main ref to measure against" "the reason must name the missing base ref"
  pass "fm-stale-base: an absent origin/<default> reports as undeterminable"
}

test_detached_head_with_own_commits_is_undeterminable() {
  local w wt out status
  w=$(new_world detached-head-with-own-commits-is-undeterminable)
  wt=$(add_detached_task "$w" t-detached)
  commit_file "$wt" stray.txt stray "work with no branch to name"

  out=$(run_sweep "$w"); status=$?
  expect_code 1 "$status" "a detached HEAD carrying commits has no branch to resolve"
  assert_contains "$out" "STALE BASE UNDETERMINABLE: cannot tell whether t-detached is behind" \
    "a detached HEAD with its own commits must be reported"
  assert_contains "$out" "no branch to name" "the reason must say the branch could not be resolved"
  pass "fm-stale-base: a detached HEAD carrying commits reports as undeterminable"
}

test_worktree_outside_the_project_is_undeterminable() {
  local w out status
  w=$(new_world worktree-outside-the-project-is-undeterminable)
  add_task "$w" t-foreign fm/t-foreign >/dev/null
  # A recorded local copy that is not one of this clone's worktrees at all.
  mkdir -p "$w/elsewhere"
  fm_write_meta "$w/state/t-foreign.meta" \
    "window=firstmate:fm-t-foreign" \
    "worktree=$w/elsewhere" \
    "project=$w/projects/proj" \
    "harness=echo" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"

  out=$(run_sweep "$w"); status=$?
  expect_code 1 "$status" "an unlinked local copy must not read as clean"
  assert_contains "$out" "STALE BASE UNDETERMINABLE: cannot tell whether t-foreign is behind" \
    "a local copy outside the project must be reported"
  pass "fm-stale-base: a recorded local copy outside the project reports as undeterminable"
}

# --- the incident: base moves, three of four branches behind ----------------

test_multi_task_incident_names_exactly_the_behind_branches() {
  local w out status
  w=$(new_world multi-task-incident-names-exactly-the-behind-branches)
  push_branch "$(add_task "$w" pr41 fm/pr41)" fm/pr41
  push_branch "$(add_task "$w" pr42 fm/pr42)" fm/pr42
  push_branch "$(add_task "$w" pr45 fm/pr45)" fm/pr45
  # pr43 is the one that was steered onto the fixed base.
  advance_origin "$w"
  push_branch "$(add_task "$w" pr43 fm/pr43)" fm/pr43

  out=$(run_sweep "$w"); status=$?

  expect_code 1 "$status" "three behind branches must report"
  assert_contains "$out" "STALE BASE: pr41" "pr41 was behind and must be named"
  assert_contains "$out" "STALE BASE: pr42" "pr42 was behind and must be named"
  assert_contains "$out" "STALE BASE: pr45" "pr45 was behind and must be named"
  assert_not_contains "$out" "pr43" "the branch already on the new base must not be named"
  pass "fm-stale-base: base moves, three of four branches named, the fourth not"
}

# --- acknowledgement: silence what was acted on, re-alarm on a new base -----

test_ack_silences_until_the_base_moves_again() {
  local w wt out status
  w=$(new_world ack-silences-until-the-base-moves-again)
  wt=$(add_task "$w" t-ack fm/t-ack)
  push_branch "$wt" fm/t-ack
  advance_origin "$w"

  run_sweep "$w" >/dev/null && fail "sweep did not fire before the acknowledgement"

  out=$(run_sweep "$w" --ack t-ack) || fail "--ack must succeed"
  assert_contains "$out" "acknowledged: t-ack" "--ack must confirm what it silenced"
  assert_present "$w/state/t-ack.stale-base-ack" "--ack must leave a durable marker"

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "an acknowledged finding must stay quiet at the same base"
  [ -z "$out" ] || fail "acknowledged finding still reported: $out"

  out=$(run_sweep "$w" --all); status=$?
  expect_code 0 "$status" "--all must not turn an acknowledged finding back into a failure"
  assert_contains "$out" "STALE BASE (acknowledged): t-ack" "--all must still show what was silenced"

  # A second landing moves the base again: the same branch is stale against a
  # NEW base, which is a new finding and must alarm again.
  advance_origin "$w"
  out=$(run_sweep "$w"); status=$?
  expect_code 1 "$status" "a base that moves again must re-alarm past the acknowledgement"
  assert_contains "$out" "STALE BASE: t-ack" "the re-alarm must name the task again"
  pass "fm-stale-base: an acknowledgement is scoped to the base it was made at"
}

test_ack_all_silences_every_current_finding() {
  local w out status
  w=$(new_world ack-all-silences-every-current-finding)
  push_branch "$(add_task "$w" a1 fm/a1)" fm/a1
  push_branch "$(add_task "$w" a2 fm/a2)" fm/a2
  advance_origin "$w"

  out=$(run_sweep "$w" --ack-all) || fail "--ack-all must succeed"
  assert_contains "$out" "acknowledged: a1" "--ack-all must cover the first finding"
  assert_contains "$out" "acknowledged: a2" "--ack-all must cover the second finding"

  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "--ack-all must silence every current finding"
  [ -z "$out" ] || fail "findings survived --ack-all: $out"
  pass "fm-stale-base: --ack-all silences every current finding"
}

test_ack_only_touches_the_named_task() {
  local w out status
  w=$(new_world ack-only-touches-the-named-task)
  push_branch "$(add_task "$w" b1 fm/b1)" fm/b1
  push_branch "$(add_task "$w" b2 fm/b2)" fm/b2
  advance_origin "$w"

  run_sweep "$w" --ack b1 >/dev/null || fail "--ack must succeed"

  out=$(run_sweep "$w"); status=$?
  expect_code 1 "$status" "the unacknowledged sibling must still report"
  assert_contains "$out" "STALE BASE: b2" "the unacknowledged task must still be named"
  assert_not_contains "$out" "STALE BASE: b1" "the acknowledged task must be silenced"
  pass "fm-stale-base: --ack silences only the task it names"
}

# --- scoping ----------------------------------------------------------------

test_project_filter_limits_the_sweep() {
  local w other out status
  w=$(new_world project-filter-limits-the-sweep)
  other=$(add_project "$w" beta)
  push_branch "$(add_task "$w" p-alpha fm/p-alpha)" fm/p-alpha
  push_branch "$(add_task "$w" p-beta fm/p-beta ship beta)" fm/p-beta
  advance_origin "$w" proj
  advance_origin "$w" beta

  out=$(run_sweep "$w" --project "$other"); status=$?
  expect_code 1 "$status" "the filtered project's finding must still report"
  assert_contains "$out" "STALE BASE: p-beta" "the named project's task must be reported"
  assert_not_contains "$out" "p-alpha" "another project's task must not be swept"
  pass "fm-stale-base: --project limits the sweep to one clone"
}

test_empty_home_is_silent() {
  local w out status
  w=$(new_world empty-home-is-silent)
  out=$(run_sweep "$w"); status=$?
  expect_code 0 "$status" "a home with no in-flight work must be silent"
  [ -z "$out" ] || fail "empty home produced output: $out"
  pass "fm-stale-base: a home with no in-flight work is silent"
}

test_behind_pushed_branch_fires_and_names_the_remedy
test_branch_containing_the_new_base_is_silent
test_branch_that_merged_the_new_base_goes_quiet
test_scout_task_is_silent
test_secondmate_record_is_silent
test_unpushed_branch_is_silent
test_fresh_detached_worktree_is_silent
test_project_without_origin_remote_is_silent
test_missing_project_clone_is_undeterminable
test_absent_origin_default_ref_is_undeterminable
test_detached_head_with_own_commits_is_undeterminable
test_worktree_outside_the_project_is_undeterminable
test_multi_task_incident_names_exactly_the_behind_branches
test_ack_silences_until_the_base_moves_again
test_ack_all_silences_every_current_finding
test_ack_only_touches_the_named_task
test_project_filter_limits_the_sweep
test_empty_home_is_silent
