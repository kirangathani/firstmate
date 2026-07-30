#!/usr/bin/env bash
# Tests for bin/fm-assert-tests-kept.sh: a rebase must never reduce the test
# assertions the base already had, compared as stable <file>::<name> pairs.
#
# Matrix (per data/rebase-assert-plan.md):
#   (a) branch removes a shell test present on main -> reported, exit non-zero
#       (exercised through the task-id/meta path)
#   (b) branch removes a Python test -> reported
#   (c) branch adds tests but removes none -> nothing missing or failing
#   (d) branch renames a test -> reported (the documented, intended false positive)
#   (e) branch identical to main -> nothing missing or failing
#   (f) branch removes a JS test -> reported (extractor coverage beyond the plan's five)
#   (g) the Z/K rewritten-assertion case: same test name, changed body, main's
#       behavior gone -> caught by check 2 as `failing:` where check 1 passes
#   (h) a behavior-preserving rewrite of code and test body -> exit zero
#       (check 2 runs the base's assertions and they still pass)
#   (i) base test files check 2 cannot execute -> every identifier reported as
#       `unexecuted:` on stdout with a loud stderr block, exit non-zero
#   (j) pytest, clean: the base's Python test passes against the branch -> exit
#       zero (proves real pytest execution, not a name check)
#   (k) pytest, rewritten assertion body -> caught as `failing:` where check 1
#       passes (the Z/K case in Python)
#   (l) pytest with no resolvable interpreter -> `unexecuted:`, never a pass
#   (m) pytest whose editable install shadows the scratch tree -> `unexecuted:`,
#       the safe failure, never a green verdict against the wrong tree
#   (n) an editable install the scratch tree DOES shadow still executes, so the
#       safe failure cannot quietly become "every editable project is skipped"
#   (o) the `summary:` line is always printed and counts every class
#   (p) a run never mutates the live worktree
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
  assert_not_contains "$out" 'missing: tests/app.test.sh::alpha holds' \
    "meta-shape: a kept assertion must not be reported as missing"
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

