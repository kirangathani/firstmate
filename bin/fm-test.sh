#!/usr/bin/env bash
# fm-test.sh - the single owner of firstmate's behaviour-test definition.
#
# Runs the tests/*.test.sh behaviour suite. The file set, the execution rules
# (direct exec, run-all-then-report), and the shard partition all live here and
# ONLY here, so the gates cannot drift apart:
#   - CI:       .github/workflows/ci.yml runs one `bin/fm-test.sh --shard K/N`
#               per matrix shard, plus a fan-in gate job that fails unless
#               every shard succeeded.
#   - Pre-push: .no-mistakes.yaml `commands.test` runs `bin/fm-test.sh --local`
#               - the change-selected parallel run described below, which is a
#               SELECTION and SCHEDULING change over the same file set, the same
#               execution rules, and the same verdict per file.
# The canonical whole-set serial run (no arguments) remains the definition of
# the suite and the reference every other mode is measured against. The local ==
# CI parity contract - that the union of CI's shards is exactly the whole set,
# and that the selected, sharded local path returns the whole set's verdict for
# every file it runs - is asserted by tests/fm-test.test.sh.
#
# WHY SHARDS EXIST (CI)
# ---------------------
# The serial suite outgrew CI's 15-minute cap: a run on main on 2026-08-02
# spent 863s in the test loop alone (job 91531989135's sibling, steps timed
# via the GitHub API) and finished 25s under the cap, and PR #13 was cancelled
# at the cap twice while still making progress. Sharding is a SCHEDULING change
# only: every file still runs on every CI run, split across parallel jobs.
# There is deliberately no change-based selection in CI - CI stays exhaustive,
# because CI is the authority that catches the host-dependence class of bug a
# local run passes by construction (a borrowed git identity, an assumed node).
#
# THE PARTITION (CI)
# ------------------
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
# WHY LOCAL SELECTS AND PARALLELISES
# ----------------------------------
# The pre-push gate used to run the identical serial loop CI runs, so the whole
# suite was paid for twice - 10.4 minutes locally, plus the CI run - and a gate
# that slow is worth routing around, which is the worst possible property for a
# gate. Local mode instead runs only what the change can affect, in parallel
# shards packed against measured per-file durations rather than by position.
#
# Selection is NOT filename matching. tests/fm-teardown.test.sh has to run when
# bin/fm-crew-state.sh changes, even though neither name resembles the other and
# the test file itself is untouched. bin/fm-test-plan.awk therefore builds a
# reference graph over the tracked repo, closes it transitively from each test
# file, and selects every test whose closure intersects the change set; that
# file owns the graph's construction and its safety argument.
#
# The selection and the packing are two SEPARATE planner invocations, and the
# packed shards are audited against the selection before anything runs, exactly
# as a CI shard audits the partition. Deriving both from one invocation would
# make the audit compare the packer with itself: a file the packer dropped would
# lower the assigned count and the run count together, and the run would report
# every file green having never executed it.
#
# WHAT LOCAL MODE DOES NOT DO
# ---------------------------
# It does not cache a PASS. Caching a lint finding is sound because a finding is
# a pure function of file contents; a test outcome is not - it also depends on
# the host, the clock, the installed tools and concurrent load, which is exactly
# the class of bug CI exists to catch. So every selected file is executed in
# full on every local run, and the only thing carried between runs is how long
# each file took, used for shard packing and never for a verdict. Narrowing
# happens through the closure or not at all: any changed file the planner cannot
# attribute to some test escalates the run to the canonical whole set, as does
# any failure to derive the change set, the file list, or the plan.
#
# Usage:
#   fm-test.sh                    run the whole canonical suite serially
#                                  (the reference definition; the mode every
#                                  other mode must agree with)
#   fm-test.sh --shard K/N        run shard K of N (what CI runs)
#   fm-test.sh --list-shard K/N   print shard K's files without running them
#                                  (local reproduction: run the printed files,
#                                  or just `fm-test.sh --shard K/N`)
#   fm-test.sh --local            run only the tests the working change can
#                                  affect, in parallel cost-packed shards
#                                  (what the pre-push gate runs)
#   fm-test.sh --list-local       print the files --local would run
#   fm-test.sh --verify-parity    run the whole set and the local path over the
#                                  same files and diff their per-file verdicts
#                                  (slow on the real suite by construction; the
#                                  fixture version runs in tests/fm-test.test.sh)
#
# Environment:
#   FM_TEST_SUITE_DIR   directory holding *.test.sh (default: tests). Exists so
#                        tests/fm-test.test.sh can point this runner at fixture
#                        suites; the gates never set it.
#   FM_TEST_BASE        git ref --local diffs against (default: the first of
#                        origin/main, main, origin/master, master that resolves).
#   FM_TEST_CHANGED     path to a file listing changed paths, bypassing git
#                        entirely. Used by the parity tests.
#   FM_TEST_JOBS        parallel shard count for --local (default: half the
#                        cores, clamped to 2..6).
#   FM_TEST_CACHE_DIR   where measured per-file durations are recorded
#                        (default: fm-test-cache under the shared git common
#                        dir, so linked worktrees share one sidecar).
#   FM_TEST_NO_CACHE=1  read and write no durations.
#   FM_TEST_EMIT_VERDICTS  path to write "<file><TAB><exit status>" per executed
#                        file, sorted. Used by --verify-parity.
#
# Exit status: 0 when every executed file passed, 1 when any failed or the
# accounting does not add up, 2 on usage or partition-audit errors.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SUITE_DIR="${FM_TEST_SUITE_DIR:-tests}"
TAB=$(printf '\t')

