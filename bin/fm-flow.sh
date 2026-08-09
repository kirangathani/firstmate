#!/usr/bin/env bash
# fm-flow.sh - the captain-facing entry point for the fleet pipeline view.
#
# The view is deliberately two programs (docs/flow-tui.md): fm-flow-snapshot.sh
# owns every outside read, fm-flow-tui.mjs owns pixels and keys and reads a
# snapshot on stdin. That seam is what makes byte-exact frame tests possible,
# and nothing here weakens it.
#
# What the seam does NOT give you on its own is a SECOND snapshot. stdin ends
# as soon as the first document has been read, so a hand-rolled
# `fm-flow-snapshot.sh --json | fm-flow-tui.mjs --watch` can only ever redraw
# the frame it started with. This script is the piece that closes that: it
# builds the collector command ONCE, feeds its output in as the first frame,
# and hands the very same command to the viewer as --refresh-cmd, so the live
# view can never end up reading a different home, a different task, or a
# different --no-ci posture than the frame it started from.
#
# Usage:
#   fm-flow.sh [--no-ci] [--task <id>] [--refresh-ms <n>]
#   fm-flow.sh --open <task-id>
#   fm-flow.sh --detail <task-id>
#
#   --no-ci           pass through to fm-flow-snapshot.sh: skip every GitHub
#                     read, so the whole view is local and cheap
#   --task <id>       pass through to fm-flow-snapshot.sh: one task only
#   --refresh-ms <n>  collector cadence in the live view, milliseconds
#                     (default 10000). Refreshes never overlap, so a
#                     collector slower than this sets the real cadence.
#   --open <task-id>  put THIS terminal on that worker's window. This is what
#                     the viewer runs when the captain presses enter; it is a
#                     normal command and can be run on its own.
#   --detail <task-id>  show that one task's pipeline in detail, live, by
#                     running bin/fm-nm-flow.sh --watch on this terminal. This
#                     is what the viewer runs when the captain presses d. Ctrl-C
#                     ends it and returns to whatever launched it. Strictly
#                     read-only, and it moves no window.
#
# Environment knobs:
#   FM_FLOW_OPEN_DRY_RUN   --open only. Print the action it would take and the
#                          argv it would run, change nothing, exit 0. The three
#                          actions are `switch` (this terminal is already a tmux
#                          client), `attach` (it is not, and it is a terminal),
#                          and `refuse` (it is not a terminal at all).
#   FM_FLOW_DETAIL_DRY_RUN --detail only. Print the argv it would run, change
#                          nothing, exit 0.
#
# Read-only with respect to fleet state: it collects, it draws, --open moves the
# captain's own terminal view, and --detail draws one task. It takes no session
# lock, drains no wakes, and writes nothing under state/.
#
# Exit codes: 0 clean exit, 1 the snapshot, the open, or the detail view failed,
# 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# Exported so the --open command the viewer runs on enter resolves the SAME
# home this view was collected from, rather than re-deriving one.
export FM_HOME

