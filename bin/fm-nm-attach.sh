#!/usr/bin/env bash
# The ONE owner of attaching to a no-mistakes pipeline run.
#
# WHY THIS EXISTS. `no-mistakes axi run` and `axi respond` do not start work in
# the caller's shell: the pipeline executes in a shared background daemon and
# these commands ATTACH to the branch's run and block, returning at the next
# gate, decision point, or outcome - or when `--wait` elapses, whichever comes
# first. `--wait` defaults to 8m because a foreground agent tool call is capped
# near 10 minutes. A full run is 25-35 minutes, so a FOREGROUND default-wait
# attach returns `error: wait of 8m0s elapsed while driving the run` three or
# four times per run, each costing a turn and context, and none of them carrying
# any news. Measured 2026-09-15 on task eln-location-no-project-l3: three
# consecutive 8-minute foreground holds, three elapsed errors, no progress.
#
# Worse, the daemon never pushes anything. An ask-user finding parks a step at
# `awaiting_approval` and the run waits INDEFINITELY, so a parked gate is noticed
# only when somebody happens to reattach.
#
# The fix is mechanical rather than advisory, because "remember to background it
# with a long wait" is an instruction an agent decides whether to follow, and
# agents do not reliably decide. A PreToolUse hook cannot close it either: the
# hook sees only the model's command STRING, and harness-native tracked
# background execution is not itself a policy signal
# (bin/fm-arm-pretool-check.sh's header owns that fact). So backgrounding is
# OWNED HERE instead of inspected there. This script always detaches, always uses
# a multi-hour wait, and always returns immediately; the worker cannot get the
# foreground-8m shape out of it. bin/fm-fix-instructions-check.sh denies the raw
# `axi run`/`axi respond` command so this is the only route.
#
# WHAT THIS OWNER DOES NOT COVER: `axi answer`. That verb attaches to nothing -
# it records one answer to a question the run's own reviewer asked and returns at
# once - so none of the reasoning above applies to it, and the raw-command denial
# deliberately does not match it. It is FIRSTMATE'S OWN command, run by
# bin/fm-nm-questions.sh so the captain's answer reaches the reviewer directly
# rather than through the worker (captain's ruling, 2026-09-15). A worker never
# runs it, and `axi respond` refuses `--action answer`, so a gate with questions
# still open cannot be released from either side. Because of that, the answer
# that closes the last open question resumes the reviewer with nothing attached,
# so bin/fm-nm-questions.sh then calls THIS script from the task's worktree - the
# one case firstmate starts an attach, through this owner and its checks.
#
# WHAT THE CALLER GETS. The attach runs in a detached process group with stdin
# closed and both output streams in the task's own temp root. When it returns,
# the SAME detached process re-reads `no-mistakes axi status` and appends exactly
# one line to state/<task-id>.status, so the run's next event wakes firstmate even
# if the worker is idle, compacted, or gone. That status line - not the worker
# noticing - is the notification.
#
# THAT NOTIFICATION REACHES NOBODY WHILE THE CAPTAIN DRIVES THE TASK. The
# watcher keeps a captain-driven task's `needs-decision` lines with the captain
# (docs/captain-driven.md), and nothing here signals the worker's own tool, so a
# parked gate on such a task is a record nobody reads. Measured 2026-11-25: a
# worker under a signed record wrote five warning-severity review findings and
# one security-related info finding to its status log as decisions, said it had
# sent them to firstmate, and the captain first saw them as a question 2 h 53 min
# later, when he asked. `--await` is how that
# worker receives its own returns, and the launch says so under captain control.
#
# Usage:
#   fm-nm-attach.sh <task-id>
#   fm-nm-attach.sh <task-id> --respond <axi respond args...>
#   fm-nm-attach.sh <task-id> --await [--max <seconds>]
#   fm-nm-attach.sh --help
#
# THE AWAIT. `--await` attaches to nothing and needs no worktree: it waits for
# this task's live hold to return, then prints that ONE hold's record - the line
# it recorded (`received: ...`) and the `no-mistakes axi status` it classified,
# both read from the hold's own capture directory, so a result is never paired
# with another hold's findings - and where each decision goes. That routing
# comes from bin/fm-ack-lib.sh's fm_captain_driven, the one predicate the
# watcher asks too, so the worker and the watcher cannot disagree about who will
# read a `needs-decision` line.
# The first await to see a returned hold claims it with a `received` file in
# that capture directory, so its decisions are put to a person once; a second
# read of that hold, or any read with no hold live, prints the record as
# evidence only and never routes it, because it may already be answered.
# A `question-<id>` gate row, and `review-questions-omitted`, are the reviewer's
# own live questions (no-mistakes renders them as ask-user warnings); the await
# names them as bin/fm-nm-questions.sh's to ask and answer, never the worker's.
# It prints only what the pipeline has already published, so it can never show a
# finding before the reviewer has reported it.
#   exit 0  a hold returned; its record is printed above
#   exit 1  the hold ended without recording a result (killed outright)
#   exit 2  no hold is live; the latest hold's record is printed as evidence
#   exit 3  --max elapsed with the hold still live; run --await again
# Run it as a background task where the worker's tool reports a background
# task's exit, otherwise in the foreground with --max, so the tool regains
# control between checks and can still take the captain's messages.
#
# Run it from inside the task worktree, exactly where the raw command runs. It
# refuses when the working directory is not a git worktree on branch
# fm/<task-id>, because `axi status` and `axi run` both answer for the worktree
# they are called in, so a wrong cwd would drive another task's run.
#
#   FM_NM_ATTACH_WAIT   the --wait value passed through (default 3h). Any value
#                       `time.ParseDuration` accepts; verified 2026-09-15 on
#                       no-mistakes v1.70.1 that `--wait 3h` parses and
#                       `--wait 3x` is rejected at flag-parse time.
#
# THE STATUS LINE IT APPENDS, and why each verb is the one it is.
# bin/fm-classify-lib.sh owns the wake vocabulary, and only the verbs it already
# knows are used here, so the line is triaged rather than absorbed as a no-verb
# signal. All four carry the same `[key=nm-run]` token, because a task has at
# most one active run and the keyed fold in that library is what keeps an earlier
# parked gate from being masked by a later unrelated append.
#
#   needs-decision [key=nm-run]: run <id> parked at <step> (<gate-status>) ...
#       The run stopped and will not move until somebody responds. Captain-
#       relevant, and it OPENS the keyed decision so it cannot rot silently.
#   resolved [key=nm-run]: run <id> <passed|checks-passed>
#       The run passed or its PR is ready for fm-pr-green.sh verification: `resolved`
#       CLOSES the key. Not captain-relevant by verb, which is correct rather
#       than a downgrade - the watcher then asks bin/fm-crew-state.sh whether the
#       crew is provably working, and a finished run is not, so the wake
#       surfaces on the real state instead of on a hardcoded word.
#   blocked [key=nm-run]: run <id> <failed|cancelled>: <error>
#       Captain-relevant, and `blocked` REPLACES the record under the same key:
#       what firstmate owes moved from "answer the gate" to "deal with the dead
#       run", which is one open decision, not two.
#   paused [key=nm-run]: run <id> still <status> at <step> after <elapsed>s (wait limit <wait>); reattach
#       `--wait` elapsed with the run still live. That is the library's exact
#       declared-external-wait case: expected to clear on its own, so the idle
#       pane must not be escalated as a possible wedge.
#   blocked [key=nm-daemon]: daemon unreachable while attached to run <id>
#       Its own key, because a dead daemon is not this run's gate.
#
# This is the brief's `gate:`/`outcome:`/`elapsed:` triple mapped onto verbs the
# classifier already supports, which the task asked for explicitly; a new class
# would need both consumers of that library taught about it.
#
# In `--respond` mode one further line is appended at SEND time,
# `resolved [key=nm-run]: responded ...`, because sending the response is what
# answers the parked gate. Without it a park opened by a previous attach would
# stay open through a subsequent `paused` or `resolved` return, and firstmate
# would keep chasing a gate that was already answered. The follower still
# appends exactly one line of its own when the hold returns.
#
# `--wait` is appended AFTER the caller's own respond arguments, and pflag is
# last-wins, so a `--wait 8m` a worker put in its own arguments cannot take
# effect. That ordering is the enforcement, not a detail.
#
# WHAT IT REFUSES, all before anything is launched:
#   - a working directory that is not a git worktree on fm/<task-id>
#   - `--yes`/`-y` in the respond arguments (it auto-resolves every ask-user
#     finding, including the ones the captain owns)
#   - a fix round whose --instructions cannot carry context, delegated to
#     bin/fm-fix-instructions-policy.mjs, the one owner of that decision. The
#     PreToolUse gate can no longer see this command, so the floor is enforced
#     here or nowhere.
#   - a second attach while one is already alive for this task, with exit 3
#     rather than 1, so a caller can tell "already attached" from a failure
#   - a composed intent too large to reach the daemon (see below)
#
# ON A --local-skip TASK this is not the command to reach for: bin/fm-spawn.sh
# puts a `no-mistakes` shim at the front of that worker's PATH which exits 0 with
# a message naming the flag, so the hold learns nothing and classifies the result
# as an unreachable daemon. The shim's own message is in the attach log, which is
# where that diagnosis comes from; the daemon itself is fine.
#
# THE ONE GAP LEFT, stated rather than papered over. The hold reports on every
# exit path once it is running, including being killed. It cannot report if it is
# killed in the few milliseconds between this script returning and the
# re-executed follower installing its handler - but a hold killed in that window
# has not started the attach either, so there is nothing about the run to report,
# and the only trace it leaves is a liveness marker naming a dead pid, which the
# next attach clears rather than being blocked by.
#
# THE INTENT SIZE CAP. The pinned intent travels as a base64 git push option,
# whose limit is 65520 bytes of encoded text - 49140 raw bytes, since base64
# expands 3 bytes to 4. Over that, this refuses with the exact measured size
# rather than letting the run fail somewhere downstream. Compaction is NOT done
# here: the thing to shorten is the brief's own `## Gate decisions` subsection
# (bin/fm-nm-decision.sh writes it, bin/fm-nm-intent.sh emits it), which is the
# only part of the intent that grows without bound, and task
# fm-nm-intent-size-cap-i6 owns doing that.
#
# THE INTENT TRAVELS ON ARGV, and that is bounded on purpose. The follower is
# this same script re-executed, and the intent is handed to it as one argument,
# so it is subject to the kernel's per-argument limit (MAX_ARG_STRLEN, 131072
# bytes on Linux; measured 2026-09-15 - 131071 execs, 131072 does not). An argv
# payload dies at its threshold rather than degrading, which is why firstmate
# normally keeps growing payloads off argv entirely. It is safe here only because
# the size cap above is enforced BEFORE the exec and is far smaller: 49140 raw
# bytes, 2.7x of headroom. tests/fm-nm-attach.test.sh probes the real limit at
# run time and asserts the cap stays under it, so a later cap raise cannot
# silently cross it.
#
set -eu
# Job control OFF, deliberately and explicitly, exactly as bin/fm-watch-arm.sh
# does and for the same reason. With `monitor` on, bash puts each background job
# in its own process group, which makes the launched process a group leader,
# which makes setsid(1) FORK instead of exec. `$!` would then be the short-lived
# setsid process rather than the hold, so the marker below would record a pid
# that dies immediately - and the idempotency guard reads that pid's liveness, so
# a second attach would be allowed to race a hold that is genuinely still
# running. Non-interactive bash already defaults to this, but an exported
# SHELLOPTS carrying `monitor` would otherwise turn it back on.
set +m

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# base64 bytes; see THE INTENT SIZE CAP above.
INTENT_B64_LIMIT=65520

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") die "usage: fm-nm-attach.sh <task-id> [--respond <axi respond args...> | --await [--max <seconds>]]" ;;
esac

