#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's own ship branch fm/<id>, else
# the pane busy-signature) and reconciles the possibly-stale log against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's OWN ship branch fm/<id>, active
#      or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Attribution is keyed on fm/<id> (bin/fm-brief.sh's branch
#      contract), because a worktree pool slot re-leased to a newer task after
#      this worker died without teardown still sits at the path meta records, so
#      a read through that path answers for the NEW occupant and would report a
#      dead task as working (2026-07-30 incident). Three ownership tiers decide
#      what a read through the recorded worktree may be attributed to (see the
#      attribution block below): the worktree checked out on fm/<id> is the
#      strong proof and keeps full attribution unconditionally; a worktree on
#      any other branch that no other task records is unproven either way, so it
#      keeps its own `axi status` answer only while this task's own agent
#      process is confirmed alive; a worktree provably another task's gets no
#      attribution from that path at all, only its own fm/<id> row in the
#      repo-wide runs list.
#      The coarse runs list is repo-wide and is therefore only ever queried for
#      fm/<id>, the one branch name unique to this task.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail. A busy pane reports
#      working EXCEPT when the recorded worktree is off the fm/<id> contract and
#      is either provably another task's or has no confirmed-live agent of its
#      own, since the busy banner cannot then be told apart from a crew parked
#      at a gate. An active run record and a coarse `running` row are withheld
#      on that same not-proven-so-not-healthy rule (wt_ownership_unproven), so
#      all three healthy-verdict sites fail closed together. A crew still on its
#      own fm/<id> is never in that tier, so a closed window over a genuinely
#      in-flight run keeps full run-step attribution and still reports working.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log. Every verdict carries the "worktree not
#      on fm/<id>" observation when the recorded checkout has moved off the
#      contract branch, since that is what recovery has to know.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
#
# --progress adds ONE extra line after the canonical one, and only for a run this
# reader is currently calling `working` off a FULL `axi status` record:
#
#   progress: <active-step><TAB><token>
#
# The token is a deterministic fingerprint of the run's own step table - the run
# id, the top-level status, and every step's name, status and finding count. It
# is the input bin/fm-nm-stall.sh compares across observations to tell a run that
# is ADVANCING from one that has stopped advancing, so it deliberately excludes
# `duration_ms` and every other column that ticks: a fingerprint that changed on
# its own could never expose a frozen step. The column filter is an ALLOWLIST
# read from the TOON header rather than a positional drop, so a future
# no-mistakes that adds another ticking column is excluded by construction.
# Nothing else about this reader's output or behaviour changes, and the line is
# never emitted without the flag.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-bounded-lib.sh
. "$SCRIPT_DIR/fm-bounded-lib.sh"

PROGRESS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --progress) PROGRESS=1; shift ;;
    --) shift; break ;;
    -*) echo "usage: fm-crew-state.sh [--progress] <id>" >&2; exit 2 ;;
    *) break ;;
  esac
done

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh [--progress] <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
#
# $WT_NOTE (set below, empty until then) is appended to EVERY verdict, not just
# the run-step one: when the recorded worktree is no longer checked out on this
# task's own fm/<id>, recovery needs that observation most on the paths where
# there is no run to report at all (a dead endpoint, a stale status log), since
# it is the one hint that the recorded worktree may no longer hold this task's
# unlanded work.
# Set only on the --progress path, and only for a working run read from a full
# `axi status` record (see nm_progress_record). Empty everywhere else, which is
# what tells bin/fm-nm-stall.sh this verdict carries no measurable step progress.
PROGRESS_LINE=""

emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2" detail=${3:-}
  if [ -n "${WT_NOTE:-}" ]; then
    if [ -n "$detail" ]; then detail="$detail${SEP}${WT_NOTE}"; else detail=$WT_NOTE; fi
  fi
  [ -n "$detail" ] && line="$line${SEP}$detail"
  printf '%s\n' "$line"
  if [ "$PROGRESS" = 1 ] && [ -n "$PROGRESS_LINE" ]; then
    printf 'progress: %s\n' "$PROGRESS_LINE"
  fi
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
# The exact-label check is applied only where the endpoint's label is pinned
# (fm_backend_expected_label_of_meta): a tmux meta written before that pin
# became a hard spawn requirement reads leniently, so a live crewmate whose
# window drifted is never masked as an unreadable pane here.
EXPECTED_LABEL=$(fm_backend_expected_label_of_meta "$META" "$ID")
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    # tmux goes through the shared fm_backend_target_exists primitive rather
    # than a raw `tmux display-message` probe: display-message falls back to
    # the session's current window and exits 0 for any name, so the inline
    # probe reported a closed pane as readable (bin/backends/tmux.sh,
    # fm_backend_tmux_target_exists).
    tmux) fm_backend_target_exists "$TASK_BACKEND" "$1" "$EXPECTED_LABEL" ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# 0 only when a real harness-agent PROCESS is CONFIRMED running for this crew.
