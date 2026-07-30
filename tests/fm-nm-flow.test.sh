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
#   (m) a name-check-only base file is reported on its own legend line instead
#       of reading as a clean verified pass, and the merge-gate row stays
#       inside 80 columns; an origin/-prefixed base with two-digit counts keeps
#       every rendered line inside 80 columns with the base ref named whole,
#       and an over-running probe degrades to pending rather than hanging
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
#   (t) a frame is bounded to the row budget the way it is bounded to columns:
#       the 24-line worst case fits a plain pane whole, a smaller budget drops
#       only legend lines and says how many, and the header always survives
#   (u) the probe's scratch dir is removed even when a watch frame is interrupted
#   (v) --watch takes a task id or a numeric interval in either order, and names
#       a unit-suffixed interval as the mistyped interval it is
#   (w) a no-CI-checks marker gets its own banner, never CI GREEN
#   (x) a parked run with no resolvable gate name says so, and never invents a
#       findings breakdown it could not read
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
  printf '%s\n' "$fb"
}

reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_RM_WT=""
  export FM_FAKE_AXI_STATUS FM_FAKE_RUNS_LIST FM_FAKE_CI_LOGS FM_FAKE_RM_WT
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
  assert_contains "$out" "prior-tests: missing 1 / failing 0 !!" \
    "merge-gate box shows the missing count"
  assert_contains "$out" "prior-tests: compared against base main" \
    "the compared base is named in full on its own legend line"
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
  # A python test file is enumerated by name but never executed by check 2, so
  # the run is a name-only verification for that file while still exiting 0.
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
  assert_contains "$out" "prior-tests: missing 0 / failing 0 ok" \
    "merge-gate box keeps its own annotation"
  assert_contains "$out" "prior-tests: compared against base main" \
    "the compared base is named in full on its own legend line"
  assert_contains "$out" "prior-tests: 1 base file verified by name only, not by assertion" \
    "the name-only file count is reported on its own legend line"
  local row width
  row=$(printf '%s\n' "$out" | grep 'missing 0 / failing 0' | head -1)
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
  assert_contains "$out" "prior-tests: missing 12 / failing 10 !!" \
    "two-digit missing and failing counts both land in the box row"
  base_line=$(printf '%s\n' "$out" | grep 'compared against base' | head -1)
  assert_contains "$base_line" "prior-tests: compared against base origin/master" \
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
  assert_not_contains "$out" "failing 0 ok" "a timed-out probe never renders a green result"
  assert_not_contains "$out" "compared against base" \
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
  FM_FAKE_AXI_STATUS="runs: 0 runs yet in this repository"
  out=$(FM_NM_FLOW_WATCH_MAX=2 run_flow "$d" --worktree "$d/wt" --tests-gate --watch 1)
  first=$(printf '%s\n' "$out" | sed -n '1,/^$/p')
  assert_contains "$first" "prior-tests: checking..." "frame 1 renders before the probe runs"
  assert_not_contains "$first" "compared against base" \
    "frame 1 claims no comparison before the probe has run"
  assert_contains "$out" "prior-tests: missing 1 / failing 0 !!" \
    "frame 2 carries the computed result"
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
# merge-gate verdict, so an rc that swallowed the signal renders "missing 0 /
# failing 0 ok" over a suite that never ran.
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
  pass "the perl bounding arm reports 128+signal like timeout does"
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
  assert_not_contains "$out" "failing 0 ok" \
    "a signal-killed probe never renders a green result"
  assert_not_contains "$out" "compared against base" \
    "a signal-killed probe claims no comparison"
  assert_not_contains "$out" "verified by name only" \
    "a signal-killed probe carries no stale name-only count"
  pass "a signal-killed probe renders pending, never a false green"
}

# (t) the frame is bounded to the pane's rows the way it is bounded to columns.
# The worst case is the ordinary one: every conditional line present at once -
# the PR line, the compared base, the name-only count and the det|LLM legend.
test_frame_height_bounded() {
  reset_fakes
  local d out lines hdr box
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

  out=$(run_flow "$d" height-task --tests-gate)
  assert_contains "$out" "PR: https://github.com/o/r/pull/7" "the PR line is present"
  assert_contains "$out" "prior-tests: compared against base main" "the base legend is present"
  assert_contains "$out" "verified by name only" "the name-only legend is present"
  assert_contains "$out" "det|LLM: commands.<step>" "the det|LLM legend is present"
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" = 24 ] || fail "the worst-case frame is $lines lines, expected the 24-line case"
  assert_not_contains "$out" "legend line" "nothing is dropped inside a 24-row budget"
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  assert_contains "$hdr" "height-task" "the header survives at the default budget"

  # A genuinely smaller pane: only legend lines go, the drop is stated, and the
  # run-specific base claim outlives the fixed explanatory legends.
  out=$(FM_NM_FLOW_ROWS=20 run_flow "$d" height-task --tests-gate)
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" -le 20 ] || fail "frame is $lines lines against a 20-row budget"
  assert_contains "$out" "legend lines dropped to fit a 20-row pane" "the drop is stated explicitly"
  hdr=$(strip_sgr "$(printf '%s\n' "$out" | head -1)")
  assert_contains "$hdr" "height-task" "the header is never dropped"
  assert_contains "$out" "IDLE: no run for branch" "the banner is never dropped"
  for box in intent rebase review test document lint push "open PR" "CI monitor" "merge gate" captain teardown; do
    assert_contains "$out" "[ $box" "step row $box is never dropped"
  done
  assert_contains "$out" "prior-tests: compared against base main" \
    "the base claim outranks the fixed legends"
  assert_not_contains "$out" "outcomes: checks-passed" "the lowest-value legend goes first"

  # A bogus override falls back to the same hard 24-row default.
  out=$(FM_NM_FLOW_ROWS=not-a-number run_flow "$d" height-task --tests-gate)
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" = 24 ] || fail "a non-numeric row override did not fall back to 24: $lines lines"
  assert_not_contains "$out" "legend line" "the fallback budget drops nothing"
  pass "frame height is bounded without losing the header, banner or a step row"
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
  # so an INT here would be a no-op. Both land on the same handler, and the
  # signal is delivered while the probe holds the foreground - so the handler
  # runs the moment the probe returns, ahead of its own cleanup line.
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  leftover=$(find "$d/tmp" -maxdepth 1 -name 'fm-nm-flow.*' 2>/dev/null | head -1)
  [ -z "$leftover" ] || fail "an interrupted probe leaked its scratch dir: $leftover"
  pass "the probe's scratch dir is removed even when the frame is interrupted"
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
test_tests_gate_tmpdir_cleanup_on_interrupt
test_watch_argument_shapes
test_ci_no_checks_banner
test_parked_unnamed_gate

echo "all fm-nm-flow tests passed"