# --- the detached half ------------------------------------------------------
#
# Re-entry into this same script rather than a generated runner file: argv is
# passed through as argv, so nothing has to be re-quoted into a script body, and
# there is one copy of the classifier. --follow-internal is not documented in
# --help because it is not a caller-facing mode.
if [ "$1" = --follow-internal ]; then
  shift
  ID=$1; STATE_DIR=$2; MARKER=$3; WAIT=$4; RESPOND=$5
  CAPTURE=$6
  shift 6

  STATUS_FILE="$STATE_DIR/$ID.status"
  say() { printf '%s\n' "$*"; }
  CLASSIFIED=0
  # Every line this follower appends carries the report-time prefix
  # bin/fm-classify-lib.sh owns, so a gate or outcome reported from a detached
  # hold can be timed the same way a crew's own report is. This script is a
  # hardened detached process with an EXIT-trap reporting contract, so it stamps
  # inline rather than taking on a library source it has no other need for.
  stamp() { printf '[t=%s] ' "$(date +%s)"; }
  # The same line also lands in this hold's own capture directory, beside the
  # status read it was classified from, so --await can hand over a result and
  # the findings it came from as one hold's record rather than pairing the
  # newest status line with whichever capture happens to be newest. Best effort:
  # the status line is the notification, and a failed copy must not cost it.
  note() {
    local line
    line="$(stamp)$1"
    printf '%s\n' "$line" >> "$STATUS_FILE"
    CLASSIFIED=1
    printf '%s\n' "$line" > "$CAPTURE/result.line" 2>/dev/null || true
  }

  # The status line this process appends is the ONLY thing that tells firstmate
  # the run moved - the worker's turn ended the moment the parent returned. So a
  # follower that dies on its way to classifying would take the whole
  # notification with it, silently, which is the exact failure class this script
  # exists to remove. So every exit path reports something, and the same handler
  # owns clearing the liveness marker so no path can leave one behind.
  # shellcheck disable=SC2329 # Invoked indirectly, by the EXIT trap below.
  on_follower_exit() {
    # Marker FIRST, then the report. That order matters to anyone watching: the
    # status line is what wakes firstmate, and the marker is what would refuse
    # its next attach, so releasing the marker before the wake means the wake is
    # never observable while a stale marker still blocks acting on it.
    unlink "$MARKER" 2>/dev/null || true
    if [ "$CLASSIFIED" != 1 ]; then
      fallback="$(stamp)blocked [key=nm-run]: the background attach for $ID stopped before it could report what the run did; read the attach log"
      printf '%s\n' "$fallback" >> "$STATUS_FILE"
      printf '%s\n' "$fallback" > "$CAPTURE/result.line" 2>/dev/null || true
    fi
  }
  trap on_follower_exit EXIT

  # Keep each command's stdout separate from stderr/progress and from every
  # other attach. tee preserves the existing live diagnostic log. A failed tee
  # triggers the EXIT trap; the CLI's own exit status comes from PIPESTATUS.
  set +o pipefail
  if [ "$RESPOND" = respond ]; then
    shift
    say "attaching: no-mistakes axi respond $* --wait $WAIT"
    drive=(respond "$@")
  else
    say "attaching: no-mistakes axi run --intent <pinned> --wait $WAIT"
    drive=(run --intent "$1")
  fi
  SECONDS=0
  no-mistakes axi "${drive[@]}" --wait "$WAIT" | tee "$CAPTURE/drive.stdout"
  ATTACH_RC=${PIPESTATUS[0]} ELAPSED=$SECONDS
  printf '%s\n' "$ATTACH_RC" > "$CAPTURE/drive.rc"
  say "attach returned rc=$ATTACH_RC at $(date -u +%Y-%m-%dT%H:%M:%SZ) (elapsed ${ELAPSED}s, wait limit $WAIT)"

  say '--- axi status ---'
  no-mistakes axi status | tee "$CAPTURE/status.stdout"
  STATUS_RC=${PIPESTATUS[0]}
  printf '%s\n' "$STATUS_RC" > "$CAPTURE/status.rc"
  observation=$(awk -v task="$ID" -v drive_rc="$ATTACH_RC" -v status_rc="$STATUS_RC" \
    -f "$SCRIPT_DIR/fm-nm-attach-result.awk" "$CAPTURE/drive.stdout" "$CAPTURE/status.stdout")
  read -r event run value detail <<< "$observation"
  case "$event" in
    daemon) note "blocked [key=nm-daemon]: daemon unreachable while attached to run $run" ;;
    absent) note "blocked [key=nm-run]: no run exists for fm/$ID after attaching (rc=$ATTACH_RC); see the attach log" ;;
    ambiguous) note "blocked [key=nm-run]: ambiguous run status for fm/$ID; see the attach log" ;;
    failed) note "blocked [key=nm-run]: run $run $value: $detail" ;;
    gate) note "needs-decision [key=nm-run]: run $run parked at $value ($detail) - respond through $SCRIPT_DIR/fm-nm-attach.sh $ID --respond" ;;
    passed) note "resolved [key=nm-run]: run $run $value" ;;
    elapsed) note "paused [key=nm-run]: run $run still $value at $detail after ${ELAPSED}s (wait limit $WAIT); reattach with $SCRIPT_DIR/fm-nm-attach.sh $ID" ;;
    *) note "blocked [key=nm-run]: no confirmed attach outcome for fm/$ID (rc=$ATTACH_RC, elapsed ${ELAPSED}s, wait limit $WAIT); see the attach log" ;;
  esac

  say "classified; the EXIT trap clears the marker"
  exit 0
