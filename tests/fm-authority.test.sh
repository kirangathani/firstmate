#!/usr/bin/env bash
# tests/fm-authority.test.sh - behavior tests for bin/fm-authority.sh, the
# captain's mid-task delivery authority.
#
# Matrix:
#   (a) grant then check passes, with the reason and time printed
#   (b) a hand-written or tampered record does not check as authorized
#   (c) revoke removes one scope, or every scope
#   (d) a granted ci/local skip writes byte-identical authority lines to a
#       spawn-time one, and the merge gate's excusal reads it identically
#   (e) push-default is reported by check and implied by no other scope, and no
#       testing-skip token can stand in for it
#   (f) check is read-only and exits non-zero with no record or no key
#   (g) grant refuses what the delivery mode cannot honour, and non-ship tasks
#   (h) every non-local-only ship brief carries the check clause in rule 1
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTH="$ROOT/bin/fm-authority.sh"
TMP_ROOT=$(fm_test_tmproot fm-authority-tests)

# make_home <name> <mode> [<kind>]: a home with a signing key and one task record.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data"
  head -c 32 /dev/urandom > "$home/config/ci-waiver-secret"
  chmod 600 "$home/config/ci-waiver-secret"
  fm_write_meta "$home/state/t-a1.meta" "kind=${3:-ship}" "mode=$2" "project=$home/project"
  printf '%s\n' "$home"
}

run_auth() {  # <home> <args...>
  local home=$1
  shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    FM_HOME="$home" "$AUTH" "$@" 2>&1
}

mint() {  # <home> <fn> <id>
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; "$1" "$2"' "$ROOT" "$2" "$3" \
    < "$1/config/ci-waiver-secret"
}

test_grant_then_check_passes() {
  local home out status
  home=$(make_home grant direct-PR)
  out=$(run_auth "$home" check t-a1 ci); status=$?
  expect_code 1 "$status" "check reported an ungranted scope as authorized"$'\n'"$out"
  out=$(run_auth "$home" grant t-a1 ci --reason "captain ordered it"); status=$?
  expect_code 0 "$status" "grant failed"$'\n'"$out"
  out=$(run_auth "$home" check t-a1 ci); status=$?
  expect_code 0 "$status" "check did not pass after grant"$'\n'"$out"
  assert_contains "$out" "authorized: t-a1 ci - captain ordered it (granted " "check did not print the reason and time"
  pass "fm-authority: grant then check passes and reports reason and time"
}

test_hand_written_or_tampered_record_fails_check() {
  local home out status
  home=$(make_home tamper direct-PR)
  printf 'ci_skip=on\npush_default=on\n' >> "$home/state/t-a1.meta"
  out=$(run_auth "$home" check t-a1); status=$?
  expect_code 1 "$status" "a bare flag line checked as authorized"$'\n'"$out"
  printf 'ci_skip_auth=%s\n' abababababababababababababababababababababababababababababababab >> "$home/state/t-a1.meta"
  out=$(run_auth "$home" check t-a1 ci); status=$?
  expect_code 1 "$status" "a forged token checked as authorized"$'\n'"$out"
  # A real token lifted from another task does not travel.
  fm_write_meta "$home/state/t-a1.meta" "kind=ship" "mode=direct-PR" "ci_skip=on" \
    "ci_skip_auth=$(mint "$home" fm_ci_waiver_dispatch_token other-a1)"
  out=$(run_auth "$home" check t-a1 ci); status=$?
  expect_code 1 "$status" "another task's token checked as authorized"$'\n'"$out"
  pass "fm-authority: a hand-written, forged, or lifted grant does not check as authorized"
}

