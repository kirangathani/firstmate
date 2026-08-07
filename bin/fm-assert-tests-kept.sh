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
# Both trees are materialized into a temp dir, each base test file is first run
# against the base tree (its baseline must be green for its verdict to mean
# anything), then copied over the branch tree and run there; every assertion the
# baseline recorded as passing that the branch run does not is a failing
# assertion.
#
# Check 2 compares names the two runs EMITTED, so it only means anything while
# those names are stable. A name built from a runtime value - a measured
# duration, a pane or container id, a count derived from the tree under test - is
# a different string on every run, and a set difference then reads one passing
# assertion as an assertion that vanished. So check 2 refuses to compare a name
# it cannot also resolve in check 1's STATIC extraction of the same base file,
# and reports it as `unstable:` instead of `failing:`. That refusal is the
# script's own stated invariant applied to check 2 (identifiers are stable NAMES,
# see check 1 above), and it blocks like the other check-2 classes: an assertion
# whose identity moves is one the gate has never been able to verify - check 1
# requests the literal unexpanded source string, which no run can ever report,
# so it lands in `unaccounted:` on every run - and a green result over a name
# that means something different each time reads as verified while proving
# nothing. Turning that into a non-blocking note would trade a loud wrong answer
# for a quiet no-answer. The fix belongs in the TEST: name the assertion with a
# constant string and put the runtime value in its fail message.
#
# A base test file check 2 could not actually execute is NOT a pass. Each of its
# identifiers is reported as `unexecuted:`, because a bare green result that
# means "nothing was run" reads as verified while catching nothing - the precise
# failure this check exists to prevent. A file is unexecuted when no supported
# runner resolves for it, when its baseline run is not green (fixtures or imports
# that do not resolve), or when the scratch tree could not be proven
# authoritative for the code under test.
#
# A GREEN baseline run has the same hole one level down: it can exit zero having
# verified only some of the identifiers it was bounded to, or none of them. So
# every identifier the run was bounded to is accounted for individually, and the
# two ways it can fail to be a pass are reported separately:
#   - `skipped:`     the runner reported an EXPLICIT skip for it. Accounted for,
#                    and specifically NOT unexecuted.
#   - `unaccounted:` the run produced no result for it at all - no testcase in
#                    the report, a report that is missing/empty/unparseable, or
#                    (shell runner) no `ok - <name>` line.
# A requested identifier and a runner's own names are two different namespaces,
# so accounting matches a bare name against the runner's own naming (pytest's
# `<name>[...]` parametrized cases, the JS runners' composed `a > b` titles) and
# lets passing win over skipped; bin/fm-test-exec-lib.sh's
# fm_reported_name_accounts and its identifier-scheme notes own that rule.
# NEITHER class affects this script's exit code in this PR: exit 1 stays driven
# only by `missing:`, `failing:` and `unexecuted:`. The point of the change is to
# make a green-but-empty run VISIBLE where it previously read as verified, not to
# add a merge-refusing condition.
#
# Two limits are carried forward here rather than hidden:
#   (i)  a skipif that is true only because of the SCRATCH environment is
#        indistinguishable from a deliberate skip in the runner's report, so it
#        lands in `skipped:`; this change does not close that.
#   (ii) a missing or unparseable results file lands in `unaccounted:` rather
#        than `unexecuted:` precisely because that would be a new merge-refusing
#        condition; mapping finding classes to what blocks a merge is
#        bin/fm-pr-merge.sh's contract.
#
# The per-language detect/run/parse mechanics of check 2, the scratch-tree
# lifecycle, and the reason a scratch tree can fail to be authoritative are all
# owned by bin/fm-test-exec-lib.sh; this script orchestrates them.
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
# Output and exit status. stdout is strictly line-oriented so a gate or a viewer
# can parse it; the human-facing diagnostic blobs go to stderr. Six finding
# prefixes and one summary line are the stable contract:
#   - `missing: <file>::<name>` per identifier present on the base and absent
#     from the branch (check 1).
#   - `failing: <file>::<name>` per base assertion that passed on the base and
#     did not pass against the branch's code (check 2).
#   - `unexecuted: <file>::<name>` per identifier check 2 could not actually
#     run, with the reason and the verbatim captured output on stderr.
#   - `skipped: <file>::<name>` per identifier a green baseline run reported an
#     explicit skip for.
#   - `unaccounted: <file>::<name>` per identifier a green baseline run produced
#     no result for at all.
#   - `unstable: <file>::<name>` per base-run assertion name check 2 could not
#     resolve in check 1's static extraction of the same file, so the two runs
#     could not be compared over it. <name> is the name the BASE RUN reported,
#     which is evidence of what actually moved rather than a static identifier;
#     it differs run to run by definition, so a supersession over one needs the
#     `ids:` glob form, and fixing the test is the real answer.
#   - `summary: missing=<n> failing=<n> unexecuted=<n> skipped=<n>
#     unaccounted=<n> unstable=<n>` always, as the last line, whether or not
#     anything was found. `unstable=` is appended LAST so every existing prefix
#     match of this line keeps working.
#   - Exit 1 when ANY of `missing:`, `failing:`, `unexecuted:` or `unstable:` is
#     non-empty, exit 0 when all four are empty. `skipped:` and `unaccounted:`
#     are reported but do NOT affect the exit code. This script reports; it does
#     not decide which classes block a merge (that is bin/fm-pr-merge.sh's
#     contract, not this one's).
#   - Exit 2 when the check cannot run at all (bad usage, missing meta,
#     missing worktree or project, unresolvable refs), so a caller gating on
#     this script can tell "assertions vanished" from "could not verify".
#
# FM_ASSERT_TESTS_TIMEOUT caps each executed test file's runtime in seconds
# (default 300) when a `timeout` binary exists; a timed-out branch run counts
# as failing, a timed-out baseline run counts as unexecuted.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

