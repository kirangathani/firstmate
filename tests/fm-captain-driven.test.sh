#!/usr/bin/env bash
# tests/fm-captain-driven.test.sh - the predicate behind "the captain is driving
# this worker himself, so firstmate neither alarms on it nor watches it".
#
# Two halves, two owners. bin/fm-captain-driven-lib.sh reads a human tmux client
# sitting in the task's window; bin/fm-ack-lib.sh's fm_captain_driven ORs that
# with the captain's own signed record and is what every supervision surface
# asks. docs/captain-driven.md owns the contract and the measurement behind it.
#
# The watcher's behaviour under this predicate is in fm-watch-triage.test.sh, and
# the unactioned-alarm classes it feeds are in fm-unactioned-guard.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-driven-tests)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

fm_fake_tmux_clients "$FAKEBIN"
PATH="$FAKEBIN:$PATH"
export PATH

# shellcheck source=bin/fm-ack-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-ack-lib.sh"

# The library's own default, read at run time rather than written down here: a
# boundary case sized from a copy of the limit stops testing the limit the
# moment somebody changes it.
GRACE=$FM_CAPTAIN_DRIVEN_GRACE_DEFAULT
NOW=1789646192

make_case() {  # <name> -> case dir with state/ and a clients file
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  : > "$dir/clients"
  printf '%s\n' "$dir"
}

# One attached client, viewing <target>, last keystroke <epoch>.
attach() {  # <dir> <target> <epoch>
  fm_fake_tmux_client_row "$1/clients" "$2" "$3"
}

drive() {  # <dir> <id> -> run fm_captain_attached under the frozen clock
  FM_FAKE_TMUX_CLIENTS="$1/clients" FM_CAPTAIN_DRIVEN_NOW=$NOW \
    fm_captain_attached "$1/state" "$2"
}

# Each call gets a clean memo: the library caches the client list for the
# current second, and these cases hold the clock still on purpose.
reset_memo() { _FM_CAPTAIN_CLIENTS=; _FM_CAPTAIN_CLIENTS_AT=; }

test_a_client_in_the_window_is_the_captain_driving() {
  local dir
  dir=$(make_case attached)
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship"
  attach "$dir" "sess:fm-task" "$NOW"
  reset_memo
  drive "$dir" task || fail "a client sitting in the task's window did not read as captain-driven"
  case "$FM_CAPTAIN_ATTACHED_REASON" in
    *"its window"*) ;;
    *) fail "the reason did not say the captain is in the window: $FM_CAPTAIN_ATTACHED_REASON" ;;
  esac
  pass "a tmux client viewing a task's window makes it captain-driven, with a reason that says so"
}

test_a_client_in_another_window_is_not() {
  local dir
  dir=$(make_case elsewhere)
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship"
  attach "$dir" "sess:fm-other" "$NOW"
  reset_memo
  drive "$dir" task && fail "a client viewing a DIFFERENT window silenced supervision of this one"
  pass "a client viewing another window leaves this task supervised"
}

test_a_client_matches_by_index_and_by_window_id() {
  local dir
  dir=$(make_case spellings)
  fm_write_meta "$dir/state/by-index.meta" "window=sess:9" "kind=ship"
  fm_write_meta "$dir/state/by-id.meta" "window=@9" "kind=ship"
  attach "$dir" "sess:fm-task" "$NOW"
  reset_memo
  drive "$dir" by-index || fail "a target recorded as session:index did not match the attached client"
  reset_memo
  drive "$dir" by-id || fail "a target recorded as a window id did not match the attached client"
  pass "a recorded target matches the attached client by name, by index, or by window id"
}

