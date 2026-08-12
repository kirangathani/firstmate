#!/usr/bin/env bash
# Stalled-validation sweep: which validating tasks have a no-mistakes pipeline
# step that has STOPPED ADVANCING.
#
# THE GAP THIS CLOSES. Firstmate has always been able to detect a stopped
# WORKER: bin/fm-watch.sh's stale-pane path, and the wedge timer on top of it.
# It had no notion of a stopped pipeline STEP. A step running for two minutes
# and a step frozen for twenty hours were represented identically -
# bin/fm-crew-state.sh reports both as `working - source: run-step` - and the
# worker-liveness path never fires either, because a worker blocked in a
# synchronous validation renders a busy pane the whole time, so its pane is
# never stale at all.
#
# Measured consequence, 2026-08-11/12: task eln-drop-variables-w7's CI step sat
# on `could not check CI: gh pr checks: exit status 1` for over twenty hours
# while its PR had been green throughout. Every check firstmate made read
# `working - run-step - validating (running)` and was treated as healthy
# progress. No alarm existed to fire. The root cause is upstream and not ours to
# fix - no-mistakes' CI step shells out to `gh pr checks`, the command
# bin/fm-pr-merge.sh's own header documents as unsuitable (it conflates pending
# with failing, and fails outright from the detached HEAD every task worktree
# is) - so firstmate needs its own detection rather than a fix upstream.
#
# THE PREDICATE IS PROGRESS, NOT LIVENESS AND NOT TOTAL RUNTIME.
# The question is "has this run's step/state CHANGED since it was last looked
# at", never "is the pane quiet" and never "has this run been going a while". A
# long run that keeps advancing stays silent for as long as it takes; a short
# run whose step froze alarms.
#
# THE TOKEN is bin/fm-crew-state.sh's `--progress` line: that reader already
# owns run-step reconciliation, so the fingerprint is built from the `axi
# status` record it already fetched, and its header owns what the token contains
# and why `duration_ms` is excluded from it.
#
# THE RECORD, state/<id>.nm-progress, one line:
#   <first-observed-epoch>\t<last-observed-epoch>\t<surfaced>\t<step>\t<token>
# `first` is when this exact token was first seen; `last` is the most recent
# observation that still saw it. THE FROZEN SPAN IS MEASURED IN OBSERVED TIME,
# `last - first`, never `now - first`, and that is deliberate:
#   - a firstmate restart, a watcher outage, or a machine asleep cannot inflate
#     the span, because a span only grows when something actually looked twice
#     and saw the same step both times;
#   - sampling can only ever UNDER-report a freeze (the change is noticed at the
#     next observation, not the moment it happened), so coarse sampling cannot
#     manufacture a false alarm; and
#   - because the record is a durable state file, the span survives a restart
#     exactly like every other state/ record. An alarm never resets just because
#     firstmate restarted.
#
# WHERE IT RUNS (two places, one predicate - this file owns the predicate):
#   OBSERVE   bin/fm-watch.sh, on its own slow cadence, via `--surface`. That is
#             the only path that pays the cost, and it is also the only path
#             that can reach firstmate promptly: a validating fleet writes no
#             status lines and shows no stale panes, so the heartbeat backs off
#             and a turn end may be hours away - which is exactly how the
#             incident above ran unnoticed overnight.
#   BACKSTOP  bin/fm-guard.sh (warn) and bin/fm-turnend-guard.sh (block), from
#             the durable records only. Those two paths make NO no-mistakes call
#             and spawn no subprocess per task: they stat and read one small
#             file each, so putting this on the turn-end path costs nothing.
#
# COST CONTROL on the observe path. Each read is wall-clock bounded
# (FM_NM_STALL_READ_TIMEOUT), and at most FM_NM_STALL_MAX_READS tasks are read
# per sweep, least-recently-observed first, so a large fleet spreads across
# successive sweeps instead of blocking one watcher cycle behind every task.
# Under-sampling costs only accuracy in the conservative direction (above).
#
# THE THRESHOLD, FM_NM_STALL_SECS, defaults to three hours, chosen against real
# step durations rather than a guess. Across the 61 most recent no-mistakes runs
# on this machine (`no-mistakes axi status --run <id>` over ~/.no-mistakes/logs,
# 2026-08-12), the longest a single step legitimately occupied was 96 minutes
# (`test`), then 73 minutes (`review`), 19 minutes (`lint`) and 7 minutes
# (`document`). Three hours is 1.9x the longest legitimate step observed, so an
# ordinary slow run cannot cry wolf, while the twenty-hour freeze above would
# have surfaced before hour four. Wrong-but-quiet is the failure being fixed;
# wrong-and-noisy is a real cost too, and data/learnings.md already records what
# a guard that fires constantly becomes.
#
# NO FALSE ALARMS. Silent for: a scout or secondmate record (neither drives a
# validation of its own), a task with no run attributed to it, a run that is
# parked at a gate or finished (the unanswered-report alarm owns those), and a
# run whose PR has gone green and is only waiting on a merge decision -
# bin/fm-crew-state.sh reports that as `done`, not `working`, so it never
# reaches this sweep.
#
# WHAT IT DOES NOT COVER, stated rather than hidden: a run whose attribution
# fell back to the coarse repo-wide runs list, and a run record with no step
# table, are both UNMEASURABLE here - there is no step state to compare - so
# their records are cleared rather than aged. A no-mistakes CLI that stops
# answering at all is likewise invisible to this sweep, and stays the
# stale-pane and unanswered-report paths' to catch.
#
# NEVER AUTO-RECOVERS. This detects and alarms. Whether a frozen run is left to
# continue, stopped, or escalated stays firstmate's and the captain's decision.
#
# ACKNOWLEDGEMENT. A finding is silenced by `--ack <id>`, which records the
# frozen token in state/<id>.nm-stall-ack. The key is the token itself, so the
# finding stays quiet while firstmate's answer is in flight and re-arms the
# moment the run advances and freezes again - the same shape, and for the same
# reason, as bin/fm-stale-base.sh's acknowledgement. Deliberately NOT
# bin/fm-ack-lib.sh's record: that one is fingerprinted on the crew's own status
# log, which by construction gains no line while a validation runs, so it could
# neither be re-armed by a later freeze nor silenced without also muting every
# unrelated state that task reports.
#
# Usage:
#   fm-nm-stall.sh                     report from the durable records (cheap)
#   fm-nm-stall.sh --observe           refresh the records first, then report
#   fm-nm-stall.sh --surface           refresh, then print ONLY findings not yet
#                                      surfaced, one line each, and mark them
#   fm-nm-stall.sh --ack <id> [<id>..] silence those findings at their step
#   fm-nm-stall.sh --ack-all           silence every current finding
#   fm-nm-stall.sh --threshold         print the effective threshold in seconds
# Exit: 0 nothing to report, 1 at least one unacknowledged finding, 2 bad usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# The current-state reader is the one owner of run-step reconciliation and of
# the progress token; FM_CREW_STATE_BIN is the established test seam for it
# (bin/fm-classify-lib.sh).
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# Probed rather than sourced unconditionally, for the reason bin/fm-ack-lib.sh
# gives: an unconditional `.` of a missing sibling prints to stderr, and callers
# of this script must stay byte-silent when they have nothing to say.
if [ -r "$SCRIPT_DIR/fm-bounded-lib.sh" ]; then
  # shellcheck source=bin/fm-bounded-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-bounded-lib.sh"
