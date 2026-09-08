#!/usr/bin/env bash
# Tests for bin/fm-merge-green.sh, the captain's mechanical merge switch, and
# for the standing merge rule its trigger half lives in (bin/fm-pr-poll.sh).
#
# The switch adds no gate of its own: every merge goes through
# bin/fm-pr-merge.sh, whose gates tests/fm-pr-merge.test.sh owns. What is tested
# HERE is only what the switch itself decides - which candidates, in what order,
# and what it does with each answer.
#
#   (a) two green candidates against one main: the first merges, and the second
#       - now behind the main that merge created - is reported needs-main-merge
#       with its worker steered, never merged, and the queue stops there
#   (b) a waivered direct-PR candidate whose ONLY red check is the no-mistakes
#       attestation merges: that excusal is what makes a waivered PR green
#   (c) a candidate with any other red or pending check is not merged, and the
#       run exits non-zero so the captain sees it
#   (d) --dry-run merges nothing, steers nobody, and prints the same table
#   (e) with config/merge-green ABSENT the merge poll behaves exactly as before
#       (silent on an open PR, `merged` on a merged one); present, an open green
#       PR also wakes firstmate
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SWITCH="$ROOT/bin/fm-merge-green.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-green-tests)
ATTESTATION_CHECK='PR must be raised via no-mistakes'

# --- fixtures ----------------------------------------------------------------

# make_fleet <name> <task...>: a case dir holding one project repo with a bare
# origin, one isolated worktree and one task record per named task, and a state
# dir. Each task's meta carries a recorded pr= (last line, as
# fm_pr_metadata_identity_parse requires) and a dispatch time in the order the
# tasks were named, so the switch's oldest-first order is the argument order.
# Echoes the case dir.
make_fleet() {
  local name=$1 case_dir fakebin task n=0 at=1000
  shift
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/fmhome/data"
  touch "$case_dir/state/.last-watcher-beat"

  git init -q -b main "$case_dir/project" 2>/dev/null || {
    git init -q "$case_dir/project"
    git -C "$case_dir/project" checkout -q -b main
  }
  mkdir -p "$case_dir/project/tests"
  # Self-contained so the kept-tests gate can execute it if it ever needs to.
  # Each branch below leaves this file byte-identical, so the gate takes its
  # assumed-covered path and the fixture stays fast.
  cat > "$case_dir/project/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass "alpha holds"
EOF
  git -C "$case_dir/project" add -A
  git -C "$case_dir/project" commit -qm baseline
  fm_git_add_origin "$case_dir/project" "$case_dir/remote"

  for task in "$@"; do
    n=$((n + 1))
    git -C "$case_dir/project" worktree add -q -b "fm/$task" "$case_dir/wt-$task" main
    printf 'work for %s\n' "$task" > "$case_dir/wt-$task/$task.txt"
    git -C "$case_dir/wt-$task" add -A
    git -C "$case_dir/wt-$task" -c user.name=fmtest -c user.email=fmtest@example.invalid \
      commit -qm "$task work"
    # Pushed, because the merge mock advances the bare origin's main to this
    # branch and the objects have to exist there for that to be a real move.
    git -C "$case_dir/project" push -q origin "fm/$task"
    fm_write_meta "$case_dir/state/$task.meta" \
      "window=sess:fm-$task" \
      "worktree=$case_dir/wt-$task" \
      "project=$case_dir/project" \
      "harness=claude" \
      "kind=ship" \
      "mode=no-mistakes" \
      "tmux_window_pinned=1" \
      "spawned_at=$at" \
      "pr=https://github.com/o/r/pull/$n"
    at=$((at + 1000))
  done
  printf '%s\n' "$case_dir"
}

# write_projects_registry <case_dir> <mode>: the private registry
# bin/fm-project-mode.sh resolves a delivery mode from.
write_projects_registry() {
  local case_dir=$1 mode=$2
  mkdir -p "$case_dir/fmhome/data"
  {
    printf '%s\n' '# Projects'
    printf -- '- project [%s] - test project (added 2026-09-08)\n' "$mode"
  } > "$case_dir/fmhome/data/projects.md"
}

