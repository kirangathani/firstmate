#!/usr/bin/env bash
# tests/fm-supersession-attest.test.sh - behavior tests for the captain-signed
# supersession attestation: bin/fm-supersession-attest.sh (signer, captain-side),
# bin/fm-supersession-verify.sh (verifier, CI-side), and the wire they share
# through bin/fm-supersession-attest-lib.sh.
#
# THE PROPERTY UNDER TEST is that the SIGNATURE is what confers authority, never
# the file and never the label. An approval that is not signed by this home's
# key, or is signed for another commit, another task, another repository or
# another purpose, excuses nothing - and an approval that IS signed excuses only
# the identifiers the captain actually approved. Everything else here supports
# those two.
#
# Matrix:
#   (a) sign refuses a task with no durable record at all
#   (b) sign refuses when the project has no approval record: an attestation
#       carries approvals that exist, it never creates one
#   (c) sign refuses a record holding no fully-formed entry, rather than
#       attesting an empty approval set
#   (d) sign refuses an abbreviated SHA rather than expanding it
#   (e) sign refuses a repository the task's own checkout does not push to
#   (f) sign refuses with no secret at all, so a worker that found the record
#       still cannot mint a line
#   (g) the published line carries the approved entries' MATCHING half and never
#       the captain's stated reason or the date it was approved
#   (h) a line issued by sign verifies against that exact commit, and the
#       verifier hands on exactly the entries the record holds
#   (i) a FORGED signature does not verify, so every finding blocks
#   (j) a line issued for one commit does not verify for another
#   (k) a line is bound to its task id too: relabelling it breaks it
#   (l) a line whose ENTRY TOKEN was edited after signing does not verify, which
#       is what stops an approval being widened after the captain granted it
#   (m) no attestation line at all is quiet and unverified (the normal-PR case)
#   (n) an attestation with no repository secret is unverified and LOUD
#   (o) a malformed attestation line is unverified and loud, never guessed at
#   (p) GitHub's CRLF PR bodies verify
#   (q) verify exits 0 for every verdict, because the required check depends on
#       this job and a failed dependency would leave that check never reporting
#   (r) the body is read LIVE from GitHub, not from an event payload: an
#       approval always arrives as an edit to an open PR, and a re-run replays
#       the payload the PR had before it
#   (s) what a repository holds is derived for it AND for this purpose: it is
#       not the master, not another repository's key, and NOT that repository's
#       CI-waiver key, so a theft of the key that skips a whole suite cannot
#       mint an approval and a theft of this one cannot skip a suite
#   (t) a CI waiver line is not an attestation and an attestation is not a CI
#       waiver, whichever body either is pasted into
#   (u) end to end: signed and covered findings are excused, an uncovered
#       finding beside them still blocks, and an unsigned copy of the same
#       approvals excuses nothing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATTEST="$ROOT/bin/fm-supersession-attest.sh"
VERIFY="$ROOT/bin/fm-supersession-verify.sh"
REVERIFY="$ROOT/bin/fm-reverify-base.sh"
TMP_ROOT=$(fm_test_tmproot fm-supersession-attest)

SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222
REPO=acme/widgets
OTHER_REPO=acme/other
PR_NUMBER=61

# The captain's private prose. Every case that inspects a published line looks
# for THIS string, because the one thing that must never reach a public PR body
# is why the captain approved the override.
PRIVATE_REASON='the captain says this is the requested behaviour change, not a regression'

# --- fixtures ---------------------------------------------------------------

# make_home <slug>: a home with config/, state/, data/ and a project checkout
# whose origin is $REPO. Echoes the home dir.
make_home() {  # <slug>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data/supersessions" "$home/project"
  git -C "$home/project" init --quiet
  git -C "$home/project" remote add origin "https://github.com/$REPO.git"
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' \
    > "$home/config/ci-waiver-secret"
  chmod 600 "$home/config/ci-waiver-secret"
  printf '%s\n' "$home"
}

write_task() {  # <home> <id>
  fm_write_meta "$1/state/$2.meta" \
    "window=fm-$2" \
    "worktree=$1/project" \
    "project=$1/project" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"
}

# The record the captain approves. Its reason field is the private half.
write_record() {  # <home> <project-name>
  cat > "$1/data/supersessions/$2.md" <<EOF
# Captain-approved test-assertion supersessions - $2

- id: tests/a.test.sh::alpha holds | project: $2 | date: 2026-08-13 | reason: $PRIVATE_REASON
- ids: tests/b.test.sh::* | project: $2 | kind: failing | date: 2026-08-13 | reason: $PRIVATE_REASON
EOF
}

