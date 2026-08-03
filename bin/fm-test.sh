#!/usr/bin/env bash
# fm-test.sh - the single owner of firstmate's behaviour-test definition.
#
# Runs the tests/*.test.sh behaviour suite. The file set, the execution rules
# (direct exec, run-all-then-report), and the shard partition all live here and
# ONLY here, so the gates cannot drift apart:
#   - CI:       .github/workflows/ci.yml runs one `bin/fm-test.sh --shard K/N`
#               per matrix shard, plus a fan-in gate job that fails unless
#               every shard succeeded.
#   - Pre-push: .no-mistakes.yaml `commands.test` runs `bin/fm-test.sh` with no
#               arguments - the canonical whole-set serial run. Same script,
#               same file set, same execution rules as CI's shards.
# The local == CI parity contract, including that the union of CI's shards is
# exactly the whole set, is asserted by tests/fm-test.test.sh.
#
# WHY SHARDS EXIST
# ----------------
# The serial suite outgrew CI's 15-minute cap: a run on main on 2026-08-02
# spent 863s in the test loop alone (job 91531989135's sibling, steps timed
# via the GitHub API) and finished 25s under the cap, and PR #13 was cancelled
# at the cap twice while still making progress. Sharding is a SCHEDULING change
# only: every file still runs on every CI run, split across parallel jobs.
# There is deliberately no change-based selection here - CI stays exhaustive.
#
# THE PARTITION
# -------------
# Files are the canonical set `tests/*.test.sh`, listed in byte order
# (LC_ALL=C), so the partition is a pure function of the tracked file names.
# File i (1-based) goes to shard ((i-1) mod N) + 1. Round-robin deliberately
# spreads name-adjacent families (fm-watch*.test.sh etc.), which cluster the
# slow timing-wait tests, across shards. Before running its own files, every
# shard invocation re-derives ALL N shards and refuses to run unless they are
# pairwise disjoint and their union is byte-identical to the whole set, so a
# future packing change can never silently drop or double-run a file. There is
# no fallback mode: a partition that fails its own audit aborts loudly.
#
# EXECUTION RULES
# ---------------
# Each test file is executed directly (not `bash file`), so a file committed
# without its executable bit fails with 126 instead of silently passing - CI
# has always enforced mode 100755 this way. A failing file does not stop the
# run: every assigned file runs, failures are collected, and the summary names
# each failed file with its exit status and this invocation's shard. The
# accounting line always prints assigned/run/passed/failed/skipped counts, and
# a file assigned but somehow not run (skipped) is a hard failure, never a
# pass.
#
# Usage:
#   fm-test.sh                    run the whole canonical suite serially
#                                  (the reference definition; what the
#                                  pre-push gate runs)
#   fm-test.sh --shard K/N        run shard K of N (what CI runs)
#   fm-test.sh --list-shard K/N   print shard K's files without running them
#                                  (local reproduction: run the printed files,
#                                  or just `fm-test.sh --shard K/N`)
#
# Environment:
#   FM_TEST_SUITE_DIR  directory holding *.test.sh (default: tests). Exists so
#                       tests/fm-test.test.sh can point this runner at fixture
#                       suites; the gates never set it.
#
# Exit status: 0 when every executed file passed, 1 when any failed or the
# accounting does not add up, 2 on usage or partition-audit errors.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SUITE_DIR="${FM_TEST_SUITE_DIR:-tests}"

usage() {
  printf 'usage: fm-test.sh [--shard K/N | --list-shard K/N]\n' >&2
  exit 2
}

MODE=whole-set
SHARD_K=1
SHARD_N=1
case "${1:-}" in
  '') ;;
  --shard|--list-shard)
    [ "$#" -eq 2 ] || usage
    case "$1" in
      --shard) MODE=shard ;;
      *) MODE=list-shard ;;
    esac
    spec=$2
    case "$spec" in
      *[!0-9/]*|*/*/*|/*|*/|'') usage ;;
      */*) SHARD_K=${spec%%/*}; SHARD_N=${spec##*/} ;;
      *) usage ;;
    esac
    if [ "$SHARD_N" -lt 1 ] || [ "$SHARD_K" -lt 1 ] || [ "$SHARD_K" -gt "$SHARD_N" ]; then
      printf 'fm-test.sh: shard %s is not within 1..%s\n' "$SHARD_K" "$SHARD_N" >&2
      exit 2
    fi
    ;;
  *) usage ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