test_added_tests_removed_none_loses_nothing() {
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

  # This corpus is deliberately not executable, so it exits 1 on the unexecuted
  # class alone (case (i) owns that). The signal here is check 1's: adding tests
  # loses none of the base's.
  expect_code 1 "$code" "add-only: the corpus is unexecutable, so exit reflects that class"
  assert_contains "$out" 'summary: missing=0 failing=0' \
    "add-only: adding tests must lose no base assertion"
  assert_not_contains "$out" 'missing:' "add-only: nothing may be reported missing"
  assert_not_contains "$out" 'failing:' "add-only: nothing may be reported failing"
  pass "a branch that only adds tests loses none of the base's assertions"
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

test_identical_branch_loses_nothing() {
  local dir out code
  dir=$(make_repo identical)

  set +e
  out=$(run_explicit "$dir" 2>/dev/null)
  code=$?
  set -e

  expect_code 1 "$code" "identical: the corpus is unexecutable, so exit reflects that class"
  assert_contains "$out" 'summary: missing=0 failing=0' \
    "identical: an unchanged branch must lose no base assertion"
  assert_not_contains "$out" 'missing:' "identical: nothing may be reported missing"
  assert_not_contains "$out" 'failing:' "identical: nothing may be reported failing"
  pass "a branch identical to main loses none of the base's assertions"
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
  assert_not_contains "$out" 'missing: app.test.js::epsilon works' \
    "js-removed: a kept JS test must not be reported as missing"
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
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0' \
    "zk-refactor: a fully executed clean tree must report zero in every class"
  pass "a behavior-preserving rewrite of code and test body exits zero"
}

test_unexecutable_files_are_reported_not_passed() {
  local dir out code
  # The baseline corpus's shell test calls an undefined `pass`, so its baseline
  # run is red; its python/js files resolve no runner (no config, no venv, and
  # no JS runner until PR3). None of that may read as a pass.
  dir=$(make_repo unexecuted-report)

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "unexecuted-report: an unexecutable base test file must exit non-zero"
  assert_contains "$out" 'unexecuted: tests/app.test.sh::alpha holds' \
    "unexecuted-report: a red shell baseline must report its identifiers as unexecuted"
  assert_contains "$out" 'unexecuted: test_app.py::test_gamma' \
    "unexecuted-report: a Python file with no resolvable runner must be reported as unexecuted"
  assert_contains "$out" 'unexecuted: app.test.js::epsilon works' \
    "unexecuted-report: a JS file with no runner must be reported as unexecuted"
  # Seven: two shell, two Python, and three JS (the describe title counts).
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=7' \
    "unexecuted-report: the summary must count every unexecuted identifier"
  assert_not_contains "$out" 'missing:' \
    "unexecuted-report: nothing was renamed or deleted, so check 1 must stay silent"
  assert_not_contains "$out" 'failing:' \
    "unexecuted-report: an unexecuted file is not a failing assertion"
  assert_grep 'UNEXECUTED: tests/app.test.sh (fails on the base itself' "$dir/stderr" \
    "unexecuted-report: the reason a file could not be executed must be on stderr"
  assert_grep 'captured baseline output' "$dir/stderr" \
    "unexecuted-report: the verbatim baseline output must be captured as evidence"
  pass "base test files check 2 cannot execute are reported as unexecuted, never as a pass"
}

# --- pytest fixtures --------------------------------------------------------

# The provisioned environment the Python fixtures link in, exactly as a
# pipeline-provisioned worktree's .venv is linked at the real gate. Built once
# per suite run and shared, so the per-case cost is a symlink.
PYTEST_VENV="$TMP_ROOT/_pytest-venv"

# ensure_pytest_venv: build $PYTEST_VENV if absent. Returns non-zero when the
# host cannot provide pytest at all, so the caller fails loudly instead of
# silently dropping the coverage that proves assertions really execute.
ensure_pytest_venv() {
  if [ -x "$PYTEST_VENV/bin/python" ]; then
    return 0
  fi
  if python3 -c 'import pytest' >/dev/null 2>&1; then
    # Already available on the host: reuse it and stay off the network.
    python3 -m venv --system-site-packages "$PYTEST_VENV" >/dev/null 2>&1 || return 1
  else
    python3 -m venv "$PYTEST_VENV" >/dev/null 2>&1 || return 1
    "$PYTEST_VENV/bin/python" -m pip install --quiet --disable-pip-version-check pytest \
      >/dev/null 2>&1 || return 1
  fi
  "$PYTEST_VENV/bin/python" -m pytest --version >/dev/null 2>&1
}

require_pytest_venv() {
  ensure_pytest_venv || fail "$1: could not provision a venv with pytest (needs python3 with venv, and pip or an importable pytest); the pytest runner cannot be verified without one"
}

# write_py_tree <dir> <behavior> <asserted> [<pkg-parent>]: the plan's Z/K
# worked example in Python - pkg.mod.greet() returns <behavior> and test_mod.py
# asserts <asserted> under the stable name test_x_behaves. The repo addopts is a
# coverage gate no fixture installs, so a run that did NOT neutralize addopts
# would error out instead of reporting a verdict. <pkg-parent> defaults to the
# tree root; "lib" gives a custom layout that neither the root nor a src/
# PYTHONPATH root can expose, which is what the shadow case needs.
write_py_tree() {
  local dir=$1 behavior=$2 asserted=$3 parent=${4:-}
  local pkgdir="$dir${parent:+/$parent}/pkg"
  mkdir -p "$pkgdir"
  cat > "$dir/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
addopts = "--cov=pkg --cov-fail-under=100"
EOF
  printf '.venv/\n' > "$dir/.gitignore"
  : > "$pkgdir/__init__.py"
  printf 'def greet():\n    return "%s"\n' "$behavior" > "$pkgdir/mod.py"
  cat > "$dir/test_mod.py" <<EOF
from pkg.mod import greet


def test_x_behaves():
    assert greet() == "$asserted"
EOF
}

# make_py_repo <name> [<pkg-parent>]: main has greet returning Z and
# test_x_behaves asserting Z, with a work branch checked out. Echoes dir. The
# caller links the provisioned env itself, so the no-interpreter case can skip it.
make_py_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git init -q -b main "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b main
  }
  write_py_tree "$dir" Z Z "${2:-}"
  commit_all "$dir" "main: greet returns Z, test asserts Z"
  git -C "$dir" checkout -q -b work
  printf '%s\n' "$dir"
}