usage() {
  sed -n '2,51p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SNAP_ARGS=()
REFRESH_MS=10000
OPEN_ID=
DETAIL_ID=

while [ $# -gt 0 ]; do
  case "$1" in
    --no-ci) SNAP_ARGS+=(--no-ci) ;;
    --task) shift; [ $# -gt 0 ] || { echo "error: --task needs an id" >&2; exit 2; }; SNAP_ARGS+=(--task "$1") ;;
    --refresh-ms) shift; [ $# -gt 0 ] || { echo "error: --refresh-ms needs a number" >&2; exit 2; }; REFRESH_MS=$1 ;;
    --open) shift; [ $# -gt 0 ] || { echo "error: --open needs a task id" >&2; exit 2; }; OPEN_ID=$1 ;;
    --detail) shift; [ $# -gt 0 ] || { echo "error: --detail needs a task id" >&2; exit 2; }; DETAIL_ID=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# The two one-shot actions do different things to this terminal, so a command
# line asking for both is refused rather than given a silent precedence.
if [ -n "$OPEN_ID" ] && [ -n "$DETAIL_ID" ]; then
  echo "error: pass --open or --detail, not both: one hands this terminal to the worker, the other draws its pipeline here" >&2
  exit 2
fi

# --- --detail: one task's pipeline, in full, on this terminal ----------------
#
# The row already states a CI verdict per agent, so the obvious next move from
# it is that agent's own pipeline - and until this existed the captain had to
# know bin/fm-nm-flow.sh by name and type it with the right task id. This is the
# path from the view to that command, and it is deliberately the SAME command
# rather than a second renderer: that script is already the read-only detailed
# view of one task's delivery flow, and a copy of it here would drift.
#
# Ctrl-C is the way back, so this traps it and reports the return rather than
# dying with a signal - the viewer shows the first stderr line as its footer
# flash, and "interrupted" is not what happened from the captain's side.
if [ -n "$DETAIL_ID" ]; then
  meta="$STATE_DIR/$DETAIL_ID.meta"
  [ -f "$meta" ] || { echo "error: no local record for $DETAIL_ID" >&2; exit 1; }
  NM="$SCRIPT_DIR/fm-nm-flow.sh"
  [ -x "$NM" ] || { echo "error: $NM is missing" >&2; exit 1; }

  if [ -n "${FM_FLOW_DETAIL_DRY_RUN:-}" ]; then
    printf 'action=detail target=%s cmd=%s\n' "$DETAIL_ID" "$NM"
    exit 0
  fi

  # One function, named by both the trap and the ordinary return, so the two
  # paths cannot say different things. It is a function rather than an inline
  # trap string on purpose: the trap body is re-parsed by the shell when the
  # signal arrives, so an apostrophe inside it has to survive two rounds of
  # quoting. The first cut of this did not, and the captain's own return from
  # the detail view flashed `unexpected EOF while looking for matching '`
  # instead of the outcome. Observed 2026-08-09 in a live terminal.
  detail_returned() {
    echo "back from the pipeline detail for $DETAIL_ID" >&2
  }
  trap 'detail_returned; exit 0' INT

  detail_rc=0
  "$NM" "$DETAIL_ID" --watch || detail_rc=$?
  # 130 is the shell's own encoding of "interrupted", which is how the captain
  # is expected to leave; every other non-zero exit is a real failure and must
  # not be reported as a clean return.
  if [ "$detail_rc" -ne 0 ] && [ "$detail_rc" -ne 130 ]; then
    echo "error: the pipeline detail for $DETAIL_ID stopped with exit $detail_rc" >&2
    exit 1
  fi
  detail_returned
  exit 0
fi

# --- --open: put this terminal on one worker's window ------------------------
#
# Deliberately narrow. Focusing a window is a per-backend verb that firstmate's
# backend interface does not carry yet, and inventing one here for five
# runtimes off the back of a view change would be guessing. tmux is the
# verified reference backend and its commands are known good, so tmux works and
# every other backend is told plainly that it does not, rather than being sent a
# command nobody has run.
#
# WHOSE terminal moves is the whole of it, and the shipped version got it
# wrong. `select-window` changes the target SESSION's current window; it does
# nothing to the terminal the command was typed in. Run from a terminal that is
# not a client of that session - which is how the captain ran it - it exits 0
# having moved a view nobody was looking at, and the viewer duly reported
# `opened <id>`. Reproduced 2026-08-09: `--open` from a non-tmux shell returned
# 0 and the invoking terminal was unchanged.
#
# So the action depends on what this terminal already is:
#
#   switch  $TMUX is set, so this terminal IS a tmux client. select-window then
#           switch-client moves this client onto the worker's window; the view
#           keeps running in its own window, which is where the captain comes
#           back to. Verified by asking the client where it ended up.
#   attach  $TMUX is unset and stdin/stdout are a terminal. The only way to put
#           THIS terminal on a tmux window is to attach it, so that is what
#           happens; detaching returns the captain to whatever was here before,
#           which is the viewer when the viewer launched it. attach blocks for
#           as long as the captain stays, so this command does too.
#   refuse  not a terminal at all - a script, a pipe, a cron job. There is
#           nothing to put anywhere, and the one thing this must never do is
#           move a window somewhere invisible and call it success.
#
# The outcome line goes to STDERR because in the attach case stdout belongs to
# tmux, and because the viewer flashes exactly what this command says it did.
if [ -n "$OPEN_ID" ]; then
  meta="$STATE_DIR/$OPEN_ID.meta"
  [ -f "$meta" ] || { echo "error: no local record for $OPEN_ID" >&2; exit 1; }
  # shellcheck source=bin/fm-backend.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-backend.sh"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { echo "error: no window recorded for $OPEN_ID" >&2; exit 1; }

  # A terminal is required for BOTH actions, not just the attach. `switch-client`
  # with no client of its own to name moves whatever client happens to be
  # attached to the invoking pane's session - so a script or an agent running
  # inside a tmux pane, with no terminal at all, would yank the captain's own
  # terminal onto some other window. Observed 2026-08-09 while reproducing this
  # very defect. No terminal, nothing to move, no action.
  if [ ! -t 1 ]; then
    open_action=refuse
  elif [ -n "${TMUX:-}" ]; then
    open_action=switch
  elif [ -t 0 ]; then
    open_action=attach
  else
    open_action=refuse
  fi

  case "$backend" in
    tmux)
      command -v tmux >/dev/null 2>&1 || { echo "error: tmux is not installed" >&2; exit 1; }

      if [ -n "${FM_FLOW_OPEN_DRY_RUN:-}" ]; then
        printf 'action=%s target=%s\n' "$open_action" "$target"
        exit 0
      fi

      # The window has to exist before anything is claimed about it, and the
      # backend's own probe is what decides that for the rest of the fleet.
      expected_label=$(fm_backend_expected_label_of_meta "$meta" "$OPEN_ID")
      fm_backend_target_exists tmux "$target" "$expected_label" >/dev/null 2>&1 \
        || { echo "error: no window $target; that worker is gone" >&2; exit 1; }

      case "$open_action" in
        switch)
          client=$(tmux display-message -p '#{client_tty}' 2>/dev/null)
          [ -n "$client" ] || {
            echo "error: this tmux session has no attached terminal to switch" >&2
            exit 1
          }
          tmux select-window -t "$target" >/dev/null 2>&1 \
            || { echo "error: could not select $target" >&2; exit 1; }
          tmux switch-client -c "$client" -t "${target%%:*}" >/dev/null 2>&1 \
            || { echo "error: could not switch this terminal to ${target%%:*}" >&2; exit 1; }
          # Proof, not assumption: ask the client itself where it now is. This
          # is the difference between reporting an open and performing one.
          now=$(tmux display-message -p -c "$client" '#{session_name}:#{window_name}' 2>/dev/null)
          [ "$now" = "$target" ] || {
            echo "error: asked for $target but this terminal is showing ${now:-nothing}" >&2
            exit 1
          }
          echo "switched to $target" >&2
          exit 0
          ;;
        attach)
          tmux select-window -t "$target" >/dev/null 2>&1 \
            || { echo "error: could not select $target" >&2; exit 1; }
          if tmux attach-session -t "${target%%:*}"; then
            echo "back from $target" >&2
            exit 0
          fi
          echo "error: could not attach this terminal to ${target%%:*}" >&2
          exit 1
          ;;
        *)
          echo "error: $target is live, but this is not a terminal to show it in" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      echo "error: focusing a $backend window is not implemented; that worker is at $target" >&2
      exit 1
      ;;
  esac
