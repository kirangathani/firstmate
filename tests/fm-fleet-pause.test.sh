#!/usr/bin/env bash
# tests/fm-fleet-pause.test.sh - bin/fm-fleet-pause.sh, the captain's fleet
# pause, and the suppression its record buys through bin/fm-ack-lib.sh's
# fm_supervision_suspended.
#
# The watcher's own behaviour under the record (no signal, turn-end, or stale
# wake while paused, and a wake again once resumed) is in fm-watch-triage.test.sh
# beside the captain-driven cases it mirrors.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-pause-tests)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# The captain-driven exclusion reads the attached tmux clients; without the fake
# its verdict would be whatever window the operator is looking at.
fm_fake_tmux_clients "$FAKEBIN"
PATH="$FAKEBIN:$PATH"
export PATH

# A send owner that records each call, and whether the target's record already
# existed when the instruction went out. FM_FAKE_SEND_FAIL names a target whose
# send fails, the way a dead endpoint does.
cat > "$FAKEBIN/fake-send" <<'SH'
#!/usr/bin/env bash
set -u
if [ -f "$FM_STATE_OVERRIDE/$1.captain-pause" ]; then rec=record; else rec=norecord; fi
printf '%s\t%s\t%s\n' "$1" "$rec" "$2" >> "$FM_FAKE_SEND_LOG"
if [ "$1" = "${FM_FAKE_SEND_FAIL:-}" ]; then
  echo "error: endpoint for $1 is gone" >&2
  exit 1
fi
exit 0
SH
chmod +x "$FAKEBIN/fake-send"

# shellcheck source=bin/fm-ack-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-ack-lib.sh"

make_home() {  # <name> <id>... -> home dir with one meta per id
  local home="$TMP_ROOT/$1" id
  shift
  mkdir -p "$home/state" "$home/config"
  : > "$home/clients"
  for id in "$@"; do
    fm_write_meta "$home/state/$id.meta" "window=sess:fm-$id" "kind=ship"
  done
  printf '%s\n' "$home"
}

fleet_pause() {  # <home> <args...>
  local home=$1
  shift
  env -u FM_ACK_SECRET_FILE FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_TMUX_CLIENTS="$home/clients" \
    FM_FAKE_SEND_LOG="$home/sends" FM_FLEET_PAUSE_SEND_BIN="$FAKEBIN/fake-send" \
    "$ROOT/bin/fm-fleet-pause.sh" "$@"
}

sent_to() {  # <home> -> sorted target ids
  cut -f1 "$1/sends" 2>/dev/null | sort | tr '\n' ' '
}

test_pause_with_no_ids_covers_every_meta_and_records_before_sending() {
  local home id
  home=$(make_home all a b c d e f g h i j)
  fleet_pause "$home" pause >/dev/null || fail "pause with no ids failed"
  for id in a b c d e f g h i j; do
    [ -f "$home/state/$id.captain-pause" ] || fail "a direct report with a record was not paused"
  done
  [ "$(sent_to "$home")" = "a b c d e f g h i j " ] || fail "the pause instruction did not reach every direct report: $(sent_to "$home")"
  grep -F "norecord" "$home/sends" >/dev/null && fail "an instruction went out before its record existed"
  pass "pause with no ids targets every recorded direct report and writes each record before its send"
}

test_except_leaves_the_named_workers_running() {
  local home
  home=$(make_home except a b c d)
  fleet_pause "$home" pause --except b d >/dev/null || fail "pause --except failed"
  [ -f "$home/state/a.captain-pause" ] && [ -f "$home/state/c.captain-pause" ] || fail "a worker not excepted was left running"
  [ -e "$home/state/b.captain-pause" ] || [ -e "$home/state/d.captain-pause" ] && fail "an excepted worker was paused"
  [ "$(sent_to "$home")" = "a c " ] || fail "the instruction went to an excepted worker: $(sent_to "$home")"
  pass "pause --except pauses everything but the named workers"
}

