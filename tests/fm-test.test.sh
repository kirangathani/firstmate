#!/usr/bin/env bash
# Parity guard for firstmate's behaviour-test definition.
#
# bin/fm-test.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml, sharded) and the pre-push gate (.no-mistakes.yaml
# commands.test, change-selected) invoke, so the local suite can never diverge
# from CI. Two separate contracts are asserted here, because the two gates now
# run different amounts of work.
#
# CI's contract is exhaustiveness: sharding is a scheduling change only, so the
# union of CI's shards must be exactly the canonical whole set, disjointly and
# deterministically. That is asserted on the real suite rather than trusting the
# argument for it, the CI matrix is pinned to the runner's shard denominator so
# the two cannot drift, and the fan-in gate wiring that turns a skipped or
# cancelled shard into a failure instead of a silent pass is pinned too.
#
# The local gate's contract is stronger, because it deliberately runs FEWER
# files: selection must follow the reference closure rather than file names, and
# the selected parallel path must return the whole set's verdict for every file
# it runs. Both are asserted at the bottom of this file on a fixture repo with
# a real reference graph, including on a tree that fails - "both modes report
# green" is the one result that would prove nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"

# --- one owner: both gates invoke bin/fm-test.sh ----------------------------

[ -x "$RUNNER" ] || fail "bin/fm-test.sh must be executable so CI/gate can run it directly"
pass "fm-test.sh is executable"

# shellcheck disable=SC2016 # The ${{ }} is GitHub expression syntax, literal here.
grep -Fq -- '- run: bin/fm-test.sh --shard ${{ matrix.shard }}/' "$CI" \
  || fail "CI behaviour job must invoke the one-owner script's shard mode"
assert_no_grep 'for test_script' "$CI" "CI must call fm-test.sh, not re-spell the test loop inline"
pass "CI behaviour job calls the one-owner script, not an inline loop"

grep -Fqx "  test: 'bin/fm-test.sh --local'" "$NM" \
  || fail "no-mistakes commands.test must map exactly to the one-owner script's local mode"
pass "pre-push gate runs the selecting local mode of the same owner"

assert_no_grep '--local' "$CI" "CI must stay exhaustive: no change-based selection in the workflow"
pass "CI never invokes the selecting local mode"

# --- CI matrix and the runner's denominator cannot drift --------------------

DENOM=$(grep -Eo 'fm-test\.sh --shard \$\{\{ matrix\.shard \}\}/[0-9]+' "$CI" | grep -Eo '[0-9]+$')
[ -n "$DENOM" ] || fail "could not read the shard denominator from CI's fm-test.sh invocation"
MATRIX=$(grep -Eo 'shard: \[[0-9, ]+\]' "$CI" | head -1)
[ -n "$MATRIX" ] || fail "could not read the shard matrix from CI"
want='shard: ['
k=1
while [ "$k" -le "$DENOM" ]; do
  [ "$k" -eq 1 ] || want="$want, "
  want="$want$k"
  k=$((k + 1))
done
want="$want]"
[ "$MATRIX" = "$want" ] \
  || fail "CI shard matrix ($MATRIX) must be exactly 1..$DENOM to match the invocation denominator"
pass "CI runs every shard 1..$DENOM of the denominator it invokes"

# --- fan-in gate: a skipped/cancelled shard fails, never passes -------------

assert_grep 'needs: tests' "$CI" "the tests-complete gate must depend on the shard matrix"
assert_grep 'if: always()' "$CI" "the gate must report a verdict even when shards fail or are cancelled"
assert_grep 'needs.tests.result' "$CI" "the gate must test the aggregate shard result"
# shellcheck disable=SC2016 # $result must stay literal: it is the gate's own shell text.
assert_grep 'if [ "$result" != "success" ]; then' "$CI" \
  "the gate must fail on anything but every-shard-success (including skipped and cancelled)"
pass "tests-complete gate turns non-success shard outcomes into failures"

# --- partition parity on the real suite -------------------------------------
# The union of shards 1..N must be byte-identical to the whole set, the shard
# sizes must sum to the whole set (disjointness), and listing must be
# deterministic. Asserted for CI's real denominator and one other N.