test_pytest_clean_run_exits_zero() {
  local dir out code
  require_pytest_venv pytest-clean
  dir=$(make_py_repo pytest-clean)
  ln -s "$PYTEST_VENV" "$dir/.venv"
  # A legitimate refactor: internals change, the behavior main asserted holds.
  printf 'def greet():\n    value = "Z"\n    return value\n' > "$dir/pkg/mod.py"
  commit_all "$dir" "refactor greet, behavior preserved"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-clean: the base's Python assertion still passes, so exit must be zero"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0' \
    "pytest-clean: a real pytest run must report zero unexecuted, proving it executed"
  assert_not_contains "$out" 'unexecuted:' \
    "pytest-clean: the Python file must be executed, not name-checked"
  pass "a Python base test that passes against the branch exits zero"
}

test_pytest_rewritten_assertion_caught() {
  local dir out code
  require_pytest_venv pytest-rewrite
  dir=$(make_py_repo pytest-rewrite)
  ln -s "$PYTEST_VENV" "$dir/.venv"
  # The resolver takes K's side in BOTH files: greet returns K and the test keeps
  # its name but asserts K. Check 1 sees the same name on both sides.
  write_py_tree "$dir" K K
  commit_all "$dir" "resolver takes K in both pkg/mod.py and the test"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "pytest-rewrite: a rewritten Python assertion body must exit non-zero"
  assert_contains "$out" 'failing: test_mod.py::test_x_behaves' \
    "pytest-rewrite: check 2 must report main's Python assertion as failing against the branch"
  assert_not_contains "$out" 'missing:' \
    "pytest-rewrite: check 1 must NOT flag anything (the name survived), proving check 2 caught it"
  assert_not_contains "$out" 'unexecuted:' \
    "pytest-rewrite: the verdict must come from a real run, not a fallback"
  pass "a rewritten Python assertion body is caught by check 2 where check 1 passes"
}

test_pytest_without_interpreter_is_unexecuted() {
  local dir out code
  # No .venv linked, so no interpreter resolves from the worktree.
  dir=$(make_py_repo pytest-no-venv)

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "pytest-no-venv: an unresolvable interpreter must not be a silent pass"
  assert_contains "$out" 'unexecuted: test_mod.py::test_x_behaves' \
    "pytest-no-venv: the identifier must be reported as unexecuted"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=1' \
    "pytest-no-venv: the summary must count it as unexecuted"
  pass "a Python test with no resolvable interpreter is reported unexecuted, not passed"
}

test_pytest_editable_shadow_is_unexecuted() {
  local dir out code
  require_pytest_venv pytest-shadow
  # A custom package layout (lib/pkg, neither root nor src) installed editable:
  # the venv's site-packages points at the ABSOLUTE live worktree path, which
  # the scratch tree's PYTHONPATH cannot shadow. Testing the live branch tree
  # while believing it is the scratch copy is the false green this must refuse.
  dir=$(make_py_repo pytest-shadow lib)

  link_borrowed_pytest_venv "$dir" "$dir/lib"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "pytest-shadow: an unauthoritative scratch tree must not be a silent pass"
  assert_contains "$out" 'unexecuted: test_mod.py::test_x_behaves' \
    "pytest-shadow: a tree that cannot be proven authoritative must be reported unexecuted"
  assert_not_contains "$out" 'failing:' \
    "pytest-shadow: an untrusted tree yields no verdict at all, neither pass nor fail"
  assert_grep 'shadows the scratch tree' "$dir/stderr" \
    "pytest-shadow: the reason must name the shadowing so it is actionable"
  pass "a Python tree the scratch copy cannot shadow is reported unexecuted, never passed"
}

