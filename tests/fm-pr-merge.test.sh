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
#
# Three-class finding consumption and the batch supersession format are driven
# off a CONSTRUCTED fm-assert-tests-kept.sh stdout + exit code (make_stub_case),
# because the unexecuted: class comes from detector-side execution work that
# lands separately; see that helper's comment for the shim mechanics.
#   (n) an unexecuted finding with no per-project exec-gate marker is
#       informational and merges (today's warn-only behavior)
#   (o) the same unexecuted finding with the marker present refuses
#   (p) missing/failing refuse whether or not the marker is present
#   (p2) an EXCUSED missing finding alongside a gated unexecuted one still
#       refuses: the decision comes from all three classes' counts, never from a
#       single-class path (the leak this series closes)
#   (q) a legacy single-id entry excuses exactly its own identifier, no more
#   (r) an ids: glob batch excuses every matching identifier
#   (s) an ids: glob batch does not excuse a non-matching identifier
#   (t) kind: restricts a batch, so an `ids: * | kind: unexecuted` entry can
#       never excuse a missing finding
#   (u) `ids: *` with NO kind excuses every class (documented back-compat)
#   (v) an invalid kind, or any field written after reason, is warned and
#       ignored, never silently treated as kind: any
#   (w) an entry carrying neither id: nor ids: is warned and ignored
#   (x) exit 1 with no parseable finding line refuses as unverified
#   (y) exit 2 still refuses as unverifiable
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
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/fmhome" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
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
  assert_grep 'no meta for task missing-x1' "$case_dir/stderr" \
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

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
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
  assert_grep 'must not override --repo parsed from PR URL' "$case_dir/stderr" \
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

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126/ \
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

### three-class finding consumption and batch supersessions ##################
#
# make_stub_case <name> <detector-exit> [<finding line>...]: a case whose merge
# gate reads a CONSTRUCTED fm-assert-tests-kept.sh result instead of the real
# detector. A shim bin/ holds symlinks to the REAL fm-pr-merge.sh and
# fm-pr-check.sh, so the code under test is the real code resolved through its
# own SCRIPT_DIR, next to a stub detector that prints the given finding lines and
# exits with the given code. This is how the unexecuted: class is exercised
# before the detector that emits it exists, and it also lets a single case mix
# finding classes that no one fixture could produce together. Echoes the case dir.
make_stub_case() {
  local name=$1 exit_code=$2
  shift 2
  local case_dir fakebin shimbin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  shimbin="$case_dir/shimbin"
  mkdir -p "$case_dir/state" "$fakebin" "$shimbin" "$case_dir/project"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  ln -s "$PR_MERGE" "$shimbin/fm-pr-merge.sh"
  ln -s "$ROOT/bin/fm-pr-check.sh" "$shimbin/fm-pr-check.sh"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$case_dir/kept-findings"
  else
    : > "$case_dir/kept-findings"
  fi
  cat > "$shimbin/fm-assert-tests-kept.sh" <<SH
#!/usr/bin/env bash
cat "$case_dir/kept-findings"
exit $exit_code
SH
  chmod +x "$shimbin/fm-assert-tests-kept.sh"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

# Same environment as run_pr_merge, but invoking the shimmed fm-pr-merge.sh so
# the stub detector is the sibling it resolves.
run_pr_merge_stub() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/fmhome" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/shimbin/fm-pr-merge.sh" "$@"
}

# enable_exec_gate <case_dir>: create the per-project marker that makes
# unexecuted findings block for this case's project.
enable_exec_gate() {
  local case_dir=$1
  mkdir -p "$case_dir/fmhome/data/exec-gate"
  touch "$case_dir/fmhome/data/exec-gate/project"
}

# write_supersessions <case_dir> <entry line>...
write_supersessions() {
  local case_dir=$1
  shift
  mkdir -p "$case_dir/fmhome/data/supersessions"
  {
    printf '%s\n' "# Supersessions for project"
    printf '%s\n' "$@"
  } > "$case_dir/fmhome/data/supersessions/project.md"
}

test_unexecuted_without_marker_is_informational_and_merges() {
  local case_dir
  case_dir=$(make_stub_case unexecuted-no-marker 1 'unexecuted: tests/x.test.sh::X behaves')

  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unexecuted-no-marker: an ungated unexecuted finding must not block the merge"

  assert_grep 'note: unexecuted (not gated for project): tests/x.test.sh::X behaves' "$case_dir/stderr" \
    "unexecuted-no-marker: the ungated finding was not reported as informational"
  assert_no_grep 'refusing to merge' "$case_dir/stderr" \
    "unexecuted-no-marker: an ungated unexecuted finding caused a refusal"
  grep -qxF 'pr merge 51 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "unexecuted-no-marker: the merge did not proceed"
  pass "an unexecuted finding is informational and non-blocking when the project has no exec-gate marker"
}

