#!/usr/bin/env bash
# The writer for firstmate's own latency ledger. Sourced, never executed.
# bin/fm-latency.sh is the CLI over the same ledger and owns the report; this
# file owns the FORMAT, the columns, and the never-break-the-caller contract.
# docs/configuration.md's "Self-latency ledger" section is the human-facing
# account of what is recorded and how to read the report.
#
# WHY IT EXISTS. Firstmate is a supervisor, and the thing it is slowest at is
# answering its own crew. Until now that was unmeasurable from its own records:
# state/<id>.status carried no time, state/.wake-queue's enqueue epochs were
# destroyed on drain, and no bin/fm-*.sh recorded its own wall time anywhere.
# The one prior measurement (data/fm-relay-latency-gate-r3/report.md section 2)
# had to parse Claude Code transcripts with a throwaway script, which works for
# exactly one harness. This ledger collects the same facts from firstmate's own
# scripts and its already-wired harness hooks, so the numbers exist for every
# verified harness and survive the session that produced them.
#
# NOTHING HERE MAY EVER BREAK A FLEET COMMAND. Every entry point returns 0
# whatever happens, and every write is guarded, because the alternative is
# instrumentation that can fail a merge. A caller may write
# `fm_latency_cmd_end "$?" || true` for belt and braces, but the `|| true` is
# never load-bearing: these functions do not fail.
#
# --- the ledger -------------------------------------------------------------
#
# $FM_HOME/data/latency.tsv, append-only, tab-separated, one row per event,
# under a header written when the file is created. It lives in data/ and not
# state/ because AGENTS.md section 2 puts DURABLE private fleet records in
# data/ and VOLATILE runtime records in state/, and the whole point of this
# ledger is to compare this week against last month. It is captain-private and
# gitignored with the rest of data/, exactly like data/timeline.tsv.
#
# Columns. Every numeric column holds one bare number or is empty; units are in
# the header; a qualifier gets its own column rather than polluting a number.
# Empty means "not known", never zero and never a placeholder word.
#
#   epoch_ms            when the event was recorded
#   kind                wake | cmd | tool | turn (below)
#   action              wake: the wake kind; cmd: the script; tool: the tool;
#                       turn: `stop`
#   task                the task id the event is about, when it has one
#   duration_ms         cmd: the measured command's wall time
#                       turn: the whole turn's wall time
#   think_ms            the gap since the previous hook event on this session -
#                       model time, because no command was running in it
#   reported_epoch_ms   wake: when the CREW wrote the status line that woke
#                       firstmate, from its own "[t=<epoch>] " stamp. Empty for
#                       a line written before that stamp existed, which is not
#                       an error (bin/fm-classify-lib.sh owns that grammar)
#   enqueued_epoch_ms   wake: when the watcher queued the wake
#   exit_code           cmd: the measured command's exit status
#   tools               turn: how many tool calls the turn made
#   note                free text; the only cell that may hold prose
#
# THE FOUR KINDS, and the eight activities the captain asked to see:
#   wake  one drained wake record. reported -> enqueued -> epoch_ms is the
#         chain from "the crew reported" to "firstmate saw it".
#   cmd   one measured firstmate command, self-timed by the script itself.
#   tool  one tool call arriving at the pre-tool hook. Its think_ms is the gap
#         since the last hook event, which contains no command execution.
#   turn  one turn ending at the turn-end hook.
# Draining the queue and re-arming the watcher are `cmd` rows for those two
# scripts. Getting back to and successfully responding to a crew is a `cmd` row
# for bin/fm-send.sh with its exit_code, read against the preceding `wake`
# row's reported_epoch_ms for the same task. Triage is the interval from a
# `wake` row to the first `cmd` row naming that task.
#
# WHAT IT CANNOT SEE, stated plainly rather than implied: the duration of a
# command that is NOT one of firstmate's self-timed scripts. A pre-tool hook
# fires before a command and a turn-end hook fires at a turn boundary; neither
# harness event fires when a command FINISHES, and only claude publishes a
# transcript to recover it from. So for an unmeasured command the interval to
# the next tool event is execution plus thinking and is recorded as think_ms
# without a separate duration - which is why the scripts on firstmate's own
# supervision path time themselves instead.
#
# --- concurrency ------------------------------------------------------------
#
# No lock. Rows are short single lines written with one O_APPEND `printf`, and
# a write below PIPE_BUF (4096 on Linux, 512 guaranteed by POSIX) to a file
# opened for append does not interleave. The note cell is truncated to keep
# that true even when a caller passes prose.
#
# --- environment ------------------------------------------------------------
#
#   FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE   as every sibling script
#   FM_LATENCY_LEDGER   override the ledger path (default $FM_HOME/data/latency.tsv)
#   FM_LATENCY_OFF      set to any non-empty value to record nothing at all