# shellcheck source=bin/fm-test-exec-lib.sh
. "$SCRIPT_DIR/fm-test-exec-lib.sh"

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
# The env links MUST be unlinked before the recursive delete, so cleanup can
# never traverse one into the live worktree's real dependency dirs.
trap 'cleanup_scratch_env "$TMPD/base-tree"; cleanup_scratch_env "$TMPD/branch-tree"; rm -rf "$TMPD"' EXIT

# The library's probes are reached through command substitution (a subshell), so
# they memoize to files rather than to variables; give them somewhere to write
# that this run's cleanup already owns.
FM_TEST_EXEC_CACHE_DIR="$TMPD/probe-cache"
mkdir -p "$FM_TEST_EXEC_CACHE_DIR"

# --- check 1: every base test identifier still present by name ---------------

enumerate_tests "$BASE" > "$TMPD/base"
enumerate_tests "$COMPARE_REF" > "$TMPD/branch"
comm -23 "$TMPD/base" "$TMPD/branch" > "$TMPD/missing"

# --- check 2: run the base's own test files against the branch's code --------
# The runner interface (runner_for_file / run_base_test_file / passing_idents)
# and the scratch-tree lifecycle (prepare_scratch_env / scratch_untrusted_reason
# / cleanup_scratch_env) are owned by bin/fm-test-exec-lib.sh, sourced above.

: > "$TMPD/failing"
: > "$TMPD/unexec"
: > "$TMPD/unexec-report"
: > "$TMPD/execfiles"
: > "$TMPD/skipped"
: > "$TMPD/unaccounted"
: > "$TMPD/unstable"
: > "$TMPD/unstable-report"

# idents_for_file <file>: the check-1 identifiers the base enumerated for <file>.
# They are both what a run is bounded to and what an unexecuted file reports.
idents_for_file() {
  local f=$1 ident
  while IFS= read -r ident; do
    case "$ident" in "$f::"*) printf '%s\n' "$ident" ;; esac
  done < "$TMPD/base"
}

# name_accounted <spec> <name> <names-file>: succeed when <names-file> holds a
# runner name that accounts for check 1's bare <name>. The two namespaces are
# not the same and the reconciliation rule is per-runner, so each line is judged
# by bin/fm-test-exec-lib.sh's fm_reported_name_accounts, which owns that rule.
name_accounted() {
  local spec=$1 name=$2 file=$3 reported
  while IFS= read -r reported; do
    [ -n "$reported" ] || continue
    if fm_reported_name_accounts "$spec" "$name" "$reported"; then
      return 0
    fi
  done < "$file"
  return 1
}

