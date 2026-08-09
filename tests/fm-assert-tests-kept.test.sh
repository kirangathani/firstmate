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
#   (q) a tests/ dir whose test imports a sibling helper by bare name still
#       executes under --import-mode=importlib, so the layout prepend mode used
#       to carry is not silently reported unexecuted
#   (r) a pytest file whose every test is explicitly skipped reports `skipped:`
#       per identifier and exits ZERO - visible, not a silent clean pass
#   (s) a partially-run pytest file reports the identifier that produced no
#       result as `unaccounted:`, and still exits zero
#   (t) a pytest file whose results report cannot be read reports every
#       identifier `unaccounted:`, and still exits zero
#   (u) a shell name that never emitted `ok - ` is `unaccounted:`, since the TAP
#       protocol has no skip marker to report instead
#   (v) parametrization: check 1's bare `def test_*` name and the runner's
#       `test_x[param]` names are different namespaces, so a green parametrized
#       test must NOT be reported unaccounted, an all-skipped one must be
#       `skipped:`, one passing case outweighs its skipped cases, and a near-name
#       pair (test_x beside test_xy) must not cross-match
#   (w) vitest, clean: the base's JS test passes against the branch -> exit
#       zero with every class zero, proving real execution AND that composed
#       `describe > it` titles account for check 1's per-segment names
#   (x) vitest, rewritten assertion body -> caught as `failing:` under the
#       runner's composed title where check 1 passes (the Z/K case in JS)
#   (y) vitest signalled but node_modules absent -> `unexecuted:` per
#       identifier, never a pass
#   (z) a workspace-style node_modules symlink into live first-party source ->
#       `unexecuted:`, the safe failure, never a verdict against the wrong tree
#   (aa) jest, clean and rewritten-assertion variants of (w)/(x)
#   (bb) jest, an explicitly skipped test reports `skipped:` (jest spells an
#       explicit skip "pending") and still exits zero
#   (cc) a JS run never mutates the live worktree or the linked node_modules
#       (vitest's results cache must stay disabled)
#   (dd) base resolution: a PR stacked on a NON-default branch is compared
#        against the branch it targets, in both directions - the assertion its
#        own base had and the branch dropped is reported, and one only the
#        default branch had is not; a recorded PR whose base cannot be read
#        REFUSES (exit 2) rather than falling back to the default, naming the
#        cause gh reported rather than swallowing it; a recorded PR that lives
#        in a GitHub repository OTHER than origin's REFUSES before any fetch,
#        naming both sides, since both PR-derived refs are fetched from origin,
#        and that refusal names owner/repo only, never origin's raw address,
#        which can carry an embedded credential; a recorded pr= that is not a
#        readable PR link REFUSES before any gh call or fetch, naming the value
#        it could not read, because an unidentifiable link cannot be checked
#        against origin at all; the repository sense of that refusal is spelled
#        "lives in", never "targets", which means the PR's BASE BRANCH
#        everywhere else in the script;
#        an origin that is not a GitHub URL at all is NOT a determinable
#        mismatch and must still resolve normally, which every other case here
#        covers implicitly because their origin is a local path; a task with
#        no recorded PR still resolves the default branch; and explicit mode
#        takes the caller's --base verbatim without consulting GitHub
#   (ee) an assertion whose NAME is built from a runtime value: check 2 refuses to
#        compare a name it cannot resolve in check 1's static extraction and
#        reports `unstable:` rather than a false `failing:`; that refusal never
#        swallows a genuinely failing assertion or masks a deleted one in the same
#        file; and the constant-named fix is both compared cleanly AND finally
#        accounted for, which the unexpanded form never could be
#   (ff) --assume-branch-suite-green: a base test file the branch's copy matches
#        byte for byte is NOT executed and every identifier in it is reported
#        `assumed-covered:` at exit zero; the same tree without the flag executes
#        it and reports `failing:`, so the skip is opt-in and the flagged run
#        really did decline to run it; a rewritten assertion body and a deleted
#        base test file are both still caught under the flag; and identical
#        content at a DIFFERENT path is never treated as identical
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ASSERT_KEPT="$ROOT/bin/fm-assert-tests-kept.sh"
TMP_ROOT=$(fm_test_tmproot fm-assert-tests-kept-tests)

# --- the shared pinned-runtime cache ----------------------------------------
# The vitest, jest and pytest environments below are real installs of pinned
# third-party runners. Rebuilding them into the per-run $TMP_ROOT cost about 29s
# of this file's ~50s on every single local run, so they now live in a stable
# directory keyed on the pinned version instead.
#
# THE COVERAGE TRADE, DECIDED DELIBERATELY. Caching them means the default local
# run stops exercising the npm-install and venv-creation path every time: after
# this change that path runs on the first run after a version bump, whenever the
# cache is missing or broken, and in CI, which always starts cold. The captain
# weighed that and accepted it, because CI is exhaustive by design and is the
# gate that has to catch a broken provisioning path. This is a chosen posture,
# not something that drifted - if you are tempted to "restore" the per-run
# rebuild, the trade is recorded in the backlog decision
# fm-testperf-profile-t3-decision-js-py-env-cache. What did NOT change: the
# cases still install and execute real vitest, jest and pytest against real
# trees, and a host that cannot provision one still fails loudly rather than
# quietly skipping the coverage.
#
# Correctness rules the builders below keep:
#   - the pinned version is part of the directory NAME, so a version bump names
#     a directory that does not exist yet and is rebuilt, never reused;
#   - every environment is built under a private staging path and published by
#     a single rename, so a concurrent local shard either sees no environment or
#     a complete one, never a half-installed one.
#
# Kept beside the timings sidecar under the shared git common dir, which
# bin/fm-test.sh already establishes as never tracked and never shipped, so a
# stale or hostile cache cannot ride into the repo or into CI.
ENV_CACHE="${FM_TEST_ENV_CACHE_DIR:-}"
if [ -z "$ENV_CACHE" ]; then
  ENV_CACHE="$(fm_test_git_common_dir "$TMP_ROOT")/fm-test-env-cache"
fi

# Every pin lives here and is written ONCE. The cache directory's NAME and the
# version handed to npm/pip are both derived from the same variable, so they
# cannot drift apart and leave a stale tree served under a bumped pin's name.
# Bump a runner by editing only its version variable below.
#
# These are the versions the runner behavior in bin/fm-test-exec-lib.sh was
# verified against (vitest/jest on 2026-08-03, pytest on 2026-08-05). pytest is
# pinned for the same reason vitest and jest are: unpinned, a months-old local
# venv keeps serving an old pytest while CI, always cold, resolves the newest,
# so a skip/pending spelling or JUnit-XML shape change would go red in CI and
# stay green locally forever with no key to invalidate.
VITEST_VERSION=3.2.7
JEST_VERSION=30.4.1
PYTEST_VERSION=9.1.1
VITEST_ENV="$ENV_CACHE/vitest-$VITEST_VERSION"
JEST_ENV="$ENV_CACHE/jest-$JEST_VERSION"
# A venv additionally bakes in the interpreter it was built against and is not
# portable across CPython versions, so that joins the pinned pytest in the key.
PYTEST_VENV_KEY=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)
if [ -n "$PYTEST_VENV_KEY" ]; then
  PYTEST_VENV="$ENV_CACHE/pytest-$PYTEST_VERSION-py$PYTEST_VENV_KEY"
else
  # No usable python3 to key on; stay per-run and let ensure_pytest_venv fail.
  PYTEST_VENV="$TMP_ROOT/_pytest-venv"
fi

# Every failure path below removes its own staging tree, but a run KILLED
# mid-install cannot, and each orphan is a whole node_modules or venv sitting in
# the cache forever. Sweep only entries carrying the private `.build.<6 chars>`
# marker that nothing has touched for six hours - two orders of magnitude longer
# than the slowest install here, so a concurrently building shard is never in
# range and a published environment never matches the pattern at all.
if [ -d "$ENV_CACHE" ]; then
  find "$ENV_CACHE" -maxdepth 1 -type d -name '*.build.??????' -mmin +360 \
    -exec rm -rf {} + 2>/dev/null || true
fi

# publish_env <staging> <final>: move a fully built environment into place with
# one rename, so no reader ever observes a partial tree. Returns non-zero and
# leaves nothing behind when another shard published first.
publish_env() {
  local staging=$1 final=$2 leftover
  leftover=$(basename "$staging")
  [ -n "$leftover" ] || return 1
  mkdir -p "$(dirname "$final")" 2>/dev/null || true
  if [ -e "$final" ] || ! mv "$staging" "$final" 2>/dev/null; then
    rm -rf "$staging" 2>/dev/null || true
  fi
  # A shard can win the rename between the test above and the mv, in which case
  # mv put the staging tree INSIDE the winner's directory. The staging name is
  # unique to this process, so removing it can never touch a real cache entry.
  rm -rf "${final:?}/$leftover" 2>/dev/null || true
  [ -e "$final" ]
}