# link_borrowed_pytest_venv <dir> <extra-path>: give <dir> its OWN .venv (so an
# editable artifact never leaks into the shared one), borrowing pytest from the
# shared venv through a bare-path .pth, and install a second .pth pointing at
# <extra-path> - exactly the shape an editable install leaves behind.
link_borrowed_pytest_venv() {
  local dir=$1 extra=$2 site shared_site
  python3 -m venv "$dir/.venv" >/dev/null 2>&1 \
    || fail "could not create the case's own venv at $dir/.venv"
  site=$("$dir/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
  shared_site=$("$PYTEST_VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
  printf '%s\n' "$shared_site" > "$site/borrow-pytest.pth"
  printf '%s\n' "$extra" > "$site/__editable__.demo.pth"
}

test_pytest_editable_that_scratch_shadows_still_runs() {
  local dir out code
  require_pytest_venv pytest-editable-ok
  # The counterpart to the shadow case: a flat layout installed editable, which
  # the scratch tree's PYTHONPATH DOES shadow. This must still execute, so the
  # safe failure can never quietly become "every editable project is skipped".
  dir=$(make_py_repo pytest-editable-ok)
  link_borrowed_pytest_venv "$dir" "$dir"
  write_py_tree "$dir" K K
  commit_all "$dir" "resolver takes K in both pkg/mod.py and the test"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "pytest-editable-ok: the rewritten assertion must still be caught"
  # Reaching a failing: verdict at all proves BOTH trees resolved to their own
  # scratch copy: against the live tree the baseline would have been red.
  assert_contains "$out" 'failing: test_mod.py::test_x_behaves' \
    "pytest-editable-ok: an editable install the scratch tree shadows must still be executed"
  assert_not_contains "$out" 'unexecuted:' \
    "pytest-editable-ok: a shadowable editable install must not be refused as untrusted"
  pass "an editable install the scratch tree can shadow is still executed"
}

test_run_never_mutates_the_live_worktree() {
  local dir before after
  require_pytest_venv no-mutation
  dir=$(make_py_repo no-mutation)
  ln -s "$PYTEST_VENV" "$dir/.venv"
  before="$TMP_ROOT/no-mutation.before"
  after="$TMP_ROOT/no-mutation.after"
  # run_explicit puts this harness's own state dir inside the fixture, so create
  # it up front: the snapshot must isolate what the RUN does to the worktree.
  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"
  # find does not traverse the .venv symlink, so this covers the tracked tree
  # and would catch a stray __pycache__, .pytest_cache, or scratch leak.
  find "$dir" -path "$dir/.git" -prune -o -print | sort > "$before"

  set +e
  run_explicit "$dir" > /dev/null 2>&1
  set -e

  find "$dir" -path "$dir/.git" -prune -o -print | sort > "$after"
  diff -u "$before" "$after" > "$TMP_ROOT/no-mutation.diff" \
    || fail "no-mutation: the run must not add or remove anything in the live worktree"$'\n'"$(cat "$TMP_ROOT/no-mutation.diff")"
  assert_absent "$PYTEST_VENV/../.venv" "no-mutation: the run must not create env dirs outside the worktree"
  pass "a check-2 run never mutates the live worktree"
}

test_removed_shell_test_reported_via_meta
test_removed_python_test_reported
test_added_tests_removed_none_loses_nothing
test_renamed_test_reported_as_missing
test_identical_branch_loses_nothing
test_removed_js_test_reported
test_rewritten_assertion_caught_by_check2
test_behavior_preserving_rewrite_is_silent_zero
test_unexecutable_files_are_reported_not_passed
test_pytest_clean_run_exits_zero
test_pytest_rewritten_assertion_caught
test_pytest_without_interpreter_is_unexecuted
test_pytest_editable_shadow_is_unexecuted
test_pytest_editable_that_scratch_shadows_still_runs
test_run_never_mutates_the_live_worktree