# The grace only covers a window left SELECTED while the captain is away from
# the keyboard; leaving the window drops it at once, which the case above holds.
test_the_grace_ends_the_sitting() {
  local dir inside outside
  dir=$(make_case grace)
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship"
  inside=$((NOW - GRACE + 1))
  outside=$((NOW - GRACE))
  attach "$dir" "sess:fm-task" "$inside"
  reset_memo
  drive "$dir" task || fail "a keystroke inside the grace window did not count as the captain driving"
  attach "$dir" "sess:fm-task" "$outside"
  reset_memo
  if drive "$dir" task; then
    printf 'grace=%s last-keystroke=%s now=%s\n' "$GRACE" "$outside" "$NOW"
    fail "a keystroke at the full grace age still counted as the captain driving"
  fi
  pass "a sitting lasts exactly the documented grace after the last keystroke, then supervision resumes"
}

test_a_task_with_no_tmux_window_is_never_attached_driven() {
  local dir
  dir=$(make_case no-window)
  fm_write_meta "$dir/state/herdr-task.meta" "window=lab:w1:p2" "backend=herdr" "kind=ship"
  fm_write_meta "$dir/state/no-window.meta" "kind=ship"
  attach "$dir" "lab:w1:p2" "$NOW"
  reset_memo
  drive "$dir" herdr-task && fail "a non-tmux task read as attached-driven from a tmux client list"
  reset_memo
  drive "$dir" no-window && fail "a task with no recorded window read as attached-driven"
  reset_memo
  drive "$dir" never-dispatched && fail "a task with no record at all read as attached-driven"
  pass "a task on another backend, with no window, or with no record is never attached-driven"
}

# The signed record is the half that outlives a sitting, and it wins when both
# hold because it carries the captain's own stated reason.
test_the_signed_record_wins_and_outlives_the_sitting() {
  local dir out
  dir=$(make_case signed)
  mkdir -p "$dir/config"
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$dir/config/ci-waiver-secret"
  chmod 600 "$dir/config/ci-waiver-secret"
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship"
  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" "$ROOT/bin/fm-monitor.sh" \
    --exempt task --reason "I am driving this one" 2>&1) \
    || fail "minting the captain's own record failed: $out"

  # Nobody attached: the record alone is the whole verdict.
  reset_memo
  FM_ACK_SECRET_FILE="$dir/config/ci-waiver-secret" FM_FAKE_TMUX_CLIENTS="$dir/clients" \
    FM_CAPTAIN_DRIVEN_NOW=$NOW fm_captain_driven "$dir/state" task \
    || fail "a signed record did not make the task captain-driven with nobody attached"
  [ "$FM_CAPTAIN_DRIVEN_SOURCE" = signed ] || fail "the verdict did not name the signed record as its source: $FM_CAPTAIN_DRIVEN_SOURCE"
  [ "$FM_CAPTAIN_DRIVEN_REASON" = "I am driving this one" ] || fail "the verdict did not carry the captain's own stated reason: $FM_CAPTAIN_DRIVEN_REASON"

  # Attached as well: the record still wins, because its reason is his words.
  attach "$dir" "sess:fm-task" "$NOW"
  reset_memo
  FM_ACK_SECRET_FILE="$dir/config/ci-waiver-secret" FM_FAKE_TMUX_CLIENTS="$dir/clients" \
    FM_CAPTAIN_DRIVEN_NOW=$NOW fm_captain_driven "$dir/state" task \
    || fail "a signed record plus an attached client did not read as captain-driven"
  [ "$FM_CAPTAIN_DRIVEN_SOURCE" = signed ] || fail "an attached client outranked the captain's own signed record"

  # And the record is what a sweep and a session start report.
  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" "$ROOT/bin/fm-monitor.sh" --list-exempt 2>&1)
  printf '%s' "$out" | grep -F "I am driving this one" >/dev/null \
    || fail "the standing record was not listed with its reason: $out"
  pass "the captain's signed record is captain-driven on its own, outranks a sitting, and is listed with his reason"
}

