#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-flow.sh - the read-only live flow view of a
# task's no-mistakes delivery pipeline.
#
# The viewer parses `no-mistakes axi status` TOON (shapes maintained by
# tests/fm-crew-state.test.sh against the real CLI), the plain-text
# `no-mistakes runs` list, and the ci step log markers, all served here by a
# fake `no-mistakes` on PATH over real throwaway git worktrees. Cases:
#   (a) usage / resolution errors exit 2 / 1
#   (b) task-id mode resolves the worktree from state/<id>.meta
#   (c) running step is highlighted with the >> marker
#   (d) parked at a gate: banner shows step, findings count, action breakdown
#   (e) checks-passed / passed / failed / cancelled outcomes render distinctly,
#       and the terminal-failure loop line is marked on failed
#   (f) ci monitoring with a green ci log surfaces CI GREEN + merge gate next
#   (g) no run for the branch -> IDLE banner + full static diagram
#   (h) empty status answer -> STATUS UNREADABLE, never a guess
#   (i) other branch's run + runs-list row -> coarse background-run banner
#   (j) --tests-gate runs the real fm-assert-tests-kept.sh explicit mode and
#       shows missing/failing counts; rendering leaves the worktree clean
#   (k) --watch honors the FM_NM_FLOW_WATCH_MAX test hook and re-renders
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM_FLOW="$ROOT/bin/fm-nm-flow.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-flow)
fm_git_identity

make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# Fake no-mistakes mirroring the surface the viewer uses: `axi status`,
# `axi logs --step ci ...`, and the top-level `runs` list.
make_fakebin() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs)   printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_CI_LOGS=""
  export FM_FAKE_AXI_STATUS FM_FAKE_RUNS_LIST FM_FAKE_CI_LOGS
}

run_flow() {  # <case-dir> <args...>
  local d=$1
  shift
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$NM_FLOW" "$@"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "abc1234"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "abc1234"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_outcome() {  # <branch> <outcome> [pr]
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "abc1234"
  pr: "${3:-}"
  findings: none
outcome: $2
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) usage and resolution errors
test_usage_error() {
  reset_fakes
  local rc=0
  "$NM_FLOW" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no-args usage"
  rc=0
  "$NM_FLOW" some-id --worktree /nope >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "task-id and --worktree together"
  pass "usage errors exit 2"
}

test_missing_meta() {
  reset_fakes
  local d rc=0 err
  d=$(new_case missing-meta)
  make_fakebin "$d" >/dev/null
  err=$(run_flow "$d" no-such-task 2>&1) || rc=$?
  expect_code 1 "$rc" "missing meta"
  assert_contains "$err" "no metadata" "missing meta names the problem"
  pass "missing meta exits 1"
}

# (b) task-id mode resolves worktree from meta
test_task_id_resolution() {
  reset_fakes
  local d out
  d=$(new_case meta-mode)
  make_repo_on_branch "$d/wt" fm/meta-task
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/meta-task.meta" \
    "window=firstmate:fm-meta-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo"
  FM_FAKE_AXI_STATUS="$(run_running fm/meta-task)"
  out=$(run_flow "$d" meta-task)
  assert_contains "$out" "meta-task (demo)" "title carries id and project"
  assert_contains "$out" "branch fm/meta-task" "header shows the branch"
  assert_contains "$out" "state: running @ review" "run state read via meta worktree"
  pass "task-id mode resolves worktree from meta"
}

# (c) running step highlighted
test_running_step_highlight() {
  reset_fakes
  local d out
  d=$(new_case running)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" ">> [ review      LLM     ]" "current step carries the >> marker"
  assert_not_contains "$out" ">> [ intent" "non-current steps unmarked"
  assert_contains "$out" "!! LLM merge can drop base code; merge gate catches" "rebase warning present"
  assert_contains "$out" "!! LLM auto-rebase can drop base code; gate catches" "ci auto-rebase warning present"
  assert_contains "$out" "fix round: pipeline" "gate fix-round loop shown"
  pass "running step is highlighted with warnings in place"
}

# (d) parked at a gate
test_parked_at_review_gate() {
  reset_fakes
  local d out
  d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-b)"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "PARKED at review gate: 2 findings (1 ask-user, 1 auto-fix, 0 no-op)" \
    "parked banner shows step, count, and action breakdown"
  assert_contains "$out" ">> [ review      LLM     ]" "gate step highlighted"
  pass "parked gate state is prominent"
}