# relocate_venv_paths <staging> <final>: a venv bakes its own absolute path into
# its console-script shebangs, its activate scripts and pyvenv.cfg. A venv built
# at one path and then renamed leaves `bin/pytest` pointing at a path that no
# longer exists, and bin/fm-test-exec-lib.sh uses exactly that script as its
# interpreter fallback. Rewrite the baked paths to the FINAL location while the
# tree is still private, so the publishing rename remains the only step a
# concurrent reader can observe. `bin/python` itself is a symlink to the system
# interpreter and needs no repair; a moved venv resolves its own prefix from the
# executable's real path, so `bin/python -m pytest` was never the broken part.
relocate_venv_paths() {
  local staging=$1 final=$2 f body
  for f in "$staging"/pyvenv.cfg "$staging"/bin/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    body=$(cat "$f" 2>/dev/null) || continue
    case "$body" in
      *"$staging"*) ;;
      *) continue ;;
    esac
    printf '%s\n' "${body//"$staging"/$final}" > "$f" || return 1
  done
  return 0
}

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

# run_explicit <dir> [<extra arg>...]: explicit --worktree/--base mode. Extra
# args are passed through BEFORE the positional ones, which is where the
# premise-flag cases below want them; one case deliberately passes the flag
# after them instead, to hold up the "any argument position" claim.
run_explicit() {
  local dir=$1
  shift
  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/.state" \
    "$ASSERT_KEPT" "$@" --worktree "$dir" --base main --branch work
}

# --- the PR-base fixtures ----------------------------------------------------
# A PR is not necessarily stacked on the default branch, and the gate's verdict
# is only meaningful against the tree the PR was actually built on. These cases
# build an origin whose `feature-base` branch DELIBERATELY diverges from main in
# both directions, so a run against the wrong base is visible either way:
#   - feature-base drops main's tests/mainonly.test.sh, so a run against main
#     reports a `missing:` the PR never caused (a sound PR refused);
#   - feature-base adds tests/feature.test.sh, so a run against main cannot see
#     the branch dropping it (a genuine loss missed).
# Every test file is self-contained (its own pass/fail helpers) so check 2 can
# actually execute it and the case's exit code stays about the base, not about
# an unexecutable fixture.
pr_base_test_file() {
  cat <<EOF
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "\$1"; }
fail() { printf 'not ok - %s\n' "\$1" >&2; exit 1; }
pass "$1"
EOF
}

# make_pr_base_case <name>: origin.git with main and feature-base as above, a
# project clone, and a task worktree on fm/task-pb branched from feature-base
# with tests/feature.test.sh removed. Echoes the case dir.
make_pr_base_case() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  mkdir -p "$case_dir/_seed/tests"
  pr_base_test_file 'alpha holds' > "$case_dir/_seed/tests/app.test.sh"
  pr_base_test_file 'mainonly holds' > "$case_dir/_seed/tests/mainonly.test.sh"
  commit_all "$case_dir/_seed" baseline
  git -C "$case_dir/_seed" push -q origin HEAD:main
  git -C "$case_dir/_seed" checkout -q -b feature-base
  rm "$case_dir/_seed/tests/mainonly.test.sh"
  pr_base_test_file 'feature holds' > "$case_dir/_seed/tests/feature.test.sh"
  commit_all "$case_dir/_seed" "feature base"
  git -C "$case_dir/_seed" push -q origin HEAD:feature-base
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-pb "$case_dir/wt" \
    origin/feature-base
  rm "$case_dir/wt/tests/feature.test.sh"
  commit_all "$case_dir/wt" "drop the feature assertion"

  fm_write_meta "$case_dir/state/task-pb.meta" \
    "window=fm-task-pb" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "pr=https://github.com/o/r/pull/7"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# write_pr_base_gh <case_dir> <baseRefName-or-empty>: a gh stub answering the
# base-branch lookup. An empty second argument makes the lookup FAIL, standing
# in for an unreachable or unauthenticated GitHub.
write_pr_base_gh() {
  local case_dir=$1 base=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" baseRefName "*)
    [ -n '$base' ] || { echo 'mock: base lookup failed' >&2; exit 1; }
    printf '%s\n' '$base'
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_pr_base_case() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$ASSERT_KEPT" task-pb
}

test_pr_base_branch_is_compared_against_the_pr_target() {
  local case_dir out code
  case_dir=$(make_pr_base_case pr-base-nondefault)
  write_pr_base_gh "$case_dir" feature-base

  set +e
  out=$(run_pr_base_case "$case_dir" 2> "$case_dir/stderr")
  code=$?
  set -e

  assert_contains "$out" 'base: origin/feature-base' \
    "pr-base-nondefault: the base must be the branch the PR targets"
  expect_code 1 "$code" \
    "pr-base-nondefault: the assertion dropped from the PR's own base must exit non-zero"
  assert_contains "$out" 'missing: tests/feature.test.sh::feature holds' \
    "pr-base-nondefault: an assertion the PR's base had and the branch dropped must be reported"
  assert_not_contains "$out" 'missing: tests/mainonly.test.sh::mainonly holds' \
    "pr-base-nondefault: an assertion only the DEFAULT branch had must not be reported"
  pass "a PR stacked on a non-default branch is compared against that branch"
}

test_unreadable_pr_base_refuses_rather_than_assuming_default() {
  local case_dir out err code
  case_dir=$(make_pr_base_case pr-base-unreadable)
  write_pr_base_gh "$case_dir" ''

  set +e
  out=$(run_pr_base_case "$case_dir" 2> "$case_dir/stderr")
  code=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 2 "$code" \
    "pr-base-unreadable: an unreadable PR base must refuse as 'cannot verify', not report findings"
  assert_contains "$err" 'https://github.com/o/r/pull/7' \
    "pr-base-unreadable: the refusal must name the PR whose base could not be read"
  assert_not_contains "$out" 'missing:' \
    "pr-base-unreadable: refusing must not produce findings measured against an assumed base"
  assert_not_contains "$out" 'base: origin/main' \
    "pr-base-unreadable: refusing must never fall back to the default branch"
  assert_contains "$err" 'the gh query failed' \
    "pr-base-unreadable: the refusal must classify the cause, not fold every failure into one"
  assert_contains "$err" 'mock: base lookup failed' \
    "pr-base-unreadable: gh's own stderr must reach the operator, not be discarded"
  pass "a recorded PR whose base cannot be read refuses instead of assuming the default branch"
}

test_pr_in_another_github_repo_refuses_before_any_fetch() {
  local case_dir out err code
  case_dir=$(make_pr_base_case pr-base-wrong-repo)
  write_pr_base_gh "$case_dir" feature-base
  # A GitHub origin that is NOT the PR's repository. The fixture then has no
  # fetchable remote at all, which is the point: the assertion must refuse
  # BEFORE either PR-derived fetch, so reaching one would fail differently.
  git -C "$case_dir/project" remote set-url origin \
    https://github.com/someone-else/other-repo.git

  set +e
  out=$(run_pr_base_case "$case_dir" 2> "$case_dir/stderr")
  code=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 2 "$code" \
    "pr-base-wrong-repo: a PR in another GitHub repository must refuse as 'cannot verify'"
  assert_contains "$err" 'lives in o/r' \
    "pr-base-wrong-repo: the refusal must name the PR URL's own owner/repo"
  # "targets" means the PR's BASE BRANCH everywhere else in the script and its
  # header, so the repository sense must never reclaim the word: an operator
  # hitting this merge-blocking refusal would go looking at the wrong thing.
  assert_not_contains "$err" 'targets' \
    "pr-base-wrong-repo: the repository sense must not be spelled 'targets'"
  assert_contains "$err" 'someone-else/other-repo' \
    "pr-base-wrong-repo: the refusal must name origin's owner/repo"
  assert_not_contains "$out" 'missing:' \
    "pr-base-wrong-repo: refusing must not produce findings measured against the wrong repository"
  assert_not_contains "$out" 'base:' \
    "pr-base-wrong-repo: refusing must never name a base resolved from the wrong repository"
  pass "a PR whose repository is not origin's refuses rather than fetching a same-named branch"
}

# The only writer of pr= validates it with this same parser first, so nothing
# reaches this today - which is exactly why it is asserted. This script is the
# last gate before a merge and must not trust an input it cannot identify, and
# a hand-edited meta file is the one route in.
test_unparseable_recorded_pr_refuses_before_any_github_call() {
  local case_dir out err code
  case_dir=$(make_pr_base_case pr-base-unparseable)
  write_pr_base_gh "$case_dir" feature-base
  # Every gh call and every fetch is logged, so "refused BEFORE any of them" is
  # asserted from evidence rather than from the exit code alone.
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$case_dir/net.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*) printf 'git %s\n' "\$*" >> "$case_dir/net.log" ;;
esac
exec $(command -v git) "\$@"
SH
  chmod +x "$case_dir/fakebin/git"
  : > "$case_dir/net.log"
  fm_write_meta "$case_dir/state/task-pb.meta" \
    "window=fm-task-pb" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "pr=https://github.example.com/o/r/pull/7"

  set +e
  out=$(run_pr_base_case "$case_dir" 2> "$case_dir/stderr")
  code=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 2 "$code" \
    "pr-base-unparseable: a recorded pr= that is not a PR link must refuse as 'cannot verify'"
  assert_contains "$err" 'https://github.example.com/o/r/pull/7' \
    "pr-base-unparseable: the refusal must name the value it could not read"
  assert_not_contains "$out" 'missing:' \
    "pr-base-unparseable: refusing must not produce findings measured against an assumed base"
  assert_not_contains "$out" 'base:' \
    "pr-base-unparseable: refusing must never name a base at all"
  [ ! -s "$case_dir/net.log" ] || fail \
    "pr-base-unparseable: refused only after touching the network: $(cat "$case_dir/net.log")"
  pass "a recorded pr= that is not a readable PR link refuses before any gh call or fetch"
}