test_unexecuted_with_marker_refuses() {
  local case_dir rc
  case_dir=$(make_stub_case unexecuted-marker 1 'unexecuted: tests/x.test.sh::X behaves')
  enable_exec_gate "$case_dir"

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unexecuted-marker: a gated unexecuted finding must refuse the merge"
  assert_grep 'no captain-approved supersession entry covers: tests/x.test.sh::X behaves (unexecuted)' "$case_dir/stderr" \
    "unexecuted-marker: the gated finding was not named as uncovered"
  assert_grep 'unverified rather than proven broken' "$case_dir/stderr" \
    "unexecuted-marker: the refusal did not explain what unexecuted means"
  assert_no_grep 'not gated for project' "$case_dir/stderr" \
    "unexecuted-marker: the finding was still treated as informational"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unexecuted-marker: gh-axi pr merge was invoked despite a gated unexecuted finding"
  pass "an unexecuted finding refuses the merge once the project's exec-gate marker exists"
}

test_missing_and_failing_refuse_regardless_of_marker() {
  local case_dir rc marker
  for marker in absent present; do
    case_dir=$(make_stub_case "classes-refuse-marker-$marker" 1 \
      'missing: tests/a.test.sh::alpha holds' \
      'failing: tests/b.test.sh::beta holds')
    [ "$marker" = present ] && enable_exec_gate "$case_dir"

    set +e
    run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "classes-refuse-marker-$marker: missing/failing must refuse"
    assert_grep 'covers: tests/a.test.sh::alpha holds (missing)' "$case_dir/stderr" \
      "classes-refuse-marker-$marker: the missing finding was not named"
    assert_grep 'covers: tests/b.test.sh::beta holds (failing)' "$case_dir/stderr" \
      "classes-refuse-marker-$marker: the failing finding was not named"
    assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
      "classes-refuse-marker-$marker: gh-axi pr merge was invoked despite missing/failing findings"
  done
  pass "missing and failing findings refuse the merge whether or not the exec-gate marker exists"
}

test_excused_missing_plus_gated_unexecuted_refuses() {
  local case_dir rc
  # Regression for the leak this series closes: when the ONLY counted findings
  # were missing/failing and one of them was excused, an unexecuted finding
  # alongside it was silently ignored and the merge proceeded (excused=1,
  # unexcused=0, so neither refusal condition fired). The decision must come
  # from the parsed-and-policy-applied counts of ALL THREE classes, so a gated
  # unexecuted finding refuses even when every missing/failing one is excused.
  case_dir=$(make_stub_case excused-missing-plus-unexecuted 1 \
    'missing: tests/y.test.sh::Y behaves' \
    'unexecuted: tests/x.test.sh::X behaves')
  enable_exec_gate "$case_dir"
  write_supersessions "$case_dir" \
    '- id: tests/y.test.sh::Y behaves | project: project | date: 2026-08-01 | reason: captain approved dropping Y'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "excused-missing-plus-unexecuted: a gated unexecuted finding must refuse even when the missing one is excused"
  assert_grep 'captain-approved supersession covers: tests/y.test.sh::Y behaves (missing)' "$case_dir/stderr" \
    "excused-missing-plus-unexecuted: the excused missing finding was not reported as excused"
  assert_grep 'no captain-approved supersession entry covers: tests/x.test.sh::X behaves (unexecuted)' "$case_dir/stderr" \
    "excused-missing-plus-unexecuted: the unexecuted finding was silently ignored alongside an excused finding"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "excused-missing-plus-unexecuted: gh-axi pr merge was invoked with an uncovered unexecuted finding"
  pass "an excused missing finding does not let a gated unexecuted finding through"
}

