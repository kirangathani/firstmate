#!/usr/bin/env bash
# tests/fm-review-attest.test.sh - behavior tests for the pipeline-reviewed
# attestation: bin/fm-review-attest.sh, and the payload domain it borrows the
# HMAC and the per-repository key derivation from in bin/fm-ci-waiver-lib.sh.
#
# THE PROPERTY UNDER TEST is that the line means exactly what it says and
# nothing wider: the pipeline's `review` step completed on THIS commit, of THIS
# task, in THIS repository. Every case below is one way that could quietly stop
# being true - a review on an earlier commit, a review that never finished, a
# review that never happened, or a signature minted for another purpose
# entirely.
#
# Matrix:
#   (a) attest signs when a run for the branch reviewed the exact PR head
#   (b) attest refuses when the reviewed commit is not the PR's head
#   (c) attest refuses when the pipeline has no run for the branch at all
#   (d) attest refuses a review step that did not reach `completed`, but a
#       completed review is not masked by a newer run that has not reached one
#   (e) a skipped review refuses without the captain's recorded decision, and
#       is attested with it, naming what it is endorsing
#   (f) attest refuses a task with no durable record and one with no PR
#   (g) attest refuses a repository the task's own checkout does not push to
#   (h) publishing is idempotent: a body already carrying the exact line is left
#       alone, and the PR is edited through a REST PATCH rather than `gh pr edit`
#   (i) --print-only publishes nothing
#   (j) verify round-trips a line attest issued
#   (k) verify refuses another commit, another task, another repository, a
#       forged signature, and a malformed line
#   (l) the `review-attest` domain differs from a CI waiver over the same task
#       and commit, in both directions
#   (m) the key is the repository's already-published FM_CI_WAIVER_SECRET, so an
#       enrolled repository needs no second secret
#   (n) signing always derives from the master, so an ambient FM_CI_WAIVER_SECRET
#       exported for some other repository cannot select the signing key
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATTEST="$ROOT/bin/fm-review-attest.sh"
# The REAL captured DDL of the no-mistakes tables, so a column or constraint the
# live database does not have cannot be asserted against here. Shared with
# tests/fm-timeline.test.sh, which captured it; its README records how.
FIXTURES="$ROOT/tests/fixtures/timeline"
TMP_ROOT=$(fm_test_tmproot fm-review-attest)

command -v sqlite3 >/dev/null 2>&1 || { echo "ok - skipped: sqlite3 not installed"; exit 0; }

SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222
REPO=acme/widgets
OTHER_REPO=acme/other
PR_NUMBER=61
ID=demo

# --- fixtures ---------------------------------------------------------------

# make_home <slug>: a home with config/, state/, data/, a project checkout whose
# origin is $REPO, and a no-mistakes database holding nothing yet. Echoes it.
make_home() {  # <slug>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/project"
  git -C "$home/project" init --quiet
  git -C "$home/project" remote add origin "https://github.com/$REPO.git"
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' \
    > "$home/config/ci-waiver-secret"
  chmod 600 "$home/config/ci-waiver-secret"
  make_db "$home"
  printf '%s\n' "$home"
}

# A database with the live schema and one repo row. Timestamps are epoch SECONDS
# in the real tables, so they are here too.
make_db() {  # <home>
  sqlite3 "$1/nm.sqlite" < "$FIXTURES/schema.sql"
  sqlite3 "$1/nm.sqlite" "
    INSERT INTO repos (id, working_path, upstream_url, default_branch, created_at)
      VALUES ('repo1', '$1/project', 'https://github.com/$REPO', 'main', 100);"
}

# add_run <home> <run-id> <branch> <head-sha> <review-status> [<created-at>]
add_run() {
  sqlite3 "$1/nm.sqlite" "
    INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at)
      VALUES ('$2', 'repo1', '$3', '$4', 'basesha', 'passed', ${6:-100}, ${6:-100});
    INSERT INTO step_results (id, run_id, step_name, step_order, status)
      VALUES ('$2-rev', '$2', 'review', 3, '$5'),
             ('$2-test', '$2', 'test', 4, 'completed');"
}

clear_runs() {  # <home>
  sqlite3 "$1/nm.sqlite" 'DELETE FROM runs; DELETE FROM step_results;'
}