fi

STALL_SECS=${FM_NM_STALL_SECS:-10800}
case "$STALL_SECS" in ''|*[!0-9]*) STALL_SECS=10800 ;; esac
READ_TIMEOUT=${FM_NM_STALL_READ_TIMEOUT:-20}
case "$READ_TIMEOUT" in ''|*[!0-9]*) READ_TIMEOUT=20 ;; esac
MAX_READS=${FM_NM_STALL_MAX_READS:-4}
case "$MAX_READS" in ''|*[!0-9]*) MAX_READS=4 ;; esac

TAB=$'\t'

usage() {
  cat >&2 <<'EOF'
usage: fm-nm-stall.sh [--observe|--surface]
       fm-nm-stall.sh --ack <task-id> [<task-id>...]
       fm-nm-stall.sh --ack-all
       fm-nm-stall.sh --threshold
EOF
}

MODE=report
OBSERVE=0
SURFACE=0
ACK_IDS=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    # The effective threshold, so an operator asking "how long before this
    # fires" and a boundary test sizing itself both read the one live value
    # rather than a second copy that drifts from it.
    --threshold) printf '%s\n' "$STALL_SECS"; exit 0 ;;
    --observe) OBSERVE=1; shift ;;
    --surface) OBSERVE=1; SURFACE=1; shift ;;
    --ack-all) MODE=ack-all; shift ;;
    --ack)
      MODE=ack
      shift
      [ "$#" -ge 1 ] || { usage; exit 2; }
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -*) break ;;
          *) ACK_IDS="$ACK_IDS $1"; shift ;;
        esac
      done
      ;;
    *) usage; exit 2 ;;
  esac
