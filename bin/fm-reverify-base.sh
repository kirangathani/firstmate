#!/usr/bin/env bash
# Re-verify a branch against a base that has moved, WITHOUT re-driving CI.
#
# THE PROBLEM. GitHub runs a PR's checks only when the PR's own head changes,
# never when the base moves. On 2026-08-09 PRs 31-36 all still showed green
# measured against a base four later merges had replaced. The only remedy the
# platform offers is to push the branch again, which re-runs everything: four
# behaviour shards, lint, repo invariants, and the macOS stock-Bash check, for
# every open PR, every time main moves.
#
# THE CHEAP PATH. The question a moved base actually raises is narrow: do the
# base's CURRENT test assertions still hold against this branch's code? Almost
# every base test file is byte-identical to the branch's copy, and the branch's
# own verified-green suite already ran those. Only the files that DIFFER need
# running here. That selection is not implemented in this file and must never
# be: bin/fm-assert-tests-kept.sh is its single owner, and this script is a
# THIN caller of it - it forwards its arguments verbatim, reads the owner's
# stable stdout contract, and renders the verdict. Measured on firstmate
# (2026-08-09, PR #54): 2 of 85 base test files needed running, 166s against
# 2484s for the full pass.
#
# WHAT IT DOES NOT ANSWER, stated because a narrower check that reads as a
# broader one is the failure this gate family exists to prevent: it re-runs the
# base's ASSERTIONS against the branch's tree. It does not merge the base's
# source into the branch, so it cannot see a semantic conflict between the two
# sets of changes. Merging the moved base forward and re-verifying remains the
# complete answer; this is the fast, cheap first read, never its replacement.
#
# THREE OUTCOMES, NEVER TWO. A check that renders "nothing was left to run" the
# same way as "everything ran and held" turns a never-evaluated result into a
# pass, so the first stdout line is always exactly one of:
#   reverify: verified          the base's assertions were RE-RUN against this
#                               branch and held (executed-files >= 1, no
#                               findings). Exit 0.
#   reverify: nothing-to-verify determinate, and NOT a pass over anything: every
#                               one of the base's test files is byte-identical
#                               to the branch's copy, which the branch's own
#                               verified-green suite already ran, so no
#                               assertion was left for this check to re-run
#                               (executed-files = 0, no findings). Exit 0.
#   reverify: not-verified      the base's assertions did NOT hold: an
#                               identifier the base had is missing from the
#                               branch, or one of its assertions failed against
#                               the branch's code. Exit 1.
#   reverify: could-not-verify  no verdict could be established. Exit 1, because
#                               a required check that goes green when it could
#                               not run is the exact false green this whole gate
#                               family exists to eliminate.
#
# EVERY WAY IT CAN FAIL TO EVALUATE IS could-not-verify, never a pass:
#   - the owner refused outright (its exit 2: bad usage, missing worktree,
#     unresolvable ref, an unreadable or wrong-repository PR base);
#   - the owner reported `unexecuted:` or `unstable:` findings, which are
#     precisely "this assertion has never been verifiable here";
#   - the owner exited on a signal or any code its contract does not define;
#   - the owner printed no `summary:` line, or one carrying no readable
#     `executed-files=` field. A green exit whose evidence cannot be read is
#     indistinguishable from a green exit that verified nothing, so it is
#     treated as the latter;
#   - the owner exited 0 while its own summary reports findings, or exited 1
#     while reporting none. Either way its two statements disagree and neither
#     can be trusted.
#
# Usage:
#   fm-reverify-base.sh <arg>...
#       Every argument is forwarded VERBATIM to bin/fm-assert-tests-kept.sh, so
#       both of that script's modes work here and its flags need no mirror in
#       this file. In CI that is:
#         fm-reverify-base.sh --worktree . --base origin/<base branch> \
#           --branch <pr head sha> --assume-branch-suite-green
#       --assume-branch-suite-green is what buys the skip, and it is a PREMISE
#       the caller must actually hold - the compare side's own suite verified
#       green for this exact head. .github/workflows/ci.yml holds it by taking
#       `needs: tests-complete` on the same unchanged head; bin/fm-pr-merge.sh
#       holds it through its own checks-green gate. Nothing else may pass it.
#
# Output. stdout is line-oriented so a gate or a log reader can parse it:
#   - `reverify: <outcome>` always, as the FIRST line.
#   - `reverify-detail: <sentence>` always, as the second: the outcome in words,
#     including the counts it was decided from.
#   - the owner's own stdout verbatim after that, so every finding stays visible
#     in the same log. The owner's stderr is not captured and reaches the
#     caller's stderr untouched.
#   When GITHUB_STEP_SUMMARY names a file, the two lines are appended there too,
#   so the outcome is legible in the run summary without opening the log.
# Exit: 0 for verified and nothing-to-verify, 1 for not-verified and
#   could-not-verify. There is deliberately no third exit code: a caller gating
#   on this script needs "may this merge" and both non-verdicts answer no.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER="$SCRIPT_DIR/fm-assert-tests-kept.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-reverify-base.sh <arg>...
       Every argument is forwarded verbatim to bin/fm-assert-tests-kept.sh.
       In CI:
         fm-reverify-base.sh --worktree . --base origin/main \
           --branch <pr head sha> --assume-branch-suite-green
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '')
    # Still banners, so anything reading the first stdout line always gets an
    # outcome rather than a bare usage error it has no rule for.
    usage
    echo "reverify: could-not-verify"
    echo "reverify-detail: no arguments were given, so there was nothing to check"
    exit 1
    ;;
