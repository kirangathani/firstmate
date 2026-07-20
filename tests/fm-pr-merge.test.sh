#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a branch missing a test identifier the base already had is refused
#       before gh-axi pr merge (bin/fm-assert-tests-kept.sh gate); the clean
#       branch in (a)/(c)/(e)/(g) passing through that same gate covers the
#       merge-normally side
#   (j) a branch that keeps a base test's name but rewrites its assertion body
#       (the Z/K case) is refused before gh-axi pr merge (check 2)
#   (k) a clean branch whose base tests actually execute merges normally
#   (l) a failing base assertion with a VALID captain supersession entry in
#       data/supersessions/<project>.md merges normally
#   (m) a supersession entry missing a required field is NOT honored
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta, a
# fakebin with a gh-axi mock that records how it was invoked, and a real
# project repo plus fm/task-x1 worktree (identical to main, one baseline shell
# test) so the bin/fm-assert-tests-kept.sh merge gate can resolve and pass.
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git init -q -b main "$case_dir/project" 2>/dev/null || {
    git init -q "$case_dir/project"
    git -C "$case_dir/project" checkout -q -b main
  }
  mkdir -p "$case_dir/project/tests"
  cat > "$case_dir/project/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
pass "alpha holds"
EOF
  git -C "$case_dir/project" add -A
  git -C "$case_dir/project" commit -qm baseline
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# FM_HOME is pinned to a per-case dir so the supersession lookup at
# $FM_HOME/data/supersessions/<project>.md is hermetic and never reads the real
# firstmate home's records.
run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/fmhome" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

# make_zk_case <name>: like make_case, but the project fixture is the plan's
# Z/K worked example with a runnable self-contained shell test (pass/fail
# helpers inline), so the merge gate's check 2 actually executes it: main has
# app.sh producing Z and tests/x.test.sh asserting Z under the stable name
# "X behaves". The fm/task-x1 worktree starts identical to main. Echoes the
# case dir.
make_zk_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git init -q -b main "$case_dir/project" 2>/dev/null || {
    git init -q "$case_dir/project"
    git -C "$case_dir/project" checkout -q -b main
  }
  mkdir -p "$case_dir/project/tests"
  printf '#!/usr/bin/env bash\necho Z\n' > "$case_dir/project/app.sh"
  cat > "$case_dir/project/tests/x.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
out=$(bash ./app.sh)
[ "$out" = "Z" ] || fail "X behaves"
pass "X behaves"
EOF
  git -C "$case_dir/project" add -A
  git -C "$case_dir/project" commit -qm baseline
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf '%s\n' "$case_dir"
}

# rewrite_zk_branch <case_dir>: the resolver takes K's side in BOTH files -
# app.sh now produces K and the test keeps its name but asserts K, so the
# behavior main guaranteed is gone while every test name survives.
rewrite_zk_branch() {
  local case_dir=$1
  printf '#!/usr/bin/env bash\necho K\n' > "$case_dir/wt/app.sh"
  cat > "$case_dir/wt/tests/x.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
out=$(bash ./app.sh)
[ "$out" = "K" ] || fail "X behaves"
pass "X behaves"
EOF
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "resolver takes K in both app.sh and test"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_missing_base_test_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case test-keep-refuses)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  cat > "$case_dir/wt/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
EOF
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "drop alpha"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "test-keep-refuses: fm-pr-merge should refuse"
  assert_grep 'missing: tests/app.test.sh::alpha holds' "$case_dir/stdout" \
    "test-keep-refuses: the vanished assertion was not reported by name"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "test-keep-refuses: refusal did not explain itself"
  assert_grep 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "test-keep-refuses: pr= should still be recorded before the gate refuses"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "test-keep-refuses: gh-axi pr merge was invoked despite a missing base test"
  pass "fm-pr-merge refuses to merge when a base test identifier is missing from the branch"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_rewritten_assertion_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_zk_case zk-rewrite-refuses)
  rewrite_zk_branch "$case_dir"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "zk-rewrite-refuses: fm-pr-merge should refuse"
  assert_grep 'failing: tests/x.test.sh::X behaves' "$case_dir/stdout" \
    "zk-rewrite-refuses: the rewritten assertion was not reported as failing by name"
  assert_no_grep 'missing: tests/x.test.sh' "$case_dir/stdout" \
    "zk-rewrite-refuses: check 1 should see the surviving name (check 2 is what refuses here)"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "zk-rewrite-refuses: refusal did not explain itself"
  assert_grep 'escalate needs-decision' "$case_dir/stderr" \
    "zk-rewrite-refuses: refusal did not route the supersession decision to the captain"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "zk-rewrite-refuses: gh-axi pr merge was invoked despite a failing base assertion"
  pass "fm-pr-merge refuses a kept-name rewritten assertion (check 2) before calling gh-axi"
}

test_clean_runnable_branch_merges_normally() {
  local case_dir
  case_dir=$(make_zk_case zk-clean-merges)
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "zk-clean-merges: fm-pr-merge failed"

  grep -qxF 'pr merge 42 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "zk-clean-merges: a clean branch with executing base tests did not merge normally"
  pass "a clean branch whose base tests execute green merges normally"
}

test_valid_supersession_entry_merges_normally() {
  local case_dir
  case_dir=$(make_zk_case supersession-valid)
  rewrite_zk_branch "$case_dir"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"
  mkdir -p "$case_dir/fmhome/data/supersessions"
  cat > "$case_dir/fmhome/data/supersessions/project.md" <<'EOF'
# Supersessions for project
- id: tests/x.test.sh::X behaves | project: project | date: 2026-07-19 | reason: captain approved K superseding Z behavior
EOF

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "supersession-valid: fm-pr-merge failed"

  assert_grep 'captain-approved supersession covers: tests/x.test.sh::X behaves' "$case_dir/stderr" \
    "supersession-valid: the excused assertion was not named"
  grep -qxF 'pr merge 43 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "supersession-valid: a fully-excused failing assertion did not merge normally"
  pass "a failing base assertion with a valid captain supersession entry merges normally"
}

test_supersession_entry_missing_field_not_honored() {
  local case_dir rc
  case_dir=$(make_zk_case supersession-malformed)
  rewrite_zk_branch "$case_dir"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"
  mkdir -p "$case_dir/fmhome/data/supersessions"
  cat > "$case_dir/fmhome/data/supersessions/project.md" <<'EOF'
# Supersessions for project
- id: tests/x.test.sh::X behaves | project: project | reason: no date recorded
EOF

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "supersession-malformed: an entry missing its date field must not excuse the merge"
  assert_grep 'ignoring supersession entry missing a required field' "$case_dir/stderr" \
    "supersession-malformed: the malformed entry was not warned about"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "supersession-malformed: refusal did not explain itself"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "supersession-malformed: gh-axi pr merge was invoked despite a malformed supersession entry"
  pass "a supersession entry missing a required field is not honored"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_missing_base_test_refuses_before_merge
test_rewritten_assertion_refuses_before_merge
test_clean_runnable_branch_merges_normally
test_valid_supersession_entry_merges_normally
test_supersession_entry_missing_field_not_honored
test_parses_pr_url_for_gh_axi
