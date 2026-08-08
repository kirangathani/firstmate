#!/usr/bin/env bash
# Harness-neutral status-line producer: one short line saying whether THIS
# session is in control of the current home's fleet.
#
# Fleet control is defined by the session lock (state/.lock). Showing it
# persistently is cheaper and calmer than a session re-checking and complaining
# every turn, and it makes the two-session case obvious at a glance instead of
# only surfacing when something refuses.
#
# Contract, because this runs on every status-line render:
#   - Bounded work only: one small file read plus at most eight ps parent hops
#     (bin/fm-session-lock-lib.sh). No process scans, no globbing over the fleet,
#     no network, no git.
#   - It never writes anything under state/, and never creates it.
#   - It degrades QUIETLY: when ownership cannot be determined it prints nothing
#     rather than a wrong or alarming answer. A missing state dir (every crewmate
#     or scout task worktree of this repo, which carries this tracked script but
#     no fleet) is exactly that case.
#   - Always exits 0.
#
# Wiring: Claude Code reads it through the statusLine setting in
# .claude/settings.json. No other harness is wired to it yet; the script itself
# is harness-neutral, so an adapter only has to run it and print its stdout.
set -u

# Harnesses hand the status line a JSON payload on stdin. Drain it without a
# fork so the caller never sees a broken pipe; its contents are not needed. Skip
# the drain on a terminal so a hand-run of this script cannot hang waiting for
# an EOF nobody will send.
[ -t 0 ] || IFS= read -r -d '' _payload 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# No fleet state here (a task worktree, or a home that has never run): say
# nothing rather than guess.
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
    printf '%s - not in control of fleet (another session holds it)\n' "$home_label"
    ;;
  *)
    printf '%s - not in control of fleet (no session holds it; run bin/fm-session-start.sh)\n' "$home_label"
    ;;
esac
exit 0