usage() {
  printf 'usage: fm-test.sh [--shard K/N | --list-shard K/N | --local | --list-local | --verify-parity]\n' >&2
  exit 2
}

MODE='whole-set'
SHARD_K=1
SHARD_N=1
case "${1:-}" in
  '') ;;
  --local) [ "$#" -eq 1 ] || usage; MODE='local' ;;
  --list-local) [ "$#" -eq 1 ] || usage; MODE='list-local' ;;
  --verify-parity) [ "$#" -eq 1 ] || usage; MODE='verify-parity' ;;
  --shard|--list-shard)
    [ "$#" -eq 2 ] || usage
    case "$1" in
      --shard) MODE='shard' ;;
      *) MODE='list-shard' ;;
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

# --- measured durations -----------------------------------------------------
# Durations only, never a verdict: a recorded time cannot make a file skip, it
# can only change which shard the file lands in. Kept under .git, which is
# never tracked and never shipped, so CI always starts without one.
#
# The COMMON git dir, not --git-dir: --git-dir in a linked worktree is that
# worktree's private directory, and the gate this mode exists for runs in a
# fresh throwaway worktree every time, so a per-worktree sidecar would always be
# cold and the packer would fall back to a uniform cost for every file. The
# common dir is shared by every worktree of the repo, so a measurement taken in
# one run is available to the next.
CACHE_DIR="${FM_TEST_CACHE_DIR:-}"
if [ -z "$CACHE_DIR" ]; then
  git_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
  CACHE_DIR="${git_dir:-$ROOT/.fm-test}/fm-test-cache"
fi
TIMINGS="$CACHE_DIR/timings"
USE_CACHE=1
[ "${FM_TEST_NO_CACHE:-0}" = 1 ] && USE_CACHE=0

# Sub-second wall clock where the platform has it, whole seconds where it does
# not. Only ever feeds the packer, so a coarse clock costs balance, not safety.
if [ "$(date +%N 2>/dev/null)" = "N" ]; then
  now() { date +%s; }
else
  now() { date +%s.%N; }
fi

