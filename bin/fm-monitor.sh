#!/usr/bin/env bash
# The forced monitoring sweep: every direct report this home supervises, what
# state it reported, and whether firstmate has acted on it.
#
# WHY A COMMAND AT ALL, when bin/fm-turnend-guard.sh already blocks a turn that
# would end with a report unanswered. Because the guard is an ALARM and alarms
# are silent when clean, which is correct for a guard and useless as an answer to
# "have you gone over everything". This is the RENDER surface: it names every
# task in every class on every run, zeros included, so a clean fleet produces
# evidence of having been checked rather than an absence of complaint. That is
# the same render contract bin/fm-drift-check.sh follows, and for the same
# reason - a silent all-clear is indistinguishable from not having looked.
#
# NO PREDICATE OF ITS OWN. This script computes nothing itself; it renders what
# the alarm surfaces alarm from, so the sweep can never report a task clean that
# the turn-end guard would block on. Two predicates feed it, each owned
# elsewhere: fm_ack_sweep in bin/fm-ack-lib.sh classifies whether firstmate has
# acted on what each task reported, and bin/fm-nm-stall.sh reports any task whose
# validation step has stopped advancing - a condition no reported state can
# express, because a frozen validation reports nothing at all. Both are rendered
# on every run, counts included.
#
# THE SIX CLASSES, all named on every render:
#   unactioned  reported a state that owes firstmate an action, past the grace
#               window, not acted on. This is what blocks a turn end.
#   pending     owes an action but is still inside the grace window.
#   acked       firstmate did its part; the ball is with the captain, a worker,
#               or an external wait.
#   moved-on    the status log still shows an owed state, but the authoritative
#               current-state read proves the worker resumed past it.
#   exempt      the captain signed a standing exemption for this task.
#   quiet       the last thing it reported owes firstmate nothing.
#
# THE EXEMPTION, and exactly what it is worth.
#   state/<id>.monitor-exempt, one line: <epoch>\t<hmac-hex>\t<reason>. The HMAC
#   is over the task id AND the reason under this home's master key
#   (config/ci-waiver-secret), so an exemption cannot be granted by appending a
#   line and its stated justification cannot be edited afterwards. Minting one
#   requires the key; without one, --exempt refuses rather than writing an
#   unverifiable record.
#
#   Against a WORKER that is unforgeable: a worker holds no key and is told
#   about no key. Against FIRSTMATE it is not, and this file will not pretend
#   otherwise - firstmate runs as the same OS user as the captain and can read
#   the key file, exactly the residual limit bin/fm-ci-waiver-lib.sh already
#   documents for the dispatch tokens. What actually constrains firstmate is that
#   an exemption is never silent: it is named with its reason on every render
#   here, and announced unprompted at every session start by bin/fm-bootstrap.sh.
#   A self-granted exemption therefore reports itself to the captain instead of
#   quietly removing a task from supervision.
#
#   An exemption suppresses the ALARM for that task and nothing else. It does not
#   remove the task from this render, from the backlog, or from any other check.
#   bin/fm-teardown.sh removes the record with the rest of the task's state.
#
# Usage:
#   fm-monitor.sh                          sweep and render every task
#   fm-monitor.sh --quiet                  render only tasks needing attention
#   fm-monitor.sh --exempt <id> --reason <why>   sign a standing exemption
#   fm-monitor.sh --unexempt <id>          drop an exemption
#   fm-monitor.sh --list-exempt            show standing exemptions
# Exit: 0 nothing needs firstmate's attention, 1 at least one unactioned report
#       or stalled validation, 2 bad usage or a refused exemption.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-ack-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ack-lib.sh"

SECRET_FILE="${FM_ACK_SECRET_FILE:-$CONFIG/ci-waiver-secret}"
export FM_ACK_SECRET_FILE="$SECRET_FILE"

# A forced sweep confirms every task's current state, so it must not stop after
# the alarm path's small budget. The captain asked whether every task was gone
# over; "the first three" is not an answer. An explicit budget still wins.
FM_ACK_CONFIRM_MAX=${FM_ACK_CONFIRM_MAX:-1000}
export FM_ACK_CONFIRM_MAX

TAB=$'\t'

usage() {
  cat >&2 <<'EOF'
usage: fm-monitor.sh [--quiet]
       fm-monitor.sh --exempt <task-id> --reason "<why>"
       fm-monitor.sh --unexempt <task-id>
       fm-monitor.sh --list-exempt
EOF
}

MODE=sweep
ONLY_ATTENTION=0
TARGET=
REASON=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --quiet) ONLY_ATTENTION=1; shift ;;
    --list-exempt) MODE=list-exempt; shift ;;
    --exempt)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MODE=exempt
      TARGET=$2
      shift 2
      ;;
    --unexempt)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MODE=unexempt
      TARGET=$2
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      REASON=$2
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

# --- shared guards -----------------------------------------------------------

