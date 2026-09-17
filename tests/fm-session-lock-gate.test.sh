#!/usr/bin/env bash
# tests/fm-session-lock-gate.test.sh - the SESSION lock (state/.lock) decides
# which session controls a home's fleet, and this suite pins the places that
# consume that decision:
#   bin/fm-session-lock-lib.sh  the single ownership resolver (ancestry walk)
#   bin/fm-lock.sh ownership    the read-only entry point the OpenCode and Pi
#                               adapters call instead of their own copies
#   bin/fm-watch-arm.sh         refuses to arm from a session that does not own
#                               the fleet, and still arms for one that does
#   bin/fm-watch-checkpoint.sh  Codex's bounded foreground protocol, the second
#                               entry point that takes the watcher singleton
#   bin/fm-statusline.sh        the persistent in/not-in-control indicator,
#                               composed beneath the operator's own status line
#
# The regression these guard: before the gate existed, only the OpenCode and Pi
# adapters checked ownership. A second Claude Code session could arm a watcher
# for a home whose session lock named a different session, take the watcher
# singleton, and supervise a fleet it was not responsible for while the owning
# session's arm quietly attached to it.
#
# state/.lock (session lock) and state/.watch.lock (watcher singleton) are
# different locks with similar names; assertions here name which one they mean.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
WATCH_CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
LOCK_CLI="$ROOT/bin/fm-lock.sh"
STATUSLINE="$ROOT/bin/fm-statusline.sh"

# The kernel start ticks that identify a lock holder are Linux-only (/proc), and
# every code path treats them as optional. Where they are unavailable, the
# pid-reuse assertions below do not apply and the legacy pid-only behavior is
# what is asserted instead.
start_ticks_available() {
  [ -r "/proc/$$/stat" ]
}

TMP_ROOT=$(fm_test_tmproot fm-session-lock-gate)

# The watcher's one-shot PR-check migration would otherwise run inside these
# fixtures; the watcher-lock suite marks it complete the same way.
mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

# A live process that is NOT in this test's ancestry, standing in for a rival
# firstmate session that holds the session lock.
start_other_session() {
  # Both output descriptors are redirected: this runs inside a command
  # substitution, and a background job holding that pipe open would block the
  # substitution until the sleep finished.
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

watch_singleton_present() {
  local state=$1
  [ -L "$state/.watch.lock" ] || [ -e "$state/.watch.lock" ]
}

# Used only where the arm is expected to REFUSE, so it must return immediately.
# The bound keeps an ungated arm (which would sit in a real watcher cycle
# waiting for a wake that never comes) a fast, legible failure.
run_arm_foreground() {  # <state> [args...]
  local state=$1
  shift
  timeout 30 env PATH="$(dirname "$state")/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=2 \
    "$WATCH_ARM" "$@" 2>&1
}

# Arm in the background and wait for it to report a started watcher; echoes the
# arm pid. Used where the arm is expected to pass the gate and keep running.
start_arm_background() {  # <state> <output file>
  local state=$1 out=$2 armpid i
  PATH="$(dirname "$state")/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 \
    "$WATCH_ARM" > "$out" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$armpid"
}

stop_arm_background() {  # <arm pid> <state>
  local armpid=$1 state=$2 watcher
  watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -TERM "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  [ -n "$watcher" ] && kill -TERM "$watcher" 2>/dev/null
  return 0
}

# --- bin/fm-lock.sh ownership -----------------------------------------------

test_ownership_cli_classifies_and_writes_nothing() {
  local dir state other out
  dir="$TMP_ROOT/ownership-cli"
  state="$dir/state"
  mkdir -p "$dir"

  # Absent state dir: the query must classify, never create anything.
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership) \
    || fail "fm-lock.sh ownership must always exit 0"
  [ "$out" = missing ] || fail "absent session lock must classify as missing, got: $out"
  [ ! -d "$state" ] || fail "fm-lock.sh ownership created the state dir; it must be read-only"

  mkdir -p "$state"
  printf '%s\n' "$$" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = owned ] || fail "session lock naming an ancestor must classify as owned, got: $out"

  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ "$out" = other ] || fail "a live non-ancestor holder must classify as other, got: $out"

  printf '%s\n' "$(dead_pid)" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = missing ] || fail "a dead holder must classify as missing, got: $out"

  printf 'not-a-pid\n' > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = missing ] || fail "a malformed session lock must classify as missing, got: $out"

  pass "fm-lock.sh ownership: classifies owned/other/missing and never writes state"
}

test_lock_holder_identity_and_file_format() {
  local dir state other out ticks
  dir="$TMP_ROOT/lock-identity"
  state="$dir/state"
  mkdir -p "$state"

  # A lock whose only line carries NO trailing newline still names a holder.
  # Validating on read's exit status instead of the parsed value read it as
  # "missing", which would arm over a live rival owner.
  other=$(start_other_session)
  printf '%s' "$other" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = other ] || fail "a newline-free session lock must still name its holder, got: $out"

  # A LEGACY pid-only lock (no recorded ticks) keeps working on the pid alone.
  printf '%s\n' "$other" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = other ] || fail "a legacy pid-only lock must still resolve a live rival as other, got: $out"
  printf '%s\n' "$$" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
  [ "$out" = owned ] || fail "a legacy pid-only lock must still resolve an ancestor as owned, got: $out"

  if start_ticks_available; then
    ticks=$(bash -c '. "$1"; fm_pid_start_ticks "$2"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$$") \
      || fail "could not read this process's start ticks"
    printf '%s\n%s\n' "$$" "$ticks" > "$state/.lock"
    out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
    [ "$out" = owned ] || fail "matching start ticks must still resolve as owned, got: $out"

    # The pid is live, but the kernel says it started at a different time, so it
    # is a REUSED pid rather than the session that took the lock. That must read
    # as a stale lock, not as a live rival: refusing there would leave the home
    # unsupervised with the blind-turn alarm silenced.
    printf '%s\n%s\n' "$other" 1 > "$state/.lock"
    out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" ownership)
    [ "$out" = missing ] || fail "a live pid with mismatched start ticks must resolve as missing, got: $out"
  fi

  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  pass "fm-session-lock-lib: holder identity is pid plus optional start ticks, parsed from the value not the read status"
}

# --- bin/fm-lock.sh acquire refusal and argument handling --------------------

# bin/fm-lock.sh acquire asks TWO questions the ownership walk does not: which
# process to record (fm_session_harness_pid, an upward walk for a harness), and
# whether the current holder is a harness. A suite process has no harness
# ancestor of its own, so these cases shadow `ps` with a stub that reports every
# queried pid as a live `claude` and refuses `ppid=` - the same stub shape
# tests/fm-session-start.test.sh and tests/fm-grok-harness.test.sh use. Refusing
# `ppid=` stops the ancestry walk at the caller, which is what makes the rival
# below a NON-ancestor deterministically rather than by luck of the pid tree.
install_fake_ps_claude() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_lock_refusal_describes_the_holder_and_names_a_remedy() {
  local dir state other out status
  # Before this, the refusal said only "another live firstmate session holds the
  # lock (pid N)", which left the captain with a bare number and no way to tell a
  # rival session from an ancestor of this one - the question the 2026-09-15
  # lock-loss incident turned on. Every surface that has to explain a refusal now
  # prints bin/fm-session-lock-lib.sh's one description and one remedy.
  dir=$(make_case lock-refusal-description)
  state="$dir/state"
  install_fake_ps_claude "$dir/fakebin"
  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK_CLI" 2>&1); status=$?
  expect_code 1 "$status" "acquiring over a live rival holder must still fail"
  assert_contains "$out" "another live firstmate session holds the lock" \
    "the refusal must still say a live session holds the lock"
  assert_contains "$out" "pid $other" "the refusal must name the exact holder pid"
  assert_contains "$out" "is not an ancestor of this process" \
    "the refusal must say whether the holder is an ancestor of this session"
  assert_contains "$out" "bin/fm-session-start.sh" "the refusal must name the remedy command"
  [ "$(cat "$state/.lock")" = "$other" ] || fail "a refused acquire rewrote the lock"

  # The same description reaches `status`, which previously could not tell a
  # rival from an ancestor either.
  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK_CLI" status); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "fm-lock.sh status must always exit 0"
  assert_contains "$out" "lock: held by live harness pid $other" \
    "status must still report a live harness holder the way every caller reads it"
  assert_contains "$out" "is not an ancestor of this process" \
    "status must say whether the holder is an ancestor of this session"
  assert_contains "$out" "bin/fm-session-start.sh" "status must name the remedy for a rival holder"
  pass "fm-lock.sh: the acquire refusal and status share one holder description and one remedy"
}