fi

# --- the caller-facing half -------------------------------------------------

ID=$1
shift
RESPOND=run
AWAIT_MAX=
if [ "$#" -gt 0 ]; then
  case "$1" in
    --respond)
      shift
      [ "$#" -gt 0 ] || die "--respond needs the axi respond arguments that follow it"
      RESPOND=respond
      ;;
    --await)
      shift
      RESPOND=await
      if [ "$#" -gt 0 ]; then
        [ "$1" = --max ] && [ "$#" = 2 ] || die "--await takes only --max <seconds>"
        case "$2" in ''|*[!0-9]*) die "--max needs a whole number of seconds, got: $2" ;; esac
        AWAIT_MAX=$2
      fi
      ;;
    *) die "unknown argument: $1 (expected --respond or --await)" ;;
  esac
fi

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WAIT="${FM_NM_ATTACH_WAIT:-3h}"
BRANCH="fm/$ID"
MARKER="$STATE/$ID.nm-attach"
TASK_TMP="${FM_TASK_TMP_OVERRIDE:-/tmp/fm-$ID}"

[ -d "$STATE" ] || die "no state directory at $STATE; is FM_HOME right for task $ID?"

# Who will read a `needs-decision` line from this task, from the one predicate
# the watcher asks (see THAT NOTIFICATION REACHES NOBODY above).
# shellcheck source=bin/fm-ack-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ack-lib.sh"
captain_control() { fm_captain_driven "$STATE" "$ID"; }