test_revoke_removes_scope_or_everything() {
  local home out status
  home=$(make_home revoke no-mistakes)
  run_auth "$home" grant t-a1 all --reason r >/dev/null || fail "grant all failed"
  run_auth "$home" grant t-a1 push-default --reason r >/dev/null || fail "grant push-default failed"
  out=$(run_auth "$home" revoke t-a1 ci); status=$?
  expect_code 0 "$status" "revoke ci failed"$'\n'"$out"
  run_auth "$home" check t-a1 ci >/dev/null && fail "ci still authorized after revoke"
  run_auth "$home" check t-a1 local >/dev/null || fail "revoking ci also revoked local"
  run_auth "$home" check t-a1 push-default >/dev/null || fail "revoking ci also revoked push-default"
  run_auth "$home" revoke t-a1 >/dev/null || fail "revoke of every scope failed"
  out=$(run_auth "$home" check t-a1); status=$?
  expect_code 1 "$status" "a scope survived revoke of every scope"$'\n'"$out"
  assert_no_grep '_skip' "$home/state/t-a1.meta" "revoke left testing-skip lines behind"
  assert_no_grep 'push_default' "$home/state/t-a1.meta" "revoke left push-default lines behind"
  assert_grep 'mode=no-mistakes' "$home/state/t-a1.meta" "revoke dropped an unrelated record line"
  pass "fm-authority: revoke removes one scope, or every scope, and nothing else"
}

test_granted_skip_matches_a_spawn_time_skip() {
  local home out spawned granted
  home=$(make_home equiv no-mistakes)
  run_auth "$home" grant t-a1 all --reason r >/dev/null || fail "grant all failed"
  grep -qx "local_skip_auth=$(mint "$home" fm_ci_waiver_dispatch_local_token t-a1)" "$home/state/t-a1.meta" \
    || fail "granted local token differs from the one spawn mints"
  grep -qx "ci_skip_auth=$(mint "$home" fm_ci_waiver_dispatch_token t-a1)" "$home/state/t-a1.meta" \
    || fail \
    "granted ci token differs from the one spawn mints"
  # The merge gate's excusal reads both records identically.
  fm_write_meta "$home/state/s-a1.meta" "kind=ship" "mode=no-mistakes" "project=$home/project" \
    "local_skip=on" "local_skip_auth=$(mint "$home" fm_ci_waiver_dispatch_local_token s-a1)" \
    "ci_skip=on" "ci_skip_auth=$(mint "$home" fm_ci_waiver_dispatch_token s-a1)"
  authority() {
    bash -c '. "$0/bin/fm-attestation-lib.sh"; fm_attestation_authority "$1" "$2/state/$1.meta" "$2/config" "$2" "$0/bin"' \
      "$ROOT" "$1" "$home" 2>/dev/null
  }
  spawned=$(authority s-a1) || fail "the spawn-time record excused nothing"
  granted=$(authority t-a1) || fail "the granted record excused nothing"
  [ "$spawned" = "$granted" ] || fail "merge-gate excusal differs: spawn [$spawned] grant [$granted]"
  out=$(run_auth "$home" check t-a1 local)
  assert_contains "$out" "authorized: t-a1 local" "check did not report the granted local skip"
  out=$(run_auth "$home" check s-a1 ci)
  assert_contains "$out" "authorized: s-a1 ci - granted at dispatch" "check did not report a spawn-time skip as granted at dispatch"
  pass "fm-authority: a granted testing skip is byte-identical to a spawn-time one at the merge gate"
}

test_push_default_is_its_own_scope() {
  local home out status
  home=$(make_home push no-mistakes)
  run_auth "$home" grant t-a1 all --reason r >/dev/null || fail "grant all failed"
  out=$(run_auth "$home" check t-a1 push-default); status=$?
  expect_code 1 "$status" "a testing skip implied push-default"$'\n'"$out"
  # A testing-skip token pasted beside push_default=on does not verify as it.
  printf 'push_default=on\npush_default_auth=%s\n' "$(mint "$home" fm_ci_waiver_dispatch_token t-a1)" >> "$home/state/t-a1.meta"
  run_auth "$home" check t-a1 push-default >/dev/null && fail "a ci-skip token verified as push-default"
  out=$(run_auth "$home" grant t-a1 push-default --reason "ship straight to main"); status=$?
  expect_code 0 "$status" "grant push-default failed"$'\n'"$out"
  out=$(run_auth "$home" check t-a1 push-default); status=$?
  expect_code 0 "$status" "push-default not authorized after grant"$'\n'"$out"
  assert_contains "$out" "ship straight to main" "push-default check did not print its reason"
  out=$(run_auth "$home" check t-a1)
  assert_contains "$out" "authorized: t-a1 push-default" "a no-scope check omitted push-default"
  run_auth "$home" revoke t-a1 all >/dev/null
  run_auth "$home" check t-a1 push-default >/dev/null || fail "revoking the testing skips revoked push-default"
  pass "fm-authority: push-default is reported by check and implied by no other scope"
}

