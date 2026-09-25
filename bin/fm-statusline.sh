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
# fleet. So a base status-line command runs first and its output is printed above
# the fleet line. The base command is deliberately NOT named in tracked material,
# because it is machine-specific.
#
# Resolution order for that base command, highest first:
#   1. FM_STATUSLINE_BASE - explicit env override, and the only thing that
#      reaches a task worktree from the dispatching home (bin/fm-spawn.sh).
#   2. config/statusline-base - local, gitignored, first line only, in the style
#      of config/crew-harness.
#   3. The harness's own user-level status-line command, read live from
#      ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json as .statusLine.command.
#      That is exactly the status line the operator would be seeing if this
#      repo's tracked project settings did not exist, so restoring it is the
#      correct default rather than a guess - and it still names nothing
#      machine-specific in tracked material.
#   4. Nothing: the fleet line alone, silently.
# The literal value "none" in 1 or 2 means "no base line at all" and stops the
# fallback, for an operator who wants the fleet line by itself.
#
# 3 exists because the previous default was 4. A home with no config/ dir - a
# fresh home, a fresh clone, a task worktree - silently blanked the operator's
# own status line, and nothing warned: the only way to discover it was noticing
# the line was gone. A default that requires a hand-written local file to avoid
# breaking something is the defect, so the default now resolves the answer from
# the authoritative copy already on disk.
#
# A resolved base is run the way Claude Code itself runs a statusLine command:
# an existing file is executed directly (the long-standing "one path" contract,
# and the only form that survives a path containing spaces), anything else is a
# command line handed to sh -c. FM_STATUSLINE_COMPOSING is exported across that
# call and short-circuits base resolution in the child, so a user-level setting
# that names this very script terminates instead of recursing.
#
# Contract, because this runs on every status-line render:
#   - Bounded work only: at most four small file reads, one JSON read of the
#     user settings file, at most eight ps parent hops
#     (bin/fm-session-lock-lib.sh), and whatever the operator's own base command
#     costs. No process scans, no globbing over the fleet, no network, no git.
#     The linked-worktree test below is part of that budget, and is why it stats
#     .git and reads the secondmate marker rather than asking git anything.
#     The watcher-pool strip (below) adds one more bounded read of its own: a
#     directory listing capped at bin/fm-arm-pool-lib.sh's pool target (six) plus
#     one kill -0 per live record, never a scan of the whole process table.
#   - It never writes anything under state/, and never creates it. The strip
#     sources bin/fm-wake-lib.sh, whose own `mkdir -p "$STATE"` is a no-op here
#     because this point in the script is only reached once state/ is already
#     known to exist (the earlier `[ -d "$STATE" ]` guard).
#   - It degrades QUIETLY: when ownership cannot be determined it prints no fleet
#     line rather than a wrong or alarming answer. Two cases are exactly that: a
#     missing state dir, and an unmarked linked worktree, which is every crewmate
#     or scout task worktree of this repo including one whose recycled slot left
#     a state dir behind.
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