test_lock_rejects_unknown_arguments_without_touching_state() {
  local dir state arg out status
  # `fm-lock.sh --help` used to fall through to ACQUIRE, because the verb list
  # was a two-way test: it created state/ and tried to take the lock. It was run
  # for real during the 2026-09-15 incident, while the home was already in
  # trouble.
  dir="$TMP_ROOT/lock-unknown-args"
  state="$dir/state"
  mkdir -p "$dir"

  for arg in --help -h help bogus ownershipp; do
    out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" "$arg" 2>&1); status=$?
    expect_code 2 "$status" "fm-lock.sh $arg must exit 2, never attempt an acquisition"
    assert_contains "$out" "Usage: fm-lock.sh" "fm-lock.sh $arg must print the usage"
    assert_contains "$out" "ownership" "the usage must list the read-only ownership verb"
    assert_not_contains "$out" "lock acquired" "fm-lock.sh $arg must not acquire the lock"
    [ ! -d "$state" ] || fail "fm-lock.sh $arg created the state dir"
    [ ! -e "$state/.lock" ] || fail "fm-lock.sh $arg wrote a lock"
  done
  pass "fm-lock.sh: an unknown argument prints the usage and exits 2, creating nothing"
}

test_take_over_refuses_a_pid_that_is_not_the_recorded_holder() {
  local dir state holder out status recorded
  # take-over is the captain displacing one NAMED session, so it refuses every
  # pid but the one on record. That is what stops it being run blind: the holder
  # has to have been read first, and a holder that changed since that read is a
  # different situation than the one the captain decided about.
  dir=$(make_case lock-take-over-refuses)
  state="$dir/state"
  holder=$(start_other_session)
  printf '%s\n' "$holder" > "$state/.lock"

  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" take-over $((holder + 1)) 2>&1); status=$?
  expect_code 1 "$status" "take-over of a pid that does not hold the lock must fail"
  assert_contains "$out" "does not hold this lock" "the refusal must say the named pid is not the holder"
  assert_contains "$out" "pid $holder" "the refusal must name the holder actually on record"
  recorded=$(sed -n '1p' "$state/.lock")
  [ "$recorded" = "$holder" ] || fail "a refused take-over rewrote the lock: $recorded"

  # No pid at all, and a non-numeric one, are usage errors rather than attempts:
  # exit 2 like every other malformed invocation, and nothing written.
  for out in '' abc 12x; do
    status=0
    FM_STATE_OVERRIDE="$state" "$LOCK_CLI" take-over $out >/dev/null 2>&1 || status=$?
    expect_code 2 "$status" "a malformed take-over argument must exit 2"
  done
  recorded=$(sed -n '1p' "$state/.lock")
  [ "$recorded" = "$holder" ] || fail "a malformed take-over rewrote the lock: $recorded"

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-lock.sh: take-over refuses any pid but the recorded holder, and writes nothing when it does"
}

test_take_over_records_this_session_and_names_what_it_displaced() {
  local dir state holder hpid out recorded
  # The sanctioned way out of a rival holder the captain knows is not managing
  # this fleet. It records THIS session's own harness process, exactly as an
  # ordinary acquire would, so the home is owned by something that outlives the
  # tool call that ran the command.
  dir=$(make_case lock-take-over-succeeds)
  state="$dir/state"
  holder=$(start_other_session)
  printf '%s\n' "$holder" > "$state/.lock"

  hpid=$(start_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
'$LOCK_CLI' take-over $holder > '$dir/takeover.out' 2>&1
'$LOCK_CLI' ownership > '$dir/ownership.out' 2>&1
")
  wait_for_chain "$dir" || { stop_harness "$hpid"; kill "$holder" 2>/dev/null; fail "the take-over chain never finished"; }
  out=$(cat "$dir/takeover.out")
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  stop_harness "$hpid"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  assert_contains "$out" "lock taken over: harness pid $hpid" \
    "take-over must record this session's own harness process"
  assert_contains "$out" "displaced" "take-over must say what it displaced"
  assert_contains "$out" "pid $holder" "take-over must name the holder it displaced"
  [ "$recorded" = "$hpid" ] || fail "the lock must name the taking-over harness $hpid, got: $recorded"
  [ "$(cat "$dir/ownership.out")" = owned ] \
    || fail "the session that took over must read owned, got: $(cat "$dir/ownership.out")"
  pass "fm-lock.sh: take-over records this session and names the holder it displaced"
}

test_every_remedy_offers_the_take_over_as_its_second_half() {
  local dir state rival out
  # One owner for that string (fm_session_lock_remedy), so the acquire refusal
  # and status cannot drift apart or offer a command the reader cannot run: the
  # remedy carries the holder's pid because take-over refuses every other pid.
  # The rival is a real version-named harness rather than a bare sleep, because
  # the remedy is printed only for a holder that is LIVE and harness-shaped; a
  # sleep reads as stale and never reaches it.
  dir=$(make_case lock-remedy-take-over)
  state="$dir/state"
  rival=$(start_versioned_harness "$dir/rival" "true")
  wait_for_chain "$dir/rival" || { stop_harness "$rival"; fail "the rival harness never started"; }
  write_lock_for "$state" "$rival"

  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" status 2>&1)
  assert_contains "$out" "bin/fm-lock.sh take-over $rival" \
    "status must offer the take-over naming the holder it would displace"
  assert_contains "$out" "captain only" "the remedy must mark the take-over as the captain's"
  assert_contains "$out" "bin/fm-session-start.sh" "the remedy must keep naming the ordinary way out first"

  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" 2>&1 || true)
  assert_contains "$out" "bin/fm-lock.sh take-over $rival" \
    "the acquire refusal must offer the same take-over, naming the same holder"

  stop_harness "$rival"
  pass "fm-lock.sh: the remedy offers the captain-only take-over, naming the holder it would displace"
}

# --- what fm-session-lock-lib.sh accepts as a harness -------------------------

# Start one process from a fake VERSIONED Claude install, running <body> one
# shell level below itself and then staying alive so the recorded holder is still
# live when the caller asserts. Echoes the harness pid; the caller kills it.
#
# The shape is the incident's own, captured by the scout from the real processes
# and reproduced here with a copy of bash: comm is the VERSION string
# (`2.1.273`), while argv0 and /proc/<pid>/exe both sit under a directory named
# `claude`. That is what a Claude Code session launched by its own daemon looks
# like, and what the acquire walk could not see. The launch scrubs CLAUDE_PID for
# the whole chain, so the operator's own session cannot leak into the fixture.
start_versioned_harness() {  # <dir> <body>
  local dir=$1 body=$2 bin
  bin="$dir/claude/versions/2.1.273"
  mkdir -p "$dir/claude/versions"
  cp /bin/bash "$bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$body"
    printf 'touch "%s/chain.done"\n' "$dir"
  } > "$dir/chain.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'bash "%s/chain.sh"\n' "$dir"
    printf 'sleep 300\n'
  } > "$dir/harness-body.sh"
  env -u CLAUDE_PID "$bin" "$dir/harness-body.sh" \
    --session-id 00000000-0000-4000-8000-000000000000 --fork-session >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