WHOLE=$("$RUNNER" --list-shard 1/1)
TOTAL=$(printf '%s\n' "$WHOLE" | wc -l | tr -d ' ')
[ "$TOTAL" -gt 0 ] || fail "whole-set listing must not be empty"
printf '%s\n' "$WHOLE" | grep -Fq 'tests/fm-test.test.sh' \
  || fail "the canonical set must include this very test file"

for n in "$DENOM" 3; do
  union=''
  sum=0
  k=1
  while [ "$k" -le "$n" ]; do
    part=$("$RUNNER" --list-shard "$k/$n")
    [ -n "$part" ] || fail "shard $k/$n listed no files"
    count=$(printf '%s\n' "$part" | wc -l | tr -d ' ')
    sum=$((sum + count))
    union="$union$part
"
    k=$((k + 1))
  done
  [ "$sum" -eq "$TOTAL" ] || fail "shard sizes for N=$n sum to $sum, not the whole set's $TOTAL"
  if ! diff <(printf '%s' "$union" | LC_ALL=C sort) <(printf '%s\n' "$WHOLE") >/dev/null; then
    fail "union of shards 1..$n is not the whole set"
  fi
  pass "shards 1..$n disjointly cover all $TOTAL test files"
done

first=$("$RUNNER" --list-shard "2/$DENOM")
second=$("$RUNNER" --list-shard "2/$DENOM")
[ "$first" = "$second" ] || fail "shard listing must be deterministic"
pass "shard listing is deterministic"

# --- execution rules, on a fixture suite ------------------------------------
# FM_TEST_SUITE_DIR points the runner at a throwaway suite so the failure
# paths run in milliseconds instead of re-running the real 86-file suite.