test_check_is_read_only_and_needs_key_and_record() {
  local home out status before after
  home=$(make_home readonly direct-PR)
  run_auth "$home" grant t-a1 ci --reason r >/dev/null || fail "grant failed"
  before=$(cd "$home" && find . -type f -exec cksum {} + | sort)
  run_auth "$home" check t-a1 >/dev/null
  run_auth "$home" check t-a1 ci >/dev/null
  run_auth "$home" check t-a1 local >/dev/null
  after=$(cd "$home" && find . -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ] || fail "check changed the home"
  out=$(run_auth "$home" check nope-a1 ci); status=$?
  expect_code 1 "$status" "check passed with no record"$'\n'"$out"
  rm -f "$home/config/ci-waiver-secret"
  out=$(run_auth "$home" check t-a1 ci); status=$?
  expect_code 1 "$status" "check passed with no signing key"$'\n'"$out"
  out=$(run_auth "$home" grant t-a1 ci --reason r); status=$?
  expect_code 1 "$status" "grant minted with no signing key"$'\n'"$out"
  pass "fm-authority: check writes nothing and fails with no record or no key"
}

test_grant_refusals() {
  local home out status
  home=$(make_home refuse no-mistakes)
  out=$(run_auth "$home" grant t-a1 ci --reason r); status=$?
  expect_code 1 "$status" "ci alone was granted on a no-mistakes task"$'\n'"$out"
  out=$(run_auth "$home" grant t-a1 local); status=$?
  expect_code 1 "$status" "grant accepted no reason"$'\n'"$out"
  home=$(make_home refuse-lo local-only)
  out=$(run_auth "$home" grant t-a1 push-default --reason r); status=$?
  expect_code 1 "$status" "push-default was granted on a local-only task"$'\n'"$out"
  out=$(run_auth "$home" grant t-a1 testing --reason r); status=$?
  expect_code 1 "$status" "a testing skip was granted on a local-only task"$'\n'"$out"
  home=$(make_home refuse-scout no-mistakes scout)
  out=$(run_auth "$home" grant t-a1 local --reason r); status=$?
  expect_code 1 "$status" "a scout task took a grant"$'\n'"$out"
  assert_no_grep '_auth=' "$home/state/t-a1.meta" "a refused grant still wrote a token"
  pass "fm-authority: grant refuses what the mode cannot honour and non-ship tasks"
}

test_grant_rewrites_the_brief_and_every_brief_carries_the_clause() {
  local home mode brief
  for mode in no-mistakes direct-PR local-only; do
    home=$(make_home "brief-$mode" "$mode")
    printf '%s\n' "- project [$mode]" > "$home/data/projects.md"
    env -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$home" \
      "$ROOT/bin/fm-brief.sh" t-a1 project >/dev/null 2>&1 || fail "scaffold failed for $mode"
    brief="$home/data/t-a1/brief.md"
    if [ "$mode" = local-only ]; then
      assert_no_grep 'fm-authority.sh' "$brief" "a local-only brief carries a clause nothing can grant"
      continue
    fi
    grep -q "Never push to the default branch unless .*fm-authority.sh' check t-a1 push-default" "$brief" \
      || fail "rule 1 is not conditional on the push-default check"
    assert_grep "fm-authority.sh' check t-a1 <local|ci|push-default>" "$brief" "the brief lacks the standing check clause"
  done
  home="$TMP_ROOT/brief-direct-PR"
  run_auth "$home" grant t-a1 ci --reason r >/dev/null || fail "grant failed"
  assert_grep 'CI waiver handshake' "$home/data/t-a1/brief.md" "the grant did not rewrite the brief"
  run_auth "$home" revoke t-a1 ci >/dev/null || fail "revoke failed"
  assert_no_grep 'CI waiver handshake' "$home/data/t-a1/brief.md" "the revoke did not rewrite the brief"
  pass "fm-authority: grant and revoke rewrite the brief, and ship briefs carry the check clause"
}

test_grant_then_check_passes
test_hand_written_or_tampered_record_fails_check
test_revoke_removes_scope_or_everything
test_granted_skip_matches_a_spawn_time_skip
test_push_default_is_its_own_scope
test_check_is_read_only_and_needs_key_and_record
test_grant_refusals
test_grant_rewrites_the_brief_and_every_brief_carries_the_clause
