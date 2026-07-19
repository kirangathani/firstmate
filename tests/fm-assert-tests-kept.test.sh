#!/usr/bin/env bash
# Tests for bin/fm-assert-tests-kept.sh: a rebase must never reduce the test
# assertions the base already had, compared as stable <file>::<name> pairs.
#
# Matrix (per data/rebase-assert-plan.md):
#   (a) branch removes a shell test present on main -> reported, exit non-zero
#       (exercised through the task-id/meta path)
#   (b) branch removes a Python test -> reported
#   (c) branch adds tests but removes none -> exit zero, stdout empty
#   (d) branch renames a test -> reported (the documented, intended false positive)
#   (e) branch identical to main -> exit zero, stdout empty
#   (f) branch removes a JS test -> reported (extractor coverage beyond the plan's five)
#   (g) the Z/K rewritten-assertion case: same test name, changed body, main's
#       behavior gone -> caught by check 2 as `failing:` where check 1 passes
#   (h) a behavior-preserving rewrite of code and test body -> exit zero
#       (check 2 runs the base's assertions and they still pass)
#   (i) base test files check 2 cannot execute -> loud name-check-only WARNING
#       on stderr, exit still reflects check 1
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ASSERT_KEPT="$ROOT/bin/fm-assert-tests-kept.sh"
TMP_ROOT=$(fm_test_tmproot fm-assert-tests-kept-tests)

# write_baseline <dir>: the three-language test corpus every case starts from.
write_baseline() {
  local dir=$1
  mkdir -p "$dir/tests"
  cat > "$dir/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
pass "alpha holds"
pass "beta holds"
EOF
  cat > "$dir/test_app.py" <<'EOF'
def test_gamma():
    assert True

async def test_delta():
    assert True
EOF
  cat > "$dir/app.test.js" <<'EOF'
describe('app', () => {
  it('epsilon works', () => {});
  test("zeta works", () => {});
});
EOF
}

# make_repo <name>: a plain local repo with the baseline committed on main and
# a work branch checked out, for the explicit --worktree/--base mode. Echoes dir.
make_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git init -q -b main "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b main
  }
  write_baseline "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -qm baseline
  git -C "$dir" checkout -q -b work
  printf '%s\n' "$dir"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

run_explicit() {
  local dir=$1
  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/.state" \
    "$ASSERT_KEPT" --worktree "$dir" --base main --branch work
}

test_removed_shell_test_reported_via_meta() {
  local case_dir out code
  case_dir="$TMP_ROOT/meta-shape"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  write_baseline "$case_dir/_seed"
  commit_all "$case_dir/_seed" baseline
  git -C "$case_dir/_seed" push -q origin HEAD:main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  cat > "$case_dir/wt/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
pass "alpha holds"
EOF
  commit_all "$case_dir/wt" "drop beta"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"
  touch "$case_dir/state/.last-watcher-beat"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ASSERT_KEPT" task-x1 2> "$case_dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "meta-shape: removed shell test must exit non-zero"
  assert_contains "$out" 'missing: tests/app.test.sh::beta holds' \
    "meta-shape: the removed shell assertion must be reported by name"
  assert_not_contains "$out" 'alpha holds' \
    "meta-shape: a kept assertion must not be reported"
  pass "removed shell test is reported through the task-id meta path"
}

test_removed_python_test_reported() {
  local dir out code
  dir=$(make_repo py-removed)
  cat > "$dir/test_app.py" <<'EOF'
def test_gamma():
    assert True
EOF
  commit_all "$dir" "drop test_delta"

  set +e
  out=$(run_explicit "$dir" 2>/dev/null)
  code=$?
  set -e

  expect_code 1 "$code" "py-removed: removed Python test must exit non-zero"
  assert_contains "$out" 'missing: test_app.py::test_delta' \
    "py-removed: the removed Python test must be reported by name"
  pass "removed Python test is reported"
}

test_added_tests_removed_none_is_silent_zero() {
  local dir out code
  dir=$(make_repo add-only)
  cat >> "$dir/tests/app.test.sh" <<'EOF'
pass "newly added case"
EOF
  cat >> "$dir/test_app.py" <<'EOF'

def test_extra():
    assert True
EOF
  commit_all "$dir" "add tests only"

  set +e
  out=$(run_explicit "$dir" 2>/dev/null)
  code=$?
  set -e

  expect_code 0 "$code" "add-only: adding tests must exit zero"
  [ -z "$out" ] || fail "add-only: stdout must be empty, got: $out"
  pass "a branch that only adds tests exits zero and prints nothing"
}

test_renamed_test_reported_as_missing() {
  local dir out code
  dir=$(make_repo renamed)
  cat > "$dir/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
pass "alpha still holds"
pass "beta holds"
EOF
  commit_all "$dir" "rename alpha"

  set +e
  out=$(run_explicit "$dir" 2>/dev/null)
  code=$?
  set -e

  expect_code 1 "$code" "renamed: a renamed test must exit non-zero (intended false positive)"
  assert_contains "$out" 'missing: tests/app.test.sh::alpha holds' \
    "renamed: the old name must be reported so the rename is justified, not silent"
  pass "a renamed test is reported (the documented intended false positive)"
}

