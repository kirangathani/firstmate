#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working, and
# surfaced otherwise, so a crew that finishes (or stops and waits) without a
# current working signal is never silently swallowed. Four things count as that
# evidence, and bin/fm-classify-lib.sh's crew_absorb_class is their one owner:
# an actively-running no-mistakes step, a backend busy signal, a subprocess the
# harness detached and has not reaped, and a live pipeline attach. The last two
# are the shape of a worker idle at its composer while its OWN shell command
# runs - it is not generating, so nothing renders a busy footer, and a plain
# shell command has no run to attribute - which used to read as stopped and cost
# five surfaced wakes in fifteen minutes across three workers (2026-09-17).
# A declared external-wait pause is the separate idle absorb case and re-surfaces
# only on its long bounded cadence, although its initial no-verb status signal
# still surfaces in normal mode. A task the captain has signed out of monitoring
# (state/<id>.monitor-exempt, verified through fm_ack_is_exempt) is absorbed on
# that same bounded cadence: the exemption already said nobody is going to act
# on that pane, so surfacing it every cycle spends a wake for nothing, while the
# bounded recheck keeps a forgotten exemption from rotting invisibly.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active.
#   check: <script>: <out> authenticated check output, always actionable
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   signal: fm-lock ...    this home's session lock was lost mid-cycle and could
#                          not be re-acquired, or another live session now holds
#                          it; supervision stood down and the line names the
#                          exact command that resolves it
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# The wall-clock bound the slow sweeps below use, probed rather than sourced
# unconditionally for the reason bin/fm-nm-stall.sh gives: an unconditional `.`
# of a missing sibling prints to stderr.
if [ -r "$SCRIPT_DIR/fm-bounded-lib.sh" ]; then
  # shellcheck source=bin/fm-bounded-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-bounded-lib.sh"
fi
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The captain-signed monitoring exemption is verified through its owner
# (fm_ack_is_exempt), never by re-reading the record here: the signature IS the
# authority, so a second reader that checked anything less would turn an
# unsigned file into an exemption.
# shellcheck source=bin/fm-ack-lib.sh
. "$SCRIPT_DIR/fm-ack-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crew entering `blocked` wakes its supervisor
# sub-second; the poll loop stays live every cycle as the permanent fail-closed
# backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