# record_timings <verdict file>: merge this run's measured durations into the
# sidecar, keeping entries for files this run did not execute. Best effort - a
# failure to record must never change a verdict.
record_timings() {
  [ "$USE_CACHE" = 1 ] || return 0
  [ -s "$1" ] || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  # Staged inside CACHE_DIR rather than under $TMP: the sidecar is shared by
  # every worktree of the repo, so two runs can be writing it at once, and only
  # a same-directory rename is atomic. A concurrent reader then sees the old
  # file or the new one, never a half-written one.
  local staged="$CACHE_DIR/timings.$$"
  {
    cut -f1,3 "$1"
    [ -f "$TIMINGS" ] && cat "$TIMINGS"
  } 2>/dev/null \
    | awk -F'\t' 'NF >= 2 && $1 != "" && !seen[$1]++ { printf "%s\t%s\n", $1, $2 }' \
      >"$staged" 2>/dev/null \
    && mv "$staged" "$TIMINGS" 2>/dev/null
  rm -f "$staged" 2>/dev/null || true
  return 0
}

# --- the shared execution loop ----------------------------------------------
# Every mode runs its files through this one function, so "same file set, same
# execution rules, same verdict" is a property of the code rather than of three
# hand-synchronised loops.
#
# run_files <list> <transcript|-> <verdicts>
#   transcript "-" streams the banner and each file's own output live, which is
#   what the serial reference and CI shards want; any other value buffers to
#   that file, which is what parallel shards need so their output is readable.
#   verdicts gets "<file><TAB><exit status><TAB><seconds>" per executed file.
# Returns 0 when every file passed, 1 otherwise.
run_files() {
  local list=$1 transcript=$2 verdicts=$3
  local t rc rfailed=0 s e
  : >"$verdicts"
  [ "$transcript" = - ] || : >"$transcript"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    rc=0
    s=$(now)
    # Every entry contains a slash (SUITE_DIR/name), so this is a path exec,
    # never a PATH lookup, and a missing executable bit fails with 126.
    # stdin is /dev/null so a test that reads stdin cannot swallow this loop's
    # own file list and silently skip the rest of the run.
    if [ "$transcript" = - ]; then
      printf '== %s ==\n' "$t"
      "$t" </dev/null || rc=$?
    else
      printf '== %s ==\n' "$t" >>"$transcript"
      "$t" </dev/null >>"$transcript" 2>&1 || rc=$?
    fi
    e=$(now)
    printf '%s\t%s\t%s\n' "$t" "$rc" \
      "$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", b - a}')" >>"$verdicts"
    [ "$rc" -eq 0 ] || rfailed=1
  done <"$list"
  return "$rfailed"
}

# report <label> <list> <verdicts>: the accounting line, the failure lines and
# the exit status, worded identically in every mode.
report() {
  local label=$1 list=$2 verdicts=$3
  local assigned run passed failed skipped
  assigned=$(wc -l <"$list" | tr -d ' ')
  run=$(wc -l <"$verdicts" | tr -d ' ')
  passed=$(awk -F'\t' '$2 == 0' "$verdicts" | wc -l | tr -d ' ')
  failed=$((run - passed))
  skipped=$((assigned - run))

  if [ -n "${FM_TEST_EMIT_VERDICTS:-}" ]; then
    cut -f1,2 "$verdicts" | LC_ALL=C sort >"$FM_TEST_EMIT_VERDICTS"
  fi

  printf 'fm-test.sh: %s: %s assigned, %s run, %s passed, %s failed, %s skipped.\n' \
    "$label" "$assigned" "$run" "$passed" "$failed" "$skipped" >&2

  if [ "$skipped" -ne 0 ]; then
    printf 'fm-test.sh: FAILED - %s assigned file(s) were never run; a skip is never a pass.\n' \
      "$skipped" >&2
    return 1
  fi
  if [ "$failed" -ne 0 ]; then
    awk -F'\t' -v L="$label" '$2 != 0 { printf "fm-test.sh: FAILED in %s: %s (exit %s)\n", L, $1, $2 }' \
      "$verdicts" >&2
    return 1
  fi
  printf 'fm-test.sh: %s: all %s test files passed.\n' "$label" "$run" >&2
  return 0
}