# A predictable path under a world-writable sticky directory: -e and -O both
# follow a link, so -L is asked first. Launch and await refuse the same way.
task_tmp_unsafe() {
  [ -L "$TASK_TMP" ] || { [ -e "$TASK_TMP" ] && [ ! -O "$TASK_TMP" ]; }
}

# A recorded pid is a live hold only while it runs: kill -0 also succeeds on a
# zombie nobody has reaped yet, and an await must not wait on one forever.
hold_alive() {  # <pid>
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; esac
}

# --- the await --------------------------------------------------------------
#
# One hold's result is read from that hold's own capture directory: the line it
# recorded (result.line) and the status read it classified (status.stdout). The
# first await to see a returned hold claims it with a `received` file there, so
# the decision is put to a person once. Every other read - no hold live, or a
# hold another await already received - prints that record as evidence only,
# and never as a question still to ask: it may already be answered.

# The gate's findings as "<id>\t<severity>\t<action>" rows. Only the four leading
# columns are parsed; a quoted file field is consumed whole.
gate_findings() {  # <status-file>
  awk '
    function field(   f, c, n) {
      if (substr(s, 1, 1) == "\"") {
        f = ""; n = 2
        while (n <= length(s)) {
          c = substr(s, n, 1)
          if (c == "\"") {
            if (substr(s, n + 1, 1) == "\"") { f = f "\""; n += 2; continue }
            n++
            break
          }
          f = f c; n++
        }
        s = substr(s, n + 1)
        return f
      }
      n = index(s, ",")
      if (n == 0) { f = s; s = ""; return f }
      f = substr(s, 1, n - 1); s = substr(s, n + 1)
      return f
    }
    /^  findings\[[0-9]+\]\{id,severity,file,action,description\}:$/ { on = 1; next }
    on && /^    / { s = substr($0, 5); id = field(); sev = field(); field(); act = field(); print id "\t" sev "\t" act; next }
    { on = 0 }
  ' "$1"
}

