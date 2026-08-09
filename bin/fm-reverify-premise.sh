#!/usr/bin/env bash
# Establish the ONE premise the cheap base re-verification rests on: this exact
# head's own behaviour suite is verified green.
#
# WHY A PREMISE IS NEEDED AT ALL. bin/fm-reverify-base.sh is cheap only because
# bin/fm-assert-tests-kept.sh's --assume-branch-suite-green skips a base test
# file the branch's copy matches byte for byte - 83 of 85 files on this repo,
# 166s against 2484s. That skip is sound ONLY if the branch's own suite really
# did run those identical files against this same code. Passing the flag without
# establishing that would turn the whole check into the false green it exists to
# eliminate, so this script establishes it and never assumes it.
#
# WHY IT READS THE API RATHER THAN TAKING `needs:`. The re-verification runs in
# its own workflow, deliberately: the cheap path is "re-run this one thing", and
# a standalone workflow is re-run whole with `gh run rerun <run-id>` rather than
# by hunting a job id inside the full CI run. A separate workflow cannot take
# `needs:` on CI's jobs, so the premise is read from the head commit's own check
# runs - which is also stronger, because it is re-read at the moment of each
# re-run instead of inherited from a result recorded minutes or days earlier.
#
# THE READ. `gh api repos/<repo>/commits/<sha>/check-runs` returns the LATEST
# attempt per check name (the endpoint's own default filter), so a re-run never
# leaves a superseded attempt to be counted - the supersession rule
# bin/fm-flow-snapshot.sh has to apply to `statusCheckRollup` does not arise
# here, and is deliberately not copied.
#
# THREE ANSWERS, and the caller must act differently on each:
#   premise: green      the fan-in check succeeded AND every behaviour shard
#                       concluded success. The skip is sound; re-verify.
#   premise: waived     the fan-in check succeeded with no shard having run - a
#                       verified captain CI waiver authorized this PR to carry no
#                       test evidence. There is then no green suite to rest the
#                       skip on and nothing to re-verify against, so the caller
#                       reports the waiver rather than manufacturing a verdict or
#                       a block the waiver already ruled out.
#   premise: unavailable  anything else: the fan-in check failed, was cancelled,
#                       never appeared, a shard failed, or the wait ran out. The
#                       caller must BLOCK. A required check that goes green
#                       because it could not establish its own premise is exactly
#                       the false green this gate family exists to remove.
#
# Usage:
#   fm-reverify-premise.sh --repo <owner/repo> --sha <commit>
#                          --fanin-check <name> --shard-check-prefix <prefix>
#                          [--timeout-seconds <n>] [--poll-seconds <n>]
#   The two check names come from the caller because .github/workflows/ci.yml
#   owns them; tests/fm-reverify-base.test.sh derives both from that file at run
#   time and asserts the caller passes what CI actually publishes, so the names
#   cannot drift into a second, quietly wrong copy here.
#
# Output. stdout is line-oriented:
#   - `premise: <green|waived|unavailable>` always, as the FIRST line.
#   - `premise-detail: <sentence>` always, as the second.
#   When GITHUB_OUTPUT names a file, `premise=<value>` is appended there too, so
#   a workflow can branch on it without parsing the log.
# Exit: 0 for green and waived, 1 for unavailable. Both non-blocking answers
#   share an exit code because the caller must read the line to tell them apart
#   anyway, and a workflow step that failed could not have written its output.
#
# FM_REVERIFY_PREMISE_GH overrides the `gh` command, for tests only.
set -u

GH_CMD=${FM_REVERIFY_PREMISE_GH:-gh}

REPO=
SHA=
FANIN=
SHARD_PREFIX=
TIMEOUT=1500
POLL=20

usage() {
  cat >&2 <<'EOF'
usage: fm-reverify-premise.sh --repo <owner/repo> --sha <commit>
                              --fanin-check <name> --shard-check-prefix <prefix>
                              [--timeout-seconds <n>] [--poll-seconds <n>]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --repo) [ "$#" -ge 2 ] || { usage; exit 1; }; REPO=$2; shift 2 ;;
    --sha) [ "$#" -ge 2 ] || { usage; exit 1; }; SHA=$2; shift 2 ;;
    --fanin-check) [ "$#" -ge 2 ] || { usage; exit 1; }; FANIN=$2; shift 2 ;;
    --shard-check-prefix) [ "$#" -ge 2 ] || { usage; exit 1; }; SHARD_PREFIX=$2; shift 2 ;;
    --timeout-seconds) [ "$#" -ge 2 ] || { usage; exit 1; }; TIMEOUT=$2; shift 2 ;;
    --poll-seconds) [ "$#" -ge 2 ] || { usage; exit 1; }; POLL=$2; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

# answer <value> <sentence>: render, publish, exit. The only exit path, so no
# branch below can leave the caller without one of the three answers.
answer() {  # <value> <sentence>
  printf 'premise: %s\n' "$1"
  printf 'premise-detail: %s\n' "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'premise=%s\n' "$1" >> "$GITHUB_OUTPUT" 2>/dev/null || true
  fi
  case "$1" in
    green|waived) exit 0 ;;
    *) exit 1 ;;
  esac
}