# runtime_name_resolves <spec> <file> <reported>: succeed when check 1's STATIC
# extraction of <file> holds an identifier that accounts for the runtime name
# <reported>. This is name_accounted's predicate run in the other direction, and
# it is what stops check 2 comparing a name it cannot statically resolve. Reads
# $TMPD/requested, so that file must already hold this file's identifiers.
runtime_name_resolves() {
  local spec=$1 f=$2 reported=$3 ident
  while IFS= read -r ident; do
    [ -n "$ident" ] || continue
    if fm_reported_name_accounts "$spec" "${ident#"$f::"}" "$reported"; then
      return 0
    fi
  done < "$TMPD/requested"
  return 1
}

# mark_unstable <file> <reported>: report one base-run name check 2 could not
# resolve statically, and record the human-facing explanation.
mark_unstable() {
  local f=$1 reported=$2
  printf '%s::%s\n' "$f" "$reported" >> "$TMPD/unstable"
  {
    printf 'UNSTABLE IDENTITY: %s\n' "$f"
    printf '  the base run reported this passing assertion: %s\n' "$reported"
    printf '  the branch run of the SAME (base) test file reported no such name, and\n'
    printf "  check 1's static extraction of that file cannot resolve it either, so the\n"
    printf '  two runs named one assertion two different ways and nothing was compared.\n'
    printf '  This is a defect in the TEST, not in the branch under review: make the\n'
    printf "  assertion's name a constant string and move the runtime value into its\n"
    printf '  fail message, which is where a measured number is diagnostic.\n'
  } >> "$TMPD/unstable-report"
}

# record_ident <dest> <ident>: append <ident> to <dest>, dropping one check 1
# already reported as missing so it is never double-reported.
record_ident() {
  local dest=$1 ident=$2
  if grep -qxF "$ident" "$TMPD/missing"; then
    return 0
  fi
  printf '%s\n' "$ident" >> "$dest"
}

# mark_unexecuted <file> <reason> [<captured-output-file>]: report every check-1
# identifier in <file> as unexecuted, and record the human-facing reason block.
mark_unexecuted() {
  local f=$1 reason=$2 captured=${3:-} ident recorded=0
  while IFS= read -r ident; do
    # An identifier check 1 already reported as missing would double-report.
    if grep -qxF "$ident" "$TMPD/missing"; then
      continue
    fi
    printf '%s\n' "$ident" >> "$TMPD/unexec"
    recorded=1
  done < <(idents_for_file "$f")
  # Nothing left to report means nothing to explain; stay quiet.
  [ "$recorded" -eq 1 ] || return 0
  {
    printf 'UNEXECUTED: %s (%s)\n' "$f" "$reason"
    if [ -n "$captured" ] && [ -s "$captured" ]; then
      printf -- '----- captured baseline output -----\n'
      cat "$captured"
      printf -- '----- end -----\n'
    fi
  } >> "$TMPD/unexec-report"
}

git -C "$WT" ls-tree -r -z --name-only "$BASE" |
  while IFS= read -r -d '' f; do
    lang=$(lang_for_file "$f")
    [ -n "$lang" ] || continue
    spec=$(runner_for_file "$WT" "$f")
    if [ -z "$spec" ]; then
      mark_unexecuted "$f" 'no supported test runner resolves for this file'
      continue
    fi
    # The spec's own fields are tab-separated, so the file goes last.
    printf '%s\t%s\n' "$spec" "$f" >> "$TMPD/execfiles"
  done