TMPROOT=$(fm_test_tmproot fm-test-fixture)
FX="$TMPROOT/suite"
mkdir -p "$FX"
# Round-robin over the sorted names puts {aa,cc} in shard 1/2 and {bb,dd} in
# shard 2/2, so the failing bb shares its shard with a LATER passing file.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/aa.test.sh"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 7\n' > "$FX/bb.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/cc.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/dd.test.sh"
chmod +x "$FX"/*.test.sh

# A deliberately failing test must fail its shard, name the shard, the file,
# and the exit status, and must not stop the shard's remaining files.
out=$(FM_TEST_SUITE_DIR="$FX" "$RUNNER" --shard 2/2 2>&1)
rc=$?
[ "$rc" -eq 1 ] || fail "a failing test file must fail its shard (got rc=$rc)"
assert_contains "$out" "FAILED in shard 2/2" "the failure must name the shard it came from"
assert_contains "$out" "bb.test.sh (exit 7)" "the failure must name the file and its exit status"
assert_contains "$out" "== $FX/dd.test.sh ==" "a failure must not stop the shard's remaining files"
assert_contains "$out" "2 run, 1 passed, 1 failed, 0 skipped" "the accounting line must count run/passed/failed/skipped"
pass "a deliberately failing test fails its shard with full attribution"

# The sibling shard without the failing file passes with explicit accounting.
out=$(FM_TEST_SUITE_DIR="$FX" "$RUNNER" --shard 1/2 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "the all-green shard must pass (got rc=$rc): $out"
assert_contains "$out" "2 run, 2 passed, 0 failed, 0 skipped" "the green shard must still print its accounting"
pass "an all-green shard passes with explicit accounting"

# The whole-set mode reports the same failure, so the pre-push gate catches it.
out=$(FM_TEST_SUITE_DIR="$FX" "$RUNNER" 2>&1)
rc=$?
[ "$rc" -eq 1 ] || fail "the whole-set run must fail on a failing file (got rc=$rc)"
assert_contains "$out" "FAILED in whole set" "the whole-set run must report the failure"
pass "the whole-set mode fails on the same failing file"

# A file without its executable bit must fail loudly (exit 126), preserving
# the mode-100755 invariant CI has always enforced by direct execution.
chmod -x "$FX/cc.test.sh"
out=$(FM_TEST_SUITE_DIR="$FX" "$RUNNER" --shard 1/2 2>&1)
rc=$?
chmod +x "$FX/cc.test.sh"
[ "$rc" -eq 1 ] || fail "a non-executable test file must fail its shard (got rc=$rc)"
assert_contains "$out" "cc.test.sh (exit 126)" "the non-executable file must surface as exit 126"
pass "a test file missing its executable bit fails, never silently passes"

# An empty suite must refuse rather than report green.
EMPTY="$TMPROOT/empty"
mkdir -p "$EMPTY"
out=$(FM_TEST_SUITE_DIR="$EMPTY" "$RUNNER" 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "an empty suite must refuse with rc=2 (got rc=$rc)"
assert_contains "$out" "refusing to report an empty suite as green" "the empty-suite refusal must be loud"
pass "an empty suite refuses instead of passing vacuously"

# Out-of-range and malformed shard specs must be usage errors, not runs.
for spec in 0/4 5/4 x/4 4 4/ /4 1/2/3; do
  FM_TEST_SUITE_DIR="$FX" "$RUNNER" --shard "$spec" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "--shard $spec must be rejected with rc=2 (got rc=$rc)"
done
pass "malformed and out-of-range shard specs are rejected"

# ===========================================================================
# Local mode: closure selection and selected-vs-whole-set parity
# ===========================================================================
#
# The local gate runs FEWER files than CI, so it needs a stronger guard than
# the shard partition does, and the guard has to be about the SELECTION rule
# rather than about file names. Two claims are load-bearing and both are
# asserted below on a real fixture repo with a real reference graph:
#   1. a test that exercises an edited script is selected even though the test
#      file itself is untouched and its name resembles nothing that changed;
#   2. the selected, sharded, parallel path returns the whole-set path's verdict
#      for every file it runs, so narrowing never turns a failure into a pass.
# A third guard covers the approximation itself: the planner reads a static
# reference graph, so any changed file that graph cannot attribute to a test
# must escalate to the canonical whole set rather than quietly run less.

# fm_test_local_fixture <dir>: a miniature repo with the canonical layout and a
# REAL reference graph, so selection is exercised rather than mocked.
#   tests/aa -> bin/tool.sh -> bin/lib-core.sh   (the transitive case)
#   tests/bb -> bin/other.sh                     (must NOT be dragged in)
#   tests/cc -> nothing
#   tests/dd -> docs/notes.md, which NAMES bin/tool.sh in prose
# fm-test.sh resolves its root from its own location, so the fixture gets its
# own copy of the runner and the planner.
fm_test_local_fixture() {
  local root=$1
  mkdir -p "$root/bin" "$root/tests" "$root/docs"
  cp "$RUNNER" "$root/bin/fm-test.sh"
  cp "$ROOT/bin/fm-test-plan.awk" "$root/bin/fm-test-plan.awk"
  chmod +x "$root/bin/fm-test.sh"

  printf '#!/usr/bin/env bash\ncore_ready() { printf "ready\\n"; }\n' > "$root/bin/lib-core.sh"
  cat > "$root/bin/tool.sh" <<'SH'
#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-core.sh"
core_ready
SH
  printf '#!/usr/bin/env bash\nprintf "other\\n"\n' > "$root/bin/other.sh"
  chmod +x "$root/bin/tool.sh" "$root/bin/other.sh"

  # Prose that names a script. A doc is a legitimate dependency TARGET for the
  # test that reads it, and never a source of edges: editing bin/tool.sh does
  # not change what this file says.
  printf '# Notes\n\nThe tool lives at bin/tool.sh and it prints ready.\n' > "$root/docs/notes.md"
  # Referenced by nothing at all. README.md is prose, so "no test reaches it" is
  # a positive finding; bin/orphan.sh is code, which can also be reached by
  # execution through a computed name, so the same absence proves nothing.
  printf '# Fixture\n' > "$root/README.md"
  printf '#!/usr/bin/env bash\nprintf "orphan\\n"\n' > "$root/bin/orphan.sh"
  chmod +x "$root/bin/orphan.sh"

  printf '#!/usr/bin/env bash\nFIXTURE_LIB=1\nexport FIXTURE_LIB\n' > "$root/tests/lib.sh"
  cat > "$root/tests/aa.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/tool.sh" >/dev/null
SH
  cat > "$root/tests/bb.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/other.sh" >/dev/null
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/tests/cc.test.sh"
  cat > "$root/tests/dd.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -q Notes "$ROOT/docs/notes.md"
SH
  chmod +x "$root/tests"/*.test.sh

  git -C "$root" init -q
  git -C "$root" add -A
  git -C "$root" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture
}

# fm_test_local_list <fixture> <changed path>...: the files --local would run
# for that exact change set.
fm_test_local_list() {
  local fx=$1 changed
  shift
  changed="$fx/.changed"
  printf '%s\n' "$@" > "$changed"
  FM_TEST_NO_CACHE=1 FM_TEST_CHANGED="$changed" "$fx/bin/fm-test.sh" --list-local 2>/dev/null
}

LOCALROOT=$(fm_test_tmproot fm-test-local)
FXL="$LOCALROOT/repo"
fm_test_local_fixture "$FXL"

# --- selection follows the closure, not the file name -----------------------
# bin/lib-core.sh is named by NO test file. It reaches tests/aa.test.sh only
# through bin/tool.sh. This is the case filename matching gets wrong.
sel=$(fm_test_local_list "$FXL" bin/lib-core.sh)
assert_contains "$sel" 'tests/aa.test.sh' \
  "a test exercising an edited script must be selected even though the test file is untouched"
assert_not_contains "$sel" 'tests/bb.test.sh' "an unrelated test must not be selected"
assert_not_contains "$sel" 'tests/cc.test.sh' "an unrelated test must not be selected"
assert_not_contains "$sel" 'tests/dd.test.sh' "an unrelated test must not be selected"
pass "selection is closure-derived: an edited library selects its transitive test only"

# The directly-invoked script selects the same test, and nothing more.
sel=$(fm_test_local_list "$FXL" bin/other.sh)
[ "$sel" = 'tests/bb.test.sh' ] || fail "editing bin/other.sh must select exactly tests/bb.test.sh, got: $sel"
pass "a directly-invoked script selects exactly its own test"

# A changed test file selects itself even though nothing depends on it.
sel=$(fm_test_local_list "$FXL" tests/cc.test.sh)
[ "$sel" = 'tests/cc.test.sh' ] || fail "a changed test file must select itself, got: $sel"
pass "a changed test file selects itself"

# --- prose is a dependency target, never a source of edges ------------------
# docs/notes.md names bin/tool.sh. The test that READS the doc must run when the
# doc changes, and must NOT run merely because the doc mentions something else
# that changed - otherwise every file cited anywhere in the documentation drags
# the whole suite in, which is what a whole-set run already does for free.
sel=$(fm_test_local_list "$FXL" docs/notes.md)
[ "$sel" = 'tests/dd.test.sh' ] || fail "a changed doc must select the test that reads it, got: $sel"
sel=$(fm_test_local_list "$FXL" bin/tool.sh)
assert_contains "$sel" 'tests/aa.test.sh' "the script's own test must be selected"
assert_not_contains "$sel" 'tests/dd.test.sh' \
  "a doc merely NAMING the changed script must not drag its reader in"
pass "prose is a dependency target, not a source of edges"

# --- an unattributable change escalates to the whole set --------------------
# The planner reads a static graph, so it cannot prove it saw every route to a
# file. It CAN prove a changed file is on no route at all, and that is the case
# where running less would be a guess.
printf '%s\n' bin/orphan.sh > "$FXL/.changed"
out=$(FM_TEST_NO_CACHE=1 FM_TEST_CHANGED="$FXL/.changed" "$FXL/bin/fm-test.sh" --local 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "the escalated whole-set run must still pass on a green fixture (rc=$rc): $out"
assert_contains "$out" 'running the canonical whole set instead' \
  "an unreferenced SCRIPT must escalate: it can still be reached by a computed name"
assert_contains "$out" 'whole set: 4 assigned, 4 run' "the escalation must run every file"
pass "an unreferenced script escalates to the whole set"

# Prose is the exception, and only because the evidence is genuinely different:
# a doc affects a test only by being read, and a test that reads a doc names it.
# Escalating here instead would put every documentation-only edit through the
# full suite, which is the slow gate this mode exists to remove.
printf '%s\n' README.md > "$FXL/.changed"
out=$(FM_TEST_NO_CACHE=1 FM_TEST_CHANGED="$FXL/.changed" "$FXL/bin/fm-test.sh" --local 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "an unread doc must not fail the run (rc=$rc): $out"
assert_not_contains "$out" 'running the canonical whole set instead' \
  "an unread doc must not escalate: no test reads it, so no test can be affected"
assert_contains "$out" 'no test reads README.md' "the narrowed run must name what it ruled out"
assert_contains "$out" '0 of 4 files run' "an unread doc must run nothing"
pass "an unread doc runs nothing and names itself, instead of escalating"

# The asymmetry must not leak: a doc a test DOES read still selects that test.
sel=$(fm_test_local_list "$FXL" docs/notes.md README.md)
[ "$sel" = 'tests/dd.test.sh' ] \
  || fail "a read doc must still select its reader even alongside an unread one, got: $sel"
pass "the prose exception applies only to docs no test reads"

# --- parity: the selected, sharded path agrees with the whole set -----------
# This is the contract that makes narrowing safe. --verify-parity runs the
# canonical whole-set serial mode and the selected parallel mode over the same
# files and diffs their per-file verdicts. It is asserted on a tree that
# actually HAS a failure, because "both modes report green" is the one result
# that proves nothing.
out=$(FM_TEST_NO_CACHE=1 "$FXL/bin/fm-test.sh" --verify-parity 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "green fixture must reach parity (rc=$rc): $out"
assert_contains "$out" 'PARITY OK - 4 file(s)' "parity must compare every file, not a subset"
pass "the selected, sharded path agrees with the whole set on a green tree"

printf '#!/usr/bin/env bash\nprintf "broken\\n" >&2\nexit 3\n' > "$FXL/bin/other.sh"
chmod +x "$FXL/bin/other.sh"
out=$(FM_TEST_NO_CACHE=1 "$FXL/bin/fm-test.sh" --verify-parity 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "a failing tree must still reach parity (rc=$rc): $out"
assert_contains "$out" 'PARITY OK' "both modes must agree about the failure too"
pass "the two paths agree file for file on a tree that fails"

# And the local path must actually FAIL on it: a faster gate that reports green
# on a broken tree is the only outcome worse than a slow gate.
sel_rc=0
printf '%s\n' bin/other.sh > "$FXL/.changed"
out=$(FM_TEST_NO_CACHE=1 FM_TEST_CHANGED="$FXL/.changed" \
  "$FXL/bin/fm-test.sh" --local 2>&1) || sel_rc=$?
[ "$sel_rc" -eq 1 ] || fail "the local run must fail on a broken selected test (rc=$sel_rc): $out"
assert_contains "$out" 'tests/bb.test.sh (exit 3)' "the local failure must name the file and its status"
assert_contains "$out" '1 assigned, 1 run, 0 passed, 1 failed, 0 skipped' \
  "the local run must print the same accounting as every other mode"
pass "a broken selected test fails the local run with full attribution"
git -C "$FXL" checkout -q -- bin/other.sh

# Every fallback names the concrete blocker, so a run that silently went wide is
# never mistaken for a run that selected.
out=$(FM_TEST_NO_CACHE=1 FM_TEST_CHANGED="$FXL/nonexistent" "$FXL/bin/fm-test.sh" --local 2>&1)
assert_contains "$out" 'is not a readable file' "the fallback must name the concrete blocker"
assert_contains "$out" 'running the canonical whole set instead' "an unusable change list must not narrow"
pass "an unusable change set falls back to the whole set and says why"

# --- the parallel shards cover the selection exactly ------------------------
# Same disjoint-coverage property the CI partition has, on the selected set:
# what ran must be exactly what --list-local promised.
printf '%s\n' bin/lib-core.sh bin/other.sh docs/notes.md > "$FXL/.changed"
listed=$(FM_TEST_NO_CACHE=1 FM_TEST_CHANGED="$FXL/.changed" "$FXL/bin/fm-test.sh" --list-local 2>/dev/null)
ran=$(FM_TEST_NO_CACHE=1 FM_TEST_EMIT_VERDICTS="$FXL/.verdicts" FM_TEST_CHANGED="$FXL/.changed" \
  FM_TEST_JOBS=3 "$FXL/bin/fm-test.sh" --local >/dev/null 2>&1; cut -f1 "$FXL/.verdicts")
[ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$(printf '%s\n' "$ran" | LC_ALL=C sort)" ] \
  || fail "the parallel shards must run exactly the listed selection; listed [$listed] ran [$ran]"
[ "$(printf '%s\n' "$ran" | wc -l)" -eq "$(printf '%s\n' "$ran" | sort -u | wc -l)" ] \
  || fail "no file may be run twice across the parallel shards"
pass "the parallel shards disjointly cover exactly the selected set"

printf 'ok - fm-test parity suite complete\n'
