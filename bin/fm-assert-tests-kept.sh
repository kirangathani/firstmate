#!/usr/bin/env bash
# Assert a rebase never reduces the test assertions main already had.
#
# The one step where an agent can silently discard work that is not its own is
# rebase conflict resolution. When two branches change the same function, both
# change that function's tests by construction, so a resolver can take one side
# in BOTH the source file and the test file - deleting the other branch's
# functionality AND the test that would have caught it, leaving a green suite.
# The invariant this script checks: every test identifier present on the
# authoritative base (origin/<default>) is still present on the branch under
# review.
#
# Two checks run, because names alone do not catch the motivating scenario:
# a branch that KEEPS a test's name and REWRITES its assertion body passes any
# name comparison while the behavior the base guaranteed is gone.
#
# Check 1 (names): every test identifier on the base must still be present on
# the branch. Identifiers are stable NAMES, never line numbers, compared as
# <file>::<name> pairs so reordering or reformatting never false-positives:
#   - Shell:  tests/*.test.sh (at any depth), each `pass "<name>"` call.
#   - Python: test_*.py / *_test.py, each `def test_*` (async included).
#   - JS/TS:  *.test.<js|jsx|ts|tsx|mjs|cjs> and *.spec.<same>, each
#             it(/test(/describe( first string argument (.only/.skip/.each too).
#
# Check 2 (assertions): run the base's OWN test files against the branch's
# code, so a silently rewritten test body is caught as well as a deleted one.
# Both trees are materialized into a temp dir, each base shell test file is
# first run against the base tree (its baseline must be green for its verdict
# to mean anything), then copied over the branch tree and run there; every
# `ok - <name>` the baseline emitted that the branch run does not is a failing
# assertion. Execution covers shell test files only; non-shell test files, and
# shell files whose baseline run is not green (fixtures or imports that do not
# resolve), are LOUDLY reported on stderr as verified by name only - check 2
# falls back to check 1 for them rather than silently reporting success.
#
# Report only: a legitimately renamed or intentionally removed test IS reported,
# because removing an assertion main already had must be justified, not silent.
# There is no suppression mechanism; the script reports, it does not decide
# (the captain-approved supersession record consulted by bin/fm-pr-merge.sh is
# that script's contract, not this one's).
#
# Usage:
#   fm-assert-tests-kept.sh <task-id>
#       Resolve worktree=, project=, and pr=/pr_head= from state/<id>.meta the
#       same way fm-review-diff.sh does: base is origin/<default> (fetched)
#       for remote-backed projects or the local default branch otherwise, and
#       the compare side is the PR head when pr= is recorded and resolvable,
#       falling back to the local branch fm/<id> with a warning.
#   fm-assert-tests-kept.sh --worktree <path> --base <ref> [--branch <ref>]
#       Explicit mode: enumerate <base> vs <ref> (default HEAD) in <path>.
#
# Output and exit status:
#   - One `missing: <file>::<name>` line on stdout per identifier present on
#     the base and absent from the branch (check 1), and one
#     `failing: <file>::<name>` line per base assertion that passed on the base
#     and did not pass against the branch's code (check 2), plus a count line
#     on stderr; exit 1 when either set is non-empty.
#   - Nothing on stdout and exit 0 when nothing is missing or failing; loud
#     name-check-only WARNING lines may still appear on stderr when check 2
#     could not execute some base test files.
#   - Exit 2 when the check cannot run at all (bad usage, missing meta,
#     missing worktree or project, unresolvable refs), so a caller gating on
#     this script can tell "assertions vanished" from "could not verify".
#
# FM_ASSERT_TESTS_TIMEOUT caps each executed test file's runtime in seconds
# (default 300) when a `timeout` binary exists; a timed-out branch run counts
# as failing, a timed-out baseline run counts as name-check-only fallback.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

# Deterministic collation for sort/comm regardless of the host locale.
export LC_ALL=C

usage() {
  echo "usage: fm-assert-tests-kept.sh <task-id>" >&2
  echo "       fm-assert-tests-kept.sh --worktree <path> --base <ref> [--branch <ref>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

WT=
BASE=
COMPARE_REF=
COMPARE_LABEL=

if [ "${1:-}" = "--worktree" ]; then
  # Explicit mode: --worktree <path> --base <ref> [--branch <ref>]
  [ $# -ge 4 ] || { usage; exit 2; }
  WT=$2
  [ "$3" = "--base" ] || { usage; exit 2; }
  BASE=$4
  shift 4
  case "${1:-}" in
    '') COMPARE_REF=HEAD ;;
    --branch)
      [ $# -eq 2 ] || { usage; exit 2; }
      COMPARE_REF=$2
      ;;
    *) usage; exit 2 ;;
  esac
  COMPARE_LABEL=$COMPARE_REF
  [ -d "$WT" ] || { echo "error: worktree is missing: $WT" >&2; exit 2; }
