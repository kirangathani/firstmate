#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# The window-name pin is a HARD requirement, not best-effort: every strict
# liveness read downstream compares '#{window_name}' against fm-<id>, so both
# rename options must actually be off on the created window.
[ "$(tmux show-options -w -t "$TARGET" automatic-rename)" = "automatic-rename off" ] \
  || fail "real tmux: create_task must pin the window name by disabling automatic-rename"
[ "$(tmux show-options -w -t "$TARGET" allow-rename)" = "allow-rename off" ] \
  || fail "real tmux: create_task must pin the window name by disabling allow-rename"
pass "real tmux: fm_backend_tmux_create_task pins the created window's name"

# An unpinnable window is refused rather than left behind for a strict reader
# to misjudge: with set-window-option forced to fail, the spawn errors AND the
# half-created window is removed again.
PIN_FAIL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke-pin.XXXXXX")
cat > "$PIN_FAIL_DIR/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = set-window-option ]; then
  echo "can't set option: automatic-rename" >&2
  exit 1
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$PIN_FAIL_DIR/tmux"
if out=$(PATH="$PIN_FAIL_DIR:$PATH" fm_backend_tmux_create_task "$SESSION" fm-smoke-unpinnable "$HOME" 2>&1); then
  fail "real tmux: create_task must refuse a window whose name it could not pin"
fi
case "$out" in
  *"could not pin the window name"*) : ;;
  *) fail "real tmux: an unpinnable window should fail loudly, got: $out" ;;
esac
if tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx fm-smoke-unpinnable; then
  fail "real tmux: a refused spawn must not leave its half-created window behind"
fi
rm -rf "$PIN_FAIL_DIR"
pass "real tmux: fm_backend_tmux_create_task fails loudly and cleans up when the name cannot be pinned"

# --- send text + Enter -------------------------------------------------------

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ '" Enter
sleep 0.3
tmux send-keys -t "$TARGET" -l "clear" ; tmux send-keys -t "$TARGET" Enter
sleep 0.3

fm_backend_tmux_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "fm_backend_tmux_send_literal failed"
sleep 0.2
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
sleep 0.6
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- endpoint liveness (fm_backend_target_exists) ----------------------------
# Regression: `tmux display-message -p -t <session>:<name>` does NOT fail on an
# unmatched window name - it silently falls back to the session's CURRENT
# window and exits 0, so the old probe reported EVERY task in an existing
# session as alive (evidence 2026-08-03: 6 dead tasks all read alive with 1
# real window). Both directions matter here: a false negative would fire
# recovery against a healthy worker, which is worse than the bug being fixed.
# The `-t` targets below are exactly what the session-start and fleet-snapshot
# digests pass ("<session>:<window>" plus the owning "fm-<id>" label).

# A second window, made the session's CURRENT one, is what a name-fallback
# probe would silently answer from. `sleep` is chosen so its agent-liveness
# classification (unknown) differs from the verdict for a genuinely gone
# window (dead): without that difference the assertion below could not tell a
# correct read from an inherited one.
tmux new-window -d -t "$SESSION:" -n fm-smoke-neighbour "sleep 300" \
  || fail "real tmux: could not create the neighbour window"
tmux select-window -t "$SESSION:fm-smoke-neighbour" \
  || fail "real tmux: could not select the neighbour window"

fm_backend_target_exists tmux "$TARGET" \
  || fail "real tmux: a LIVE window must report alive (false negative would trigger spurious recovery)"
fm_backend_target_exists tmux "$TARGET" "$WINDOW" \
  || fail "real tmux: a LIVE window must report alive when its own label is passed"
pass "real tmux: fm_backend_target_exists reports a live window alive, with and without its label"

if fm_backend_target_exists tmux "$SESSION:fm-smoke-gone"; then
  fail "real tmux: a nonexistent window name in a LIVE session must report dead, not alive"
fi
if fm_backend_target_exists tmux "$SESSION:fm-smoke-gone" "fm-smoke-gone"; then
  fail "real tmux: a nonexistent window name must report dead when its label is passed too"
fi
pass "real tmux: fm_backend_target_exists reports a nonexistent window in a live session as dead"

# A caller that knows the owning label must not accept a window that merely
# resolved: the fully-qualified live "$TARGET" is rejected when the expected
# label names the neighbour instead. (The unique-prefix resolution this guards
# against is exercised directly further down, once the neighbour is gone.)
if fm_backend_target_exists tmux "$TARGET" fm-smoke-neighbour; then
  fail "real tmux: a resolved window whose name differs from the expected label must report dead"
fi
pass "real tmux: fm_backend_target_exists rejects a target that resolves to a differently-named window"