# Seconds between cycles, from its one owner in bin/fm-classify-lib.sh (sourced
# above): the same number bin/fm-crew-state.sh ages a detached subprocess
# against and bin/fm-wake-lib.sh measures a watcher handover with.
POLL=$FM_WATCH_POLL_SECS
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
NM_STALL_INTERVAL=${FM_NM_STALL_INTERVAL:-600}  # seconds between stalled-validation sweeps
# How many of a signal file's newly appended lines ride along in the wake. A
# crewmate reports sparingly, so a handful is the whole of what it just said; the
# cap exists only so a runaway writer cannot put an unbounded file into a queue
# record that is read on every wake.
SIGNAL_APPENDED_MAX_LINES=${FM_SIGNAL_APPENDED_MAX_LINES:-6}
# Seconds between review-question sweeps, ZERO by default: the sweep runs on
# every cycle, at the same cadence a crewmate's status line is picked up. A
# separate cadence made a reviewer's question the slowest thing in the loop
# (captain, 2026-09-15), and the sweep is built to be affordable here - an
# unchanged conversation costs two stats and no database query at all, which
# bin/fm-nm-questions.sh's header owns. The knob remains for an operator who
# wants to throttle it.
NM_QUESTIONS_INTERVAL=${FM_NM_QUESTIONS_INTERVAL:-0}
NM_QUESTIONS_TIMEOUT=${FM_NM_QUESTIONS_TIMEOUT:-20}  # seconds bounding one review-question sweep
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# How long a turn-end marker must have sat unseen before a BARE one - a turn-end
# with no status line beside it - is worth a wake of its own. Default: the grace
# above (already spent before this is measured, so a fresh marker reads ~grace
# old) plus two poll cycles, which is the shortest window in which the pane-stale
# layer below can see the same crew twice and surface it. Past it, that layer has
# had its chance and did not fire - the usual cause being that no watcher was
# running when the turn ended - so the marker is surfaced instead of absorbed.
# Both inputs may be FRACTIONAL in a test home (FM_POLL=0.2), and a fraction is a
# hard arithmetic error rather than a rounding, so each is floored to an integer
# with the production default as its fallback before it is added. Without that
# floor the whole assignment failed and left the variable unset, which under
# set -u took the watcher down on its next read.
turn_end_quiet_int() {  # <value> <fallback>
  local v=${1%%.*}
  case "$v" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$v" ;;
  esac
}
TURN_END_QUIET_SECS=${FM_TURN_END_QUIET_SECS:-$(( $(turn_end_quiet_int "$SIGNAL_GRACE" 30) + $(turn_end_quiet_int "$POLL" 15) * 2 ))}
case "$TURN_END_QUIET_SECS" in ''|*[!0-9]*) TURN_END_QUIET_SECS=60 ;; esac
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Provider usage-limit dialog signature. A stale pane showing this dialog is a
# harness frozen at a provider prompt, so no run-step or absorb path may treat
# it as working; its wake carries the dialog evidence instead of the generic
# stale reason firstmate has learned to dismiss as benign (2026-08-02: two live
# crewmates froze at this dialog and sat undetected until a human peeked).
# Phrases as recorded from live claude panes (dialog signatures logged
# 2026-07-14, incident 2026-08-02); override via env if a harness's wording
# changes. Matched against the whole bounded capture, not just the footer,
# because the dialog renders mid-pane; a pane merely DISPLAYING these phrases
# (e.g. an editor open on this file) can false-positive, which costs one loud
# surfaced wake per distinct pane hash and is self-correcting on peek.
LIMIT_DIALOG_REGEX=${FM_LIMIT_DIALOG_REGEX:-'Stop and wait for limit|Adjust monthly spend|Upgrade to Max|Upgrade your plan'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, a busy pane, a detached subprocess older than a poll cycle,
# or a live pipeline attach - via crew_is_provably_working over fm-crew-state.sh,
# whose header owns each reading); a crew that stopped its turn with none of
# those is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent surfaces once PER
# DECLARATION (not per pane hash - see pause_state_class) so a churning idle pane
# cannot turn that one check into an endless bare stale flood.
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Absorb a stale pane under a declared external-wait pause (paused:), a
# dead-agent captain-held transfer, or a captain-signed monitoring exemption,
# and re-surface it once every PAUSE_RESURFACE_SECS for a recheck so it cannot
# rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash> [what-is-holding-it]
  local win=$1 task=$2 h=$3
  local held=${4:-"awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds"}
  local label=${5:-paused}
  local key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (quiet ${age}s, $held)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale ($label, age ${age}s): $win"
}