else
  ID=${1:-}
  [ -n "$ID" ] || { usage; exit 2; }
  [ $# -eq 1 ] || { usage; exit 2; }

  META="$STATE/$ID.meta"
  [ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 2; }

  WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
  PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
  [ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 2; }
  [ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 2; }
  [ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 2; }
  [ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 2; }

  default_branch() {
    local ref branch
    ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -n "$ref" ]; then
      echo "${ref#origin/}"
      return 0
    fi
    for branch in main master; do
      if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
        echo "$branch"
        return 0
      fi
    done
    return 1
  }

  DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 2; }

  BRANCH="fm/$ID"
  if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
    BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 2; }
    git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 2; }
  fi

  pr_number_from_target() {
    local target=$1 n
    case "$target" in
      '' ) return 1 ;;
      *"/pull/"*)
        n=${target##*/pull/}
        n=${n%%[!0-9]*}
        ;;
      [0-9]*)
        n=${target%%[!0-9]*}
        ;;
      *) return 1 ;;
    esac
    [ -n "$n" ] || return 1
    printf '%s' "$n"
  }

  resolve_pr_head() {
    local pr_url=$1 recorded_head=$2 n resolved
    if [ -n "$recorded_head" ] \
      && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
      printf '%s' "$recorded_head"
      return 0
    fi
    n=$(pr_number_from_target "$pr_url") || return 1
    git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
    git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
    resolved=$(git -C "$WT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) || return 1
    [ -n "$resolved" ] || return 1
    printf '%s' "$resolved"
  }

  PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
  COMPARE_REF=$BRANCH
  COMPARE_LABEL=$BRANCH
  if [ -n "$PR_URL" ]; then
    if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
      COMPARE_REF=$PR_HEAD
      COMPARE_LABEL="PR head $(git -C "$WT" rev-parse --short "$PR_HEAD")"
    else
      echo "warning: PR head unavailable; check may lag the open PR (using local branch $BRANCH)" >&2
    fi
  fi

  if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    # Update the remote-tracking ref itself; a bare single-branch fetch can
    # leave origin/<default> stale on some Git versions.
    git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
    BASE="origin/$DEFAULT"
  else
    BASE="$DEFAULT"
  fi
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not resolve in $WT" >&2; exit 2; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 2; }

# --- language classification and name extraction -----------------------------

# lang_for_file <path>: print shell|python|js for a recognized test file,
# nothing otherwise. Shell wins for tests/*.test.sh so firstmate's own suite is
# never mis-scanned by the JS matcher (*.test.* would also match it).
lang_for_file() {
  local f=$1 base
  case "$f" in
    tests/*.test.sh|*/tests/*.test.sh) echo shell; return 0 ;;
  esac
  base=${f##*/}
  case "$base" in
    test_*.py|*_test.py) echo python; return 0 ;;
    *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.test.mjs|*.test.cjs) echo js; return 0 ;;
    *.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|*.spec.mjs|*.spec.cjs) echo js; return 0 ;;
  esac
  return 0
}

# Each extractor reads file content on stdin and prints one test name per line.
# Extraction is purely lexical and identical for both sides of the comparison,
# so a dynamic or oddly-formatted name that extracts the same way on base and
# branch can never produce a false positive on its own.

# Invoked indirectly as "extract_$lang" from enumerate_tests.
# shellcheck disable=SC2329
extract_shell() {
  awk '
    match($0, /(^|[^A-Za-z0-9_])pass[ \t]+"[^"]+"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^.*pass[ \t]+"/, "", s)
      sub(/"$/, "", s)
      print s
    }
  '
}

# Invoked indirectly as "extract_$lang" from enumerate_tests.
# shellcheck disable=SC2329
extract_python() {
  awk '
    match($0, /^[ \t]*(async[ \t]+)?def[ \t]+test_[A-Za-z0-9_]*/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^.*def[ \t]+/, "", s)
      print s
    }
  '
}

# Invoked indirectly as "extract_$lang" from enumerate_tests.
# shellcheck disable=SC2329
extract_js() {
  awk -v sq="'" '
    match($0, /^[ \t]*(it|test|describe)(\.(only|skip|each))?[ \t]*\(/) {
      rest = substr($0, RSTART + RLENGTH)
      sub(/^[ \t]*/, "", rest)
      q = substr(rest, 1, 1)
      if (q != "\"" && q != sq && q != "`") next
      rest = substr(rest, 2)
      i = index(rest, q)
      if (i > 1) print substr(rest, 1, i - 1)
    }
  '
}

# enumerate_tests <ref>: print the sorted unique set of <file>::<name> test
# identifiers reachable at <ref>, reading file content from git objects so the
# working tree state never matters.
enumerate_tests() {
  local ref=$1 f lang name
  git -C "$WT" ls-tree -r -z --name-only "$ref" |
    while IFS= read -r -d '' f; do
      lang=$(lang_for_file "$f")
      [ -n "$lang" ] || continue
      git -C "$WT" show "$ref:$f" 2>/dev/null |
        "extract_$lang" |
        while IFS= read -r name; do
          [ -n "$name" ] || continue
          printf '%s::%s\n' "$f" "$name"
        done
    done | sort -u
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-assert-tests-kept.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# --- check 1: every base test identifier still present by name ---------------

enumerate_tests "$BASE" > "$TMPD/base"
enumerate_tests "$COMPARE_REF" > "$TMPD/branch"
comm -23 "$TMPD/base" "$TMPD/branch" > "$TMPD/missing"

# --- check 2: run the base's own test files against the branch's code --------

TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "${FM_ASSERT_TESTS_TIMEOUT:-300}")
fi

# run_test_file <tree> <file> <out>: run one test file from the tree root with
# firstmate's own env overrides stripped, stdout to <out>, stderr discarded.
run_test_file() {
  local tree=$1 f=$2 out=$3
  (
    cd "$tree" || exit 125
    FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_HOME='' \
      ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} bash "$f"
  ) > "$out" 2>/dev/null
}