require_tmux() {
  command -v tmux >/dev/null 2>&1 || {
    printf 'fm-test.sh: tmux is required for e2e tests\n' >&2
    exit 1
  }
  tmux -V >&2
}

# shard_files K N: shard K's files, round-robin over the canonical order.
shard_files() {
  awk -v k="$1" -v n="$2" '((NR - 1) % n) + 1 == k' "$TMP/files"
}

# ============================================================================
# Reference and CI modes: the whole set, and the fixed round-robin partition.
# ============================================================================

run_canonical() {
  local label rc=0
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

  require_tmux
  printf 'fm-test.sh: %s: %s of %s test files assigned.\n' \
    "$label" "$(wc -l <"$TMP/run" | tr -d ' ')" "$total" >&2

  run_files "$TMP/run" - "$TMP/verdicts" || true
  record_timings "$TMP/verdicts"
  report "$label" "$TMP/run" "$TMP/verdicts" || rc=$?
  return "$rc"
}

case "$MODE" in
  whole-set|shard|list-shard) run_canonical; exit $? ;;
esac

# ============================================================================
# Local mode: closure selection + cost-packed parallel shards.
# ============================================================================

PLAN_AWK="$ROOT/bin/fm-test-plan.awk"

# The parity check only re-invokes this script, so it is settled before any of
# the selection inputs are derived.
if [ "$MODE" = verify-parity ]; then
  printf 'fm-test.sh: running the canonical whole set (this is the slow one)...\n' >&2
  ref_rc=0
  FM_TEST_EMIT_VERDICTS="$TMP/ref" FM_TEST_NO_CACHE=1 "$ROOT/bin/fm-test.sh" \
    >"$TMP/ref.out" 2>&1 || ref_rc=$?
  if [ "$ref_rc" -gt 1 ] || [ ! -s "$TMP/ref" ]; then
    printf 'fm-test.sh: PARITY BROKEN - the whole-set run never reached a verdict (exit %s):\n' "$ref_rc" >&2
    tail -40 "$TMP/ref.out" >&2
    exit 1
  fi
  # Both paths must run the SAME files, so the change set is every canonical
  # test file: each is in its own closure, so all of them select and the whole
  # select-pack-parallelise path is exercised over the full suite.
  printf 'fm-test.sh: running the selected, sharded local path...\n' >&2
  loc_rc=0
  FM_TEST_EMIT_VERDICTS="$TMP/loc" FM_TEST_NO_CACHE=1 FM_TEST_CHANGED="$TMP/files" \
    "$ROOT/bin/fm-test.sh" --local >"$TMP/loc.out" 2>&1 || loc_rc=$?
  if grep -q 'running the canonical whole set instead' "$TMP/loc.out"; then
    printf 'fm-test.sh: PARITY BROKEN - the local path fell back to the whole set instead of selecting:\n' >&2
    cat "$TMP/loc.out" >&2
    exit 1
  fi
  if [ "$loc_rc" -gt 1 ] || [ ! -s "$TMP/loc" ]; then
    printf 'fm-test.sh: PARITY BROKEN - the local path never reached a verdict (exit %s):\n' "$loc_rc" >&2
    tail -40 "$TMP/loc.out" >&2
    exit 1
  fi
  if diff -u "$TMP/ref" "$TMP/loc" >"$TMP/diff"; then
    printf 'fm-test.sh: PARITY OK - %s file(s), identical verdicts in both modes.\n' \
      "$(wc -l <"$TMP/ref" | tr -d ' ')" >&2
    exit 0
  fi
  printf 'fm-test.sh: PARITY BROKEN - the local path disagrees with the whole set:\n' >&2
  cat "$TMP/diff" >&2
  exit 1
fi

