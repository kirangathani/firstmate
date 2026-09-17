#!/usr/bin/env bash
# Record that firstmate has acted on a direct report's terminal or
# firstmate-owed state, and silence the unactioned alarm for that state.
#
# Usage:
#   fm-ack.sh [--refill] <task-id> [<what you did>]   record the action
#   fm-ack.sh --list                                  show unactioned direct reports
#
# --refill, only as the FIRST argument, keeps a SUCCESSFUL ack alive as one of the
# dormant-arm pool's waiting arms instead of exiting, so the pool refills as a side
# effect of ordinary work and costs no model call of its own. Pass it only when
# running this as the harness's own background task: the process becomes the thing
# that waits, so a foreground caller would never get its prompt back. A failed ack
# never reaches it. bin/fm-arm-pool-lib.sh owns the pool and that decision.
#
# The alarm itself lives in bin/fm-guard.sh; the record format, the owed-state
# sets, the grace window, and the confirm mechanics are owned by
# bin/fm-ack-lib.sh. Read that header before changing any of them.
#
# Most actions ack themselves: bin/fm-send.sh acks whenever it delivers an
# instruction to a task in this home (triggering validation, relaying a decision
# back to a crew, steering a blocker), and bin/fm-pr-check.sh acks when it arms
# the merge poll for a PR-ready task. Run this by hand for the actions that
# leave no other trace - above all relaying a `needs-decision` or a `failed` to
# the captain, after which the task is legitimately waiting on them and must not
# keep alarming.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-ack-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ack-lib.sh"
# Self-timed: acking is how "firstmate got back to the crew" is recorded when
# the action left no other trace, so how long it took to get here is one of the
# numbers the latency ledger exists to hold. bin/fm-latency-lib.sh owns the
# ledger and can never fail this command.
# shellcheck source=bin/fm-latency-lib.sh
. "$SCRIPT_DIR/fm-latency-lib.sh"
fm_latency_cmd_start fm-ack.sh
trap 'fm_latency_cmd_end $?' EXIT

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

REFILL=0
if [ "${1:-}" = "--refill" ]; then
  REFILL=1
  shift
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --list)
    rows=$(fm_ack_unactioned "$STATE")
    if [ -z "$rows" ]; then
      echo "no unactioned direct reports"
      exit 0
    fi
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id verb age verdict last; do
      printf '%s\t%s\t%ss\t%s\t%s\n' "$id" "$verb" "$age" "$verdict" "$last"
    done
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
esac

ID=$1
shift
NOTE=$*
fm_latency_cmd_task "$ID"

if [ ! -f "$STATE/$ID.meta" ]; then
  echo "error: no metadata for '$ID' in $STATE; fm-ack refuses to record an ack for an unknown task" >&2
  exit 1
fi

if ! fm_ack_record "$STATE" "$ID" "$NOTE"; then
  echo "error: could not write $(fm_ack_file "$STATE" "$ID")" >&2
  exit 1
fi
echo "acked: $ID${NOTE:+ ($NOTE)}"

# The record is written, so if the caller asked, spend what is left of this
# already paid-for process on being an ear rather than on exiting. The latency
# row is closed by hand first because exec does not run EXIT traps, and the
# libraries are sourced only here so an ordinary ack pays nothing for a path it
# does not take.
if [ "$REFILL" -eq 1 ]; then
  fm_latency_cmd_end 0
  trap - EXIT
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-arm-pool-lib.sh
  . "$SCRIPT_DIR/fm-arm-pool-lib.sh"
  fm_arm_pool_refill_or_exit "$SCRIPT_DIR/fm-watch-arm.sh"
fi