require_known_task() {  # <id>
  if ! fm_ci_waiver_valid_task_id "$1"; then
    echo "error: '$1' is not a valid task id" >&2
    exit 2
  fi
  if [ ! -f "$STATE/$1.meta" ]; then
    echo "error: no record for '$1' in $STATE; fm-monitor refuses to exempt a task it does not supervise" >&2
    exit 2
  fi
}

# --- exemption verbs ---------------------------------------------------------

case "$MODE" in
  exempt)
    require_known_task "$TARGET"
    if [ -z "$REASON" ]; then
      echo "error: --exempt needs --reason \"<why>\"; an exemption with no stated reason is an unexplained blind spot" >&2
      exit 2
    fi
    # The record is one line and the reason is its last field, so a reason
    # carrying a newline or a tab would produce a record that reads back as a
    # different reason than the one that was signed.
    case "$REASON" in
      *"$TAB"*|*"
"*)
        echo "error: --reason must be a single line with no tab characters" >&2
        exit 2
        ;;
    esac
    if ! fm_ci_waiver_secret_readable "$SECRET_FILE"; then
      echo "error: no signing key at $SECRET_FILE, so this exemption cannot be signed." >&2
      echo "       An unsigned marker would let firstmate or a worker exempt itself from being checked," >&2
      echo "       so fm-monitor writes nothing instead. Run 'bin/fm-ci-waiver.sh init' first." >&2
      exit 2
    fi
    SIG=$(fm_ci_waiver_monitor_exempt_token "$TARGET" "$REASON" < "$SECRET_FILE") || SIG=
    if [ -z "$SIG" ]; then
      echo "error: could not sign the exemption for '$TARGET'" >&2
      exit 2
    fi
    printf '%s\t%s\t%s\n' "$(fm_ack_now)" "$SIG" "$REASON" > "$(fm_ack_exempt_file "$STATE" "$TARGET")" || {
      echo "error: could not write $(fm_ack_exempt_file "$STATE" "$TARGET")" >&2
      exit 2
    }
    # Verify what was just written rather than trusting the write: a record that
    # does not read back as exempt is a silent blind spot in the other direction.
    if ! fm_ack_is_exempt "$STATE" "$TARGET"; then
      rm -f "$(fm_ack_exempt_file "$STATE" "$TARGET")" 2>/dev/null || true
      echo "error: the exemption written for '$TARGET' did not verify; nothing was recorded" >&2
      exit 2
    fi
    printf 'exempt: %s is no longer alarmed on (%s)\n' "$TARGET" "$REASON"
    printf 'It is still reported on every sweep and at every session start.\n'
    exit 0
    ;;
  unexempt)
    require_known_task "$TARGET"
    if [ ! -f "$(fm_ack_exempt_file "$STATE" "$TARGET")" ]; then
      printf 'no exemption recorded for %s\n' "$TARGET"
      exit 0
    fi
    rm -f "$(fm_ack_exempt_file "$STATE" "$TARGET")" || {
      echo "error: could not remove $(fm_ack_exempt_file "$STATE" "$TARGET")" >&2
      exit 2
    }
    printf 'monitoring resumed: %s\n' "$TARGET"
    exit 0
    ;;
  list-exempt)
    FOUND=0
    for f in "$STATE"/*.monitor-exempt; do
      [ -e "$f" ] || continue
      id=${f##*/}
      id=${id%.monitor-exempt}
      if fm_ack_is_exempt "$STATE" "$id"; then
        printf 'exempt\t%s\t%s\n' "$id" "$FM_ACK_EXEMPT_REASON"
      else
        # A record that does not verify is reported, never dropped: it is either
        # a forged exemption or a real one this home can no longer check, and
        # both are things the captain needs to see.
        printf 'INVALID\t%s\t%s\n' "$id" "does not verify against this home's key - not exempt"
      fi
      FOUND=1
    done
    [ "$FOUND" = 1 ] || printf 'no standing exemptions\n'
    exit 0
    ;;
esac

# --- the sweep ---------------------------------------------------------------

ROWS=$(fm_ack_sweep "$STATE")

N_UNACTIONED=0
N_PENDING=0
N_ACKED=0
N_MOVED=0
N_EXEMPT=0
N_QUIET=0
ATTENTION=
ACCOUNTED=

# Both the class and the confirm verdict are internal labels (AGENTS.md section
# 9). This render is read by the captain, so it translates them here rather than
# leaving that to whoever relays it.
say_worker() {  # <verdict>
  case "$1" in
    clear) printf 'working or in a declared wait' ;;
    owed) printf 'still sitting at that state' ;;
    unconfirmed) printf 'current state could not be read' ;;
    *) printf 'not checked' ;;
  esac
}