esac

[ -x "$OWNER" ] || {
  echo "reverify: could-not-verify"
  echo "reverify-detail: the selection owner $OWNER is missing or not executable, so nothing could be run"
  exit 1
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-reverify-base.XXXXXX") || {
  echo "reverify: could-not-verify"
  echo "reverify-detail: could not create a scratch directory to capture the check's output"
  exit 1
}
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

OUT="$TMP_DIR/out"
RC=0
"$OWNER" "$@" > "$OUT" || RC=$?

# summary_field <name>: the field's value from the owner's summary line, or the
# empty string when there is no summary line or no readable field. Anchored to
# the line start because the owner's stdout also carries bin/fm-guard.sh's
# unredirected banners, and a foreign line says nothing about any class.
SUMMARY=$(grep -m1 '^summary: ' "$OUT" || true)
summary_field() {  # <field-name>
  local v
  [ -n "$SUMMARY" ] || return 1
  v=$(printf '%s' "$SUMMARY" | sed -n "s/.*[[:space:]]$1=\([0-9]\{1,\}\)\([[:space:]].*\)\{0,1\}\$/\1/p")
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# verdict <outcome> <sentence>: render, relay the owner's stdout, and exit.
verdict() {  # <outcome> <sentence>
  local outcome=$1 sentence=$2
  printf 'reverify: %s\n' "$outcome"
  printf 'reverify-detail: %s\n' "$sentence"
  cat "$OUT"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf 'reverify: %s\n' "$outcome"
      printf 'reverify-detail: %s\n' "$sentence"
    } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
  case "$outcome" in
    verified|nothing-to-verify) exit 0 ;;
    *) exit 1 ;;
  esac
}

# The owner's contract defines exit 0, 1 and 2 and nothing else. Anything else -
# a signal, a crash, an interpreter failure - is a run whose verdict does not
# exist, so it is the fail-closed outcome rather than an unhandled fall-through.
case "$RC" in
  0|1) ;;
  2)
    verdict could-not-verify \
      "the base-assertion check refused to run at all (exit 2); its stderr above names the missing requirement"
    ;;
  *)
    verdict could-not-verify \
      "the base-assertion check ended on exit $RC, which its contract does not define, so no verdict exists"
    ;;
esac

MISSING=$(summary_field missing) || MISSING=
FAILING=$(summary_field failing) || FAILING=
UNEXEC=$(summary_field unexecuted) || UNEXEC=
UNSTABLE=$(summary_field unstable) || UNSTABLE=
ASSUMED=$(summary_field assumed-covered) || ASSUMED=
EXECUTED=$(summary_field executed-files) || EXECUTED=

if [ -z "$SUMMARY" ]; then
  verdict could-not-verify \
    "the base-assertion check exited $RC but printed no summary line, so what it did or did not run cannot be read"
fi
# Every count the verdict below is decided from must be present and numeric. A
# summary missing one is an owner this caller does not understand, and guessing
# a zero for it would manufacture exactly the green this check exists to refuse.
require_field() {  # <value> <field-name>
  [ -n "$1" ] && return 0
  verdict could-not-verify \
    "the base-assertion check's summary carries no readable $2= count, so its result cannot be read as a verdict over anything"
}
require_field "$MISSING" missing
require_field "$FAILING" failing
require_field "$UNEXEC" unexecuted
require_field "$UNSTABLE" unstable
require_field "$ASSUMED" assumed-covered
require_field "$EXECUTED" executed-files

FINDINGS=$((MISSING + FAILING + UNEXEC + UNSTABLE))

# The owner's exit code and its own summary are two statements about the same
# run. When they disagree, one of them is wrong and there is no way to tell
# which, so the run is treated as having produced no verdict at all.
if [ "$RC" -eq 0 ] && [ "$FINDINGS" -ne 0 ]; then
  verdict could-not-verify \
    "the base-assertion check exited 0 while its own summary reports $FINDINGS blocking finding(s); the two disagree, so neither can be trusted"
fi
if [ "$RC" -eq 1 ] && [ "$FINDINGS" -eq 0 ]; then
  verdict could-not-verify \
    "the base-assertion check exited 1 while its own summary reports no blocking finding; the two disagree, so neither can be trusted"
fi

# A genuine regression outranks an unverifiable one: it is the actionable
# statement, and the sentence still names the unverifiable half.
if [ "$((MISSING + FAILING))" -ne 0 ]; then
  verdict not-verified \
    "the base's assertions do not hold against this branch: $MISSING identifier(s) the base has are missing from it and $FAILING of the base's assertion(s) failed against its code (also unverifiable: unexecuted=$UNEXEC unstable=$UNSTABLE)"
fi
if [ "$((UNEXEC + UNSTABLE))" -ne 0 ]; then
  verdict could-not-verify \
    "$UNEXEC of the base's assertion(s) could not be executed here at all and $UNSTABLE could not be compared because the base's own test named them differently on two runs; neither is a pass"
fi

if [ "$EXECUTED" -eq 0 ]; then
  verdict nothing-to-verify \
    "no base test file needed re-running: all $ASSUMED of the base's assertion(s) sit in files byte-identical to this branch's copies, which the branch's own verified-green suite already ran"
fi

verdict verified \
  "the base's assertions hold: $EXECUTED base test file(s) differed from this branch's copies and were re-run against its code with no finding; the remaining $ASSUMED assertion(s) sit in byte-identical files the branch's own verified-green suite already ran"
