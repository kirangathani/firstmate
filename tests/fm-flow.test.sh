#!/usr/bin/env bash
# Behavior tests for the fleet pipeline view's entry point.
#
# bin/fm-flow.sh exists for one reason: the viewer reads its snapshot on stdin,
# stdin ends the moment that document has been read, and a watch loop therefore
# has no second document to read. This script is what gives it one, and the
# assertion that matters is that the command it hands over as --refresh-cmd is
# the SAME collector argv the first frame came from. A refresh that quietly
# dropped --no-ci or --task would redraw a different fleet than the one the
# captain asked for, and nothing on screen would say so.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLOW="$ROOT/bin/fm-flow.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow)
mkdir -p "$TMP_ROOT"

[ -x "$FLOW" ] || fail "bin/fm-flow.sh is not executable"
bash -n "$FLOW" || fail "bin/fm-flow.sh is not syntactically valid"
pass "the entry point is executable and parses"

out=$("$FLOW" --help); rc=$?
expect_code 0 $rc "--help must exit 0"
assert_contains "$out" "fm-flow.sh" "help does not name the command"
assert_contains "$out" "--open" "help does not document --open"
pass "--help explains the command"

out=$("$FLOW" --nonsense 2>&1); rc=$?
expect_code 2 $rc "an unknown argument must be a usage error"
pass "an unknown argument is refused"

out=$("$FLOW" --task 2>&1); rc=$?
expect_code 2 $rc "--task with no value must be a usage error"
pass "a flag missing its value is refused"

# --- the refresh command is the collector argv, verbatim ---------------------
#
# Driven through a mirror of bin/ holding the real fm-flow.sh next to a fake
# collector and a fake viewer, so the test observes the exact argv handoff
# without running a real fleet snapshot.

mirror="$TMP_ROOT/bin"
mkdir -p "$mirror"
cp "$FLOW" "$mirror/fm-flow.sh"
cat >"$mirror/fm-flow-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SNAPSHOT_LOG"
printf '{"schema":"fm-flow-snapshot.v1","generated_epoch":1,"agents":[]}\n'
EOF
cat >"$mirror/fm-flow-tui.mjs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_TUI_ARGV"
cat >"$FAKE_TUI_STDIN"
EOF
chmod +x "$mirror/fm-flow-snapshot.sh" "$mirror/fm-flow-tui.mjs"

export FAKE_SNAPSHOT_LOG="$TMP_ROOT/collect.log"
export FAKE_TUI_ARGV="$TMP_ROOT/tui.argv"
export FAKE_TUI_STDIN="$TMP_ROOT/tui.stdin"
: >"$FAKE_SNAPSHOT_LOG"

"$mirror/fm-flow.sh" --no-ci --task alpha-1 >/dev/null 2>&1 ||
  fail "the entry point failed on a healthy collector"

assert_grep "fm-flow-snapshot.v1" "$FAKE_TUI_STDIN" "the first frame was not fed in on stdin"
assert_grep "--watch" "$FAKE_TUI_ARGV" "the viewer was not started in watch mode"

refresh=$(grep -A1 -- '--refresh-cmd' "$FAKE_TUI_ARGV" | tail -1)
[ -n "$refresh" ] || fail "no --refresh-cmd was passed to the viewer"
assert_contains "$refresh" "--no-ci" "the refresh command dropped --no-ci"
assert_contains "$refresh" "alpha-1" "the refresh command dropped --task"
assert_contains "$refresh" "fm-flow-snapshot.sh" "the refresh command does not run the collector"
pass "the refresh command carries the same collector arguments as the first frame"

# Running it must reproduce the first frame's own invocation, not an
# approximation of it. Comparing the two logged argv lines is the check.
first=$(head -1 "$FAKE_SNAPSHOT_LOG")
FAKE_SNAPSHOT_LOG="$FAKE_SNAPSHOT_LOG" sh -c "$refresh" >/dev/null ||
  fail "the refresh command does not run"
second=$(tail -1 "$FAKE_SNAPSHOT_LOG")
[ "$first" = "$second" ] ||
  fail "refresh ran '$second' but the first frame came from '$first'"
pass "running the refresh command re-collects with identical arguments"

# --- a failed collector is reported, not drawn -------------------------------

