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
# WHAT THE CALLER GETS. The attach runs in a detached process group with stdin
# closed and both output streams in the task's own temp root. When it returns,
# the SAME detached process re-reads `no-mistakes axi status` and appends exactly
# one line to state/<task-id>.status, so the run's next event wakes firstmate even
# if the worker is idle, compacted, or gone. That status line - not the worker
# noticing - is the notification.
#
# Usage:
#   fm-nm-attach.sh <task-id>
#   fm-nm-attach.sh <task-id> --respond <axi respond args...>
#   fm-nm-attach.sh --help
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
#       The run finished cleanly, so nothing is owed at the gate: `resolved`
#       CLOSES the key. Not captain-relevant by verb, which is correct rather
#       than a downgrade - the watcher then asks bin/fm-crew-state.sh whether the
#       crew is provably working, and a finished run is not, so the wake
#       surfaces on the real state instead of on a hardcoded word.
#   blocked [key=nm-run]: run <id> <failed|cancelled>: <error>
#       Captain-relevant, and `blocked` REPLACES the record under the same key:
#       what firstmate owes moved from "answer the gate" to "deal with the dead
#       run", which is one open decision, not two.
#   paused [key=nm-run]: run <id> still <status> at <step> after <wait>; reattach
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
#   - a second attach while one is already alive for this task
#   - a composed intent too large to reach the daemon (see below)
#
# THE INTENT SIZE CAP. The pinned intent travels as a base64 git push option,
# whose limit is 65520 bytes of encoded text - 49140 raw bytes, since base64
# expands 3 bytes to 4. Over that, this refuses with the exact measured size
# rather than letting the run fail somewhere downstream. Compaction is NOT done
# here: the thing to shorten is the brief's own `## Gate decisions` subsection
# (bin/fm-nm-decision.sh writes it, bin/fm-nm-intent.sh emits it), which is the
# only part of the intent that grows without bound, and task
# fm-nm-intent-size-cap-i6 owns doing that.
set -eu

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
  "") die "usage: fm-nm-attach.sh <task-id> [--respond <axi respond args...>]" ;;
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
  shift 5

  STATUS_FILE="$STATE_DIR/$ID.status"
  say() { printf '%s\n' "$*"; }
  CLASSIFIED=0
  note() { printf '%s\n' "$1" >> "$STATUS_FILE"; CLASSIFIED=1; }

  # The status line this process appends is the ONLY thing that tells firstmate
  # the run moved - the worker's turn ended the moment the parent returned. So a
  # follower that dies on its way to classifying would take the whole
  # notification with it, silently, which is the exact failure class this script
  # exists to remove. So every exit path reports something, and the same handler
  # owns clearing the liveness marker so no path can leave one behind.
  # shellcheck disable=SC2329 # Invoked indirectly, by the EXIT trap below.
  on_follower_exit() {
    if [ "$CLASSIFIED" != 1 ]; then
      printf 'blocked [key=nm-run]: the background attach for %s stopped before it could report what the run did; read the attach log\n' \
        "$ID" >> "$STATUS_FILE"
    fi
    unlink "$MARKER" 2>/dev/null || true
  }
  trap on_follower_exit EXIT

  # The hold. Never `--yes`; the caller already refused it, and it is not added
  # back here.
  ATTACH_RC=0
  if [ "$RESPOND" = respond ]; then
    shift
    say "attaching: no-mistakes axi respond $* --wait $WAIT"
    no-mistakes axi respond "$@" --wait "$WAIT" || ATTACH_RC=$?
  else
    say "attaching: no-mistakes axi run --intent <pinned> --wait $WAIT"
    no-mistakes axi run --intent "$1" --wait "$WAIT" || ATTACH_RC=$?
  fi
  say "attach returned rc=$ATTACH_RC at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Classify from the run record, not from the attach's own prose: the record is
  # what the daemon actually holds, and an elapsed wait prints an `error:` line
  # that is not a failure at all.
  STATUS_RC=0
  RUN_OUT=$(no-mistakes axi status 2>&1) || STATUS_RC=$?
  say '--- axi status ---'
  say "$RUN_OUT"

  field() { printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1; }
  unquote() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}
    case "$s" in \"*\") s=${s#\"}; s=${s%\"} ;; esac
    printf '%s' "$s"
  }

  RUN_ID=$(unquote "$(field id)")
  RUN_STATUS=$(unquote "$(field status)")
  OUTCOME=$(unquote "$(field outcome)")
  RUN_ERROR=$(unquote "$(field error)")
  RUN_BRANCH=$(unquote "$(field branch)")
  [ -n "$RUN_ID" ] || RUN_ID=unknown

  # `axi status` answers with THIS task's run under the key `run:`, and with
  # another branch's run under `other_branch_run:` (internal/cli/axi_query.go
  # picks the key, and adds a leading `current_branch:` only in that foreign
  # case). Both bodies carry the same `id:`/`status:` fields, so a record whose
  # own `branch:` is not ours is discarded rather than reported as this task's
  # run - reporting it would attribute another task's failure to this one.
  if [ -n "$RUN_BRANCH" ] && [ "$RUN_BRANCH" != "fm/$ID" ]; then
    say "discarding a record for $RUN_BRANCH; this task's branch is fm/$ID"
    RUN_ID=unknown
    RUN_STATUS=""
    OUTCOME=""
  fi

  # steps[] rows are `<step>,<status>,<findings>,<duration_ms>` (verified against
  # the installed CLI; tests/fixtures/nm-attach/ holds the captured records).
  # step_in reports the first row whose status is one of the listed states.
  step_in() {  # <state>...
    local states=$1 state
    shift
    for state in "$@"; do states="$states\\|$state"; done
    printf '%s\n' "$RUN_OUT" \
      | sed -n "s/^[[:space:]]*\([A-Za-z][A-Za-z0-9_-]*\),[[:space:]]*\"\{0,1\}\($states\)\"\{0,1\}[[:space:]]*,.*/\1 \2/p" \
      | head -1
  }

  GATE_ROW=$(step_in awaiting_approval fix_review)
  GATE_STEP=${GATE_ROW%% *}
  GATE_STATUS=${GATE_ROW##* }
  if [ -z "$GATE_ROW" ] && { [ "$RUN_STATUS" = awaiting_approval ] || [ "$RUN_STATUS" = fix_review ]; }; then
    # A record with no step table still names its gate in the scalar status.
    GATE_STEP=$RUN_STATUS
    GATE_STATUS=$RUN_STATUS
  fi

  ACTIVE_ROW=$(step_in running fixing ci awaiting_approval fix_review)
  ACTIVE_STEP=${ACTIVE_ROW%% *}
  [ -n "$ACTIVE_STEP" ] || ACTIVE_STEP=$RUN_STATUS
  [ -n "$ACTIVE_STEP" ] || ACTIVE_STEP=unknown

  # A daemon that did not answer at all is its own blocker: a non-zero exit, or a
  # body carrying none of the four keys every `axi status` record opens with.
  # Deliberately NOT "an empty run body", which a healthy running run can print
  # (bin/fm-nm-db-lib.sh's header records that measurement), and deliberately not
  # keyed on `current_branch:` alone, which an on-branch record does not carry.
  if [ "$STATUS_RC" -ne 0 ] \
    || ! printf '%s\n' "$RUN_OUT" | grep -qE '^[[:space:]]*(current_branch:|run:|other_branch_run:|runs\[)'; then
    note "blocked [key=nm-daemon]: daemon unreachable while attached to run $RUN_ID"
  elif [ "$RUN_ID" = unknown ]; then
    # The daemon answered but holds no run for this branch, so the attach never
    # started one. Blocked rather than paused: nothing is going to clear on its own.
    note "blocked [key=nm-run]: no run exists for fm/$ID after attaching (rc=$ATTACH_RC); see the attach log"
  elif [ -n "$OUTCOME" ]; then
    case "$OUTCOME" in
      passed|checks-passed) note "resolved [key=nm-run]: run $RUN_ID $OUTCOME" ;;
      *) note "blocked [key=nm-run]: run $RUN_ID $OUTCOME: $RUN_ERROR" ;;
    esac
  elif [ -n "$GATE_STEP" ]; then
    note "needs-decision [key=nm-run]: run $RUN_ID parked at $GATE_STEP ($GATE_STATUS) - respond through $SCRIPT_DIR/fm-nm-attach.sh $ID --respond"
  else
    case "$RUN_STATUS" in
      # `completed` reaches here only from a record that carries no `outcome:` -
      # the daemon-database rendering never writes one (bin/fm-nm-db-lib.sh) -
      # and a finished run must not read as an external wait.
      completed) note "resolved [key=nm-run]: run $RUN_ID completed" ;;
      failed|cancelled) note "blocked [key=nm-run]: run $RUN_ID $RUN_STATUS: $RUN_ERROR" ;;
      *) note "paused [key=nm-run]: run $RUN_ID still ${RUN_STATUS:-active} at $ACTIVE_STEP after $WAIT; reattach with $SCRIPT_DIR/fm-nm-attach.sh $ID" ;;
    esac
  fi

  say "classified; the EXIT trap clears the marker"
  exit 0
