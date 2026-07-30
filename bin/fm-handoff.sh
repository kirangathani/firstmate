#!/usr/bin/env bash
# fm-handoff.sh - own the handoff document's path, its unread marker, and the
# pickup announcement a post-/clear session sees.
#
# WHY THIS EXISTS. A firstmate session that is reset - by `/clear`, by a
# deliberate restart, or by the machine rebooting under it - loses every fact
# that lived only in its conversation. Fleet state reconstructs itself from
# state/, data/backlog.md and the backends; the REASONING does not. The
# `/handoff` skill (.agents/skills/handoff/SKILL.md) owns what goes in the
# document. This script owns the plumbing: where it lands, how the next session
# is told about it, and how it stops announcing once read.
#
# THE PICKUP MECHANISM, and why it is a SessionStart hook.
# `/clear` is a Claude Code CLI built-in handled by the harness UI, not a tool
# the model can call, so no skill can execute it and no skill runs after it. The
# only thing that runs after `/clear` is a hook. Claude Code re-fires
# SessionStart on `/clear` with a `source` discriminator, so `pickup` is wired
# into .claude/settings.json as a SessionStart hook and emits the pointer as
# hookSpecificOutput.additionalContext.
# Verified empirically on Claude Code 2.1.220; the evidence (payloads and the
# fresh model echoing the injected marker) is recorded in docs/handoff.md.
# The hook is registered with NO matcher on purpose, so the pointer also
# survives the reset shapes `/clear` does not cover: a fresh `startup` after a
# reboot or a crash is exactly the case a handoff is written for, and an unread
# handoff must not be silently skipped just because the session died the hard
# way instead of being cleared deliberately.
#
# THE UNREAD MARKER, and why the READER clears it.
# `arm` writes state/.handoff-unread holding one absolute path. `pickup`
# announces while that marker exists; `consume` removes it. Clearing is
# deliberately NOT done by `pickup` itself: a session that is announced to and
# then dies before reading anything would otherwise lose the handoff outright,
# which is the one failure this whole path exists to prevent. So the marker
# means "not yet read by anyone", the announcement repeats until a session
# actually reads the document and calls `consume`, and a handoff that HAS been
# consumed never announces again. A marker pointing at a file that no longer
# exists is self-healing: `pickup` clears it and stays silent.
#
# SCOPING. There is no harness-side scoping and none is needed. The tracked
# .claude/settings.json is checked out into every worktree of this repo,
# including crewmate/scout task worktrees, but state/ is gitignored and absent
# there, so `pickup` exits silently. A real firstmate home - the main home or a
# secondmate's own home - has state/, and each announces only its own handoff.
#
# Usage:
#   fm-handoff.sh path [--slug <slug>]   print the path for a NEW handoff doc
#   fm-handoff.sh arm <file>             mark that handoff unread for the next session
#   fm-handoff.sh pickup                 SessionStart hook: announce an unread handoff
#   fm-handoff.sh consume [<file>]       mark the handoff read (no more announcements)
#   fm-handoff.sh status                 report whether a handoff is pending
#
# Exit codes: `pickup` always exits 0 - it is a hook, never a gate, and must
# never break a session start. The interactive subcommands exit non-zero on a
# real usage or validation error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MARKER="$STATE/.handoff-unread"

die() {
  printf 'fm-handoff: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Absolute-path a possibly-relative argument without requiring the file to
# exist yet (realpath -m is not portable enough to rely on here).
abspath() {
  local p=$1 dir base
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  dir=$(dirname "$p")
  base=$(basename "$p")
  [ -d "$dir" ] || die "no such directory: $dir"
  printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
}

# --- path -------------------------------------------------------------------
#
# Names follow the precedent already on disk: HANDOFF-<date>.md for the day's
# first, then -session2, -session3 for later ones the same day. Never returns a
# path that already exists, so `/handoff` cannot silently overwrite an earlier
# handoff that a successor has not read yet.
cmd_path() {
  local slug='' date_stamp n candidate
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) [ $# -ge 2 ] || die "--slug needs a value"; slug=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$slug" in
    *[!A-Za-z0-9._-]*) die "slug may only contain letters, digits, dot, underscore and dash" ;;
  esac

  mkdir -p "$DATA" || die "cannot create $DATA"
  date_stamp=$(date +%Y-%m-%d)
  candidate="$DATA/HANDOFF-$date_stamp${slug:+-$slug}.md"
  n=2
  while [ -e "$candidate" ]; do
    candidate="$DATA/HANDOFF-$date_stamp${slug:+-$slug}-session$n.md"
    n=$((n + 1))
    [ "$n" -le 100 ] || die "too many handoffs for one day; name this one with --slug"
  done
  printf '%s\n' "$candidate"
}