done

[ -d "$STATE" ] || exit 0

# Test seam: freeze "now" so span assertions are deterministic, exactly as
# FM_ACK_NOW does for the unanswered-report predicate.
now() {
  if [ -n "${FM_NM_STALL_NOW:-}" ]; then printf '%s' "$FM_NM_STALL_NOW"; else date +%s; fi
}

progress_file() {  # <task-id>
  printf '%s/%s.nm-progress' "$STATE" "$1"
}

ack_path() {  # <task-id>
  printf '%s/%s.nm-stall-ack' "$STATE" "$1"
}

# "2h04m" / "35m". Spans below a minute never reach a caller (the threshold is
# hours), so minutes are the smallest unit worth printing.
human_span() {  # <seconds>
  local s=$1 h m
  case "$s" in ''|*[!0-9]*) printf 'an unknown time'; return ;; esac
  h=$((s / 3600))
  m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

# --- the record -------------------------------------------------------------

REC_FIRST=
REC_LAST=
REC_SURFACED=
REC_STEP=
REC_TOKEN=
read_record() {  # <task-id>; 1 when absent or malformed
  local line rest f
  REC_FIRST=; REC_LAST=; REC_SURFACED=; REC_STEP=; REC_TOKEN=
  f=$(progress_file "$1")
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || return 1
  REC_FIRST=${line%%"$TAB"*}
  rest=${line#*"$TAB"}
  [ "$rest" != "$line" ] || return 1
  REC_LAST=${rest%%"$TAB"*}
  rest=${rest#*"$TAB"}
  REC_SURFACED=${rest%%"$TAB"*}
  rest=${rest#*"$TAB"}
  REC_STEP=${rest%%"$TAB"*}
  rest=${rest#*"$TAB"}
  REC_TOKEN=$rest
  case "$REC_FIRST" in ''|*[!0-9]*) return 1 ;; esac
  case "$REC_LAST" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$REC_TOKEN" ] || return 1
  return 0
}

write_record() {  # <task-id> <first> <last> <surfaced> <step> <token>
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" > "$(progress_file "$1")" 2>/dev/null
}

# --- observation ------------------------------------------------------------

# Kinds that never drive a no-mistakes validation of their own worktree, so they
# are outside this sweep's domain rather than unchecked (bin/fm-crew-state.sh
# skips the run lookup for exactly these). Read in one pass with no subprocess
# per task, for the reason bin/fm-stale-base.sh gives: this runs once per
# in-flight task on the turn-end path. Last occurrence wins, matching how every
# other reader treats a meta key.
task_is_in_domain() {  # <meta-file>
  local line kind=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) kind=${line#kind=} ;;
    esac
  done < "$1"
  case "$kind" in
    scout|secondmate) return 1 ;;
  esac
  return 0
}

# One bounded current-state read. Sets OBS_SOURCE (the reader's own source
# token) and, when the run carries measurable step progress, OBS_STEP/OBS_TOKEN.
# A read that times out or cannot be parsed leaves OBS_SOURCE empty, which the
# caller treats as "no evidence either way" and NOT as progress.
OBS_SOURCE=
OBS_STEP=
OBS_TOKEN=
observe_task() {  # <task-id>
  local out line rest rc=0
  OBS_SOURCE=; OBS_STEP=; OBS_TOKEN=
  if command -v fm_bounded_available >/dev/null 2>&1 && fm_bounded_available; then
    out=$(fm_bounded_run "$READ_TIMEOUT" "$FM_CREW_STATE_BIN" --progress "$1" 2>/dev/null) || rc=$?
    [ "$rc" -ne 124 ] || return 0
  else
    out=$("$FM_CREW_STATE_BIN" --progress "$1" 2>/dev/null) || true
  fi
  while IFS= read -r line; do
    case "$line" in
      state:*)
        rest=${line#*source: }
        [ "$rest" != "$line" ] || continue
        OBS_SOURCE=${rest%% *}
        ;;
      progress:*)
        rest=${line#progress: }
        case "$rest" in
          *"$TAB"*)
            OBS_STEP=${rest%%"$TAB"*}
            OBS_TOKEN=${rest#*"$TAB"}
            ;;
        esac
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

# Fold one observation into the durable record. Three outcomes, and the
# difference between them is the whole reason this is not a plain timer:
#   token seen, same as recorded   -> extend the frozen span to this observation
#   token seen, different          -> the run ADVANCED: restart the span here,
#                                     which is also what re-arms an acked finding
#   no token, but the run-step read was determinate (parked, finished, coarse or
#   step-less, i.e. nothing to measure) -> drop the record entirely
#   anything else (unreadable, no run attributed) -> leave the record untouched,
#                                     so an unread task's span cannot grow
apply_observation() {  # <task-id> <now>
  local id=$1 t=$2
  if [ -n "$OBS_TOKEN" ]; then
    if read_record "$id" && [ "$REC_TOKEN" = "$OBS_TOKEN" ]; then
      write_record "$id" "$REC_FIRST" "$t" "$REC_SURFACED" "$REC_STEP" "$REC_TOKEN"
    else
      write_record "$id" "$t" "$t" 0 "$OBS_STEP" "$OBS_TOKEN"
    fi
    return 0
  fi
  if [ "$OBS_SOURCE" = run-step ]; then
    rm -f "$(progress_file "$id")" 2>/dev/null || true
  fi
  return 0
}

# Refresh at most MAX_READS records, least-recently-observed first so every task
# is reached across successive sweeps rather than the same few every time. A
# task with no record yet sorts first, because it has never been observed.
observe_sweep() {
  local meta id t order='' row read_count=0
  t=$(now)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_is_in_domain "$meta" || continue
    if read_record "$id"; then
      order="${order}${REC_LAST}${TAB}${id}"$'\n'
    else
      order="${order}0${TAB}${id}"$'\n'
    fi
  done
  [ -n "$order" ] || return 0
  # The loop must stay in THIS shell (observe_task sets globals it consumes), so
  # the sorted list is fed in by here-string rather than through a pipe.
  while IFS= read -r row; do
    # "<last-observed><TAB><id>"; only the id is wanted, the epoch was the sort key.
    id=${row#*"$TAB"}
    [ -n "$id" ] && [ "$id" != "$row" ] || continue
    [ "$read_count" -lt "$MAX_READS" ] || break
    read_count=$((read_count + 1))
    observe_task "$id"
    apply_observation "$id" "$t"
  done <<< "$(printf '%s' "$order" | sort -n -k1,1)"
}

# --- the findings -----------------------------------------------------------

# One tab-separated record per REPORTABLE task, from the durable records only:
#   <id><TAB><surfaced><TAB><token><TAB><sentence>
# A determinate all-clear emits nothing.
scan() {
  local meta id frozen since t
  t=$(now)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_is_in_domain "$meta" || continue
    read_record "$id" || continue
    frozen=$((REC_LAST - REC_FIRST))
    [ "$frozen" -ge "$STALL_SECS" ] || continue
    since=$((t - REC_LAST))
    [ "$since" -ge 0 ] || since=0
    printf '%s\t%s\t%s\t%s\n' "$id" "$REC_SURFACED" "$REC_TOKEN" \
      "$id's validation has been stuck on its $(step_label "$REC_STEP") for $(human_span "$frozen") without advancing (last checked $(human_span "$since") ago)"
  done
}

step_label() {  # <recorded step>
  case "$1" in
    ''|-) printf 'current step' ;;
    *) printf '"%s" step' "$1" ;;
  esac
}

acked() {  # <task-id> <token>
  local recorded
  recorded=$(cat "$(ack_path "$1")" 2>/dev/null) || return 1
  [ "$recorded" = "$2" ]
}

# --- run --------------------------------------------------------------------

[ "$OBSERVE" = 1 ] && observe_sweep

RECORDS=$(scan) || { echo "fm-nm-stall: sweep failed" >&2; exit 2; }

if [ "$MODE" = ack ] || [ "$MODE" = ack-all ]; then
  if [ "$MODE" = ack ] && [ -z "${ACK_IDS# }" ]; then
    usage
    exit 2
  fi
  ACKED_ANY=0
  while IFS=$TAB read -r id surfaced token text; do
    [ -n "$id" ] || continue
    if [ "$MODE" = ack ]; then
      case " ${ACK_IDS# } " in
        *" $id "*) ;;
        *) continue ;;
      esac
    fi
    # The id came from a state/*.meta basename this sweep just read, so the
    # marker path is never caller-controlled.
    printf '%s\n' "$token" > "$(ack_path "$id")" || exit 2
    printf 'acknowledged: %s\n' "$id"
    ACKED_ANY=1
  done <<< "$RECORDS"
  [ "$ACKED_ANY" = 1 ] || printf 'no current stalled-validation finding to acknowledge\n'
  exit 0