run_attest() {  # <home> <arg>...
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    "$ATTEST" "$@" 2>&1
}

# The key a repository's re-verification job actually holds: derived from the
# home's master for that repo and this purpose alone, never the master itself.
repo_key() {  # <home> [<owner/repo>]
  bash -c '. "$0/bin/fm-supersession-attest-lib.sh"; fm_supersession_attest_repo_key "$1"' \
    "$ROOT" "${2:-$REPO}" < "$1/config/ci-waiver-secret"
}

# The CI-WAIVER key for the same repository, for the cases that prove the two
# published keys are different keys with different powers.
waiver_repo_key() {  # <home> [<owner/repo>]
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_repo_key "$1"' \
    "$ROOT" "${2:-$REPO}" < "$1/config/ci-waiver-secret"
}

# fake_gh <dir> <body-file>: a `gh` whose `pr view --json body` prints that
# file. The verifier reads the PR body through gh at job time; the cases drive
# that read rather than an env-var seam production never uses.
fake_gh() {  # <dir> <body-file>
  local dir=$1 body=$2 bin
  bin="$1/fakebin"
  mkdir -p "$bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s/gh-argv"\n' "$dir"
    printf 'cat "%s"\n' "$body"
  } > "$bin/gh"
  chmod +x "$bin/gh"
  printf '%s\n' "$bin/gh"
}

RC=0
OUT=
run_verify() {  # <gh> <secret> <head-sha> [<github-output-file>]
  RC=0
  OUT=$(FM_SUPERSESSION_GH="$1" \
    FM_SUPERSESSION_SECRET="$2" \
    FM_SUPERSESSION_HEAD_SHA="$3" \
    FM_SUPERSESSION_REPO="$REPO" \
    FM_SUPERSESSION_PR="$PR_NUMBER" \
    GITHUB_OUTPUT="${4-}" \
    "$VERIFY" 2>&1) || RC=$?
}

# body_with <dir> <slug> <line>...: a PR body carrying prose and those lines.
body_with() {  # <dir> <slug> <line>...
  local dir=$1 slug=$2 file line
  shift 2
  file="$dir/body-$slug"
  printf 'This PR does a thing.\n\nSome prose.\n' > "$file"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
  printf '%s\n' "$file"
}

# sign_for <home> <id> <sha> [<repo>]: the published line alone, with the
# signer's own stderr note dropped.
sign_for() {  # <home> <id> <sha> [<repo>]
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$1" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    "$ATTEST" sign "$2" "$3" "${4:-$REPO}" 2>/dev/null
}

# --- the signer refuses -----------------------------------------------------

test_sign_refuses_a_task_with_no_durable_record() {
  local home out
  home=$(make_home no-task)
  out=$(run_attest "$home" sign ghost "$SHA_A" "$REPO") && fail "sign accepted a task with no record"
  assert_contains "$out" 'no durable record' \
    "sign must name the missing record rather than inventing an approval for it"
  pass "sign refuses a task with no durable record"
}

test_sign_refuses_when_the_project_has_no_approval_record() {
  local home out
  # The case that must never soften: an attestation carries an approval that
  # already exists. If it could stand in for one, the signature would be the
  # approval, and the captain's decision would have been skipped entirely.
  home=$(make_home no-record)
  write_task "$home" demo
  out=$(run_attest "$home" sign demo "$SHA_A" "$REPO") && fail "sign attested a project with no approvals"
  assert_contains "$out" 'nothing to attest' \
    "sign must refuse rather than attest an approval that was never granted"
  pass "sign refuses a project whose captain has approved nothing"
}

test_sign_refuses_a_record_with_no_fully_formed_entry() {
  local home out
  home=$(make_home empty-record)
  write_task "$home" demo
  cat > "$home/data/supersessions/project.md" <<EOF
# Captain-approved supersessions
- id: tests/a.test.sh::alpha holds | project: project | reason: $PRIVATE_REASON
EOF
  out=$(run_attest "$home" sign demo "$SHA_A" "$REPO") && fail "sign attested a malformed entry"
  assert_contains "$out" 'no fully-formed entry' \
    "an entry the merge gate would refuse must not be attested to CI either"
  pass "sign refuses a record whose only entry the fleet's own matcher rejects"
}