# Where each finding of a parked gate goes, so there is one question and one
# answer owner for each. A `question-<id>` row, and the `review-questions-omitted`
# row naming the questions the gate had no room for, are the reviewer's own live
# questions (no-mistakes renders them as ask-user warnings); bin/fm-nm-questions.sh
# owns putting those to the captain and answering them.
route_findings() {  # <status-file>
  local id sev act human='' own='' questions=''
  while IFS=$'\t' read -r id sev act; do
    [ -n "$id" ] || continue
    case "$id" in
      question-*|review-questions-omitted) questions="$questions $id"; continue ;;
    esac
    [ "$act" = ask-user ] || continue
    case "$sev" in
      warning|error) human="$human $id" ;;
      *) own="$own $id" ;;
    esac
  done < <(gate_findings "$1")
  if [ -n "$human" ]; then
    if captain_control; then
      echo "The captain is driving this task ($FM_CAPTAIN_DRIVEN_REASON), so firstmate's monitoring does not relay a needs-decision line from it: the status log is a record nobody reads."
      echo "Put these to the captain in this window now:$human. Then append needs-decision [key=<slug>]: asked the captain in this window - <question> as the record, and resolved [key=<slug>] once he answers."
    else
      echo "Escalate these to firstmate with keyed needs-decision lines (rule 6), and stop:$human."
    fi
  fi
  [ -z "$own" ] || echo "Yours to answer under your brief, unless one is security-shaped:$own."
  [ -z "$questions" ] || echo "The reviewer's own live questions, not findings for you to route or answer:$questions. Firstmate puts each to the captain once and answers it through bin/fm-nm-questions.sh, so do nothing at this gate for them."
  echo "Escalate a security-shaped finding whatever its severity."
}