test_named_ids_pause_only_those() {
  local home
  home=$(make_home named a b c)
  fleet_pause "$home" pause b >/dev/null || fail "pause with an id failed"
  [ -f "$home/state/b.captain-pause" ] || fail "the named worker was not paused"
  [ -e "$home/state/a.captain-pause" ] || [ -e "$home/state/c.captain-pause" ] && fail "a worker that was not named was paused"
  pass "pause with ids pauses only the named workers"
}

test_an_unknown_id_refuses_before_writing_anything() {
  local home
  home=$(make_home unknown a b)
  fleet_pause "$home" pause --except typo >/dev/null 2>&1 && fail "an unknown excepted id did not refuse"
  [ -e "$home/state/a.captain-pause" ] && fail "a refused command still paused a worker"
  [ -e "$home/sends" ] && fail "a refused command still sent an instruction"
  pass "an id this home has no record of refuses the whole command before anything is written"
}

test_a_captain_driven_worker_is_skipped() {
  local home out
  home=$(make_home driven a b)
  fm_fake_tmux_client_row "$home/clients" "sess:fm-a" "$(date +%s)"
  out=$(fleet_pause "$home" pause) || fail "pause failed with a captain-driven worker in the fleet"
  [ -e "$home/state/a.captain-pause" ] && fail "a worker the captain is driving was paused"
  [ -f "$home/state/b.captain-pause" ] || fail "the other worker was not paused"
  printf '%s' "$out" | grep -F "skipped: a" >/dev/null || fail "the skip was not reported: $out"
  pass "a worker the captain is driving himself is skipped and reported"
}

test_a_failed_send_is_one_line_and_nothing_is_verified() {
  local home out
  home=$(make_home failed a b c)
  out=$(FM_FAKE_SEND_FAIL=b fleet_pause "$home" pause) || fail "a failed send made the whole pause fail"
  [ "$(printf '%s\n' "$out" | grep -c '^send failed: b')" = 1 ] || fail "the failed send was not reported in exactly one line: $out"
  [ -f "$home/state/b.captain-pause" ] || fail "a failed send dropped the record, so that worker would still notify"
  # One call per worker and nothing else: no retry, no peek, no second look.
  [ "$(wc -l < "$home/sends" | tr -d ' ')" = 3 ] || fail "the pause made more than one call per worker: $(cat "$home/sends")"
  pass "a failed send is reported in one line, the record stands, and nothing is retried or verified"
}

test_a_paused_worker_owes_nothing_and_alarms_again_after_resume() {
  local home rows
  home=$(make_home owed a)
  printf 'needs-decision: pick A or B\n' > "$home/state/a.status"
  export FM_ACK_SECRET_FILE="$home/config/absent-key" FM_FAKE_TMUX_CLIENTS="$home/clients"
  rows=$(FM_ACK_CONFIRM_MAX=0 FM_ACK_NO_CACHE=1 fm_ack_unactioned "$home/state" 0)
  [ -n "$rows" ] || fail "the fixture does not alarm before the pause, so the case proves nothing"
  fleet_pause "$home" pause >/dev/null || fail "pause failed"
  fm_supervision_suspended "$home/state" a || fail "a paused worker did not read as suspended"
  [ "$FM_SUSPENDED_SOURCE" = captain-pause ] || fail "the suspension did not name the captain's pause: $FM_SUSPENDED_SOURCE"
  rows=$(FM_ACK_CONFIRM_MAX=0 FM_ACK_NO_CACHE=1 fm_ack_unactioned "$home/state" 0)
  [ -z "$rows" ] || fail "a paused worker still alarmed: $rows"
  fleet_pause "$home" resume >/dev/null || fail "resume failed"
  rows=$(FM_ACK_CONFIRM_MAX=0 FM_ACK_NO_CACHE=1 fm_ack_unactioned "$home/state" 0)
  [ -n "$rows" ] || fail "supervision did not resume after the resume"
  unset FM_ACK_SECRET_FILE FM_FAKE_TMUX_CLIENTS
  pass "a paused worker owes nothing to the alarm and turn-end guards, and alarms again once resumed"
}