test_sign_refuses_an_abbreviated_sha() {
  local home out
  home=$(make_home short-sha)
  write_task "$home" demo
  write_record "$home" project
  out=$(run_attest "$home" sign demo 1111111 "$REPO") && fail "sign accepted an abbreviated SHA"
  assert_contains "$out" '40-character' \
    "sign must refuse an abbreviation the verifier could never resolve"
  pass "sign refuses an abbreviated commit id"
}

test_sign_refuses_a_repository_the_task_does_not_belong_to() {
  local home out
  # The verifier accepts a line on its signature alone and never checks that the
  # task named in it has anything to do with the PR carrying it, so a line signed
  # for an unrelated repository would excuse findings on unrelated work.
  home=$(make_home wrong-repo)
  write_task "$home" demo
  write_record "$home" project
  out=$(run_attest "$home" sign demo "$SHA_A" "$OTHER_REPO") && fail "sign accepted a foreign repository"
  assert_contains "$out" 'does not belong to' \
    "sign must name the mismatch rather than issue a line for someone else's PR"
  pass "sign refuses a repository the task's own checkout does not push to"
}

test_sign_refuses_with_no_secret_at_all() {
  local home out
  # The record alone is not authority: without this home's key there is no line
  # to publish, which is what stops anyone who merely reaches the record.
  home=$(make_home no-secret)
  write_task "$home" demo
  write_record "$home" project
  rm -f "$home/config/ci-waiver-secret"
  out=$(run_attest "$home" sign demo "$SHA_A" "$REPO") && fail "sign issued a line with no secret"
  assert_contains "$out" 'no signing secret' \
    "sign must name the missing key rather than publish an unsigned approval"
  pass "sign refuses to issue an attestation without this home's key"
}

# --- what the line carries --------------------------------------------------

test_the_line_carries_the_approvals_matching_half_and_never_the_reason() {
  local home line
  home=$(make_home published)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  [ -n "$line" ] || fail "sign printed no line"

  assert_not_contains "$line" "$PRIVATE_REASON" \
    "the captain's stated reason must never reach a public PR body"
  assert_not_contains "$line" '2026-08-13' \
    "the approval's date is part of the private record, not of what CI needs"
  case "$line" in
    'fm-supersession: v1 demo '"$SHA_A"' '*) : ;;
    *) fail "the published line does not match its own grammar: $line" ;;
  esac
  assert_not_contains "$line" 'fm-ci-waiver' \
    "an attestation must not be published under the CI waiver's label: they mean opposite things"
  pass "the published line carries the approvals' matching half alone, never the captain's reason"
}

# --- the verifier -----------------------------------------------------------

test_a_signed_line_verifies_and_hands_on_the_approved_entries() {
  local home line gh body out_file
  home=$(make_home verifies)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  body=$(body_with "$home" ok "$line")
  gh=$(fake_gh "$home" "$body")
  out_file="$home/gh-output"
  : > "$out_file"
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A" "$out_file"

  expect_code 0 "$RC" "the verifier must complete whatever its verdict"
  assert_contains "$OUT" 'superseded=true' \
    "a line signed by this repository's key for this commit must verify"
  assert_contains "$OUT" 'entry: id any tests/a.test.sh::alpha holds' \
    "the verifier must say in plain words which approvals it accepted"
  assert_contains "$(cat "$out_file")" 'ids	failing	tests/b.test.sh::*' \
    "the verified entries must reach the next job in the canonical form the matcher reads"
  assert_not_contains "$(cat "$out_file")" "$PRIVATE_REASON" \
    "nothing the verifier hands on may carry the captain's private reason"
  pass "a signed attestation verifies and hands on exactly the approved entries"
}

test_a_forged_signature_does_not_verify() {
  local home line forged body gh
  home=$(make_home forged)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  # Every field kept, the signature replaced: what an agent that can read the
  # grammar but not the secret would be able to produce.
  forged=$(printf '%s\n' "$line" | awk '{ $NF = "0000000000000000000000000000000000000000000000000000000000000000"; print }')
  body=$(body_with "$home" forged "$forged")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"

  expect_code 0 "$RC" "a refused attestation is a verdict, not an error"
  assert_contains "$OUT" 'superseded=false' \
    "a signature this repository's key does not reproduce must excuse nothing"
  assert_contains "$OUT" '::warning::' \
    "a refused attestation must be loud, not silently ignored"
  pass "a forged signature excuses nothing"
}