if [ "$RESPOND" = await ]; then
  pid=$(sed -n '1p' "$MARKER" 2>/dev/null || true)
  log=$(sed -n '2p' "$MARKER" 2>/dev/null || true)
  task_tmp_unsafe && die "refusing to read attach results under $TASK_TMP: it is a symlink or is owned by another user"
  evidence=1
  if hold_alive "$pid"; then
    waited=0
    while hold_alive "$pid"; do
      if [ -n "$AWAIT_MAX" ] && [ "$waited" -ge "$AWAIT_MAX" ]; then
        echo "still running: the attach for $ID (pid $pid) has not returned after ${AWAIT_MAX}s; run $0 $ID --await again"
        exit 3
      fi
      sleep 1
      waited=$((waited + 1))
    done
    capture=${log%/*}
    if [ ! -f "$capture/result.line" ]; then
      echo "the attach for $ID ended without recording a result; read its log at $log and 'no-mistakes axi status'" >&2
      exit 1
    fi
    if ( set -C; date +%s > "$capture/received" ) 2>/dev/null; then
      evidence=0
    else
      echo "this hold's result was already received (epoch $(cat "$capture/received" 2>/dev/null || echo unknown)); what follows is evidence, not a new question"
    fi
    rc=0
  else
    # The hold that wrote its log last is the latest to have returned; a receipt
    # never touches a log, so claiming an old hold cannot make it look newest.
    # shellcheck disable=SC2012 # mktemp names are [A-Za-z0-9], so ls -t is safe here.
    capture=$(ls -t "$TASK_TMP"/nm-attach-*/nm-attach-*.log 2>/dev/null | head -1)
    capture=${capture%/*}
    echo "no attach is live for $ID. The latest hold's record follows as evidence only: it may already be answered, so ask nothing from it, and read 'no-mistakes axi status' for the run's current gate before acting."
    rc=2
  fi
  if [ -z "$capture" ] || [ ! -f "$capture/result.line" ]; then
    echo "no attach result is recorded for $ID"
    exit "$rc"
  fi
  echo "received: $(cat "$capture/result.line")"
  if [ -f "$capture/status.stdout" ]; then
    echo "--- the pipeline's own status when this hold returned ($capture/status.stdout) ---"
    cat "$capture/status.stdout"
    echo "--- end of status ---"
  fi
  if [ "$evidence" = 0 ]; then
    case "$(status_line_body "$(cat "$capture/result.line")")" in
      "needs-decision [key=nm-run]:"*) route_findings "$capture/status.stdout" ;;
      *) echo "Act on the received line as your brief's re-attach loop says." ;;
    esac
  fi
  exit "$rc"
fi

# cwd scoping. Both `axi run` and `axi status` answer for the worktree they are
# called in, so the wrong cwd drives another task's run.
CWD_TOP=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "$(pwd -P) is not a git worktree; run this from inside the task worktree for $ID"
CWD_BRANCH=$(git -C "$CWD_TOP" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$CWD_BRANCH" = "$BRANCH" ] \
  || die "$CWD_TOP is on '${CWD_BRANCH:-a detached HEAD}', not $BRANCH; run this from inside task $ID's own worktree"

# Idempotency. The marker holds the follower's pid and its log path; a pid that
# is still alive means a hold is already driving this run, and a second one would
# race it and double the status lines.
if [ -f "$MARKER" ]; then
  LIVE_PID=$(sed -n '1p' "$MARKER" 2>/dev/null || true)
  LIVE_LOG=$(sed -n '2p' "$MARKER" 2>/dev/null || true)
  if [ -n "$LIVE_PID" ] && kill -0 "$LIVE_PID" 2>/dev/null; then
    echo "error: an attach for $ID is already running (pid $LIVE_PID); it will append its own status line when it returns. Watch it at ${LIVE_LOG:-<log path unrecorded>}" >&2
    exit 3
  fi
  unlink "$MARKER" 2>/dev/null || true
fi

# `--yes` is refused rather than passed through: it auto-resolves EVERY ask-user
# finding, including the warning and error ones that are the captain's to decide.
#
# All four spellings Cobra accepts, not just the bare long one: `--yes`,
# `--yes=true`, `-y`, and `-y` inside a short-flag cluster. The cluster test is
# deliberately narrowed to a pure `-<letters>` word, so an ordinary flag VALUE
# cannot trip it - the only text it could false-refuse is a value that is itself
# nothing but a dash and letters including a y, and refusing that costs a
# reword, while missing a real --yes silently auto-resolves a captain decision.
if [ "$RESPOND" = respond ]; then
  for arg in "$@"; do
    case "$arg" in
      --yes|--yes=*) die "--yes is never used from here: it auto-resolves every ask-user finding, including the ones the captain owns" ;;
      --*) ;;
      -*[yY]*)
        case "$arg" in
          -*[!-a-zA-Z]*) ;;
          *) die "--yes is never used from here (found as $arg): it auto-resolves every ask-user finding, including the ones the captain owns" ;;
        esac
        ;;
    esac
  done
fi

# The pinned intent, from its one owner, for a run. `axi respond` takes no
# --intent, so it is neither composed nor size-checked in that mode.
INTENT=""
if [ "$RESPOND" = run ]; then
  INTENT=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-nm-intent.sh" "$ID") \
    || die "could not compose the pinned intent for $ID (see above); the run is not started"
  RAW_BYTES=$(printf '%s' "$INTENT" | wc -c | tr -d ' ')
  # base64 emits 4 characters per 3-byte group, padding the last partial group,
  # so the encoded size is ceil(raw/3)*4. Split in two so the group count floors
  # before it is scaled, which one expression would get wrong.
  B64_GROUPS=$(( (RAW_BYTES + 2) / 3 ))
  B64_BYTES=$(( B64_GROUPS * 4 ))
  if [ "$B64_BYTES" -gt "$INTENT_B64_LIMIT" ]; then
    die "the pinned intent for $ID is $B64_BYTES bytes base64 ($RAW_BYTES raw), over the $INTENT_B64_LIMIT-byte push-option limit; compact the '## Gate decisions' subsection of $FM_HOME/data/$ID/brief.md, which is the only part of the intent that grows without bound"
  fi
fi

# The fix-instructions floor, from its one owner. The PreToolUse gate now denies
# the raw command, so it never sees a fix round again; enforced here or nowhere.
if [ "$RESPOND" = respond ]; then
  POLICY="$SCRIPT_DIR/fm-fix-instructions-policy.mjs"
  if [ -f "$POLICY" ] && command -v node >/dev/null 2>&1; then
    POLICY_CMD="no-mistakes axi respond"
    for arg in "$@"; do POLICY_CMD="$POLICY_CMD $(printf '%q' "$arg")"; done
    # --fix-instructions-only: that module's default mode denies a raw attach
    # outright, which is the whole point of the PreToolUse gate and would refuse
    # the very command this script exists to run.
    POLICY_OUT=$(node "$POLICY" --fix-instructions-only --command "$POLICY_CMD" 2>/dev/null) || POLICY_OUT=allow
    case "$POLICY_OUT" in
      deny*) die "$(printf '%s' "$POLICY_OUT" | cut -f3-)" ;;
    esac
  fi
fi

# The log goes in the task's own temp root, which fm-spawn creates and
# fm-teardown removes, under the same symlink/ownership refusal fm-spawn.sh
# applies before writing there (task_tmp_unsafe above).
if task_tmp_unsafe; then
  die "refusing to write this attach's log under $TASK_TMP: it is a symlink or is owned by another user"
fi
mkdir -p "$TASK_TMP"
CAPTURE=$(mktemp -d "$TASK_TMP/nm-attach-XXXXXXXX")
LOG="$CAPTURE/nm-attach-$(date +%s).log"

# Sending the response is what answers a parked gate, so the keyed decision the
# previous attach opened is closed here rather than when this hold returns - see
# the header. It MUST be written before the launch below, not after: a response
# that returns instantly would otherwise let the follower append its own line
# first, and a `resolved` landing after a fresh `needs-decision` would close the
# NEXT gate instead of the one just answered. Everything that can refuse has
# already refused by this point, so nothing is closed for a response never sent.
if [ "$RESPOND" = respond ]; then
  printf '[t=%s] resolved [key=nm-run]: responded to the gate for %s; attaching again\n' \
    "$(date +%s)" "$ID" >> "$STATE/$ID.status"
fi

# Detach. setsid puts the hold in its own process group and session so it is not
# reaped when the worker's shell, tool call, or whole agent goes away. stdin is
# closed so the hold can never block on a read, and both streams go to the log.
#
# setsid is ABSENT ON macOS (the same fact bin/fm-watch-arm.sh records), so there
# the hold falls back to nohup: it still survives the parent exiting and SIGHUP,
# but it stays in the caller's process group, so a group-directed kill of the
# worker's shell would take it too. A worker's turn ending sends no such signal,
# so the ordinary case is unaffected; this is stated rather than engineered
# around because the fleet this defends runs on Linux.
if command -v setsid >/dev/null 2>&1; then
  setsid "$0" --follow-internal "$ID" "$STATE" "$MARKER" "$WAIT" "$RESPOND" "$CAPTURE" \
    "${INTENT:-}" "$@" </dev/null >>"$LOG" 2>&1 &
else
  nohup "$0" --follow-internal "$ID" "$STATE" "$MARKER" "$WAIT" "$RESPOND" "$CAPTURE" \
    "${INTENT:-}" "$@" </dev/null >>"$LOG" 2>&1 &
fi
FOLLOWER_PID=$!
# The pid only exists after the launch, so a hold that finishes instantly can
# remove this marker before it is written and leave it behind. That is why the
# liveness test above is `kill -0` on the recorded pid rather than the file's
# existence: a marker whose pid is gone is a dead hold's leftover, and is cleared
# rather than allowed to strand the task.
printf '%s\n%s\n' "$FOLLOWER_PID" "$LOG" > "$MARKER"

echo "attached in the background (pid $FOLLOWER_PID), --wait $WAIT: $LOG"
if captain_control; then
  echo "Returning now on purpose. The hold appends one line to $STATE/$ID.status when the run reaches a gate, an outcome, or the wait, but the captain is driving this task, so firstmate's monitoring does not relay it: that line is a record nobody reads. Run $0 $ID --await now and keep it running until it returns; it prints the result to you."
else
  echo "Returning now on purpose. The hold appends one line to $STATE/$ID.status when the run reaches a gate, an outcome, or the wait; that line is what wakes firstmate. Do not poll this - read $LOG or 'no-mistakes axi status' if you want a look."
fi