# whole_set_fallback <reason>: the only sound answer whenever selection cannot
# be derived. Local mode never narrows on a guess.
#
# A listing mode answers the question "what would --local run", so it answers it
# with the whole set's file list, exactly as --list-shard lists without running.
# Escalation is not exotic - any new, still-unreferenced script triggers it, and
# that is precisely when someone runs --list-local to see what was selected - so
# a fallback here must never turn a listing into a full suite execution.
whole_set_fallback() {
  if [ "$MODE" = list-local ]; then
    printf 'fm-test.sh: %s; listing the canonical whole set instead.\n' "$1" >&2
    cat "$TMP/files"
    exit 0
  fi
  printf 'fm-test.sh: %s; running the canonical whole set instead.\n' "$1" >&2
  MODE='whole-set'
  run_canonical
  exit $?
}

BASE_LABEL=''
CHANGED_REASON=''

# derive_changed: write the change set to $TMP/changed, or set CHANGED_REASON
# to the concrete blocker and return 1.
derive_changed() {
  local base cand mb
  if [ -n "${FM_TEST_CHANGED:-}" ]; then
    CHANGED_REASON="the supplied change list $FM_TEST_CHANGED is not a readable file"
    [ -f "$FM_TEST_CHANGED" ] || return 1
    # Every step that produces $TMP/changed guards its own failure. This
    # function is invoked as the left operand of `||`, which suspends set -e
    # inside it, so an unguarded failure here would return 0 with an empty or
    # truncated change set - a green gate that ran nothing, which is the one
    # outcome the escalation design exists to prevent.
    CHANGED_REASON="could not read the supplied change list $FM_TEST_CHANGED"
    LC_ALL=C sort -u "$FM_TEST_CHANGED" >"$TMP/changed" || return 1
    BASE_LABEL="the supplied change list"
    return 0
  fi
  CHANGED_REASON="not inside a git work tree, so there is no baseline to select against"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  base=${FM_TEST_BASE:-}
  if [ -n "$base" ]; then
    CHANGED_REASON="FM_TEST_BASE=$base does not resolve to a commit"
    git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || return 1
  else
    for cand in origin/main main origin/master master; do
      if git rev-parse --verify -q "$cand^{commit}" >/dev/null 2>&1; then
        base=$cand
        break
      fi
    done
  fi
  CHANGED_REASON="no default branch resolves (tried FM_TEST_BASE, origin/main, main, origin/master, master)"
  [ -n "$base" ] || return 1
  CHANGED_REASON="HEAD has no merge base with $base"
  mb=$(git merge-base HEAD "$base" 2>/dev/null) || return 1
  [ -n "$mb" ] || return 1
  CHANGED_REASON="could not diff the working tree against $base"
  # `git diff --name-only <mb>` compares the merge base to the WORKING TREE, so
  # committed, staged and unstaged edits are all in scope; untracked files are
  # collected separately because diff never sees them.
  git diff --name-only "$mb" >"$TMP/changed.raw" 2>/dev/null || return 1
  git ls-files --others --exclude-standard >>"$TMP/changed.raw" 2>/dev/null || true
  CHANGED_REASON="could not assemble the change set derived from $base"
  LC_ALL=C sort -u "$TMP/changed.raw" >"$TMP/changed" || return 1
  BASE_LABEL="$base ($(printf '%.12s' "$mb"))"
  return 0
}

[ -f "$PLAN_AWK" ] || whole_set_fallback "the selection planner $PLAN_AWK is missing"
derive_changed || whole_set_fallback "$CHANGED_REASON"

# The reference universe. A file the planner cannot see is a file it cannot
# attribute, so a repo listing that fails is a fallback, never a narrower run.
git ls-files >"$TMP/tracked" 2>/dev/null || : >"$TMP/tracked"
[ -s "$TMP/tracked" ] || whole_set_fallback "could not list the tracked repo files"