test_a_line_bound_to_another_commit_does_not_verify() {
  local home line body gh
  home=$(make_home other-commit)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  body=$(body_with "$home" stale "$line")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_B"

  assert_contains "$OUT" 'superseded=false' \
    "an approval for one commit must not carry to another"
  assert_contains "$OUT" "$SHA_A" \
    "the warning must name the commit the line was actually issued for"
  pass "an attestation issued for one commit does not verify for another"
}

test_a_line_relabelled_with_another_task_does_not_verify() {
  local home line relabelled body gh
  home=$(make_home relabel)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  relabelled=${line/ demo / other }
  body=$(body_with "$home" relabelled "$relabelled")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"

  assert_contains "$OUT" 'superseded=false' \
    "the task id is signed too, so relabelling a line must break it"
  pass "an attestation relabelled with another task id does not verify"
}

test_a_widened_entry_token_does_not_verify() {
  local home line widened wide_token body gh
  # The attack this closes: take a real signature and swap in an approval set the
  # captain never granted - the batch entry that excuses everything.
  home=$(make_home widened)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  wide_token=$(printf 'ids\tany\t*\n' \
    | bash -c '. "$0/bin/fm-supersession-attest-lib.sh"; fm_supersession_token_encode' "$ROOT")
  widened=$(printf '%s\n' "$line" | awk -v t="$wide_token" '{ $(NF - 1) = t; print }')
  body=$(body_with "$home" widened "$widened")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"

  assert_contains "$OUT" 'superseded=false' \
    "the approved entries are inside the signature, so widening them must break it"
  pass "an entry set edited after signing does not verify"
}

test_a_body_with_no_attestation_is_quiet_and_unverified() {
  local home body gh
  home=$(make_home quiet)
  body=$(body_with "$home" plain)
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"

  assert_contains "$OUT" 'superseded=false' \
    "the ordinary PR must excuse nothing"
  assert_not_contains "$OUT" '::warning::' \
    "the ordinary PR must produce no noise at all"
  pass "a PR body with no attestation is quiet and excuses nothing"
}

test_an_attestation_with_no_repository_secret_is_loud() {
  local home line body gh
  home=$(make_home no-repo-secret)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  body=$(body_with "$home" nosecret "$line")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" '' "$SHA_A"

  assert_contains "$OUT" 'superseded=false' \
    "no secret means no verdict, which means no excuse"
  assert_contains "$OUT" 'FM_SUPERSESSION_SECRET' \
    "the warning must name the secret that is missing and how it is set"
  pass "an attestation offered to a repository holding no key is refused and loud"
}

test_a_malformed_attestation_line_is_refused_and_loud() {
  local home body gh
  home=$(make_home malformed)
  body=$(body_with "$home" malformed 'fm-supersession: v1 demo not-a-sha token sig')
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"

  assert_contains "$OUT" 'superseded=false' \
    "a line that does not match the grammar must never be guessed at"
  assert_contains "$OUT" 'does not match the attestation grammar' \
    "the warning must name the grammar the line failed"
  pass "a malformed attestation line is refused and reported"
}

test_a_crlf_body_verifies() {
  local home line body gh
  # GitHub stores PR bodies with CRLF line endings, so a verifier that did not
  # strip them would refuse every real attestation while passing every test.
  home=$(make_home crlf)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  body="$home/body-crlf"
  printf 'Prose.\r\n\r\n%s\r\n' "$line" > "$body"
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"

  assert_contains "$OUT" 'superseded=true' \
    "a body with GitHub's own line endings must verify"
  pass "an attestation in a CRLF PR body verifies"
}

test_the_verifier_exits_zero_for_every_verdict() {
  local home line body gh case_body
  # The required check `Base assertions re-verified` depends on this job. A job
  # that failed would leave that check never reporting at all, and branch
  # protection waiting on it forever, so refusing an attestation must be a
  # verdict rather than an error.
  home=$(make_home exit-zero)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  for case_body in "$line" 'fm-supersession: nonsense' ''; do
    body=$(body_with "$home" "exit-$RANDOM" "$case_body")
    gh=$(fake_gh "$home" "$body")
    run_verify "$gh" "$(repo_key "$home")" "$SHA_A"
    expect_code 0 "$RC" "the verifier must exit 0 for the verdict on: ${case_body:-an empty body}"
  done
  run_verify "$gh" '' ''
  expect_code 0 "$RC" "the verifier must exit 0 even with no secret and no head SHA"
  pass "the verifier exits 0 for every verdict, so the required check always reports"
}