wait_for_chain() {  # <dir>
  local dir=$1 i=0
  while [ "$i" -lt 150 ]; do
    [ -e "$dir/chain.done" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_harness() {  # <pid>
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
  return 0
}

# A live process shaped like a Claude Code BASH TOOL SHELL. The argument string
# is the real one, captured on 2026-09-15 from this repo's own crewmate session
# (`ps -o args= -p $$` inside a Bash tool call), with the snapshot path pointed at
# the fixture and the eval'd command replaced by a sleep. What matters is that it
# names `.claude/shell-snapshots/`, because the old holder check grepped the
# harness regex over the whole argument line and therefore read every tool shell
# as a live harness.
start_tool_shell_session() {  # <dir>
  local dir=$1 snap
  snap="$dir/.claude/shell-snapshots/snapshot-bash-1789510754725-53yowz.sh"
  mkdir -p "$dir/.claude/shell-snapshots"
  : > "$snap"
  /bin/bash -c "source $snap 2>/dev/null || true && shopt -u extglob 2>/dev/null || true && eval 'sleep 300' < /dev/null && pwd -P >| $dir/tool-shell-cwd" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

test_acquire_records_a_version_named_harness_process() {
  local dir state hpid recorded
  # The incident, exactly: a Claude Code session launched by its own daemon has
  # no `claude`-comm process of its own, so the acquire walk matched nothing and
  # printed `cannot locate harness process in ancestry`. That is what
  # bin/fm-lock.sh printed at 21:33 on 2026-09-15, with supervision already off
  # and no way to turn it back on from inside the session.
  dir=$(make_case lock-versioned-comm)
  state="$dir/state"
  hpid=$(start_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
'$LOCK_CLI' > '$dir/acquire.out' 2>&1
'$LOCK_CLI' status > '$dir/status.out' 2>&1
bash -c \"'$LOCK_CLI' ownership\" > '$dir/ownership.out' 2>&1
")
  wait_for_chain "$dir" || { stop_harness "$hpid"; fail "the versioned-harness chain never finished"; }

  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  assert_contains "$(cat "$dir/acquire.out")" "lock acquired: harness pid $hpid" \
    "acquire must find the version-named harness and record it: $(cat "$dir/acquire.out")"
  [ "$recorded" = "$hpid" ] || fail "the lock must name the version-named harness $hpid, got: $recorded"
  assert_contains "$(cat "$dir/status.out")" "lock: held by live harness pid $hpid" \
    "the holder check must accept the same process the finder recorded"
  [ "$(cat "$dir/ownership.out")" = owned ] \
    || fail "a shell below the recorded harness must read owned, got: $(cat "$dir/ownership.out")"
  stop_harness "$hpid"
  pass "fm-session-lock-lib: a harness named by version, not by command name, is found and recorded"
}

test_a_bash_tool_shell_is_not_a_live_harness() {
  local dir state tool hpid out recorded
  # The other half of the same asymmetry. The holder check grepped the harness
  # regex over the WHOLE `ps -o args=` line, and every Claude Code tool shell's
  # arguments name ~/.claude/shell-snapshots, so a lock left naming a tool shell
  # read as a live harness and would have been defended as a rival session.
  dir=$(make_case lock-tool-shell)
  state="$dir/state"
  tool=$(start_tool_shell_session "$dir")
  printf '%s\n' "$tool" > "$state/.lock"

  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_CLI" status 2>&1)
  assert_contains "$out" "lock: stale" "a bash tool shell must not read as a live harness holder: $out"
  assert_not_contains "$out" "held by live harness" "a bash tool shell must not be reported as a live holder"

  # A stale lock is overwritable, so a real session takes the home back without
  # an operator editing the file.
  hpid=$(start_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
'$LOCK_CLI' > '$dir/acquire.out' 2>&1
")
  wait_for_chain "$dir" || { stop_harness "$hpid"; stop_harness "$tool"; fail "the versioned-harness chain never finished"; }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  stop_harness "$hpid"
  stop_harness "$tool"
  [ "$recorded" = "$hpid" ] || fail "acquire must overwrite a lock naming a tool shell, got: $recorded"
  pass "fm-session-lock-lib: a bash tool shell is not a harness, so a lock naming one is stale and overwritable"
}

test_the_marker_finds_the_session_the_ancestry_walk_cannot_reach() {
  local dir state hpid recorded depth
  # The marker (CLAUDE_PID) exists so that ownership does not depend on the
  # harness process being RECOGNISABLE. The predicate learns launch shapes one at
  # a time; the marker names the session's own process outright.
  #
  # The discrimination is made exact rather than assumed. In this fixture the
  # harness sits exactly two hops above fm-lock.sh (harness -> chain shell ->
  # fm-lock.sh), and the finder's walk tests the depth it is given WITHOUT a
  # trailing hop, so a depth of 2 cannot reach it. The same case therefore asserts
  # both halves at that one depth: with the marker the harness is recorded, and
  # with the marker scrubbed the acquire fails outright. If the walk could reach
  # the harness anyway, the second half would pass and this test would fail.
  dir=$(make_case lock-marker-fast-path)
  state="$dir/state"
  depth=2
  hpid=$(start_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
export FM_SESSION_LOCK_ANCESTRY_DEPTH=$depth
env -u CLAUDE_PID '$LOCK_CLI' > '$dir/no-marker.out' 2>&1
env CLAUDE_PID=\"\$PPID\" '$LOCK_CLI' > '$dir/marker.out' 2>&1
")
  wait_for_chain "$dir" || { stop_harness "$hpid"; fail "the versioned-harness chain never finished"; }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  stop_harness "$hpid"

  assert_contains "$(cat "$dir/no-marker.out")" "cannot locate harness process in ancestry" \
    "at depth $depth the walk must NOT reach the harness, or this case proves nothing: $(cat "$dir/no-marker.out")"
  assert_contains "$(cat "$dir/marker.out")" "lock acquired: harness pid $hpid" \
    "the marker must name the session the walk could not reach: $(cat "$dir/marker.out")"
  [ "$recorded" = "$hpid" ] || fail "the lock must name the marker's harness $hpid, got: $recorded"
  pass "fm-session-lock-lib: a validated harness marker names a session the ancestry walk cannot reach"
}

test_an_inherited_marker_for_another_session_is_ignored() {
  local dir state hpid rival recorded
  # A marker can be inherited STALE by a process the harness never spawned: a
  # tmux server started by one session hands its CLAUDE_PID to panes opened
  # later, which belong to other sessions (verified 2026-09-15 on this box, scout
  # report 2.1 - the scout's own claude process carried a CLAUDE_PID naming the
  # interactive session two levels of indirection away).
  #
  # The rival here is a SECOND versioned harness: alive and harness-shaped, so
  # the only gate left to reject it is ancestry. That is what makes this a test of
  # the ancestry validation rather than of the harness predicate.
  dir=$(make_case lock-marker-stale)
  state="$dir/state"
  rival=$(start_versioned_harness "$dir/rival" "true")
  wait_for_chain "$dir/rival" || { stop_harness "$rival"; fail "the rival harness never started"; }

  hpid=$(start_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
env CLAUDE_PID=$rival '$LOCK_CLI' > '$dir/acquire.out' 2>&1
")
  wait_for_chain "$dir" || { stop_harness "$hpid"; stop_harness "$rival"; fail "the versioned-harness chain never finished"; }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  stop_harness "$hpid"
  stop_harness "$rival"

  [ "$recorded" != "$rival" ] \
    || fail "a marker naming a live harness OUTSIDE this ancestry was believed; the lock names the rival $rival"
  [ "$recorded" = "$hpid" ] \
    || fail "the walk must find this session's own harness $hpid when the marker is not ours, got: $recorded"
  pass "fm-session-lock-lib: a marker naming a live harness outside this ancestry is ignored, and the walk answers instead"
}

# The start ticks the kernel recorded for a pid, or empty where /proc is not
# available. The library that owns the parse is asked for it in a subshell, the
# same way tests/fm-continuity-pretool-check.test.sh asks for a pid identity, so
# the suite does not carry a second copy of a format the lock file depends on.
holder_ticks() {  # <pid>
  bash -c '. "$1"; fm_pid_start_ticks "$2"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$1" 2>/dev/null || true
}

# Write the session lock the way a real acquire would: pid on line 1, and the
# holder's start ticks on line 2 wherever the kernel offers them.
write_lock_for() {  # <state> <pid>
  local state=$1 pid=$2 ticks
  ticks=$(holder_ticks "$pid")
  if [ -n "$ticks" ]; then
    printf '%s\n%s\n' "$pid" "$ticks" > "$state/.lock"
  else
    printf '%s\n' "$pid" > "$state/.lock"
  fi
}

wait_for_marker() {  # <path>
  local path=$1 i=0
  while [ "$i" -lt 300 ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_death() {  # <pid>
  local pid=$1 i=0
  while [ "$i" -lt 150 ]; do
    is_live_non_zombie "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Start the incident's FULL process chain, the one the 2026-09-15 lock loss
# turned on:
#   claude  ->  2.1.273  ->  bash  ->  <the caller's commands>
# The outer `claude` is a copy of bash named `claude`, which is the shape of the
# Claude Code daemon that sat between the interactive session and the background
# one; beneath it is the version-named session process of start_versioned_harness
# above. Both shapes were captured by the scout from the real processes. Each
# level runs the next WITHOUT exec, so every one is a genuine process and the
# finder's walk has two candidates to choose between rather than one.
#
# The chain is driven in two phases by marker files, because both things this
# fixture exists to test need the caller to act BETWEEN them: <phase1> runs once
# the caller touches <dir>/go1, so the caller can pre-write the lock knowing both
# pids, and <phase2> runs once it touches <dir>/go2, so the caller can kill the
# outer `claude` in between - which is exactly the daemon self-restart that broke
# the ancestry link at 21:26. Each wait is bounded so a failing assertion leaves
# a dead fixture rather than a hung suite.
#
# Echoes "<outer claude pid> <versioned session pid>". The caller stops BOTH:
# the outer holds its child open with `wait`, so killing the outer orphans the
# versioned process rather than ending it.
start_claude_over_versioned_harness() {  # <dir> <phase1 body> <phase2 body>
  local dir=$1 phase1=$2 phase2=$3 outer versioned='' i=0
  mkdir -p "$dir/bin" "$dir/claude/versions"
  cp /bin/bash "$dir/bin/claude"
  cp /bin/bash "$dir/claude/versions/2.1.273"
  # The phase gate is its own script rather than a loop written into the chain,
  # so the generated chain needs no shell expansions of its own: a `printf`
  # format carrying them has to be single-quoted to survive generation, which is
  # exactly what shellcheck reads as a mistake (SC2016). A quoted heredoc is
  # literal by construction, the same way install_fake_ps_claude above writes its
  # stub, so the bound stays real and the suite stays clean without a disable.
  cat > "$dir/await.sh" <<'SH'
#!/usr/bin/env bash
set -u
i=0
while [ ! -e "$1" ] && [ "$i" -lt 300 ]; do
  sleep 0.1
  i=$((i + 1))
done
SH
  chmod +x "$dir/await.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf '"%s/await.sh" "%s/go1"\n' "$dir" "$dir"
    printf '%s\n' "$phase1"
    printf 'touch "%s/phase1.done"\n' "$dir"
    printf '"%s/await.sh" "%s/go2"\n' "$dir" "$dir"
    printf '%s\n' "$phase2"
    printf 'touch "%s/chain.done"\n' "$dir"
  } > "$dir/chain.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'bash "%s/chain.sh"\n' "$dir"
    printf 'sleep 300\n'
  } > "$dir/harness-body.sh"
  # The versioned process is backgrounded and publishes its own pid to a file:
  # the caller needs BOTH pids, and a command substitution can only carry the
  # one it started. `wait` is what keeps the outer alive until it is killed.
  {
    printf '#!/usr/bin/env bash\n'
    printf '"%s/claude/versions/2.1.273" "%s/harness-body.sh" \\\n' "$dir" "$dir"
    printf '  --session-id 00000000-0000-4000-8000-000000000000 --fork-session >/dev/null 2>&1 &\n'
    printf 'printf "%%s\\n" "$!" > "%s/versioned.pid"\n' "$dir"
    printf 'wait\n'
  } > "$dir/outer-body.sh"
  env -u CLAUDE_PID "$dir/bin/claude" "$dir/outer-body.sh" >/dev/null 2>&1 &
  outer=$!
  while [ "$i" -lt 150 ]; do
    versioned=$(cat "$dir/versioned.pid" 2>/dev/null || true)
    [ -n "$versioned" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s %s\n' "$outer" "$versioned"
}

test_acquire_records_the_nearest_harness_not_the_one_above_it() {
  local dir state pids outer versioned recorded
  # With two harness-shaped processes in one ancestry, WHICH one is recorded is
  # the whole difference between a lock that survives a Claude Code auto-update
  # and the one that did not. The outer `claude` here stands in for the daemon:
  # the daemon self-restarts on every binary change, so a lock naming anything
  # at or above it is only as durable as the next upgrade.
  dir=$(make_case lock-nearest-harness)
  state="$dir/state"
  pids=$(start_claude_over_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
'$LOCK_CLI' > '$dir/acquire1.out' 2>&1
" "
export FM_STATE_OVERRIDE='$state'
bash -c \"'$LOCK_CLI' ownership\" > '$dir/ownership2.out' 2>&1
'$LOCK_CLI' > '$dir/acquire2.out' 2>&1
")
  read -r outer versioned <<< "$pids"
  [ -n "$versioned" ] || { stop_harness "$outer"; fail "the versioned session process never started under the outer claude"; }

  touch "$dir/go1"
  wait_for_marker "$dir/phase1.done" || {
    stop_harness "$versioned"; stop_harness "$outer"
    fail "the chain's first phase never finished"
  }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  assert_contains "$(cat "$dir/acquire1.out")" "lock acquired: harness pid $versioned" \
    "acquire must record the NEAREST harness, the session's own process: $(cat "$dir/acquire1.out")"
  assert_not_contains "$(cat "$dir/acquire1.out")" "moved from ancestor" \
    "a first acquisition over no lock at all has nothing to inherit"
  [ "$recorded" = "$versioned" ] \
    || fail "the lock must name the version-named session process $versioned, got: $recorded"
  [ "$recorded" != "$outer" ] \
    || fail "the lock names the outer claude $outer, the disposable process the incident depended on"

  # The daemon restart: kill the process ABOVE the recorded holder. Ownership
  # must not notice, because nothing above the session is consulted any more.
  stop_harness "$outer"
  wait_for_death "$outer" || { stop_harness "$versioned"; fail "the outer claude never died"; }
  touch "$dir/go2"
  wait_for_marker "$dir/chain.done" || {
    stop_harness "$versioned"
    fail "the chain's second phase never finished"
  }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  stop_harness "$versioned"

  [ "$(cat "$dir/ownership2.out")" = owned ] \
    || fail "losing the process above the session must not lose the fleet, got: $(cat "$dir/ownership2.out")"
  assert_contains "$(cat "$dir/acquire2.out")" "lock acquired: harness pid $versioned" \
    "re-acquiring after the process above died must still succeed: $(cat "$dir/acquire2.out")"
  [ "$recorded" = "$versioned" ] || fail "the re-acquire moved the lock off the session, to: $recorded"
  pass "fm-lock.sh: the nearest harness is recorded, so the fleet survives the death of the process above it"
}

test_acquire_inherits_a_lock_that_names_a_live_ancestor() {
  local dir state pids outer versioned recorded
  # The migration case, and the one that would have prevented the incident
  # outright. At 08:59 on 2026-09-15 the INTERACTIVE session acquired the lock;
  # the background session beneath it never held the lock at all, and its own
  # acquire was refused at 18:29 while every gate still read `owned` through
  # ancestry - a split brain that predated the failure by three hours. A live
  # holder that is an ancestor is now inherited instead of defended, so the first
  # descendant to act becomes the sole owner and a legacy lock migrates with no
  # operator step.
  dir=$(make_case lock-inherit-ancestor)
  state="$dir/state"
  pids=$(start_claude_over_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
'$LOCK_CLI' > '$dir/acquire.out' 2>&1
" "
export FM_STATE_OVERRIDE='$state'
bash -c \"'$LOCK_CLI' ownership\" > '$dir/ownership.out' 2>&1
")
  read -r outer versioned <<< "$pids"
  [ -n "$versioned" ] || { stop_harness "$outer"; fail "the versioned session process never started under the outer claude"; }

  # The 08:59 state: the lock names the live process ABOVE this session, with its
  # kernel start ticks, exactly as a real acquire from that session wrote it.
  write_lock_for "$state" "$outer"
  touch "$dir/go1"
  wait_for_marker "$dir/phase1.done" || {
    stop_harness "$versioned"; stop_harness "$outer"
    fail "the chain's first phase never finished"
  }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  assert_contains "$(cat "$dir/acquire.out")" "lock acquired: harness pid $versioned (moved from ancestor $outer)" \
    "a live ANCESTOR holder must be inherited, and the move named: $(cat "$dir/acquire.out")"
  assert_not_contains "$(cat "$dir/acquire.out")" "another live firstmate session holds the lock" \
    "a session forked from the holder is not a rival and must not be refused"
  [ "$recorded" = "$versioned" ] \
    || fail "the inherited lock must name this session's own process $versioned, got: $recorded"

  # Having inherited it, the fleet survives the ancestor's death - which is the
  # whole point of moving the lock down before the daemon restarts.
  stop_harness "$outer"
  wait_for_death "$outer" || { stop_harness "$versioned"; fail "the outer claude never died"; }
  touch "$dir/go2"
  wait_for_marker "$dir/chain.done" || {
    stop_harness "$versioned"
    fail "the chain's second phase never finished"
  }
  stop_harness "$versioned"
  [ "$(cat "$dir/ownership.out")" = owned ] \
    || fail "after inheriting, the ancestor's death must not lose the fleet, got: $(cat "$dir/ownership.out")"
  pass "fm-lock.sh: a live ancestor holder is inherited, so a legacy lock migrates and survives that ancestor"
}

test_a_live_harness_outside_this_ancestry_is_still_refused() {
  local dir state rival pids outer versioned recorded
  # Requirement (b), and the one this change could plausibly have broken: making
  # a descendant inherit must not make a STRANGER inheritable. The rival here is
  # a second version-named harness, alive and harness-shaped, so the only thing
  # that can reject it is the ancestry test - which is what makes this a test of
  # the inherit condition rather than of the harness predicate.
  dir=$(make_case lock-rival-not-inherited)
  state="$dir/state"
  rival=$(start_versioned_harness "$dir/rival" "true")
  wait_for_chain "$dir/rival" || { stop_harness "$rival"; fail "the rival harness never started"; }
  write_lock_for "$state" "$rival"

  pids=$(start_claude_over_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
'$LOCK_CLI' > '$dir/acquire.out' 2>&1
printf '%s\n' \"\$?\" > '$dir/acquire.status'
" "true")
  read -r outer versioned <<< "$pids"
  [ -n "$versioned" ] || { stop_harness "$outer"; stop_harness "$rival"; fail "the versioned session process never started"; }
  touch "$dir/go1"
  wait_for_marker "$dir/phase1.done" || {
    stop_harness "$versioned"; stop_harness "$outer"; stop_harness "$rival"
    fail "the chain's first phase never finished"
  }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  touch "$dir/go2"
  stop_harness "$versioned"
  stop_harness "$outer"
  stop_harness "$rival"

  [ "$(cat "$dir/acquire.status")" = 1 ] \
    || fail "acquiring over a live harness outside this ancestry must still exit 1, got: $(cat "$dir/acquire.status")"
  assert_contains "$(cat "$dir/acquire.out")" "another live firstmate session holds the lock" \
    "a live non-ancestor holder must still be refused: $(cat "$dir/acquire.out")"
  assert_contains "$(cat "$dir/acquire.out")" "is not an ancestor of this process" \
    "the refusal must say why the holder was not inherited"
  assert_not_contains "$(cat "$dir/acquire.out")" "moved from ancestor" \
    "a rival session must never be reported as an inherited ancestor"
  [ "$recorded" = "$rival" ] || fail "a refused acquire rewrote the lock, to: $recorded"
  pass "fm-lock.sh: a live harness outside this session's ancestry is a rival, not an ancestor to inherit from"
}

test_arming_converges_a_lock_that_names_an_ancestor() {
  local dir state pids outer versioned recorded watcher
  # Inheriting at acquire alone would leave every already-running home on its
  # legacy ancestor-recorded lock until someone next ran session start, and a
  # daemon restart before that repeats the incident. So both entry points that
  # take the watcher singleton re-acquire once on their OWNED path, which for a
  # lock already naming this session is a no-op refresh and for a legacy lock is
  # the migration. Codex reaches supervision through the checkpoint rather than
  # the arm, so both are exercised here, each from inside the chain so the
  # ancestry the gate walks is the real one.
  dir=$(make_case gate-arm-converge)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  pids=$(start_claude_over_versioned_harness "$dir" "
export FM_STATE_OVERRIDE='$state'
export PATH='$dir/fakebin':\$PATH
export FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
timeout 30 '$WATCH_CHECKPOINT' --seconds 1 > '$dir/checkpoint.out' 2>&1 || true
" "
export FM_STATE_OVERRIDE='$state'
export PATH='$dir/fakebin':\$PATH
export FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_ARM_CONFIRM_TIMEOUT=5
timeout 20 '$WATCH_ARM' > '$dir/arm.out' 2>&1 || true
")
  read -r outer versioned <<< "$pids"
  [ -n "$versioned" ] || { stop_harness "$outer"; fail "the versioned session process never started under the outer claude"; }

  # Codex's entry point first, on the 08:59 lock shape.
  write_lock_for "$state" "$outer"
  touch "$dir/go1"
  wait_for_marker "$dir/phase1.done" || {
    stop_harness "$versioned"; stop_harness "$outer"
    fail "the checkpoint phase never finished"
  }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  assert_not_contains "$(cat "$dir/checkpoint.out")" "read-only" \
    "a session descended from the holder owns the home and must not be refused: $(cat "$dir/checkpoint.out")"
  [ "$recorded" = "$versioned" ] \
    || fail "the checkpoint must move the lock onto this session's own process $versioned, got: $recorded"

  # Then the arm, put back on the legacy lock so it has the same work to do. The
  # beacon the checkpoint's own watcher touched has to go with it, or the arm
  # attaches to that finished cycle instead of starting one.
  write_lock_for "$state" "$outer"
  find "$state" -maxdepth 1 -name .last-watcher-beat -delete
  touch "$dir/go2"
  wait_for_marker "$dir/chain.done" || {
    watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$watcher" ] && kill -TERM "$watcher" 2>/dev/null
    stop_harness "$versioned"; stop_harness "$outer"
    fail "the arm phase never finished: $(cat "$dir/arm.out" 2>/dev/null || true)"
  }
  recorded=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher" ] && kill -TERM "$watcher" 2>/dev/null
  stop_harness "$versioned"
  stop_harness "$outer"

  assert_not_contains "$(cat "$dir/arm.out")" "read-only" \
    "the arm must not refuse a session descended from the lock holder: $(cat "$dir/arm.out")"
  assert_contains "$(cat "$dir/arm.out")" "watcher: started pid=" \
    "the arm must still arm after converging the lock: $(cat "$dir/arm.out")"
  [ "$recorded" = "$versioned" ] \
    || fail "the arm must move the lock onto this session's own process $versioned, got: $recorded"
  pass "fm-watch-arm, fm-watch-checkpoint: arming converges an ancestor-recorded lock onto this session"
}

test_the_harness_predicate_has_exactly_one_implementation() {
  local definitions leftovers names count alternatives name
  # The finder and the holder check each used to carry their own idea of what a
  # harness is, and the two were wrong in opposite directions. One definition is
  # what keeps them from drifting apart again.
  definitions=$(grep -rl 'fm_session_pid_is_harness()' "$ROOT/bin" 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$definitions" = 1 ] || fail "expected exactly one harness predicate, found $definitions"

  leftovers=$(grep -rln 'FM_SESSION_HARNESS_RE\|FM_SESSION_HARNESS_NAMES' "$ROOT/bin" 2>/dev/null \
    | grep -vc 'fm-session-lock-lib\.sh$' || true)
  [ "$leftovers" = 0 ] \
    || fail "the harness name list is read outside its own library in $leftovers file(s); the predicate is the only reader"

  # The predicate needs the harness list in two forms: a loose regex for a
  # basename, and a plain name list for the exact directory-component test. They
  # are two copies of one fact, so pin them to each other.
  names=$(bash -c '. "$1"; printf "%s\n" "$FM_SESSION_HARNESS_NAMES"' _ "$ROOT/bin/fm-session-lock-lib.sh")
  count=$(printf '%s\n' "$names" | tr ' ' '\n' | grep -c .)
  alternatives=$(bash -c '. "$1"; printf "%s\n" "$FM_SESSION_HARNESS_RE"' _ "$ROOT/bin/fm-session-lock-lib.sh" \
    | tr '|' '\n' | grep -c .)
  [ "$count" = "$alternatives" ] \
    || fail "FM_SESSION_HARNESS_NAMES has $count names but FM_SESSION_HARNESS_RE has $alternatives alternatives"
  for name in $names; do
    bash -c '. "$1"; fm_session_name_is_harness "$2"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$name" \
      || fail "harness name $name is in the list but does not match the regex"
  done
  pass "fm-session-lock-lib: one harness predicate, and its two forms of the harness list agree"
}

# --- bin/fm-watch-arm.sh gate ------------------------------------------------

test_arm_refuses_when_another_session_owns_the_fleet() {
  local dir state other out status
  dir=$(make_case gate-arm-other)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"

  out=$(run_arm_foreground "$state"); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true

  [ "$status" -ne 124 ] || fail "the non-owning arm did not return; it ran a watcher cycle instead of declining"
  expect_code 0 "$status" "a non-owning session declining to arm is correct, not a failure"
  assert_contains "$out" "read-only" "the refusal must say the session is read-only"
  assert_contains "$out" "not arming" "the refusal must say it did not arm"
  assert_not_contains "$out" "watcher: FAILED" "declining to arm must not be reported as a supervision failure"
  assert_not_contains "$out" "watcher: started" "a non-owning session must not start a watcher"
  if watch_singleton_present "$state"; then
    fail "a non-owning arm took the watcher singleton (state/.watch.lock)"
  fi
  [ ! -e "$state/.last-watcher-beat" ] || fail "a non-owning arm ran a watcher (beacon was touched)"
  pass "fm-watch-arm: refuses quietly (exit 0) when another live session holds the session lock"
}

test_arm_refuses_restart_when_another_session_owns_the_fleet() {
  local dir state other out status
  dir=$(make_case gate-arm-other-restart)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"

  # --restart stops this home's watcher before starting one, so the gate has to
  # come first: a read-only session must never be able to stop the owner's
  # watcher.
  out=$(run_arm_foreground "$state" --restart); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true

  [ "$status" -ne 124 ] || fail "the non-owning --restart did not return; it ran a watcher cycle instead of declining"
  expect_code 0 "$status" "a non-owning --restart must decline, not fail"
  assert_contains "$out" "read-only" "the --restart refusal must say the session is read-only"
  if watch_singleton_present "$state"; then
    fail "a non-owning --restart touched the watcher singleton (state/.watch.lock)"
  fi
  pass "fm-watch-arm: --restart is gated too, so a read-only session cannot stop the owner's watcher"
}

test_arm_starts_for_the_owning_session() {
  local dir state out armpid
  dir=$(make_case gate-arm-owned)
  state="$dir/state"
  out="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  printf '%s\n' "$$" > "$state/.lock"

  armpid=$(start_arm_background "$state" "$out")
  grep -qF 'watcher: started pid=' "$out" || {
    stop_arm_background "$armpid" "$state"
    fail "the owning session did not arm: $(cat "$out")"
  }
  assert_not_contains "$(cat "$out")" "read-only" "the owning session must not be refused"
  watch_singleton_present "$state" || {
    stop_arm_background "$armpid" "$state"
    fail "the owning session's arm did not take the watcher singleton"
  }
  stop_arm_background "$armpid" "$state"
  pass "fm-watch-arm: the session that owns the session lock arms exactly as before"
}

test_arm_recognises_ownership_several_process_levels_down() {
  local dir state out out2 status other level1 level2 level3 armpid i
  dir=$(make_case gate-arm-depth)
  state="$dir/state"
  out="$dir/arm.out"
  level1="$dir/level1.sh"
  level2="$dir/level2.sh"
  level3="$dir/level3.sh"
  mark_pr_check_migration_complete "$state"
  printf '%s\n' "$$" > "$state/.lock"

  # A real watcher sits at least three shell levels below its session
  # (watcher <- bash <- bash <- claude), so ownership must be resolved by
  # ancestry. Each level runs the next WITHOUT exec, so every one is a genuine
  # extra process: the arm's own parent is level3, never the lock holder.
  printf '#!/usr/bin/env bash\nbash "%s"\nexit $?\n' "$level2" > "$level1"
  printf '#!/usr/bin/env bash\nbash "%s"\nexit $?\n' "$level3" > "$level2"
  printf '#!/usr/bin/env bash\n"%s"\nexit $?\n' "$WATCH_ARM" > "$level3"
  chmod +x "$level1" "$level2" "$level3"

  PATH="$dir/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 \
    bash "$level1" > "$out" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || {
    stop_arm_background "$armpid" "$state"
    fail "ownership was not recognised three process levels below the lock holder: $(cat "$out")"
  }
  stop_arm_background "$armpid" "$state"

  # The same depth must still refuse a rival holder, so the walk is genuinely
  # deciding rather than the depth simply making everything look owned.
  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"
  rm -f "$state/.last-watcher-beat"
  out2=$(timeout 30 env PATH="$dir/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=2 \
    bash "$level1" 2>&1); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ "$status" -ne 124 ] || fail "the deep non-owning arm did not return; it ran a watcher cycle instead of declining"
  assert_contains "$out2" "read-only" "the same ancestry depth must still refuse a rival session lock holder"
  pass "fm-watch-arm: ownership is resolved by ancestry, not by the immediate parent"
}

test_arm_still_arms_without_a_lock_holder_and_says_so() {
  local row dir state out armpid
  # Startup and recovery can legitimately arm before any session lock exists, and
  # a dead holder means nobody is being displaced. Both must still arm - refusing
  # would leave the home unsupervised - but neither may do it silently.
  for row in absent dead malformed; do
    dir=$(make_case "gate-arm-$row")
    state="$dir/state"
    out="$dir/arm.out"
    mark_pr_check_migration_complete "$state"
    case "$row" in
      absent) rm -f "$state/.lock" ;;
      dead) printf '%s\n' "$(dead_pid)" > "$state/.lock" ;;
      malformed) printf 'garbage\n' > "$state/.lock" ;;
    esac

    armpid=$(start_arm_background "$state" "$out")
    grep -qF 'watcher: started pid=' "$out" || {
      stop_arm_background "$armpid" "$state"
      fail "$row session lock blocked a legitimate arm: $(cat "$out")"
    }
    assert_contains "$(cat "$out")" "no live session holds this home's session lock" \
      "$row session lock must be announced, never a silent grant"
    assert_contains "$(cat "$out")" "bin/fm-session-start.sh" \
      "$row session lock notice must name the command that claims the lock"
    stop_arm_background "$armpid" "$state"
  done
  pass "fm-watch-arm: an absent, dead-holder, or malformed session lock arms but is announced"
}

test_arm_arms_when_the_lock_holder_pid_was_reused() {
  local dir state other out armpid
  # After a reboot state/.lock survives (state/ is not tmpfs) and its pid is
  # very likely handed to an unrelated live process. Reading that as a live rival
  # would refuse to arm AND silence the blind-turn alarm at the same time, so the
  # home would run unsupervised with nothing complaining.
  start_ticks_available || {
    pass "fm-watch-arm: pid-reuse detection needs /proc start ticks; not available here"
    return 0
  }
  dir=$(make_case gate-arm-reused-pid)
  state="$dir/state"
  out="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  other=$(start_other_session)
  printf '%s\n%s\n' "$other" 1 > "$state/.lock"

  armpid=$(start_arm_background "$state" "$out")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  grep -qF 'watcher: started pid=' "$out" || {
    stop_arm_background "$armpid" "$state"
    fail "a reused holder pid blocked a legitimate arm: $(cat "$out")"
  }
  assert_contains "$(cat "$out")" "no live session holds this home's session lock" \
    "a reused holder pid must be announced as a stale lock, never a silent grant"
  assert_not_contains "$(cat "$out")" "read-only" "a reused holder pid must not read as a live rival"
  stop_arm_background "$armpid" "$state"
  pass "fm-watch-arm: a live pid the kernel says is a different process is a stale lock, so the home still arms"
}

# --- bin/fm-watch-checkpoint.sh gate -----------------------------------------
# Codex's documented watcher protocol is the second entry point that takes the
# watcher singleton, so it carries the same gate. bin/fm-watch.sh itself is NOT
# gated: the arm and the away-mode daemon fork it as a legitimate child.

run_checkpoint() {  # <state> [args...]
  local state=$1
  shift
  timeout 30 env PATH="$(dirname "$state")/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_CHECKPOINT" --seconds 1 "$@" 2>&1
}

test_checkpoint_is_gated_on_the_session_lock() {
  local dir state other out status
  dir=$(make_case gate-checkpoint)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"

  other=$(start_other_session)
  printf '%s\n' "$other" > "$state/.lock"
  out=$(run_checkpoint "$state"); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "a non-owning checkpoint declining is correct, not a failure"
  assert_contains "$out" "read-only" "the checkpoint refusal must say the session is read-only"
  assert_contains "$out" "not arming" "the checkpoint refusal must say it did not arm"
  assert_not_contains "$out" "watcher: FAILED" "declining a checkpoint must not be a supervision failure"
  if watch_singleton_present "$state"; then
    fail "a non-owning checkpoint took the watcher singleton (state/.watch.lock)"
  fi
  [ ! -e "$state/.last-watcher-beat" ] || fail "a non-owning checkpoint ran a watcher (beacon was touched)"

  # The owning session runs its checkpoint exactly as before.
  printf '%s\n' "$$" > "$state/.lock"
  out=$(run_checkpoint "$state"); status=$?
  expect_code 124 "$status" "the owning session's quiet checkpoint must still time out normally"
  assert_contains "$out" "checkpoint: no actionable wake within 1s" "the owning session's checkpoint did not run"
  assert_not_contains "$out" "read-only" "the owning session's checkpoint must not be refused"
  pass "fm-watch-checkpoint: gated on the session lock the same way, so Codex inherits the rule too"
}

# --- bin/fm-statusline.sh ----------------------------------------------------

# With nothing configured locally, base-command resolution falls back to the
# harness's own user-level status line (docs/configuration.md "Status-line
# composition"). These cases are about the fleet line and about the configured
# sources, so they pin that fallback at an empty config dir - otherwise they
# would read whatever status line the developer running the suite happens to have
# installed, and assert on it. tests/fm-statusline-render.test.sh owns the
# fallback itself, and renders it end to end.
STATUSLINE_EMPTY_CONFIG="$TMP_ROOT/statusline-empty-claude-config"
mkdir -p "$STATUSLINE_EMPTY_CONFIG"

# FM_STATUSLINE_BASE is scrubbed for the invocation, not merely left unset here:
# bin/fm-statusline.sh reads that env var BEFORE config/statusline-base, so an
# operator who has their own base command configured - and every crewmate pane,
# because bin/fm-spawn.sh forwards the dispatching home's setting into the worker
# environment - would otherwise run the real base command instead of each
# fixture's, and the composition assertions below would assert nothing.
# test_statusline_base_reaches_a_worktree_that_has_no_config_dir sets the var on
# purpose and therefore does not use this helper.
run_statusline() {  # <home>
  printf '{"session_id":"test"}' |
    env -u FM_STATUSLINE_BASE FM_HOME="$1" CLAUDE_CONFIG_DIR="$STATUSLINE_EMPTY_CONFIG" \
      "$STATUSLINE" 2>&1
}

test_statusline_reports_fleet_control() {
  local home out other status
  home="$TMP_ROOT/statusline-home"
  mkdir -p "$home/state"

  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "the status line must always exit 0"
  assert_contains "$out" "in control of fleet" "the owning session must be shown as in control"
  assert_not_contains "$out" "not in control of fleet" "the owning session must not be shown as out of control"

  other=$(start_other_session)
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(run_statusline "$home")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_contains "$out" "not in control of fleet" "a session that does not hold the lock must be shown as not in control"

  rm -f "$home/state/.lock"
  out=$(run_statusline "$home")
  assert_contains "$out" "not in control of fleet" "no lock holder means no session is in control"
  assert_contains "$out" "bin/fm-session-start.sh" "the no-holder line must name how to take control"
  pass "fm-statusline: reports fleet control for the current home"
}

test_statusline_is_silent_and_writes_nothing_without_fleet_state() {
  local home out status
  # Every crewmate and scout task worktree of this repo carries the tracked
  # script but no state dir; the indicator must degrade to silence there.
  home="$TMP_ROOT/statusline-no-state"
  mkdir -p "$home"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "the status line must exit 0 with no fleet state"
  [ -z "$out" ] || fail "the status line spoke without fleet state: $out"
  [ ! -d "$home/state" ] || fail "the status line created the state dir; it must never write to state"
  pass "fm-statusline: silent, and creates nothing, where there is no fleet state"
}

# A REAL linked worktree, because git writing .git as a FILE rather than a
# directory is the whole distinction under test, and a hand-written stand-in
# would test a shape git may not emit.
make_linked_worktree() {  # <repo dir> <worktree dir>
  local repo=$1 worktree=$2
  mkdir -p "$repo"
  git -C "$repo" init -q -b statusline-fixture
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m initial
  git -C "$repo" worktree add -q --detach "$worktree"
}

test_statusline_says_nothing_in_an_unmarked_linked_worktree() {
  local repo worktree home out status
  # A task worktree is recycled between occupants and state/ is gitignored rather
  # than removed, so a fresh crew inherits an earlier one's empty state dir. That
  # made a state dir alone mean "there is a fleet here" for a home that does not
  # exist, and every crew pane rendered a confident verdict about it. The verdict
  # could never have been right: bin/fm-spawn.sh exports FM_HOME only for a
  # secondmate, so the pane was never reading the real home's lock.
  repo="$TMP_ROOT/statusline-linked-repo"
  worktree="$TMP_ROOT/statusline-linked-worktree"
  make_linked_worktree "$repo" "$worktree"
  mkdir -p "$worktree/state"
  [ -f "$worktree/.git" ] || fail "the linked-worktree fixture must have a .git FILE; that is the case under test"

  out=$(run_statusline "$worktree"); status=$?
  expect_code 0 "$status" "a task worktree must not fail the status line"
  assert_not_contains "$out" "control of fleet" "a leftover state dir in a task worktree must not produce a verdict about a fleet"

  # A leased secondmate home is a linked worktree too, so .git is a file there as
  # well; the marker is the only thing that tells the two apart, and
  # bin/fm-primary-scope-lib.sh owns reading it.
  printf 'secondmate-fixture\n' > "$worktree/.fm-secondmate-home"
  printf '%s\n' "$$" > "$worktree/state/.lock"
  out=$(run_statusline "$worktree")
  assert_contains "$out" "in control of fleet" "a marked secondmate worktree is a home and must be answered despite its .git file"

  # The control, so the silence above cannot be a status line that has simply
  # gone quiet everywhere: only the unmarked LINKED worktree is silenced, and a
  # home that is not one is still answered.
  home="$TMP_ROOT/statusline-not-a-linked-worktree"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(run_statusline "$home")
  assert_contains "$out" "in control of fleet" "only an unmarked linked worktree may be silenced; every other home is still answered"
  pass "fm-statusline: an unmarked linked worktree says nothing about a fleet it does not have"
}

install_statusline_base() {  # <home> <base path>
  local home=$1 base=$2
  mkdir -p "$home/config"
  cat > "$base" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf 'base line payload=%s\n' "$payload"
SH
  chmod +x "$base"
  printf '%s\n' "$base" > "$home/config/statusline-base"
}

test_statusline_composes_with_the_operators_own_status_line() {
  local home base out status
  # .claude/settings.json is tracked and shared, so wiring this script there
  # would otherwise REPLACE whatever status line the operator already runs, in
  # every worktree of this repo. It composes instead: the operator's line first,
  # the fleet line beneath it.
  home="$TMP_ROOT/statusline-compose"
  base="$TMP_ROOT/statusline-base.sh"
  mkdir -p "$home/state"
  install_statusline_base "$home" "$base"
  printf '%s\n' "$$" > "$home/state/.lock"

  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "composing must still always exit 0"
  assert_contains "$out" "base line" "the operator's own status line must still be printed"
  assert_contains "$out" "in control of fleet" "the fleet line must still be printed"
  assert_contains "$out" 'payload={"session_id":"test"}' "the harness payload must be forwarded to the base command"
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = 'base line payload={"session_id":"test"}' ] \
    || fail "the base line must come first, got: $out"
  printf '%s\n' "$out" | sed -n '2p' | grep -qF 'in control of fleet' \
    || fail "the fleet line must come second, got: $out"

  # A crewmate or scout task worktree carries the tracked script but no fleet
  # state. The fleet line is silent there, and going blank instead of showing the
  # operator's own line is the complaint this composition answers.
  home="$TMP_ROOT/statusline-compose-no-state"
  mkdir -p "$home"
  install_statusline_base "$home" "$base"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "composing without fleet state must exit 0"
  assert_contains "$out" "base line" "the operator's line must print even where there is no fleet state"
  assert_not_contains "$out" "control of fleet" "there is no fleet here, so there must be no fleet line"
  [ ! -d "$home/state" ] || fail "composing created the state dir; it must never write to state"

  # An absent, empty, or non-executable base command in the configured source
  # means no base line from it, quietly. The user-level fallback is pinned empty
  # here (see run_statusline), so what is left is the fleet line alone.
  home="$TMP_ROOT/statusline-base-unusable"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$TMP_ROOT/statusline-base-does-not-exist.sh" > "$home/config/statusline-base"
  out=$(run_statusline "$home")
  assert_contains "$out" "in control of fleet" "a missing base command must not suppress the fleet line"
  assert_not_contains "$out" "base line" "a missing base command must print nothing of its own"

  printf '%s\n' "$TMP_ROOT/statusline-base-not-executable.sh" > "$home/config/statusline-base"
  printf '#!/usr/bin/env bash\nprintf "base line\\n"\n' > "$TMP_ROOT/statusline-base-not-executable.sh"
  chmod 0644 "$TMP_ROOT/statusline-base-not-executable.sh"
  out=$(run_statusline "$home"); status=$?
  expect_code 0 "$status" "a non-executable base command must not fail the status line"
  assert_contains "$out" "in control of fleet" "a non-executable base command must not suppress the fleet line"
  assert_not_contains "$out" "base line" "a non-executable base command must not be run"

  : > "$home/config/statusline-base"
  out=$(run_statusline "$home")
  assert_contains "$out" "in control of fleet" "an empty base setting must not suppress the fleet line"
  pass "fm-statusline: composes beneath the operator's own status line, and degrades to the fleet line alone"
}

test_statusline_base_reaches_a_worktree_that_has_no_config_dir() {
  local worktree base out status
  # This is the shape a real crewmate or scout task worktree has: a plain git
  # worktree carrying the tracked .claude/settings.json wiring, with NO config/
  # and NO state/. There is no file for the composition to read there, so a
  # deliberate per-home setting reaches it only through the FM_STATUSLINE_BASE
  # env override that bin/fm-spawn.sh forwards from the dispatching home. A
  # worktree that inherits no override falls back to the operator's own
  # user-level status line instead of going blank; that case is rendered end to
  # end in tests/fm-statusline-render.test.sh.
  worktree="$TMP_ROOT/statusline-task-worktree"
  base="$TMP_ROOT/statusline-task-base.sh"
  mkdir -p "$worktree"
  cat > "$base" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf 'base line payload=%s\n' "$payload"
SH
  chmod +x "$base"
  [ ! -d "$worktree/config" ] || fail "the task-worktree fixture must have no config dir"

  out=$(printf '{"session_id":"test"}' | FM_HOME="$worktree" FM_STATUSLINE_BASE="$base" "$STATUSLINE" 2>&1); status=$?
  expect_code 0 "$status" "the env override must not fail the status line"
  assert_contains "$out" 'base line payload={"session_id":"test"}' \
    "the forwarded base command must run, and receive the harness payload, where there is no config dir"
  assert_not_contains "$out" "control of fleet" "a task worktree has no fleet, so there must be no fleet line"
  [ ! -d "$worktree/state" ] || fail "the status line created the state dir; it must never write to state"
  pass "fm-statusline: FM_STATUSLINE_BASE reaches a task worktree that has no config dir of its own"
}

test_statusline_fixtures_are_isolated_from_an_inherited_base() {
  local home fixture ambient out
  # The regression: run_statusline used to inherit FM_STATUSLINE_BASE, which
  # bin/fm-statusline.sh resolves BEFORE config/statusline-base. On any machine
  # whose operator has a base status line configured - and in every crewmate
  # pane, because bin/fm-spawn.sh forwards the dispatching home's setting into
  # the worker environment - the real base command ran instead of the fixture's,
  # and the composition cases above silently asserted the wrong command's
  # output. This case makes that leak fail everywhere instead of only on a
  # machine that happens to have the setting, by exporting a hostile value for
  # the duration of one run.
  home="$TMP_ROOT/statusline-inherited-base"
  fixture="$TMP_ROOT/statusline-fixture-base.sh"
  ambient="$TMP_ROOT/statusline-ambient-base.sh"
  mkdir -p "$home/state"
  install_statusline_base "$home" "$fixture"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "ambient line\\n"\n' > "$ambient"
  chmod +x "$ambient"
  printf '%s\n' "$$" > "$home/state/.lock"

  out=$(FM_STATUSLINE_BASE="$ambient" run_statusline "$home")
  assert_contains "$out" "base line" "the fixture's base command must be the one that runs"
  assert_not_contains "$out" "ambient line" "an inherited FM_STATUSLINE_BASE must not reach the fixture's status line"
  assert_contains "$out" "in control of fleet" "the fleet line must still be printed"
  pass "fm-statusline: the fixtures are isolated from an inherited FM_STATUSLINE_BASE"
}

test_statusline_other_branch_names_a_remedy() {
  local home other out
  home="$TMP_ROOT/statusline-other-remedy"
  mkdir -p "$home/state"
  other=$(start_other_session)
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(run_statusline "$home")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_contains "$out" "not in control of fleet" "a rival holder must be shown as not in control"
  assert_contains "$out" "bin/fm-session-start.sh" "the rival-holder line must name a remedy, like the no-holder line does"
  pass "fm-statusline: the rival-holder line names a remedy instead of leaving the session with none"
}

test_statusline_is_wired_into_claude_settings() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  command=$(jq -r '.statusLine.command // empty' "$settings")
  [ -n "$command" ] || fail "no statusLine command in .claude/settings.json"
  assert_contains "$command" 'fm-statusline.sh' "the Claude status line must run the firstmate indicator"
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "the status line must resolve from the project dir, not a bare relative path"
  [ "$(jq -r '.statusLine.type // empty' "$settings")" = command ] \
    || fail "the Claude status line must be a command status line"
  pass ".claude/settings.json: the fleet-control indicator is wired for Claude Code"
}

# --- one implementation only -------------------------------------------------

# The lock write has to REPLACE the file rather than truncate it in place. A
# reader that lands inside a truncate window reads a short file, and since
# bin/fm-watch.sh's per-poll check turns a `missing` verdict into a re-acquire
# and possibly a stand-down, a torn read became a way to lose supervision on a
# perfectly healthy home. A race is not reproducible on demand, so this asserts
# the mechanism that removes it: the file's inode changes across a write, which
# is true of a rename and false of a truncate, and nothing is left behind.
test_lock_write_replaces_the_file_instead_of_truncating_it() {
  local dir state before after leftovers
  dir=$(make_case lock-write-atomic)
  state="$dir/state"
  mkdir -p "$state"
  bash -c '. "$1"; fm_session_lock_write "$2" "$3"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$state" "$$" \
    || fail "the first lock write failed"
  before=$(stat -c %i "$state/.lock" 2>/dev/null || true)
  [ -n "$before" ] || fail "test setup: the first write produced no lock to compare against"
  bash -c '. "$1"; fm_session_lock_write "$2" "$3"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$state" "$$" \
    || fail "the second lock write failed"
  after=$(stat -c %i "$state/.lock" 2>/dev/null || true)
  [ -n "$after" ] || fail "the second write left no lock file at all"
  [ "$before" != "$after" ] \
    || fail "the lock was written in place, so a concurrent reader can still see a half-written file"
  [ "$(sed -n '1p' "$state/.lock")" = "$$" ] \
    || fail "the replaced lock does not name the pid that was written"
  leftovers=$(find "$state" -maxdepth 1 -name '.lock.tmp.*' | wc -l | tr -d '[:space:]')
  [ "$leftovers" = 0 ] || fail "the lock write left $leftovers temporary file(s) behind"
  pass "the session lock is replaced rather than truncated in place"
}

test_ownership_walk_has_exactly_one_implementation() {
  local definitions file text adapter
  # Four near-identical private copies of this walk are how the current drift
  # arose: the adapters each had one, and the Claude path had none. Everything
  # must go through bin/fm-session-lock-lib.sh, directly or through
  # `bin/fm-lock.sh ownership`.
  definitions=$(grep -rl 'fm_session_lock_ownership()' "$ROOT/bin" 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$definitions" = 1 ] || fail "expected exactly one ownership resolver, found $definitions"

  for file in fm-lock.sh fm-watch-arm.sh fm-watch-checkpoint.sh fm-turnend-guard.sh \
    fm-continuity-pretool-check.sh fm-sessionstart-nudge.sh fm-statusline.sh; do
    text=$(cat "$ROOT/bin/$file")
    assert_contains "$text" 'fm-session-lock-lib.sh' "bin/$file must resolve ownership through the shared library"
    assert_not_contains "$text" 'ps -o ppid=' "bin/$file carries its own session-lock ancestry walk"
  done

  for adapter in .opencode/plugins/fm-primary-watch-arm.js .pi/extensions/fm-primary-pi-watch.ts .pi/extensions/fm-primary-turnend-guard.ts; do
    text=$(cat "$ROOT/$adapter")
    assert_contains "$text" 'fm-lock.sh' "$adapter must delegate ownership to the shared entry point"
    assert_contains "$text" '"ownership"' "$adapter must call the ownership subcommand"
    assert_not_contains "$text" 'ps -o ppid=' "$adapter still walks the process ancestry itself"
    assert_not_contains "$text" '.lock`, "utf8"' "$adapter still reads the session lock directly"
  done
  pass "session-lock ownership has exactly one implementation (bin/fm-session-lock-lib.sh)"
}

test_ownership_cli_classifies_and_writes_nothing
test_lock_holder_identity_and_file_format
test_lock_refusal_describes_the_holder_and_names_a_remedy
test_lock_rejects_unknown_arguments_without_touching_state
test_take_over_refuses_a_pid_that_is_not_the_recorded_holder
test_take_over_records_this_session_and_names_what_it_displaced
test_every_remedy_offers_the_take_over_as_its_second_half
test_acquire_records_a_version_named_harness_process
test_a_bash_tool_shell_is_not_a_live_harness
test_the_harness_predicate_has_exactly_one_implementation
test_the_marker_finds_the_session_the_ancestry_walk_cannot_reach
test_an_inherited_marker_for_another_session_is_ignored
test_acquire_records_the_nearest_harness_not_the_one_above_it
test_acquire_inherits_a_lock_that_names_a_live_ancestor
test_a_live_harness_outside_this_ancestry_is_still_refused
test_arm_refuses_when_another_session_owns_the_fleet
test_arm_refuses_restart_when_another_session_owns_the_fleet
test_arm_starts_for_the_owning_session
test_arming_converges_a_lock_that_names_an_ancestor
test_arm_recognises_ownership_several_process_levels_down
test_arm_still_arms_without_a_lock_holder_and_says_so
test_arm_arms_when_the_lock_holder_pid_was_reused
test_checkpoint_is_gated_on_the_session_lock
test_statusline_reports_fleet_control
test_statusline_is_silent_and_writes_nothing_without_fleet_state
test_statusline_says_nothing_in_an_unmarked_linked_worktree
test_statusline_composes_with_the_operators_own_status_line
test_statusline_base_reaches_a_worktree_that_has_no_config_dir
test_statusline_fixtures_are_isolated_from_an_inherited_base
test_statusline_other_branch_names_a_remedy
test_statusline_is_wired_into_claude_settings
test_lock_write_replaces_the_file_instead_of_truncating_it
test_ownership_walk_has_exactly_one_implementation