test_identical_branch_is_silent_zero() {
  local dir out code
  dir=$(make_repo identical)

  set +e
  out=$(run_explicit "$dir" 2>/dev/null)
  code=$?
  set -e

  expect_code 0 "$code" "identical: unchanged branch must exit zero"
  [ -z "$out" ] || fail "identical: stdout must be empty, got: $out"
  pass "a branch identical to main exits zero and prints nothing"
}

test_removed_js_test_reported() {
  local dir out code
  dir=$(make_repo js-removed)
  cat > "$dir/app.test.js" <<'EOF'
describe('app', () => {
  it('epsilon works', () => {});
});
EOF
  commit_all "$dir" "drop zeta"

  set +e
  out=$(run_explicit "$dir" 2>/dev/null)
  code=$?
  set -e

  expect_code 1 "$code" "js-removed: removed JS test must exit non-zero"
  assert_contains "$out" 'missing: app.test.js::zeta works' \
    "js-removed: the removed JS test must be reported by name"
  assert_not_contains "$out" 'epsilon' \
    "js-removed: a kept JS test must not be reported"
  pass "removed JS test is reported"
}

# write_zk_tree <dir> <behavior> <asserted>: the plan's Z/K worked-example
# shape - app.sh prints <behavior>, and a self-contained runnable shell test
# (pass/fail helpers inline, so check 2's baseline run is green) asserts app.sh
# prints <asserted> under the stable name "X behaves".
write_zk_tree() {
  local dir=$1 behavior=$2 asserted=$3
  mkdir -p "$dir/tests"
  printf '#!/usr/bin/env bash\necho %s\n' "$behavior" > "$dir/app.sh"
  cat > "$dir/tests/x.test.sh" <<EOF
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "\$1"; }
fail() { printf 'not ok - %s\n' "\$1" >&2; exit 1; }
out=\$(bash ./app.sh)
[ "\$out" = "$asserted" ] || fail "X behaves"
pass "X behaves"
EOF
}

# make_zk_repo <name>: main has X producing Z and test_X asserting Z, with a
# work branch checked out. Echoes dir.
make_zk_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git init -q -b main "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b main
  }
  write_zk_tree "$dir" Z Z
  commit_all "$dir" "main: X produces Z, test asserts Z"
  git -C "$dir" checkout -q -b work
  printf '%s\n' "$dir"
}

test_rewritten_assertion_caught_by_check2() {
  local dir out code
  dir=$(make_zk_repo zk-rewrite)
  # The resolver takes K's side in BOTH files: X now produces K and the test
  # keeps its name but asserts K. Check 1 sees the same name on both sides.
  write_zk_tree "$dir" K K
  commit_all "$dir" "resolver takes K in both app.sh and test"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "zk-rewrite: a rewritten assertion body must exit non-zero"
  assert_contains "$out" 'failing: tests/x.test.sh::X behaves' \
    "zk-rewrite: check 2 must report main's assertion as failing against the branch"
  assert_not_contains "$out" 'missing:' \
    "zk-rewrite: check 1 must NOT flag anything (the name survived), proving check 2 is what catches this"
  pass "the Z/K rewritten-assertion case is caught by check 2 where check 1 passes"
}

test_behavior_preserving_rewrite_is_silent_zero() {
  local dir out code
  dir=$(make_zk_repo zk-refactor)
  # A legitimate refactor: app.sh internals and the test body both change, but
  # the behavior main asserted is preserved, so main's own test still passes.
  cat > "$dir/app.sh" <<'EOF'
#!/usr/bin/env bash
v=Z
echo "$v"
EOF
  cat > "$dir/tests/x.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
observed=$(bash ./app.sh)
if [ "$observed" != "Z" ]; then fail "X behaves"; fi
pass "X behaves"
EOF
  commit_all "$dir" "refactor both sides, behavior preserved"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "zk-refactor: a behavior-preserving rewrite must exit zero"
  [ -z "$out" ] || fail "zk-refactor: stdout must be empty, got: $out"
  pass "a behavior-preserving rewrite of code and test body exits zero"
}

test_unrunnable_check2_falls_back_loudly() {
  local dir out code
  # The baseline corpus's shell test calls an undefined `pass`, so its baseline
  # run is red and check 2 cannot execute it; python/js are never executed.
  dir=$(make_repo loud-fallback)

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "loud-fallback: exit must still reflect check 1 (nothing missing)"
  [ -z "$out" ] || fail "loud-fallback: stdout must be empty, got: $out"
  assert_grep 'WARNING' "$dir/stderr" \
    "loud-fallback: check 2 falling back to the name check must warn loudly"
  assert_grep 'name-check only: tests/app.test.sh' "$dir/stderr" \
    "loud-fallback: the unrunnable shell test file must be named"
  assert_grep 'name-check only: test_app.py' "$dir/stderr" \
    "loud-fallback: non-executed non-shell test files must be named"
  pass "check 2 falling back to the name check says so loudly on stderr"
}

test_removed_shell_test_reported_via_meta
test_removed_python_test_reported
test_added_tests_removed_none_is_silent_zero
test_renamed_test_reported_as_missing
test_identical_branch_is_silent_zero
test_removed_js_test_reported
test_rewritten_assertion_caught_by_check2
test_behavior_preserving_rewrite_is_silent_zero
test_unrunnable_check2_falls_back_loudly