test_the_body_is_read_live_from_github() {
  local home line body gh argv
  # Load-bearing rather than incidental: an approval always arrives as an edit to
  # an open PR, editing a body triggers no workflow, and re-running the check
  # replays the payload the PR had BEFORE the edit. Only a live read sees it.
  home=$(make_home live-read)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  body=$(body_with "$home" live "$line")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"
  argv=$(cat "$home/gh-argv")

  assert_contains "$OUT" 'superseded=true' \
    "the verifier must find an attestation that is in the body now"
  assert_contains "$argv" "pr view $PR_NUMBER" \
    "the verifier must read the PR itself rather than a payload captured earlier"
  assert_contains "$argv" '--json body' \
    "the verifier must ask GitHub for the body it is scanning"
  pass "the attestation is read from the PR's current body, not from the event payload"
}

# --- key separation ---------------------------------------------------------

test_the_published_key_is_derived_for_that_repository_and_this_purpose() {
  local home master key other waiver
  home=$(make_home keys)
  master=$(cat "$home/config/ci-waiver-secret")
  key=$(repo_key "$home")
  other=$(repo_key "$home" "$OTHER_REPO")
  waiver=$(waiver_repo_key "$home")

  [ "$key" != "$master" ] || fail "the published key is the master itself, so a stolen Actions secret would be the fleet's key"
  [ "$key" != "$other" ] || fail "two repositories are published the same key, so a theft from one is a theft from both"
  [ "$key" != "$waiver" ] || fail "the attestation key is the repository's CI-waiver key, so stealing one grants the other"
  pass "each repository's attestation key is derived for that repository and for this purpose alone"
}

test_neither_the_master_nor_another_repositorys_key_verifies() {
  local home line body gh
  home=$(make_home foreign-keys)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  body=$(body_with "$home" foreign "$line")
  gh=$(fake_gh "$home" "$body")

  run_verify "$gh" "$(cat "$home/config/ci-waiver-secret")" "$SHA_A"
  assert_contains "$OUT" 'superseded=false' \
    "the master must not verify what only a derived key may"
  run_verify "$gh" "$(repo_key "$home" "$OTHER_REPO")" "$SHA_A"
  assert_contains "$OUT" 'superseded=false' \
    "another repository's key must not verify this repository's attestation"
  run_verify "$gh" "$(waiver_repo_key "$home")" "$SHA_A"
  assert_contains "$OUT" 'superseded=false' \
    "the repository's CI-waiver key must not verify an attestation"
  pass "neither the master, another repository's key, nor the CI-waiver key verifies an attestation"
}

test_a_ci_waiver_line_is_not_an_attestation() {
  local home body gh waiver_line
  # The two mean opposite things - a waiver says there is no test evidence, an
  # attestation says there is and one assertion was overridden - so neither may
  # ever be read as the other, whichever body it is pasted into.
  home=$(make_home labels)
  waiver_line=$(bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_line "$1" "$2" "$3"' \
    "$ROOT" demo "$SHA_A" \
    "$(printf '%s' "$(waiver_repo_key "$home")" \
      | bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_sign "$1" "$2"' "$ROOT" demo "$SHA_A")")
  body=$(body_with "$home" waiver "$waiver_line")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A"

  assert_contains "$OUT" 'superseded=false' \
    "a verified CI waiver must excuse no base assertion at all"
  assert_not_contains "$OUT" '::warning::' \
    "a waiver line is not a malformed attestation; it is simply not one"
  pass "a CI waiver line excuses nothing here, whatever it authorizes elsewhere"
}

# --- end to end -------------------------------------------------------------