cat >"$mirror/fm-flow-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
echo "collector exploded" >&2
exit 1
EOF
chmod +x "$mirror/fm-flow-snapshot.sh"
: >"$FAKE_TUI_ARGV"
out=$("$mirror/fm-flow.sh" 2>&1); rc=$?
expect_code 1 $rc "a failed snapshot must exit 1"
assert_contains "$out" "nothing to draw" "a failed snapshot was not explained"
[ ! -s "$FAKE_TUI_ARGV" ] || fail "the viewer was launched after the snapshot failed"
pass "a failed snapshot is reported and the view is not opened"

# --- --open focuses one worker, and refuses rather than guessing -------------

state="$TMP_ROOT/home/state"
mkdir -p "$state"

out=$(FM_HOME="$TMP_ROOT/home" "$FLOW" --open ghost-1 2>&1); rc=$?
expect_code 1 $rc "--open on an unknown task must fail"
assert_contains "$out" "ghost-1" "the refusal did not name the task"
pass "--open on a task with no local record refuses"

printf 'window=\nproject=/p\n' >"$state/nowindow-1.meta"
out=$(FM_HOME="$TMP_ROOT/home" "$FLOW" --open nowindow-1 2>&1); rc=$?
expect_code 1 $rc "--open with no recorded window must fail"
assert_contains "$out" "no window recorded" "the refusal did not say what was missing"
pass "--open with no recorded window refuses"

# Focusing a window is a per-backend verb firstmate's backend interface does
# not carry yet. tmux is the verified reference backend; every other backend
# must be told plainly that it is not implemented AND handed the target, not
# sent a command nobody has ever run against it.
printf 'window=ws-7\nbackend=herdr\nproject=/p\n' >"$state/herdr-1.meta"
out=$(FM_HOME="$TMP_ROOT/home" "$FLOW" --open herdr-1 2>&1); rc=$?
expect_code 1 $rc "--open on an unsupported backend must fail"
assert_contains "$out" "not implemented" "an unsupported backend was not named as unimplemented"
assert_contains "$out" "ws-7" "the refusal did not tell the captain where the worker is"
pass "--open refuses an unverified backend and still names the target"

# The live-tmux case runs on a PRIVATE tmux server (its own TMUX_TMPDIR, with
# TMUX unset so tmux does not treat it as nested). --open ends in
# `switch-client`, which moves an ATTACHED client to the target session: on the
# shared server that is the captain's own terminal being yanked into a test
# fixture mid-run. A private server has no attached client, so the same call is
# a real exercise of the code and a no-op for anyone watching.
if command -v tmux >/dev/null 2>&1; then
  # Short path on purpose: a unix socket path is capped near 108 bytes, and
  # TMPDIR here can already be long enough to blow that on its own.
  TMUX_TMPDIR=$(mktemp -d /tmp/fmflowtmux.XXXXXX) || fail "could not make a tmux socket dir"
  export TMUX_TMPDIR
  FM_TEST_CLEANUP_DIRS+=("$TMUX_TMPDIR")
  chmod 700 "$TMUX_TMPDIR"
  unset TMUX
  sess="fmflowtest$$"
  if tmux new-session -d -s "$sess" -n first 2>/dev/null; then
    tmux new-window -d -t "$sess" -n second
    printf 'window=%s:second\nproject=/p\n' "$sess" >"$state/real-1.meta"
    FM_HOME="$TMP_ROOT/home" "$FLOW" --open real-1 || fail "--open failed on a live tmux window"
    active=$(tmux display-message -p -t "$sess" '#{window_name}')
    [ "$active" = "second" ] || fail "--open did not focus the worker's window (active: $active)"

    printf 'window=%s:gone\nproject=/p\n' "$sess" >"$state/missing-1.meta"
    out=$(FM_HOME="$TMP_ROOT/home" "$FLOW" --open missing-1 2>&1); rc=$?
    expect_code 1 $rc "--open on a window that does not exist must fail"
    assert_contains "$out" "gone" "the refusal did not name the missing window"
    tmux kill-server 2>/dev/null
    pass "--open focuses a live tmux window and refuses a dead one"
  else
    echo "skip: could not create a private tmux server"
  fi
else
  echo "skip: tmux not found"
fi