write_task() {  # <home> <id> [<pr-url>]
  fm_write_meta "$1/state/$2.meta" \
    "window=fm-$2" \
    "worktree=$1/project" \
    "project=$1/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "pr=${3:-https://github.com/$REPO/pull/$PR_NUMBER}"
}

# fake_gh <home> <head-sha>: a `gh` that answers the two reads attest makes and
# records every PATCH it is handed. The PR body lives in <home>/pr-body so a
# case can seed it.
fake_gh() {  # <home> <head-sha>
  local home=$1 head=$2 bin="$1/fakebin"
  mkdir -p "$bin"
  [ -f "$home/pr-body" ] || printf 'This PR does a thing.\n' > "$home/pr-body"
  cat > "$bin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/gh-argv"
if [ "\${1:-}" = api ] && [ "\${2:-}" = --method ]; then
  # The real call passes the body as JSON on stdin (--input -), so capture it
  # from there, exactly as the API receives it.
  prev=
  for a in "\$@"; do
    if [ "\$prev" = --input ]; then
      if [ "\$a" = - ]; then cat > "$home/gh-patch.json"; else cp "\$a" "$home/gh-patch.json"; fi
    fi
    prev=\$a
  done
  printf '{}\n'
  exit 0
fi
case "\${4:-}" in
  .head.sha) printf '%s\n' '$head' ;;
  *) cat "$home/pr-body" ;;
esac
SH
  chmod +x "$bin/gh"
}

drop_patch_record() {  # <home>
  find "$1" -maxdepth 1 -name gh-patch.json -delete
}

run_attest() {  # <home> <arg>...
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_REVIEW_ATTEST_DB="$home/nm.sqlite" \
    FM_REVIEW_ATTEST_GH="$home/fakebin/gh" \
    FM_CI_WAIVER_SECRET='' \
    "$ATTEST" "$@" 2>&1
}

run_verify() {  # <home> <arg>...
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_CONFIG_OVERRIDE='' \
    FM_CI_WAIVER_SECRET='' \
    "$ATTEST" verify "$@" 2>&1
}

# line_only <output>: the published line alone, from an attest run's mixed
# stdout and stderr.
line_only() {
  printf '%s\n' "$1" | grep '^fm-review-attest: ' | tail -1
}

# The key the repository's own CI holds - the SAME value fm-ci-waiver.sh
# publishes as FM_CI_WAIVER_SECRET, which is the point of case (m).
waiver_repo_key() {  # <home> [<owner/repo>]
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_repo_key "$1"' \
    "$ROOT" "${2:-$REPO}" < "$1/config/ci-waiver-secret"
}

# A home ready to attest $SHA_A: task, a completed review on it, and a gh whose
# PR head is that commit.
ready_home() {  # <slug> [<head-sha>]
  local home
  home=$(make_home "$1")
  write_task "$home" "$ID"
  add_run "$home" r1 "fm/$ID" "$SHA_A" completed
  fake_gh "$home" "${2:-$SHA_A}"
  printf '%s\n' "$home"
}

# --- the signer -------------------------------------------------------------

test_attest_signs_a_review_that_completed_on_the_prs_head() {
  local home out line
  home=$(ready_home signs)
  out=$(run_attest "$home" attest "$ID" --print-only) || fail "attest refused a reviewed head: $out"
  line=$(line_only "$out")
  [ -n "$line" ] || fail "attest printed no line: $out"
  assert_contains "$line" "fm-review-attest: v1 $ID $SHA_A " \
    "the line must name the version, the task and the exact commit"
  pass "attest signs a review that completed on the PR's head"
}

test_attest_refuses_a_review_of_another_commit() {
  local home out
  # The case the whole design turns on: the pipeline reviewed the branch, but
  # something was pushed afterwards, so the head on the PR is a commit no review
  # has ever seen.
  home=$(ready_home other-commit "$SHA_B")
  out=$(run_attest "$home" attest "$ID" --print-only) && fail "attest signed for an unreviewed head"
  assert_contains "$out" 'none at' "the refusal must say the head was never run on"
  assert_contains "$out" "${SHA_A:0:12}" \
    "the refusal must name the commits that WERE reviewed, so the push is visible"
  pass "attest refuses when the reviewed commit is not the PR's head"
}