test_end_to_end_the_signed_approvals_excuse_only_what_they_cover() {
  local home line body gh out_file entries d rc out
  # The whole chain, in both directions: sign from the captain's record, verify
  # in CI, apply to real findings. What is approved is excused; what is not still
  # blocks; and the same approvals with no signature excuse nothing.
  home=$(make_home end-to-end)
  write_task "$home" demo
  write_record "$home" project
  line=$(sign_for "$home" demo "$SHA_A")
  body=$(body_with "$home" e2e "$line")
  gh=$(fake_gh "$home" "$body")
  out_file="$home/gh-output"
  : > "$out_file"
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A" "$out_file"
  assert_contains "$OUT" 'superseded=true' "the signed line must verify before the rest of the case means anything"
  entries=$(sed -n '/^entries<</,/^FM_SUPERSESSION_ENTRIES_EOF$/p' "$out_file" \
    | sed '1d;$d')
  [ -n "$entries" ] || fail "the verifier published no entries for the next job to apply"

  # A shim bin holding the real verdict script beside a fake selection owner
  # reporting one covered finding, one covered by the glob, and one covered by
  # nothing at all.
  d="$home/shim"
  mkdir -p "$d"
  cp "$REVERIFY" "$d/fm-reverify-base.sh"
  ln -sf "$ROOT/bin/fm-supersession-lib.sh" "$d/fm-supersession-lib.sh"
  cat > "$d/fm-assert-tests-kept.sh" <<'OWNER'
#!/usr/bin/env bash
cat <<'BODY'
base: origin/main (explicit --base)
missing: tests/a.test.sh::alpha holds
failing: tests/b.test.sh::beta holds
failing: tests/c.test.sh::gamma holds
summary: missing=1 failing=2 unexecuted=0 skipped=0 unaccounted=0 assumed-covered=40 unstable=0 executed-files=3
BODY
exit 1
OWNER
  chmod +x "$d/fm-assert-tests-kept.sh"

  rc=0
  out=$(env -u GITHUB_STEP_SUMMARY FM_SUPERSESSION_ENTRIES="$entries" \
    "$d/fm-reverify-base.sh" --worktree . 2>/dev/null) || rc=$?
  expect_code 1 "$rc" "a finding no approval covers must still block the check"
  assert_contains "$out" 'reverify: not-verified' \
    "the uncovered finding must still render as the actionable outcome"
  assert_contains "$out" 'superseded: tests/a.test.sh::alpha holds (missing)' \
    "the exactly-approved finding must be excused"
  assert_contains "$out" 'superseded: tests/b.test.sh::beta holds (failing)' \
    "the glob-approved finding must be excused"
  assert_not_contains "$out" 'superseded: tests/c.test.sh::gamma holds' \
    "a finding outside every approval must not be excused"

  # The same approvals, unsigned: the file is not the authority, the signature
  # is, so CI is handed nothing and every finding blocks.
  : > "$out_file"
  body=$(body_with "$home" unsigned "fm-supersession: v1 demo $SHA_A $(printf 'ids\tany\t*\n' | bash -c '. "$0/bin/fm-supersession-attest-lib.sh"; fm_supersession_token_encode' "$ROOT") 0000000000000000000000000000000000000000000000000000000000000000")
  gh=$(fake_gh "$home" "$body")
  run_verify "$gh" "$(repo_key "$home")" "$SHA_A" "$out_file"
  assert_contains "$OUT" 'superseded=false' \
    "an unsigned approval must reach the verdict step as no approval at all"
  assert_not_contains "$(cat "$out_file")" 'entries<<' \
    "a refused attestation must publish no entries for the next job to apply"
  pass "end to end, signed approvals excuse exactly what they cover and unsigned ones excuse nothing"
}

test_sign_refuses_a_task_with_no_durable_record
test_sign_refuses_when_the_project_has_no_approval_record
test_sign_refuses_a_record_with_no_fully_formed_entry
test_sign_refuses_an_abbreviated_sha
test_sign_refuses_a_repository_the_task_does_not_belong_to
test_sign_refuses_with_no_secret_at_all
test_the_line_carries_the_approvals_matching_half_and_never_the_reason
test_a_signed_line_verifies_and_hands_on_the_approved_entries
test_a_forged_signature_does_not_verify
test_a_line_bound_to_another_commit_does_not_verify
test_a_line_relabelled_with_another_task_does_not_verify
test_a_widened_entry_token_does_not_verify
test_a_body_with_no_attestation_is_quiet_and_unverified
test_an_attestation_with_no_repository_secret_is_loud
test_a_malformed_attestation_line_is_refused_and_loud
test_a_crlf_body_verifies
test_the_verifier_exits_zero_for_every_verdict
test_the_body_is_read_live_from_github
test_the_published_key_is_derived_for_that_repository_and_this_purpose
test_neither_the_master_nor_another_repositorys_key_verifies
test_a_ci_waiver_line_is_not_an_attestation
test_end_to_end_the_signed_approvals_excuse_only_what_they_cover