# Only text files carry outgoing references; -I keeps binaries (assets/*.png)
# out of the token scan without excluding them as edge TARGETS. Canonical test
# files are appended so a brand-new, still-untracked test is scanned too.
tr '\n' '\0' <"$TMP/tracked" | xargs -0 -r grep -Il '' -- >"$TMP/scan.raw" 2>/dev/null || true
[ -s "$TMP/scan.raw" ] || cp "$TMP/tracked" "$TMP/scan.raw"
cat "$TMP/files" >>"$TMP/scan.raw"
LC_ALL=C sort -u "$TMP/scan.raw" >"$TMP/scan"

# Tracked symlinks: CLAUDE.md -> AGENTS.md and .claude/skills -> ../.agents/skills
# mean a test naming the link depends on the target, which is the path git
# reports as changed.
: >"$TMP/links"
git ls-files -s 2>/dev/null | awk -F'\t' '$0 ~ /^120000 / { print $2 }' >"$TMP/linkpaths" || true
while IFS= read -r lp; do
  [ -n "$lp" ] || continue
  lt=$(readlink "$lp" 2>/dev/null) || continue
  printf '%s\t%s\n' "$lp" "$lt" >>"$TMP/links"
done <"$TMP/linkpaths"

COSTS=''
if [ "$USE_CACHE" = 1 ] && [ -f "$TIMINGS" ]; then
  COSTS="$TIMINGS"
fi

JOBS="${FM_TEST_JOBS:-}"
if [ -z "$JOBS" ]; then
  # These tests are dominated by real sleeps and multiplexer waits rather than
  # CPU, so shards overlap well - but several of them assert on timing windows
  # (tests/fm-watcher-lock.test.sh's arm race is the known load-sensitive one),
  # and load is exactly what breaks those. Half the cores, clamped, leaves the
  # box responsive enough for those windows to hold.
  JOBS=$(nproc 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null || echo 4)
  JOBS=$((JOBS / 2))
  [ "$JOBS" -ge 2 ] || JOBS=2
  [ "$JOBS" -le 6 ] || JOBS=6
fi
[ "$JOBS" -ge 1 ] || JOBS=1

if [ ! -s "$TMP/changed" ]; then
  printf 'fm-test.sh: local: nothing differs from %s, so no test can be affected; 0 of %s files run.\n' \
    "$BASE_LABEL" "$total" >&2
  exit 0
fi

# WHAT RUNS is derived here, by MODE=select, and NOT from the packer. The packer
# is audited against this list below, which it can only do because the two are
# produced independently: deriving both from the shards output would make the
# audit compare the packer with itself, and a packing bug that dropped a file
# would lower both sides together and still report "all N test files passed".
plan_rc=0
awk -v TRACKED="$TMP/tracked" -v SCAN="$TMP/scan" -v LINKS="$TMP/links" \
    -v FILES="$TMP/files" -v CHANGED="$TMP/changed" -v COSTS="$COSTS" \
    -v JOBS="$JOBS" -v MODE=select -f "$PLAN_AWK" \
    >"$TMP/selected.raw" 2>"$TMP/plan.err" || plan_rc=$?
if [ "$plan_rc" -eq 10 ]; then
  whole_set_fallback "$(head -1 "$TMP/plan.err" | sed 's/^fm-test-plan.awk: //; s/\.$//')"
elif [ "$plan_rc" -ne 0 ]; then
  whole_set_fallback "could not plan the selection ($(tr -d '\n' <"$TMP/plan.err"))"
fi

# The planner reports files it positively determined no test can be affected by,
# so a narrowed run is auditable rather than silently narrow.
[ -s "$TMP/plan.err" ] && sed 's/^fm-test-plan.awk: /fm-test.sh: local: /' "$TMP/plan.err" >&2

LC_ALL=C sort -u "$TMP/selected.raw" >"$TMP/selected"
selected=$(wc -l <"$TMP/selected" | tr -d ' ')
changed_n=$(wc -l <"$TMP/changed" | tr -d ' ')

if [ "$MODE" = list-local ]; then
  cat "$TMP/selected"
  exit 0
fi