# write_pr_checks <case_dir> <pr-number> <tsv line...>: the rollup answer for
# one PR, in the gate's own TSV shape (typename, status, conclusion, state,
# name). Absent means one green CheckRun.
write_pr_checks() {
  local case_dir=$1 number=$2
  shift 2
  printf '%s\n' "$@" > "$case_dir/pr-checks-$number.tsv"
}

# add_mocks <case_dir>: the gh reader and the gh-axi merger.
#
# `gh-axi pr merge` records its argv AND moves the bare origin's main to that
# PR's branch, which is what a real squash merge does and is the whole premise
# of case (a): the branch below it is now measuring CI against a base that no
# longer exists.
add_mocks() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
if [ "\${1:-} \${2:-}" = "pr merge" ]; then
  branch=\$(cat "$case_dir/pr-branch-\${3:-0}" 2>/dev/null || true)
  if [ -n "\$branch" ]; then
    sha=\$(git -C "$case_dir/project" rev-parse "\$branch") || exit 1
    git -C "$case_dir/remote" update-ref refs/heads/main "\$sha" || exit 1
  fi
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
number=
for a in "\$@"; do
  case "\$a" in
    https://github.com/o/r/pull/*) number=\${a##*/} ;;
  esac
done
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*)
        git -C "$case_dir/project" rev-parse "\$(cat "$case_dir/pr-branch-\$number" 2>/dev/null || echo HEAD)"
        exit 0 ;;
      *baseRefName*) printf 'main\n'; exit 0 ;;
      *"--json state"*)
        cat "$case_dir/pr-state-\$number" 2>/dev/null || printf 'OPEN\n'
        exit 0 ;;
      *" body "*) exit 0 ;;
      *statusCheckRollup*)
        if [ -f "$case_dir/pr-checks-\$number.tsv" ]; then
          cat "$case_dir/pr-checks-\$number.tsv"
        else
          printf 'CheckRun\tCOMPLETED\tSUCCESS\t-\tmock-default-ci\n'
        fi
        exit 0 ;;
    esac
    ;;
  "api --paginate") exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    # #{pane_current_command} drives fm_backend_tmux_agent_alive; a verified
    # harness binary is the `alive` reading the steer path needs.
    case " $* " in
      *pane_current_command*) printf 'claude\n'; exit 0 ;;
    esac
    printf '%%1\n'; exit 0 ;;
  list-panes)
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "${target##*:}"
    exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-sessions) exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh" \
    "$case_dir/fakebin/tmux" "$case_dir/fakebin/sleep"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/tmux.log"
}

# pr_is <case_dir> <number> <branch> [state]: bind PR <number> to a branch (its
# head, and what a merge of it moves main to) and optionally its GitHub state.
pr_is() {
  local case_dir=$1 number=$2 branch=$3 state=${4:-OPEN}
  printf '%s\n' "$branch" > "$case_dir/pr-branch-$number"
  printf '%s\n' "$state" > "$case_dir/pr-state-$number"
}

run_switch() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/fmhome" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TMUX_LOG="$case_dir/tmux.log" \
  FM_SEND_SETTLE=0 \
  FM_SEND_SLEEP=0 \
  PATH="$case_dir/fakebin:$PATH" \
    "$SWITCH" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  return "$rc"
}

# --- (a) the serial queue ------------------------------------------------------

