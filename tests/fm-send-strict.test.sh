#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    printf '%%1\n'
    exit 0 ;;
  list-panes)
    # Endpoint-liveness primitive (bin/backends/tmux.sh
    # fm_backend_tmux_target_exists): real tmux resolves the target and prints
    # its '#{window_name}', failing on a gone window - which is what
    # FM_FAKE_TMUX_DEAD_TARGET models here.
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    printf '%s\n' "${target##*:}"
    exit 0 ;;
  capture-pane)
    printf '\xe2\x94\x82 \xe2\x94\x82\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# Running fm-send from a shim bin/ is the only way to observe the refill without
# arming a real watcher against a scratch home: the exec target is hard-coded
# relative to the script's own directory. Every entry except fm-watch-arm.sh is
# symlinked from the real bin/ at run time, never listed here, because a
# hand-maintained list is a second copy of fm-send's dependency set and rots the
# moment it gains a sibling.
make_shim_bin() {  # <name> -> echoes the shim bin dir
  local name=$1 bin f
  bin="$TMP_ROOT/$name/bin"
  mkdir -p "$bin"
  for f in "$ROOT"/bin/*; do
    [ "${f##*/}" = "fm-watch-arm.sh" ] && continue
    ln -s "$f" "$bin/${f##*/}"
  done
  cat > "$bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'stub-arm: %s\n' "$*"
SH
  chmod +x "$bin/fm-watch-arm.sh"
  printf '%s\n' "$bin"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_a_successful_send_becomes_a_waiting_arm_when_the_pool_has_room() {
  # The whole point of the one shape: the model already paid for this call, so a
  # send that has delivered spends what is left of itself being an ear.
  local dir fb home bin log out rc
  dir="$TMP_ROOT/refill-room"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home refill-room); bin=$(make_shim_bin refill-room)
  log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  out=$(env -u FM_ARM_POOL_NO_REFILL PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 timeout 30 "$bin/fm-send.sh" fm-lane-ok "hello captain" 2>&1); rc=$?

  expect_code 0 "$rc" "a send with room in the pool should hand off to the arm cleanly"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-ok literal=1 arg=hello captain" "the refill must not change what the send DOES"
  assert_contains "$out" "stub-arm: --dormant" "a successful send should exec a dormant waiting arm"
  pass "fm-send strict: a successful send refills the pool by default"
}

test_a_key_send_becomes_a_waiting_arm_too() {
  # The trust-dialog form firstmate uses (--key Enter against a raw window
  # target) goes through the same one shape, so it must refill the same way.
  local dir fb home bin log out rc
  dir="$TMP_ROOT/refill-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home refill-key); bin=$(make_shim_bin refill-key)
  log="$dir/tmux.log"; : > "$log"

  out=$(env -u FM_ARM_POOL_NO_REFILL PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 timeout 30 "$bin/fm-send.sh" sess:fm-lane-ok --key Enter 2>&1); rc=$?

  expect_code 0 "$rc" "a --key send with room in the pool should hand off to the arm cleanly"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-ok literal=0 arg=Enter" "the refill must not change what a --key send DOES"
  assert_contains "$out" "stub-arm: --dormant" "a successful --key send should exec a dormant waiting arm"
  pass "fm-send strict: a --key send refills the pool the same way"
}

test_the_opt_out_returns_the_send_to_its_caller() {
  # What every bin/ script that steers a worker relies on: it has more to do
  # after the steer, so it must get its own prompt back instead of becoming an
  # arm. tests/fm-arm-pool-refill.test.sh pins that no such script forgets it.
  local dir fb home bin log out rc
  dir="$TMP_ROOT/refill-optout"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home refill-optout); bin=$(make_shim_bin refill-optout)
  log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  out=$(FM_ARM_POOL_NO_REFILL=1 PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 timeout 30 "$bin/fm-send.sh" fm-lane-ok "hello captain" 2>&1); rc=$?

  expect_code 0 "$rc" "an opted-out send should return to its caller"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-ok literal=1 arg=hello captain" "the opt-out must not change what the send DOES"
  assert_not_contains "$out" "stub-arm" "an opted-out send must never become a waiting arm"
  pass "fm-send strict: FM_ARM_POOL_NO_REFILL returns the send to its caller"
}

test_refill_send_with_a_full_pool_delivers_then_exits() {
  # A full pool has no room for another waiting arm, so the send has to deliver
  # and then get out of the way promptly. --refill rides along here as the
  # accepted no-op it now is: it must select nothing and change nothing.
  local dir fb home log rc got pool now i pid pids= target
  dir="$TMP_ROOT/refill-full"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home refill-full); log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"
  pool="$home/state/.arm-pool"
  mkdir -p "$pool"
  # Filled to the pool's OWN target, read from the library that owns it, so this
  # still describes a full pool if that number ever changes.
  target=$(bash -c '. "$1/bin/fm-arm-pool-lib.sh"; printf %s "$FM_ARM_POOL_TARGET"' _ "$ROOT")
  now=$(date +%s)
  i=0
  while [ "$i" -lt "$target" ]; do
    sleep 60 &
    pid=$!
    pids="$pids $pid"
    printf '\t\t%s\tdormant\n' "$now" > "$pool/$pid"
    i=$((i + 1))
  done

  env -u FM_ARM_POOL_NO_REFILL PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    timeout 30 "$SEND" --refill fm-lane-ok "hello captain" >/dev/null 2>/dev/null; rc=$?
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  expect_code 0 "$rc" "a send with a full pool should deliver and exit 0"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "a full-pool send must still type its literal text"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "a full-pool send must still submit with Enter"
  pass "fm-send strict: a full pool leaves the send nothing to refill and it exits"
}

test_send_that_fails_exits_instead_of_waiting() {
  # The rule that keeps a failure visible: a send that did not land must come back
  # with its error at once, never disappear into the pool where the model would
  # hear nothing until the next wake.
  local dir fb home err rc
  dir="$TMP_ROOT/refill-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home refill-fail); err="$dir/send.err"

  env -u FM_ARM_POOL_NO_REFILL PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    timeout 30 "$SEND" fm-nosuchlane "hello captain" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a send to an unresolvable target exited 0"
  [ "$rc" -ne 124 ] || fail "a failed send waited as a dormant arm instead of reporting its error"
  assert_contains "$(cat "$err")" "no metadata for fm-nosuchlane" "a failed send must still report why it failed"
  pass "fm-send strict: a send that fails exits with its error instead of waiting"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_healthy_fm_id_send_still_works
test_a_successful_send_becomes_a_waiting_arm_when_the_pool_has_room
test_a_key_send_becomes_a_waiting_arm_too
test_the_opt_out_returns_the_send_to_its_caller
test_refill_send_with_a_full_pool_delivers_then_exits
test_send_that_fails_exits_instead_of_waiting