test_an_attached_task_is_captain_driven_without_any_record() {
  local dir
  dir=$(make_case no-record)
  mkdir -p "$dir/config"
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship"
  attach "$dir" "sess:fm-task" "$NOW"
  reset_memo
  FM_ACK_SECRET_FILE="$dir/config/ci-waiver-secret" FM_FAKE_TMUX_CLIENTS="$dir/clients" \
    FM_CAPTAIN_DRIVEN_NOW=$NOW fm_captain_driven "$dir/state" task \
    || fail "a task with a client in its window needed a command to become captain-driven"
  [ "$FM_CAPTAIN_DRIVEN_SOURCE" = attached ] || fail "the verdict did not name the sitting as its source: $FM_CAPTAIN_DRIVEN_SOURCE"
  : > "$dir/clients"
  reset_memo
  FM_ACK_SECRET_FILE="$dir/config/ci-waiver-secret" FM_FAKE_TMUX_CLIENTS="$dir/clients" \
    FM_CAPTAIN_DRIVEN_NOW=$NOW fm_captain_driven "$dir/state" task \
    && fail "the task stayed captain-driven after the captain detached"
  pass "sitting in a window is captain-driven with no command and no key, and ends when the captain leaves"
}

# The reading must not be defeated by the fleet's own noise, which is what
# docs/captain-driven.md's measurement establishes for the real tmux. Here the
# same rule is held at the predicate: a client list this home cannot read at all
# means nobody is attached, never everybody.
test_an_unreadable_client_list_leaves_every_task_supervised() {
  local dir
  dir=$(make_case unreadable)
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship"
  reset_memo
  FM_FAKE_TMUX_CLIENTS="$dir/nonexistent" FM_CAPTAIN_DRIVEN_NOW=$NOW \
    fm_captain_attached "$dir/state" task \
    && fail "an unreadable client list silenced supervision"
  reset_memo
  FM_FAKE_TMUX_CLIENTS="$dir/clients" FM_CAPTAIN_DRIVEN_NOW=$NOW \
    PATH="$TMP_ROOT/no-tmux-here:$PATH" fm_captain_attached "$dir/state" task \
    && fail "a host with no tmux at all silenced supervision"
  pass "an unreadable client list, or no tmux at all, leaves every task supervised"
}

# The blind spot has to be visible. The signed record's own announcement is
# held by fm-unactioned-guard.test.sh; this is the half reached with no record,
# which is the easier one to leave silent because nothing was ever written down.
test_session_start_and_the_sweep_name_a_task_the_captain_is_sitting_in() {
  local dir out
  dir=$(make_case announced)
  mkdir -p "$dir/config"
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship"
  printf 'needs-decision: which shape?\n' > "$dir/state/task.status"
  attach "$dir" "sess:fm-task" "$(date +%s)"

  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_FAKE_TMUX_CLIENTS="$dir/clients" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  printf '%s' "$out" | grep -F "MONITOR_EXEMPT: task" >/dev/null \
    || fail "session start did not announce a task the captain is sitting in: $out"
  printf '%s' "$out" | grep -F "its window" >/dev/null \
    || fail "the session-start announcement did not say why the task is the captain's: $out"

  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_FAKE_TMUX_CLIENTS="$dir/clients" \
    FM_CREW_STATE_BIN="$dir/absent-crew-state" "$ROOT/bin/fm-monitor.sh" --quiet 2>&1 || true)
  printf '%s' "$out" | grep -F "CAPTAIN-DRIVEN" >/dev/null \
    || fail "the sweep did not name the task the captain is sitting in: $out"
  printf '%s' "$out" | grep -F "captain-driven 1" >/dev/null \
    || fail "the sweep did not count the task as captain-driven: $out"
  printf '%s' "$out" | grep -F "needs-action 1" >/dev/null \
    && fail "the sweep still counted a captain-driven task as needing action: $out"
  pass "a task the captain is merely sitting in is named on the sweep and at session start, with its reason"
}

test_a_client_in_the_window_is_the_captain_driving
test_a_client_in_another_window_is_not
test_a_client_matches_by_index_and_by_window_id
test_the_grace_ends_the_sitting
test_a_task_with_no_tmux_window_is_never_attached_driven
test_the_signed_record_wins_and_outlives_the_sitting
test_an_attached_task_is_captain_driven_without_any_record
test_an_unreadable_client_list_leaves_every_task_supervised
test_session_start_and_the_sweep_name_a_task_the_captain_is_sitting_in