test_attest_refuses_when_the_pipeline_never_ran_on_the_branch() {
  local home out
  home=$(ready_home no-run)
  clear_runs "$home"
  out=$(run_attest "$home" attest "$ID" --print-only) && fail "attest signed with no pipeline run at all"
  assert_contains "$out" 'no run at all' "the refusal must name the missing run"
  pass "attest refuses when the pipeline has no run for the branch"
}

test_attest_refuses_a_review_that_did_not_complete() {
  local home out status
  home=$(ready_home unfinished)
  for status in running failed pending; do
    clear_runs "$home"
    add_run "$home" r1 "fm/$ID" "$SHA_A" "$status"
    out=$(run_attest "$home" attest "$ID" --print-only) && fail "attest signed a '$status' review"
    assert_contains "$out" "is '$status', not 'completed'" \
      "the refusal must name the state the review actually reached"
  done
  pass "attest refuses a review step that did not reach completed"
}

test_a_completed_review_is_not_masked_by_a_newer_run() {
  local home out
  # The question is whether this commit was ever reviewed, not what the branch
  # is doing now: a re-run started for a later step must not hide the review
  # that already finished on the same commit.
  home=$(ready_home newer-run)
  add_run "$home" r2 "fm/$ID" "$SHA_A" running 200
  out=$(run_attest "$home" attest "$ID" --print-only) \
    || fail "a newer unfinished run hid a completed review of the same commit: $out"
  [ -n "$(line_only "$out")" ] || fail "attest printed no line: $out"
  pass "a completed review is not masked by a newer run that has not reached one"
}

test_a_skipped_review_needs_the_captains_recorded_decision() {
  local home out
  home=$(ready_home skipped)
  clear_runs "$home"
  add_run "$home" r1 "fm/$ID" "$SHA_A" skipped
  out=$(run_attest "$home" attest "$ID" --print-only) && fail "attest signed a skipped review with no decision"
  assert_contains "$out" 'SKIPPED' "the refusal must say the review was skipped, not reviewed"
  assert_contains "$out" 'review-skip' "the refusal must name the decision that would authorize it"

  mkdir -p "$home/data/$ID"
  cat > "$home/data/$ID/decisions.md" <<EOF
# Gate decisions - $ID

## f-1
- finding: f-1
- key: review-skip
- step: review
- recorded: 2026-09-07T00:00:00Z
- run: r0
- requires: the captain waived this branch review, it only moves a file
- state: pending
- evidence: (none yet)
EOF
  out=$(run_attest "$home" attest "$ID" --print-only) || fail "attest refused a recorded skip decision: $out"
  assert_contains "$out" "it only moves a file" \
    "attest must print what the decision required, so firstmate reads what it endorses"
  [ -n "$(line_only "$out")" ] || fail "attest printed no line for a recorded skip decision"
  pass "a skipped review is attestable only with the captain's recorded decision"
}

test_attest_refuses_a_task_with_no_record_and_a_task_with_no_pr() {
  local home out
  home=$(ready_home no-task)
  out=$(run_attest "$home" attest ghost --print-only) && fail "attest accepted a task with no record"
  assert_contains "$out" 'no durable record' "the refusal must name the missing record"

  fm_write_meta "$home/state/nopr.meta" \
    "window=fm-nopr" "worktree=$home/project" "project=$home/project" "kind=ship"
  out=$(run_attest "$home" attest nopr --print-only) && fail "attest accepted a task with no PR"
  assert_contains "$out" 'no recorded PR' "the refusal must say there is no body to publish into"
  pass "attest refuses a task with no durable record and one with no PR"
}

test_attest_refuses_a_repository_the_task_does_not_belong_to() {
  local home out
  # A consuming workflow accepts a line on its signature alone, so a line issued
  # for an unrelated repository would stand down the review on someone else's PR.
  home=$(ready_home wrong-repo)
  write_task "$home" "$ID" "https://github.com/$OTHER_REPO/pull/$PR_NUMBER"
  out=$(run_attest "$home" attest "$ID" --print-only) && fail "attest signed for another repository"
  assert_contains "$out" 'does not belong to' "the refusal must name the repository mismatch"
  pass "attest refuses a repository the task's own checkout does not push to"
}

