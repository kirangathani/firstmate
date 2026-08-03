#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key, sent only once <target> has been
# resolved through fm_backend_tmux_target_exists (the ONE liveness primitive).
# The pre-adapter fm-send.sh guard was `tmux display-message -p -t "$T"
# '#{pane_id}' >/dev/null`, which cannot fail while the session exists: it
# falls back to the session's current window for any name (see
# fm_backend_tmux_target_exists), so it neither refused a gone target nor
# caught the unique-prefix resolution that would type this key into a
# DIFFERENT crewmate's pane. <expected-label> is the owning "fm-<id>" when the
# caller knows it (bin/fm-send.sh passes it for a task selector, and never for
# the explicit-target escape hatch).
fm_backend_tmux_send_key() {  # <target> <key> [expected-label]
  fm_backend_tmux_target_exists "$1" "${3:-}" || return 1
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
#
# The pin is a HARD REQUIREMENT, not best-effort: every strict, label-checking
# liveness read downstream (fm_backend_tmux_target_exists with an
# expected-label, and through it the session-start digest, the fleet snapshot,
# fm-crew-state.sh, and the secondmate-liveness sweep's respawn decision)
# compares the live '#{window_name}' against fm-<id>, so a window whose name
# tmux is still free to rename would eventually read DEAD while its agent is
# alive. An unpinnable window is therefore refused at creation - killed again
# and reported - rather than spawned into a state no reader can trust.
# fm-spawn.sh records the guarantee as tmux_window_pinned=1 in the task meta;
# a meta without it predates this requirement and is read leniently
# (fm_backend_expected_label_of_meta, bin/fm-backend.sh).
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid opt err
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  for opt in automatic-rename allow-rename; do
    if ! err=$(tmux set-window-option -t "$wid" "$opt" off 2>&1); then
      tmux kill-window -t "$wid" 2>/dev/null || true
      echo "error: could not pin the window name of $ses:$wname ($opt off failed${err:+: $err}); refusing to spawn a window tmux may rename away from $wname" >&2
      return 1
    fi
  done
  printf '%s\n' "$wid"
}

