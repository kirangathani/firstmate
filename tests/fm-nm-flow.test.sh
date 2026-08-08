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
#   (l) --help prints usage on stdout and exits 0
#   (m) an unexecuted base assertion qualifies the merge-gate row itself and
#       is never rendered as a bare ok, its file lands on the name-only legend
#       line, and the row stays inside 80 columns; an origin/-prefixed base
#       with two-digit counts keeps every rendered line inside 80 columns with
#       the base ref named whole, and an over-running probe degrades to
#       pending rather than hanging
#   (n) a red ci log marker surfaces CI RED instead of a healthy-wait banner
#   (o) test/lint kinds come from the worktree's .no-mistakes.yaml, and fall
#       back to det|LLM when no config is readable
#   (p) --tests-gate --watch renders frame 1 as checking... before the probe
#   (q) the header is bounded to the render width by shortening the title, and
#       never by truncating the branch or the 26-char ULID run id
#   (r) a worktree that disappears mid-watch reads as teardown, never as the
#       detached HEAD an empty symbolic-ref answer would otherwise imply
#   (s) a probe killed by a signal renders pending, never a green that means
#       nothing ran, and the perl bounding arm reports 128+signal like timeout
#   (t) watch frames are bounded to the row budget the way they are bounded to
#       columns: a stock 80x24 pane keeps a full result WITH every qualifier
#       and spends only plain legend lines to do it, a smaller budget drops
#       only plain legend lines and says how many, a result's four core
#       qualifier lines are undroppable (the box degrades to pending sooner),
#       an unfittable frame says so plainly, and the one-shot render is never
#       trimmed; a wrapping PR URL is charged the terminal rows it really takes
#   (u) the probe's scratch dir is removed even when a watch frame is interrupted
#   (v) --watch takes a task id or a numeric interval in either order, and names
#       a unit-suffixed interval as the mistyped interval it is
#   (w) a no-CI-checks marker gets its own banner, never CI GREEN
#   (x) a parked run with no resolvable gate name says so, and never invents a
#       findings breakdown it could not read
#   (y) INT/TERM during a timeout(1)-arm probe is honored immediately: the
#       viewer exits 130 promptly instead of after the probe's full bound, the
#       probe's process tree dies with it, and the scratch dir is cleaned
#   (z) an identifier covered by a captain-approved supersession entry is its
#       own labelled count in the merge-gate row - never folded into missing,
#       failing or unexecuted, never a green, inside 80 columns - and the
#       exec-gate marker decides whether the unexecuted class is matched at
#       all, mirroring the order bin/fm-pr-merge.sh applies; a result row
#       always names all SIX reported classes including their zeros, spending
#       the row prefix rather than a count when a wide magnitude will not fit,
#       derives its `ok` from those cells rather than from the check's exit
#       status (so a skipped or unaccounted identifier suppresses it at exit 0),
#       renders a never-evaluated class as a dash that is distinct from 0 and
#       suppresses `ok` too, keeps the class legend up whenever the labels are
#       up, and qualifies the result as a point-in-time snapshot against a
#       deliberately-unfetched LOCAL base ref; and the probe writes no guard
#       state and creates no state dir, even against a fresh FM_HOME
#   (aa) the merge-gate box resolves the base the GATE resolves - the branch
#       the task's recorded PR targets - and names it as the PR's own; when
#       that base cannot be read the box degrades to the default branch, says
#       on the row that it did, and never shows a silent default-branch verdict
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
# Test hook for the teardown case: delete the worktree once it has been read,
# so the NEXT watch frame observes a worktree that vanished mid-run.
if [ -n "${FM_FAKE_RM_WT:-}" ] && [ -d "$FM_FAKE_RM_WT" ]; then
  rm -rf "$FM_FAKE_RM_WT"
fi
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
  # Fake gh, shadowing any real one: the merge-gate box asks GitHub which branch
  # a recorded PR targets, and no test may make that a network call. It logs
  # every invocation so a case can assert the query happened (or did not), and
  # answers only what FM_FAKE_PR_BASE says - unset means the query fails, which
  # is the degraded path the box must fall back from.
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_GH_LOG:-}" ] && printf 'gh %s\n' "$*" >> "$FM_FAKE_GH_LOG"
if [ -n "${FM_FAKE_PR_BASE:-}" ]; then
  printf '%s\n' "$FM_FAKE_PR_BASE"
  exit 0
fi
printf 'could not resolve to a PullRequest\n' >&2
exit 1
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_RM_WT=""
  FM_FAKE_PR_BASE=""
  FM_FAKE_GH_LOG=""
  export FM_FAKE_AXI_STATUS FM_FAKE_RUNS_LIST FM_FAKE_CI_LOGS FM_FAKE_RM_WT
  export FM_FAKE_PR_BASE FM_FAKE_GH_LOG
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

# Reverse-video highlighting emits SGR escapes; drop them before measuring a
# rendered row's width so the count is characters, never escape bytes.
ESC=$(printf '\033')
strip_sgr() {  # <text>
  printf '%s' "$1" | sed "s/$ESC\\[[0-9;]*m//g"
}

# Non-tty watch frames are blank-line separated; the tests-gate result only
# lands from frame 2 on, so the frame under test is the last one.
last_frame() {  # <watch output>
  printf '%s\n' "$1" | awk 'BEGIN{RS=""} END{print}'
}