# --- arm --------------------------------------------------------------------
#
# Refuses anything that is not a real, non-empty handoff document inside this
# home's data/ dir. data/ is gitignored, so this is also what keeps a handoff
# out of tracked repo material and out of any project clone.
cmd_arm() {
  [ $# -eq 1 ] || die "arm needs exactly one handoff file"
  local file
  file=$(abspath "$1")

  [ -f "$file" ] || die "not a file: $file"
  [ -s "$file" ] || die "handoff is empty: $file"
  case "$file" in
    "$DATA"/*) ;;
    *) die "handoff must live under $DATA (it is firstmate-private, gitignored state)" ;;
  esac

  mkdir -p "$STATE" || die "cannot create $STATE"
  printf '%s\n' "$file" > "$MARKER" || die "cannot write $MARKER"
  printf 'armed: %s\n' "$file"
  printf 'The next session start in this home will be pointed at it.\n'
}

# --- pickup -----------------------------------------------------------------
#
# The SessionStart hook body. Silent unless a handoff is genuinely unread.
cmd_pickup() {
  [ -d "$STATE" ] || exit 0
  [ -f "$MARKER" ] || exit 0

  # `read` reports failure on a final line with no trailing newline even though
  # it has already set the variable, so take the value and judge that, not the
  # exit status: a hand-edited marker must still announce.
  local file=''
  IFS= read -r file < "$MARKER" 2>/dev/null || true
  [ -n "$file" ] || { rm -f "$MARKER"; exit 0; }

  # Self-heal: a marker pointing at a deleted handoff is stale, not an alarm.
  if [ ! -f "$file" ]; then
    rm -f "$MARKER"
    exit 0
  fi

  local text
  text=$(printf '%s' "\
UNREAD HANDOFF - READ THIS FILE BEFORE ANYTHING ELSE:
  $file

A previous session in this firstmate home wrote that handoff and no session has
read it yet. It carries the reasoning, decisions and in-flight context that
state files cannot reconstruct.

Do these in order, before running bin/fm-session-start.sh and before any other work:
  1. Read $file in full.
  2. Run: $SCRIPT_DIR/fm-handoff.sh consume
     (this stops it announcing itself at every future session start)
Then continue with the normal session start.")

  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ctx "$text" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null \
      || printf '%s\n' "$text"
  else
    # No jq: SessionStart also accepts plain stdout as added context, so the
    # pointer still lands. Degrade, never go silent.
    printf '%s\n' "$text"
  fi
  exit 0
}

# --- consume ----------------------------------------------------------------
#
# Idempotent by design: a session that reads the handoff and consumes it, then
# is itself cleared, must not fail on a second call.
cmd_consume() {
  [ $# -le 1 ] || die "consume takes at most one handoff file"
  local want='' current=''

  if [ ! -f "$MARKER" ]; then
    printf 'no unread handoff; nothing to consume\n'
    return 0
  fi
  IFS= read -r current < "$MARKER" 2>/dev/null || true

  if [ $# -eq 1 ]; then
    want=$(abspath "$1")
    [ "$want" = "$current" ] || die "marker points at $current, not $want; refusing to clear the wrong handoff"
  fi

  rm -f "$MARKER" || die "cannot clear $MARKER"
  printf 'consumed: %s\n' "${current:-unknown}"
}

# --- status -----------------------------------------------------------------
cmd_status() {
  local current=''
  if [ -f "$MARKER" ]; then
    IFS= read -r current < "$MARKER" 2>/dev/null || true
  fi
  if [ -n "$current" ] && [ -f "$current" ]; then
    printf 'unread: %s\n' "$current"
    return 0
  fi
  if [ -n "$current" ]; then
    printf 'stale: marker points at a missing file (%s)\n' "$current"
    return 0
  fi
  printf 'none: no handoff is pending\n'
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
sub=$1
shift
case "$sub" in
  path) cmd_path "$@" ;;
  arm) cmd_arm "$@" ;;
  pickup) cmd_pickup "$@" ;;
  consume) cmd_consume "$@" ;;
  status) cmd_status "$@" ;;
  -h | --help | help) usage ;;
  *) printf 'fm-handoff: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
esac