# fm_backend_tmux_target_exists: does <target> still resolve to a live tmux
# pane? Prints nothing; 0 = exists, non-zero = gone. This is the tmux arm of
# fm-backend.sh's fm_backend_target_exists, and the ONE primitive every tmux
# liveness read must go through.
#
# It deliberately does NOT use `tmux display-message -p -t <target>`, which
# LOOKS like an existence probe and is not. Verified empirically on tmux 3.4
# (2026-08-03), session "fmtest" holding only window "fm-real":
#
#   $ tmux display-message -p -t 'fmtest:fm-bogus' '#{pane_id} #{window_name}'
#   %41 fm-real
#   rc=0
#
# display-message silently falls back to the session's CURRENT window and
# exits 0, so it reports EVERY name as alive as long as the SESSION exists.
# The `=` exact-match prefix ('fmtest:=fm-bogus') does not help: same
# fallback, same rc=0. A stale pane id behaves the same way ('%9999' prints
# empty at rc=0). That defect made every dead task read "endpoint: alive" in
# the session-start fleet digest, so no dead ordinary crewmate was detectable
# there at all (evidence 2026-08-03: 6 tasks reported alive with 1 real
# window).
#
# `tmux list-panes -t <target>` is the correct primitive - it is what
# capture-pane resolves through, and it fails loudly on a gone target:
#
#   $ tmux list-panes -t 'fmtest:fm-bogus'   -> rc=1 "can't find window: fm-bogus"
#   $ tmux list-panes -t 'nosuchsess:fm-real'-> rc=1 "can't find session: nosuchsess"
#   $ tmux list-panes -t '%9999'             -> rc=1 "can't find pane: %9999"
#   $ tmux list-panes -t 'fmtest:fm-real'    -> rc=0
#
# It is preferred over enumerating `tmux list-windows -t <session> -F
# '#{window_name}'` and matching because enumeration needs the caller to split
# <target> back into session and window, and tmux window names may contain the
# ':' separator (and a target may equally be a pane id, a window id, or
# 'session:window.pane'). list-panes resolves the target with tmux's own
# parser, so no shape of name or target can be mis-split here. Verified rc=0
# for pane-id, window-id, bare-session, and 'session:index.pane' targets.
#
# EXISTENCE IS list-panes' EXIT STATUS, never the emptiness of its output. A
# live pane whose window was renamed to the empty string prints an empty line
# at rc=0 (verified on tmux 3.4: `tmux rename-window -t %0 ''` then `tmux
# list-panes -t %0 -F '#{window_name}'` -> rc=0, output ""), so treating empty
# output as "gone" would report a HEALTHY pane dead. False negatives are the
# worse direction here: they license bin/fm-bootstrap.sh's secondmate sweep to
# kill and respawn a live agent, and abort the away-mode daemon's startup on a
# live supervisor pane.
#
# EXPECTED-LABEL: tmux target matching is a unique-prefix/fnmatch match, so
# 'fmtest:fm-re' resolves to window 'fm-real' when that prefix is unambiguous.
# When the caller knows the owning task label (the digests pass "fm-<id>"), the
# resolved '#{window_name}' must equal it exactly, mirroring the zellij and
# cmux arms. Callers with no label (fm-send.sh's explicit-target escape hatch,
# the away-mode daemon's supervisor pane) keep tmux's own resolution, which is
# correct for them: it is the very window tmux would act on.
#
# Related but SEPARATE defects, deliberately not addressed here: crew-state
# trusting a recycled treehouse slot, and teardown killing a live crewmate
# holding a recycled slot. They compound with this one - a task that reads
# dead here may have had its recorded slot taken over by a LIVE different
# task - but both are tracked as their own work.
fm_backend_tmux_target_exists() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} name
  name=$(tmux list-panes -t "$target" -F '#{window_name}' 2>/dev/null) || return 1
  [ -n "$expected_label" ] || return 0
  [ "${name%%$'\n'*}" = "$expected_label" ]
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove the task's window, best-effort. Mirrors
# fm-teardown.sh's `tmux kill-window -t "$T" 2>/dev/null || true`.
fm_backend_tmux_kill() {  # <target>
  tmux kill-window -t "$1" 2>/dev/null || true
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_agent_alive: CONFIDENT liveness of a live harness-agent
# PROCESS in <target>'s pane, distinct from fm_backend_target_exists's
# pane-PRESENCE-only check (a pane that still exists but is sitting at a bare
# idle shell passes THAT check as "alive" - the secondmate-liveness gap
# AGENTS.md's session-start guarantee closes). See docs/tmux-backend.md
# "Agent liveness probe" for the empirical basis. Prints one of:
#   alive   - the foreground command is one of the verified harness binaries
#             (claude, codex, opencode, grok - each confirmed to run as its
#             own process name, never wrapped by a generic interpreter).
#   dead    - the foreground command is a bare shell: nothing is running in
#             the pane, so a prior agent process has exited.
#   unknown - anything else, INCLUDING a bare "node"/"python" interpreter
#             name (pi's own launcher execs into a generic "node" process
#             with no reliable way to attribute it back to pi from outside
#             the pane - docs/tmux-backend.md "Known gaps"), or an unreadable
#             pane. Callers must never treat unknown as a confirmed-dead
#             signal (bin/fm-bootstrap.sh's secondmate-liveness sweep gates a
#             respawn on `dead` only).
# <expected-label> is the owning "fm-<id>" when the caller can prove the
# window name is pinned (fm_backend_expected_label_of_meta, bin/fm-backend.sh).
# It matters most HERE, on the one path that acts destructively: without it a
# gone secondmate window "sm" prefix-resolves to a live neighbour "sm-2" and
# inherits that neighbour's verdict, so the dead secondmate is never respawned
# (or, when the neighbour sits at a bare shell, is respawned while the sweep
# kills the neighbour's window). A caller that cannot prove the pin passes no
# label and gets tmux's own resolution, which is lenient in the safe direction:
# a drifted window name must never become a confident dead reading.
fm_backend_tmux_agent_alive() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} comm
  # A GONE window must never be classified from #{pane_current_command}: that
  # read goes through display-message, which falls back to the session's
  # current window (see fm_backend_tmux_target_exists), so a dead secondmate
  # would inherit a NEIGHBOURING pane's verdict - "alive" whenever any other
  # crewmate happened to be the current window. Resolve the target strictly
  # first. A structurally-gone window collapses to `dead`, the same mapping
  # herdr's arm already uses for a structurally-gone pane; if the tmux server
  # itself did not answer, nothing was confidently read and this stays
  # `unknown`, so a momentary server glitch can never license a respawn.
  if ! fm_backend_tmux_target_exists "$target" "$expected_label"; then
    if tmux list-sessions >/dev/null 2>&1; then printf 'dead'; else printf 'unknown'; fi
    return 0
  fi
  comm=$(fm_backend_tmux_current_command "$target") || { printf 'unknown'; return 0; }
  comm=${comm#-}
  case "$comm" in
    '') printf 'unknown' ;;
    *claude*|*codex*|*opencode*|*grok*) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