test_resume_with_no_ids_reaches_every_paused_worker() {
  local home id
  home=$(make_home resume a b c d e f g h i j)
  fleet_pause "$home" pause >/dev/null || fail "pause failed"
  : > "$home/sends"
  fleet_pause "$home" resume >/dev/null || fail "resume failed"
  for id in a b c d e f g h i j; do
    [ -e "$home/state/$id.captain-pause" ] && fail "a paused worker was left paused by a resume with no ids"
  done
  [ "$(sent_to "$home")" = "a b c d e f g h i j " ] || fail "the resume instruction did not reach every paused worker: $(sent_to "$home")"
  pass "resume with no ids clears and messages every paused worker"
}

test_resume_tells_a_waiting_worker_what_it_was_waiting_on() {
  local home
  home=$(make_home waiting a b)
  printf 'paused: waiting on the parent branch fm/base to land\n' > "$home/state/a.status"
  printf 'working: implementing\n' > "$home/state/b.status"
  fleet_pause "$home" pause >/dev/null || fail "pause failed"
  # Whatever the worker says while paused must not replace what it was doing.
  printf 'paused: captain ordered a pause\n' >> "$home/state/a.status"
  fleet_pause "$home" pause a >/dev/null || fail "re-pause failed"
  : > "$home/sends"
  fleet_pause "$home" resume >/dev/null || fail "resume failed"
  grep "^a" "$home/sends" | grep -F "waiting on the parent branch fm/base to land" >/dev/null \
    || fail "a worker waiting on a parent branch was not told so on resume: $(cat "$home/sends")"
  grep "^b" "$home/sends" | grep -F "Before the pause" >/dev/null \
    && fail "a worker that was not waiting was told it was"
  pass "resume reaches a worker waiting on a parent branch and repeats its own pre-pause wait back to it"
}

test_status_and_session_start_list_paused_workers() {
  local home out
  home=$(make_home listed a b c)
  fleet_pause "$home" pause --except c >/dev/null || fail "pause failed"
  out=$(fleet_pause "$home" status) || fail "status failed"
  [ "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" = "a b " ] || fail "status did not list exactly the paused workers: $out"
  out=$(env -u FM_ACK_SECRET_FILE FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_FAKE_TMUX_CLIENTS="$home/clients" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  [ "$(printf '%s\n' "$out" | grep -c '^CAPTAIN_PAUSED: a b ')" = 1 ] \
    || fail "session start did not list the paused workers on one line: $out"
  pass "status and the session-start digest both list every paused worker"
}

# shellcheck disable=SC2016 # The patterns are literal source text, not expansions.
test_teardown_removes_the_record() {
  grep -F '"$STATE/$ID.captain-pause"' "$ROOT/bin/fm-teardown.sh" >/dev/null \
    || fail "teardown does not remove a task's pause record"
  grep -F '"$sub_state/$child_id.captain-pause"' "$ROOT/bin/fm-teardown.sh" >/dev/null \
    || fail "teardown does not remove a secondmate child's pause record"
  pass "teardown removes the pause record with the rest of the task's state"
}

test_pause_with_no_ids_covers_every_meta_and_records_before_sending
test_except_leaves_the_named_workers_running
test_named_ids_pause_only_those
test_an_unknown_id_refuses_before_writing_anything
test_a_captain_driven_worker_is_skipped
test_a_failed_send_is_one_line_and_nothing_is_verified
test_a_paused_worker_owes_nothing_and_alarms_again_after_resume
test_resume_with_no_ids_reaches_every_paused_worker
test_resume_tells_a_waiting_worker_what_it_was_waiting_on
test_status_and_session_start_list_paused_workers
test_teardown_removes_the_record
