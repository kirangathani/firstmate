#!/usr/bin/env bash
# Assert a rebase never reduces the test assertions the base already had.
#
# The one step where an agent can silently discard work that is not its own is
# rebase conflict resolution. When two branches change the same function, both
# change that function's tests by construction, so a resolver can take one side
# in BOTH the source file and the test file - deleting the other branch's
# functionality AND the test that would have caught it, leaving a green suite.
# The invariant this script checks: every test identifier present on the
# authoritative base is still present on the branch under review. The
# authoritative base is the branch the work actually targets - the PR's own base
# when there is a PR, the project's default branch otherwise (see Usage below) -
# never an assumed default, because a verdict measured against a tree the branch
# was never built on is wrong in both directions.
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
# because removing an assertion the base already had must be justified, not
# silent.
# There is no suppression mechanism; the script reports, it does not decide
# (the captain-approved supersession record consulted by bin/fm-pr-merge.sh is
# that script's contract, not this one's).
#
# Usage:
#   fm-assert-tests-kept.sh <task-id>
#       Resolve worktree=, project=, and pr=/pr_head= from state/<id>.meta. The
#       compare side is the PR head when pr= is recorded and resolvable, falling
#       back to the local branch fm/<id> with a warning.
#       The base is the branch the PR actually TARGETS, never an assumed
#       default: when pr= is recorded, the base branch name is read from GitHub
#       (`gh pr view <url> --json baseRefName`, the same raw-gh JSON read
#       fm-pr-check.sh uses, because gh-axi exposes no baseRefName field), and
#       the check REFUSES with exit 2 when that name cannot be read. Falling
#       back to the default branch there would silently compare a stacked PR
#       against a tree it was never built on, which is exactly the class of
#       wrong-base verdict this gate must not produce; the only caller that
#       records pr= (bin/fm-pr-merge.sh) already requires working GitHub access,
#       so the refusal costs no legitimate workflow. The refusal names the cause
#       it got from gh (gh absent, the query's own failure and stderr, or a name
#       git will not accept as a branch), because a refusal that blocks a merge
#       without saying why leaves the operator with no next step.
#       Both the PR head (refs/pull/<n>/head) and that base branch are fetched
#       from the worktree's origin, which is only correct if origin IS the PR's
#       repository, so a recorded pr= whose owner/repo is a GitHub repo OTHER
#       than origin's REFUSES with exit 2 before either fetch, naming both sides.
#       Fetching there would compare the branch against a same-named branch in
#       the wrong repository, the same class of wrong-base verdict as assuming
#       the default. Each side is read by the bin/fm-pr-lib.sh parser that owns
#       its input type - fm_pr_url_parse for the PR link, fm_pr_remote_parse for
#       origin's address - and compared through fm_pr_github_slug_fold, so the
#       host and owner/repo rule has one owner rather than a copy per caller.
#       The refusal names both owner/repo pairs and never origin's raw address,
#       which can carry an embedded credential that this script's unredirected
#       stderr would then put in the merge output and any CI log.
#       DELIBERATE BOUNDARY: when origin's URL is not a GitHub owner/repo at all
#       (a local path, a bare mirror, a self-hosted or non-GitHub remote) the
#       mismatch is not determinable, so the check does NOT refuse and fetching
#       from origin holds, exactly as it already does when resolving the PR head.
#       This closes the wrong-GitHub-repository hole; it is not a general
#       remote-identity check.
#       When no pr= is recorded (local-only merges), the base is the project's
#       default branch as before. Either way the base is origin/<branch>
#       (fetched) for remote-backed projects and the local branch otherwise.
#   fm-assert-tests-kept.sh --worktree <path> --base <ref> [--branch <ref>]
#       Explicit mode: enumerate <base> vs <ref> (default HEAD) in <path>.
#
# Output and exit status. stdout is strictly line-oriented so a gate or a viewer
# can parse it; the human-facing diagnostic blobs go to stderr. One base line,
# five finding prefixes and one summary line are the stable contract:
#   - `base: <ref> (<origin>)` always, as the FIRST line, naming the ref both
#     checks compared against and where that ref came from - the PR's own base
#     branch, the project's default branch, or the caller's explicit --base - so
#     an operator reading the gate's output can tell a PR-derived base from an
#     assumed one without re-deriving it.
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
#   - `summary: missing=<n> failing=<n> unexecuted=<n> skipped=<n>
#     unaccounted=<n>` always, as the last line, whether or not anything was
#     found.
#   - Exit 1 when ANY of `missing:`, `failing:` or `unexecuted:` is non-empty,
#     exit 0 when all three are empty. `skipped:` and `unaccounted:` are
#     reported but do NOT affect the exit code. This script reports; it does not
#     decide which classes block a merge (that is bin/fm-pr-merge.sh's contract,
#     not this one's).
#   - Exit 2 when the check cannot run at all, so a caller gating on this
#     script can tell "assertions vanished" from "could not verify": bad usage,
#     missing meta, missing worktree or project, unresolvable refs, and every
#     way the base itself cannot be established honestly - an unreadable PR base
#     branch, a recorded PR in a GitHub repository other than origin's, or a
#     base branch that could not be fetched from origin.
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

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
BASE_ORIGIN=
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
  # Explicit mode takes the caller's ref verbatim and never consults GitHub:
  # its caller (bin/fm-nm-flow.sh --tests-gate, an operator) already knows the
  # base it means, and a lookup here would only be able to disagree with it.
  BASE_ORIGIN='explicit --base'
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

  # resolve_pr_base <pr-url> <diagnostic-file>: print the branch name the PR
  # targets, read from GitHub. gh-axi is this repo's GitHub interface for
  # ACTIONS, but its `pr view` exposes no baseRefName field, so this is a raw-gh
  # JSON read exactly as fm-pr-check.sh's headRefOid lookup is. The URL fully
  # qualifies the repo; the cd into the worktree only supplies gh's repo context
  # if it ever needs one.
  # Unlike fm-pr-check.sh, whose lookup falls back softly, a failure here is a
  # HARD refusal that blocks a merge, so the cause must reach the operator
  # instead of being discarded: the distinguishable causes are written to
  # <diagnostic-file> along with gh's own verbatim stderr, and the caller prints
  # that block beneath the refusal.
  resolve_pr_base() {
    local pr_url=$1 diag=$2 err="$2.gh" name rc=0
    : > "$diag"
    : > "$err"
    if ! command -v gh >/dev/null 2>&1; then
      printf 'gh is not installed\n' > "$diag"
      return 1
    fi
    name=$(cd "$WT" && gh pr view "$pr_url" --json baseRefName -q .baseRefName 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      { printf 'the gh query failed (exit %s)\n' "$rc"; cat "$err"; } > "$diag"
      return 1
    fi
    if [ -z "$name" ]; then
      { printf 'the gh query succeeded but reported no base branch name\n'; cat "$err"; } > "$diag"
      return 1
    fi
    # The name goes into a refspec, so it must be a name git itself accepts as a
    # branch; anything else is rejected rather than interpolated.
    if ! git check-ref-format "refs/heads/$name" 2>"$err"; then
      { printf 'gh reported %s, which git does not accept as a branch name\n' "$name"; cat "$err"; } > "$diag"
      return 1
    fi
    printf '%s' "$name"
  }

  # assert_pr_repo_is_origin <pr-url>: refuse when the PR lives in a GitHub
  # repository other than the one origin points at. Both PR-derived fetches
  # below read from origin, so a determinable mismatch would silently measure
  # the verdict against a same-named branch in the wrong repository.
  # Each side is read by the bin/fm-pr-lib.sh parser that owns ITS input type -
  # a PR link and a git remote address are different grammars - and the two are
  # compared through that library's fold, so the host and owner/repo rule cannot
  # be read one way here and another way there.
  # Origin's raw address is deliberately NOT echoed: it can carry an embedded
  # credential, and bin/fm-pr-merge.sh redirects this script's stdout but not its
  # stderr, so the token would reach the merge output and any CI log. The
  # owner/repo pair already names the side that is wrong.
  assert_pr_repo_is_origin() {
    local pr_url=$1 origin_url pr_slug origin_slug
    fm_pr_url_parse "$pr_url" || return 0
    pr_slug=$(fm_pr_github_slug_fold "$FM_PR_OWNER" "$FM_PR_REPO")
    origin_url=$(git -C "$WT" remote get-url origin 2>/dev/null || true)
    [ -n "$origin_url" ] || return 0
    fm_pr_remote_parse "$origin_url" || return 0
    origin_slug=$(fm_pr_github_slug_fold "$FM_PR_REMOTE_OWNER" "$FM_PR_REMOTE_REPO")
    [ "$pr_slug" != "$origin_slug" ] || return 0
    echo "error: PR $pr_url targets $FM_PR_OWNER/$FM_PR_REPO but this worktree's origin is $FM_PR_REMOTE_OWNER/$FM_PR_REMOTE_REPO; refusing rather than fetching a same-named branch from the wrong repository" >&2
    exit 2
  }

  PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
  COMPARE_REF=$BRANCH
  COMPARE_LABEL=$BRANCH
  if [ -n "$PR_URL" ]; then
    # Asserted before ANY PR-derived ref is fetched, because the head fetch just
    # below reads refs/pull/<n>/head from origin on the same assumption the base
    # fetch further down makes.
    assert_pr_repo_is_origin "$PR_URL"
    if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
      COMPARE_REF=$PR_HEAD
      COMPARE_LABEL="PR head $(git -C "$WT" rev-parse --short "$PR_HEAD")"
    else
      echo "warning: PR head unavailable; check may lag the open PR (using local branch $BRANCH)" >&2
    fi
  fi

  # The base is the branch the PR TARGETS whenever a PR is recorded, and only
  # the project's default branch when none is. A recorded PR whose base cannot
  # be read refuses rather than falling back: see this script's header.
  if [ -n "$PR_URL" ]; then
    # A private 0700 directory, so the diagnostic and its sibling capture file
    # cannot be pre-created as symlinks by another user on a shared /tmp.
    PR_BASE_DIAG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-assert-tests-kept-prbase.XXXXXX")
    PR_BASE_DIAG="$PR_BASE_DIAG_DIR/cause"
    BASE_BRANCH=$(resolve_pr_base "$PR_URL" "$PR_BASE_DIAG") || {
      echo "error: cannot read the base branch of $PR_URL from GitHub; refusing rather than assuming the default branch, which would compare the branch against a base the PR was never built on" >&2
      if [ -s "$PR_BASE_DIAG" ]; then
        echo "error: cause:" >&2
        sed 's/^/error:   /' "$PR_BASE_DIAG" >&2
      fi
      rm -rf "$PR_BASE_DIAG_DIR"
      exit 2
    }
    rm -rf "$PR_BASE_DIAG_DIR"
    BASE_ORIGIN="base branch of $PR_URL"
  else
    BASE_BRANCH=$DEFAULT
    BASE_ORIGIN="default branch of $PROJ"
  fi

  if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    # Update the remote-tracking ref itself; a bare single-branch fetch can
    # leave origin/<branch> stale on some Git versions.
    git -C "$WT" fetch origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" --quiet || {
      echo "error: cannot fetch base branch $BASE_BRANCH ($BASE_ORIGIN) from origin in $WT" >&2
      exit 2
    }
    BASE="origin/$BASE_BRANCH"
  else
    BASE="$BASE_BRANCH"
  fi
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not resolve in $WT" >&2; exit 2; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 2; }

