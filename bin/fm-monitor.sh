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
# THE SEVEN CLASSES, all named on every render:
#   unactioned  reported a state that owes firstmate an action, or left a keyed
#               decision open behind later status lines, past the grace window
#               and not acted on. This is what blocks a turn end.
#   recheck     sitting in a declared external wait that has stood past the
#               recheck window with no recheck recorded inside it. It blocks a
#               turn end the same way, but what it owes is a look at the pane and
#               a re-verification of the worker's stated premise, not an action.
#   pending     owes an action but is still inside the grace window.
#   acked       firstmate did its part; the ball is with the captain, a worker,
#               or an external wait.
#   moved-on    the status log still shows an owed state, but the authoritative
#               current-state read proves the worker resumed past it.
#   captain-driven  the captain is driving this worker himself, either by his
#               own signed record or by sitting in its window right now.
#   upstream-wait  firstmate verified this task has nothing left to do and is
#               purely waiting on somebody outside the fleet. Its gate is
#               bin/fm-upstream-wait.sh's and re-runs on the recheck cadence.
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
#   WHAT IT MEANS is the whole of "the captain is driving this worker himself":
#   firstmate does not alarm on it AND the watcher does not watch it - no wake
#   on its status appends, none on its quiet pane, no mention in a heartbeat.
#   bin/fm-ack-lib.sh's fm_captain_driven is the one predicate every surface
#   asks, and it is equally true with no record at all when a human is simply
#   sitting in the task's window; --exempt is the way to say it out loud, with a
#   reason, for a stretch longer than a sitting. docs/captain-driven.md owns the
#   mechanics and the full list of what goes quiet.
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
#   It does not remove the task from this render, from the backlog, or from the
#   session-start digest: a worker firstmate is not watching has to be a blind
#   spot the captain can see rather than one he has to remember.
#   bin/fm-teardown.sh removes the record with the rest of the task's state.
#
# THE SIBLING DECLARATION, and what makes it different.
#   state/<id>.upstream-wait, one line:
#   <epoch>\t<hmac-hex>\t<awaited action>\t<evidence the gate saw>. It says
#   firstmate verified that a task has nothing left to do and is waiting on
#   somebody outside the fleet, which suspends the same supervision the
#   exemption does and is reported as its own class rather than folded into it.
#
#   --upstream-wait is granted here, beside --exempt, because this is where
#   firstmate comes to declare a standing suppression. What it is NOT is a
#   decision made here: bin/fm-upstream-wait.sh runs the gate first, and this
#   signs only what that gate passed. The captain's stated error case is a
#   crewmate "lazily pretending they are waiting on upstream when they are not",
#   so the crewmate's own yes is one of the gate's conditions and never the
#   grant. That script's header owns every condition and the recheck.
#
# Usage:
#   fm-monitor.sh                          sweep and render every task
#   fm-monitor.sh --quiet                  render only tasks needing attention
#   fm-monitor.sh --exempt <id> --reason <why>   sign a standing exemption
#   fm-monitor.sh --unexempt <id>          drop an exemption
#   fm-monitor.sh --list-exempt            show standing exemptions
#   fm-monitor.sh --upstream-wait <id> --reason <what is awaited>
#                                          run bin/fm-upstream-wait.sh's gate and,
#                                          only if it passes, sign the wait
#   fm-monitor.sh --upstream-resume <id>   drop an upstream wait
#   fm-monitor.sh --list-upstream-wait     show standing upstream waits
# Exit: 0 nothing needs firstmate's attention, 1 at least one unactioned report,
#       overdue recheck, or stalled validation, 2 bad usage or a refused exemption.
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
       fm-monitor.sh --upstream-wait <task-id> --reason "<what is awaited>"
       fm-monitor.sh --upstream-resume <task-id>
       fm-monitor.sh --list-upstream-wait
EOF
}

MODE=sweep
ONLY_ATTENTION=0
TARGET=
REASON=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,102p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    --upstream-wait)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MODE=upstream-wait
      TARGET=$2
      shift 2
      ;;
    --upstream-resume)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MODE=upstream-resume
      TARGET=$2
      shift 2
      ;;
    --list-upstream-wait) MODE=list-upstream-wait; shift ;;
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

# Both records are one tab-separated line, so a reason carrying a newline or a
# tab would produce a record that reads back as a different reason than the one
# that was signed.
require_single_line_reason() {  # <reason>
  case "$1" in
    *"$TAB"*|*"
"*)
      echo "error: --reason must be a single line with no tab characters" >&2
      exit 2
      ;;
  esac
}

# --- exemption verbs ---------------------------------------------------------