describe() {  # <class> <verb> <age> <verdict> <detail>
  case "$1" in
    unactioned) printf 'NEEDS ACTION - reported "%s" %ss ago and firstmate has not acted (worker: %s)' "$2" "$3" "$(say_worker "$4")" ;;
    pending)    printf 'just reported "%s" - not acted on yet, still inside the %ss window' "$2" "$(fm_ack_resolve_grace)" ;;
    acked)      printf 'reported "%s"; firstmate has acted, now waiting on someone else' "$2" ;;
    moved-on)   printf 'log still shows "%s" but the worker has moved past it' "$2" ;;
    exempt)     printf 'EXEMPT by the captain: %s (worker: %s)' "$5" "$(say_worker "$4")" ;;
    *)          printf 'nothing owed - last said "%s" (worker: %s)' "${2:-nothing yet}" "$(say_worker "$4")" ;;
  esac
}

while IFS=$TAB read -r id class verb age verdict detail; do
  [ -n "$id" ] || continue
  line="$id  $(describe "$class" "$verb" "$age" "$verdict" "$detail")"
  case "$class" in
    unactioned)
      N_UNACTIONED=$((N_UNACTIONED + 1))
      ATTENTION="${ATTENTION}${line}"$'\n'
      [ -z "$detail" ] || ATTENTION="${ATTENTION}    ${detail}"$'\n'
      ;;
    pending) N_PENDING=$((N_PENDING + 1)); ATTENTION="${ATTENTION}${line}"$'\n' ;;
    acked)   N_ACKED=$((N_ACKED + 1)); ACCOUNTED="${ACCOUNTED}${line}"$'\n' ;;
    moved-on) N_MOVED=$((N_MOVED + 1)); ACCOUNTED="${ACCOUNTED}${line}"$'\n' ;;
    exempt)
      N_EXEMPT=$((N_EXEMPT + 1))
      # Listed with the attention block, never the quiet one: an exemption is a
      # standing suppression of a safety check and must stay in front of the
      # captain for as long as it exists.
      ATTENTION="${ATTENTION}${line}"$'\n'
      ;;
    *) N_QUIET=$((N_QUIET + 1)); ACCOUNTED="${ACCOUNTED}${line}"$'\n' ;;
  esac
done <<EOF
$ROWS
EOF

TOTAL=$((N_UNACTIONED + N_PENDING + N_ACKED + N_MOVED + N_EXEMPT + N_QUIET))

printf 'MONITOR SWEEP: %s task(s) supervised in %s\n' "$TOTAL" "$STATE"
# Every class on every render, zeros included: a class that is simply absent
# reads as "there were none" and as "we did not check it" identically.
printf 'MONITOR COUNTS: needs-action %s | just-reported %s | acted %s | moved-on %s | exempt %s | nothing-owed %s\n' \
  "$N_UNACTIONED" "$N_PENDING" "$N_ACKED" "$N_MOVED" "$N_EXEMPT" "$N_QUIET"

if [ -n "$ATTENTION" ]; then
  printf '%s' "$ATTENTION" | while IFS= read -r l; do printf 'MONITOR: %s\n' "$l"; done
fi
if [ "$ONLY_ATTENTION" = 0 ] && [ -n "$ACCOUNTED" ]; then
  printf '%s' "$ACCOUNTED" | while IFS= read -r l; do printf 'MONITOR: %s\n' "$l"; done
fi

# The second predicate, rendered on every run for the same reason every class
# above is: a stalled validation reports NOTHING - the worker is alive and busy
# and its status log gains no line - so its absence from this render would be
# indistinguishable from not having looked, while the turn-end guard blocked on
# it. bin/fm-nm-stall.sh owns it, and reading its durable records costs no
# no-mistakes call.
N_STALLED=0
if [ -x "$SCRIPT_DIR/fm-nm-stall.sh" ]; then
  NM_STALL=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-nm-stall.sh" 2>/dev/null || true)
  N_STALLED=$(printf '%s' "$NM_STALL" | grep -c '^NM STALL: ' || true)
  case "$N_STALLED" in ''|*[!0-9]*) N_STALLED=0 ;; esac
fi
printf 'MONITOR VALIDATIONS: %s stalled (a step that has stopped advancing)\n' "$N_STALLED"
if [ "$N_STALLED" -gt 0 ]; then
  printf '%s\n' "$NM_STALL" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    printf 'MONITOR: %s\n' "$l"
  done
fi

if [ "$N_UNACTIONED" -gt 0 ]; then
  printf 'MONITOR REMEDY: do what each NEEDS ACTION state owes, then record it with bin/fm-ack.sh <id> "<what you did>".\n'
  printf 'MONITOR REMEDY: a state waiting on the CAPTAIN is recorded once you have relayed it to them.\n'
fi
if [ "$TOTAL" -eq 0 ]; then
  printf 'MONITOR: no tasks under supervision in this home.\n'
fi
if [ "$N_UNACTIONED" -gt 0 ] || [ "$N_STALLED" -gt 0 ]; then
  exit 1
fi
exit 0