# Deliberately fm_backend_agent_alive and not pane_readable: bin/fm-spawn.sh
# types the harness command into the endpoint's own shell, so a crew whose agent
# died leaves the endpoint readable as a bare shell, and the window itself is
# removed only by bin/fm-teardown.sh's kill - which by definition did not run in
# the dead-without-teardown shape this predicate exists to catch. Pane presence
# would therefore still be true for exactly the dead task it is meant to expose.
# Per fm_backend_agent_alive's contract a caller must never license anything
# from `unknown`, so only a literal `alive` corroborates: `dead`, `unknown`, an
# unreadable target, and every backend without a verified classifier all fail
# closed, and the verdict stays unknown so the crew surfaces for supervision.
# The reading is memoized: this helper is consulted from more than one decision
# point in a single invocation, each probe is a real backend round trip (a herdr
# CLI call on that backend), and fm-crew-state runs per heartbeat for every crew
# in the fleet.
AGENT_ALIVE_VERDICT=""
crew_agent_alive() {
  [ -n "$BACKEND_TARGET" ] || return 1
  if [ -z "$AGENT_ALIVE_VERDICT" ]; then
    AGENT_ALIVE_VERDICT=$(fm_backend_agent_alive "$TASK_BACKEND" "$BACKEND_TARGET" 2>/dev/null) \
      || AGENT_ALIVE_VERDICT=unknown
    [ -n "$AGENT_ALIVE_VERDICT" ] || AGENT_ALIVE_VERDICT=unknown
  fi
  [ "$AGENT_ALIVE_VERDICT" = alive ]
}
# crew_pane_is_busy: the busy-signature fallback, backend-aware the same way -
# fm_backend_busy_state's native semantic state (herdr's agent.get) when
# available, else the shared tmux pane-regex reader (fm_pane_is_busy,
# bin/fm-tmux-lib.sh) unchanged for tmux/unknown.
#
# `busy` alone is trusted outright. Both `idle` and unknown/unparseable fall
# through to the shared tail-regex corroboration, NOT just unknown: herdr's
# agent.get reports generation state ("working" while the model is streaming
# a turn, "done"/"idle" once it is not - docs/herdr-backend.md "Busy state"),
# which is a narrower signal than "this crew's turn/tool call is still in
# progress". A crew blocked on its own long-running foreground tool call (e.g.
# `no-mistakes axi run` without --yes, which blocks synchronously until a gate
# or outcome - AGENTS.md section 7) is not generating for that whole span, so
# agent.get can read idle/blocked (bin/backends/herdr.sh maps both to `idle`)
# while the pane's own rendered text still shows the harness's busy banner
# (BUSY_REGEX, e.g. "esc to interrupt") for the entire tool call, exactly like
# tmux's regex-only reader would correctly report. Trusting herdr's `idle`
# outright (skipping that corroboration) is what let a still-working crew read
# as not-busy here, and - combined with a no-mistakes run-step lookup that also
# missed attribution (see nm_runs_status_for_branch) - as not provably working in
# fm-classify-lib.sh, triggering an immediate (non-wedge) stale wake instead of
# the absorb-then-escalate path. A genuinely human-blocked agent (a permission
# dialog, not mid-tool-call) does not render the busy banner, so this
# corroboration does not mask that case: it stays correctly not-busy.
crew_pane_is_busy() {  # <target>
  case "$TASK_BACKEND" in
    tmux) fm_pane_is_busy "$1" ;;
    *)
      local bs tail40
      bs=$(fm_backend_busy_state "$TASK_BACKEND" "$1" 2>/dev/null)
      case "$bs" in
        busy) return 0 ;;
        *)
          tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || return 1
          printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
            | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
          ;;
      esac
      ;;
  esac
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# Bounded no-mistakes call in the worktree; stdout only, never fails the script.
# A host with no bounder at all runs nothing rather than risking an unbounded
# no-mistakes call inside crew-state's own polling loop.
nm_run() {  # <args...>
  fm_bounded_available || return 0
  ( cd "$WT" && fm_bounded_run "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

# The --progress payload: "<active-step><TAB><token>", or nothing at all when
# this run record carries no step table to measure. Read from $RUN_OUT, so it
# costs no extra no-mistakes call on top of the one the run-step path already
# made.
#
# The active step is the first row whose status is running or fixing - the step a
# frozen run is frozen ON, which is what the alarm has to be able to name.
#
# WHY AN ALLOWLIST. Only columns the TOON header names `step`, `status` and
# `findings` enter the token. Every other column is dropped by name, not by
# position, because the point of the token is to change when and only when the
# pipeline ADVANCES: `duration_ms` climbs on its own while a step sits still, so
# including it would make a wedged step look like a moving one forever. A row
# whose field count does not match the header ends the table rather than being
# guessed at.
#
# A run with no steps table at all yields nothing, so it is reported as
# unmeasurable rather than as a step frozen at an unknown name.
nm_progress_record() {
  printf '%s\n' "$RUN_OUT" | awk \
    -v run="$(strip_quotes "$(nm_field id)")" \
    -v st="$(strip_quotes "$(nm_field status)")" '
    BEGIN { active = ""; steps = ""; n = 0; intab = 0; stepcol = 0; statuscol = 0 }
    # Anchored, so the sibling active_steps[N]{...} table a live run also emits
    # cannot be mistaken for this one. That table exists to be watched by a
    # human and carries active_for and last_activity, both of which re-render on
    # every read; nothing from it may reach a progress fingerprint.
    !intab && /^[ \t]*steps\[[0-9]+\]\{[^}]*\}[ \t]*:/ {
      hdr = $0
      sub(/^[ \t]*steps\[[0-9]+\]\{/, "", hdr)
      sub(/\}[ \t]*:.*$/, "", hdr)
      n = split(hdr, f, ",")
      for (i = 1; i <= n; i++) {
        gsub(/[ \t"]/, "", f[i])
        keep[i] = (f[i] == "step" || f[i] == "status" || f[i] == "findings")
        if (f[i] == "step") stepcol = i
        if (f[i] == "status") statuscol = i
      }
      intab = 1
      next
    }
    intab {
      line = $0
      gsub(/^[ \t]+/, "", line)
      gsub(/[ \t]+$/, "", line)
      m = split(line, c, ",")
      if (m != n || n == 0) { intab = 0; next }
      rec = ""
      for (i = 1; i <= m; i++) {
        gsub(/^[ \t"]+/, "", c[i])
        gsub(/[ \t"]+$/, "", c[i])
        if (keep[i]) rec = rec (rec == "" ? "" : ":") c[i]
      }
      steps = steps (steps == "" ? "" : ",") rec
      if (active == "" && stepcol > 0 && statuscol > 0 \
        && (c[statuscol] == "running" || c[statuscol] == "fixing")) active = c[stepcol]
      next
    }
    END {
      if (steps == "") exit 0
      printf "%s\t%s\n", (active == "" ? "-" : active), \
        "run=" run ";status=" st ";steps=" steps
    }
  '
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# matching row's status word (running/completed/cancelled/failed), or empty
# when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
#
# The branch passed here must always be fm/<id>. This list is REPO-WIDE, so
# unlike the in-worktree `axi status` answer it carries no path scoping of its
# own: fm/<id> is the only branch name that is unique to one task. Looking a
# crew up under whatever branch its worktree happens to be on would match the
# newest run anyone started on a shared name like main and report this crew
# working off someone else's run.
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out row st rest br
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    if [ "$br" = "$branch" ]; then
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# The run attribution key is this task's OWN ship branch, fm/<id> - the branch
# contract bin/fm-brief.sh scaffolds ("create your branch: git checkout -b
# fm/$ID") and bin/fm-promote.sh instructs. A worktree pool slot (treehouse) is
# released when its worker dies without teardown, while meta deliberately
# survives so recovery can find the worktree and unlanded work; once the slot is
# re-leased to a newer task, the path in meta belongs to a DIFFERENT live task,
# and both `git symbolic-ref` and `axi status` resolved through that path answer
# for the new occupant. Keying the match on those answers reported two genuinely
# dead tasks as `working - validating (running)` (2026-07-30 incident:
# nm-flow-view-r7, fm-upstream-sync-b3, and live kept-exec-p2 all recorded the
# identical recycled slot path).
EXPECTED_BRANCH="fm/$ID"
# CREW_BRANCH - what the recorded worktree is checked out on right now - is the
# STRONG ownership proof, and only when it equals fm/<id>: that branch is unique
# to this task, a fresh lease starts detached and creates its own fm/<new-id>,
# and git refuses to check one branch out in two worktrees of the same repo, so
# an equal reading means the slot is still ours and everything read through the
# path is ours. Empty at detached HEAD (a just-spawned crew, a scout's scratch
# worktree, or a recycled slot's fresh lease): skip the lookup entirely, as
# before, so a respawned crew that has not yet re-created fm/<id> is read from
# its pane rather than a previous attempt's terminal run.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# Physically-resolved form of <path>, falling back to the raw string when it
# cannot be resolved (a path that no longer exists). Meta's worktree= is written
# from each backend's own cwd read (bin/fm-spawn.sh), which is physical for some
# backends and possibly symlinked for others, so two metas recording ONE slot
# can differ as raw strings and must be compared in this normalized form.
norm_path() {  # <path>
  local p=${1:-} real
  [ -n "$p" ] || return 0
  if real=$(cd "$p" 2>/dev/null && pwd -P); then printf '%s' "$real"; else printf '%s' "$p"; fi
}
WT_REAL=$(norm_path "$WT")

# 0 when some OTHER surviving state/<other>.meta records this very worktree
# path. bin/fm-teardown.sh removes meta, so a second surviving record of one
# path is the direct evidence that the pool slot was leased out more than once
# and this task can no longer claim exclusive ownership of it.
wt_recorded_by_another_task() {
  local meta other other_wt
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    other=${meta##*/}
    other=${other%.meta}
    [ "$other" = "$ID" ] && continue
    other_wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$other_wt" ] || continue
    [ "$(norm_path "$other_wt")" = "$WT_REAL" ] && return 0
  done
  return 1
}

# WT_FOREIGN=1 means the recorded worktree is provably NOT exclusively this
# task's, so nothing read through that path may be attributed here. Two proofs,
# both independent of what is running inside it:
#   - it is checked out on ANOTHER task's ship branch (fm/<other-id>), which
#     only the slot's newer lessee can have created; or
#   - another surviving meta records the same path (wt_recorded_by_another_task).
# Neither proof is exhaustive - an occupant that is a human, a tool, or a crew
# from another FM_HOME sitting on a non-fm branch leaves both false - so a
# worktree that merely fails them is NOT thereby proven ours. That is why
# attribution off an off-contract branch additionally requires this task's own
# agent process to be confirmed alive (crew_agent_alive) below: an unrecorded
# foreign occupant implies our own agent is long gone, while the case that
# actually needs the attribution - a ship crew PARKED at a gate, blocked in a
# synchronous `no-mistakes axi run` - has a real agent process by construction,
# so it still reports parked and surfaces for a captain decision instead of
# being read as a busy pane and absorbed by crew_absorb_class.
# WT_NOTE states only what the branch mismatch itself proves - the worktree is
# not on fm/<id> - and never that the slot was re-leased, which a mismatch alone
# does not show. emit() appends it to every verdict.
WT_FOREIGN=0
WT_NOTE=""
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && [ "$CREW_BRANCH" != "$EXPECTED_BRANCH" ]; then
  WT_NOTE="worktree not on $EXPECTED_BRANCH (now on $CREW_BRANCH)"
  case "$CREW_BRANCH" in
    fm/*) WT_FOREIGN=1 ;;
    *) if wt_recorded_by_another_task; then WT_FOREIGN=1; fi ;;
  esac
fi

# 0 when this task sits in the UNPROVEN tier: its recorded worktree is off the
# fm/<id> contract AND this task's own agent is not confirmed alive, so neither
# the worktree's ownership nor a live worker behind any signal read here could
# be established. Nothing in that tier may yield a healthy verdict: every signal
# that would tell real work apart from a dead task (or from a crew blocked at a
# gate inside a synchronous `no-mistakes axi run`) is precisely the signal that
# could not be proven, so the honest answer is unknown, which surfaces.
#
# The SINGLE owner of that rule. All three sites that can produce a healthy
# verdict consult it - the full run record, the coarse runs-list row, and the
# busy-pane fallback - so they cannot drift apart again, which is exactly how
# a crew that created fm/<id>, moved its own worktree onto another branch and
# died kept reading working at whichever site had not yet been widened.
# The pane site additionally surfaces the whole foreign tier (a worktree provably
# another task's) even when the agent is alive, since it has no attributable run
# at all to tell a busy banner from a gate; the run-step site by then HAS this
# task's own fm/<id> row, so a foreign slot plus a live agent still reports
# working, the deliberately preserved "run still in flight after the slot
# lapsed" case.
wt_ownership_unproven() {
  [ -n "$WT_NOTE" ] || return 1
  ! crew_agent_alive
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback, so the run-step
# block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  if [ "$WT_FOREIGN" = 1 ]; then
    # `axi status` from inside a worktree that is not ours would answer for the
    # other occupant, so it is never consulted here. The repo-wide runs list is
    # keyed on branch rather than path, so this task's own fm/<id> run, if it
    # ever had one, still reports its true state. No row at all falls through
    # to the pane/log path, where this task's own dead endpoint reads unknown
    # rather than the other occupant's health.
    COARSE_STATUS=$(nm_runs_status_for_branch "$EXPECTED_BRANCH")
    if [ -n "$COARSE_STATUS" ]; then
      HAVE_RUN=1
      RUN_SOURCE=coarse
    fi
  else
    RUN_OUT=$(nm_run axi status)
    if [ -n "$RUN_OUT" ]; then
      run_branch=$(strip_quotes "$(nm_field branch)")
      if [ -n "$run_branch" ] && [ "$run_branch" = "$EXPECTED_BRANCH" ]; then
        HAVE_RUN=1
      elif [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && crew_agent_alive; then
        # Off the branch contract: the run matches only the branch the worktree
        # is on, which is not by itself proof the worktree is still ours, so it
        # is attributed only while this task's own agent process is confirmed
        # running.
        HAVE_RUN=1
      else
        # The active-or-most-recent run is for another branch (the CLI is alive
        # and answered; only the attribution missed) - try the coarse fallback.
        # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
        # primary call means the CLI itself did not respond, so retrying it
        # immediately with a second bounded call would just double the wait
        # for no better answer.
        COARSE_STATUS=$(nm_runs_status_for_branch "$EXPECTED_BRANCH")
        if [ -n "$COARSE_STATUS" ]; then
          HAVE_RUN=1
          RUN_SOURCE=coarse
        fi
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)
        # A row still reading `running` is only a row: the runs list is not
        # rewritten when a worker is killed. Across the whole unproven tier -
        # the abrupt-death shape this block exists for, including a crew that
        # created fm/<id>, moved its own worktree onto another branch and then
        # died - that alone is NOT evidence of a live worker, so it reports
        # working only outside that tier (wt_ownership_unproven, the same rule
        # the busy-pane fallback applies). Anything short of that is unknown,
        # which surfaces for supervision instead of being absorbed as healthy.
        if wt_ownership_unproven; then
          RUN_STATE=unknown
          RUN_DETAIL="runs list row still running, but no live agent process is confirmed"
        else
          RUN_STATE=working
          RUN_DETAIL="validating (background run)"
        fi
        ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: captain decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      # The third and last healthy-verdict site, held to the same rule as the
      # runs-list row and the busy pane: a run RECORD reading active is not
      # rewritten when its worker is killed either, so across the unproven tier
      # it is not evidence of a live worker. Only the active statuses above pass
      # through here - a terminal record needs no liveness proof, and the parked
      # branch above must keep surfacing its gate findings.
      if [ "$RUN_STATE" = working ] && wt_ownership_unproven; then
        RUN_STATE=unknown
        RUN_DETAIL="run record still reads active, but no live agent process is confirmed"
      fi
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  # Computed here and nowhere else, so every existing caller pays nothing: only
  # a --progress read of a working run off a full record has a token at all.
  if [ "$PROGRESS" = 1 ] && [ "$RUN_STATE" = working ] && [ "$RUN_SOURCE" = full ]; then
    PROGRESS_LINE=$(nm_progress_record)
  fi

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# signature is not meaningful for them; read their state from the status log only.
#
# A busy pane is NOT reported as working across the unproven tier
# (wt_ownership_unproven) nor on the foreign tier, which together are exactly
# where attribution was deliberately WITHHELD above. The busy
# banner covers a synchronous `no-mistakes axi run` blocked at a gate just as it
# covers real work (see crew_pane_is_busy), so with no attributable run to tell
# the two apart, `working - source: pane` would let crew_absorb_class absorb a
# crew that may be parked and waiting on the captain. The honest verdict there
# is unknown, which surfaces for supervision. This costs nothing on the verified
# tmux harnesses, whose busy pane classifies as alive; it bounds the extra
# surfacing to the off-contract path on the configurations fm_backend_agent_alive
# cannot classify at all (pi execs into a generic node process; zellij, orca and
# cmux always read unknown), which is exactly where the withheld attribution
# would otherwise silently become a healthy verdict.
if [ "$KIND" != secondmate ] && crew_pane_is_busy "$BACKEND_TARGET"; then
  if [ "$WT_FOREIGN" = 1 ] || wt_ownership_unproven; then
    emit unknown pane "harness busy, but no run of this task's own is attributable"
  fi
  emit working pane "harness busy"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