case "$MODE" in
  exempt)
    require_known_task "$TARGET"
    if [ -z "$REASON" ]; then
      echo "error: --exempt needs --reason \"<why>\"; an exemption with no stated reason is an unexplained blind spot" >&2
      exit 2
    fi
    require_single_line_reason "$REASON"
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
    printf 'captain-driven: %s is yours now - firstmate neither alarms on it nor watches it (%s)\n' "$TARGET" "$REASON"
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
    printf 'supervision resumed: %s\n' "$TARGET"
    exit 0
    ;;
  upstream-wait)
    require_known_task "$TARGET"
    if [ -z "$REASON" ]; then
      echo "error: --upstream-wait needs --reason \"<what is awaited>\"; a wait with no stated action is one nobody can re-verify" >&2
      exit 2
    fi
    require_single_line_reason "$REASON"
    # The gate runs FIRST, and its refusal is the whole answer: nothing is
    # signed for a task that is not purely waiting, and the conditions it names
    # are what firstmate acts on. bin/fm-upstream-wait.sh's header owns them.
    if ! GATE=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-upstream-wait.sh" --gate "$TARGET" --reason "$REASON" 2>&1); then
      printf '%s\n' "$GATE" >&2
      echo "error: the gate refused, so no upstream wait was recorded for '$TARGET'" >&2
      exit 2
    fi
    # The action that gets SIGNED is the crewmate's own words from the gate,
    # never the --reason typed here, so what the record says is being awaited is
    # the same sentence the gate read and verified against.
    ACTION=$(printf '%s\n' "$GATE" | sed -n 's/^gate action: //p' | head -1)
    EVIDENCE=$(printf '%s\n' "$GATE" | sed -n 's/^gate evidence: //p' | head -1)
    [ -n "$ACTION" ] || ACTION=$REASON
    require_single_line_reason "$ACTION"
    if ! fm_ci_waiver_secret_readable "$SECRET_FILE"; then
      echo "error: no signing key at $SECRET_FILE, so this wait cannot be signed." >&2
      echo "       An unsigned marker would let a worker suspend its own supervision by writing a file," >&2
      echo "       which is the exact pretending this gate exists to stop. Run 'bin/fm-ci-waiver.sh init' first." >&2
      exit 2
    fi
    SIG=$(fm_ci_waiver_upstream_wait_token "$TARGET" "$ACTION" < "$SECRET_FILE") || SIG=
    if [ -z "$SIG" ]; then
      echo "error: could not sign the upstream wait for '$TARGET'" >&2
      exit 2
    fi
    printf '%s\t%s\t%s\t%s\n' "$(fm_ack_now)" "$SIG" "$ACTION" "$EVIDENCE" \
      > "$(fm_upstream_wait_file "$STATE" "$TARGET")" || {
      echo "error: could not write $(fm_upstream_wait_file "$STATE" "$TARGET")" >&2
      exit 2
    }
    # Verify what was just written rather than trusting the write, for the
    # reason --exempt does: a record that does not read back is a blind spot in
    # the other direction.
    if ! fm_upstream_waiting "$STATE" "$TARGET"; then
      find "$STATE" -maxdepth 1 -name "$TARGET.upstream-wait" -delete 2>/dev/null || true
      echo "error: the upstream wait written for '$TARGET' did not verify; nothing was recorded" >&2
      exit 2
    fi
    printf 'upstream wait: %s is waiting on %s - firstmate neither alarms on it nor watches it\n' "$TARGET" "$ACTION"
    printf 'The gate saw: %s\n' "$EVIDENCE"
    printf 'It re-runs on every recheck, so this drops itself the moment that stops being true.\n'
    exit 0
    ;;
  upstream-resume)
    require_known_task "$TARGET"
    if [ ! -f "$(fm_upstream_wait_file "$STATE" "$TARGET")" ]; then
      printf 'no upstream wait recorded for %s\n' "$TARGET"
      exit 0
    fi
    find "$STATE" -maxdepth 1 -name "$TARGET.upstream-wait" -delete 2>/dev/null || {
      echo "error: could not remove $(fm_upstream_wait_file "$STATE" "$TARGET")" >&2
      exit 2
    }
    printf 'supervision resumed: %s\n' "$TARGET"
    exit 0
    ;;
  list-upstream-wait)
    exec env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-upstream-wait.sh" --list
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
N_RECHECK=0
N_PENDING=0
N_ACKED=0
N_MOVED=0
N_EXEMPT=0
N_UPSTREAM=0
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