# Longest note this library will write. Chosen so a whole row stays inside the
# 512-byte atomic-append floor POSIX guarantees, with the fixed columns
# accounted for; see the concurrency note above.
FM_LATENCY_NOTE_MAX=200

FM_LATENCY_HEADER='epoch_ms	kind	action	task	duration_ms	think_ms	reported_epoch_ms	enqueued_epoch_ms	exit_code	tools	note'

_fm_latency_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _fm_latency_lib_dir="."

# Resolve the ledger and the marker directory. Re-resolved on every call rather
# than cached at source time, because a sourcing script may set FM_HOME after
# the source and because a test moves the home between cases.
fm_latency_ledger() {
  local home
  if [ -n "${FM_LATENCY_LEDGER:-}" ]; then printf '%s' "$FM_LATENCY_LEDGER"; return 0; fi
  home=${FM_HOME:-$(cd "$_fm_latency_lib_dir/.." && pwd 2>/dev/null)} || home=
  printf '%s' "${FM_DATA_OVERRIDE:-$home/data}/latency.tsv"
}

fm_latency_state() {
  local home
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then printf '%s' "$FM_STATE_OVERRIDE"; return 0; fi
  home=${FM_HOME:-$(cd "$_fm_latency_lib_dir/.." && pwd 2>/dev/null)} || home=
  printf '%s' "$home/state"
}

# Epoch MILLISECONDS. bash 5's EPOCHREALTIME costs nothing; bash 3.2 (still the
# system bash on macOS) has no sub-second clock at all, so it pays one perl
# fork, and a box with neither degrades to whole seconds rather than refusing.
# `date +%s%3N` is deliberately not used: %N is a GNU extension and silently
# yields the literal "N" on BSD date, which would write a garbage number into a
# numeric column instead of failing.
fm_latency_now_ms() {
  local r f
  r=${EPOCHREALTIME:-}
  case "$r" in
    *[.,]*)
      f=${r#*[.,]}000
      case "${r%%[.,]*}" in
        ''|*[!0-9]*) ;;
        *) printf '%s%s' "${r%%[.,]*}" "${f:0:3}"; return 0 ;;
      esac
      ;;
  esac
  r=$(perl -MTime::HiRes=time -e 'printf "%d", time() * 1000' 2>/dev/null) || r=
  case "$r" in
    ''|*[!0-9]*) r=$(date +%s 2>/dev/null)000 ;;
  esac
  case "$r" in
    ''|000|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$r" ;;
  esac
}

# A cheap, fork-free approximation of bin/fm-primary-scope-lib.sh's
# fm_primary_scope_matches, for the HOOKS, which are checked out into every
# worktree of this repo and therefore also fire inside crewmate and scout task
# worktrees whose events belong to no home's ledger.
#
# It is an approximation on purpose. The real predicate asks git whether
# git-dir equals git-common-dir, which is two forks on a path that runs before
# every single tool call - a measurable cost added to the very thing this
# ledger exists to reduce. A linked worktree's `.git` is a FILE pointing at the
# parent repo and a plain checkout's is a DIRECTORY, which is the same
# distinction for one stat. A genuinely marked secondmate home is force-
# included exactly as the real predicate force-includes it.
#
# It decides only whether to RECORD. Nothing safety-relevant reads it, so the
# worst case of a wrong answer is a row written or skipped, never a gate
# changing its mind.
fm_latency_scope_ok() {  # <root>
  [ -e "$1/.fm-secondmate-home" ] && return 0
  [ -d "$1/.git" ]
}

