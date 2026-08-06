#!/usr/bin/env bash
# tests/fm-ci-waiver.test.sh - behavior tests for the CI testing waiver:
# bin/fm-ci-waiver.sh (signer, captain-side), bin/fm-ci-waiver-verify.sh
# (verifier, CI-side), and the payload contract they share through
# bin/fm-ci-waiver-lib.sh.
#
# The property under test is that a waiver cannot be produced by anyone who does
# not hold the secret, and cannot be moved off the commit it was issued for.
# Everything else here supports those two.
#
# Matrix:
#   (a) init writes a mode-600 secret and never prints its value
#   (b) init refuses to overwrite an existing secret; --rotate replaces it
#   (c) sign REFUSES for a task whose record carries no skip flag
#   (d) sign refuses when the task has no durable record at all
#   (e) sign refuses an abbreviated SHA rather than expanding it
#   (e2) sign refuses a ci_skip=on line with no valid dispatch token - absent,
#        forged, or replayed from another task - because a worker can write that
#        line into the same state directory it appends its status lines to
#   (f) a signature issued by sign verifies against that exact commit
#   (g) a FORGED signature does not verify, so the full suite runs
#   (h) a signature issued for one commit does not verify for another
#   (i) a signature is bound to its task id too: relabelling the line breaks it
#   (j) no waiver line at all is quiet and unwaived (the normal-PR case)
#   (k) a waiver line with no repository secret is unwaived and LOUD
#   (l) a malformed waiver line is unwaived and loud, never guessed at
#   (m) a stale line beside a fresh one still verifies (the re-push case)
#   (n) GitHub's CRLF PR bodies verify
#   (o) verify exits 0 for every verdict, because failing the job would SKIP the
#       expensive jobs it gates - the exact fail-open it exists to prevent
#   (p) what a repository holds is DERIVED for it alone: it is not the master,
#       and one repository's key is not another's, so stealing the key CI must
#       necessarily hold is contained to the repository it came from
#   (q) neither the master nor another repository's key verifies a signature
#       issued for this one
#   (r) sign refuses without a valid <owner/repo>, since a signature that did
#       not name its repository could not select a key
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAIVER="$ROOT/bin/fm-ci-waiver.sh"
VERIFY="$ROOT/bin/fm-ci-waiver-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-waiver-tests)

SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222
REPO=acme/widgets
OTHER_REPO=acme/other

# The key a repository's CI actually holds: derived from the home's master for
# that repo alone, never the master itself.
repo_key() {  # <home> [<owner/repo>]
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_repo_key "$1"' \
    "$ROOT" "${2:-$REPO}" < "$1/config/ci-waiver-secret"
}

# A home with config/ and state/ of its own. Echoes the home dir.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$home"
}

# Run a firstmate-side waiver command against <home>, with every ambient
# firstmate override cleared so the test owns its environment.
run_waiver() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    "$WAIVER" "$@" 2>&1
}

# Run the CI-side verifier with an explicit claim/head/secret triple.
run_verify() {  # <secret> <claim> <head-sha> [<github-output-file>]
  FM_CI_WAIVER_SECRET="$1" \
    FM_CI_WAIVER_CLAIM="$2" \
    FM_CI_WAIVER_HEAD_SHA="$3" \
    GITHUB_OUTPUT="${4-}" \
    "$VERIFY" 2>&1
}

