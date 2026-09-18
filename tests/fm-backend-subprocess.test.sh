#!/usr/bin/env bash
# tests/fm-backend-subprocess.test.sh - is the harness under an endpoint WAITING
# ON A SUBPROCESS OF ITS OWN? fm_backend_subprocess_state (bin/fm-backend.sh)
# and the tmux pane-pid reader it stands on (fm_backend_tmux_pane_pid,
# bin/backends/tmux.sh). The empirical basis for both - why a session leader is
# the test, why the age bound is needed, and what the probe cannot catch - is
# recorded in docs/tmux-backend.md "Subprocess probe".
#
# Its own file rather than an addition to tests/fm-backend.test.sh, following
# the fm-backend-cmux / -herdr / -orca / -zellij siblings: this is one new
# primitive with its own process fixtures, and that suite is already the
# repo's largest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-subprocess-tests)

# --- fm_backend_subprocess_state --------------------------------------------
#
# Over REAL processes and the real `ps`, because the whole predicate is a claim
# about what a process tree looks like: a fake table would assert the shape this
# test already believes rather than the one the kernel reports. Only tmux's
# pane-pid lookup is faked, since that is the one part with no process in it.
#
# The fixture reproduces the two child shapes the harness actually produces
# (measured on ten live claude panes, 2026-09-17; bin/fm-backend.sh's header):
# a tool shell setsid'd into its own session, and an MCP-server-shaped child
# that stays in the harness's session.

# A fake tmux that answers the one query fm_backend_tmux_pane_pid makes, plus
# the strict target resolve it is gated behind.
make_subprocess_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin-subproc"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-panes)
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || exit 1
    _t=""; _p=""
    for _a in "$@"; do [ "$_p" = "-t" ] && _t="$_a"; _p="$_a"; done
    printf '%s\n' "${_t##*:}"
    exit 0 ;;
  display-message)
    case "$*" in
      *pane_pid*) printf '%s\n' "${FM_FAKE_TMUX_PANE_PID:-}"; exit 0 ;;
    esac
    exit 1 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# Start a root process holding one child of the requested shape, and echo its
# pid. `detached` setsid's the child into its own session the way a harness
# detaches a tool shell; `plain` leaves it in the root's session the way a
# long-lived service child sits. The root execs into its own wait so that the
# pid echoed here is the one the child hangs under.
SUBPROC_ROOT_PIDS=
start_subprocess_root() {  # <detached|plain> -> echoes root pid
  local shape=$1 pid
  if [ "$shape" = detached ]; then
    bash -c 'setsid sleep 60 >/dev/null 2>&1 & exec sleep 60' >/dev/null 2>&1 &
  else
    bash -c 'sleep 60 >/dev/null 2>&1 & exec sleep 60' >/dev/null 2>&1 &
  fi
  pid=$!
  SUBPROC_ROOT_PIDS="$SUBPROC_ROOT_PIDS $pid"
  # The child is spawned by the root after it starts, so wait for the tree to
  # exist rather than racing it. Bounded well under a second.
  local i=0
  while [ "$i" -lt 40 ]; do
    [ -n "$(ps --ppid "$pid" -o pid= 2>/dev/null)" ] && break
    sleep 0.025
    i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

stop_subprocess_roots() {
  local pid kid
  for pid in $SUBPROC_ROOT_PIDS; do
    for kid in $(ps --ppid "$pid" -o pid= 2>/dev/null); do
      kill "$kid" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  SUBPROC_ROOT_PIDS=
}

test_subprocess_state_detached_child_is_seen() {
  local fb root out
  fb=$(make_subprocess_fakebin "$TMP_ROOT")
  root=$(start_subprocess_root detached)
  out=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID="$root" \
    fm_backend_subprocess_state tmux sess:fm-a 0)
  stop_subprocess_roots
  [ "$out" = detached ] || fail "a session-leader descendant must read detached, got '$out'"
  pass "fm_backend_subprocess_state: a descendant in its own session reads detached"
}

test_subprocess_state_same_session_child_is_not_seen() {
  local fb root out
  fb=$(make_subprocess_fakebin "$TMP_ROOT")
  root=$(start_subprocess_root plain)
  out=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID="$root" \
    fm_backend_subprocess_state tmux sess:fm-a 0)
  stop_subprocess_roots
  [ "$out" = none ] || fail "a child sharing the root's session must read none, got '$out'"
  pass "fm_backend_subprocess_state: a child in the harness's own session reads none (MCP-server shape)"
}

# The age bound is what separates a tool shell from a status-line render, which
# a claude pane re-runs continuously, idle or busy, for well under a second. The
# threshold is driven from the call rather than from a sleep: a child that has
# just started cannot satisfy a bound above its own age.
test_subprocess_state_age_bound_excludes_a_just_started_child() {
  local fb root out_young out_any
  fb=$(make_subprocess_fakebin "$TMP_ROOT")
  root=$(start_subprocess_root detached)
  out_any=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID="$root" \
    fm_backend_subprocess_state tmux sess:fm-a 0)
  out_young=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID="$root" \
    fm_backend_subprocess_state tmux sess:fm-a 86400)
  stop_subprocess_roots
  [ "$out_any" = detached ] || fail "the same child must read detached with no age bound, got '$out_any'"
  [ "$out_young" = none ] || fail "a child younger than the bound must read none, got '$out_young'"
  pass "fm_backend_subprocess_state: a child younger than the age bound is not counted"
}

test_subprocess_state_unreadable_inputs_are_unknown() {
  local fb root gone_out noroot_out badage_out other_out
  fb=$(make_subprocess_fakebin "$TMP_ROOT")
  root=$(start_subprocess_root detached)
  gone_out=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID="$root" FM_FAKE_TMUX_PANE_ALIVE=0 \
    fm_backend_subprocess_state tmux sess:fm-a 0)
  noroot_out=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID='' \
    fm_backend_subprocess_state tmux sess:fm-a 0)
  badage_out=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID="$root" \
    fm_backend_subprocess_state tmux sess:fm-a 'soon')
  other_out=$(PATH="$fb:$PATH" FM_FAKE_TMUX_PANE_PID="$root" \
    fm_backend_subprocess_state herdr default:w1:p2 0)
  stop_subprocess_roots
  [ "$gone_out" = unknown ] || fail "a gone endpoint must read unknown, got '$gone_out'"
  [ "$noroot_out" = unknown ] || fail "an unreadable root pid must read unknown, got '$noroot_out'"
  [ "$badage_out" = unknown ] || fail "a non-numeric age bound must read unknown, got '$badage_out'"
  [ "$other_out" = unknown ] || fail "a backend with no verified root-pid reader must read unknown, got '$other_out'"
  pass "fm_backend_subprocess_state: every unreadable input reads unknown, never none"
}

test_subprocess_state_detached_child_is_seen
test_subprocess_state_same_session_child_is_not_seen
test_subprocess_state_age_bound_excludes_a_just_started_child
test_subprocess_state_unreadable_inputs_are_unknown