test_second_candidate_behind_the_new_main_is_not_merged() {
  local case_dir rc out
  case_dir=$(make_fleet serial mg-a1 mg-b1)
  add_mocks "$case_dir"
  pr_is "$case_dir" 1 fm/mg-a1
  pr_is "$case_dir" 2 fm/mg-b1

  set +e
  run_switch "$case_dir"
  rc=$?
  set -e
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "serial: a run whose only holdback is a main merge is not a refusal"
  assert_contains "$out" "merged" "serial: the first candidate should have merged"
  assert_contains "$out" "https://github.com/o/r/pull/1" "serial: the table names the first PR in full"
  assert_contains "$out" "needs-main-merge" \
    "serial: the second candidate is behind the main the first merge created"
  assert_contains "$out" "https://github.com/o/r/pull/2" "serial: the table names the second PR in full"
  assert_contains "$out" "(update rounds: 1)" \
    "serial: the summary reports how many update rounds that branch has needed"

  # Exactly one merge call, and it is the first PR's.
  assert_grep 'pr merge 1 ' "$case_dir/gh-axi.log" "serial: the first PR should have been merged"
  assert_no_grep 'pr merge 2 ' "$case_dir/gh-axi.log" \
    "serial: a branch that does not contain the current main must not be merged"

  # The steer went to that branch's own worker, and named the merge, not a rebase.
  assert_grep 'target=sess:fm-mg-b1' "$case_dir/tmux.log" \
    "serial: the second candidate's worker should have been steered"
  assert_grep 'git merge origin/main' "$case_dir/tmux.log" \
    "serial: the steer should tell the worker to merge main forward"
  assert_grep 'NEVER rebase' "$case_dir/tmux.log" \
    "serial: the steer must forbid a rebase"
  assert_no_grep 'target=sess:fm-mg-a1' "$case_dir/tmux.log" \
    "serial: the merged branch's worker must not be steered"
  assert_present "$case_dir/state/mg-b1.stale-base-ack" \
    "serial: the stale-base finding should be recorded as acted on"
  pass "the switch merges one PR, then reports the branch it left behind rather than merging it"
}

# --- (b) a waivered direct-PR PR is mechanically green -------------------------

test_direct_pr_with_only_the_attestation_red_merges() {
  local case_dir rc out
  case_dir=$(make_fleet waivered mg-w1)
  add_mocks "$case_dir"
  pr_is "$case_dir" 1 fm/mg-w1
  write_projects_registry "$case_dir" direct-PR
  write_pr_checks "$case_dir" 1 \
    "$(printf 'CheckRun\tCOMPLETED\tSUCCESS\t-\tLint shell scripts')" \
    "$(printf 'CheckRun\tCOMPLETED\tFAILURE\t-\t%s' "$ATTESTATION_CHECK")"

  set +e
  run_switch "$case_dir"
  rc=$?
  set -e
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "waivered: a direct-PR PR whose only red check is the attestation is green"
  assert_contains "$out" "merged" "waivered: it should have merged"
  assert_grep 'pr merge 1 ' "$case_dir/gh-axi.log" "waivered: the merge should have been called"
  assert_grep 'ATTESTATION CHECK EXEMPTED' "$case_dir/stderr" \
    "waivered: the merge log must disclose which check was excused"
  pass "a waivered direct-PR PR whose only red check is the attestation lands through the switch"
}

# --- (c) any other red or pending check is not green ---------------------------

test_a_red_check_is_not_merged_and_exits_non_zero() {
  local case_dir rc out
  case_dir=$(make_fleet red mg-r1)
  add_mocks "$case_dir"
  pr_is "$case_dir" 1 fm/mg-r1
  write_pr_checks "$case_dir" 1 \
    "$(printf 'CheckRun\tCOMPLETED\tSUCCESS\t-\tLint shell scripts')" \
    "$(printf 'CheckRun\tCOMPLETED\tFAILURE\t-\tBehavior tests')"

  set +e
  run_switch "$case_dir"
  rc=$?
  set -e
  out=$(cat "$case_dir/stdout")

  expect_code 1 "$rc" "red: a refused candidate must make the run exit non-zero"
  assert_contains "$out" "not-green" "red: the table should say the PR is not green"
  assert_no_grep 'pr merge ' "$case_dir/gh-axi.log" "red: nothing may be merged"
  pass "a PR with any other red check is not merged, and the run exits non-zero"
}

test_a_pending_check_is_not_merged_and_exits_non_zero() {
  local case_dir rc out
  case_dir=$(make_fleet pending mg-p1)
  add_mocks "$case_dir"
  pr_is "$case_dir" 1 fm/mg-p1
  write_pr_checks "$case_dir" 1 \
    "$(printf 'CheckRun\tCOMPLETED\tSUCCESS\t-\tLint shell scripts')" \
    "$(printf 'CheckRun\tIN_PROGRESS\t-\t-\tBehavior tests')"

  set +e
  run_switch "$case_dir"
  rc=$?
  set -e
  out=$(cat "$case_dir/stdout")

  expect_code 1 "$rc" "pending: an unfinished PR must make the run exit non-zero"
  assert_contains "$out" "not-green" "pending: the table should say the PR is not green"
  assert_no_grep 'pr merge ' "$case_dir/gh-axi.log" "pending: nothing may be merged"
  pass "a PR with a check still running is not merged, and the run exits non-zero"
}