if [ "$selected" -eq 0 ]; then
  printf 'fm-test.sh: local: %s changed file(s) against %s, none of them reaching a test; 0 of %s files run.\n' \
    "$changed_n" "$BASE_LABEL" "$total" >&2
  exit 0
fi

# Packing is a SCHEDULING step over the selection above: it may reorder and
# distribute, never add or drop.
pack_rc=0
awk -v TRACKED="$TMP/tracked" -v SCAN="$TMP/scan" -v LINKS="$TMP/links" \
    -v FILES="$TMP/files" -v CHANGED="$TMP/changed" -v COSTS="$COSTS" \
    -v JOBS="$JOBS" -v MODE=shards -f "$PLAN_AWK" \
    >"$TMP/shards" 2>"$TMP/pack.err" || pack_rc=$?
[ "$pack_rc" -eq 0 ] \
  || whole_set_fallback "could not pack the selected files into shards ($(tr -d '\n' <"$TMP/pack.err"))"

# Partition audit, the local counterpart of the CI one: the packed shards must
# disjointly cover exactly the independently derived selection. Sorting with
# duplicates kept means a file packed twice makes the union longer than the
# selection, so this one comparison catches a drop and a double-run alike.
cut -f2 "$TMP/shards" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort >"$TMP/union"
packed_sum=$(wc -l <"$TMP/union" | tr -d ' ')
if [ "$packed_sum" -ne "$selected" ] || ! cmp -s "$TMP/union" "$TMP/selected"; then
  printf 'fm-test.sh: SELECTION PARTITION BROKEN - the packed shards do not disjointly cover the %s selected test file(s); refusing to run.\n' \
    "$selected" >&2
  diff -u "$TMP/selected" "$TMP/union" >&2 || true
  exit 2
fi

require_tmux
nshards=$(wc -l <"$TMP/shards" | tr -d ' ')
printf 'fm-test.sh: local: %s of %s test files selected from %s changed file(s) against %s, in %s parallel shard(s).\n' \
  "$selected" "$total" "$changed_n" "$BASE_LABEL" "$nshards" >&2

# Each shard gets its own TMPDIR and its own multiplexer server directory, so
# parallel shards cannot collide on a fixture path or on a session name inside a
# shared tmux server. TMUX is unset for the same reason: a shard's tests must
# talk to that shard's own server, not to whatever terminal launched the run.
pids=''
sids=''
while IFS="$TAB" read -r sid members; do
  [ -n "$members" ] || continue
  printf '%s\n' "$members" | tr ' ' '\n' | sed '/^$/d' >"$TMP/run.$sid"
  mkdir -p "$TMP/tmp.$sid" "$TMP/mux.$sid"
  (
    export TMPDIR="$TMP/tmp.$sid" TMUX_TMPDIR="$TMP/mux.$sid"
    unset TMUX
    rc=0
    run_files "$TMP/run.$sid" "$TMP/transcript.$sid" "$TMP/verdicts.$sid" || rc=$?
    printf '%s\n' "$rc" >"$TMP/rc.$sid"
    tmux kill-server >/dev/null 2>&1 || true
  ) &
  pids="$pids $!"
  sids="$sids $sid"
done <"$TMP/shards"

for p in $pids; do
  wait "$p" || true
done

: >"$TMP/verdicts"
for sid in $sids; do
  printf -- '--- shard %s (%s file(s)) ---\n' "$sid" "$(wc -l <"$TMP/run.$sid" | tr -d ' ')"
  [ -f "$TMP/transcript.$sid" ] && cat "$TMP/transcript.$sid"
  [ -f "$TMP/verdicts.$sid" ] && cat "$TMP/verdicts.$sid" >>"$TMP/verdicts"
  if [ ! -f "$TMP/rc.$sid" ]; then
    printf 'fm-test.sh: shard %s produced no exit status; its files count as never run.\n' "$sid" >&2
  fi
done

record_timings "$TMP/verdicts"
report "local selection" "$TMP/selected" "$TMP/verdicts"