test_legacy_single_id_entry_excuses_exactly_its_identifier() {
  local case_dir rc
  case_dir=$(make_stub_case legacy-id-exact 1 \
    'failing: tests/x.test.sh::X behaves' \
    'failing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | project: project | date: 2026-07-19 | reason: captain approved K superseding Z behavior'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-id-exact: an unexcused second finding must still refuse"
  assert_grep 'captain-approved supersession covers: tests/x.test.sh::X behaves (failing)' "$case_dir/stderr" \
    "legacy-id-exact: the legacy entry did not excuse its own identifier"
  assert_grep 'no captain-approved supersession entry covers: tests/y.test.sh::Y behaves (failing)' "$case_dir/stderr" \
    "legacy-id-exact: the legacy entry excused an identifier it does not name"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "legacy-id-exact: gh-axi pr merge was invoked with one finding unexcused"
  pass "a legacy single-id supersession entry excuses exactly its own identifier and nothing else"
}

test_ids_glob_batch_excuses_matching_findings() {
  local case_dir
  case_dir=$(make_stub_case ids-glob-matches 1 \
    'failing: tests/legacy/a.test.sh::one' \
    'failing: tests/legacy/b.test.sh::two')
  write_supersessions "$case_dir" \
    '- ids: tests/legacy/*::* | project: project | kind: failing | date: 2026-08-01 | reason: captain approved the legacy suite rewrite'

  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "ids-glob-matches: a fully-excused batch did not merge"

  assert_grep 'captain-approved supersession covers: tests/legacy/a.test.sh::one (failing)' "$case_dir/stderr" \
    "ids-glob-matches: the first glob-matched finding was not excused"
  assert_grep 'captain-approved supersession covers: tests/legacy/b.test.sh::two (failing)' "$case_dir/stderr" \
    "ids-glob-matches: the second glob-matched finding was not excused"
  grep -qxF 'pr merge 55 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "ids-glob-matches: the merge did not proceed"
  pass "an ids: glob batch entry excuses every identifier it matches"
}

test_ids_glob_does_not_excuse_non_matching_finding() {
  local case_dir rc
  case_dir=$(make_stub_case ids-glob-non-match 1 \
    'failing: tests/legacy/a.test.sh::one' \
    'failing: tests/core/c.test.sh::three')
  write_supersessions "$case_dir" \
    '- ids: tests/legacy/*::* | project: project | kind: failing | date: 2026-08-01 | reason: captain approved the legacy suite rewrite'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ids-glob-non-match: a finding outside the glob must still refuse"
  assert_grep 'captain-approved supersession covers: tests/legacy/a.test.sh::one (failing)' "$case_dir/stderr" \
    "ids-glob-non-match: the glob-matched finding was not excused"
  assert_grep 'no captain-approved supersession entry covers: tests/core/c.test.sh::three (failing)' "$case_dir/stderr" \
    "ids-glob-non-match: a finding outside the glob was excused"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "ids-glob-non-match: gh-axi pr merge was invoked with a finding outside the glob"
  pass "an ids: glob batch entry does not excuse an identifier outside its glob"
}

test_kind_restricted_batch_does_not_excuse_missing() {
  local case_dir rc
  case_dir=$(make_stub_case kind-restricts-batch 1 \
    'unexecuted: tests/x.test.sh::X behaves' \
    'missing: tests/y.test.sh::Y behaves')
  enable_exec_gate "$case_dir"
  write_supersessions "$case_dir" \
    '- ids: * | project: project | kind: unexecuted | date: 2026-08-01 | reason: bumped the runner, captain reviewed the suite manually'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "kind-restricts-batch: a kind-restricted batch must not excuse a missing finding"
  assert_grep 'captain-approved supersession covers: tests/x.test.sh::X behaves (unexecuted)' "$case_dir/stderr" \
    "kind-restricts-batch: the batch did not excuse the class it names"
  assert_grep 'no captain-approved supersession entry covers: tests/y.test.sh::Y behaves (missing)' "$case_dir/stderr" \
    "kind-restricts-batch: the batch silently excused a deleted assertion"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "kind-restricts-batch: gh-axi pr merge was invoked despite an unexcused missing finding"
  pass "kind: restricts a batch entry to its own finding class, never excusing a deleted assertion"
}

test_wildcard_ids_without_kind_excuses_every_class() {
  local case_dir
  # Adversarial and deliberate: `ids: *` with an ABSENT kind is documented
  # back-compat (absent kind means any), so it excuses every class for the whole
  # project. This proves the documented behavior rather than quietly narrowing
  # it; the header warns the captain that such an entry is a loaded gun.
  case_dir=$(make_stub_case wildcard-no-kind 1 \
    'missing: tests/a.test.sh::alpha holds' \
    'failing: tests/b.test.sh::beta holds' \
    'unexecuted: tests/c.test.sh::gamma holds')
  enable_exec_gate "$case_dir"
  write_supersessions "$case_dir" \
    '- ids: * | project: project | date: 2026-08-01 | reason: captain accepted the whole-suite rewrite'

  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "wildcard-no-kind: a kindless wildcard batch must excuse every class"

  assert_grep 'covers: tests/a.test.sh::alpha holds (missing)' "$case_dir/stderr" \
    "wildcard-no-kind: the missing finding was not excused"
  assert_grep 'covers: tests/b.test.sh::beta holds (failing)' "$case_dir/stderr" \
    "wildcard-no-kind: the failing finding was not excused"
  assert_grep 'covers: tests/c.test.sh::gamma holds (unexecuted)' "$case_dir/stderr" \
    "wildcard-no-kind: the unexecuted finding was not excused"
  grep -qxF 'pr merge 58 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "wildcard-no-kind: the fully-excused merge did not proceed"
  pass "an ids: * entry with no kind excuses every finding class, as the back-compat contract documents"
}

test_invalid_kind_entry_not_honored() {
  local case_dir rc
  case_dir=$(make_stub_case invalid-kind 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | project: project | kind: whatever | date: 2026-08-01 | reason: typo must not degrade to any'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "invalid-kind: an unrecognized kind must not excuse the merge"
  assert_grep 'ignoring supersession entry whose kind is not missing, failing, unexecuted, or any' "$case_dir/stderr" \
    "invalid-kind: the invalid kind was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "invalid-kind: gh-axi pr merge was invoked despite an invalid kind"
  pass "a supersession entry naming an invalid kind is warned about and never honored"
}

test_field_after_reason_not_honored() {
  local case_dir rc
  # A kind written after reason would be swallowed into the reason text, so the
  # entry would silently widen to kind: any. That must refuse, not parse loosely.
  case_dir=$(make_stub_case field-after-reason 1 'missing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- ids: * | project: project | date: 2026-08-01 | reason: bumped the runner | kind: unexecuted'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "field-after-reason: an entry with a field after reason must not excuse the merge"
  assert_grep 'reason must be the last field' "$case_dir/stderr" \
    "field-after-reason: the misordered entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "field-after-reason: gh-axi pr merge was invoked despite a misordered entry"
  pass "a supersession entry with a field written after reason is warned about and never honored"
}

test_no_space_field_after_reason_not_honored() {
  local case_dir rc
  # The same swallowing as field-after-reason, one character narrower: without
  # the space after the colon the entry would parse as ids: * with kind: any and
  # excuse a missing finding the captain meant to scope to unexecuted.
  case_dir=$(make_stub_case field-after-reason-no-space 1 'missing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- ids: * | project: project | date: 2026-08-01 | reason: bumped the runner | kind:unexecuted'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "field-after-reason-no-space: a no-space field after reason must not excuse the merge"
  assert_grep 'reason must be the last field' "$case_dir/stderr" \
    "field-after-reason-no-space: the misordered entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "field-after-reason-no-space: gh-axi pr merge was invoked despite a misordered entry"
  pass "a field written after reason with no space after its colon is warned about and never honored"
}

test_duplicated_kind_field_not_honored() {
  local case_dir rc
  # Taking the last value would widen kind: unexecuted to kind: any and excuse a
  # genuinely missing assertion.
  case_dir=$(make_stub_case duplicate-kind 1 'missing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- ids: * | project: project | kind: unexecuted | kind: any | date: 2026-08-01 | reason: a repeat must not widen the entry'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "duplicate-kind: a duplicated kind must not excuse the merge"
  assert_grep "ignoring supersession entry with a duplicated field 'kind'" "$case_dir/stderr" \
    "duplicate-kind: the duplicated field was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "duplicate-kind: gh-axi pr merge was invoked despite a duplicated field"
  pass "a supersession entry repeating kind: is warned about and never honored"
}

test_duplicated_ids_field_not_honored() {
  local case_dir rc
  # The finding matches the second glob but not the first, so a last-wins parse
  # would excuse it and merge.
  case_dir=$(make_stub_case duplicate-ids 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- ids: tests/legacy/* | ids: * | project: project | date: 2026-08-01 | reason: a repeat must not widen the glob'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/67 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "duplicate-ids: a duplicated ids must not excuse the merge"
  assert_grep "ignoring supersession entry with a duplicated field 'ids'" "$case_dir/stderr" \
    "duplicate-ids: the duplicated field was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "duplicate-ids: gh-axi pr merge was invoked despite a duplicated field"
  pass "a supersession entry repeating ids: is warned about and never honored"
}

test_entry_with_both_id_and_ids_not_honored() {
  local case_dir rc
  case_dir=$(make_stub_case both-id-and-ids 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | ids: * | project: project | date: 2026-08-01 | reason: exactly one identifier field is allowed'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/68 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "both-id-and-ids: an entry carrying both identifier fields must not excuse the merge"
  assert_grep "carrying both 'id:' and 'ids:' (use exactly one)" "$case_dir/stderr" \
    "both-id-and-ids: the two-identifier entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "both-id-and-ids: gh-axi pr merge was invoked despite an entry carrying both id: and ids:"
  pass "a supersession entry carrying both id: and ids: is warned about and never honored"
}

test_unparseable_or_unrecognized_field_not_honored() {
  local case_dir rc
  # Two shapes of the same fail-closed branch: a field with no `key: value`
  # structure at all, and a well-formed field naming a key this grammar has no
  # meaning for. Neither may be skipped over into a partially parsed entry.
  case_dir=$(make_stub_case unrecognized-field 1 \
    'failing: tests/x.test.sh::X behaves' \
    'failing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | project: project | scope: everything | date: 2026-08-01 | reason: an unknown key must refuse' \
    '- id: tests/y.test.sh::Y behaves | project: project | oops | date: 2026-08-01 | reason: a structureless field must refuse'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/69 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unrecognized-field: neither malformed entry may excuse the merge"
  assert_grep "ignoring supersession entry with an unrecognized field 'scope'" "$case_dir/stderr" \
    "unrecognized-field: the unrecognized key was not warned about"
  assert_grep "ignoring supersession entry with an unparseable field 'oops'" "$case_dir/stderr" \
    "unrecognized-field: the structureless field was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unrecognized-field: gh-axi pr merge was invoked despite unparseable supersession entries"
  pass "a supersession entry with an unparseable or unrecognized field is warned about and never honored"
}

test_entry_without_id_or_ids_not_honored() {
  local case_dir rc
  case_dir=$(make_stub_case no-id-field 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- project: project | date: 2026-08-01 | reason: forgot the identifier entirely'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-id-field: an entry with no identifier must not excuse the merge"
  assert_grep "carries neither 'id:' nor 'ids:' as its first field" "$case_dir/stderr" \
    "no-id-field: the identifier-less entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "no-id-field: gh-axi pr merge was invoked despite an identifier-less entry"
  pass "a supersession entry carrying neither id: nor ids: is warned about and ignored"
}

test_findings_exit_with_no_parseable_line_refuses() {
  local case_dir rc
  case_dir=$(make_stub_case unparseable-findings 1 'something went sideways')

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unparseable-findings: exit 1 with no parseable finding must refuse"
  assert_grep 'none of its output parsed as a missing:/failing:/unexecuted: line' "$case_dir/stderr" \
    "unparseable-findings: the refusal did not explain the unparseable output"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unparseable-findings: gh-axi pr merge was invoked on unparseable gate output"
  pass "a findings exit whose output has no parseable finding line refuses as unverified"
}

test_unverifiable_exit_refuses() {
  local case_dir rc
  case_dir=$(make_stub_case unverifiable-exit 2)

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unverifiable-exit: exit 2 must refuse as unverifiable"
  assert_grep 'could not verify the base'"'"'s tests are kept' "$case_dir/stderr" \
    "unverifiable-exit: the refusal did not explain that the check could not run"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unverifiable-exit: gh-axi pr merge was invoked on an unverifiable gate result"
  pass "an unverifiable gate exit still refuses the merge"
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
test_unexecuted_without_marker_is_informational_and_merges
test_unexecuted_with_marker_refuses
test_missing_and_failing_refuse_regardless_of_marker
test_excused_missing_plus_gated_unexecuted_refuses
test_legacy_single_id_entry_excuses_exactly_its_identifier
test_ids_glob_batch_excuses_matching_findings
test_ids_glob_does_not_excuse_non_matching_finding
test_kind_restricted_batch_does_not_excuse_missing
test_wildcard_ids_without_kind_excuses_every_class
test_invalid_kind_entry_not_honored
test_field_after_reason_not_honored
test_no_space_field_after_reason_not_honored
test_duplicated_kind_field_not_honored
test_duplicated_ids_field_not_honored
test_entry_with_both_id_and_ids_not_honored
test_unparseable_or_unrecognized_field_not_honored
test_entry_without_id_or_ids_not_honored
test_findings_exit_with_no_parseable_line_refuses
test_unverifiable_exit_refuses