# Forget a window's bounded-cadence bookkeeping, including the throttle marker
# that keeps handle_paused_stale's re-surface to once per window.
#
# A captain-exempt task is the one case that must survive this. Its absorb runs
# on every poll rather than once per distinct pane hash (nothing about an
# exemption is tied to what the pane is showing), so the throttle marker is the
# ONLY thing keeping it to one re-surface per window - and the callers below
# clear on "the last status line is not a pause", which is true of nearly every
# exempt task. Clearing it each cycle would leave the marker permanently fresh,
# the re-surface would fire on every poll, and the exemption would produce the
# exact wake flood it exists to stop. Guarded here, in the one owner of the
# clearing, rather than at each call site, so a later call site cannot reopen it.
clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  fm_ack_is_exempt "$STATE" "$(window_to_task "$win" "$STATE")" && return 0
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  # .paused-<key> means THIS declaration already had its one live-agent surface
  # (surface_nonterminal_stale and handle_paused_stale both set it; the poll loop
  # clears it the moment the last status line stops being a pause or captain
  # hold). Once it exists the live-agent probe below must not force another
  # surface: a stale hash is classified on FIRST SIGHTING, and an idle pane's
  # hash churns on its own (a clock, a token counter, a redrawn composer), so a
  # per-hash probe re-surfaces a declared pause forever instead of once
  # (2026-09-07 plated-readme-play-store-live-r2: six bare wedge-shaped stale
  # wakes for a worker whose PR was open, green, and awaiting a merge decision).
  # The bounded PAUSE_RESURFACE_SECS recheck, not this probe, is what keeps a
  # forgotten pause from rotting invisibly. An authoritative active run still
  # outranks the declaration here, exactly as on the first-sighting path below.
  if [ -e "$STATE/.paused-$key" ]; then
    if [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
      printf 'paused'
      return
    fi
    class=$(crew_absorb_class "$task")
    if [ "$class" = working ]; then
      rm -f "$recheck_file"
      printf 'working'
      return
    fi
    date +%s > "$recheck_file"
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# The task id a signal file belongs to, which is what the captain reads.
signal_id_of_file() {
  local base
  base=$(basename "$1")
  base=${base%.status}
  printf '%s' "${base%.turn-ended}"
}

# What the crewmate actually WROTE since this watcher last looked, so the wake
# can carry the words instead of a path to go and read them.
#
# The offset comes free: .seen-* already holds the previous "size:mtime"
# signature, so the previous size is the number of bytes to skip. Nothing extra
# is stat'ed and nothing new is persisted.
#
# A file SHORTER than its recorded size was rewritten rather than appended to, so
# an offset into it would read from the wrong place or from nothing at all. Its
# last lines are the closest honest answer to "what does this say now", so that
# is what is taken.
# Lines are joined with " | " before they reach the wake record, which is one
# line by construction (bin/fm-wake-lib.sh's fm_wake_append flattens tabs and
# newlines to spaces); joining first keeps the boundaries between a crewmate's
# separate lines visible instead of running them together.
signal_appended_text() {  # <seen-file> <status-file> <current sig>
  local sf=$1 f=$2 sig=$3 prev prev_size now_size text
  prev=$(cat "$sf" 2>/dev/null || true)
  prev_size=${prev%%:*}
  now_size=${sig%%:*}
  case "$prev_size" in
    ''|*[!0-9]*) prev_size=0 ;;
  esac
  case "$now_size" in
    ''|*[!0-9]*) now_size=0 ;;
  esac
  if [ "$now_size" -lt "$prev_size" ]; then
    text=$(tail -n "$SIGNAL_APPENDED_MAX_LINES" "$f" 2>/dev/null || true)
  else
    text=$(tail -c "+$((prev_size + 1))" "$f" 2>/dev/null | tail -n "$SIGNAL_APPENDED_MAX_LINES" || true)
  fi
  printf '%s' "$text" | awk 'NF { if (out != "") out = out " | "; out = out $0 } END { printf "%s", out }'
}

# One wake payload for one changed signal file: the id first, then the crewmate's
# own words. A turn-end marker carries no words, and says so rather than looking
# like a crewmate who wrote nothing.
signal_payload() {  # <seen-file> <status-file> <current sig>
  local id text
  id=$(signal_id_of_file "$2")
  text=$(signal_appended_text "$1" "$2" "$3")
  case "$2" in
    *.turn-ended) printf 'signal: %s ended its turn' "$id"; return 0 ;;
  esac
  if [ -n "$text" ]; then
    printf 'signal: %s | %s' "$id" "$text"
  else
    printf 'signal: %s wrote to its status file' "$id"
  fi
}

