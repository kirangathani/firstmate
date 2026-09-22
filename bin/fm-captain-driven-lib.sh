# shellcheck shell=bash
# Shared owner of the AUTOMATIC half of "the captain is driving this worker
# himself, so firstmate is not watching it".
# Usage: . bin/fm-captain-driven-lib.sh
#
# WHY THIS EXISTS. On 2026-09-17 the captain sat down in a worker's tmux window
# and drove it by hand. The watcher went on watching: it fired a stale wake on
# the quiet pane, firstmate peeked, saw the worker's own question, and put that
# question back to the captain who was already answering it. The captain's words
# were "I am driving that agent, why are you watching it?".
#
# The explicit half of the answer already existed - a captain-signed
# state/<id>.monitor-exempt, minted by bin/fm-monitor.sh - but it had to be typed
# every time he sat down. This library is the half that needs no command: tmux
# already knows which window each attached client is looking at, and when that
# client last pressed a key.
#
# THE SIGNAL, AND WHY IT IS TRUSTWORTHY (measured 2026-09-17, tmux 3.4, on an
# isolated `tmux -L fmtest` server so the live fleet was never touched):
#   #{window_active_clients}  the number of attached clients viewing a window.
#                             On the live fleet it read 1 for the one window the
#                             captain was on and 0 for the other ten.
#   #{client_activity}        the client's own last INPUT time. Three directions
#                             were checked, and all three came out right:
#     - a viewed window producing output every 2s for 31s did NOT advance it
#       (act stayed 1789646058 across seven samples), so a chatty worker cannot
#       make its own window look driven;
#     - `tmux send-keys`, which is how firstmate itself steers a worker
#       (bin/fm-send.sh), did NOT advance it either, so firstmate's own traffic
#       never counts as a human;
#     - a real keystroke from the attached client DID advance it, within 2s
#       (1789646103 -> 1789646115).
#   Firstmate never runs `tmux attach`, so it owns no client at all; every
#   primitive it uses (capture-pane, send-keys, display-message) is a one-shot
#   command. Every client tmux lists is therefore a human terminal.
#
# THE RULE. A task is attached-driven when some client is viewing the window
# recorded in state/<id>.meta AND that client's last keystroke was inside
# FM_CAPTAIN_DRIVEN_GRACE. Switching window or detaching drops it IMMEDIATELY,
# because the client is then viewing something else; the grace only covers a
# window left selected while the captain is away from the keyboard.
#
# TMUX ONLY, and that is not a gap this library should paper over. The reading is
# "which window is a human looking at", and no other runtime backend exposes one.
# A task on another backend is simply never attached-driven, and the explicit
# signed record still works there, so nothing is silently unsupervised.
#
# THE COMBINED VERDICT IS NOT HERE. fm_captain_driven, which is the predicate
# every supervision surface actually asks, lives in bin/fm-ack-lib.sh next to the
# signed record it ORs this with. This file is sourced on its own only by a
# reader that must not verify signatures (bin/fm-flow-snapshot.sh).
# docs/captain-driven.md is the mechanism narrative.

# How long after the captain's last keystroke a window he is still viewing stays
# his. Ten minutes: long enough to read a worker's output, think, and type again
# without supervision cutting back in mid-thought, and short enough that a
# terminal left parked on a window overnight returns to supervision the same
# morning rather than the next time somebody notices. Leaving the window, or
# detaching, resumes supervision at once and does not wait this out.
FM_CAPTAIN_DRIVEN_GRACE_DEFAULT=600

# Test seam: freeze "now" so grace assertions are deterministic.
fm_captain_driven_now() {
  if [ -n "${FM_CAPTAIN_DRIVEN_NOW:-}" ]; then printf '%s' "$FM_CAPTAIN_DRIVEN_NOW"; else date +%s; fi
}

fm_captain_driven_grace() {
  local g=${FM_CAPTAIN_DRIVEN_GRACE:-$FM_CAPTAIN_DRIVEN_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_CAPTAIN_DRIVEN_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

# The tmux target recorded for <id>, or empty when the task has none or does not
# run on tmux. An absent backend= field means tmux, which is the P1
# compatibility contract bin/fm-watch.sh's window_backend also follows.
fm_captain_driven_window() {  # <state-dir> <id>
  local meta backend win
  meta="$1/$2.meta"
  [ -f "$meta" ] || return 0
  backend=$(grep '^backend=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -z "$backend" ] || [ "$backend" = tmux ] || return 0
  win=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  printf '%s' "$win"
}

# One `tmux list-clients` read, memoized for the current second. A fleet sweep
# asks this predicate once per task, and the watcher asks it once per window on
# every poll, so without the memo a twenty-task home would fork tmux twenty times
# to answer one question that has one answer. The memo lives in a global, so it
# only works when this is called from the caller's own shell rather than inside a
# command substitution; a lost memo costs a fork, never a wrong answer.
_FM_CAPTAIN_CLIENTS=
_FM_CAPTAIN_CLIENTS_AT=
_fm_captain_clients_refresh() {
  local now
  now=$(fm_captain_driven_now)
  [ "$_FM_CAPTAIN_CLIENTS_AT" != "$now" ] || return 0
  _FM_CAPTAIN_CLIENTS_AT=$now
  _FM_CAPTAIN_CLIENTS=
  command -v tmux >/dev/null 2>&1 || return 0
  # Three spellings of the client's current window, because a recorded target may
  # be any of them: bin/fm-spawn.sh writes "<session>:fm-<id>" (the name form,
  # which tmux_window_pinned=1 guarantees cannot drift), while an index or a
  # window id is equally valid tmux. Matching all three costs nothing extra.
  _FM_CAPTAIN_CLIENTS=$(tmux list-clients \
    -F '#{client_activity}	#{client_session}:#{window_name}	#{client_session}:#{window_index}	#{window_id}' \
    2>/dev/null) || _FM_CAPTAIN_CLIENTS=
  return 0
}

# 0 when a human tmux client is viewing <id>'s window and pressed a key inside
# the grace window. On success FM_CAPTAIN_ATTACHED_REASON says so in the
# captain's own terms, because every surface that reports this has to tell him
# what it decided and why.
# shellcheck disable=SC2034 # Read by bin/fm-ack-lib.sh's fm_captain_driven, not this file.
FM_CAPTAIN_ATTACHED_REASON=
fm_captain_attached() {  # <state-dir> <id>
  local win now grace act by_name by_index by_id idle
  FM_CAPTAIN_ATTACHED_REASON=
  [ -n "${2:-}" ] || return 1
  win=$(fm_captain_driven_window "$1" "$2")
  [ -n "$win" ] || return 1
  _fm_captain_clients_refresh
  [ -n "$_FM_CAPTAIN_CLIENTS" ] || return 1
  now=$(fm_captain_driven_now)
  grace=$(fm_captain_driven_grace)
  while IFS=$'\t' read -r act by_name by_index by_id; do
    case "$act" in ''|*[!0-9]*) continue ;; esac
    [ "$win" = "$by_name" ] || [ "$win" = "$by_index" ] || [ "$win" = "$by_id" ] || continue
    idle=$((now - act))
    [ "$idle" -ge 0 ] || idle=0
    [ "$idle" -lt "$grace" ] || continue
    # shellcheck disable=SC2034 # Read by bin/fm-ack-lib.sh's fm_captain_driven, not this file.
    FM_CAPTAIN_ATTACHED_REASON="you are sitting in its window (last keystroke $((idle / 60))m ago)"
    return 0
  done <<FMCLIENTS
$_FM_CAPTAIN_CLIENTS
FMCLIENTS
  return 1
}