# A missing argument answers `unavailable` rather than exiting on usage alone,
# so a caller reading the first stdout line always gets one of the three
# answers - including when the caller itself is what is wrong.
missing_arg() {  # <flag>
  usage
  answer unavailable "no $1 was given, so this head's own suite result could not be read"
}
[ -n "$REPO" ] || missing_arg --repo
[ -n "$SHA" ] || missing_arg --sha
[ -n "$FANIN" ] || missing_arg --fanin-check
[ -n "$SHARD_PREFIX" ] || missing_arg --shard-check-prefix

command -v "$GH_CMD" >/dev/null 2>&1 || answer unavailable \
  "the GitHub CLI is not available, so this head's own check results could not be read"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-reverify-premise.XXXXXX") || answer unavailable \
  "could not create a scratch directory to capture the check-run read"
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

RUNS="$TMP_DIR/runs"

# read_checks: one line per check run, "<name>\t<status>\t<conclusion>". The
# endpoint returns the latest attempt per name, so no supersession pass is
# needed. A read that fails leaves the file empty and is retried by the loop:
# a transient API failure is not evidence about the suite either way.
read_checks() {
  "$GH_CMD" api --paginate \
    "repos/$REPO/commits/$SHA/check-runs" \
    --jq '.check_runs[] | [.name, .status, .conclusion] | @tsv' \
    > "$RUNS" 2>"$TMP_DIR/err" || return 1
}

DEADLINE=$(( $(date +%s) + TIMEOUT ))
LAST_REASON="the behaviour suite's own checks never appeared for this head"

while :; do
  : > "$RUNS"
  if read_checks; then
    FANIN_STATUS=
    FANIN_CONCLUSION=
    SHARD_TOTAL=0
    SHARD_SUCCESS=0
    SHARD_SKIPPED=0
    SHARD_PENDING=0
    SHARD_BAD=
    while IFS=$'\t' read -r name status conclusion; do
      [ -n "$name" ] || continue
      if [ "$name" = "$FANIN" ]; then
        FANIN_STATUS=$status
        FANIN_CONCLUSION=$conclusion
        continue
      fi
      case "$name" in
        "$SHARD_PREFIX"*)
          SHARD_TOTAL=$((SHARD_TOTAL + 1))
          if [ "$status" != completed ]; then
            SHARD_PENDING=$((SHARD_PENDING + 1))
          else
            case "$conclusion" in
              success) SHARD_SUCCESS=$((SHARD_SUCCESS + 1)) ;;
              skipped) SHARD_SKIPPED=$((SHARD_SKIPPED + 1)) ;;
              *) SHARD_BAD="${SHARD_BAD:+$SHARD_BAD, }$name ($conclusion)" ;;
            esac
          fi
          ;;
      esac
    done < "$RUNS"

    if [ -z "$FANIN_STATUS" ]; then
      LAST_REASON="no '$FANIN' check has appeared for this head yet"
    elif [ "$FANIN_STATUS" != completed ] || [ "$SHARD_PENDING" -gt 0 ]; then
      LAST_REASON="the behaviour suite is still running for this head"
    elif [ "$FANIN_CONCLUSION" != success ]; then
      answer unavailable \
        "the behaviour suite is not green for this head ('$FANIN' concluded ${FANIN_CONCLUSION:-nothing}), so there is no verified-green suite to rest the cheap path on; fix the suite first"
    elif [ -n "$SHARD_BAD" ]; then
      # The fan-in can pass on a waiver while a shard reports something other
      # than success, so the shards are read in their own right rather than
      # through it.
      answer unavailable \
        "a behaviour shard did not succeed for this head ($SHARD_BAD), so the branch's own suite cannot stand in for the base test files this check would skip"
    elif [ "$SHARD_SUCCESS" -gt 0 ] && [ "$SHARD_SUCCESS" -eq "$SHARD_TOTAL" ]; then
      answer green \
        "all $SHARD_SUCCESS behaviour shard(s) succeeded for this head, so a base test file byte-identical to this branch's copy has already been run against this same code"
    elif [ "$SHARD_TOTAL" -eq 0 ] || [ "$SHARD_SKIPPED" -eq "$SHARD_TOTAL" ]; then
      # The fan-in succeeded while no shard ran: the waiver path. It reports the
      # waiver, and never a verdict, because there is no test evidence here at
      # all - not for this check to rest on, and not for it to re-verify.
      answer waived \
        "'$FANIN' succeeded for this head with no behaviour shard having run, which is the verified CI waiver path: this PR carries no test evidence to re-verify against"
    else
      LAST_REASON="the behaviour suite's shards are in a mixed state for this head ($SHARD_SUCCESS succeeded, $SHARD_SKIPPED skipped, of $SHARD_TOTAL)"
    fi
  else
    LAST_REASON="reading this head's check runs from GitHub failed"
  fi

  [ "$(date +%s)" -lt "$DEADLINE" ] || break
  sleep "$POLL"
done

answer unavailable \
  "gave up after ${TIMEOUT}s waiting for this head's own behaviour suite to conclude: $LAST_REASON"