if [ -s "$TMPD/execfiles" ]; then
  mkdir -p "$TMPD/base-tree" "$TMPD/branch-tree"
  git -C "$WT" archive "$BASE" | tar -xf - -C "$TMPD/base-tree"
  git -C "$WT" archive "$COMPARE_REF" | tar -xf - -C "$TMPD/branch-tree"
  while IFS= read -r entry; do
    spec=${entry%$'\t'*}
    f=${entry##*$'\t'}
    if [ ! -f "$TMPD/base-tree/$f" ]; then
      mark_unexecuted "$f" 'absent from the materialized base tree'
      continue
    fi
    # Bound the run to exactly what check 1 enumerated for this file. An empty
    # set is passed through rather than skipped: a runner that needs nodeids
    # refuses (and reports nothing, since there is nothing to report), while the
    # shell runner still runs the file and can surface an unnamed breakage.
    idents=()
    while IFS= read -r ident; do
      idents+=("$ident")
    done < <(idents_for_file "$f")
    # The same set as a file, needed BEFORE the runs by runtime_name_resolves and
    # again after them by the accounting loop below.
    idents_for_file "$f" | sort -u > "$TMPD/requested"
    # Run against the branch worktree's already-provisioned environment, linked
    # into the scratch trees so the live worktree is never mutated.
    prepare_scratch_env "$spec" "$TMPD/base-tree" "$WT"
    prepare_scratch_env "$spec" "$TMPD/branch-tree" "$WT"
    untrusted=
    for tree in base-tree branch-tree; do
      untrusted=$(scratch_untrusted_reason "$spec" "$TMPD/$tree" "$WT" "$f")
      [ -z "$untrusted" ] || break
    done
    if [ -n "$untrusted" ]; then
      mark_unexecuted "$f" "$untrusted"
      continue
    fi
    base_rc=0
    run_base_test_file "$spec" "$TMPD/base-tree" "$f" \
      "$TMPD/run-base" "$TMPD/run-base.err" ${idents[@]+"${idents[@]}"} || base_rc=$?
    if [ "$base_rc" -ne 0 ]; then
      mark_unexecuted "$f" "fails on the base itself, exit $base_rc" "$TMPD/run-base.err"
      continue
    fi
    # Overlay the base's test file over the branch tree, then run the base's
    # assertions against the branch's code.
    rm -rf "${TMPD:?}/branch-tree/$f"
    mkdir -p "$TMPD/branch-tree/$(dirname "$f")"
    cp "$TMPD/base-tree/$f" "$TMPD/branch-tree/$f"
    branch_rc=0
    run_base_test_file "$spec" "$TMPD/branch-tree" "$f" \
      "$TMPD/run-branch" "$TMPD/run-branch.err" ${idents[@]+"${idents[@]}"} || branch_rc=$?
    passing_idents "$spec" "$TMPD/run-base" "$TMPD/base-tree/$f" > "$TMPD/ok-base"
    passing_idents "$spec" "$TMPD/run-branch" "$TMPD/branch-tree/$f" > "$TMPD/ok-branch"
    comm -23 "$TMPD/ok-base" "$TMPD/ok-branch" > "$TMPD/ok-delta"
    delta_seen=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # A file check 1 already reported as missing this name would double-report.
      if grep -qxF "$f::$name" "$TMPD/missing"; then
        delta_seen=1
        continue
      fi
      # A name check 1's static extraction cannot resolve is not comparable: the
      # two runs may simply have named one assertion two ways (header contract).
      # It deliberately does NOT count as an attributed delta, so a non-zero
      # branch run alongside only unstable names still reports its unnamed
      # failure below rather than being explained away by a naming defect.
      if ! runtime_name_resolves "$spec" "$f" "$name"; then
        mark_unstable "$f" "$name"
        continue
      fi
      delta_seen=1
      printf '%s::%s\n' "$f" "$name" >> "$TMPD/failing"
    done < "$TMPD/ok-delta"
    if [ "$branch_rc" -ne 0 ] && [ "$delta_seen" -eq 0 ]; then
      printf '%s::(unnamed assertion; base test file exited %s against the branch)\n' \
        "$f" "$branch_rc" >> "$TMPD/failing"
    fi
    # A green baseline is not the same as a baseline that verified everything it
    # was bounded to. Account for each requested identifier against what the
    # BASELINE actually recorded: an explicit skip is accounted for, and anything
    # the run produced no result for at all was never verified and must not be
    # counted as one. Neither class changes this script's exit code.
    # Matching is a PREDICATE across two namespaces, not line equality, so this
    # classifies each requested identifier in turn rather than using comm.
    # Passing wins outright: one passing case of a parametrized name means the
    # baseline verified that name, whatever its other cases did.
    skipped_idents "$spec" "$TMPD/run-base" "$TMPD/base-tree/$f" > "$TMPD/skip-base"
    while IFS= read -r ident; do
      [ -n "$ident" ] || continue
      name=${ident#"$f::"}
      if name_accounted "$spec" "$name" "$TMPD/ok-base"; then
        continue
      fi
      if name_accounted "$spec" "$name" "$TMPD/skip-base"; then
        record_ident "$TMPD/skipped" "$ident"
      else
        record_ident "$TMPD/unaccounted" "$ident"
      fi
    done < "$TMPD/requested"
  done < "$TMPD/execfiles"
fi

sort -u "$TMPD/failing" > "$TMPD/failing.sorted"
sort -u "$TMPD/unexec" > "$TMPD/unexec.sorted"
sort -u "$TMPD/skipped" > "$TMPD/skipped.sorted"
sort -u "$TMPD/unaccounted" > "$TMPD/unaccounted.sorted"
sort -u "$TMPD/unstable" > "$TMPD/unstable.sorted"

if [ -s "$TMPD/unstable-report" ]; then
  {
    echo "WARNING: check 2 could not COMPARE these assertions, because the base test"
    echo "WARNING: file named them differently on its two runs. Each is reported as"
    echo "WARNING: 'unstable:' on stdout and blocks like any other check-2 finding: an"
    echo "WARNING: assertion whose name moves has never been verifiable by this gate,"
    echo "WARNING: and a green run over a name that changes every time proves nothing."
    cat "$TMPD/unstable-report"
  } >&2
fi

if [ -s "$TMPD/unexec-report" ]; then
  {
    echo "WARNING: check 2 (assertion run) could not execute these base test files."
    echo "WARNING: Every identifier in them is reported as 'unexecuted:' on stdout,"
    echo "WARNING: NOT as a pass: a kept name whose assertion body was rewritten is"
    echo "WARNING: exactly what a name-only check does not catch."
    cat "$TMPD/unexec-report"
  } >&2
fi

while IFS= read -r line; do
  printf 'missing: %s\n' "$line"
done < "$TMPD/missing"
while IFS= read -r line; do
  printf 'failing: %s\n' "$line"
done < "$TMPD/failing.sorted"
while IFS= read -r line; do
  printf 'unexecuted: %s\n' "$line"
done < "$TMPD/unexec.sorted"
while IFS= read -r line; do
  printf 'skipped: %s\n' "$line"
done < "$TMPD/skipped.sorted"
while IFS= read -r line; do
  printf 'unaccounted: %s\n' "$line"
done < "$TMPD/unaccounted.sorted"
while IFS= read -r line; do
  printf 'unstable: %s\n' "$line"
done < "$TMPD/unstable.sorted"

MISSING_COUNT=$(grep -c . "$TMPD/missing" || true)
FAILING_COUNT=$(grep -c . "$TMPD/failing.sorted" || true)
UNEXEC_COUNT=$(grep -c . "$TMPD/unexec.sorted" || true)
SKIPPED_COUNT=$(grep -c . "$TMPD/skipped.sorted" || true)
UNACCOUNTED_COUNT=$(grep -c . "$TMPD/unaccounted.sorted" || true)
UNSTABLE_COUNT=$(grep -c . "$TMPD/unstable.sorted" || true)
printf 'summary: missing=%s failing=%s unexecuted=%s skipped=%s unaccounted=%s unstable=%s\n' \
  "$MISSING_COUNT" "$FAILING_COUNT" "$UNEXEC_COUNT" \
  "$SKIPPED_COUNT" "$UNACCOUNTED_COUNT" "$UNSTABLE_COUNT"

if [ "$MISSING_COUNT" -eq 0 ] && [ "$FAILING_COUNT" -eq 0 ] && [ "$UNEXEC_COUNT" -eq 0 ] \
  && [ "$UNSTABLE_COUNT" -eq 0 ]; then
  exit 0
fi
echo "error: $MISSING_COUNT test identifier(s) present on $BASE are missing from $COMPARE_LABEL, $FAILING_COUNT of $BASE's assertion(s) do not pass against $COMPARE_LABEL, $UNEXEC_COUNT could not be executed at all, and $UNSTABLE_COUNT could not be compared because the base test file named them differently on its two runs" >&2
exit 1
