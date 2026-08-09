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

# --- --open moves THIS terminal, or it does nothing at all -------------------
#
# `select-window` changes the target SESSION's current window and does nothing
# to the terminal the command was typed in. Run from a terminal that is not a
# client of that session - which is how the captain ran it - the shipped version
# exited 0 having moved a view nobody was looking at, and the viewer duly
# flashed `opened <id>`. Reproduced 2026-08-09 before this change.
#
# Worse, `switch-client` with no client of its own to name moves whatever client
# IS attached to the invoking pane's session. A test, a script or an agent
# running inside a tmux pane with no terminal of its own would therefore yank
# the captain's terminal onto a fixture window. Observed on 2026-08-09 while
# reproducing this defect: the captain's only client spent the reproduction
# attached to a sandbox session.
#
# So both the action and the refusal are asserted, and the refusal is asserted
# to have CHANGED NOTHING - that is the whole point of it.
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
    tmux select-window -t "$sess:first"
    printf 'window=%s:second\nproject=/p\n' "$sess" >"$state/real-1.meta"

    # No terminal: there is nothing to put on that window, so nothing happens
    # and it says so. The session's current window is the evidence - a refusal
    # that had still run select-window would be the original defect wearing an
    # error message.
    out=$(FM_HOME="$TMP_ROOT/home" "$FLOW" --open real-1 </dev/null 2>&1); rc=$?
    expect_code 1 $rc "--open with no terminal must refuse"
    assert_contains "$out" "not a terminal" "the refusal did not say what was missing"
    active=$(tmux display-message -p -t "$sess" '#{window_name}')
    [ "$active" = "first" ] ||
      fail "a refused --open still moved the session's current window to $active"
    pass "--open with no terminal to show it in refuses and moves nothing"

    # With a real terminal it commits to an action, and which action depends on
    # whether that terminal is already a tmux client. The dry run is the seam:
    # it reports the decision without attaching anything to this test's pty.
    if command -v script >/dev/null 2>&1; then
      dry() {  # <env-assignments...>
        script -qec "env $* FM_HOME='$TMP_ROOT/home' FM_FLOW_OPEN_DRY_RUN=1 '$FLOW' --open real-1" \
          /dev/null 2>/dev/null | tr -d '\r'
      }
      got=$(dry "TMUX=")
      assert_contains "$got" "action=attach" "a terminal outside tmux must be attached, got: $got"
      got=$(dry "TMUX=/tmp/fake,1,0")
      assert_contains "$got" "action=switch" "a terminal already in tmux must be switched, got: $got"
      pass "--open attaches a plain terminal and switches one that is already a tmux client"
    else
      echo "skip: script not found, cannot give --open a terminal"
    fi

    printf 'window=%s:gone\nproject=/p\n' "$sess" >"$state/missing-1.meta"
    out=$(FM_HOME="$TMP_ROOT/home" "$FLOW" --open missing-1 2>&1); rc=$?
    expect_code 1 $rc "--open on a window that does not exist must fail"
    assert_contains "$out" "gone" "the refusal did not name the missing window"
    pass "--open refuses a window that is no longer there"
    tmux kill-server 2>/dev/null
  else
    echo "skip: could not create a private tmux server"
  fi
else
  echo "skip: tmux not found"
fi

# --- the viewer is told what enter will do, in words that fit this terminal ---
#
# Whether enter switches a tmux client or attaches a plain terminal decides how
# the captain gets BACK, and only this script knows which. The viewer must not
# guess, so it is handed the sentence rather than composing one.
: >"$FAKE_TUI_ARGV"
cat >"$mirror/fm-flow-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"schema":"fm-flow-snapshot.v1","generated_epoch":1,"agents":[]}\n'
EOF
chmod +x "$mirror/fm-flow-snapshot.sh"

TMUX='' "$mirror/fm-flow.sh" >/dev/null 2>&1 || fail "the entry point failed with TMUX unset"
hint=$(grep -A1 -- '--open-hint' "$FAKE_TUI_ARGV" | tail -1)
assert_contains "$hint" "attach" "a terminal outside tmux was not told enter attaches"
assert_contains "$hint" "come back" "the hint did not say how to get back"
pass "the viewer is handed the sentence that is true for this terminal"

# --- the drill-in from a row to that agent's own pipeline --------------------
#
# The row states a CI verdict per agent, so the obvious next move is that
# agent's pipeline in detail - and until this existed the only way there was to
# know bin/fm-nm-flow.sh by name and type it. Enter is a different and equally
# useful action and keeps its key, so the drill-in gets its own.

detail=$(grep -A1 -- '--detail-cmd' "$FAKE_TUI_ARGV" | tail -1)
[ -n "$detail" ] || fail "the viewer was given no way into the pipeline detail"
assert_contains "$detail" "--detail" "the drill-in command does not run the detail path"
assert_contains "$detail" "FM_FLOW_ID" "the drill-in command does not name the selected agent"
dhint=$(grep -A1 -- '--detail-hint' "$FAKE_TUI_ARGV" | tail -1)
assert_contains "$dhint" "pipeline" "the drill-in hint does not say what the key shows"
assert_contains "$dhint" "back" "the drill-in hint does not say how to come back"
pass "the viewer is wired to the pipeline detail and told how to come back from it"

out=$(FM_HOME="$TMP_ROOT/home" "$FLOW" --detail ghost-1 2>&1); rc=$?
expect_code 1 $rc "--detail on an unknown task must fail"
assert_contains "$out" "ghost-1" "the refusal did not name the task"
pass "--detail on a task with no local record refuses"

# The dry run is the seam: it proves which command would run without starting a
# watch loop this test would then have to interrupt.
printf 'window=x:1\nproject=/p\nworktree=/wt\n' >"$state/detail-1.meta"
out=$(FM_HOME="$TMP_ROOT/home" FM_FLOW_DETAIL_DRY_RUN=1 "$FLOW" --detail detail-1 2>&1); rc=$?
expect_code 0 $rc "--detail dry run must exit 0"
assert_contains "$out" "detail-1" "the dry run did not name the task"
assert_contains "$out" "fm-nm-flow.sh" "the drill-in does not reuse the existing detail view"
pass "--detail runs the existing per-task pipeline view rather than a second copy of it"

out=$("$FLOW" --detail 2>&1); rc=$?
expect_code 2 $rc "--detail with no value must be a usage error"
out=$("$FLOW" --help)
assert_contains "$out" "--detail" "help does not document --detail"
pass "--detail is documented and refuses a missing task id"