fm_statusline_trim() {  # <value> -> value without surrounding whitespace
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

# The harness's own user-level status-line command. Quiet by construction: an
# unreadable, absent, or unparseable settings file, a settings file with no
# status line, and a machine with neither jq nor node all yield the empty string
# rather than an error. node is a bootstrap-required tool and jq is not, so jq is
# only ever an optimisation here.
fm_statusline_user_base() {
  local dir file
  dir=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
  file="$dir/settings.json"
  [ -r "$file" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r 'if (.statusLine | type) == "object" and (.statusLine.type == "command")
           then (.statusLine.command // "") else "" end' "$file" 2>/dev/null || true
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      try {
        const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).statusLine;
        if (s && typeof s === "object" && s.type === "command" && typeof s.command === "string") {
          process.stdout.write(s.command);
        }
      } catch {}
    ' "$file" 2>/dev/null || true
  fi
}

BASE=
# A base command this script itself invoked is already composing; resolving a
# base again there would double the operator's line, or recurse forever when the
# user-level setting names this script.
if [ -z "${FM_STATUSLINE_COMPOSING:-}" ]; then
  BASE=$(fm_statusline_trim "${FM_STATUSLINE_BASE:-}")
  if [ -z "$BASE" ] && [ -f "$CONFIG/statusline-base" ]; then
    IFS= read -r BASE 2>/dev/null < "$CONFIG/statusline-base" || true
    BASE=$(fm_statusline_trim "$BASE")
  fi
  # Nothing configured locally: fall back to what the operator's own harness
  # would be running here. This is the case that used to render nothing at all.
  [ -n "$BASE" ] || BASE=$(fm_statusline_trim "$(fm_statusline_user_base)")
  [ "$BASE" != none ] || BASE=
  # A home whose harness-level status line already IS this script: composing it
  # under itself would print the fleet line twice. FM_STATUSLINE_COMPOSING alone
  # stops that recursing, this stops it duplicating.
  case "$BASE" in *fm-statusline.sh*) BASE= ;; esac
fi

if [ -n "$BASE" ]; then
  # Captured rather than streamed so the fleet line below always starts on its
  # own line, whatever the base command does about a trailing newline.
  if [ -f "$BASE" ]; then
    base_out=$(printf '%s' "$PAYLOAD" | FM_STATUSLINE_COMPOSING=1 "$BASE" 2>/dev/null || true)
  else
    base_out=$(printf '%s' "$PAYLOAD" | FM_STATUSLINE_COMPOSING=1 sh -c "$BASE" 2>/dev/null || true)
  fi
  [ -z "$base_out" ] || printf '%s\n' "$base_out"
fi

# No fleet state here (a task worktree, or a home that has never run): say
# nothing about the fleet rather than guess. The base line above still stands.
[ -d "$STATE" ] || exit 0
# A state dir answers "was there ever a fleet here", not "is this a home". A
# recycled task worktree carries a gitignored state/ left behind by an earlier
# occupant of the same slot, so a crew pane rendered a confident verdict about a
# home that does not exist. That verdict could never have been right: a crew pane
# reads its own worktree, because bin/fm-spawn.sh exports FM_HOME only for a
# secondmate, and a crew's ancestry never contains the home's session anyway.
# Decided without forking git, which the contract above forbids. A linked
# worktree is the one shape that is someone ELSE's checkout, and git marks it by
# writing .git as a FILE rather than a directory; a leased secondmate home is a
# linked worktree too, and its marker (bin/fm-primary-scope-lib.sh) is the only
# thing that tells the two apart. So the test silences exactly that case and
# nothing else, which is the same quiet degrading as a missing state dir.
# It is deliberately a test for the shape that must NOT speak rather than for the
# shape that may. Requiring a .git directory would have been the same answer for
# every real home - a checkout, a plain-clone secondmate, a leased secondmate
# worktree, a task worktree - while also silencing any directory that is no git
# checkout at all, which is not a home this ever had to decide about. Narrowing
# to the one shape that was actually wrong keeps every case that speaks today
# speaking.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
[ ! -f "$FM_HOME/.git" ] || fm_root_is_secondmate_home "$FM_HOME" || exit 0
# Without ps the ancestry walk cannot run, and every answer would be wrong in
# the alarming direction.
command -v ps >/dev/null 2>&1 || exit 0

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

home_label=${FM_HOME%/}
home_label=${home_label##*/}
[ -n "$home_label" ] || home_label=firstmate

# --- watcher pool strip ------------------------------------------------------
# Right-aligned on the fleet line: one distinctly-marked cell for the LIVE
# watcher, one filled box per waiting dormant arm, hollow boxes for empty slots
# up to bin/fm-arm-pool-lib.sh's pool target. Captain's request, screenshot
# 2026-09-17 ("add some blue boxes right aligned here ... where it gives the
# number of watchers"), launch confirmed 2026-09-24.
#
# Colour choice: bin/fm-flow-tui.mjs's own palette comment names sgr("94") as
# the slot it calls `blue` in code, but its own later ruling (docs/flow-tui.md
# "Pink, not red") records that this exact slot renders PINK in the captain's
# terminal theme, not blue - so reusing it here would silently ship pink boxes
# under a "blue boxes" request. Nothing in this repo documents which SGR code
# renders blue for him. SGR 34 (plain, non-bright blue) is used instead: themes
# that retint the bright ANSI slots for accent colours - which is exactly what
# happened to slot 94 - most commonly leave the plain-intensity slots at their
# ordinary hue, so 34 is the best available guess, not a verified one.
FM_STATUSLINE_BLUE=$(printf '\033[34m')
FM_STATUSLINE_BLUE_BOLD=$(printf '\033[1;34m')
FM_STATUSLINE_RESET=$(printf '\033[0m')
fm_statusline_tab=$(printf '\t')

fm_statusline_pid_alive() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null
}

# Claude Code draws the status line NARROWER than the terminal: its footer Box
# carries paddingX on both sides, so a line built to exactly COLUMNS is always
# too wide and Ink's wrap:"truncate" eats the last cells of the strip, which is
# the `...[#][#][.][…` the captain reported at every window size. The margin is
# constant, so it is subtracted before right-aligning. MEASURED, not read off
# the binary (docs/configuration.md "Status-line composition" records the
# capture): 4 columns on Claude Code 2.1.282, at both 100 and 137 columns.
# FM_STATUSLINE_RIGHT_MARGIN overrides it for a harness that draws differently;
# a non-numeric value falls back to the default rather than breaking the row.
FM_STATUSLINE_RIGHT_MARGIN_DEFAULT=4
case "${FM_STATUSLINE_RIGHT_MARGIN:-}" in
  ''|*[!0-9]*) FM_STATUSLINE_RIGHT_MARGIN=$FM_STATUSLINE_RIGHT_MARGIN_DEFAULT ;;
esac