fi

# --- the caller-facing half -------------------------------------------------

ID=$1
shift
RESPOND=run
if [ "$#" -gt 0 ]; then
  [ "$1" = --respond ] || die "unknown argument: $1 (expected --respond)"
  shift
  [ "$#" -gt 0 ] || die "--respond needs the axi respond arguments that follow it"
  RESPOND=respond
fi

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WAIT="${FM_NM_ATTACH_WAIT:-3h}"
BRANCH="fm/$ID"

[ -d "$STATE" ] || die "no state directory at $STATE; is FM_HOME right for task $ID?"

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
MARKER="$STATE/$ID.nm-attach"
if [ -f "$MARKER" ]; then
  LIVE_PID=$(sed -n '1p' "$MARKER" 2>/dev/null || true)
  LIVE_LOG=$(sed -n '2p' "$MARKER" 2>/dev/null || true)
  if [ -n "$LIVE_PID" ] && kill -0 "$LIVE_PID" 2>/dev/null; then
    die "an attach for $ID is already running (pid $LIVE_PID); it will append its own status line when it returns. Watch it at ${LIVE_LOG:-<log path unrecorded>}"
  fi
  unlink "$MARKER" 2>/dev/null || true
fi

# `--yes` is refused rather than passed through: it auto-resolves EVERY ask-user
# finding, including the warning and error ones that are the captain's to decide.
if [ "$RESPOND" = respond ]; then
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) die "--yes is never used from here: it auto-resolves every ask-user finding, including the ones the captain owns" ;;
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
# fm-teardown removes. It is a predictable path under a world-writable sticky
# directory, so the same symlink/ownership refusal fm-spawn.sh applies before
# writing there applies here: -e and -O both follow a link, so -L is asked first.
TASK_TMP="${FM_TASK_TMP_OVERRIDE:-/tmp/fm-$ID}"
if [ -L "$TASK_TMP" ] || { [ -e "$TASK_TMP" ] && [ ! -O "$TASK_TMP" ]; }; then
  die "refusing to write this attach's log under $TASK_TMP: it is a symlink or is owned by another user"