describe() {  # <class> <verb> <age> <verdict> <detail> <open-keys>
  case "$1" in
    recheck)
      printf 'NEEDS A RECHECK - paused %s without one; read the pane and re-verify what it is waiting on (worker: %s)' \
        "$(fm_ack_duration "$3")" "$(say_worker "$4")"
      ;;
    unactioned)
      if [ -n "$6" ]; then
        printf 'NEEDS ACTION - waiting on a decision (%s) firstmate has not answered; a later status line does not close it (worker: %s)' "$6" "$(say_worker "$4")"
      else
        printf 'NEEDS ACTION - reported "%s" %ss ago and firstmate has not acted (worker: %s)' "$2" "$3" "$(say_worker "$4")"
      fi
      ;;
    pending)    printf 'just reported "%s" - not acted on yet, still inside the %ss window' "$2" "$(fm_ack_resolve_grace)" ;;
    acked)      printf 'reported "%s"; firstmate has acted, now waiting on someone else' "$2" ;;
    moved-on)   printf 'log still shows "%s" but the worker has moved past it' "$2" ;;
    exempt)     printf 'CAPTAIN-DRIVEN, so firstmate is not watching it: %s (worker: %s)' "$5" "$(say_worker "$4")" ;;
    upstream-wait) printf 'WAITING ON ACTION FROM UPSTREAM, verified: %s. Firstmate is not watching it, and the check re-runs on every recheck' "$5" ;;
    *)          printf 'nothing owed - last said "%s" (worker: %s)' "${2:-nothing yet}" "$(say_worker "$4")" ;;
  esac
}

while IFS=$TAB read -r id class verb age verdict open_keys detail; do
  [ -n "$id" ] || continue
  # "-" is this row format's empty; see bin/fm-ack-lib.sh's fm_ack_unactioned.
  [ "$open_keys" != - ] || open_keys=
  [ "$verb" != - ] || verb=
  [ "$verdict" != - ] || verdict=
  line="$id  $(describe "$class" "$verb" "$age" "$verdict" "$detail" "$open_keys")"
  case "$class" in
    unactioned)
      N_UNACTIONED=$((N_UNACTIONED + 1))
      ATTENTION="${ATTENTION}${line}"$'\n'
      [ -z "$detail" ] || ATTENTION="${ATTENTION}    ${detail}"$'\n'
      ;;
    recheck)
      N_RECHECK=$((N_RECHECK + 1))
      ATTENTION="${ATTENTION}${line}"$'\n'
      [ -z "$detail" ] || ATTENTION="${ATTENTION}    ${detail}"$'\n'
      ;;
    pending) N_PENDING=$((N_PENDING + 1)); ATTENTION="${ATTENTION}${line}"$'\n' ;;
    acked)   N_ACKED=$((N_ACKED + 1)); ACCOUNTED="${ACCOUNTED}${line}"$'\n' ;;
    moved-on) N_MOVED=$((N_MOVED + 1)); ACCOUNTED="${ACCOUNTED}${line}"$'\n' ;;
    exempt)
      N_EXEMPT=$((N_EXEMPT + 1))
      # Listed with the attention block, never the quiet one: a task firstmate
      # is not watching is a standing suppression of a safety check and must
      # stay in front of the captain for as long as it lasts.
      ATTENTION="${ATTENTION}${line}"$'\n'
      ;;
    upstream-wait)
      N_UPSTREAM=$((N_UPSTREAM + 1))
      # Same block, same reason. It is a verified suppression rather than the
      # captain's own, which changes who granted it and nothing about its
      # needing to stay visible.
      ATTENTION="${ATTENTION}${line}"$'\n'
      ;;
    *) N_QUIET=$((N_QUIET + 1)); ACCOUNTED="${ACCOUNTED}${line}"$'\n' ;;
  esac
done <<EOF
$ROWS
EOF

TOTAL=$((N_UNACTIONED + N_RECHECK + N_PENDING + N_ACKED + N_MOVED + N_EXEMPT + N_UPSTREAM + N_QUIET))

printf 'MONITOR SWEEP: %s task(s) supervised in %s\n' "$TOTAL" "$STATE"
# Every class on every render, zeros included: a class that is simply absent
# reads as "there were none" and as "we did not check it" identically.
printf 'MONITOR COUNTS: needs-action %s | needs-recheck %s | just-reported %s | acted %s | moved-on %s | captain-driven %s | upstream-wait %s | nothing-owed %s\n' \
  "$N_UNACTIONED" "$N_RECHECK" "$N_PENDING" "$N_ACKED" "$N_MOVED" "$N_EXEMPT" "$N_UPSTREAM" "$N_QUIET"

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
if [ "$N_RECHECK" -gt 0 ]; then
  printf 'MONITOR REMEDY: for each NEEDS A RECHECK task, read its pane and re-verify what it says it is waiting on -\n'
  printf 'MONITOR REMEDY: the stated premise is what nobody has checked. Then record it with bin/fm-ack.sh <id> "<what you verified>",\n'
  printf 'MONITOR REMEDY: which buys one more window before the next recheck is owed.\n'
fi
if [ "$TOTAL" -eq 0 ]; then
  printf 'MONITOR: no tasks under supervision in this home.\n'
fi
if [ "$N_UNACTIONED" -gt 0 ] || [ "$N_RECHECK" -gt 0 ] || [ "$N_STALLED" -gt 0 ]; then
  exit 1
fi
exit 0