# A BARE turn-end: every file that changed in this batch is a turn-end marker, so
# the crew ended a turn and wrote nothing anybody can act on. The wake it produced
# carried no content at all - measured on a live crewmate on 2026-09-17, which is
# what this absorb exists for.
# Turn-end markers exist for STALE detection, not as an event in their own right:
# a crew that really has stopped - including one that finished through an
# interactive pane menu and wrote no done: status - is caught within two polls by
# the pane-stale layer below, which reads the same crew_absorb_class verdict this
# path used to read and surfaces it as `stale:` with the pane as evidence. So
# absorbing a bare turn-end costs the swallowed-finish guard nothing; it moves it
# one layer down, to the layer that has something to say when it fires.
# The one thing that layer cannot see is a window it can no longer capture at all
# (fm_backend_capture failing skips the task), and TURN_END_QUIET_SECS is the
# valve for exactly that: a marker nothing has spoken for by then surfaces on its
# own rather than waiting for a pane that is never coming back.
signal_is_bare_turn_end() {  # <file> ...
  local f
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    case "$f" in *.turn-ended) ;; *) return 1 ;; esac
  done
  return 0
}

# 0 when any marker in a bare batch has gone quiet past TURN_END_QUIET_SECS, the
# one case where a bare turn-end still surfaces: the pane-stale layer has already
# had its window and produced nothing, so nothing else is going to speak for this
# crew.
signal_turn_end_is_overdue() {  # <file> ...
  local f
  for f in "$@"; do
    [ "$(age_of "$f")" -ge "$TURN_END_QUIET_SECS" ] && return 0
  done
  return 1
}

