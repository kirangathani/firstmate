#!/usr/bin/env bash
# Record that firstmate has acted on a direct report's terminal or
# firstmate-owed state, and silence the unactioned alarm for that state.
#
# Usage:
#   fm-ack.sh <task-id> [<what you did>]   record the action
#   fm-ack.sh --list                       show unactioned direct reports
#
# ONE shape only: issue it as its own Monitor, timeout_ms 1800000, the command
# alone with 2>&1, nothing bundled. A SUCCESSFUL ack does not exit - it stays
# alive as one of the dormant-arm pool's waiting arms whenever the pool has room,
# so ordinary acking keeps the pool full and costs no model call of its own. The
# Bash tool cannot run this script at all: the PreToolUse seatbelt denies it with
# that replacement (bin/fm-arm-command-policy.mjs, docs/arm-pretool-check.md).
# bin/fm-arm-pool-lib.sh owns the pool and the FM_ARM_POOL_NO_REFILL opt-out that
# a script needing its own prompt back must set. A failed ack, --list, and --help
# all exit as they always have. --refill is accepted as a first-argument no-op
# for one release so older protocol text and scripts keep working.
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

# --refill selected the refill when it was opt-in. It is now the default, so the
# flag is accepted as a no-op for one release and simply consumed here.
if [ "${1:-}" = "--refill" ]; then
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

# The record is written, so spend what is left of this already paid-for process
# on being an ear rather than on exiting. fm_arm_pool_refill_or_exit exits
# instead when the pool is full or when the caller set FM_ARM_POOL_NO_REFILL.
# The latency row is closed by hand first because exec does not run EXIT traps.
fm_latency_cmd_end 0
trap - EXIT
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-arm-pool-lib.sh
. "$SCRIPT_DIR/fm-arm-pool-lib.sh"
fm_arm_pool_refill_or_exit "$SCRIPT_DIR/fm-watch-arm.sh"