# fm_backend_agent_alive (the secondmate-liveness sweep's probe) must resolve
# the target the same way: a gone window is `dead`, never the neighbour's
# verdict (`unknown` here, since sleep is neither a harness nor a shell).
verdict=$(fm_backend_agent_alive tmux "$SESSION:fm-smoke-neighbour")
[ "$verdict" = unknown ] \
  || fail "real tmux: the neighbour window's own agent verdict should be unknown, got '$verdict'"
verdict=$(fm_backend_agent_alive tmux "$SESSION:fm-smoke-gone")
[ "$verdict" = dead ] \
  || fail "real tmux: a gone window must classify as dead from its own resolution, got '$verdict'"
pass "real tmux: fm_backend_agent_alive reports a gone window dead instead of inheriting the current window's verdict"

# fm_backend_tmux_send_key guards through the same primitive. Its previous
# guard (`display-message -p -t <target> '#{pane_id}'`) could not fail while
# the session existed, so a key aimed at a gone window was still handed to
# send-keys, and one aimed at a target that prefix-resolves elsewhere went to
# the WRONG pane.
if fm_backend_tmux_send_key "$SESSION:fm-smoke-gone" Enter 2>/dev/null; then
  fail "real tmux: send_key must refuse a target that does not resolve"
fi
if fm_backend_tmux_send_key "$TARGET" Enter fm-smoke-neighbour 2>/dev/null; then
  fail "real tmux: send_key must refuse a target that resolves to a differently-labelled window"
fi
fm_backend_tmux_send_key "$TARGET" Enter "$WINDOW" \
  || fail "real tmux: send_key must still send to a live window matching its own label"
pass "real tmux: fm_backend_tmux_send_key refuses a gone or mislabelled target and sends to a matching one"

tmux kill-window -t "$SESSION:fm-smoke-neighbour" 2>/dev/null || true

# With the neighbour gone, "$SESSION:fm-smoke" is an UNAMBIGUOUS prefix of the
# one remaining window, so tmux really does resolve it to "$WINDOW". That is
# the hazard the expected-label argument exists for, exercised non-vacuously:
# the truncated target resolves, yet a caller that names a DIFFERENT owning
# window must still be refused, while the caller that names the resolved
# window must still be accepted.
TRUNCATED="$SESSION:fm-smoke"
fm_backend_target_exists tmux "$TRUNCATED" \
  || fail "real tmux: '$TRUNCATED' should resolve to '$WINDOW' by unique-prefix match (the case below is vacuous otherwise)"
if fm_backend_target_exists tmux "$TRUNCATED" fm-smoke-other; then
  fail "real tmux: a truncated target that resolves to '$WINDOW' must be rejected when the expected label names a different window"
fi
fm_backend_target_exists tmux "$TRUNCATED" "$WINDOW" \
  || fail "real tmux: a truncated target must still be accepted when the expected label matches the window it resolved to"
pass "real tmux: fm_backend_target_exists rejects a unique-prefix resolution to a differently-labelled window and accepts a matching one"

# Existence is list-panes' EXIT STATUS, not the emptiness of its output: a live
# pane whose window name is the empty string prints an empty line at rc=0, and
# reporting it dead would fire recovery against a healthy worker.
tmux new-window -d -t "$SESSION:" -n fm-smoke-unnamed "sleep 300" \
  || fail "real tmux: could not create the to-be-unnamed window"
unnamed_pane=$(tmux list-panes -t "$SESSION:fm-smoke-unnamed" -F '#{pane_id}' | head -n 1)
[ -n "$unnamed_pane" ] || fail "real tmux: could not find the pane of the to-be-unnamed window"
tmux rename-window -t "$unnamed_pane" '' \
  || fail "real tmux: could not blank the window name"
[ -z "$(tmux list-panes -t "$unnamed_pane" -F '#{window_name}')" ] \
  || fail "real tmux: the window name did not actually blank (the case below would be vacuous)"
fm_backend_target_exists tmux "$unnamed_pane" \
  || fail "real tmux: a LIVE pane whose window name is empty must report alive when no label is passed"
if fm_backend_target_exists tmux "$unnamed_pane" "$WINDOW"; then
  fail "real tmux: a blank-named window must not satisfy a non-empty expected label"
fi
pass "real tmux: fm_backend_target_exists reads existence from list-panes' exit status, so a blank-named live pane is alive"
tmux kill-window -t "$unnamed_pane" 2>/dev/null || true

# --- kill ---------------------------------------------------------------------

fm_backend_tmux_kill "$TARGET"
if fm_backend_target_exists tmux "$TARGET"; then
  fail "real tmux: a killed window must report dead through fm_backend_target_exists"
fi
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: fm_backend_tmux_kill removes the window and is idempotent/best-effort"

cleanup_all
trap - EXIT