test_pr_repo_mismatch_refusal_never_leaks_origin_credentials() {
  local case_dir err code
  case_dir=$(make_pr_base_case pr-base-credentialed-origin)
  write_pr_base_gh "$case_dir" feature-base
  # A credentialed remote is a supported GitHub form, so the mismatch IS
  # determinable and must refuse - while bin/fm-pr-merge.sh leaves this script's
  # stderr unredirected, so anything echoed here reaches the merge output and any
  # CI log.
  git -C "$case_dir/project" remote set-url origin \
    https://x-access-token:ghs_notarealtoken@github.com/someone-else/other-repo.git

  set +e
  run_pr_base_case "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  code=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 2 "$code" \
    "pr-base-credentialed-origin: a credentialed origin must still refuse on a mismatch"
  assert_contains "$err" 'someone-else/other-repo' \
    "pr-base-credentialed-origin: the refusal must still name origin's owner/repo"
  assert_not_contains "$err" 'ghs_notarealtoken' \
    "pr-base-credentialed-origin: the refusal must never echo origin's embedded credential"
  assert_not_contains "$err" 'x-access-token' \
    "pr-base-credentialed-origin: the refusal must never echo origin's raw address"
  pass "a mismatch refusal names both repositories without leaking origin's credential"
}

test_task_without_a_pr_still_resolves_the_default_branch() {
  local case_dir out code
  case_dir=$(make_pr_base_case pr-base-absent)
  # No PR recorded: the local-only path, which must keep resolving the default.
  fm_write_meta "$case_dir/state/task-pb.meta" \
    "window=fm-task-pb" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"
  # A gh that fails everything proves the no-PR path never depends on GitHub.
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo 'mock: gh must not be consulted without a recorded PR' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"

  set +e
  out=$(run_pr_base_case "$case_dir" 2> "$case_dir/stderr")
  code=$?
  set -e

  assert_contains "$out" 'base: origin/main (default branch of' \
    "pr-base-absent: with no PR recorded the base must still be the project's default branch"
  expect_code 1 "$code" \
    "pr-base-absent: the default branch's dropped assertion must still exit non-zero"
  assert_contains "$out" 'missing: tests/mainonly.test.sh::mainonly holds' \
    "pr-base-absent: the default branch's own assertions must still be checked"
  pass "a task with no recorded PR still resolves the project's default branch"
}

test_explicit_mode_never_consults_github() {
  local dir out code
  dir=$(make_repo explicit-base-untouched)
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo 'mock: explicit mode must not consult GitHub' >&2
exit 1
SH
  chmod +x "$dir/fakebin/gh"
  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/.state" \
    PATH="$dir/fakebin:$PATH" \
    "$ASSERT_KEPT" --worktree "$dir" --base main --branch work 2>/dev/null)
  code=$?
  set -e

  assert_contains "$out" 'base: main (explicit --base)' \
    "explicit-base-untouched: explicit mode must take the caller's ref verbatim"
  [ "$code" -ne 2 ] \
    || fail "explicit-base-untouched: explicit mode must not fail on a GitHub lookup"
  pass "explicit mode takes the caller's base verbatim and never consults GitHub"
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
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0' \
    "zk-refactor: a fully executed clean tree must report zero in every class"
  pass "a behavior-preserving rewrite of code and test body exits zero"
}

