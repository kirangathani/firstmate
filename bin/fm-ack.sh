#!/usr/bin/env bash
# Record that firstmate has acted on a direct report's terminal or
# firstmate-owed state, and silence the unactioned alarm for that state.
#
# Usage:
#   fm-ack.sh <task-id> [<what you did>]   record the action
#   fm-ack.sh --list                       show unactioned direct reports
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

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

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

if [ ! -f "$STATE/$ID.meta" ]; then
  echo "error: no metadata for '$ID' in $STATE; fm-ack refuses to record an ack for an unknown task" >&2
  exit 1
fi

if ! fm_ack_record "$STATE" "$ID" "$NOTE"; then
  echo "error: could not write $(fm_ack_file "$STATE" "$ID")" >&2
  exit 1
fi
echo "acked: $ID${NOTE:+ ($NOTE)}"