# --- publishing -------------------------------------------------------------

test_publishing_uses_a_rest_patch_and_is_idempotent() {
  local home out line body
  home=$(ready_home publish)
  out=$(run_attest "$home" attest "$ID") || fail "attest failed to publish: $out"
  line=$(line_only "$out")
  assert_contains "$out" 'published the attestation' "attest must report the publish"
  assert_grep "PATCH repos/$REPO/pulls/$PR_NUMBER" "$home/gh-argv" \
    "the body must be written with a REST PATCH, not 'gh pr edit', which fails on repos with classic projects"
  assert_no_grep 'pr edit' "$home/gh-argv" "gh pr edit must never be called"
  body=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).body)' \
    "$home/gh-patch.json")
  assert_contains "$body" "$line" "the patched body must carry the line"
  assert_contains "$body" "This PR does a thing." "the patched body must keep what was already there"
  printf '%s\n' "$body" | grep -qxF "$line" || fail "the line must sit on a line of its own"

  # The same PR, now already carrying the line: nothing further is written.
  printf '%s\n' "$body" > "$home/pr-body"
  drop_patch_record "$home"
  out=$(run_attest "$home" attest "$ID") || fail "a second attest failed: $out"
  assert_contains "$out" 'already carries this exact attestation' \
    "a body that already carries the line must be left alone"
  assert_absent "$home/gh-patch.json" "an idempotent run must not PATCH the body again"
  pass "publishing goes through a REST PATCH and is idempotent"
}

test_print_only_publishes_nothing() {
  local home out
  home=$(ready_home print-only)
  out=$(run_attest "$home" attest "$ID" --print-only) || fail "attest --print-only failed: $out"
  assert_contains "$out" '(not published)' "--print-only must say it published nothing"
  assert_absent "$home/gh-patch.json" "--print-only must not PATCH the body"
  pass "--print-only prints the line and publishes nothing"
}

# --- verify -----------------------------------------------------------------

test_verify_round_trips_a_line_attest_issued() {
  local home out line
  home=$(ready_home roundtrip)
  line=$(line_only "$(run_attest "$home" attest "$ID" --print-only)")
  out=$(run_verify "$home" "$REPO" "$ID" "$SHA_A" "$line") || fail "verify refused its own line: $out"
  assert_contains "$out" 'verified: the pipeline reviewed' "verify must report the verdict it reached"
  pass "verify round-trips a line attest issued"
}

test_verify_refuses_another_commit_task_signature_and_shape() {
  local home line forged out
  home=$(ready_home refuse)
  line=$(line_only "$(run_attest "$home" attest "$ID" --print-only)")

  out=$(run_verify "$home" "$REPO" "$ID" "$SHA_B" "$line") && fail "verify accepted a line for another commit"
  assert_contains "$out" 'covers commit' "the refusal must name the commit the line actually covers"

  out=$(run_verify "$home" "$REPO" other "$SHA_A" "${line/$ID/other}") \
    && fail "verify accepted a line relabelled with another task"
  assert_contains "$out" 'does not match' "a relabelled line must fail on its signature"

  out=$(run_verify "$home" "$OTHER_REPO" "$ID" "$SHA_A" "$line") \
    && fail "verify accepted one repository's line for another"
  assert_contains "$out" 'does not match' "a line is bound to the repository it was signed for"

  forged="fm-review-attest: v1 $ID $SHA_A $(printf 'a%.0s' $(seq 64))"
  out=$(run_verify "$home" "$REPO" "$ID" "$SHA_A" "$forged") && fail "verify accepted a forged signature"
  assert_contains "$out" 'does not match' "a forged signature must be refused"

  out=$(run_verify "$home" "$REPO" "$ID" "$SHA_A" "fm-review-attest: v1 $ID $SHA_A") \
    && fail "verify accepted a truncated line"
  assert_contains "$out" 'not a fm-review-attest:' "a malformed line must be refused, never half-read"
  pass "verify refuses another commit, another task, another repository, a forgery and a bad shape"
}

# --- domain separation and the shared key -----------------------------------

