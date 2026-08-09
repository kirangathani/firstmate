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
#   - Bounded work only: at most three small file reads, one JSON read of the
#     user settings file, at most eight ps parent hops
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
