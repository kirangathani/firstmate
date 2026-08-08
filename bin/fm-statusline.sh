#!/usr/bin/env bash
# Harness-neutral status-line producer: one short line saying whether THIS
# session is in control of the current home's fleet.
#
# Fleet control is defined by the session lock (state/.lock). Showing it
# persistently is cheaper and calmer than a session re-checking and complaining
# every turn, and it makes the two-session case obvious at a glance instead of
# only surfacing when something refuses.
#
# It COMPOSES rather than replaces. .claude/settings.json is tracked and shared,
# so wiring this script there would otherwise override whatever status line the
# operator already runs globally, in every worktree of this repo - and go fully
# blank in crewmate and scout worktrees, which carry the tracked script but no
# fleet. So an optional base status-line command runs first and its output is
# printed above the fleet line. The base command is deliberately NOT named in
# tracked material, because it is machine-specific: it comes from the local,
# gitignored config/statusline-base (one path, in the style of config/crew-harness)
# or from FM_STATUSLINE_BASE. Absent, empty, or non-executable simply means no
# base command, silently. Composition applies even where the fleet line is
# absent, so a task worktree shows the operator's own line rather than nothing.
#
# Contract, because this runs on every status-line render:
#   - Bounded work only: two small file reads plus at most eight ps parent hops
#     (bin/fm-session-lock-lib.sh), and whatever the operator's own base command
#     costs. No process scans, no globbing over the fleet, no network, no git.
#   - It never writes anything under state/, and never creates it.
#   - It degrades QUIETLY: when ownership cannot be determined it prints no fleet
#     line rather than a wrong or alarming answer. A missing state dir (every
#     crewmate or scout task worktree of this repo) is exactly that case.
#   - Always exits 0.
#
# Wiring: Claude Code reads it through the statusLine setting in
# .claude/settings.json. No other harness is wired to it yet; the script itself
# is harness-neutral, so an adapter only has to run it and print its stdout.
set -u

# Harnesses hand the status line a JSON payload on stdin. Capture it ONCE without
# a fork so the caller never sees a broken pipe, and forward the same bytes to
# the base command, which expects the same payload. Skip the read on a terminal
# so a hand-run of this script cannot hang waiting for an EOF nobody will send.
PAYLOAD=
[ -t 0 ] || IFS= read -r -d '' PAYLOAD 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

BASE="${FM_STATUSLINE_BASE:-}"
if [ -z "$BASE" ] && [ -f "$CONFIG/statusline-base" ]; then
  IFS= read -r BASE 2>/dev/null < "$CONFIG/statusline-base" || true
fi
BASE=${BASE#"${BASE%%[![:space:]]*}"}
BASE=${BASE%"${BASE##*[![:space:]]}"}
if [ -n "$BASE" ] && [ -x "$BASE" ]; then
  # Captured rather than streamed so the fleet line below always starts on its
  # own line, whatever the base command does about a trailing newline.
  base_out=$(printf '%s' "$PAYLOAD" | "$BASE" 2>/dev/null || true)
  [ -z "$base_out" ] || printf '%s\n' "$base_out"
fi

# No fleet state here (a task worktree, or a home that has never run): say
# nothing about the fleet rather than guess. The base line above still stands.
[ -d "$STATE" ] || exit 0
# Without ps the ancestry walk cannot run, and every answer would be wrong in
# the alarming direction.
command -v ps >/dev/null 2>&1 || exit 0

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

home_label=${FM_HOME%/}
home_label=${home_label##*/}
[ -n "$home_label" ] || home_label=firstmate

case "$(fm_session_lock_ownership "$STATE")" in
  owned)
    printf '%s - in control of fleet\n' "$home_label"
    ;;
  other)
    printf '%s - not in control of fleet (another session holds it; end that session or run bin/fm-session-start.sh once it is gone)\n' "$home_label"
    ;;
  *)
    printf '%s - not in control of fleet (no session holds it; run bin/fm-session-start.sh)\n' "$home_label"
    ;;
esac
exit 0