# Flatten a cell to one tab-free line and bound it. TSV cells are single-line
# by construction everywhere else; the note is the only free text.
fm_latency_clean() {  # <text>
  local t=$1
  t=${t//	/ }
  t=${t//$'\n'/ }
  t=${t//$'\r'/ }
  printf '%s' "${t:0:$FM_LATENCY_NOTE_MAX}"
}

# Append one row. Always returns 0. Every failure mode - an unwritable ledger,
# an absent data directory, a read-only filesystem - is a silent no-op, because
# the caller is a fleet command whose exit status means something else
# entirely.
fm_latency_append() {  # <kind> <action> <task> <duration_ms> <think_ms> <reported_ms> <enqueued_ms> <exit_code> <tools> <note>
  local ledger dir
  [ -z "${FM_LATENCY_OFF:-}" ] || return 0
  ledger=$(fm_latency_ledger) || return 0
  [ -n "$ledger" ] || return 0
  dir=${ledger%/*}
  # Never CREATE the home's data directory. A home that has one is a home whose
  # durable records already live there; anywhere else, recording is not wanted.
  [ -d "$dir" ] || return 0
  # `2>/dev/null` comes BEFORE the append, not after it. Redirections are set
  # up left to right, so with the usual `>> "$f" 2>/dev/null` ordering a
  # FAILING append - an unwritable ledger, a read-only filesystem - has already
  # printed "Permission denied" to the caller's still-original stderr by the
  # time stderr is silenced. That message would land in the middle of a hook's
  # deny object or a fleet command's output, which is exactly the kind of
  # damage this library promises it cannot do.
  if [ ! -e "$ledger" ]; then
    printf '%s\n' "$FM_LATENCY_HEADER" 2>/dev/null >> "$ledger" || return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(fm_latency_now_ms)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
    "$(fm_latency_clean "${10}")" 2>/dev/null >> "$ledger" || return 0
  return 0
}

# --- self-timing a firstmate command ----------------------------------------
#
# Two shapes, because scripts differ in whether they already own an EXIT trap.
#
#   A script with NO exit trap:
#       . "$SCRIPT_DIR/fm-latency-lib.sh"
#       fm_latency_cmd_start fm-send.sh "$ID"
#       trap 'fm_latency_cmd_end $?' EXIT
#
#   A script that ALREADY traps EXIT calls the end function from inside its own
#   handler, so this library never competes for the trap:
#       cleanup() { local status=$?; fm_latency_cmd_end "$status"; ... }
#
# Installing an EXIT trap from inside this library would silently replace a
# caller's existing one - in bin/fm-wake-drain.sh that handler is what restores
# an unconsumed wake queue - so it never does.
FM_LATENCY_CMD_ACTION=
FM_LATENCY_CMD_TASK=
FM_LATENCY_CMD_START=

fm_latency_cmd_start() {  # <action> [task]
  FM_LATENCY_CMD_ACTION=${1:-}
  FM_LATENCY_CMD_TASK=${2:-}
  FM_LATENCY_CMD_START=$(fm_latency_now_ms)
  return 0
}

# Name the task a measurement is about, for a script that only learns it after
# it has started - bin/fm-send.sh resolves its target several steps in, and
# starting the clock after that resolution would leave the resolution itself,
# which is the part that reads metadata, out of the measurement.
fm_latency_cmd_task() {  # <task-id>
  FM_LATENCY_CMD_TASK=${1:-}
  return 0
}

fm_latency_cmd_end() {  # <exit-status> [note]
  local status=${1:-} dur=
  [ -n "$FM_LATENCY_CMD_ACTION" ] || return 0
  [ -n "$FM_LATENCY_CMD_START" ] || return 0
  dur=$(( $(fm_latency_now_ms) - FM_LATENCY_CMD_START ))
  [ "$dur" -ge 0 ] 2>/dev/null || dur=
  case "$status" in ''|*[!0-9]*) status= ;; esac
  fm_latency_append cmd "$FM_LATENCY_CMD_ACTION" "$FM_LATENCY_CMD_TASK" \
    "$dur" '' '' '' "$status" '' "${2:-}"
  # One measurement per invocation: a script whose cleanup runs twice, or which
  # calls this from both a handler and a trap, records one row, not two.
  FM_LATENCY_CMD_ACTION=
  return 0
}

# --- hook events ------------------------------------------------------------
#
# think_ms is the gap since the previous hook event in this home, held in
# state/.latency-last. A pre-tool hook fires with no command running and a
# turn-end hook fires at a turn boundary, so the interval between two hook
# events with no measured command inside it is model time. The marker is
# per-home rather than per-session because exactly one session supervises a
# home at a time (AGENTS.md section 2's session lock).
fm_latency_hook_gap_ms() {  # -> ms since the previous hook event, or empty
  local state marker prev now gap
  state=$(fm_latency_state) || return 0
  marker="$state/.latency-last"
  now=$(fm_latency_now_ms)
  prev=
  [ -f "$marker" ] && IFS= read -r prev < "$marker" 2>/dev/null
  printf '%s\n' "$now" 2>/dev/null > "$marker" || true
  case "$prev" in ''|*[!0-9]*) return 0 ;; esac
  gap=$(( now - prev ))
  [ "$gap" -ge 0 ] 2>/dev/null || return 0
  printf '%s' "$gap"
}

# One tool call arriving at the pre-tool hook.
fm_latency_tool_event() {  # <tool-name>
  [ -z "${FM_LATENCY_OFF:-}" ] || return 0
  fm_latency_append tool "${1:-tool}" '' '' "$(fm_latency_hook_gap_ms)" '' '' '' '' ''
  return 0
}

# One turn ending at the turn-end hook. The turn's own wall time is measured
# from the previous turn end, held in state/.latency-turn.
fm_latency_turn_event() {
  local state marker now prev_end dur tools gap
  [ -z "${FM_LATENCY_OFF:-}" ] || return 0
  dur=
  gap=$(fm_latency_hook_gap_ms)
  state=$(fm_latency_state) || return 0
  marker="$state/.latency-turn"
  now=$(fm_latency_now_ms)
  prev_end=
  [ -f "$marker" ] && IFS= read -r prev_end < "$marker" 2>/dev/null
  case "$prev_end" in
    ''|*[!0-9]*) ;;
    *) dur=$(( now - prev_end )); [ "$dur" -ge 0 ] 2>/dev/null || dur= ;;
  esac
  # Counted before the row below is written, so a turn row can never count
  # itself, and read from the ledger rather than from a counter this function
  # keeps - a counter teardown deletes or a crash drops would make the column
  # lie, and the ledger is the thing that has to be right.
  tools=$(fm_latency_tool_count_since "$prev_end")
  printf '%s\n' "$now" 2>/dev/null > "$marker" || true
  fm_latency_append turn stop '' "$dur" "$gap" '' '' '' "$tools" ''
  return 0
}

# How many tool rows the ledger holds at or after <since_ms>. Read from the
# ledger's own tail rather than kept in a counter, so a counter that drifts,
# is deleted by teardown, or is never written cannot make the column lie.
fm_latency_tool_count_since() {  # <since-epoch-ms>
  local since=$1 ledger
  case "$since" in ''|*[!0-9]*) return 0 ;; esac
  ledger=$(fm_latency_ledger) || return 0
  [ -f "$ledger" ] || return 0
  # Bounded: a turn with more than this many tool calls reports the cap, which
  # is still the right shape of answer and keeps the read off a whole-file scan.
  tail -n "${FM_LATENCY_TURN_SCAN_LINES:-2000}" "$ledger" 2>/dev/null \
    | LC_ALL=C awk -F'\t' -v since="$since" '$2 == "tool" && $1 + 0 >= since + 0 { n++ } END { print n + 0 }' \
    2>/dev/null || return 0
}

# --- drained wakes ----------------------------------------------------------
#
# One row per drained wake record, from the raw
# "epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload" rows bin/fm-wake-drain.sh has
# already printed. The crew's own report time is read from the task's status
# log, where bin/fm-classify-lib.sh's "[t=<epoch>] " prefix puts it; a log
# whose last line predates that prefix yields an empty cell, which is the
# correct answer and not a failure.
fm_latency_wake_rows() {  # raw drain rows on stdin
  local epoch seq kind key payload state task reported enqueued_ms last
  [ -z "${FM_LATENCY_OFF:-}" ] || return 0
  state=$(fm_latency_state) || return 0
  # The status-line parser, loaded HERE and not at source time. Every caller of
  # this function already has it, but a caller of the hook entry points above
  # does not need it, and those run before every single tool call - so the cost
  # of the bigger library is paid only on the one path that reads a status log.
  if ! command -v status_line_epoch >/dev/null 2>&1 \
    && [ -r "$_fm_latency_lib_dir/fm-classify-lib.sh" ]; then
    # shellcheck source=bin/fm-classify-lib.sh
    . "$_fm_latency_lib_dir/fm-classify-lib.sh" 2>/dev/null || true
  fi
  while IFS=$'\t' read -r epoch seq kind key payload; do
    [ -n "$kind" ] || continue
    task=
    reported=
    case "$key" in
      *.status)     task=${key%.status} ;;
      *.turn-ended) task=${key%.turn-ended} ;;
    esac
    case "$task" in
      ''|*[!A-Za-z0-9._-]*) task= ;;
    esac
    if [ -n "$task" ] && [ -f "$state/$task.status" ] \
      && command -v status_line_epoch >/dev/null 2>&1 \
      && command -v last_status_line >/dev/null 2>&1; then
      last=$(last_status_line "$state/$task.status" 2>/dev/null) || last=
      reported=$(status_line_epoch "$last" 2>/dev/null) || reported=
      [ -z "$reported" ] || reported="${reported}000"
    fi
    enqueued_ms=
    case "$epoch" in
      ''|*[!0-9]*) ;;
      *) enqueued_ms="${epoch}000" ;;
    esac
    fm_latency_append wake "$kind" "$task" '' '' "$reported" "$enqueued_ms" '' '' "$(fm_latency_clean "${payload:-}")"
    : "$seq"
  done
  return 0
}