test_unexecutable_files_are_reported_not_passed() {
  local dir out code
  # The baseline corpus's shell test calls an undefined `pass`, so its baseline
  # run is red; its python/js files resolve no runner (no config, no venv, and
  # no package.json). None of that may read as a pass.
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

# --- (ff) the --assume-branch-suite-green identical-file skip ----------------
# The flag lets check 2 skip a base test file the branch's copy matches byte for
# byte, on the premise that the branch's own verified-green suite already ran
# that identical file against that same branch code. These cases hold up all
# four halves of that: the skip happens and is REPORTED, it is off by default,
# it never reaches the cases the gate exists for (a rewritten body, a deleted
# file), and a MOVED file is not mistaken for an identical one.

test_assume_green_reports_an_identical_file_instead_of_running_it() {
  local dir out code
  dir=$(make_zk_repo assume-identical)
  # The test file is left BYTE-IDENTICAL while app.sh changes Z -> K, so main's
  # assertion would FAIL if it were executed. That is what makes non-execution
  # observable at all, and it deliberately falsifies the flag's premise: a real
  # branch in this state has a RED suite, so bin/fm-pr-merge.sh's checks-green
  # gate refuses the merge and the flag is never honestly passed for it. This
  # fixture is the proof of mechanism, and it is exactly why the flag is opt-in
  # rather than the default.
  printf '#!/usr/bin/env bash\necho K\n' > "$dir/app.sh"
  commit_all "$dir" "branch changes app.sh only; the test file is untouched"

  set +e
  out=$(run_explicit "$dir" --assume-branch-suite-green 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "assume-identical: an assumed-covered identifier must not affect the exit code"
  assert_contains "$out" 'assumed-covered: tests/x.test.sh::X behaves' \
    "assume-identical: every identifier in a skipped file must be reported in its own class"
  assert_contains "$out" 'assumed-covered=1' \
    "assume-identical: the summary must count the assumed-covered identifier"
  assert_not_contains "$out" 'failing:' \
    "assume-identical: the identical file must not have been executed at all"
  assert_not_contains "$out" 'unexecuted:' \
    "assume-identical: a deliberately skipped file is accounted for, never unexecuted"
  pass "an identical base test file is reported assumed-covered instead of being run"
}

test_identical_file_is_executed_without_the_premise_flag() {
  local dir out code
  # The SAME tree as the case above. Without the flag nothing is skipped, so
  # main's assertion is executed against the branch's K and reported failing -
  # proving both that the skip is opt-in and that the case above really did
  # decline to run the file rather than running it and finding nothing.
  dir=$(make_zk_repo assume-default-off)
  printf '#!/usr/bin/env bash\necho K\n' > "$dir/app.sh"
  commit_all "$dir" "branch changes app.sh only; the test file is untouched"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "assume-default-off: without the flag the base's assertion must still be run and fail"
  assert_contains "$out" 'failing: tests/x.test.sh::X behaves' \
    "assume-default-off: the default path must execute the identical file exactly as before"
  assert_contains "$out" 'assumed-covered=0' \
    "assume-default-off: nothing may be assumed covered when the caller asserted no premise"
  assert_not_contains "$out" 'assumed-covered: ' \
    "assume-default-off: no identifier may be reported assumed-covered without the flag"
  pass "the identical-file skip is off by default and the run is unchanged"
}

test_assume_green_still_catches_a_rewritten_assertion_body() {
  local dir out code
  dir=$(make_zk_repo assume-rewrite)
  # The motivating scenario: the resolver takes K's side in BOTH files, so the
  # name survives check 1 and the test file DIFFERS from main's. A differing
  # file is never identical, so the flag must not reach it.
  write_zk_tree "$dir" K K
  commit_all "$dir" "resolver takes K in both app.sh and test"

  set +e
  out=$(run_explicit "$dir" --assume-branch-suite-green 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "assume-rewrite: a rewritten assertion body must still exit non-zero under the flag"
  assert_contains "$out" 'failing: tests/x.test.sh::X behaves' \
    "assume-rewrite: the flag must not stop check 2 catching a rewritten assertion body"
  assert_contains "$out" 'assumed-covered=0' \
    "assume-rewrite: a file whose content differs is never assumed covered"
  pass "a rewritten assertion body is still caught under --assume-branch-suite-green"
}

test_assume_green_still_catches_a_deleted_base_test_file() {
  local dir out code
  dir=$(make_zk_repo assume-delete)
  git -C "$dir" rm -q tests/x.test.sh
  git -C "$dir" commit -qm "branch deletes main's test file"

  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"
  set +e
  # The flag TRAILS the positional arguments here rather than going through
  # run_explicit, holding up the contract that it is accepted in any argument
  # position rather than in one blessed slot.
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/.state" \
    "$ASSERT_KEPT" --worktree "$dir" --base main --branch work \
    --assume-branch-suite-green 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "assume-delete: a deleted base test file must still exit non-zero under the flag"
  assert_contains "$out" 'missing: tests/x.test.sh::X behaves' \
    "assume-delete: check 1 must still report the deleted assertion"
  assert_contains "$out" 'assumed-covered=0' \
    "assume-delete: a file the branch does not hold at all is never assumed covered"
  pass "a deleted base test file is still caught under --assume-branch-suite-green"
}

test_assume_green_does_not_treat_a_moved_file_as_identical() {
  local dir out code
  dir=$(make_zk_repo assume-move)
  # Identical CONTENT at a different path. Identity is the blob at the SAME
  # path, so this is a delete plus an add and main's path has no branch copy
  # whose run could stand in for it.
  git -C "$dir" mv tests/x.test.sh tests/y.test.sh
  git -C "$dir" commit -qm "branch moves the test file, content unchanged"

  set +e
  out=$(run_explicit "$dir" --assume-branch-suite-green 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "assume-move: a moved test file is still the documented check 1 report"
  assert_contains "$out" 'missing: tests/x.test.sh::X behaves' \
    "assume-move: check 1 must still report the identifier at its old path"
  assert_not_contains "$out" 'assumed-covered: ' \
    "assume-move: identical content at a DIFFERENT path must never be assumed covered"
  assert_contains "$out" 'assumed-covered=0' \
    "assume-move: the summary must show nothing was assumed covered"
  pass "a moved base test file is not mistaken for an identical one"
}

# --- pytest fixtures --------------------------------------------------------

# The provisioned environment the Python fixtures link in, exactly as a
# pipeline-provisioned worktree's .venv is linked at the real gate. Built once
# and shared, so the per-case cost is a symlink. $PYTEST_VERSION and
# $PYTEST_VENV are set with the other pins under "the shared pinned-runtime
# cache" at the top of this file; that is also where the key rule and the
# coverage trade are recorded.
PYTEST_VENV_READY=0

# pytest_venv_usable <venv>: the venv exists AND resolves the PINNED pytest.
# Version-checking, not presence-checking: `-m pytest --version` passes for ANY
# pytest, so a venv built with --system-site-packages against whatever the host
# happens to carry would sail through while serving a version the directory name
# promises it is not. A mismatch is a cache miss, so the pin is what the cases
# actually run.
pytest_venv_usable() {
  [ -x "$1/bin/python" ] || return 1
  [ "$("$1/bin/python" -c 'import pytest; print(pytest.__version__)' 2>/dev/null)" \
    = "$PYTEST_VERSION" ]
}

# ensure_pytest_venv: build $PYTEST_VENV if absent or unusable. Returns non-zero
# when the host cannot provide the pinned pytest, so the caller fails loudly
# instead of silently dropping the coverage that proves assertions really
# execute, and never falls back to some other version.
#
# A cached venv is verified once per run rather than trusted on the strength of
# its interpreter existing: it may have been built with --system-site-packages
# against a host pytest that has since gone away or been upgraded past the pin.
# An unusable one is rebuilt, never patched around.
ensure_pytest_venv() {
  local staging
  if [ "$PYTEST_VENV_READY" = 1 ]; then
    return 0
  fi
  if pytest_venv_usable "$PYTEST_VENV"; then
    PYTEST_VENV_READY=1
    return 0
  fi
  mkdir -p "$(dirname "$PYTEST_VENV")" 2>/dev/null || return 1
  # mktemp creates the directory; `venv` re-uses an existing empty one, so the
  # name stays claimed for the whole build and no second process can take it.
  staging=$(mktemp -d "$PYTEST_VENV.build.XXXXXX" 2>/dev/null) || return 1
  if [ "$(python3 -c 'import pytest; print(pytest.__version__)' 2>/dev/null)" = "$PYTEST_VERSION" ]; then
    # The host already carries EXACTLY the pin: reuse it and stay off the
    # network. Gated on the version, never on bare importability - borrowing
    # whatever pytest the host has would quietly defeat the pin.
    python3 -m venv --system-site-packages "$staging" >/dev/null 2>&1 || { rm -rf "$staging"; return 1; }
  else
    python3 -m venv "$staging" >/dev/null 2>&1 || { rm -rf "$staging"; return 1; }
    "$staging/bin/python" -m pip install --quiet --disable-pip-version-check "pytest==$PYTEST_VERSION" \
      >/dev/null 2>&1 || { rm -rf "$staging"; return 1; }
  fi
  pytest_venv_usable "$staging" || { rm -rf "$staging"; return 1; }
  relocate_venv_paths "$staging" "$PYTEST_VENV" || { rm -rf "$staging"; return 1; }
  # Another shard may have published a good venv while this one was building,
  # and the fixtures symlink their .venv straight at it - removing it here would
  # pull a live interpreter out from under a case that is already running. So
  # re-probe first and, if the published tree is now good, throw away THIS build
  # rather than the tree in use. Only a still-unusable predecessor is dropped,
  # and only once the replacement is built and proven.
  if pytest_venv_usable "$PYTEST_VENV"; then
    rm -rf "$staging"
    PYTEST_VENV_READY=1
    return 0
  fi
  if [ -e "$PYTEST_VENV" ]; then
    rm -rf "$PYTEST_VENV"
  fi
  publish_env "$staging" "$PYTEST_VENV" || return 1
  pytest_venv_usable "$PYTEST_VENV" || return 1
  PYTEST_VENV_READY=1
}

require_pytest_venv() {
  ensure_pytest_venv || fail "$1: could not provision a venv with pytest==$PYTEST_VERSION (needs python3 with venv, plus a pip able to install that exact version - so an interpreter that version still supports, and network or a matching cached wheel; an importable host pytest skips the install only when it is already exactly $PYTEST_VERSION); the pytest runner cannot be verified without one"
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
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0' \
    "pytest-clean: a real pytest run must report zero in every class, proving it executed and accounted for its identifier"
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
#
# The borrowed directory is where pytest ACTUALLY lives under the shared venv's
# interpreter, not that venv's sysconfig purelib: ensure_pytest_venv builds the
# shared venv with --system-site-packages whenever the host already has pytest,
# and in that branch its own purelib is EMPTY, so borrowing it would hand the
# case venv a directory containing nothing. That failure is invisible on a host
# without pytest, and on a host with one it silently degrades the cases below to
# "no supported test runner resolves", which is not what they claim to test - so
# the borrow is asserted to work before any case relies on it.
link_borrowed_pytest_venv() {
  local dir=$1 extra=$2 site shared_site
  python3 -m venv "$dir/.venv" >/dev/null 2>&1 \
    || fail "could not create the case's own venv at $dir/.venv"
  site=$("$dir/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
  shared_site=$("$PYTEST_VENV/bin/python" \
    -c 'import os, pytest; print(os.path.dirname(os.path.dirname(os.path.abspath(pytest.__file__))))') \
    || fail "could not locate pytest under the shared venv at $PYTEST_VENV"
  printf '%s\n' "$shared_site" > "$site/borrow-pytest.pth"
  printf '%s\n' "$extra" > "$site/__editable__.demo.pth"
  "$dir/.venv/bin/python" -m pytest --version >/dev/null 2>&1 \
    || fail "the case venv at $dir/.venv cannot run pytest borrowed from $shared_site"
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

# write_py_helper_tree <dir> <behavior>: pkg.mod.greet() returns <behavior>, and
# tests/test_mod.py asserts it against a constant held in a SIBLING helper module
# imported by bare name. That is the prepend-mode layout --import-mode=importlib
# does not put on sys.path by itself, so this tree only collects because the test
# file's own directory (inside the scratch tree) is a PYTHONPATH root.
write_py_helper_tree() {
  local dir=$1 behavior=$2
  mkdir -p "$dir/pkg" "$dir/tests"
  cat > "$dir/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
addopts = "--cov=pkg --cov-fail-under=100"
EOF
  printf '.venv/\n' > "$dir/.gitignore"
  : > "$dir/pkg/__init__.py"
  printf 'def greet():\n    return "%s"\n' "$behavior" > "$dir/pkg/mod.py"
  printf 'EXPECTED = "Z"\n' > "$dir/tests/helpers.py"
  cat > "$dir/tests/test_mod.py" <<'EOF'
from helpers import EXPECTED
from pkg.mod import greet


def test_x_behaves():
    assert greet() == EXPECTED
EOF
}

test_pytest_sibling_helper_layout_executes() {
  local dir out code
  require_pytest_venv pytest-helper
  dir="$TMP_ROOT/pytest-helper"
  mkdir -p "$dir"
  git init -q -b main "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b main
  }
  write_py_helper_tree "$dir" Z
  commit_all "$dir" "main: greet returns Z, the test asserts it via a sibling helper"
  git -C "$dir" checkout -q -b work
  ln -s "$PYTEST_VENV" "$dir/.venv"
  # Only the behavior changes; the helper's constant is untouched, so the base's
  # own test file run against the branch's code must fail.
  printf 'def greet():\n    return "K"\n' > "$dir/pkg/mod.py"
  commit_all "$dir" "branch: greet returns K"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "pytest-helper: the changed behavior must be caught"
  # A `failing:` verdict at all proves the baseline collected and ran, which is
  # only possible when the sibling helper resolved.
  assert_contains "$out" 'failing: tests/test_mod.py::test_x_behaves' \
    "pytest-helper: a sibling-helper layout must execute, not be reported unexecuted"
  assert_not_contains "$out" 'unexecuted:' \
    "pytest-helper: importlib mode must not strand a tests/ dir of helper modules"
  assert_not_contains "$out" 'missing:' \
    "pytest-helper: the test name survived, so check 1 must stay silent"
  pass "a test importing a sibling helper by bare name still executes under importlib mode"
}

test_run_never_mutates_the_live_worktree() {
  local dir before after venv_before venv_after
  require_pytest_venv no-mutation
  dir=$(make_py_repo no-mutation)
  ln -s "$PYTEST_VENV" "$dir/.venv"
  before="$TMP_ROOT/no-mutation.before"
  after="$TMP_ROOT/no-mutation.after"
  venv_before="$TMP_ROOT/no-mutation.venv-before"
  venv_after="$TMP_ROOT/no-mutation.venv-after"
  # run_explicit puts this harness's own state dir inside the fixture, so create
  # it up front: the snapshot must isolate what the RUN does to the worktree.
  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"
  # find does not traverse the .venv symlink, so this covers the tracked tree
  # and would catch a stray __pycache__, .pytest_cache, or scratch leak.
  find "$dir" -path "$dir/.git" -prune -o -print | sort > "$before"
  # The linked env is the LIVE shared venv, and `find` above deliberately stops
  # at the symlink, so the tree snapshot alone cannot see a write INTO it: a
  # plugin regenerating a .pth or a datafile landing at a sysconfig path would be
  # invisible. Snapshot the env itself so that class of mutation can actually
  # fail this case.
  find "$PYTEST_VENV" | sort > "$venv_before"

  set +e
  run_explicit "$dir" > /dev/null 2>&1
  set -e

  find "$dir" -path "$dir/.git" -prune -o -print | sort > "$after"
  diff -u "$before" "$after" > "$TMP_ROOT/no-mutation.diff" \
    || fail "no-mutation: the run must not add or remove anything in the live worktree"$'\n'"$(cat "$TMP_ROOT/no-mutation.diff")"
  find "$PYTEST_VENV" | sort > "$venv_after"
  diff -u "$venv_before" "$venv_after" > "$TMP_ROOT/no-mutation.venv-diff" \
    || fail "no-mutation: the run must not write into the provisioned environment it borrows"$'\n'"$(cat "$TMP_ROOT/no-mutation.venv-diff")"
  pass "a check-2 run never mutates the live worktree"
}

# --- accounting fixtures: a green run that verified less than it was asked to --

# init_repo_at <dir>: an empty repo on main, for fixtures that write their own
# tree rather than one of the shared corpora. Echoes nothing.
init_repo_at() {
  local dir=$1
  mkdir -p "$dir"
  git init -q -b main "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b main
  }
}

# write_py_accounting_tree <dir> <test-body> [<conftest-body>]: a minimal pytest
# tree whose repo addopts is the same uninstalled coverage gate the other Python
# fixtures use, so a run that failed to neutralize addopts errors out loudly
# instead of quietly reporting one of the accounting classes under test.
write_py_accounting_tree() {
  local dir=$1 test_body=$2 conftest_body=${3:-}
  mkdir -p "$dir"
  cat > "$dir/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
addopts = "--cov=pkg --cov-fail-under=100"
EOF
  printf '.venv/\n' > "$dir/.gitignore"
  printf '%s' "$test_body" > "$dir/test_mod.py"
  if [ -n "$conftest_body" ]; then
    printf '%s' "$conftest_body" > "$dir/conftest.py"
  fi
}

test_pytest_all_skipped_is_visible_not_a_silent_pass() {
  local dir out code
  require_pytest_venv pytest-all-skipped
  dir="$TMP_ROOT/pytest-all-skipped"
  init_repo_at "$dir"
  write_py_accounting_tree "$dir" 'import pytest


@pytest.mark.skip(reason="not runnable in this environment")
def test_x_behaves():
    assert False


@pytest.mark.skip(reason="not runnable in this environment")
def test_y_behaves():
    assert False
'
  commit_all "$dir" "main: every test carries an explicit skip"
  git -C "$dir" checkout -q -b work
  ln -s "$PYTEST_VENV" "$dir/.venv"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-all-skipped: a skip-only run must not become a new merge-refusing condition"
  assert_contains "$out" 'skipped: test_mod.py::test_x_behaves' \
    "pytest-all-skipped: an explicitly skipped identifier must be reported by name"
  assert_contains "$out" 'skipped: test_mod.py::test_y_behaves' \
    "pytest-all-skipped: every skipped identifier must be reported, not just the first"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=2 unaccounted=0' \
    "pytest-all-skipped: a green run that verified nothing must not read as a clean pass"
  assert_not_contains "$out" 'unexecuted:' \
    "pytest-all-skipped: an explicit skip is accounted for, so it is not unexecuted"
  assert_not_contains "$out" 'unaccounted:' \
    "pytest-all-skipped: a reported skip IS a result, so nothing here is unaccounted"
  pass "a pytest file whose tests are all skipped is reported per identifier, not silently passed"
}

test_pytest_partially_run_file_reports_the_unrun_identifier() {
  local dir out code
  require_pytest_venv pytest-partial
  dir="$TMP_ROOT/pytest-partial"
  init_repo_at "$dir"
  # A deselecting conftest, the ordinary way a suite drops a case at collection:
  # the run still exits green, but produces no result at all for test_b.
  write_py_accounting_tree "$dir" 'def test_a():
    assert True


def test_b():
    assert True
' 'def pytest_collection_modifyitems(config, items):
    dropped = [item for item in items if item.name == "test_b"]
    if dropped:
        config.hook.pytest_deselected(items=dropped)
        items[:] = [item for item in items if item.name != "test_b"]
'
  commit_all "$dir" "main: two tests, one deselected at collection"
  git -C "$dir" checkout -q -b work
  ln -s "$PYTEST_VENV" "$dir/.venv"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-partial: reporting an unaccounted identifier must not change the exit code"
  assert_contains "$out" 'unaccounted: test_mod.py::test_b' \
    "pytest-partial: an identifier the run produced no result for must not be counted as verified"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=1' \
    "pytest-partial: only the unrun identifier is unaccounted; the one that ran is not"
  assert_not_contains "$out" 'unaccounted: test_mod.py::test_a' \
    "pytest-partial: an identifier that really ran must stay out of the unaccounted class"
  pass "a partially-run pytest file reports the identifier that produced no result"
}

test_pytest_unreadable_report_is_unaccounted_not_a_pass() {
  local dir out code
  require_pytest_venv pytest-bad-report
  dir="$TMP_ROOT/pytest-bad-report"
  init_repo_at "$dir"
  # pytest_unconfigure runs after the junitxml plugin has written its report, so
  # this leaves a green run whose results file cannot be parsed at all.
  write_py_accounting_tree "$dir" 'def test_a():
    assert True
' 'def pytest_unconfigure(config):
    path = getattr(config.option, "xmlpath", None)
    if not path:
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("<<< this is not a parseable report")
'
  commit_all "$dir" "main: a green run whose report is unreadable"
  git -C "$dir" checkout -q -b work
  ln -s "$PYTEST_VENV" "$dir/.venv"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-bad-report: an unreadable report must not become a new merge-refusing condition"
  assert_contains "$out" 'unaccounted: test_mod.py::test_a' \
    "pytest-bad-report: a report that cannot be read verifies nothing, so its identifiers are unaccounted"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=1' \
    "pytest-bad-report: the summary must count the unaccounted identifier"
  assert_not_contains "$out" 'unexecuted:' \
    "pytest-bad-report: this PR maps an unreadable report to unaccounted, deliberately not to unexecuted"
  pass "a pytest file whose results report cannot be read reports unaccounted and still exits zero"
}

# make_py_accounting_repo <name> <test-body> [<conftest-body>]: an accounting
# fixture committed on main with a work branch checked out and the shared venv
# linked in. Echoes the dir.
make_py_accounting_repo() {
  local dir="$TMP_ROOT/$1"
  init_repo_at "$dir"
  write_py_accounting_tree "$dir" "$2" "${3:-}"
  commit_all "$dir" "main: $1"
  git -C "$dir" checkout -q -b work
  ln -s "$PYTEST_VENV" "$dir/.venv"
  printf '%s\n' "$dir"
}

test_parametrized_green_test_is_not_unaccounted() {
  local dir out code
  require_pytest_venv pytest-parametrized
  # check 1 requests the bare nodeid `test_x`; pytest ACCEPTS it, runs both cases
  # green, and reports them as `test_x[1]` / `test_x[2]`. Reading that as "no
  # result" would make the class say the opposite of the truth for the most
  # common pytest idiom.
  dir=$(make_py_accounting_repo pytest-parametrized 'import pytest


@pytest.mark.parametrize("v", [1, 2])
def test_x(v):
    assert v > 0
')

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-parametrized: a green parametrized test must exit zero"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0' \
    "pytest-parametrized: a bare name the runner reports only as parametrized cases is still accounted for"
  assert_not_contains "$out" 'unaccounted:' \
    "pytest-parametrized: a test that fully ran must never be reported as producing no result"
  pass "a parametrized test that runs green is accounted for, not reported unaccounted"
}

test_parametrized_all_skipped_is_skipped_not_unaccounted() {
  local dir out code
  require_pytest_venv pytest-param-skipped
  dir=$(make_py_accounting_repo pytest-param-skipped 'import pytest


@pytest.mark.skip(reason="not runnable in this environment")
@pytest.mark.parametrize("v", [1, 2])
def test_x(v):
    assert False
')

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-param-skipped: a skip-only run must still exit zero"
  assert_contains "$out" 'skipped: test_mod.py::test_x' \
    "pytest-param-skipped: an explicit skip reported only under parametrized names is still a skip"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=1 unaccounted=0' \
    "pytest-param-skipped: the same reconciliation rule must apply to the skipped set"
  assert_not_contains "$out" 'unaccounted:' \
    "pytest-param-skipped: a reported skip IS a result, so it is not unaccounted"
  pass "an all-skipped parametrized test is reported skipped, not unaccounted"
}

test_parametrized_one_passing_case_counts_as_passing() {
  local dir out code
  require_pytest_venv pytest-param-mixed
  # One case runs green, the other is explicitly skipped. Passing wins: the
  # baseline did verify this name, so it is neither skipped nor unaccounted.
  dir=$(make_py_accounting_repo pytest-param-mixed 'import pytest


@pytest.mark.parametrize(
    "v",
    [1, pytest.param(2, marks=pytest.mark.skip(reason="one case only"))],
)
def test_x(v):
    assert v > 0
')

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-param-mixed: a partly skipped parametrized test must exit zero"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0' \
    "pytest-param-mixed: one passing case means the name was verified, so passing outranks skipped"
  assert_not_contains "$out" 'skipped:' \
    "pytest-param-mixed: a name with a passing case must not be reported skipped"
  pass "a parametrized test with at least one passing case counts as passing"
}

test_parametrized_near_name_does_not_cross_match() {
  local dir out code
  require_pytest_venv pytest-param-nearname
  # test_xy's parametrized names begin with the string `test_x`, so a bare prefix
  # test would let them account for test_x, which produced no result at all.
  dir=$(make_py_accounting_repo pytest-param-nearname 'import pytest


@pytest.mark.parametrize("v", [1, 2])
def test_xy(v):
    assert v > 0


def test_x():
    assert True
' 'def pytest_collection_modifyitems(config, items):
    dropped = [item for item in items if item.name == "test_x"]
    if dropped:
        config.hook.pytest_deselected(items=dropped)
        items[:] = [item for item in items if item.name != "test_x"]
')

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "pytest-param-nearname: reporting an unaccounted identifier must not change the exit code"
  assert_contains "$out" 'unaccounted: test_mod.py::test_x' \
    "pytest-param-nearname: test_xy[1] must not account for a requested test_x"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=1' \
    "pytest-param-nearname: only the name that really produced no result is unaccounted"
  assert_not_contains "$out" 'unaccounted: test_mod.py::test_xy' \
    "pytest-param-nearname: the parametrized name that did run must stay accounted for"
  pass "a near-name pair does not cross-match: the bracket must follow the name immediately"
}

test_shell_name_that_never_ran_is_unaccounted() {
  local dir out code
  dir="$TMP_ROOT/shell-unaccounted"
  init_repo_at "$dir"
  mkdir -p "$dir/tests"
  cat > "$dir/tests/x.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "always runs"
if [ -n "${FM_NEVER_SET:-}" ]; then
  pass "conditional case"
fi
EOF
  commit_all "$dir" "main: one assertion the file's own guard never reaches"
  git -C "$dir" checkout -q -b work

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "shell-unaccounted: the TAP protocol and its green-exit trust rule are unchanged"
  assert_contains "$out" 'unaccounted: tests/x.test.sh::conditional case' \
    "shell-unaccounted: a name the run never emitted 'ok - ' for was not verified"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=1' \
    "shell-unaccounted: the shell runner has no skip marker, so an unrun name is unaccounted, never skipped"
  assert_not_contains "$out" 'unaccounted: tests/x.test.sh::always runs' \
    "shell-unaccounted: the assertion that did run must not be reported"
  pass "a shell assertion that never emitted 'ok - ' is reported unaccounted, not passed"
}

# --- vitest / jest fixtures --------------------------------------------------

# The provisioned environments the JS fixtures link in, exactly as a
# pipeline-provisioned worktree's node_modules is linked at the real gate.
# Built by a real `npm install` at $VITEST_VERSION / $JEST_VERSION and shared,
# so the per-case cost is a symlink. The install needs node, npm, and network or
# a warm npm cache; CI provides all three, and the suite is self-contained with
# no workflow-side installs.
#
# The pinned version is part of the cache directory's NAME, so bumping a version
# names a directory that does not exist yet and gets a fresh install; a tree
# installed against the old pin can never be served for the new one.
# $VITEST_VERSION / $JEST_VERSION and the directories they key are set with the
# other pins under "the shared pinned-runtime cache" at the top of this file;
# bump a pin there and nowhere else.

# ensure_js_env <env-dir> <package> <version> <bin>: build the shared env if
# absent. Returns non-zero when the host cannot provide it, so the caller fails
# loudly instead of silently dropping the coverage that proves JS assertions
# really execute.
#
# Installed under a private staging path and published with one rename, so a
# concurrent shard either finds no environment and installs its own or finds a
# complete one, and never links a half-installed node_modules into a fixture.
# Unlike a venv, an npm tree bakes in no absolute paths - `node_modules/.bin`
# entries are relative symlinks - so it survives the rename untouched.
ensure_js_env() {
  local env=$1 pkg=$2 version=$3 bin=$4 staging
  if [ -x "$env/node_modules/.bin/$bin" ]; then
    return 0
  fi
  command -v node >/dev/null 2>&1 || return 1
  command -v npm >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$env")" 2>/dev/null || return 1
  staging=$(mktemp -d "$env.build.XXXXXX" 2>/dev/null) || return 1
  printf '{"name":"fm-%s-env","private":true,"devDependencies":{"%s":"%s"}}\n' \
    "$pkg" "$pkg" "$version" > "$staging/package.json"
  if ! npm install --prefix "$staging" --no-audit --no-fund --loglevel=error \
      >/dev/null 2>&1 || [ ! -x "$staging/node_modules/.bin/$bin" ]; then
    rm -rf "$staging"
    return 1
  fi
  publish_env "$staging" "$env" || return 1
  [ -x "$env/node_modules/.bin/$bin" ]
}

require_vitest_env() {
  ensure_js_env "$VITEST_ENV" vitest "$VITEST_VERSION" vitest \
    || fail "$1: could not provision a node_modules with vitest (needs node and npm, plus network or a warm npm cache); the vitest runner cannot be verified without one"
}

require_jest_env() {
  ensure_js_env "$JEST_ENV" jest "$JEST_VERSION" jest \
    || fail "$1: could not provision a node_modules with jest (needs node and npm, plus network or a warm npm cache); the jest runner cannot be verified without one"
}

# write_js_tree <dir> <runner> <behavior> <asserted>: the plan's Z/K worked
# example in JS - src/mod.js's greet() returns <behavior> and mod.test.js
# asserts <asserted> inside a describe block, so check 1 enumerates the
# describe title and the it title as separate names while the runner reports
# one composed `greet > x behaves` title. vitest gets an ESM tree, jest a CJS
# tree it runs with zero config.
write_js_tree() {
  local dir=$1 runner=$2 behavior=$3 asserted=$4
  mkdir -p "$dir/src"
  if [ "$runner" = vitest ]; then
    cat > "$dir/package.json" <<EOF
{"name":"fixture","private":true,"type":"module","devDependencies":{"vitest":"$VITEST_VERSION"}}
EOF
    printf 'export function greet() {\n  return "%s";\n}\n' "$behavior" > "$dir/src/mod.js"
    cat > "$dir/mod.test.js" <<EOF
import { describe, it, expect } from 'vitest';
import { greet } from './src/mod.js';

describe('greet', () => {
  it('x behaves', () => {
    expect(greet()).toBe('$asserted');
  });
});
EOF
  else
    cat > "$dir/package.json" <<EOF
{"name":"fixture","private":true,"devDependencies":{"jest":"$JEST_VERSION"}}
EOF
    printf 'module.exports.greet = function greet() {\n  return "%s";\n};\n' "$behavior" > "$dir/src/mod.js"
    cat > "$dir/mod.test.js" <<EOF
const { greet } = require('./src/mod.js');

describe('greet', () => {
  it('x behaves', () => {
    expect(greet()).toBe('$asserted');
  });
});
EOF
  fi
  printf 'node_modules/\n' > "$dir/.gitignore"
}

# make_js_repo <name> <runner>: main has greet returning Z and the composed
# test asserting Z, with a work branch checked out. Echoes dir. The caller
# links the provisioned env itself, so the no-node_modules case can skip it.
make_js_repo() {
  local dir="$TMP_ROOT/$1"
  init_repo_at "$dir"
  write_js_tree "$dir" "$2" Z Z
  commit_all "$dir" "main: greet returns Z, test asserts Z"
  git -C "$dir" checkout -q -b work
  printf '%s\n' "$dir"
}

test_vitest_clean_run_exits_zero() {
  local dir out code
  require_vitest_env vitest-clean
  dir=$(make_js_repo vitest-clean vitest)
  ln -s "$VITEST_ENV/node_modules" "$dir/node_modules"
  # A legitimate refactor: internals change, the behavior main asserted holds.
  printf 'export function greet() {\n  const value = "Z";\n  return value;\n}\n' > "$dir/src/mod.js"
  commit_all "$dir" "refactor greet, behavior preserved"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "vitest-clean: the base's JS assertion still passes, so exit must be zero"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0' \
    "vitest-clean: a real vitest run must report zero in every class, proving the describe and it names were both accounted against the composed title"
  assert_not_contains "$out" 'unexecuted:' \
    "vitest-clean: the JS file must be executed, not name-checked"
  pass "a vitest base test that passes against the branch exits zero"
}

test_vitest_rewritten_assertion_caught() {
  local dir out code
  require_vitest_env vitest-rewrite
  dir=$(make_js_repo vitest-rewrite vitest)
  ln -s "$VITEST_ENV/node_modules" "$dir/node_modules"
  # The resolver takes K's side in BOTH files: greet returns K and the test
  # keeps its name but asserts K. Check 1 sees the same names on both sides.
  write_js_tree "$dir" vitest K K
  commit_all "$dir" "resolver takes K in both src/mod.js and the test"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "vitest-rewrite: a rewritten JS assertion body must exit non-zero"
  assert_contains "$out" 'failing: mod.test.js::greet > x behaves' \
    "vitest-rewrite: check 2 must report main's assertion as failing under the runner's composed title"
  assert_not_contains "$out" 'missing:' \
    "vitest-rewrite: check 1 must NOT flag anything (the names survived), proving check 2 caught it"
  assert_not_contains "$out" 'unexecuted:' \
    "vitest-rewrite: the verdict must come from a real run, not a fallback"
  pass "a rewritten vitest assertion body is caught by check 2 where check 1 passes"
}

test_vitest_without_node_modules_is_unexecuted() {
  local dir out code
  # package.json signals vitest, but no node_modules is linked, so no binary
  # resolves from the worktree.
  dir=$(make_js_repo vitest-no-nm vitest)

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "vitest-no-nm: a missing node_modules must not be a silent pass"
  assert_contains "$out" 'unexecuted: mod.test.js::greet' \
    "vitest-no-nm: the describe identifier must be reported as unexecuted"
  assert_contains "$out" 'unexecuted: mod.test.js::x behaves' \
    "vitest-no-nm: the it identifier must be reported as unexecuted"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=2' \
    "vitest-no-nm: the summary must count both identifiers as unexecuted"
  assert_grep 'UNEXECUTED: mod.test.js' "$dir/stderr" \
    "vitest-no-nm: the reason the file could not be executed must be on stderr"
  pass "a vitest test with no node_modules is reported unexecuted, not passed"
}

test_js_workspace_link_is_unexecuted() {
  local dir out code
  require_vitest_env js-workspace-shadow
  # A workspace-style layout: node_modules is a real dir whose .bin borrows the
  # shared vitest, plus a package symlink pointing at first-party source INSIDE
  # the live worktree - the JS analogue of an editable install. A bare
  # specifier import would load the live tree while we believe we are testing
  # scratch, so no verdict may be produced at all.
  dir=$(make_js_repo js-workspace-shadow vitest)
  mkdir -p "$dir/node_modules/.bin" "$dir/packages/mylib"
  printf 'export const X = 1;\n' > "$dir/packages/mylib/index.js"
  ln -s "$VITEST_ENV/node_modules/.bin/vitest" "$dir/node_modules/.bin/vitest"
  ln -s "$dir/packages/mylib" "$dir/node_modules/mylib"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "js-workspace-shadow: an unauthoritative scratch tree must not be a silent pass"
  assert_contains "$out" 'unexecuted: mod.test.js::x behaves' \
    "js-workspace-shadow: a tree that cannot be proven authoritative must be reported unexecuted"
  assert_not_contains "$out" 'failing:' \
    "js-workspace-shadow: an untrusted tree yields no verdict at all, neither pass nor fail"
  assert_grep 'first-party code in the live worktree' "$dir/stderr" \
    "js-workspace-shadow: the reason must name the live-tree link so it is actionable"
  assert_grep 'mylib' "$dir/stderr" \
    "js-workspace-shadow: the reason must name the linked package"
  pass "a workspace-style link into live first-party source is reported unexecuted, never passed"
}

test_js_self_link_to_worktree_root_is_unexecuted() {
  local dir out code
  require_vitest_env js-root-shadow
  # `npm install file:.` / `npm link` of the ROOT package (a common trick for
  # absolute first-party imports) leaves node_modules/<self> -> .., which
  # resolves to exactly the worktree root rather than a path beneath it. A bare
  # `import ... from 'fixture'` would load the LIVE tree, so the root itself
  # must be untrusted, not just paths under it.
  dir=$(make_js_repo js-root-shadow vitest)
  mkdir -p "$dir/node_modules/.bin"
  ln -s "$VITEST_ENV/node_modules/.bin/vitest" "$dir/node_modules/.bin/vitest"
  ln -s .. "$dir/node_modules/fixture"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "js-root-shadow: a self-linked root package must not be a silent pass"
  assert_contains "$out" 'unexecuted: mod.test.js::x behaves' \
    "js-root-shadow: a tree whose node_modules links back to the worktree root must be reported unexecuted"
  assert_not_contains "$out" 'failing:' \
    "js-root-shadow: an untrusted tree yields no verdict at all, neither pass nor fail"
  assert_grep 'first-party code in the live worktree' "$dir/stderr" \
    "js-root-shadow: the reason must name the live-tree link so it is actionable"
  assert_grep 'fixture' "$dir/stderr" \
    "js-root-shadow: the reason must name the self-linked package"
  pass "a node_modules entry linking to the worktree root itself is reported unexecuted, never passed"
}

test_jest_clean_run_exits_zero() {
  local dir out code
  require_jest_env jest-clean
  dir=$(make_js_repo jest-clean jest)
  ln -s "$JEST_ENV/node_modules" "$dir/node_modules"
  printf 'module.exports.greet = function greet() {\n  const value = "Z";\n  return value;\n};\n' > "$dir/src/mod.js"
  commit_all "$dir" "refactor greet, behavior preserved"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "jest-clean: the base's JS assertion still passes, so exit must be zero"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0' \
    "jest-clean: a real jest run must report zero in every class"
  pass "a jest base test that passes against the branch exits zero"
}

test_jest_rewritten_assertion_caught() {
  local dir out code
  require_jest_env jest-rewrite
  dir=$(make_js_repo jest-rewrite jest)
  ln -s "$JEST_ENV/node_modules" "$dir/node_modules"
  write_js_tree "$dir" jest K K
  commit_all "$dir" "resolver takes K in both src/mod.js and the test"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "jest-rewrite: a rewritten JS assertion body must exit non-zero"
  assert_contains "$out" 'failing: mod.test.js::greet > x behaves' \
    "jest-rewrite: check 2 must report main's assertion as failing under the composed title"
  assert_not_contains "$out" 'missing:' \
    "jest-rewrite: check 1 must NOT flag anything (the names survived), proving check 2 caught it"
  assert_not_contains "$out" 'unexecuted:' \
    "jest-rewrite: the verdict must come from a real run, not a fallback"
  pass "a rewritten jest assertion body is caught by check 2 where check 1 passes"
}

test_jest_explicit_skip_is_visible() {
  local dir out code
  require_jest_env jest-skip
  dir="$TMP_ROOT/jest-skip"
  init_repo_at "$dir"
  mkdir -p "$dir/src"
  cat > "$dir/package.json" <<EOF
{"name":"fixture","private":true,"devDependencies":{"jest":"$JEST_VERSION"}}
EOF
  printf 'node_modules/\n' > "$dir/.gitignore"
  cat > "$dir/mod.test.js" <<'EOF'
it.skip('x behaves', () => {
  expect(false).toBe(true);
});
EOF
  commit_all "$dir" "main: the only test carries an explicit skip"
  git -C "$dir" checkout -q -b work
  ln -s "$JEST_ENV/node_modules" "$dir/node_modules"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "jest-skip: a skip-only run must not become a merge-refusing condition"
  assert_contains "$out" 'skipped: mod.test.js::x behaves' \
    "jest-skip: jest's pending status must be read as an explicit skip and reported by name"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=1 unaccounted=0' \
    "jest-skip: a green run that verified nothing must not read as a clean pass"
  assert_not_contains "$out" 'unaccounted:' \
    "jest-skip: a reported skip IS a result, so nothing here is unaccounted"
  pass "a jest test whose only assertion is explicitly skipped is reported skipped, not passed"
}

test_js_run_never_mutates_the_live_worktree() {
  local dir before after nm_before nm_after marker touched
  require_vitest_env js-no-mutation
  dir=$(make_js_repo js-no-mutation vitest)
  ln -s "$VITEST_ENV/node_modules" "$dir/node_modules"
  before="$TMP_ROOT/js-no-mutation.before"
  after="$TMP_ROOT/js-no-mutation.after"
  nm_before="$TMP_ROOT/js-no-mutation.nm-before"
  nm_after="$TMP_ROOT/js-no-mutation.nm-after"
  marker="$TMP_ROOT/js-no-mutation.marker"
  # run_explicit puts this harness's own state dir inside the fixture, so create
  # it up front: the snapshot must isolate what the RUN does to the worktree.
  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"
  # find stops at the node_modules symlink, so snapshot the linked env itself
  # too: vitest's results cache writes into node_modules/.vite unless the
  # runner invocation keeps it disabled, and THROUGH the link that would land
  # in the live provisioned env this gate promises never to mutate.
  #
  # The path-list snapshot alone cannot see that regression, because the env is
  # SHARED with every other vitest case in this file: an earlier case would
  # already have created node_modules/.vite, and a later rewrite of the same
  # paths leaves the name list identical. So stamp a marker immediately before
  # the run and assert nothing under the env is newer than it - that holds no
  # matter which cases ran first, and no matter whether the write creates a
  # path or rewrites one.
  find "$dir" -path "$dir/.git" -prune -o -print | sort > "$before"
  find "$VITEST_ENV/node_modules" | sort > "$nm_before"
  : > "$marker"

  set +e
  run_explicit "$dir" > /dev/null 2>&1
  set -e

  touched=$(find "$VITEST_ENV/node_modules" -newer "$marker" -print | sort)
  [ -z "$touched" ] \
    || fail "js-no-mutation: the run must not write anything into the linked node_modules it borrows"$'\n'"$touched"

  find "$dir" -path "$dir/.git" -prune -o -print | sort > "$after"
  diff -u "$before" "$after" > "$TMP_ROOT/js-no-mutation.diff" \
    || fail "js-no-mutation: the run must not add or remove anything in the live worktree"$'\n'"$(cat "$TMP_ROOT/js-no-mutation.diff")"
  find "$VITEST_ENV/node_modules" | sort > "$nm_after"
  diff -u "$nm_before" "$nm_after" > "$TMP_ROOT/js-no-mutation.nm-diff" \
    || fail "js-no-mutation: the run must not write into the linked node_modules it borrows"$'\n'"$(cat "$TMP_ROOT/js-no-mutation.nm-diff")"
  pass "a JS check-2 run never mutates the live worktree or the linked node_modules"
}

make_moving_name_repo() {
  local dir="$TMP_ROOT/$1" body=$2
  mkdir -p "$dir/tests"
  git init -q -b main "$dir" 2>/dev/null || {
    git init -q "$dir"
    git -C "$dir" checkout -q -b main
  }
  printf 'Z\n' > "$dir/tag.txt"
  printf '#!/usr/bin/env bash\necho Z\n' > "$dir/app.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf "pass() { printf 'ok - %%s\\\\n' \"\$1\"; }\n"
    printf "fail() { printf 'not ok - %%s\\\\n' \"\$1\" >&2; exit 1; }\n"
    # shellcheck disable=SC2016 # the expansion must stay LITERAL: this is the fixture test's own shell text.
    printf 'tag=$(cat ./tag.txt)\n'
    printf '%s' "$body"
  } > "$dir/tests/m.test.sh"
  commit_all "$dir" "main: the test names an assertion with a value read from the tree"
  git -C "$dir" checkout -q -b work
  printf '%s\n' "$dir"
}

test_moving_assertion_name_is_unstable_not_a_vanished_assertion() {
  local dir out code
  # The base test names its own assertion with a value it reads from the tree, so
  # check 2's two runs of that ONE file report two different names for one
  # passing assertion. Nothing vanished and nothing failed; the identity moved.
  # shellcheck disable=SC2016 # the fixture body is the generated test's own shell text; $tag must stay literal.
  dir=$(make_moving_name_repo moving-name '
pass "tag is readable ($tag)"
pass "unrelated assertion holds"
')
  printf 'K\n' > "$dir/tag.txt"
  commit_all "$dir" "the branch changes the value the base test reads"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "moving-name: an unresolvable identity must refuse, not pass"
  assert_contains "$out" 'unstable: tests/m.test.sh::tag is readable (Z)' \
    "moving-name: the base run's own reported name must be named as unstable"
  assert_not_contains "$out" 'failing:' \
    "moving-name: a moving name must NOT be reported as a vanished/failing assertion - both runs were green"
  assert_not_contains "$out" 'missing:' \
    "moving-name: check 1 sees the same literal source on both sides, so nothing is missing"
  assert_contains "$out" 'unstable=1' \
    "moving-name: the summary must count the unstable finding"
  # The same root cause, seen from check 1's side: it requests the LITERAL
  # unexpanded source string, which no run can ever report, so this assertion has
  # never actually been verified by the gate either.
  # shellcheck disable=SC2016 # check 1 extracts the UNEXPANDED source string, so the expected text is literal.
  assert_contains "$out" 'unaccounted: tests/m.test.sh::tag is readable ($tag)' \
    "moving-name: the unexpanded identifier check 1 requested is never accounted for by any run"
  assert_contains "$(cat "$dir/stderr")" 'UNSTABLE IDENTITY: tests/m.test.sh' \
    "moving-name: stderr must name the offending test file"
  assert_contains "$(cat "$dir/stderr")" 'defect in the TEST' \
    "moving-name: stderr must say the fix belongs in the test, not in the branch"
  pass "a moving assertion name is reported as an unstable identity, not as a vanished assertion"
}

test_unstable_name_does_not_swallow_a_real_failing_assertion() {
  local dir out code
  # One file, two assertions: one whose name moves, one whose name is constant and
  # whose behavior the branch genuinely breaks. Refusing to compare the first must
  # not blind check 2 to the second.
  # shellcheck disable=SC2016 # the fixture body is the generated test's own shell text; $tag must stay literal.
  dir=$(make_moving_name_repo unstable-plus-failing '
pass "tag is readable ($tag)"
observed=$(bash ./app.sh)
[ "$observed" = Z ] || fail "app produces Z"
pass "app produces Z"
')
  printf 'K\n' > "$dir/tag.txt"
  printf '#!/usr/bin/env bash\necho K\n' > "$dir/app.sh"
  commit_all "$dir" "the branch changes the read value AND breaks app.sh's behavior"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "unstable-plus-failing: a genuinely broken assertion must still refuse"
  assert_contains "$out" 'failing: tests/m.test.sh::app produces Z' \
    "unstable-plus-failing: the constant-named assertion the branch broke must still be reported as failing"
  assert_contains "$out" 'unstable: tests/m.test.sh::tag is readable (Z)' \
    "unstable-plus-failing: the moving name must be reported as unstable alongside it"
  pass "an unstable identity in a file never swallows a genuinely failing assertion in the same file"
}

test_unstable_name_does_not_mask_a_deleted_assertion() {
  local dir out code
  # The other direction: the branch DELETES an assertion outright from a file that
  # also holds a moving name. Check 1 must still report the deletion.
  # shellcheck disable=SC2016 # the fixture body is the generated test's own shell text; $tag must stay literal.
  dir=$(make_moving_name_repo unstable-plus-missing '
pass "tag is readable ($tag)"
pass "assertion the branch deletes"
')
  printf 'K\n' > "$dir/tag.txt"
  grep -v 'assertion the branch deletes' "$dir/tests/m.test.sh" > "$dir/tests/m.test.sh.new"
  mv "$dir/tests/m.test.sh.new" "$dir/tests/m.test.sh"
  commit_all "$dir" "the branch deletes an assertion and changes the read value"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 1 "$code" "unstable-plus-missing: a deleted assertion must still refuse"
  assert_contains "$out" 'missing: tests/m.test.sh::assertion the branch deletes' \
    "unstable-plus-missing: check 1 must still report the outright deletion"
  assert_contains "$out" 'unstable: tests/m.test.sh::tag is readable (Z)' \
    "unstable-plus-missing: the moving name must be reported as unstable alongside it"
  pass "an unstable identity in a file never masks an assertion the branch deleted"
}

test_constant_name_over_a_changed_value_is_fully_verified() {
  local dir out code
  # The fix this class asks for, asserted end to end: the runtime value moves to
  # the FAIL message and the name is a constant string. The gate then compares the
  # two runs cleanly AND finally accounts for the assertion, which the unexpanded
  # form above could never be.
  # shellcheck disable=SC2016 # the fixture body is the generated test's own shell text; $tag must stay literal.
  dir=$(make_moving_name_repo constant-name '
[ -n "$tag" ] || fail "tag is readable (got: $tag)"
pass "tag is readable"
')
  printf 'K\n' > "$dir/tag.txt"
  commit_all "$dir" "the branch changes the value the base test reads"

  set +e
  out=$(run_explicit "$dir" 2> "$dir/stderr")
  code=$?
  set -e

  expect_code 0 "$code" "constant-name: a constant identity over a changed value must exit zero"
  assert_contains "$out" 'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0 assumed-covered=0 unstable=0' \
    "constant-name: every class must be zero, including the unaccounted one the dynamic name always landed in"
  pass "a constant assertion name over a changed runtime value is compared cleanly and actually accounted for"
}

test_pr_base_branch_is_compared_against_the_pr_target
test_unreadable_pr_base_refuses_rather_than_assuming_default
test_pr_in_another_github_repo_refuses_before_any_fetch
test_unparseable_recorded_pr_refuses_before_any_github_call
test_pr_repo_mismatch_refusal_never_leaks_origin_credentials
test_task_without_a_pr_still_resolves_the_default_branch
test_explicit_mode_never_consults_github
test_removed_shell_test_reported_via_meta
test_removed_python_test_reported
test_added_tests_removed_none_loses_nothing
test_renamed_test_reported_as_missing
test_identical_branch_loses_nothing
test_removed_js_test_reported
test_rewritten_assertion_caught_by_check2
test_behavior_preserving_rewrite_is_silent_zero
test_assume_green_reports_an_identical_file_instead_of_running_it
test_identical_file_is_executed_without_the_premise_flag
test_assume_green_still_catches_a_rewritten_assertion_body
test_assume_green_still_catches_a_deleted_base_test_file
test_assume_green_does_not_treat_a_moved_file_as_identical
test_unexecutable_files_are_reported_not_passed
test_pytest_clean_run_exits_zero
test_pytest_rewritten_assertion_caught
test_pytest_without_interpreter_is_unexecuted
test_pytest_editable_shadow_is_unexecuted
test_pytest_editable_that_scratch_shadows_still_runs
test_pytest_sibling_helper_layout_executes
test_run_never_mutates_the_live_worktree
test_pytest_all_skipped_is_visible_not_a_silent_pass
test_pytest_partially_run_file_reports_the_unrun_identifier
test_pytest_unreadable_report_is_unaccounted_not_a_pass
test_shell_name_that_never_ran_is_unaccounted
test_parametrized_green_test_is_not_unaccounted
test_parametrized_all_skipped_is_skipped_not_unaccounted
test_parametrized_one_passing_case_counts_as_passing
test_parametrized_near_name_does_not_cross_match
test_vitest_clean_run_exits_zero
test_vitest_rewritten_assertion_caught
test_vitest_without_node_modules_is_unexecuted
test_js_workspace_link_is_unexecuted
test_js_self_link_to_worktree_root_is_unexecuted
test_jest_clean_run_exits_zero
test_jest_rewritten_assertion_caught
test_jest_explicit_skip_is_visible
test_js_run_never_mutates_the_live_worktree
test_moving_assertion_name_is_unstable_not_a_vanished_assertion
test_unstable_name_does_not_swallow_a_real_failing_assertion
test_unstable_name_does_not_mask_a_deleted_assertion
test_constant_name_over_a_changed_value_is_fully_verified
