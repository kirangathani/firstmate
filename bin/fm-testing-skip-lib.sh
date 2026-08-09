#!/usr/bin/env bash
# Shared owner of the captain-only testing-skip flags: the token set, the
# accumulation, and both refusal matrices.
#
# WHY THIS IS ONE FILE. bin/fm-spawn.sh and bin/fm-brief.sh must stay in
# lockstep by design - a brief can never be scaffolded for a combination that
# spawn will then refuse to launch - and they had already drifted while holding
# two copies of the same rules: the same refusal carried a fuller two-line
# explanation in one script and a shortened one-liner in the other. Rules that
# must agree belong in one place, so this states them once and both scripts
# consume it.
#
# Nothing here grants a skip. Every function either records what was passed or
# refuses a combination that cannot actually be delivered; the enforcement lives
# in bin/fm-spawn.sh (the PATH shim and the dispatch token) and in CI (the
# signed waiver).
#
# Callers use it in three steps:
#   fm_testing_skip_reset                      before the argv loop
#   fm_testing_skip_note "$arg"                per token; 0 if it consumed one
#   fm_testing_skip_check_args <kind> <noun>   argument-only rules
#   fm_testing_skip_check_mode <mode>          delivery-mode rules
# Both check functions print their own diagnosis and return 1; the caller exits.
#
# A fifth entry point, fm_testing_skip_read, reads the flags back out of a
# DISPATCHED task's state/<id>.meta rather than out of argv. It is the same
# input shape - which testing skip does this task carry - written down instead of
# typed, so it belongs to the same owner: bin/fm-pr-merge.sh's waiver banner and
# bin/fm-flow-snapshot.sh's skipped-stage rendering must agree about what the
# record says, and two greps in two scripts is how they would stop agreeing.

# Accumulated state, valid after fm_testing_skip_reset plus a pass of
# fm_testing_skip_note over argv.
FM_TESTING_SKIP_LOCAL=off
FM_TESTING_SKIP_CI=off
FM_TESTING_SKIP_FLAGS=
FM_TESTING_SKIP_COUNT=0

fm_testing_skip_reset() {
  FM_TESTING_SKIP_LOCAL=off
  FM_TESTING_SKIP_CI=off
  FM_TESTING_SKIP_FLAGS=
  FM_TESTING_SKIP_COUNT=0
}

# fm_testing_skip_read <meta-file>: set FM_TESTING_SKIP_LOCAL and
# FM_TESTING_SKIP_CI from a dispatched task's own record, resetting first so a
# caller can never read a stale accumulation.
#
# The match is on the WHOLE line, not on a `local_skip=` prefix, because the
# only value bin/fm-spawn.sh ever writes is `on` and an absent field means off.
# A line that says anything else is not a flag this owner recognises, and a
# testing skip is the last place to guess at an unrecognised value.
#
# It reports what the record SAYS and nothing more. The flag line alone is
# reachable by the worker, so it is disclosure-grade evidence only; the
# signature beside it is what grants anything, and bin/fm-attestation-lib.sh
# owns that check.
fm_testing_skip_read() {  # <meta-file>
  local meta=${1-}
  fm_testing_skip_reset
  [ -f "$meta" ] || return 0
  if grep -qx 'local_skip=on' "$meta" 2>/dev/null; then FM_TESTING_SKIP_LOCAL=on; fi
  if grep -qx 'ci_skip=on' "$meta" 2>/dev/null; then FM_TESTING_SKIP_CI=on; fi
  return 0
}

# fm_testing_skip_note <argv-token>: record a testing-skip flag.
# Returns 0 when the token WAS one (and has been recorded), 1 when it was not,
# so a caller's argv loop can fall through to its own handling.
#
# The count is incremented per flag SEEN rather than per axis switched on, so
# `--local-skip --ci-skip` is caught as two flags by the check below instead of
# silently collapsing into the same state as --all-testing-skip.
fm_testing_skip_note() {
  case "${1-}" in
    --local-skip) FM_TESTING_SKIP_LOCAL=on ;;
    --ci-skip) FM_TESTING_SKIP_CI=on ;;
    --all-testing-skip) FM_TESTING_SKIP_LOCAL=on; FM_TESTING_SKIP_CI=on ;;
    *) return 1 ;;
  esac
  FM_TESTING_SKIP_FLAGS="${FM_TESTING_SKIP_FLAGS}${FM_TESTING_SKIP_FLAGS:+ }$1"
  FM_TESTING_SKIP_COUNT=$((FM_TESTING_SKIP_COUNT + 1))
  return 0
}

# fm_testing_skip_check_args <kind> <noun>: the argument-only rules, checkable
# before any filesystem or backend work so a malformed dispatch costs nothing.
# <noun> is the caller's word for the thing being made ("task", "brief") and is
# the only thing that varies between callers; the rules themselves do not.
#
# Every unrecognised combination refuses rather than picking an interpretation:
# these flags remove test coverage, so guessing which one the captain meant is
# the one behaviour they must never have.
fm_testing_skip_check_args() {
  local kind=${1-ship} noun=${2-task}
  if [ "$FM_TESTING_SKIP_COUNT" -gt 1 ]; then
    echo "error: pass exactly one testing-skip flag; got '$FM_TESTING_SKIP_FLAGS'. Use --all-testing-skip for both, not --local-skip together with --ci-skip." >&2
    return 1
  fi
  if [ -n "$FM_TESTING_SKIP_FLAGS" ] && [ "$kind" != ship ]; then
    echo "error: $FM_TESTING_SKIP_FLAGS applies only to a ship $noun; a $kind $noun runs no local pipeline and opens no PR" >&2
    return 1
  fi
  return 0
}

# fm_testing_skip_check_mode <delivery-mode>: which skip a delivery mode can
# honour. Each row refuses a combination the mode CANNOT actually deliver,
# rather than accepting it and silently doing nothing, so a captain who asks for
# less testing always learns whether they got it.
fm_testing_skip_check_mode() {
  local mode=${1-}
  [ -n "$FM_TESTING_SKIP_FLAGS" ] || return 0
  case "$mode" in
    no-mistakes)
      if [ "$FM_TESTING_SKIP_CI" = on ] && [ "$FM_TESTING_SKIP_LOCAL" = off ]; then
        echo "error: --ci-skip alone cannot be honoured for a no-mistakes project: that pipeline owns the push and the PR, and it may add fix commits, so the head commit a waiver must cover is not known until after the PR already exists - and editing a PR body does not re-run CI." >&2
        echo "error: use --all-testing-skip (the worker then opens the PR itself, with the waiver in the body on the first CI run), or drop --ci-skip." >&2
        return 1
      fi
      ;;
    direct-PR)
      if [ "$FM_TESTING_SKIP_LOCAL" = on ]; then
        echo "error: --local-skip and --all-testing-skip do not apply to a direct-PR project: that mode already runs no local pipeline. Use --ci-skip." >&2
        return 1
      fi
      ;;
    local-only)
      echo "error: $FM_TESTING_SKIP_FLAGS does not apply to a local-only project: it runs no pipeline, opens no PR, and has no CI to waive." >&2
      return 1
      ;;
    *)
      echo "error: $FM_TESTING_SKIP_FLAGS is not supported for delivery mode '$mode'" >&2
      return 1
      ;;
  esac
  return 0
}