# THE RECORDED PR FACT FOLLOWS THE TASK, not a hand-run command.
#
# A worker's `done: PR <url>` line is the signal that this task's PR has changed.
# Until this existed, only a hand-run bin/fm-pr-check.sh moved the `pr=` in
# state/<id>.meta, so a task shipping several PRs under one id kept the PREVIOUS
# PR's fact for as long as nobody noticed. Measured 2026-09-16 on
# fm-lock-lineage-fix-l8, which ships seven PRs: it had reported PR 96 hours
# earlier while the record still named PR 95, so the fleet view drew a merged
# PR 95 beside a task that had moved on, and the merge poll armed for PR 95 kept
# reporting it merged on every sweep - armed, and watching nothing.
#
# bin/fm-pr-check.sh stays the ONE writer of that fact and the one owner of
# arming the poll; this only calls it at the moment the evidence arrives. Because
# that script rewrites state/<id>.check.sh and its sidecar in place, re-recording
# also retires the previous PR's poll rather than leaving a second one firing.
#
# It reads the STATUS FILE rather than only the bytes just appended, so a report
# whose own wake was missed still converges the next time that task writes
# anything, and it compares against the recorded fact first, so the ordinary case
# - a worker re-reporting the PR already on record - costs one grep and no call.
#
# --from-watcher is mandatory here, not a preference: it keeps the report's
# captain-facing relay owed, and it keeps the migration - which takes watcher
# exclusion by TERMing this very process - out of the watcher's own call.
# bin/fm-pr-check.sh's header owns both.
record_reported_pr() {  # <status-file>
  local f=$1 id url meta out
  case "$f" in *.status) ;; *) return 0 ;; esac
  url=$(grep -oE 'done: PR https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*' "$f" 2>/dev/null | tail -1)
  [ -n "$url" ] || return 0
  url=${url#done: PR }
  id=$(signal_id_of_file "$f")
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  ! grep -qxF "pr=$url" "$meta" 2>/dev/null || return 0
  if fm_bounded_available 2>/dev/null; then
    out=$(fm_bounded_run "$CHECK_TIMEOUT" "$SCRIPT_DIR/fm-pr-check.sh" --from-watcher "$id" "$url" 2>&1)
  else
    out=$("$SCRIPT_DIR/fm-pr-check.sh" --from-watcher "$id" "$url" 2>&1)
  fi
  triage_log "recorded reported PR for $id: $url${out:+ | $(printf '%s' "$out" | tr '\n' ' ')}"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# declared-pause exemption (a crew waiting on a known external dependency is not
# a surprise block - absorb it on the poll loop's long pause cadence instead),
# and otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane to
# diagnose") is exactly right for a blocked crew, and the drain/dedupe/guard
# machinery already understands it (queued by key=window, so a later poll-path
# stale for the same pane collapses on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"
# Seeded only when absent, exactly like the heartbeat schedule above: the
# cadence has to live in the file rather than in this process, because wake()
# exits and a busy fleet restarts this watcher constantly. A brand-new home
# defers its first stalled-validation sweep by one interval; every later restart
# inherits the schedule already on disk.
[ -e "$STATE/.last-nm-stall" ] || touch "$STATE/.last-nm-stall"

# Whether the per-poll session-lock check below applies to this watcher, decided
# once here. A watcher that does not own the home at startup never had ownership
# to lose: bin/fm-watch-arm.sh armed it with its own announced notice, and the
# blind-turn alarm already covers that home. Arming the check for it would turn
# that announced state into a stand-down on the first poll. Ownership can only be
# LOST, so the check exists to notice a loss, and only an owner can suffer one.
LOCK_ENFORCED=
[ "$(fm_session_lock_ownership "$STATE")" = owned ] && LOCK_ENFORCED=1

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Session-lock ownership, re-checked every cycle beside the self-eviction check
  # above. It costs one file read while ownership holds, and at most a short
  # ancestry walk, because ownership can only be lost by the session process
  # dying, a rival session acquiring or taking over, or a hand edit.
  # `missing` is recoverable: this watcher is the owner's descendant, so
  # bin/fm-lock.sh re-records the owner's own pid. That re-acquire can only fail
  # when no live session sits above this watcher at all, which means the session
  # that armed it is gone and there is nothing left to supervise for.
  # `other` is never recoverable here: a watcher whose session no longer owns
  # this home must stop supervising it. The arm's gate would have refused to
  # start it, so refusing to continue mid-life is that same rule, one poll later.
  # Both stand-downs leave the reason in the durable queue, which is what carries
  # it to the next session start.
  if [ -n "$LOCK_ENFORCED" ]; then
    case "$(fm_session_lock_ownership "$STATE")" in
      owned) ;;
      missing)
        # FM_STATE_OVERRIDE is passed explicitly because bin/fm-lock.sh resolves
        # its state dir from that variable and FM_HOME only, and never from an
        # ambient STATE, so a bare call could acquire against a different home
        # than the one this watcher just judged.
        if ! FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1; then
          reason="signal: fm-lock - this home's session lock is gone and no live session sits above this watcher, so supervision has stopped - run bin/fm-session-start.sh from the session that should own this home"
          fm_wake_append signal fm-lock "$reason" || exit 1
          wake "$reason"
        fi
        ;;
      other)
        fm_session_lock_read "$STATE" || true
        reason="signal: fm-lock - another live session now holds this home ($(fm_session_lock_describe_holder "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_TICKS")), so this watcher stood down - run bin/fm-lock.sh status, then $(fm_session_lock_remedy "$FM_SESSION_LOCK_PID")"
        fm_wake_append signal fm-lock "$reason" || exit 1
        wake "$reason"
        ;;
    esac
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          url=$FM_PR_DATA_URL
          owner=$FM_PR_DATA_OWNER
          repo=$FM_PR_DATA_REPO
          number=$FM_PR_DATA_NUMBER
          # FM_HOME is forwarded because the poll reads the captain's standing
          # merge rule ($FM_HOME/config/merge-green) from it, exactly as the
          # X-mode shim above is given the same home for the same reason.
          FM_HOME="$FM_HOME" run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated "$id" "$url" "$owner" "$repo" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # Slow stalled-validation sweep: has a validating task's no-mistakes step
  # stopped advancing. This needs its own cadence because NOTHING else in this
  # loop ever looks at a healthily-validating task - it writes no status lines,
  # and a worker blocked in a synchronous validation renders a busy pane, so its
  # pane is never stale. That is exactly how one task's CI step sat frozen for
  # twenty hours while every reading said `working`.
  # bin/fm-nm-stall.sh owns the predicate, the threshold, the durable record and
  # the wording. `--surface` follows the *.check.sh contract: it prints a line
  # only when firstmate should wake, and nothing at all otherwise.
  if [ "$(age_of "$STATE/.last-nm-stall")" -ge "$NM_STALL_INTERVAL" ]; then
    touch "$STATE/.last-nm-stall"
    if [ -x "$SCRIPT_DIR/fm-nm-stall.sh" ]; then
      # FM_HOME and the state dir are passed explicitly, as every other sibling
      # this loop invokes is: both are plain shell variables here, so a child
      # would otherwise resolve its own home from the repo root and sweep a
      # different fleet's records.
      nm_stall_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-nm-stall.sh" --surface 2>/dev/null || true)
      if [ -n "$nm_stall_out" ]; then
        # One reason line, because the daemon's wake grammar is line-oriented.
        reason="check: $(printf '%s' "$nm_stall_out" | tr '\n' ' ')"
        fm_wake_append check nm-stall "$reason" || exit 1
        wake "$reason"
      fi
    fi
  fi

  # Review-question sweep, EVERY cycle: has a validating task's reviewer asked
  # something only the captain can answer. It cannot ride a slower cadence for
  # two reasons - a validating fleet writes no status lines and shows no stale
  # panes, so nothing else in this loop looks at it; and the value of the channel
  # is that an early answer redirects the rest of the pass, which a three-minute
  # wait was eating into. It is affordable here because an unchanged conversation
  # costs two stats and no database query; bin/fm-nm-questions.sh's header owns
  # that cost contract, the protocol, the durable record and the wording.
  # `surface` follows the *.check.sh contract of printing a line only when
  # firstmate should wake, and nothing at all otherwise.
  if [ "$(age_of "$STATE/.last-nm-questions")" -ge "$NM_QUESTIONS_INTERVAL" ]; then
    touch "$STATE/.last-nm-questions"
    if [ -x "$SCRIPT_DIR/fm-nm-questions.sh" ]; then
      # Wall-clock bounded like the stall sweep's own reads: this runs inside the
      # watcher's cycle, and a cycle that stretches is what breaks the timing the
      # stale and pause classifications depend on. A sweep cut short costs at
      # most a duplicate wake next cycle, never a swallowed question: the owner
      # prints each question BEFORE it marks it surfaced, and that ordering is
      # what makes the bound safe to put here (see its cmd_surface comment).
      if command -v fm_bounded_available >/dev/null 2>&1 && fm_bounded_available; then
        nm_q_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
          fm_bounded_run "$NM_QUESTIONS_TIMEOUT" "$SCRIPT_DIR/fm-nm-questions.sh" surface 2>/dev/null || true)
      else
        nm_q_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
          "$SCRIPT_DIR/fm-nm-questions.sh" surface 2>/dev/null || true)
      fi
      if [ -n "$nm_q_out" ]; then
        reason="check: $(printf '%s' "$nm_q_out" | tr '\n' ' ')"
        fm_wake_append check nm-questions "$reason" || exit 1
        wake "$reason"
      fi
    fi
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - it is a BARE turn-end - every changed file is a turn-end marker, so the
    #     crew ended a turn and wrote nothing - that has gone quiet past
    #     TURN_END_QUIET_SECS. A bare turn-end inside that window is ABSORBED
    #     however the crew reads, because the wake it makes carries no words to
    #     act on and the pane-stale layer below owns the crew it describes; see
    #     signal_is_bare_turn_end for why that costs the swallowed-finish guard
    #     nothing;
    #   - or it is any OTHER no-verb wake (a working: note, a turn-end beside a
    #     status write) whose crew is NOT provably working - the crew stopped its
    #     turn with no actively-running pipeline and no busy pane, so it may be
    #     done, waiting on a decision, or wedged.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign in always-on
    # mode -> advance the markers so it will not re-fire, log, and keep blocking
    # without enqueuing. The provably-working check is the only costly one (it may
    # run a bounded no-mistakes call), so the branch ordering reaches it ONLY for a
    # non-afk, no-captain-verb signal that is not a fresh bare turn-end.
    actionable=1
    absorb_class=benign
    # $files is a space-separated status-path list (ids carry no spaces). Split it
    # once into an array rather than relying on word splitting at each call: a
    # lint directive only covers one complete compound command, so an unquoted
    # expansion inside an elif branch cannot be annotated where it sits.
    read -r -a signal_files <<< "$files"
    if afk_present || signal_reason_is_actionable "${signal_files[@]}"; then
      :
    elif signal_is_bare_turn_end "${signal_files[@]}"; then
      signal_turn_end_is_overdue "${signal_files[@]}" || { actionable=0; absorb_class="bare turn-end"; }
    elif signal_crew_provably_working "${signal_files[@]}"; then
      actionable=0
    fi
    if [ "$actionable" -eq 1 ]; then
      # The words, not a path to them: read the bytes each file gained since the
      # last look and put them in the record AND in this watcher's own reason, so
      # the wake the model is handed already says what the crewmate said.
      # Both are built here, in the same pass and BEFORE .seen-* is advanced
      # below: once a marker moves to the current size there is no "since the
      # last look" left to read, so a second pass would report every crewmate as
      # having written nothing.
      # $pending holds the pre-grace scan AND the post-grace rescan concatenated,
      # so a file that changed once appears in it TWICE. The queue tolerates that
      # (the drain dedupes on kind+key), but a repeated LINE does not: under a
      # runner that turns each printed line into a notification, every crewmate's
      # words would reach the supervisor twice on every wake. So the spoken lines
      # are deduped by file here, the same way $files is deduped above.
      spoken=
      spoken_seen=
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        payload=$(signal_payload "$sf" "$f" "$sig")
        case " $spoken_seen " in
          *" $f "*) ;;
          *)
            spoken_seen="$spoken_seen $f"
            spoken="$spoken
  $payload"
            ;;
        esac
        fm_wake_append signal "$(basename "$f")" "$payload" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
        record_reported_pr "$f"
      done <<EOF