test_the_review_attest_domain_differs_from_a_ci_waiver() {
  local home line waiver_line waiver_sig attest_sig out
  # The two grants are not comparable - a waiver skips a PR's whole test suite,
  # this skips one duplicate review - so neither signature may ever verify as
  # the other, over the same task and the same commit and under the same key.
  home=$(ready_home domains)
  line=$(line_only "$(run_attest "$home" attest "$ID" --print-only)")
  attest_sig=${line##* }

  waiver_sig=$(waiver_repo_key "$home" \
    | bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_sign "$1" "$2"' "$ROOT" "$ID" "$SHA_A")
  [ "$attest_sig" != "$waiver_sig" ] \
    || fail "the review attestation and the CI waiver signed the same bytes for one task and commit"

  waiver_line=$(bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_line "$1" "$2" "$3"' \
    "$ROOT" "$ID" "$SHA_A" "$waiver_sig")
  out=$(run_verify "$home" "$REPO" "$ID" "$SHA_A" "$waiver_line") \
    && fail "a CI waiver line verified as a review attestation"
  assert_contains "$out" 'not a fm-review-attest:' "a waiver line is not an attestation"

  # And the other direction: the attestation's signature under the waiver's own
  # label is not a waiver either.
  waiver_repo_key "$home" > "$home/repo-key"
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_check "$1" "$2" "$3"' \
    "$ROOT" "$ID" "$SHA_A" "$attest_sig" < "$home/repo-key" \
    && fail "a review attestation's signature verified as a CI waiver"
  pass "the review-attest domain differs from a CI waiver over the same task and commit"
}

test_the_key_is_the_repositorys_already_published_waiver_secret() {
  local home line out
  # An enrolled repository needs no second `publish` and no second Actions
  # secret: the value its CI already holds is the one that verifies these.
  home=$(ready_home shared-key)
  line=$(line_only "$(run_attest "$home" attest "$ID" --print-only)")
  out=$(FM_CI_WAIVER_SECRET="$(waiver_repo_key "$home")" \
    FM_ROOT_OVERRIDE='' FM_HOME="$TMP_ROOT/no-such-home" FM_CONFIG_OVERRIDE='' \
    "$ATTEST" verify "$REPO" "$ID" "$SHA_A" "$line" 2>&1) \
    || fail "the repository's published waiver key did not verify the attestation: $out"
  assert_contains "$out" 'verified' "FM_CI_WAIVER_SECRET must be the key that verifies a line"
  pass "the key is the repository's already-published FM_CI_WAIVER_SECRET"
}

test_signing_ignores_an_ambient_repository_secret() {
  local home line other
  # verify accepts FM_CI_WAIVER_SECRET because a runner has no master. Signing
  # must not: an operator with that variable exported for one repository would
  # otherwise sign another repository's line with the wrong key, and the
  # mismatch would only surface wherever the line failed to verify.
  home=$(ready_home ambient-secret)
  line=$(line_only "$(run_attest "$home" attest "$ID" --print-only)")
  other=$(FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_REVIEW_ATTEST_DB="$home/nm.sqlite" \
    FM_REVIEW_ATTEST_GH="$home/fakebin/gh" \
    FM_CI_WAIVER_SECRET="$(waiver_repo_key "$home" "$OTHER_REPO")" \
    "$ATTEST" attest "$ID" --print-only 2>&1)
  [ "$(line_only "$other")" = "$line" ] \
    || fail "an ambient FM_CI_WAIVER_SECRET changed the signing key"
  pass "signing derives from the master and ignores an ambient repository secret"
}

test_attest_signs_a_review_that_completed_on_the_prs_head
test_attest_refuses_a_review_of_another_commit
test_attest_refuses_when_the_pipeline_never_ran_on_the_branch
test_attest_refuses_a_review_that_did_not_complete
test_a_completed_review_is_not_masked_by_a_newer_run
test_a_skipped_review_needs_the_captains_recorded_decision
test_attest_refuses_a_task_with_no_record_and_a_task_with_no_pr
test_attest_refuses_a_repository_the_task_does_not_belong_to
test_publishing_uses_a_rest_patch_and_is_idempotent
test_print_only_publishes_nothing
test_verify_round_trips_a_line_attest_issued
test_verify_refuses_another_commit_task_signature_and_shape
test_the_review_attest_domain_differs_from_a_ci_waiver
test_the_key_is_the_repositorys_already_published_waiver_secret
test_signing_ignores_an_ambient_repository_secret