# (e) outcomes render distinctly
test_outcomes_distinct() {
  reset_fakes
  local d out
  d=$(new_case outcomes)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null

  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-c checks-passed https://github.com/o/r/pull/9)"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "OUTCOME: checks-passed - CI green, PR ready for merge gate + captain" \
    "checks-passed banner"
  assert_contains "$out" ">> [ merge gate  det     ]" "checks-passed highlights the merge gate"
  assert_contains "$out" "PR: https://github.com/o/r/pull/9" "PR URL surfaced"

  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-c passed https://github.com/o/r/pull/9)"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "OUTCOME: passed - PR merged/closed" "passed banner"
  assert_contains "$out" ">> [ teardown    det     ]" "passed highlights teardown"

  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-c failed)"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "OUTCOME: failed" "failed banner"
  assert_contains "$out" ">> " "failed marks the fail loop"
  assert_contains "$out" "fail loop: failed/cancelled -> commit fix on same branch -> rerun at intent" \
    "terminal-failure loop line present"

  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-c cancelled)"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "OUTCOME: cancelled" "cancelled banner"
  pass "outcomes render distinctly"
}

# (f) ci monitoring with green checks
test_ci_green_monitoring() {
  reset_fakes
  local d out
  d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "CI GREEN: monitoring until merge/close - merge gate + captain next" \
    "green ci log surfaces CI GREEN"
  assert_contains "$out" ">> [ merge gate  det     ]" "ci green highlights the merge gate"

  FM_FAKE_CI_LOGS="CI checks running"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "state: running @ ci" "checks still running stays on the ci box"
  assert_contains "$out" ">> [ CI monitor  det+LLM ]" "ci monitor highlighted while waiting"
  pass "ci monitor distinguishes waiting from green"
}

# (g) no run at all -> idle static diagram
test_idle_static_diagram() {
  reset_fakes
  local d out
  d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-idle
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "IDLE: no run for branch fm/feat-idle" "idle banner"
  local box
  for box in intent rebase review test document lint push "open PR" "CI monitor" "merge gate" captain teardown; do
    assert_contains "$out" "[ $box" "static diagram includes $box"
  done
  assert_not_contains "$out" ">> " "idle diagram highlights nothing"
  pass "no run renders the static diagram with an idle banner"
}

# (h) unreadable status
test_unreadable_status() {
  reset_fakes
  local d out
  d=$(new_case unreadable)
  make_repo_on_branch "$d/wt" fm/feat-u
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS=""
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "STATUS UNREADABLE" "unreadable banner instead of a guess"
  assert_contains "$out" "[ intent" "static diagram still rendered"
  pass "unreadable status says so rather than guessing"
}

# (i) other branch's run -> coarse runs-list fallback
test_coarse_fallback() {
  reset_fakes
  local d out
  d=$(new_case coarse)
  make_repo_on_branch "$d/wt" fm/feat-mine
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_running fm/other-branch)"
  FM_FAKE_RUNS_LIST="running     fm/feat-mine    abc1234   2026-07-26"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "background run: running (no step detail for this branch)" \
    "coarse banner from the runs list"
  FM_FAKE_RUNS_LIST="completed     fm/feat-mine    abc1234   2026-07-26"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "last run for this branch: completed" "coarse last-run status"
  pass "coarse runs-list fallback covers the last run"
}

# (j) --tests-gate over the real fm-assert-tests-kept.sh, read-only
test_tests_gate_counts() {
  reset_fakes
  local d out
  d=$(new_case tests-gate)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
pass "beta"
SH
  chmod +x "$d/wt/tests/demo.test.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
SH
  git -C "$d/wt" commit -qam "drop beta"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(run_flow "$d" --worktree "$d/wt" --tests-gate)
  assert_contains "$out" "prior-tests vs main: missing 1 / failing 0 !!" \
    "merge-gate box shows the missing count"
  [ -z "$(git -C "$d/wt" status --porcelain)" ] || fail "tests-gate render dirtied the worktree"

  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "prior-tests: pending (checked at merge)" \
    "merge-gate box pending without --tests-gate"
  pass "--tests-gate shows real counts and stays read-only"
}

# (k) watch mode re-renders and honors the frame bound
test_watch_mode_frames() {
  reset_fakes
  local d out frames
  d=$(new_case watch)
  make_repo_on_branch "$d/wt" fm/feat-w
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-w)"
  out=$(FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" --worktree "$d/wt" --watch 1)
  frames=$(printf '%s\n' "$out" | grep -c '^no-mistakes flow:')
  [ "$frames" = 2 ] || fail "expected 2 watch frames, got $frames"
  pass "watch mode re-renders and exits at the frame bound"
}

test_usage_error
test_missing_meta
test_task_id_resolution
test_running_step_highlight
test_parked_at_review_gate
test_outcomes_distinct
test_ci_green_monitoring
test_idle_static_diagram
test_unreadable_status
test_coarse_fallback
test_tests_gate_counts
test_watch_mode_frames

echo "all fm-nm-flow tests passed"