# The canonical file set, in byte order so every invocation - any shard, any
# machine, any locale - derives the identical partition.
printf '%s\n' "$SUITE_DIR"/*.test.sh | LC_ALL=C sort >"$TMP/files"
total=$(wc -l <"$TMP/files" | tr -d ' ')
first=$(head -1 "$TMP/files")
if [ "$total" -eq 0 ] || [ ! -e "$first" ]; then
  printf 'fm-test.sh: no test files match %s/*.test.sh; refusing to report an empty suite as green.\n' \
    "$SUITE_DIR" >&2
  exit 2
fi

# shard_files K N: shard K's files, round-robin over the canonical order.
shard_files() {
  awk -v k="$1" -v n="$2" '((NR - 1) % n) + 1 == k' "$TMP/files"
}

if [ "$MODE" != whole-set ]; then
  # Partition audit: re-derive every shard and require exact disjoint coverage
  # of the whole set before running anything. Refuse loudly on any mismatch -
  # a green shard must never be able to mean "some files were never assigned".
  : >"$TMP/union"
  assigned_sum=0
  k=1
  while [ "$k" -le "$SHARD_N" ]; do
    shard_files "$k" "$SHARD_N" >>"$TMP/union"
    assigned_sum=$((assigned_sum + $(shard_files "$k" "$SHARD_N" | wc -l)))
    k=$((k + 1))
  done
  LC_ALL=C sort "$TMP/union" >"$TMP/union.sorted"
  if [ "$assigned_sum" -ne "$total" ] || ! cmp -s "$TMP/union.sorted" "$TMP/files"; then
    printf 'fm-test.sh: PARTITION BROKEN - the %s shards do not disjointly cover all %s test files; refusing to run.\n' \
      "$SHARD_N" "$total" >&2
    diff -u "$TMP/files" "$TMP/union.sorted" >&2 || true
    exit 2
  fi
  shard_files "$SHARD_K" "$SHARD_N" >"$TMP/run"
  label="shard $SHARD_K/$SHARD_N"
else
  cp "$TMP/files" "$TMP/run"
  label="whole set"
fi

if [ "$MODE" = list-shard ]; then
  cat "$TMP/run"
  exit 0
fi

command -v tmux >/dev/null 2>&1 || {
  printf 'fm-test.sh: tmux is required for e2e tests\n' >&2
  exit 1
}
tmux -V >&2

assigned=$(wc -l <"$TMP/run" | tr -d ' ')
printf 'fm-test.sh: %s: %s of %s test files assigned.\n' "$label" "$assigned" "$total" >&2

run=0
passed=0
failed=0
: >"$TMP/failures"
while IFS= read -r t; do
  run=$((run + 1))
  printf '== %s ==\n' "$t"
  rc=0
  # Every entry contains a slash (SUITE_DIR/name), so this is a path exec,
  # never a PATH lookup, and a missing executable bit fails with 126.
  # stdin is /dev/null so a test that reads stdin cannot swallow this loop's
  # own file list and silently skip the rest of the shard.
  "$t" </dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf '%s (exit %s)\n' "$t" "$rc" >>"$TMP/failures"
  fi
done <"$TMP/run"

skipped=$((assigned - run))
printf 'fm-test.sh: %s: %s assigned, %s run, %s passed, %s failed, %s skipped.\n' \
  "$label" "$assigned" "$run" "$passed" "$failed" "$skipped" >&2

if [ "$skipped" -ne 0 ]; then
  printf 'fm-test.sh: FAILED - %s assigned file(s) were never run; a skip is never a pass.\n' \
    "$skipped" >&2
  exit 1
fi

if [ "$failed" -ne 0 ]; then
  while IFS= read -r line; do
    printf 'fm-test.sh: FAILED in %s: %s\n' "$label" "$line" >&2
  done <"$TMP/failures"
  exit 1
fi

printf 'fm-test.sh: %s: all %s test files passed.\n' "$label" "$run" >&2
exit 0