# Terminal width: Claude Code sets COLUMNS in the environment before running a
# statusLine command (its JSON payload carries no width field at all), so that
# is the primary source; `tput cols` covers a hand run from an interactive
# shell. Echoes nothing and fails when neither is available.
fm_statusline_term_width() {
  case "${COLUMNS:-}" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$COLUMNS"; return 0 ;;
  esac
  local cols
  command -v tput >/dev/null 2>&1 || return 1
  cols=$(tput cols 2>/dev/null) || return 1
  case "$cols" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$cols"; return 0 ;;
  esac
}

# Whether the pool has ever been joined here is decided ONCE, at the top level,
# never inside fm_statusline_watcher_strip: that function's output is always
# captured with `$(...)`, which runs it in a SUBSHELL, so a global it assigned
# there (the plain-column width used for right-alignment below) would vanish
# the moment the subshell exits. Sourcing the two pool libraries here, in the
# real shell, is what makes fm_arm_pool_live_records and FM_ARM_POOL_TARGET
# available to the function without that trap.
FM_STATUSLINE_STRIP_WIDTH=3
FM_STATUSLINE_POOL_DIR="$STATE/.arm-pool"
if [ -d "$FM_STATUSLINE_POOL_DIR" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-arm-pool-lib.sh
  . "$SCRIPT_DIR/fm-arm-pool-lib.sh"
  FM_STATUSLINE_STRIP_WIDTH=$((FM_ARM_POOL_TARGET * 3))
fi

fm_statusline_watcher_strip() {
  local watch_pid live live_slot taken n out=
  watch_pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  live=0
  fm_statusline_pid_alive "$watch_pid" && live=1

  if [ ! -d "$FM_STATUSLINE_POOL_DIR" ]; then
    # Zero-cost path: this home has never joined the pool (old-style single
    # watcher), so it costs one stat and renders as one cell instead of six.
    if [ "$live" = 1 ]; then
      printf '%s[@]%s' "$FM_STATUSLINE_BLUE_BOLD" "$FM_STATUSLINE_RESET"
    else
      printf '[.]'
    fi
    return 0
  fi

  # Consumes fm_arm_pool_live_records/fm_arm_pool_taken_slots rather than
  # re-parsing the pool directory or that library's internal record format by
  # hand, per bin/fm-arm-pool-lib.sh's own header.
  live_slot=
  if [ "$live" = 1 ]; then
    live_slot=$(fm_arm_pool_live_records | while IFS="$fm_statusline_tab" read -r pid slot; do
      [ "$pid" = "$watch_pid" ] || continue
      printf '%s' "$slot"
      break
    done)
  fi
  taken=$(fm_arm_pool_taken_slots)

  n=1
  while [ "$n" -le "$FM_ARM_POOL_TARGET" ]; do
    if [ -n "$live_slot" ] && [ "$n" = "$live_slot" ]; then
      out="$out${FM_STATUSLINE_BLUE_BOLD}[@]${FM_STATUSLINE_RESET}"
    elif printf '%s\n' "$taken" | grep -qx "$n"; then
      out="$out${FM_STATUSLINE_BLUE}[#]${FM_STATUSLINE_RESET}"
    else
      out="${out}[.]"
    fi
    n=$((n + 1))
  done
  printf '%s' "$out"
}

# Right-aligns the strip on <text>, FM_STATUSLINE_RIGHT_MARGIN columns short of
# the terminal width, when that width is known and the row fits; never wraps the
# row. Width known but too narrow: drop the strip and
# keep the text. Width unknown (no COLUMNS, no tput - piped, no tty): the
# enumerated fallback still shows the strip, placed right after the text with
# two spaces, since this script has no way to tell whether that would wrap and
# dropping it here would leave the feature invisible in most non-interactive
# runs, including a hand test of this very script.
fm_statusline_compose_row() {  # <text> <strip>
  local text=$1 strip=$2 width pad
  if [ -z "$strip" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  if width=$(fm_statusline_term_width); then
    pad=$((width - FM_STATUSLINE_RIGHT_MARGIN - ${#text} - FM_STATUSLINE_STRIP_WIDTH))
    if [ "$pad" -ge 1 ]; then
      printf '%s%*s%s\n' "$text" "$pad" '' "$strip"
    else
      printf '%s\n' "$text"
    fi
    return 0
  fi
  printf '%s  %s\n' "$text" "$strip"
}

case "$(fm_session_lock_ownership "$STATE")" in
  owned)
    fleet_text=$(printf '%s - in control of fleet' "$home_label")
    ;;
  other)
    fleet_text=$(printf '%s - not in control of fleet (another session holds it; end that session or run bin/fm-session-start.sh once it is gone)' "$home_label")
    ;;
  *)
    fleet_text=$(printf '%s - not in control of fleet (no session holds it; run bin/fm-session-start.sh)' "$home_label")
    ;;
esac

fm_statusline_compose_row "$fleet_text" "$(fm_statusline_watcher_strip)"
exit 0