# Name the base and its provenance before any finding, so the verdict below is
# never read without knowing which tree it was measured against.
printf 'base: %s (%s)\n' "$BASE" "$BASE_ORIGIN"

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
      delta_seen=1
      # A file check 1 already reported as missing this name would double-report.
      if grep -qxF "$f::$name" "$TMPD/missing"; then
        continue
      fi
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
    idents_for_file "$f" | sort -u > "$TMPD/requested"
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

MISSING_COUNT=$(grep -c . "$TMPD/missing" || true)
FAILING_COUNT=$(grep -c . "$TMPD/failing.sorted" || true)
UNEXEC_COUNT=$(grep -c . "$TMPD/unexec.sorted" || true)
SKIPPED_COUNT=$(grep -c . "$TMPD/skipped.sorted" || true)
UNACCOUNTED_COUNT=$(grep -c . "$TMPD/unaccounted.sorted" || true)
printf 'summary: missing=%s failing=%s unexecuted=%s skipped=%s unaccounted=%s\n' \
  "$MISSING_COUNT" "$FAILING_COUNT" "$UNEXEC_COUNT" \
  "$SKIPPED_COUNT" "$UNACCOUNTED_COUNT"

if [ "$MISSING_COUNT" -eq 0 ] && [ "$FAILING_COUNT" -eq 0 ] && [ "$UNEXEC_COUNT" -eq 0 ]; then
  exit 0
fi
echo "error: $MISSING_COUNT test identifier(s) present on $BASE are missing from $COMPARE_LABEL, $FAILING_COUNT of $BASE's assertion(s) do not pass against $COMPARE_LABEL, and $UNEXEC_COUNT could not be executed at all" >&2
exit 1
