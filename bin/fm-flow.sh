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
#
#   --no-ci           pass through to fm-flow-snapshot.sh: skip every GitHub
#                     read, so the whole view is local and cheap
#   --task <id>       pass through to fm-flow-snapshot.sh: one task only
#   --refresh-ms <n>  collector cadence in the live view, milliseconds
#                     (default 10000). Refreshes never overlap, so a
#                     collector slower than this sets the real cadence.
#   --open <task-id>  focus that worker's window and exit. This is what the
#                     viewer runs when the captain presses enter; it is a
#                     normal command and can be run on its own.
#
# Read-only with respect to fleet state: it collects, it draws, and --open
# moves the captain's own terminal view. It takes no session lock, drains no
# wakes, and writes nothing under state/.
#
# Exit codes: 0 clean exit, 1 the snapshot or the open failed, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# Exported so the --open command the viewer runs on enter resolves the SAME
# home this view was collected from, rather than re-deriving one.
export FM_HOME

usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SNAP_ARGS=()
REFRESH_MS=10000
OPEN_ID=

while [ $# -gt 0 ]; do
  case "$1" in
    --no-ci) SNAP_ARGS+=(--no-ci) ;;
    --task) shift; [ $# -gt 0 ] || { echo "error: --task needs an id" >&2; exit 2; }; SNAP_ARGS+=(--task "$1") ;;
    --refresh-ms) shift; [ $# -gt 0 ] || { echo "error: --refresh-ms needs a number" >&2; exit 2; }; REFRESH_MS=$1 ;;
    --open) shift; [ $# -gt 0 ] || { echo "error: --open needs a task id" >&2; exit 2; }; OPEN_ID=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- --open: focus one worker's window --------------------------------------
#
# Deliberately narrow. Focusing a window is a per-backend verb that firstmate's
# backend interface does not carry yet, and inventing one here for five
# runtimes off the back of a view change would be guessing. tmux is the
# verified reference backend and its two commands are known good, so tmux
# works and every other backend is told plainly that it does not, rather than
# being sent a command nobody has run.
if [ -n "$OPEN_ID" ]; then
  meta="$STATE_DIR/$OPEN_ID.meta"
  [ -f "$meta" ] || { echo "error: no local record for $OPEN_ID" >&2; exit 1; }
  # shellcheck source=bin/fm-backend.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-backend.sh"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { echo "error: no window recorded for $OPEN_ID" >&2; exit 1; }
  case "$backend" in
    tmux)
      command -v tmux >/dev/null 2>&1 || { echo "error: tmux is not installed" >&2; exit 1; }
      tmux select-window -t "$target" >/dev/null 2>&1 \
        || { echo "error: no window $target" >&2; exit 1; }
      # Only matters when the captain is attached to a different session; a
      # no-op otherwise, and never a reason to report failure.
      tmux switch-client -t "${target%%:*}" >/dev/null 2>&1 || true
      exit 0
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

# Not exec: the temp file holding the first frame is removed by the EXIT trap,
# and exec would replace this shell before the trap could ever run.
"$TUI" --watch \
  --refresh-cmd "$refresh_cmd" \
  --refresh-ms "$REFRESH_MS" \
  --open-cmd "$(printf '%q' "$SCRIPT_DIR/fm-flow.sh") --open \"\$FM_FLOW_ID\"" \
  <"$first"
exit $?
