#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# It blocks for THREE independent reasons, reported together in one banner so a
# permanently broken watcher cannot hide the others:
#   1. in-flight work with no live watcher (the original blind-turn reason),
#   2. an in-flight branch whose CI was measured against a base that has since
#      moved (bin/fm-stale-base.sh, which owns that predicate and its remedy), and
#   3. a direct report sitting in a state that owes firstmate an action, past the
#      grace window, unacted on (bin/fm-ack-lib.sh, which owns that predicate).
#
# Why reason 3 is here and not only in bin/fm-guard.sh. That guard has raised
# this exact finding since #35, and it exits 0 - it warns, then the turn ends
# anyway, so acting on it was a matter of the agent choosing to. The finding was
# never the weak part; its consequence was. Reason 1 is the precedent: it is also
# a condition bin/fm-guard.sh warns about, and making it block at turn end is
# what has caught two real supervision blackouts on this box. Reason 3 is the
# same predicate given the same consequence, so a turn cannot end with a worker's
# reported state unanswered.
#
# Reason 3 stays quiet on a healthy fleet for the reasons bin/fm-ack-lib.sh owns:
# a ten-minute grace, an ack that silences a state firstmate has already handled
# for as long as the captain takes to answer, and a current-state confirm that
# clears a worker which has provably moved on. A task the captain has signed an
# exemption for never reaches this check at all. A guard that fired constantly
# would be turned off, which is worse than no guard.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
# Wall-clock bound on the stale-base sweep. It is purely local git reads and
# measures ~0.2s across a ten-task fleet, but this hook is the one place a hang
# wedges the whole session, so it is bounded anyway. Expiry is REPORTED, never
# treated as an all-clear.
STALE_BASE_TIMEOUT=${FM_STALE_BASE_TIMEOUT:-10}

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-ack-lib.sh
. "$SCRIPT_DIR/fm-ack-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0

# Supervision belongs to the session holding this home's SESSION lock
# (state/.lock - not the watcher singleton state/.watch.lock checked below).
# A session that does not hold it cannot arm a watcher (bin/fm-watch-arm.sh
# declines from there), so telling it to repair supervision would block nearly
# every turn on work it must not touch. The same reasoning covers the stale-base
# alarm: a read-only session must not be steering another session's workers.
# This mirrors the read-only advisory mode bin/fm-guard.sh already uses. A dead
# or absent holder still alarms: nobody is supervising the in-flight work, and
# this session is the one that should take the lock and arm.
[ "$(fm_session_lock_ownership "$STATE")" = other ] && exit 0

blind=0
fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || blind=1

# Second, independent block reason: an in-flight branch that no longer contains
# its project's current default-branch head. Every CI result on such a branch was
# measured against a base that no longer exists, so it reads as a verdict on the
# branch and is not. bin/fm-stale-base.sh owns the predicate, the silent cases,
# and the remedy wording; it is local-ref only, so it adds no network call to the
# turn-end path. bin/fm-fleet-sync.sh raises the same finding the moment a base
# moves; this is the backstop that makes it unforgettable rather than merely
# automatic, because an absorbed wake can be missed and a turn end cannot.
#
# The bounder and the sweep are BOTH optional siblings, and each is probed
# before use. This hook must stay byte-silent whenever it has nothing to say -
# every caller captures its output, and a healthy turn that prints anything is
# indistinguishable from an alarm. An unconditional `.` of a missing sibling
# prints "No such file or directory" to stderr, and calling an undefined
# function prints "command not found", so either one would turn a silent
# healthy turn into a noisy one. That is the same fail-open-and-quiet rule the
# missing-jq and empty-stdin paths above already follow.
if [ -r "$SCRIPT_DIR/fm-bounded-lib.sh" ]; then
  # shellcheck source=bin/fm-bounded-lib.sh
  . "$SCRIPT_DIR/fm-bounded-lib.sh"
fi
STALE_BASE=
if [ -x "$SCRIPT_DIR/fm-stale-base.sh" ]; then
  stale_base_rc=0
  if command -v fm_bounded_available >/dev/null 2>&1 && fm_bounded_available; then
    STALE_BASE=$(fm_bounded_run "$STALE_BASE_TIMEOUT" \
      env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-stale-base.sh" 2>/dev/null) || stale_base_rc=$?
  else
    STALE_BASE=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-stale-base.sh" 2>/dev/null) || stale_base_rc=$?
  fi
  if [ "$stale_base_rc" -eq 124 ]; then
    STALE_BASE="STALE BASE UNDETERMINABLE: the stale-base sweep did not finish within ${STALE_BASE_TIMEOUT}s, so NO branch in flight has been checked against the current base"
  fi
fi

# Third, independent block reason: a direct report whose reported state still
# owes firstmate an action. bin/fm-ack-lib.sh owns the predicate, the grace, both
# silencers, and the captain-signed exemption; this only gives its verdict a
# consequence. The cheap filter there means a healthy fleet forks nothing, so
# this adds no measurable cost to a turn end.
#
# It is deliberately NOT bounded by a timeout the way the stale-base sweep is:
# every read it makes is a local file stat except the current-state confirm,
# which is capped per invocation and cached, and swallowing its verdict on
# expiry would mean silently ending a turn on exactly the finding this reason
# exists to force. A confirm that cannot be read already reports as unreadable
# and still alarms.
UNACTIONED=$(fm_ack_unactioned "$STATE" 2>/dev/null || true)

[ "$blind" = 1 ] || [ -n "$STALE_BASE" ] || [ -n "$UNACTIONED" ] || exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  if [ "$blind" = 1 ]; then
    afk=0
    [ -e "$STATE/.afk" ] && afk=1
    x_mode=0
    [ -f "$CONFIG/x-mode.env" ] && x_mode=1
    REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
      || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    printf '●  %s\n' "$REASON"
  fi
  if [ -n "$STALE_BASE" ]; then
    [ "$blind" = 1 ] && printf '●%s\n' "$rule"
    printf '●  TURN WOULD END WITH CI MEASURED AGAINST A BASE THAT MOVED\n'
    printf '%s\n' "$STALE_BASE" | while IFS= read -r stale_line; do
      printf '●  %s\n' "$stale_line"
    done
  fi
  if [ -n "$UNACTIONED" ]; then
    { [ "$blind" = 1 ] || [ -n "$STALE_BASE" ]; } && printf '●%s\n' "$rule"
    printf '●  TURN WOULD END WITH A REPORTED STATE UNANSWERED\n'
    while IFS=$'\t' read -r u_id u_verb u_age u_verdict u_last; do
      [ -n "$u_id" ] || continue
      printf '●  %s reported "%s" %ss ago and firstmate has not acted (state: %s).\n' \
        "$u_id" "$u_verb" "$u_age" "$u_verdict"
      printf '●      %s\n' "$u_last"
    done <<EOF
$UNACTIONED
EOF
    printf '●  Do what each state owes, then record it: bin/fm-ack.sh <id> "<what you did>"\n'
    printf '●  A state waiting on the CAPTAIN is recorded once you have relayed it to them.\n'
    printf '●  Run bin/fm-monitor.sh for the full per-task sweep.\n'
  fi
  printf '●%s\n' "$rule"
} >&2
exit 2
