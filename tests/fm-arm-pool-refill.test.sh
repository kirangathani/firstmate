#!/usr/bin/env bash
# The refill shape of fm-ack, and the rule that keeps scripts out of the pool.
#
# Since the pool became the only shape a steer has, a SUCCESSFUL fm-ack does not
# exit: it execs a waiting arm whenever the pool has room, so ordinary acking
# keeps the pool full with no extra model call. A script that acks on
# firstmate's behalf has more to do afterwards, so it must set
# FM_ARM_POOL_NO_REFILL=1 and get its own prompt back instead.
# bin/fm-arm-pool-lib.sh owns both halves; the fm-send half is pinned in
# tests/fm-send-strict.test.sh, next to that script's other delivery cases.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-arm-pool-refill)

# The exec target is hard-coded relative to the script's own directory, so the
# only way to observe the refill without arming a real watcher against a scratch
# home is to run the scripts from a shim bin/ whose fm-watch-arm.sh is a stub.
# Every OTHER entry is symlinked from the real bin/ at run time, never listed
# here: a hand-maintained list is a second copy of these scripts' dependency
# sets and rots the moment one of them gains a sibling.
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
  local home="$TMP_ROOT/$1-home"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"
  printf '%s\n' "$home"
}

test_a_successful_ack_becomes_a_waiting_arm_when_the_pool_has_room() {
  local bin home out rc
  bin=$(make_shim_bin ack-room); home=$(setup_home ack-room)

  out=$(env -u FM_ARM_POOL_NO_REFILL FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    timeout 30 "$bin/fm-ack.sh" lane-ok "relayed to the captain" 2>&1); rc=$?

  expect_code 0 "$rc" "an ack with room in the pool should hand off to the arm cleanly"
  assert_contains "$out" "acked: lane-ok" "the refill must not change what the ack DOES"
  assert_contains "$out" "stub-arm: --dormant" "a successful ack should exec a dormant waiting arm"
  pass "fm-ack: a successful ack refills the pool by default"
}

test_a_full_pool_leaves_the_ack_with_nothing_to_refill() {
  local bin home out rc
  bin=$(make_shim_bin ack-full); home=$(setup_home ack-full)

  # Sized from the limit it guards, not from a literal: with the target at zero
  # no count can be below it, which is exactly what a full pool means.
  out=$(env -u FM_ARM_POOL_NO_REFILL FM_ARM_POOL_TARGET=0 FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    timeout 30 "$bin/fm-ack.sh" lane-ok "relayed to the captain" 2>&1); rc=$?

  expect_code 0 "$rc" "an ack with a full pool should record and exit 0"
  assert_contains "$out" "acked: lane-ok" "a full pool must not change what the ack DOES"
  assert_not_contains "$out" "stub-arm" "an ack with no room in the pool must exit instead of arming"
  pass "fm-ack: a full pool leaves the ack nothing to refill and it exits"
}

test_the_opt_out_returns_the_ack_to_its_caller() {
  local bin home out rc
  bin=$(make_shim_bin ack-optout); home=$(setup_home ack-optout)

  out=$(FM_ARM_POOL_NO_REFILL=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    timeout 30 "$bin/fm-ack.sh" lane-ok "relayed to the captain" 2>&1); rc=$?

  expect_code 0 "$rc" "an opted-out ack should return to its caller"
  assert_contains "$out" "acked: lane-ok" "the opt-out must not change what the ack DOES"
  assert_not_contains "$out" "stub-arm" "an opted-out ack must never become a waiting arm"
  pass "fm-ack: FM_ARM_POOL_NO_REFILL returns the ack to its caller"
}

test_a_failed_ack_reports_its_error_instead_of_waiting() {
  local bin home out rc
  bin=$(make_shim_bin ack-fail); home=$(setup_home ack-fail)

  out=$(env -u FM_ARM_POOL_NO_REFILL FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    timeout 30 "$bin/fm-ack.sh" no-such-lane "relayed to the captain" 2>&1); rc=$?

  [ "$rc" -ne 0 ] || fail "an ack for an unknown task exited 0"
  [ "$rc" -ne 124 ] || fail "a failed ack became a waiting arm instead of reporting its error"
  assert_contains "$out" "no metadata for 'no-such-lane'" "a failed ack must still report why it failed"
  assert_not_contains "$out" "stub-arm" "a failed ack must never reach the pool"
  pass "fm-ack: a failed ack exits with its error instead of waiting"
}

test_every_bin_caller_of_a_steer_script_opts_out_of_the_refill() {
  # A script that steers or acks has more to do after the call, so it must get
  # its own prompt back. Without the opt-out it would exec a waiting arm instead
  # and simply never return - the script would hang, not fail.
  # Execution position is what the scan looks for, which here is always a quoted
  # variable path, so the banners that PRINT a steer command as advice to the
  # model are correctly left out of it.
  local line hits=0 bad=
  while IFS= read -r line; do
    hits=$((hits + 1))
    case "$line" in
      *FM_ARM_POOL_NO_REFILL*) ;;
      *) bad="$bad$(printf '\n  %s' "$line")" ;;
    esac
  done < <(grep -nE '"\$\{?[A-Za-z_]+\}?[^"]*/fm-(send|ack)\.sh"' "$ROOT"/bin/*.sh || true)
  [ "$hits" -gt 0 ] || fail "the caller scan matched nothing, so it proves nothing"
  [ -z "$bad" ] || fail "a bin/ script runs a steer script without FM_ARM_POOL_NO_REFILL:$bad"
  pass "bin: every script that runs fm-send or fm-ack opts out of the refill"
}

test_a_successful_ack_becomes_a_waiting_arm_when_the_pool_has_room
test_a_full_pool_leaves_the_ack_with_nothing_to_refill
test_the_opt_out_returns_the_ack_to_its_caller
test_a_failed_ack_reports_its_error_instead_of_waiting
test_every_bin_caller_of_a_steer_script_opts_out_of_the_refill
