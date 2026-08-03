#!/usr/bin/env bash
# Parity guard for firstmate's behaviour-test definition.
#
# bin/fm-test.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml, sharded) and the pre-push gate (.no-mistakes.yaml
# commands.test, whole set) invoke, so the local suite can never diverge from
# CI. Sharding is a scheduling change only: the union of CI's shards must be
# exactly the canonical whole set, disjointly, deterministically. These tests
# assert that directly on the real suite rather than trusting the argument for
# it, pin the CI matrix to the runner's shard denominator so the two cannot
# drift apart, and pin the fan-in gate wiring that turns a skipped or
# cancelled shard into a failure instead of a silent pass.
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

grep -Fqx "  test: 'bin/fm-test.sh'" "$NM" \
  || fail "no-mistakes commands.test must map exactly to the one-owner script's whole-set mode"
pass "pre-push gate runs the canonical whole-set mode of the same owner"

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

printf 'ok - fm-test parity suite complete\n'
