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

test_removed_shell_test_reported_via_meta
test_removed_python_test_reported
test_added_tests_removed_none_is_silent_zero
test_renamed_test_reported_as_missing
test_identical_branch_is_silent_zero
test_removed_js_test_reported