# A task record carrying ci_skip=on AND the dispatch token bin/fm-spawn.sh mints
# for it, which is what a genuinely dispatched --ci-skip task looks like.
write_waived_task() {  # <home> <id>
  local auth
  auth=$(bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_dispatch_token "$1"' \
    "$ROOT" "$2" < "$1/config/ci-waiver-secret")
  fm_write_meta "$1/state/$2.meta" \
    "window=fm-$2" \
    "worktree=$1/wt" \
    "project=$1/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "ci_skip=on" \
    "ci_skip_auth=$auth"
}

# The same record with ci_skip=on but no valid dispatch token: exactly what a
# worker can produce by appending one line to the record it already writes its
# status lines beside.
write_self_flagged_task() {  # <home> <id> [<forged-token>]
  fm_write_meta "$1/state/$2.meta" \
    "window=fm-$2" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "ci_skip=on"
  [ -z "${3-}" ] || printf 'ci_skip_auth=%s\n' "$3" >> "$1/state/$2.meta"
}

test_init_writes_private_secret_without_printing_it() {
  local home out mode secret
  home=$(make_home init-basic)
  out=$(run_waiver "$home" init)
  expect_code 0 $? "init should succeed"$'\n'"$out"
  assert_present "$home/config/ci-waiver-secret" "init did not write the secret file"
  # GNU stat first, BSD/macOS stat second, so the permission check runs on both.
  mode=$(stat -c '%a' "$home/config/ci-waiver-secret" 2>/dev/null \
    || stat -f '%Lp' "$home/config/ci-waiver-secret")
  [ "$mode" = "600" ] || fail "secret file should be mode 600, got '$mode'"
  secret=$(repo_key "$home")
  [ "${#secret}" -eq 64 ] || fail "secret should be 32 random bytes as 64 hex chars, got ${#secret}"
  assert_not_contains "$out" "$secret" "init printed the secret value"
  pass "init: writes a mode-600 secret and never prints its value"
}

test_init_refuses_silent_rotation() {
  local home first out second status
  home=$(make_home init-rotate)
  run_waiver "$home" init >/dev/null
  first=$(cat "$home/config/ci-waiver-secret")
  out=$(run_waiver "$home" init); status=$?
  [ "$status" -ne 0 ] || fail "a second init without --rotate should refuse"
  assert_contains "$out" "pass --rotate to replace it" "init did not explain the refusal"
  [ "$(cat "$home/config/ci-waiver-secret")" = "$first" ] || fail "refused init still replaced the secret"
  out=$(run_waiver "$home" init --rotate)
  expect_code 0 $? "init --rotate should succeed"$'\n'"$out"
  second=$(cat "$home/config/ci-waiver-secret")
  [ "$second" != "$first" ] || fail "--rotate produced the same secret"
  pass "init: refuses to overwrite silently, replaces on --rotate"
}

# THE authority check. Nothing else in the design grants authority: the flag is
# written by the captain's own dispatch, into a directory no worker can reach.
test_sign_refuses_a_task_with_no_skip_flag() {
  local home out status
  home=$(make_home sign-unflagged)
  run_waiver "$home" init >/dev/null
  fm_write_meta "$home/state/unflagged-a1.meta" \
    "window=fm-unflagged-a1" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(run_waiver "$home" sign unflagged-a1 "$SHA_A" "$REPO"); status=$?
  [ "$status" -ne 0 ] || fail "sign should refuse a task with no ci_skip=on"
  assert_contains "$out" "was not dispatched with --ci-skip" "sign did not name the missing authorization"
  assert_not_contains "$out" "fm-ci-waiver: v1" "a refused sign must emit no waiver line"
  pass "sign: refuses a task whose record carries no skip flag"
}

test_sign_refuses_without_a_task_record() {
  local home out status
  home=$(make_home sign-norecord)
  run_waiver "$home" init >/dev/null
  out=$(run_waiver "$home" sign ghost-a1 "$SHA_A" "$REPO"); status=$?
  [ "$status" -ne 0 ] || fail "sign should refuse a task with no meta at all"
  assert_contains "$out" "no durable record for task ghost-a1" "sign did not name the missing record"
  pass "sign: refuses a task with no durable record"
}

test_sign_refuses_an_abbreviated_sha() {
  local home out status
  home=$(make_home sign-shortsha)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" short-a1
  out=$(run_waiver "$home" sign short-a1 1111111 "$REPO"); status=$?
  [ "$status" -ne 0 ] || fail "sign should refuse an abbreviated SHA"
  assert_contains "$out" "full 40-character lowercase commit id" "sign did not explain the SHA requirement"
  pass "sign: refuses an abbreviated SHA rather than expanding it"
}

# A worker CAN reach its own state/<id>.meta - it appends every status line into
# that directory - so the bare flag line must not be authority on its own.
test_sign_refuses_a_self_flagged_task() {
  local home out status
  home=$(make_home sign-selfflagged)
  run_waiver "$home" init >/dev/null

  write_self_flagged_task "$home" selfflag-a1
  out=$(run_waiver "$home" sign selfflag-a1 "$SHA_A" "$REPO"); status=$?
  [ "$status" -ne 0 ] || fail "sign accepted a ci_skip=on line with no dispatch token"
  assert_contains "$out" "no valid dispatch authorization" "sign did not name the missing dispatch token"

  # ...and an invented token of the right shape is no better.
  write_self_flagged_task "$home" selfflag-a2 \
    0000000000000000000000000000000000000000000000000000000000000000
  out=$(run_waiver "$home" sign selfflag-a2 "$SHA_A" "$REPO"); status=$?
  [ "$status" -ne 0 ] || fail "sign accepted a forged dispatch token"
  assert_contains "$out" "no valid dispatch authorization" "sign did not reject the forged token"

  # ...and neither is a real token minted for a different task.
  write_waived_task "$home" realdispatch-a3
  local stolen
  stolen=$(grep '^ci_skip_auth=' "$home/state/realdispatch-a3.meta" | cut -d= -f2-)
  write_self_flagged_task "$home" selfflag-a4 "$stolen"
  out=$(run_waiver "$home" sign selfflag-a4 "$SHA_A" "$REPO"); status=$?
  [ "$status" -ne 0 ] || fail "sign accepted another task's dispatch token"
  assert_contains "$out" "no valid dispatch authorization" "sign did not reject the replayed token"
  pass "sign: ci_skip=on is not authority without this task's own dispatch token"
}

test_signature_verifies_for_its_own_commit() {
  local home line secret out gho
  home=$(make_home verify-good)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" good-a1
  line=$(run_waiver "$home" sign good-a1 "$SHA_A" "$REPO")
  expect_code 0 $? "sign should succeed for a flagged task"$'\n'"$line"
  assert_contains "$line" "fm-ci-waiver: v1 good-a1 $SHA_A " "sign did not print the publishable line"
  secret=$(repo_key "$home")
  gho="$home/github-output"
  out=$(run_verify "$secret" "## Summary
does a thing

$line
" "$SHA_A" "$gho")
  expect_code 0 $? "verify should exit 0"$'\n'"$out"
  assert_contains "$out" "waived=true" "a genuine waiver did not verify"
  assert_contains "$out" "::notice::" "a granted waiver must be announced, not silent"
  assert_grep "waived=true" "$gho" "verify did not publish its verdict to GITHUB_OUTPUT"
  pass "verify: a genuine signature waives its own commit"
}

test_forged_signature_runs_the_full_suite() {
  local home line forged secret out
  home=$(make_home verify-forged)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" forged-a1
  line=$(run_waiver "$home" sign forged-a1 "$SHA_A" "$REPO")
  secret=$(repo_key "$home")
  # Same grammar, same task, same commit - only the signature is invented, which
  # is exactly what an agent trying to exempt itself can produce.
  forged="${line% *} 0000000000000000000000000000000000000000000000000000000000000000"
  out=$(run_verify "$secret" "$forged" "$SHA_A")
  expect_code 0 $? "verify should exit 0 even for a forgery"$'\n'"$out"
  assert_contains "$out" "waived=false" "a forged signature was accepted"
  assert_contains "$out" "::warning::" "a forged signature was refused silently"
  assert_contains "$out" "does not verify" "the refusal did not name the bad signature"
  pass "verify: a forged signature is refused loudly and the full suite runs"
}

test_signature_does_not_travel_to_another_commit() {
  local home line secret out
  home=$(make_home verify-othercommit)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" travel-a1
  line=$(run_waiver "$home" sign travel-a1 "$SHA_A" "$REPO")
  secret=$(repo_key "$home")
  # The line is byte-for-byte genuine; only the head commit has moved on, which
  # is what happens after any further push.
  out=$(run_verify "$secret" "$line" "$SHA_B")
  expect_code 0 $? "verify should exit 0"$'\n'"$out"
  assert_contains "$out" "waived=false" "a signature issued for one commit waived another"
  assert_contains "$out" "bound to commit $SHA_A" "the refusal did not name the commit the waiver covers"
  pass "verify: a signature issued for one commit does not validate for another"
}

test_signature_is_bound_to_its_task_id() {
  local home line secret relabelled out
  home=$(make_home verify-relabel)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" real-a1
  line=$(run_waiver "$home" sign real-a1 "$SHA_A" "$REPO")
  secret=$(repo_key "$home")
  relabelled=${line/real-a1/other-b2}
  out=$(run_verify "$secret" "$relabelled" "$SHA_A")
  assert_contains "$out" "waived=false" "a relabelled waiver line was accepted"
  pass "verify: the task id is inside the signed payload, so relabelling breaks it"
}

test_absent_waiver_is_quiet_and_unwaived() {
  local home secret out
  home=$(make_home verify-absent)
  run_waiver "$home" init >/dev/null
  secret=$(repo_key "$home")
  out=$(run_verify "$secret" "## Summary
An ordinary PR body with no waiver in it at all.
" "$SHA_A")
  expect_code 0 $? "verify should exit 0"$'\n'"$out"
  assert_contains "$out" "waived=false" "an ordinary PR was somehow waived"
  assert_not_contains "$out" "::warning::" "an ordinary PR must not be annotated"
  assert_not_contains "$out" "::notice::" "an ordinary PR must not be annotated"
  pass "verify: no waiver line is quiet and unwaived"
}

test_missing_repository_secret_is_unwaived_and_loud() {
  local home line out
  home=$(make_home verify-nosecret)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" nosecret-a1
  line=$(run_waiver "$home" sign nosecret-a1 "$SHA_A" "$REPO")
  out=$(run_verify "" "$line" "$SHA_A")
  expect_code 0 $? "verify should exit 0"$'\n'"$out"
  assert_contains "$out" "waived=false" "a waiver was granted with no secret to verify it against"
  assert_contains "$out" "no FM_CI_WAIVER_SECRET" "the unverifiable waiver was not explained"
  pass "verify: a waiver offered with no repository secret is refused loudly"
}

test_malformed_waiver_line_is_refused() {
  local home secret out
  home=$(make_home verify-malformed)
  run_waiver "$home" init >/dev/null
  secret=$(repo_key "$home")
  out=$(run_verify "$secret" "fm-ci-waiver: please skip the tests" "$SHA_A")
  assert_contains "$out" "waived=false" "a malformed waiver line was accepted"
  assert_contains "$out" "does not match the waiver grammar" "a malformed line was not explained"
  pass "verify: a malformed waiver line is refused, never guessed at"
}

test_stale_line_beside_a_fresh_one_still_verifies() {
  local home stale fresh secret out
  home=$(make_home verify-repush)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" repush-a1
  stale=$(run_waiver "$home" sign repush-a1 "$SHA_A" "$REPO")
  fresh=$(run_waiver "$home" sign repush-a1 "$SHA_B" "$REPO")
  secret=$(repo_key "$home")
  out=$(run_verify "$secret" "$stale
$fresh" "$SHA_B")
  assert_contains "$out" "waived=true" "a fresh waiver was rejected because a stale one sat above it"
  pass "verify: after a re-push, a fresh line verifies alongside the stale one"
}

test_crlf_pr_body_verifies() {
  local home line secret out
  home=$(make_home verify-crlf)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" crlf-a1
  line=$(run_waiver "$home" sign crlf-a1 "$SHA_A" "$REPO")
  secret=$(repo_key "$home")
  out=$(run_verify "$secret" "$(printf '## Summary\r\n\r\n%s\r\n' "$line")" "$SHA_A")
  assert_contains "$out" "waived=true" "a CRLF PR body (what GitHub actually sends) did not verify"
  pass "verify: GitHub's CRLF PR bodies verify"
}

# --- (p)(q)(r) per-repository key derivation ---------------------------------
#
# The ci-waiver job necessarily holds the secret in its environment, and on a
# pull_request build it sits beside PR-authored code, so a repository key is the
# realistic thing to lose. These cases are the containment argument.

test_published_key_is_derived_per_repository() {
  local home master key_a key_b
  home=$(make_home derive-distinct)
  run_waiver "$home" init >/dev/null
  master=$(cat "$home/config/ci-waiver-secret")
  key_a=$(repo_key "$home" "$REPO")
  key_b=$(repo_key "$home" "$OTHER_REPO")
  case "$key_a" in
    *[!0-9a-f]*) fail "a derived repository key must be hex, got '$key_a'" ;;
  esac
  [ "${#key_a}" -eq 64 ] || fail "a derived repository key must be 64 hex chars, got ${#key_a}"
  [ "$key_a" != "$master" ] || fail "the master key itself was published to the repository"
  [ "$key_b" != "$master" ] || fail "the master key itself was published to the repository"
  [ "$key_a" != "$key_b" ] || fail "two repositories were given the same key, so a theft is not contained"
  pass "derive: each repository gets its own key and never the master"
}

test_another_repositorys_key_does_not_verify() {
  local home line out
  home=$(make_home derive-containment)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" contain-a1
  line=$(run_waiver "$home" sign contain-a1 "$SHA_A" "$REPO")

  # The key this repository's CI holds.
  out=$(run_verify "$(repo_key "$home" "$REPO")" "$line" "$SHA_A")
  assert_contains "$out" "waived=true" "the repository's own key did not verify its own waiver"

  # A key stolen from a different repository must be worthless here.
  out=$(run_verify "$(repo_key "$home" "$OTHER_REPO")" "$line" "$SHA_A")
  assert_contains "$out" "waived=false" "another repository's key verified this repository's waiver"

  # And so must the master, which is never published anywhere.
  out=$(run_verify "$(cat "$home/config/ci-waiver-secret")" "$line" "$SHA_A")
  assert_contains "$out" "waived=false" "the master key verified a waiver, so publishing it would be equivalent"
  pass "derive: a stolen key is contained to the repository it came from"
}

test_sign_refuses_without_a_repository() {
  local home out status
  home=$(make_home sign-norepo)
  run_waiver "$home" init >/dev/null
  write_waived_task "$home" norepo-a1

  out=$(run_waiver "$home" sign norepo-a1 "$SHA_A"); status=$?
  [ "$status" -ne 0 ] || fail "sign should refuse without an <owner/repo>"
  assert_contains "$out" "requires the <owner/repo>" "sign did not name the missing repository"
  assert_not_contains "$out" "fm-ci-waiver: v1" "a refused sign must emit no waiver line"

  out=$(run_waiver "$home" sign norepo-a1 "$SHA_A" 'not a repo'); status=$?
  [ "$status" -ne 0 ] || fail "sign should refuse a malformed <owner/repo>"
  assert_contains "$out" "is not a valid <owner/repo>" "sign did not explain the malformed repository"
  pass "sign: refuses unless the signature names the repository it is for"
}

test_init_writes_private_secret_without_printing_it
test_init_refuses_silent_rotation
test_published_key_is_derived_per_repository
test_another_repositorys_key_does_not_verify
test_sign_refuses_without_a_repository
test_sign_refuses_a_task_with_no_skip_flag
test_sign_refuses_without_a_task_record
test_sign_refuses_an_abbreviated_sha
test_sign_refuses_a_self_flagged_task
test_signature_verifies_for_its_own_commit
test_forged_signature_runs_the_full_suite
test_signature_does_not_travel_to_another_commit
test_signature_is_bound_to_its_task_id
test_absent_waiver_is_quiet_and_unwaived
test_missing_repository_secret_is_unwaived_and_loud
test_malformed_waiver_line_is_refused
test_stale_line_beside_a_fresh_one_still_verifies
test_crlf_pr_body_verifies