# ok_names <run-output> <out>: the sorted unique `ok - <name>` set of one run.
ok_names() {
  sed -n 's/^ok - //p' "$1" | sort -u > "$2"
}

: > "$TMPD/failing"
: > "$TMPD/nameonly"
git -C "$WT" ls-tree -r -z --name-only "$BASE" |
  while IFS= read -r -d '' f; do
    lang=$(lang_for_file "$f")
    [ -n "$lang" ] || continue
    if [ "$lang" = shell ]; then
      printf '%s\n' "$f" >> "$TMPD/shellfiles"
    else
      printf '%s (non-shell test files are not executed)\n' "$f" >> "$TMPD/nameonly"
    fi
  done

if [ -s "$TMPD/shellfiles" ]; then
  mkdir -p "$TMPD/base-tree" "$TMPD/branch-tree"
  git -C "$WT" archive "$BASE" | tar -xf - -C "$TMPD/base-tree"
  git -C "$WT" archive "$COMPARE_REF" | tar -xf - -C "$TMPD/branch-tree"
  while IFS= read -r f; do
    if [ ! -f "$TMPD/base-tree/$f" ]; then
      printf '%s (absent from the materialized base tree)\n' "$f" >> "$TMPD/nameonly"
      continue
    fi
    if run_test_file "$TMPD/base-tree" "$f" "$TMPD/run-base"; then :; else
      printf '%s (fails on the base itself, exit %s)\n' "$f" "$?" >> "$TMPD/nameonly"
      continue
    fi
    # Overlay the base's test file over the branch tree, then run the base's
    # assertions against the branch's code.
    rm -rf "${TMPD:?}/branch-tree/$f"
    mkdir -p "$TMPD/branch-tree/$(dirname "$f")"
    cp "$TMPD/base-tree/$f" "$TMPD/branch-tree/$f"
    branch_rc=0
    run_test_file "$TMPD/branch-tree" "$f" "$TMPD/run-branch" || branch_rc=$?
    ok_names "$TMPD/run-base" "$TMPD/ok-base"
    ok_names "$TMPD/run-branch" "$TMPD/ok-branch"
    comm -23 "$TMPD/ok-base" "$TMPD/ok-branch" > "$TMPD/ok-delta"
    delta_seen=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      delta_seen=1
      # A file check 1 already reported as missing this name would double-report.
      grep -qxF "$f::$name" "$TMPD/missing" && continue
      printf '%s::%s\n' "$f" "$name" >> "$TMPD/failing"
    done < "$TMPD/ok-delta"
    if [ "$branch_rc" -ne 0 ] && [ "$delta_seen" -eq 0 ]; then
      printf '%s::(unnamed assertion; base test file exited %s against the branch)\n' \
        "$f" "$branch_rc" >> "$TMPD/failing"
    fi
  done < "$TMPD/shellfiles"
fi

if [ -s "$TMPD/nameonly" ]; then
  {
    echo "WARNING: check 2 (assertion run) could not execute these base test files;"
    echo "WARNING: their assertions were verified by NAME ONLY (check 1), which does"
    echo "WARNING: NOT catch a kept-name test whose assertion body was rewritten:"
    sed 's/^/WARNING:   name-check only: /' "$TMPD/nameonly"
  } >&2
fi

sort -u "$TMPD/failing" > "$TMPD/failing.sorted"
[ -s "$TMPD/missing" ] || [ -s "$TMPD/failing.sorted" ] || exit 0

while IFS= read -r line; do
  printf 'missing: %s\n' "$line"
done < "$TMPD/missing"
while IFS= read -r line; do
  printf 'failing: %s\n' "$line"
done < "$TMPD/failing.sorted"
MISSING_COUNT=$(grep -c . "$TMPD/missing" || true)
FAILING_COUNT=$(grep -c . "$TMPD/failing.sorted" || true)
echo "error: $MISSING_COUNT test identifier(s) present on $BASE are missing from $COMPARE_LABEL, and $FAILING_COUNT of $BASE's assertion(s) do not pass against $COMPARE_LABEL" >&2
exit 1
