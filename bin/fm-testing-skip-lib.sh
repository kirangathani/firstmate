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
# Callers use it in four steps:
#   fm_testing_skip_reset                      before the argv loop
#   fm_testing_skip_note "$arg"                per token; 0 if it consumed one
#   fm_testing_skip_check_args <kind> <noun>   argument-only rules
#   fm_testing_skip_check_mode <mode>          delivery-mode rules, and the point
#                                              at which --skip-testing resolves
# Both check functions print their own diagnosis and return 1; the caller exits.
# FM_TESTING_SKIP_LOCAL / FM_TESTING_SKIP_CI are final only after
# fm_testing_skip_check_mode has run, because --skip-testing has no answer until
# the delivery mode is known.
#
# --skip-testing is the flag a caller reaches for when the intent is simply
# "skip the testing for this task". It resolves to the MOST any given delivery
# mode can honour, which is the whole matrix below collapsed into one token, so
# the accepted combinations stop being something to look up before dispatching.

# Accumulated state, valid after fm_testing_skip_reset plus a pass of
# fm_testing_skip_note over argv.
FM_TESTING_SKIP_LOCAL=off
FM_TESTING_SKIP_CI=off
FM_TESTING_SKIP_FLAGS=
FM_TESTING_SKIP_COUNT=0
FM_TESTING_SKIP_AUTO=off

fm_testing_skip_reset() {
  FM_TESTING_SKIP_LOCAL=off
  FM_TESTING_SKIP_CI=off
  FM_TESTING_SKIP_FLAGS=
  FM_TESTING_SKIP_COUNT=0
  FM_TESTING_SKIP_AUTO=off
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
    # Deliberately switches nothing on here: what "all the testing this project
    # actually has" means depends on the delivery mode, which argv does not know.
    # fm_testing_skip_check_mode resolves it.
    --skip-testing) FM_TESTING_SKIP_AUTO=on ;;
    *) return 1 ;;
  esac
  FM_TESTING_SKIP_FLAGS="${FM_TESTING_SKIP_FLAGS}${FM_TESTING_SKIP_FLAGS:+ }$1"
  FM_TESTING_SKIP_COUNT=$((FM_TESTING_SKIP_COUNT + 1))
  return 0
}

# fm_testing_skip_matrix: the accepted flag/delivery-mode matrix, printed at
# every point of refusal so a caller never has to go and look it up. Stated here
# once and reused, rather than restated per refusal, so the rows cannot drift
# apart from the rules immediately below them.
fm_testing_skip_matrix() {
  echo "error: accepted by delivery mode - no-mistakes: --local-skip or --all-testing-skip; direct-PR: --ci-skip; local-only: none, it runs no pipeline, opens no PR, and has no CI." >&2
  echo "error: or pass --skip-testing, which resolves to the most the project's own mode allows and never needs this matrix." >&2
}

# fm_testing_skip_resolved_flag: the single concrete flag that reproduces the
# resolved state, or nothing when no skip is on. This is what a caller hands to
# another firstmate script, so a resolved --skip-testing is passed on as the
# concrete flag it became rather than re-resolved a second time somewhere else.
fm_testing_skip_resolved_flag() {
  if [ "$FM_TESTING_SKIP_LOCAL" = on ] && [ "$FM_TESTING_SKIP_CI" = on ]; then
    printf '%s' --all-testing-skip
  elif [ "$FM_TESTING_SKIP_LOCAL" = on ]; then
    printf '%s' --local-skip
  elif [ "$FM_TESTING_SKIP_CI" = on ]; then
    printf '%s' --ci-skip
  fi
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
  # --skip-testing resolves HERE, where the mode is finally known, to the most
  # that mode can actually honour. It can never resolve to a combination the
  # rows below would refuse, so it needs no row of its own - only local-only,
  # which has nothing to skip at all, and an unknown mode are refusals.
  if [ "$FM_TESTING_SKIP_AUTO" = on ]; then
    case "$mode" in
      no-mistakes)
        FM_TESTING_SKIP_LOCAL=on
        FM_TESTING_SKIP_CI=on
        echo "note: --skip-testing on a no-mistakes project resolves to --all-testing-skip (local pipeline off, CI test jobs waived)" >&2
        ;;
      direct-PR)
        FM_TESTING_SKIP_LOCAL=off
        FM_TESTING_SKIP_CI=on
        echo "note: --skip-testing on a direct-PR project resolves to --ci-skip (that mode runs no local pipeline)" >&2
        ;;
      local-only)
        echo "error: --skip-testing has nothing to skip on a local-only project: it runs no pipeline, opens no PR, and has no CI to waive." >&2
        fm_testing_skip_matrix
        return 1
        ;;
      *)
        echo "error: --skip-testing is not supported for delivery mode '$mode'" >&2
        fm_testing_skip_matrix
        return 1
        ;;
    esac
    return 0
  fi
  case "$mode" in
    no-mistakes)
      if [ "$FM_TESTING_SKIP_CI" = on ] && [ "$FM_TESTING_SKIP_LOCAL" = off ]; then
        echo "error: --ci-skip alone cannot be honoured for a no-mistakes project: that pipeline owns the push and the PR, and it may add fix commits, so the head commit a waiver must cover is not known until after the PR already exists - and editing a PR body does not re-run CI." >&2
        echo "error: use --all-testing-skip (the worker then opens the PR itself, with the waiver in the body on the first CI run), or drop --ci-skip." >&2
        fm_testing_skip_matrix
        return 1
      fi
      ;;
    direct-PR)
      if [ "$FM_TESTING_SKIP_LOCAL" = on ]; then
        echo "error: --local-skip and --all-testing-skip do not apply to a direct-PR project: that mode already runs no local pipeline. Use --ci-skip." >&2
        fm_testing_skip_matrix
        return 1
      fi
      ;;
    local-only)
      echo "error: $FM_TESTING_SKIP_FLAGS does not apply to a local-only project: it runs no pipeline, opens no PR, and has no CI to waive." >&2
      fm_testing_skip_matrix
      return 1
      ;;
    *)
      echo "error: $FM_TESTING_SKIP_FLAGS is not supported for delivery mode '$mode'" >&2
      fm_testing_skip_matrix
      return 1
      ;;
  esac
  return 0
}