# --- (d) dry run ---------------------------------------------------------------

test_dry_run_merges_nothing_and_prints_the_same_table() {
  local case_dir rc out
  case_dir=$(make_fleet dryrun mg-d1 mg-d2)
  add_mocks "$case_dir"
  pr_is "$case_dir" 1 fm/mg-d1
  pr_is "$case_dir" 2 fm/mg-d2

  set +e
  run_switch "$case_dir" --dry-run
  rc=$?
  set -e
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "dry-run: a preview of green work is not a refusal"
  assert_contains "$out" "OUTCOME" "dry-run: the same summary table is printed"
  assert_contains "$out" "https://github.com/o/r/pull/1" "dry-run: the table names each PR in full"
  assert_contains "$out" "https://github.com/o/r/pull/2" "dry-run: the table names each PR in full"
  assert_contains "$out" "would-merge" "dry-run: a green candidate is previewed as one that would merge"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "dry-run merged something"$'\n'"$(cat "$case_dir/gh-axi.log")"
  [ ! -s "$case_dir/tmux.log" ] || fail "dry-run steered somebody"$'\n'"$(cat "$case_dir/tmux.log")"
  pass "--dry-run merges nothing, steers nobody, and prints the same table"
}

# --- (e) the standing merge rule's trigger half --------------------------------

run_poll() {  # <case_dir> <number>
  local case_dir=$1 number=$2
  FM_HOME="$case_dir/fmhome" \
  PATH="$case_dir/fakebin:$PATH" \
    "$POLL" --validated "mg-e$number" "https://github.com/o/r/pull/$number" o r "$number"
}

test_absent_merge_green_leaves_the_poll_unchanged() {
  local case_dir out
  case_dir=$(make_fleet poll-off mg-e1)
  add_mocks "$case_dir"
  pr_is "$case_dir" 1 fm/mg-e1 OPEN
  assert_absent "$case_dir/fmhome/config/merge-green" \
    "poll-off: the standing rule must be absent by default"

  out=$(run_poll "$case_dir" 1)
  [ -z "$out" ] || fail "poll-off: an open PR must not wake anything without the standing rule"$'\n'"$out"

  pr_is "$case_dir" 1 fm/mg-e1 MERGED
  out=$(run_poll "$case_dir" 1)
  [ "$out" = merged ] || fail "poll-off: a merged PR must still wake firstmate, got: $out"
  pass "with no standing merge rule the merge poll behaves exactly as it did before"
}

test_present_merge_green_wakes_on_a_green_open_pr() {
  local case_dir out
  case_dir=$(make_fleet poll-on mg-e1)
  add_mocks "$case_dir"
  pr_is "$case_dir" 1 fm/mg-e1 OPEN
  mkdir -p "$case_dir/fmhome/config"
  touch "$case_dir/fmhome/config/merge-green"
  # bin/fm-pr-green.sh reads the task's record from FM_HOME, so the poll's home
  # must hold it exactly as a real home does.
  mkdir -p "$case_dir/fmhome/state"
  cp "$case_dir/state/mg-e1.meta" "$case_dir/fmhome/state/mg-e1.meta"

  out=$(run_poll "$case_dir" 1)
  assert_contains "$out" "green" "poll-on: a green open PR should wake firstmate to run the switch"
  assert_contains "$out" "mg-e1" "poll-on: the wake should name the task to land"
  pass "with the standing merge rule set, a green open PR wakes firstmate too"
}

test_second_candidate_behind_the_new_main_is_not_merged
test_direct_pr_with_only_the_attestation_red_merges
test_a_red_check_is_not_merged_and_exits_non_zero
test_a_pending_check_is_not_merged_and_exits_non_zero
test_dry_run_merges_nothing_and_prints_the_same_table
test_absent_merge_green_leaves_the_poll_unchanged
test_present_merge_green_wakes_on_a_green_open_pr