fi

if [ "$SURFACE" = 1 ]; then
  # The watcher's contract: print a line only when firstmate should wake, print
  # nothing otherwise. Marking happens here rather than after the caller
  # enqueues, so a watcher that dies in between loses the immediate wake but not
  # the finding - the record still blocks at the next turn end.
  while IFS=$TAB read -r id surfaced token text; do
    [ -n "$id" ] || continue
    [ "$surfaced" != 1 ] || continue
    acked "$id" "$token" && continue
    read_record "$id" || continue
    write_record "$id" "$REC_FIRST" "$REC_LAST" 1 "$REC_STEP" "$REC_TOKEN"
    printf 'NM STALL: %s\n' "$text"
  done <<< "$RECORDS"
  exit 0
fi

REPORT=
UNACKED=0
while IFS=$TAB read -r id surfaced token text; do
  [ -n "$id" ] || continue
  if acked "$id" "$token"; then continue; fi
  UNACKED=1
  REPORT="${REPORT}NM STALL: ${text}"$'\n'
done <<< "$RECORDS"

[ -n "$REPORT" ] || exit 0

# EVERY line this script prints starts with "NM STALL", including the remedy
# footer, for the reason bin/fm-stale-base.sh's own footer states: a relay that
# allowlists lines by marker must not be able to strip the remedy off a finding.
printf '%s' "$REPORT"
printf 'NM STALL REMEDY: read that step before deciding anything - bin/fm-nm-flow.sh <task-id> renders the run, and no-mistakes axi logs --step <step> --run <id> shows the step itself.\n'
printf 'NM STALL REMEDY: a PR that is already green and only waiting on a merge decision can look like this too; read the PR with gh pr view <url> --json statusCheckRollup before treating it as broken.\n'
printf "NM STALL REMEDY: never restart or abort the run on this alarm alone - detection is all this is, and stopping a run is the captain's decision.\n"
printf 'NM STALL REMEDY: once acted on, including relaying it to the captain, silence it with bin/fm-nm-stall.sh --ack <task-id>; it re-arms by itself if the validation freezes again later.\n'

[ "$UNACKED" = 1 ] && exit 1
exit 0