$pending
EOF
      # The reason line keeps its exact existing shape as the FIRST line, because
      # the arm layer classifies a cycle by matching ^signal: on it. The words
      # follow it, indented, as further lines.
      wake "$reason$spoken"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed $absorb_class $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # A visible usage-limit dialog outranks every absorb path below: the
        # harness is frozen at a provider prompt, so neither an active run-step
        # nor a busy-looking state proves work is under way. One-shot per
        # distinct hash like every other stale classification. A crew that
        # declared its limit wait (paused:) or is captain-held stays on the
        # bounded pause cadence instead; secondmates reach this loop only when
        # paused, so the same guard covers them.
        if printf '%s' "$tail40" | grep -qiE "$LIMIT_DIALOG_REGEX" \
          && ! status_is_paused_or_captain_held "$last" \
          && [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
          fm_wake_append stale "$w" "stale: $w (usage-limit dialog visible - the worker is frozen at a provider-limit prompt, not working; act now, never absorb as busy)" || exit 1
          printf '%s' "$h" > "$sf"
          rm -f "$ssf"
          wake "stale: $w (usage-limit dialog visible)"
        fi
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif fm_ack_is_exempt "$STATE" "$task"; then
          # The captain has signed this task out of monitoring, which is a
          # standing statement that its quiet pane is not firstmate's to chase -
          # typically a window the captain is driving themselves. Surfacing it
          # every cycle spends a wake on a task nobody is going to act on, which
          # is what the exemption already said. Absorbed on the SAME bounded
          # cadence a declared pause uses, so a forgotten exemption still
          # re-surfaces once a window rather than rotting invisibly. The
          # verifier is the owner's; an unsigned or hand-written record is not
          # an exemption and never reaches here.
          #
          # Deliberately BELOW the usage-limit dialog check above, which is
          # untouched: a harness frozen at a provider prompt is not quiet
          # because the captain is driving it.
          handle_paused_stale "$w" "$task" "$h" \
            "captain-exempt from monitoring ($FM_ACK_EXEMPT_REASON) - rechecked on a long cadence; confirm the exemption still holds" \
            captain-exempt
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crew has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && ! window_is_busy "$w" "$tail40"; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