fi

# --- the view ---------------------------------------------------------------

TUI="$SCRIPT_DIR/fm-flow-tui.mjs"
SNAP="$SCRIPT_DIR/fm-flow-snapshot.sh"
[ -x "$SNAP" ] || { echo "error: $SNAP is missing" >&2; exit 1; }
[ -f "$TUI" ] || { echo "error: $TUI is missing" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "error: node is required for the fleet pipeline view" >&2; exit 1; }

COLLECT=("$SNAP" --json "${SNAP_ARGS[@]+"${SNAP_ARGS[@]}"}")

# One quoted rendering of the same argv the first frame came from. printf %q is
# what keeps a home path with a space from silently re-collecting the wrong
# thing when the viewer hands the string to /bin/sh.
refresh_cmd=$(printf '%q ' "${COLLECT[@]}")

first=$(mktemp "${TMPDIR:-/tmp}/fm-flow.XXXXXX") || exit 1
trap 'rm -f "$first"' EXIT

if ! "${COLLECT[@]}" >"$first"; then
  echo "error: the fleet snapshot failed; nothing to draw" >&2
  exit 1
fi

# What enter does, and how the captain gets back, depends on whether this
# terminal is already a tmux client - the same fork --open takes above. The
# viewer cannot work that out, and must not guess: it is handed the sentence
# that is true for THIS terminal, and prints it against the selected agent.
if [ -n "${TMUX:-}" ]; then
  here=$(tmux display-message -p '#{session_name}:#{window_name}' 2>/dev/null)
  OPEN_HINT="enter: switch to this worker's window (this view stays in ${here:-its own window})"
else
  OPEN_HINT="enter: attach to this worker's window (detach, prefix then d, to come back here)"
fi

# Not exec: the temp file holding the first frame is removed by the EXIT trap,
# and exec would replace this shell before the trap could ever run.
"$TUI" --watch \
  --refresh-cmd "$refresh_cmd" \
  --refresh-ms "$REFRESH_MS" \
  --open-cmd "$(printf '%q' "$SCRIPT_DIR/fm-flow.sh") --open \"\$FM_FLOW_ID\"" \
  --open-hint "$OPEN_HINT" \
  --detail-cmd "$(printf '%q' "$SCRIPT_DIR/fm-flow.sh") --detail \"\$FM_FLOW_ID\"" \
  --detail-hint "d this agent's pipeline (ctrl-c back)" \
  <"$first"
exit $?