# Terminal rows a frame occupies in an 80-column pane: each line is charged
# ceil(len/80) rows after stripping SGR, which is what makes a wrapping PR URL
# count as the two rows it really takes.
frame_rows() {  # <frame>
  local total=0 line len
  while IFS= read -r line; do
    line=$(strip_sgr "$line")
    len=${#line}
    total=$(( total + (len == 0 ? 1 : (len - 1) / 80 + 1) ))
  done <<< "$1"
  printf '%s' "$total"
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

# Parked, but nothing in the answer names a gate: no `gate:` scalar, no gate
# block, and no steps row parked at awaiting_approval/fix_review. The steps
# table still says which step is being worked, which is the only highlight the
# diagram can honestly carry here.
run_parked_unnamed() {  # <branch> [findings-line]
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "abc1234"
${2:+  $2}
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,fixing,0,0
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

run_running_with_id() {  # <branch> <run-id>
  cat <<EOF
run:
  id: "$2"
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
  assert_contains "$out" "miss 1/fail 0/unex 0/excu -/skip 0/unac 0 !!" \
    "merge-gate box shows all six counts, missing among them"
  assert_contains "$out" "prior-tests: base main: LOCAL, never fetched" \
    "the compared base is named in full on its own legend line"
  assert_contains "$out" "LOCAL, never fetched" \
    "the base is disclosed as a local ref this viewer never fetched"
  assert_contains "$out" "the gate refetches it" \
    "the legend says plainly that the real gate compares against the remote"
  assert_contains "$out" "prior-tests: snapshot " \
    "the result is stamped as a point-in-time snapshot"
  [ -z "$(git -C "$d/wt" status --porcelain)" ] || fail "tests-gate render dirtied the worktree"

  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "prior-tests: pending (checked at merge)" \
    "merge-gate box pending without --tests-gate"
  pass "--tests-gate shows real counts and stays read-only"
}

# (aa) the box previews the gate, so it must resolve the base the GATE resolves:
# the branch the task's recorded PR targets, not the project's default branch.
# The fixture makes the two disagree in a way a wrong base cannot hide - the
# default branch carries an identifier the PR's base does not - so the counts
# alone say which tree was compared against.
make_pr_base_flow_case() {  # <name> -> echoes case dir
  local d=$1
  d=$(new_case "$d")
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
pass "only-on-default"
SH
  chmod +x "$d/wt/tests/demo.test.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm default
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb feature-base
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
SH
  git -C "$d/wt" commit -qam "the PR's own base"
  git -C "$d/wt" checkout -qb fm/pr-base-task
  printf 'note\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "the branch under review"
  fm_write_meta "$d/state/pr-base-task.meta" \
    "window=firstmate:fm-pr-base-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo" \
    "pr=https://github.com/o/r/pull/7"
  printf '%s\n' "$d"
}

test_tests_gate_uses_the_pr_base() {
  reset_fakes
  local d out
  d=$(make_pr_base_flow_case tests-gate-pr-base)
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(FM_FAKE_PR_BASE=feature-base FM_FAKE_GH_LOG="$d/gh.log" \
    run_flow "$d" pr-base-task --tests-gate)
  grep -q 'gh pr view https://github.com/o/r/pull/7 --json baseRefName' "$d/gh.log" \
    || fail "the box must ask GitHub which branch the PR targets: $(cat "$d/gh.log" 2>/dev/null)"
  assert_contains "$out" "prior-tests: base feature-base: the PR's own base, LOCAL" \
    "the row names the PR's own base, distinguishably from a default-branch base"
  assert_contains "$out" "the gate refetches it" \
    "the unfetched-base qualifier survives a PR-derived base"
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip 0/unac 0" \
    "comparing against the PR's base finds nothing missing"
  [ -z "$(git -C "$d/wt" status --porcelain)" ] || fail "the PR-base probe dirtied the worktree"
  pass "the merge-gate box compares against the branch the recorded PR targets"
}

# The same fixture with the PR base unreadable: a viewer blocks nothing, so it
# degrades to the default branch where the gate would refuse - but it must SAY
# it did, since a silent default-branch verdict is the defect being fixed.
test_tests_gate_pr_base_unreadable_degrades() {
  reset_fakes
  local d out
  d=$(make_pr_base_flow_case tests-gate-pr-base-degraded)
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(FM_FAKE_GH_LOG="$d/gh.log" run_flow "$d" pr-base-task --tests-gate)
  assert_contains "$out" "prior-tests: base main: no PR base read, LOCAL" \
    "an unresolvable PR base falls back to the default branch AND says so"
  assert_not_contains "$out" "the PR's own base" \
    "a fallback never claims the PR's own base"
  assert_contains "$out" "miss 1/fail 0/unex 0/excu 0/skip 0/unac 0 !!" \
    "the fallback really did compare against the default branch"
  pass "an unreadable PR base degrades to the default branch and names the fallback"
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

# (l) explicit help request is not a usage error
test_help_exits_zero() {
  reset_fakes
  local out err rc=0
  out=$("$NM_FLOW" --help 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "--help exit status"
  assert_contains "$out" "usage: fm-nm-flow.sh" "--help prints usage on stdout"
  err=$("$NM_FLOW" -h 2>&1 >/dev/null)
  [ -z "$err" ] || fail "-h wrote to stderr: $err"
  pass "--help prints usage on stdout and exits 0"
}

# (m) a base file check 2 could not execute qualifies the annotation
test_tests_gate_name_check_only() {
  reset_fakes
  local d out
  d=$(new_case tests-gate-nameonly)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
SH
  chmod +x "$d/wt/tests/demo.test.sh"
  # A python test file is enumerated by name (check 1) but never executed by
  # check 2 - deterministically, on any host: pytest resolution requires BOTH a
  # pytest config marker and a worktree-local interpreter (fm-test-exec-lib.sh),
  # and this fixture has neither. The gate reports its identifier as
  # `unexecuted:` and exits 1, so the row must carry the qualifier itself and
  # never a bare "ok".
  cat > "$d/wt/tests/test_demo.py" <<'PY'
def test_alpha():
    assert True
PY
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  printf 'note\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "unrelated change"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(run_flow "$d" --worktree "$d/wt" --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 1/excu -/skip 0/unac 0" \
    "merge-gate box qualifies its own annotation with the unexecuted count"
  assert_not_contains "$out" " ok" \
    "an unexecuted base assertion never renders a bare ok"
  assert_contains "$out" "prior-tests: base main: LOCAL, never fetched" \
    "the compared base is named in full on its own legend line"
  assert_contains "$out" "prior-tests: 1 base file verified by name only, not by assertion" \
    "the name-only file count is reported on its own legend line"
  local row width
  row=$(printf '%s\n' "$out" | grep 'miss 0/fail 0' | head -1)
  row=$(strip_sgr "$row")
  width=${#row}
  [ "$width" -le 80 ] || fail "merge-gate row is $width columns: $row"
  pass "name-check-only files get a legend line, not an overflowing row"
}

# The merge-gate row must survive the widest realistic inputs: an origin/-
# prefixed default branch AND two-digit missing/failing counts. The other
# fixtures here have no remote, so tests_gate_base falls through to the LOCAL
# `main` - the shortest base there is - and never exercises this.
test_tests_gate_long_base_and_wide_counts() {
  reset_fakes
  local d out line width n base_line
  d=$(new_case tests-gate-long-base)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests"
  git -C "$d/wt" init -q

  # 12 literal pass names the branch deletes outright -> 12 missing (check 1).
  cat > "$d/wt/tests/gone.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
SH
  for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    printf 'pass "gone %s"\n' "$n" >> "$d/wt/tests/gone.test.sh"
  done
  # 10 names the branch KEEPS while removing the code they assert on, so the
  # base file runs green on the base and emits nothing on the branch -> 10
  # failing (check 2). The file itself is byte-identical on both sides.
  cat > "$d/wt/tests/broken.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
. ./lib.sh
if type feature_present >/dev/null 2>&1; then
SH
  for n in 01 02 03 04 05 06 07 08 09 10; do
    printf '  pass "kept %s"\n' "$n" >> "$d/wt/tests/broken.test.sh"
  done
  printf 'fi\n' >> "$d/wt/tests/broken.test.sh"
  chmod +x "$d/wt/tests/gone.test.sh" "$d/wt/tests/broken.test.sh"
  printf 'feature_present() { return 0; }\n' > "$d/wt/lib.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M master
  # A remote-tracking ref with no remote configured: enough for tests_gate_base
  # to resolve an origin/-prefixed base, and explicit mode never fetches.
  git -C "$d/wt" update-ref refs/remotes/origin/master refs/heads/master
  git -C "$d/wt" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

  git -C "$d/wt" checkout -qb fm/change
  rm "$d/wt/tests/gone.test.sh"
  printf '# feature removed\n' > "$d/wt/lib.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "drop tests and the feature they assert on"

  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(run_flow "$d" --worktree "$d/wt" --tests-gate)
  assert_contains "$out" "miss 12/fail 10/unex 0/excu -/skip 0/unac 0 !!" \
    "two-digit missing and failing counts both land in the box row"
  base_line=$(printf '%s\n' "$out" | grep 'prior-tests: base ' | head -1)
  assert_contains "$base_line" "prior-tests: base origin/master: LOCAL, never fetched" \
    "the origin/-prefixed base is named whole and un-elided"
  assert_not_contains "$base_line" "..." "the base ref is never ellipsis-elided"

  # Every rendered line, box rows and legend lines alike, inside 80 columns.
  while IFS= read -r line; do
    line=$(strip_sgr "$line")
    width=${#line}
    [ "$width" -le 80 ] || fail "rendered line is $width columns: $line"
  done <<< "$out"
  pass "an origin/ base with two-digit counts still fits 80 columns"
}

# The probe runs the base's own test files, so it must be time-bounded and must
# degrade to pending - never to a green that means nothing actually ran.
test_tests_gate_probe_timeout() {
  reset_fakes
  local d out
  d=$(new_case tests-gate-timeout)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/slow.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
sleep 30
pass "alpha"
SH
  chmod +x "$d/wt/tests/slow.test.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  printf 'note\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "unrelated change"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(FM_NM_FLOW_TESTS_TIMEOUT=1 run_flow "$d" --worktree "$d/wt" --tests-gate)
  assert_contains "$out" "prior-tests: pending (probe timed out after 1s)" \
    "an over-running probe degrades to pending"
  assert_not_contains "$out" " ok" "a timed-out probe never renders a green result"
  assert_not_contains "$out" "prior-tests: base " \
    "a timed-out probe claims no comparison"
  assert_not_contains "$out" "verified by name only" \
    "a timed-out probe carries no stale name-only count"
  pass "the tests-gate probe is bounded and fails to pending"
}

# (n) a red ci marker is surfaced, not collapsed into a healthy wait
test_ci_red_banner() {
  reset_fakes
  local d out
  d=$(new_case ci-red)
  make_repo_on_branch "$d/wt" fm/feat-red
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-red)"
  FM_FAKE_CI_LOGS="CI checks failed on the PR - pipeline will fix"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "CI RED: checks failed - pipeline fixing" "red checks surfaced"
  assert_contains "$out" ">> [ CI monitor  det+LLM ]" "red CI keeps the ci box highlighted"
  assert_not_contains "$out" "state: running @ ci" "red CI is not rendered as a healthy wait"

  FM_FAKE_CI_LOGS="review issues detected on the PR"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "CI RED: issues detected - pipeline fixing" "issues marker surfaced"
  pass "red CI markers reach the banner"
}

# (o) test/lint kinds come from the target project's own config
test_step_kinds_from_config() {
  reset_fakes
  local d out
  d=$(new_case step-kinds)
  make_repo_on_branch "$d/wt" fm/feat-kinds
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"

  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "[ test        det|LLM ]" "no config leaves the test kind conditional"
  assert_contains "$out" "[ lint        det|LLM ]" "no config leaves the lint kind conditional"
  assert_contains "$out" "det|LLM: commands.<step> not readable in .no-mistakes.yaml" \
    "conditional label is explained"

  cat > "$d/wt/.no-mistakes.yaml" <<'YAML'
commands:
  test: 'make test'
YAML
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "[ test        det     ]" "commands.test makes the test step det"
  assert_contains "$out" "[ lint        LLM     ]" "absent commands.lint makes the lint step LLM"
  assert_not_contains "$out" "det|LLM" "a readable config drops the conditional label"

  # A key that IS present but whose value is not readable inline must not be
  # asserted as agent-driven; it is exactly the unknown case.
  cat > "$d/wt/.no-mistakes.yaml" <<'YAML'
commands:
  test:
    - bash tests/run.sh
  lint: 'bin/lint.sh'
YAML
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "[ test        det|LLM ]" "a non-inline commands.test value stays conditional"
  assert_contains "$out" "[ lint        det     ]" "an inline commands.lint value is still det"
  assert_contains "$out" "det|LLM: commands.<step> not readable in .no-mistakes.yaml" \
    "the legend names what could not be read"
  pass "step kinds follow the worktree's .no-mistakes.yaml"
}

# (p) the tests-gate probe never blanks the first watch frame
test_tests_gate_first_frame() {
  reset_fakes
  local d out first
  d=$(new_case tests-gate-frame)
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
  # A run parked mid-flow, so the snapshot stamp has a real step to name. The
  # step is read out of `probe`, and watch mode captures only the RENDER in a
  # command substitution - a probe run in there would leave CURRENT empty in
  # the shell run_tests_gate executes in and stamp "an unknown step" forever.
  FM_FAKE_AXI_STATUS="$(run_running fm/change)"
  out=$(FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" --worktree "$d/wt" --tests-gate --watch 1)
  first=$(printf '%s\n' "$out" | sed -n '1,/^$/p')
  assert_contains "$first" "prior-tests: checking..." "frame 1 renders before the probe runs"
  assert_not_contains "$first" "prior-tests: base " \
    "frame 1 claims no comparison before the probe has run"
  assert_contains "$out" "miss 1/fail 0/unex 0/excu -/skip 0/unac 0 !!" \
    "frame 2 carries the computed result"
  assert_contains "$out" "snapshot " \
    "the cached watch result is stamped as a snapshot, not a live verdict"
  assert_contains "$out" "at step review; not re-checked since" \
    "the watch stamp names the step the run was really at"
  assert_not_contains "$out" "an unknown step" \
    "the watch stamp never falls back to an unknown step for a readable run"
  # The stamp carries a date as well as a clock reading: a pane left open
  # overnight must not render a time that scans as this morning's.
  assert_contains "$out" "snapshot $(date '+%m-%d') " \
    "the snapshot stamp carries the date, not just the time"
  pass "--tests-gate --watch never blanks the first frame"
}

# (q) the header never wraps an 80-column pane, and never at the run id's cost
test_header_width_bounded() {
  reset_fakes
  local d wt out hdr rid
  d=$(new_case header-width)
  wt="$d/wt-a-deliberately-long-task-worktree-name-for-the-header"
  make_repo_on_branch "$wt" fm/header-branch
  make_fakebin "$d" >/dev/null
  rid=01JQZX9K7T8V6WQ2E5R3N4M0AB
  [ ${#rid} -eq 26 ] || fail "fixture run id is ${#rid} chars, expected a 26-char ULID"
  FM_FAKE_AXI_STATUS="$(run_running_with_id fm/header-branch "$rid")"

  # Not a tty and no override: the hard 80-column default applies.
  out=$(run_flow "$d" --worktree "$wt")
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  [ ${#hdr} -le 80 ] || fail "header is ${#hdr} columns at the 80-col default: $hdr"
  assert_contains "$hdr" "$rid" "the full run id survives at 80 columns"
  assert_contains "$hdr" "branch fm/header-branch" "the branch survives whole"
  assert_not_contains "$hdr" "no-mistakes flow: " "the prefix is dropped before the title shrinks further"
  assert_contains "$hdr" "..." "the shortened title is ellipsis-marked at 80 columns"

  # Room for part of the title: it is shortened with an ellipsis, prefix intact.
  out=$(FM_NM_FLOW_COLS=100 run_flow "$d" --worktree "$wt")
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  [ ${#hdr} -le 100 ] || fail "header is ${#hdr} columns at 100: $hdr"
  assert_contains "$hdr" "no-mistakes flow: " "the prefix survives a shortened title"
  assert_contains "$hdr" "..." "the shortened title carries the ellipsis"
  assert_contains "$hdr" "$rid" "the full run id survives a shortened title"

  # A non-numeric or absurd override falls back to the same 80 columns.
  out=$(FM_NM_FLOW_COLS=not-a-number run_flow "$d" --worktree "$wt")
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  [ ${#hdr} -le 80 ] || fail "non-numeric width override did not fall back to 80: $hdr"
  out=$(FM_NM_FLOW_COLS=5 run_flow "$d" --worktree "$wt")
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  [ ${#hdr} -le 80 ] || fail "below-floor width override did not fall back to 80: $hdr"

  # A wider pane gets the whole header.
  out=$(FM_NM_FLOW_COLS=140 run_flow "$d" --worktree "$wt")
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  [ ${#hdr} -le 140 ] || fail "header is ${#hdr} columns at 140: $hdr"
  assert_contains "$hdr" "${wt##*/}" "a wider pane keeps the full title"
  assert_not_contains "$hdr" "..." "a wider pane needs no ellipsis"

  # Too narrow for any title: the fixed prefix goes before the branch or run id.
  out=$(FM_NM_FLOW_COLS=40 run_flow "$d" --worktree "$wt")
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  assert_not_contains "$hdr" "no-mistakes flow: " "the prefix is dropped before anything is mutilated"
  assert_contains "$hdr" "... | branch fm/header-branch" "a dropped title is still ellipsis-marked"
  assert_contains "$hdr" "$rid" "the full run id survives a narrow pane"
  pass "header is bounded by width without truncating branch or run id"
}

# (r) a worktree that disappears mid-watch is teardown, not a detached HEAD
test_worktree_removed_mid_watch() {
  reset_fakes
  local d out second
  d=$(new_case torn-down)
  make_repo_on_branch "$d/wt" fm/feat-gone
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-gone)"
  # The fake removes the worktree as it answers frame 1, so frame 2 probes a
  # worktree that is gone - exactly the state teardown leaves behind.
  FM_FAKE_RM_WT="$d/wt"
  out=$(FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" --worktree "$d/wt" --watch 1)
  second=$(printf '%s\n' "$out" | sed -n '/^$/,$p')
  assert_contains "$second" "TORN DOWN: worktree removed - task cleaned up" \
    "a removed worktree is reported as teardown"
  assert_not_contains "$second" "detached HEAD" \
    "a removed worktree is never reported as a HEAD state nothing observed"
  assert_not_contains "$second" "<detached>" \
    "the header does not claim a detached HEAD either"
  assert_contains "$second" "| worktree removed" \
    "the header says what was actually observed"
  assert_contains "$second" "[ teardown" "the static diagram is still rendered"
  pass "a worktree removed mid-watch reads as teardown, not a detached HEAD"
}

# The real task-id-mode header: the whole task id must survive at 80 columns.
test_header_keeps_task_id() {
  reset_fakes
  local d out hdr rid
  d=$(new_case header-task-id)
  make_repo_on_branch "$d/wt" fm/nm-flow-view-r7
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nm-flow-view-r7.meta" \
    "window=firstmate:fm-nm-flow-view-r7" \
    "worktree=$d/wt" \
    "project=$d/projects/firstmate"
  rid=01KYSAKNFRDXWKD0DF48ME438R
  FM_FAKE_AXI_STATUS="$(run_running_with_id fm/nm-flow-view-r7 "$rid")"
  out=$(run_flow "$d" nm-flow-view-r7)
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  [ ${#hdr} -le 80 ] || fail "task-id header is ${#hdr} columns: $hdr"
  assert_contains "$hdr" "nm-flow-view-r7..." "the whole task id survives, ellipsis-marked and unpadded"
  assert_contains "$hdr" "branch fm/nm-flow-view-r7" "the branch survives whole"
  assert_contains "$hdr" "$rid" "the full run id survives"
  pass "task identity outranks the fixed header prefix"
}

# (s) a signal-killed probe is not a result. The bounding ladder must report the
# signal death, and the gate must land on pending: run_bounded's rc IS the
# merge-gate verdict, so an rc that swallowed the signal renders an "ok" over a
# suite that never ran.
test_perl_bounding_arm_reports_signals() {
  reset_fakes
  local prog rc=0
  prog=$(sed -n "s/^PERL_BOUND_PROG='\\(.*\\)'\$/\\1/p" "$NM_FLOW")
  [ -n "$prog" ] || fail "could not extract PERL_BOUND_PROG from $NM_FLOW"
  case "$prog" in
    *'& 127'*) : ;;
    *) fail "the perl bounding arm no longer inspects the signal bits: $prog" ;;
  esac
  if ! command -v perl >/dev/null 2>&1; then
    pass "perl bounding arm preserves the signal case (static check, no perl here)"
    return
  fi
  perl -e "$prog" 10 bash -c 'kill -9 $$' >/dev/null 2>&1 || rc=$?
  expect_code 137 "$rc" "a SIGKILLed child is reported as 128+9, never as 0"
  rc=0
  perl -e "$prog" 10 bash -c 'exit 3' >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an ordinary non-zero exit is still passed through"
  rc=0
  perl -e "$prog" 1 sleep 30 >/dev/null 2>&1 || rc=$?
  expect_code 124 "$rc" "expiry is still reported as 124"

  # An interrupted parent must not orphan the detached child pgroup: TERM to
  # the perl parent forwards to the group, so the probe dies with the viewer
  # instead of running the base suite unbounded after the viewer is gone.
  local pidfile ppid child i=0
  pidfile=$TMP_ROOT/perl-arm-child-pid
  rm -f "$pidfile"
  perl -e "$prog" 30 bash -c "echo \$\$ > '$pidfile'; sleep 30" >/dev/null 2>&1 &
  ppid=$!
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$pidfile" ] || fail "the bounded child never started"
  child=$(cat "$pidfile")
  kill -TERM "$ppid" 2>/dev/null || true
  rc=0
  wait "$ppid" 2>/dev/null || rc=$?
  expect_code 143 "$rc" "TERM to the perl parent is reported as 128+15 like timeout"
  i=0
  while kill -0 "$child" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  if kill -0 "$child" 2>/dev/null; then
    kill -9 "$child" 2>/dev/null || true
    fail "the perl parent orphaned its child pgroup on TERM"
  fi
  pass "the perl bounding arm reports 128+signal and never orphans the probe"
}

test_tests_gate_signal_killed_probe() {
  reset_fakes
  local d out
  d=$(new_case tests-gate-signal)
  make_fakebin "$d" >/dev/null
  # A copy of the viewer with a sibling probe that dies by SIGKILL: SCRIPT_DIR
  # resolves the probe next to the script, so this is the only way to make the
  # real invocation come back signal-killed rather than merely non-zero.
  mkdir -p "$d/bin"
  cp "$NM_FLOW" "$d/bin/fm-nm-flow.sh"
  # The viewer sources the shared supersession grammar from its own directory,
  # so the copy needs it too - a missing library is a broken install and the
  # viewer says so rather than degrading quietly.
  cp "$ROOT/bin/fm-supersession-lib.sh" "$d/bin/fm-supersession-lib.sh"
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
kill -9 $$
SH
  chmod +x "$d/bin/fm-nm-flow.sh" "$d/bin/fm-assert-tests-kept.sh"
  mkdir -p "$d/wt/tests"
  git -C "$d/wt" init -q
  printf 'base\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" --worktree "$d/wt" --tests-gate)
  assert_contains "$out" "prior-tests: pending (check could not run, exit 137)" \
    "a signal-killed probe lands on pending and names the exit"
  assert_not_contains "$out" " ok" \
    "a signal-killed probe never renders a green result"
  assert_not_contains "$out" "prior-tests: base " \
    "a signal-killed probe claims no comparison"
  assert_not_contains "$out" "verified by name only" \
    "a signal-killed probe carries no stale name-only count"
  pass "a signal-killed probe renders pending, never a false green"
}

# (t) in watch mode the frame is bounded to the pane's rows the way it is
# bounded to columns; the one-shot render is never trimmed. The worst case is
# the ordinary one: every conditional line present at once - the PR line, the
# result's three always-on qualifier lines, the name-only count and the det|LLM
# legend - and every qualifier ranks as core while the box shows a result. The
# plain 80x24 pane is the constraint that sizes that block: a full result and
# all four core qualifiers must still fit there, spending only plain legends to
# do it. Below it the plain legends go first and then the box degrades to
# pending, never separating a result from what qualifies it.
test_frame_height_bounded() {
  reset_fakes
  local d out frame lines hdr box
  d=$(new_case frame-height)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
SH
  chmod +x "$d/wt/tests/demo.test.sh"
  # Never executed by check 2, so it is verified by name only -> legend line.
  cat > "$d/wt/tests/test_demo.py" <<'PY'
def test_alpha():
    assert True
PY
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  printf 'note\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "unrelated change"
  # Task-id mode with a PR in the meta: that is what puts the PR line in the
  # frame without a run to read one from. No .no-mistakes.yaml -> det|LLM.
  fm_write_meta "$d/state/height-task.meta" \
    "window=firstmate:fm-height-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo" \
    "pr=https://github.com/o/r/pull/7"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"

  # 26 rows: the worst case, every conditional line present at once, fits whole.
  out=$(FM_NM_FLOW_ROWS=26 FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" height-task --tests-gate --watch 1)
  frame=$(last_frame "$out")
  assert_contains "$frame" "PR: https://github.com/o/r/pull/7" "the PR line is present"
  assert_contains "$frame" "prior-tests: base main: no PR base read, LOCAL" \
    "the base legend is present, naming the fallback the fake gh forces"
  assert_contains "$frame" "the gate refetches it" "the unfetched-base qualifier is present"
  assert_contains "$frame" "prior-tests: snapshot " "the snapshot qualifier is present"
  assert_contains "$frame" "prior-tests: excu=captain-excused" "the class legend is present"
  assert_contains "$frame" "verified by name only" "the name-only legend is present"
  assert_contains "$frame" "det|LLM: commands.<step>" "the det|LLM legend is present"
  lines=$(printf '%s\n' "$frame" | wc -l | tr -d ' ')
  [ "$lines" = 26 ] || fail "the worst-case frame is $lines lines, expected the 26-line case"
  assert_not_contains "$frame" "legend line" "nothing is dropped inside a 26-row budget"
  hdr=$(strip_sgr "$(printf '%s\n' "$frame" | head -1)")
  assert_contains "$hdr" "height-task" "the header survives the widest budget"

  # THE HARD CONSTRAINT: a plain 80x24 tmux pane. The counts and every qualifier
  # that keeps them from reading as verified must ALL survive there - the plain
  # legends are what gives way, and the box must never degrade to pending at
  # this size just because the qualifiers grew.
  out=$(FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" height-task --tests-gate --watch 1)
  frame=$(last_frame "$out")
  lines=$(printf '%s\n' "$frame" | wc -l | tr -d ' ')
  [ "$lines" -le 24 ] || fail "frame is $lines lines against the default 24-row budget"
  assert_not_contains "$frame" "pane too short to qualify" \
    "a stock 80x24 pane never loses the counts to the too-short backstop"
  assert_contains "$frame" "3 legend lines dropped to fit a 24-row pane" "the drop is stated explicitly"
  assert_contains "$frame" "miss 0/fail 0/unex 1/excu 0/skip 0/unac 0" \
    "the qualified result row survives the drop"
  assert_contains "$frame" "prior-tests: base main: no PR base read, LOCAL" \
    "the base claim is undroppable while a result shows"
  assert_contains "$frame" "the gate refetches it" \
    "the stale-base qualifier is undroppable while a result shows"
  assert_contains "$frame" "prior-tests: snapshot " \
    "the snapshot qualifier is undroppable while a result shows"
  assert_contains "$frame" "prior-tests: excu=captain-excused" \
    "the class legend is undroppable while the labels are up"
  assert_contains "$frame" "verified by name only" \
    "the name-only claim is undroppable while a result shows"
  assert_not_contains "$frame" "outcomes: checks-passed" "plain legends are what drops"
  hdr=$(strip_sgr "$(printf '%s\n' "$frame" | head -1)")
  assert_contains "$hdr" "height-task" "the header is never dropped"
  assert_contains "$frame" "IDLE: no run for branch" "the banner is never dropped"
  for box in intent rebase review test document lint push "open PR" "CI monitor" "merge gate" captain teardown; do
    assert_contains "$frame" "[ $box" "step row $box is never dropped"
  done

  # 22 rows, below the plain-pane floor: the result, its qualifiers and the
  # mandatory drop notice no longer coexist, so the box itself degrades to
  # pending - at no pane size does a result appear separated from its qualifiers.
  out=$(FM_NM_FLOW_ROWS=22 FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" height-task --tests-gate --watch 1)
  frame=$(last_frame "$out")
  lines=$(printf '%s\n' "$frame" | wc -l | tr -d ' ')
  [ "$lines" -le 22 ] || fail "frame is $lines lines against a 22-row budget"
  assert_contains "$frame" "prior-tests: pending (pane too short to qualify)" \
    "the box degrades to pending when its qualifiers cannot fit"
  assert_not_contains "$frame" "prior-tests: base " "no unqualifiable claim is made"
  assert_not_contains "$frame" "snapshot " "no unqualifiable snapshot claim is made"
  assert_not_contains "$frame" "unex 1" "no unqualifiable count is shown"
  assert_not_contains "$frame" "excu 0" "no green appears without its qualifiers"

  # 21 rows: degraded to pending AND still over budget, so the plain legends go
  # too and the drop is stated.
  out=$(FM_NM_FLOW_ROWS=21 FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" height-task --tests-gate --watch 1)
  frame=$(last_frame "$out")
  lines=$(printf '%s\n' "$frame" | wc -l | tr -d ' ')
  [ "$lines" -le 21 ] || fail "frame is $lines lines against a 21-row budget"
  assert_contains "$frame" "prior-tests: pending (pane too short to qualify)" \
    "the degraded box stays pending as the pane shrinks further"
  assert_contains "$frame" "legend lines dropped to fit a 21-row pane" "the drop is still stated"

  # A pane too short even for the core rows: everything the frame can say is
  # said plainly - it will scroll - never a claim that it was made to fit.
  out=$(FM_NM_FLOW_ROWS=12 FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" height-task --tests-gate --watch 1)
  frame=$(last_frame "$out")
  assert_contains "$frame" "prior-tests: pending (pane too short to qualify)" \
    "the degraded box still never shows an unqualified result"
  assert_contains "$frame" "frame needs 18 rows; this 12-row pane will scroll it" \
    "an unfittable frame says so plainly"
  assert_not_contains "$frame" "dropped to fit" "no notice claims an unfittable frame was made to fit"
  assert_not_contains "$frame" "prior-tests: base " "still no unqualified claim"

  # A bogus override falls back to the same hard 24-row default.
  out=$(FM_NM_FLOW_ROWS=not-a-number FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" height-task --tests-gate --watch 1)
  frame=$(last_frame "$out")
  lines=$(printf '%s\n' "$frame" | wc -l | tr -d ' ')
  [ "$lines" = 24 ] || fail "a non-numeric row override did not fall back to 24: $lines lines"
  assert_contains "$frame" "3 legend lines dropped to fit a 24-row pane" \
    "the fallback budget behaves exactly like the explicit 24-row one"

  # The one-shot render is never trimmed: scrollback makes trimming pointless,
  # so even a tiny declared pane gets the complete frame.
  out=$(FM_NM_FLOW_ROWS=12 run_flow "$d" height-task --tests-gate)
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" = 26 ] || fail "the one-shot render was trimmed to $lines lines"
  assert_contains "$out" "prior-tests: base main: no PR base read, LOCAL" \
    "the one-shot render keeps the base claim"
  assert_contains "$out" "miss 0/fail 0/unex 1/excu 0/skip 0/unac 0" \
    "the one-shot render keeps the qualified result"
  assert_not_contains "$out" "dropped to fit" "the one-shot render drops nothing"
  assert_not_contains "$out" "frame needs" "the one-shot render claims no shortfall"
  pass "watch frames are row-bounded, results stay qualified, one-shot renders whole"
}

# The row budget counts terminal ROWS, not frame lines: the PR URL is never
# truncated, so past 80 columns it wraps and must be charged the rows it
# really takes. A line-counting budget would claim this frame fits and drop
# nothing; the row-counting budget drops two legend lines and says so.
test_wrapping_pr_row_budget() {
  reset_fakes
  local d out frame rows url
  d=$(new_case pr-wrap)
  make_fakebin "$d" >/dev/null
  make_repo_on_branch "$d/wt" fm/wrap
  url="https://github.com/very-long-organization-name/very-long-repository-name-for-wrapping/pull/123456"
  fm_write_meta "$d/state/wrap-task.meta" \
    "window=firstmate:fm-wrap-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo" \
    "pr=$url"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(FM_NM_FLOW_ROWS=22 FM_NM_FLOW_WATCH_MAX=1 run_flow "$d" wrap-task --watch 1)
  frame=$(last_frame "$out")
  assert_contains "$frame" "PR: $url" "the PR URL is carried whole, never truncated"
  rows=$(frame_rows "$frame")
  [ "$rows" -le 22 ] || fail "frame occupies $rows terminal rows against a 22-row budget"
  assert_contains "$frame" "2 legend lines dropped to fit a 22-row pane" \
    "the wrapped PR line is charged the rows it takes"
  pass "the row budget charges a wrapping PR URL as the rows it really takes"
}

# The whole-frame budget, asserted for every run state at once against the pane
# size that is the hard constraint: a plain 80x24.
#
# This exists because the two halves of "fits" were only ever checked apart.
# Line WIDTHS were asserted per row and the total ROW COUNT was not, so a round
# that added qualifier lines silently pushed the frame to 25 rows and the
# too-short backstop swallowed the six counts in exactly the pane the captain
# named. Later the reverse: the row count fitted at 24 while two lines ran past
# 80 columns, which wraps in a real pane to 26 and loses the header the same way.
# Either half alone reads as green. So both are asserted here, together, on
# every state the viewer can be left open at - and rows are counted the way a
# terminal counts them, charging a wrapped line the rows it really takes.
#
# The third assertion is what makes this a closure rather than a fix: the six
# counts must be present in EVERY one of these frames. Headroom is trivially
# available by dropping them, that is precisely what the backstop does under
# pressure, and it is the one trade this display must never make - so a future
# change cannot buy layout room with the data the flag exists to show.
#
# The pathological gate name is deliberate: the parked banner and the snapshot
# stamp both interpolate it, and a gate name has no length this viewer controls.
test_frame_row_budget_all_states() {
  reset_fakes
  local d out frame rows line width scenario status url
  d=$(new_case row-budget)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests" "$d/bin" "$d/data/supersessions" "$d/nodate"
  mkdir -p "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  cp "$NM_FLOW" "$d/bin/fm-nm-flow.sh"
  cp "$ROOT/bin/fm-supersession-lib.sh" "$d/bin/fm-supersession-lib.sh"
  # The base of a task with a recorded pr= is resolved through this library, so
  # the copy needs it too: without it the fallback below would be reached for
  # the wrong reason.
  cp "$ROOT/bin/fm-pr-lib.sh" "$d/bin/fm-pr-lib.sh"
  chmod +x "$d/bin/fm-nm-flow.sh"
  # Every class non-zero at once, plus the name-only stderr line: the widest
  # result the row and its qualifiers can ever be asked to carry. Stubbed rather
  # than provoked from a real base, because reaching all six classes AND an
  # excusal from real fixtures would make the row's content depend on what the
  # host can execute.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "missing: tests/demo.test.sh::alpha"
echo "missing: tests/demo.test.sh::beta"
echo "missing: tests/other.test.sh::gamma"
echo "failing: tests/demo.test.sh::delta"
echo "unexecuted: tests/test_demo.py::epsilon"
echo "skipped: tests/demo.test.sh::zeta"
echo "unaccounted: tests/demo.test.sh::eta"
echo "summary: missing=3 failing=1 unexecuted=1 skipped=1 unaccounted=1"
echo "UNEXECUTED: tests/test_demo.py" >&2
exit 1
SH
  chmod +x "$d/bin/fm-assert-tests-kept.sh"
  # One identifier excused, so the excused count is a real non-zero rather than
  # the zero every other case in this file renders.
  cat > "$d/data/supersessions/demo.md" <<'MD'
- ids: tests/other.test.sh::* | project: demo | kind: missing | date: 2026-08-03 | reason: gamma is deliberately superseded
MD
  url="https://github.com/o/r/pull/7"
  # No .no-mistakes.yaml, so the det|LLM legend is up too: every conditional
  # line the frame can carry is present in all six renders.
  fm_write_meta "$d/state/budget-task.meta" \
    "window=firstmate:fm-budget-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo" \
    "pr=$url"

  for scenario in idle running parked-named parked-long-gate checks-passed failed; do
    case "$scenario" in
      idle)         status="runs: 0 runs yet in this repository" ;;
      running)      status=$(run_running_with_id fm/change 01KZ3ZKVA4TR8V8S4R667Q6VYK) ;;
      parked-named) status=$(run_parked fm/change) ;;
      parked-long-gate)
        status="$(run_parked fm/change)"
        status="${status%gate: review}gate: review-with-a-very-long-gate-name-here"
        ;;
      checks-passed) status=$(run_outcome fm/change checks-passed "$url") ;;
      failed)        status=$(run_outcome fm/change failed "$url") ;;
    esac
    FM_FAKE_AXI_STATUS="$status"
    export FM_FAKE_AXI_STATUS
    out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
      FM_NM_FLOW_COLS=80 FM_NM_FLOW_ROWS=24 FM_NM_FLOW_WATCH_MAX=2 \
      "$d/bin/fm-nm-flow.sh" budget-task --tests-gate --watch 1)
    frame=$(last_frame "$out")
    rows=$(frame_rows "$frame")
    [ "$rows" -le 24 ] || fail "$scenario frame occupies $rows terminal rows in an 80x24 pane"
    while IFS= read -r line; do
      line=$(strip_sgr "$line")
      width=${#line}
      [ "$width" -le 80 ] || fail "$scenario frame line is $width columns: $line"
    done <<< "$frame"
    assert_contains "$frame" "miss 2/fail 1/unex 1/excu 1/skip 1/unac 1 !!" \
      "$scenario keeps all six counts inside the 80x24 budget"
    assert_contains "$frame" "prior-tests: base main: no PR base read, LOCAL" \
      "$scenario keeps the base qualifier with the counts"
    assert_contains "$frame" "prior-tests: snapshot " \
      "$scenario keeps the snapshot qualifier with the counts"
    assert_contains "$frame" "verified by name only" \
      "$scenario keeps the name-only qualifier with the counts"
    assert_not_contains "$frame" "pane too short to qualify" \
      "$scenario never degrades the box in a plain 80x24 pane"
  done

  # The long gate name is bounded in BOTH lines that interpolate it, and every
  # elision is marked: a shortened gate name must never read as a whole one.
  FM_FAKE_AXI_STATUS="$(run_parked fm/change)"
  FM_FAKE_AXI_STATUS="${FM_FAKE_AXI_STATUS%gate: review}gate: review-with-a-very-long-gate-name-here"
  export FM_FAKE_AXI_STATUS
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    FM_NM_FLOW_COLS=80 "$d/bin/fm-nm-flow.sh" budget-task --tests-gate)
  # The breakdown is carried whole and the name is what shrinks around it, to
  # exactly the width the rest of the line leaves.
  assert_contains "$out" \
    "PARKED at review-with-a-ve... gate: 2 findings (1 ask-user, 1 auto-fix, 0 no-op)" \
    "the gate name gives way to the findings breakdown, with the elision marked"
  assert_contains "$out" "at step review-with-a...; not re-checked since" \
    "the snapshot stamp bounds the same name against what its own sentence leaves"
  assert_not_contains "$out" "gate-name-here gate:" "no unbounded gate name reaches the banner"

  # The stamp's whole job is to make a stale result self-evidently stale, so the
  # one host condition its own assignment tolerates - `date` failing - must not
  # leave a blank where the age belongs.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/nodate/date"
  chmod +x "$d/nodate/date"
  out=$(PATH="$d/nodate:$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    FM_NM_FLOW_COLS=80 "$d/bin/fm-nm-flow.sh" budget-task --tests-gate)
  assert_contains "$out" "prior-tests: snapshot unknown time at " \
    "a failed clock reading is named, never rendered as a blank age"
  assert_not_contains "$out" "snapshot  at " "the stamp never renders an empty age"
  pass "every run state fits a plain 80x24 pane with all six counts intact"
}

# (u) the probe's scratch dir is the only thing this viewer writes, and an
# interrupt lands the moment the bounded probe returns - before any cleanup on
# the return path could run.
test_tests_gate_tmpdir_cleanup_on_interrupt() {
  reset_fakes
  local d pid i leftover
  d=$(new_case tests-gate-tmpdir)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/tmp" "$d/wt/tests"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/slow.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
sleep 30
pass "alpha"
SH
  chmod +x "$d/wt/tests/slow.test.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  printf 'note\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "unrelated change"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"

  # The viewer is launched directly rather than through run_flow: a backgrounded
  # shell function makes $! the subshell, and the signal would never reach the
  # script it wraps.
  TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    FM_NM_FLOW_TESTS_TIMEOUT=5 \
    "$NM_FLOW" --worktree "$d/wt" --tests-gate --watch 1 >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    set -- "$d"/tmp/fm-nm-flow.*
    [ -d "$1" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  set -- "$d"/tmp/fm-nm-flow.*
  [ -d "$1" ] || fail "the probe never created its scratch dir under TMPDIR"
  # TERM, not INT: a background job of a non-interactive shell starts with
  # SIGINT ignored, and bash cannot re-trap a signal that was ignored on entry,
  # so an INT here would be a no-op. Both land on the same handler, which fires
  # out of the `wait` while the probe is still running - ahead of the cleanup
  # line on run_tests_gate's own return path.
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  leftover=$(find "$d/tmp" -maxdepth 1 -name 'fm-nm-flow.*' 2>/dev/null | head -1)
  [ -z "$leftover" ] || fail "an interrupted probe leaked its scratch dir: $leftover"
  pass "the probe's scratch dir is removed even when the frame is interrupted"
}

# (y) on the timeout(1) arm the probe runs in its own process group, so a
# terminal interrupt reaches only the viewer's bash - and a FOREGROUND probe
# would defer the trap until the probe returned, up to the probe's whole bound
# (five minutes at the default). The probe runs as a background job under an
# interruptible `wait` precisely so the handler fires the moment the signal
# lands, TERMs the probe's tree, and lets the EXIT trap clean the scratch dir.
# TERM for the same re-trap reason as (u); the bound is set far past the
# test's own patience so a deferred trap cannot sneak through as a pass.
test_tests_gate_interrupt_not_deferred_on_timeout_arm() {
  reset_fakes
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    pass "interrupting the timeout arm (skipped: no timeout tool on this host)"
    return
  fi
  local d pid base_pid i rc=0 leftover
  d=$(new_case tests-gate-interrupt-prompt)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/tmp" "$d/wt/tests"
  git -C "$d/wt" init -q
  # The base suite records its own pid so its death is observable, then
  # outsleeps both the probe bound and the test.
  cat > "$d/wt/tests/slow.test.sh" <<SH
#!/usr/bin/env bash
echo \$\$ > '$d/base-suite-pid'
sleep 120
SH
  chmod +x "$d/wt/tests/slow.test.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  printf 'note\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "unrelated change"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"

  TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    FM_NM_FLOW_TESTS_TIMEOUT=60 \
    "$NM_FLOW" --worktree "$d/wt" --tests-gate --watch 1 >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ ! -s "$d/base-suite-pid" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$d/base-suite-pid" ] || fail "the base suite never started under the probe"
  base_pid=$(cat "$d/base-suite-pid")
  kill -TERM "$pid" 2>/dev/null || true
  # Promptness IS the property: the viewer gets ~5s to exit, not the 60s bound
  # a deferred trap would spend.
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    kill -9 "$base_pid" 2>/dev/null || true
    fail "TERM was deferred: the viewer was still alive 5s after the signal"
  fi
  wait "$pid" 2>/dev/null || rc=$?
  expect_code 130 "$rc" "the one INT/TERM handler still reports 130"
  # The probe tree must die with the viewer, never run the base suite on.
  i=0
  while kill -0 "$base_pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  if kill -0 "$base_pid" 2>/dev/null; then
    kill -9 "$base_pid" 2>/dev/null || true
    fail "the interrupted viewer orphaned the running base suite"
  fi
  leftover=$(find "$d/tmp" -maxdepth 1 -name 'fm-nm-flow.*' 2>/dev/null | head -1)
  [ -z "$leftover" ] || fail "an interrupted probe leaked its scratch dir: $leftover"
  pass "a timeout-arm interrupt ends viewer, probe tree and scratch dir promptly"
}

# (v) --watch before the task id must work: task ids are 26-char ULIDs, and a
# ULID is not an interval. Only an all-digits argument is eaten as the interval,
# and the one genuinely ambiguous shape is named rather than left to fail later.
test_watch_argument_shapes() {
  reset_fakes
  local d out err rc=0 rid
  d=$(new_case watch-args)
  rid=01KYSAKNFRDXWKD0DF48ME438R
  make_repo_on_branch "$d/wt" fm/watch-args
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/$rid.meta" \
    "window=firstmate:fm-watch-args" \
    "worktree=$d/wt" \
    "project=$d/projects/demo"
  FM_FAKE_AXI_STATUS="$(run_running fm/watch-args)"

  out=$(FM_NM_FLOW_WATCH_MAX=1 run_flow "$d" --watch "$rid")
  assert_contains "$out" "branch fm/watch-args" "--watch <task-id> resolves the task"
  assert_contains "$out" "state: running @ review" "flag-first invocation renders the run"

  out=$(FM_NM_FLOW_WATCH_MAX=1 run_flow "$d" --watch 2 "$rid")
  assert_contains "$out" "branch fm/watch-args" "a numeric interval is still consumed as one"

  err=$(FM_NM_FLOW_WATCH_MAX=1 run_flow "$d" --watch 5s "$rid" 2>&1 >/dev/null) || rc=$?
  expect_code 2 "$rc" "a unit-suffixed interval is a usage error"
  assert_contains "$err" "interval must be a whole number of seconds" \
    "the mistyped interval is named, not left to a bare usage block"
  assert_contains "$err" "5s" "the offending argument is quoted back"
  pass "--watch accepts a task id or an interval in either order"
}

# (w) nothing verified must never read as a green.
test_ci_no_checks_banner() {
  reset_fakes
  local d out
  d=$(new_case ci-no-checks)
  make_repo_on_branch "$d/wt" fm/feat-nochecks
  make_fakebin "$d" >/dev/null
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-nochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "CI: no checks reported - nothing verified" \
    "a no-checks marker gets its own banner"
  assert_not_contains "$out" "CI GREEN" \
    "a no-checks marker never renders as a CI green"
  assert_contains "$out" ">> [ merge gate  det     ]" \
    "the run is still on its way to the merge gate"
  pass "no CI checks reported is not rendered as CI GREEN"
}

# (x) a parked run whose gate nothing names must say exactly that, and must not
# report a findings breakdown it never read.
test_parked_unnamed_gate() {
  reset_fakes
  local d out
  d=$(new_case parked-unnamed)
  make_repo_on_branch "$d/wt" fm/feat-unnamed
  make_fakebin "$d" >/dev/null

  FM_FAKE_AXI_STATUS="$(run_parked_unnamed fm/feat-unnamed)"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "PARKED at an unnamed gate: findings not readable from status" \
    "an unresolvable gate name is stated, not invented"
  assert_not_contains "$out" "PARKED at gate gate" "no literal gate-named-gate banner"
  assert_not_contains "$out" "0 findings" "unknown counts are never reported as zeros"
  assert_contains "$out" ">> [ review      LLM     ]" \
    "the diagram keeps the highlight the steps table supports"

  # The same state with findings the answer DOES report: then the breakdown is
  # a fact and is printed.
  FM_FAKE_AXI_STATUS="$(run_parked_unnamed fm/feat-unnamed 'findings: none')"
  out=$(run_flow "$d" --worktree "$d/wt")
  assert_contains "$out" "PARKED at an unnamed gate: 0 findings (0 ask-user, 0 auto-fix, 0 no-op)" \
    "an explicit findings:none is a fact worth printing"
  pass "an unnamed parked gate is honest about both the gate and the counts"
}

# (z) an identifier the captain has already excused by a supersession entry is
# its OWN category in the merge-gate row: never folded into passing, failing or
# unexecuted, never silently dropped, and never a green. The viewer classifies
# for display only - bin/fm-pr-merge.sh remains the sole authority on whether a
# merge proceeds - so it applies the gate's two policy layers in the gate's own
# order, which is what keeps "excused" meaning "a captain-approved entry covers
# this" and not "this project does not gate that class".
test_tests_gate_excused_by_supersession() {
  reset_fakes
  local d out row line width
  d=$(new_case tests-gate-excused)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests" "$d/data/supersessions" "$d/data/exec-gate"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
pass "beta"
SH
  chmod +x "$d/wt/tests/demo.test.sh"
  # Enumerated by name (check 1) but never executable by check 2 on any host
  # (no pytest config marker, no worktree-local interpreter), so its identifier
  # is reported `unexecuted:` - the class the exec-gate marker governs.
  cat > "$d/wt/tests/test_demo.py" <<'PY'
def test_alpha():
    assert True
PY
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
  fm_write_meta "$d/state/ss-task.meta" \
    "window=firstmate:fm-ss-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"

  # No record at all: the dropped assertion is a plain missing finding. The
  # project IS known, so the record was genuinely consulted and found absent -
  # an established zero, not a dash.
  out=$(FM_HOME="$d" run_flow "$d" ss-task --tests-gate)
  assert_contains "$out" "miss 1/fail 0/unex 1/excu 0/skip 0/unac 0 !!" \
    "with no record the finding is missing and every other class is still named"
  assert_contains "$out" "prior-tests: excu=captain-excused" \
    "the excused label is explained whenever it appears, not only when non-zero"

  cat > "$d/data/supersessions/demo.md" <<'MD'
- ids: tests/demo.test.sh::* | project: demo | kind: missing | date: 2026-08-03 | reason: beta is deliberately superseded
- ids: tests/test_demo.py::* | project: demo | kind: unexecuted | date: 2026-08-03 | reason: python assertions cannot run here
MD

  # Exec-gate marker absent: the unexecuted identifier is not matched against
  # the record at all, so it stays in the not-run count. Only the missing one
  # moves out of its class, and it moves into a category of its own.
  out=$(FM_HOME="$d" run_flow "$d" ss-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 1/excu 1/skip 0/unac 0" \
    "an excused identifier is counted and labelled on its own"
  assert_not_contains "$out" "miss 1" "an excused identifier is not left in missing"
  assert_not_contains "$out" "fail 1" "an excused identifier is not folded into failing"
  assert_not_contains "$out" "unex 2" "an excused identifier is not folded into unexecuted"
  assert_not_contains "$out" " ok" "an excused identifier never produces a green"
  assert_contains "$out" "prior-tests: excu=captain-excused, not a pass" \
    "the excused category is spelled out under the diagram"
  assert_contains "$out" "prior-tests: base main: LOCAL, never fetched" \
    "the excused row still names the base it compared against"
  while IFS= read -r line; do
    line=$(strip_sgr "$line")
    width=${#line}
    [ "$width" -le 80 ] || fail "excused frame line is $width columns: $line"
  done <<< "$out"

  # Marker present: the project gates the unexecuted class, so its entry now
  # applies too and that identifier joins the excused count rather than
  # disappearing from the row.
  : > "$d/data/exec-gate/demo"
  out=$(FM_HOME="$d" run_flow "$d" ss-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 2/skip 0/unac 0" \
    "the exec-gate marker moves the unexecuted finding into the excused count"
  assert_not_contains "$out" " ok" "two excused identifiers are still not a green"
  row=$(printf '%s\n' "$out" | grep 'excu 2' | head -1)
  row=$(strip_sgr "$row")
  width=${#row}
  [ "$width" -le 80 ] || fail "merge-gate row is $width columns: $row"

  # A malformed entry (no reason field) fails closed exactly as the gate's own
  # parser does: nothing is excused, and the finding is back in its raw class.
  printf -- '- ids: tests/demo.test.sh::* | project: demo | kind: missing | date: 2026-08-03\n' \
    > "$d/data/supersessions/demo.md"
  rm -f "$d/data/exec-gate/demo"
  out=$(FM_HOME="$d" run_flow "$d" ss-task --tests-gate)
  assert_contains "$out" "miss 1/fail 0/unex 1/excu 0/skip 0/unac 0 !!" \
    "a malformed entry excuses nothing"
  assert_not_contains "$out" "excu 1" "a malformed entry never counts anything excused"
  pass "excused identifiers are their own category, never folded and never green"
}

# Whenever the merge-gate box shows a result it names all SIX classes the check
# reports, zeros included: no ordering, threshold or non-zero test may hide one
# behind another, because a captain reading a live pane cannot tell a hidden
# count from a class that had nothing to report. `ok` is derived from those six
# cells and NEVER from the check's exit status - the check exits 0 whenever
# missing/failing/unexecuted are empty, which says nothing about the skipped and
# unaccounted identifiers it also reports, and an unaccounted identifier is one a
# green baseline run produced no result for at all. A class this run never
# evaluated renders as a dash, distinct from an established 0, and suppresses ok
# on its own. The counts themselves are never truncated and never omitted: when
# six of them plus a flag will not fit an 80-column row it is the
# `prior-tests: ` prefix that gives way, and every legend line under the diagram
# carries that prefix anyway.
test_tests_gate_six_counts_always() {
  reset_fakes
  local d out row width
  d=$(new_case tests-gate-six-counts)
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/wt/tests" "$d/data/supersessions"
  git -C "$d/wt" init -q
  cat > "$d/wt/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "alpha"
SH
  chmod +x "$d/wt/tests/demo.test.sh"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm base
  git -C "$d/wt" branch -M main
  git -C "$d/wt" checkout -qb fm/change
  printf 'note\n' > "$d/wt/README.md"
  git -C "$d/wt" add -A
  git -C "$d/wt" commit -qm "unrelated change"
  fm_write_meta "$d/state/six-task.meta" \
    "window=firstmate:fm-six-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo"
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"

  # Nothing wrong anywhere AND every class established: the all-zero row still
  # names all six, and this is the ONE shape allowed to carry an ok.
  out=$(FM_HOME="$d" run_flow "$d" six-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip 0/unac 0 ok" \
    "a clean result names all six classes, zeros included"
  assert_contains "$out" "prior-tests: excu=captain-excused" \
    "the class legend shows even when every count is zero"
  assert_contains "$out" "-=unchecked" \
    "the dash is explained whenever the labels are up, not only when one shows"

  # The same worktree read in explicit --worktree mode knows no project, so the
  # supersession record is never consulted: excused is NOT-EVALUATED, which
  # renders as a dash and takes the green with it.
  out=$(run_flow "$d" --worktree "$d/wt" --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu -/skip 0/unac 0" \
    "an unevaluated class renders as a dash, not as a zero"
  assert_not_contains "$out" "excu 0" "never-evaluated is never rendered as a count of 0"
  assert_not_contains "$out" " ok" "an unevaluated class suppresses the green"
  assert_contains "$out" "-=unchecked" \
    "the dash is explained under the diagram"

  mkdir -p "$d/bin"
  cp "$NM_FLOW" "$d/bin/fm-nm-flow.sh"
  cp "$ROOT/bin/fm-supersession-lib.sh" "$d/bin/fm-supersession-lib.sh"
  chmod +x "$d/bin/fm-nm-flow.sh"

  # The check exits 0 - missing/failing/unexecuted are all empty - while
  # reporting a skipped and an unaccounted identifier. Neither affects that exit
  # status, and both mean a base assertion nothing verified, so the row must
  # carry them and must NOT go out green.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "skipped: tests/demo.test.sh::alpha"
echo "unaccounted: tests/demo.test.sh::beta"
echo "summary: missing=0 failing=0 unexecuted=0 skipped=1 unaccounted=1"
exit 0
SH
  chmod +x "$d/bin/fm-assert-tests-kept.sh"
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip 1/unac 1" \
    "skipped and unaccounted are read and named even though exit 0 ignores them"
  assert_not_contains "$out" " ok" \
    "a clean exit status is never a green over a skipped or unaccounted assertion"

  # Only skipped, still exit 0: the green is suppressed by that class alone.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "skipped: tests/demo.test.sh::alpha"
echo "summary: missing=0 failing=0 unexecuted=0 skipped=1 unaccounted=0"
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip 1/unac 0" \
    "a lone skipped identifier is still named"
  assert_not_contains "$out" " ok" "a lone skipped identifier suppresses the green"

  # Only unaccounted, still exit 0: same, on its own.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "unaccounted: tests/demo.test.sh::beta"
echo "summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=1"
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip 0/unac 1" \
    "a lone unaccounted identifier is still named"
  assert_not_contains "$out" " ok" "a lone unaccounted identifier suppresses the green"

  # Version skew: a check whose summary line has no concept of skipped or
  # unaccounted at all. Counting the finding lines it never emits would
  # manufacture a zero out of their absence and hand back a green asserting two
  # classes nothing evaluated, so both render as dashes and the green is gone.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "summary: missing=0 failing=0 unexecuted=0"
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip -/unac -" \
    "a class the summary never reported renders as a dash, never as a zero"
  assert_not_contains "$out" "skip 0" "an unreported class is not given a zero"
  assert_not_contains "$out" " ok" \
    "a class nothing evaluated suppresses the green even at exit 0"

  # The same skew, but the check DID emit a finding line for the class it left
  # out of the summary. A finding line is positive evidence and is believed;
  # only its absence proves nothing.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "skipped: tests/demo.test.sh::alpha"
echo "summary: missing=0 failing=0 unexecuted=0"
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip 1/unac -" \
    "a finding line is believed even when the summary omits its class"

  # No summary line at all: every class is read the same way, off the finding
  # lines, so a zero there is a real reading of the whole output.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "missing: tests/demo.test.sh::beta"
exit 1
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 1/fail 0/unex 0/excu 0/skip 0/unac 0 !!" \
    "with a populated output and no summary line the zeros are a real reading"

  # ...but only because there was output to read. Output with no content at all
  # is not a reading of anything: every class greps to 0 and the row would go
  # out as six established zeros with a green derived from no positive evidence
  # whatever, which is a check that never ran wearing the face of a clean one.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss -/fail -/unex -/excu 0/skip -/unac -" \
    "empty output is not a reading: every class the output would speak to is a dash"
  assert_not_contains "$out" "miss 0" "an empty output never manufactures a zero"
  assert_not_contains "$out" " ok" "an empty output never produces a green"

  # Whitespace is not content either - the same nothing with a newline in it.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
printf '\n\n'
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss -/fail -/unex -/excu 0/skip -/unac -" \
    "blank lines are not a reading either"
  assert_not_contains "$out" " ok" "blank output never produces a green"

  # Neither is output the CHECK ITSELF did not write. fm-assert-tests-kept.sh
  # runs bin/fm-guard.sh unredirected, so the guard's WORKTREE TANGLE / WATCHER
  # DOWN banners land on the probe's stdout. A viewer asking only "was there any
  # output" would take that foreign noise as licence to grep all six classes to
  # zero and hand back the exact manufactured green the empty-output dash exists
  # to refuse. The viewer recognises its own contract instead.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "●------------------------------------------------------------"
echo "●  WATCHER DOWN - SUPERVISION IS OFF"
echo "●  1 task(s) in flight, but no watcher has a fresh beacon."
echo "●------------------------------------------------------------"
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss -/fail -/unex -/excu 0/skip -/unac -" \
    "another script's banner on the probe's stdout is not a reading of any class"
  assert_not_contains "$out" "miss 0" "guard noise never manufactures a zero"
  assert_not_contains "$out" " ok" "guard noise never produces a green"

  # The same banner alongside a line the check really did write: the contract
  # line is positive evidence and is believed, banner and all.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "●  WATCHER DOWN - SUPERVISION IS OFF"
echo "missing: tests/demo.test.sh::beta"
exit 1
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 1/fail 0/unex 0/excu 0/skip 0/unac 0 !!" \
    "a contract line is read even when foreign output shares the stream"

  # And a genuine all-clear reading keeps its established zeros and its green:
  # the tightened test rejects foreign output, not the check's own summary.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "●  WATCHER DOWN - SUPERVISION IS OFF"
echo "summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0"
exit 0
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 0/fail 0/unex 0/excu 0/skip 0/unac 0 ok" \
    "a real all-clear reading still renders six established zeros and the green"

  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "missing: tests/demo.test.sh::beta"
exit 1
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss 1/fail 0/unex 0/excu 0/skip 0/unac 0 !!" \
    "with no summary line every class is read off the finding lines alike"

  # A magnitude a whole-directory rewrite really can produce. The counts are
  # reported verbatim and the prefix is what is spent to fit the pane.
  cat > "$d/bin/fm-assert-tests-kept.sh" <<'SH'
#!/usr/bin/env bash
echo "summary: missing=300 failing=250 unexecuted=120 skipped=110 unaccounted=100"
exit 1
SH
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$d/bin/fm-nm-flow.sh" six-task --tests-gate)
  assert_contains "$out" "miss300/fail250/unex120/excu0/skip110/unac100 !!" \
    "three-digit counts are reported whole, never truncated"
  assert_not_contains "$out" "prior-tests: miss300" \
    "the prefix is what gives way to the counts, not the other way round"
  row=$(printf '%s\n' "$out" | grep 'miss300' | head -1)
  row=$(strip_sgr "$row")
  width=${#row}
  [ "$width" -le 80 ] || fail "wide-count merge-gate row is $width columns: $row"
  pass "the merge-gate row always carries all six counts, whole and inside 80 columns"
}

# The tests-gate probe must not write fleet state. fm-assert-tests-kept.sh calls
# bin/fm-guard.sh unconditionally, and the guard in write mode claims the
# one-per-episode WATCHER DOWN banner under state/ - both a write this viewer
# promises never to make, and an alarm the next genuinely guarded command would
# then never see in full.
test_tests_gate_leaves_guard_state_alone() {
  reset_fakes
  local d out before after
  d=$(new_case tests-gate-guard)
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
  # A task in flight with no watcher beacon is exactly the state the guard
  # writes for, so this fixture is only meaningful if the guard really would
  # write here: prove it by running the guard as any ordinary caller does,
  # then clear what it left before the viewer runs.
  fm_write_meta "$d/state/guard-task.meta" \
    "window=firstmate:fm-guard-task" \
    "worktree=$d/wt" \
    "project=$d/projects/demo"
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$ROOT/bin/fm-guard.sh" >/dev/null 2>&1 || true
  [ -e "$d/state/.guard-watcher-stale-banner" ] || \
    fail "fixture does not reproduce the guard's write path"
  rm -f "$d/state/.guard-watcher-stale-banner" "$d/state/.guard-watcher-stale-banner.lock"

  before=$(find "$d/state" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | sort)
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(FM_HOME="$d" run_flow "$d" guard-task --tests-gate)
  assert_contains "$out" "miss 1/fail 0/unex 0/excu 0/skip 0/unac 0 !!" \
    "the probe really ran, so the read-only claim is not vacuous"
  [ ! -e "$d/state/.guard-watcher-stale-banner" ] || \
    fail "the tests-gate probe claimed the watcher-down banner episode"
  [ ! -e "$d/state/.guard-watcher-stale-banner.lock" ] || \
    fail "the tests-gate probe left the guard's lock behind"
  after=$(find "$d/state" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | sort)
  [ "$before" = "$after" ] || fail "the tests-gate probe changed state/: $before -> $after"

  # A fresh FM_HOME, explicit --worktree mode: the residual write read-only mode
  # does not reach is bin/fm-wake-lib.sh's source-time `mkdir -p "$STATE"`, so
  # the probe must carry a STATE pointed at its own scratch dir. Nothing outside
  # that dir may appear, not even an empty state/.
  local fresh="$d/fresh-home"
  mkdir -p "$fresh"
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$fresh" "$NM_FLOW" --worktree "$d/wt" --tests-gate)
  assert_contains "$out" "miss 1/fail 0/unex 0/excu -/skip 0/unac 0 !!" \
    "the fresh-home probe really ran too"
  [ ! -e "$fresh/state" ] || fail "--tests-gate created state/ under a fresh FM_HOME"
  [ -z "$(find "$fresh" -mindepth 1)" ] || \
    fail "--tests-gate wrote under a fresh FM_HOME: $(find "$fresh" -mindepth 1)"
  pass "the tests-gate probe writes no guard state and creates no state dir"
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
test_tests_gate_uses_the_pr_base
test_tests_gate_pr_base_unreadable_degrades
test_watch_mode_frames
test_help_exits_zero
test_tests_gate_name_check_only
test_tests_gate_long_base_and_wide_counts
test_tests_gate_probe_timeout
test_ci_red_banner
test_step_kinds_from_config
test_tests_gate_first_frame
test_worktree_removed_mid_watch
test_header_width_bounded
test_header_keeps_task_id
test_perl_bounding_arm_reports_signals
test_tests_gate_signal_killed_probe
test_frame_height_bounded
test_wrapping_pr_row_budget
test_frame_row_budget_all_states
test_tests_gate_tmpdir_cleanup_on_interrupt
test_tests_gate_interrupt_not_deferred_on_timeout_arm
test_watch_argument_shapes
test_ci_no_checks_banner
test_parked_unnamed_gate
test_tests_gate_excused_by_supersession
test_tests_gate_six_counts_always
test_tests_gate_leaves_guard_state_alone

echo "all fm-nm-flow tests passed"