fi
mkdir -p "$TASK_TMP"
LOG="$TASK_TMP/nm-attach-$(date +%s).log"

# Sending the response is what answers a parked gate, so the keyed decision the
# previous attach opened is closed here rather than when this hold returns - see
# the header. It MUST be written before the launch below, not after: a response
# that returns instantly would otherwise let the follower append its own line
# first, and a `resolved` landing after a fresh `needs-decision` would close the
# NEXT gate instead of the one just answered. Everything that can refuse has
# already refused by this point, so nothing is closed for a response never sent.
if [ "$RESPOND" = respond ]; then
  printf 'resolved [key=nm-run]: responded to the gate for %s; attaching again\n' \
    "$ID" >> "$STATE/$ID.status"
fi

# Detach. setsid puts the hold in its own process group and session so it is not
# reaped when the worker's shell, tool call, or whole agent goes away; nohup is
# the fallback where setsid is absent. stdin is closed so the hold can never
# block on a read, and both streams go to the log.
if command -v setsid >/dev/null 2>&1; then
  setsid "$0" --follow-internal "$ID" "$STATE" "$MARKER" "$WAIT" "$RESPOND" \
    "${INTENT:-}" "$@" </dev/null >>"$LOG" 2>&1 &
else
  nohup "$0" --follow-internal "$ID" "$STATE" "$MARKER" "$WAIT" "$RESPOND" \
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
echo "Returning now on purpose. The hold appends one line to $STATE/$ID.status when the run reaches a gate, an outcome, or the wait; that line is what wakes firstmate. Do not poll this - read $LOG or 'no-mistakes axi status' if you want a look."
