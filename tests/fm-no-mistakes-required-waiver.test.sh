#!/usr/bin/env bash
# tests/fm-no-mistakes-required-waiver.test.sh - behavior tests for the
# captain-flagged testing-skip exemption in
# .github/workflows/no-mistakes-required.yml.
#
# That workflow fails any PR whose body lacks the no-mistakes pipeline's own
# attestation. A worker dispatched with --local-skip or --all-testing-skip
# never runs the pipeline, so it never writes that attestation, so without an
# exemption the testing-skip flags are unusable on this repository - the one
# repository where --all-testing-skip is the valid combination.
#
# The exemption has to be a signature, never a second marker. The attestation
# is a literal string the PR author writes, so any check that merely greps for
# another string is forgeable by the same agent that would be exempting itself.
# Only bin/fm-ci-waiver-verify.sh's verdict, computed from a secret that lives
# on the captain's machine and in this repository's Actions secrets and never
# reaches a worker, may exempt anything here.
#
# Matrix:
#   (a) an ordinary PR body still FAILS the attestation script, unchanged
#   (b) an attested PR body still passes it, unchanged
#   (c) the workflow wires the attestation step to the waiver verdict, and
#       keeps the job REPORTING rather than skipping it, because a skipped
#       check reads as passing to bin/fm-pr-merge.sh
#   (d) end to end: an ordinary body verifies as not waived, so (a) applies
#   (e) end to end: a genuinely signed body verifies as waived, so the
#       attestation step does not run and the PR is not failed for it
#   (f) a forged signature does not exempt anything, so (a) still applies
#   (g) a waiver job that did not succeed HARD-FAILS the check rather than
#       silently exempting the PR
#   (h) a base ref that carries no verifier at all reports waived=false rather
#       than exiting 127, which would fail the job and hard-fail (g)
#   (i) both workflows' ci-waiver jobs run byte-identical verify steps, since
#       the defect (h) covers was present in both
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
WAIVER="$ROOT/bin/fm-ci-waiver.sh"
VERIFY="$ROOT/bin/fm-ci-waiver-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-required-waiver-tests)
mkdir -p "$TMP_ROOT"

SHA=3333333333333333333333333333333333333333
REPO=acme/widgets

[ -f "$WORKFLOW" ] || fail "missing $WORKFLOW"

# Echo the shell body of the named step's `run:` block scalar, dedented, so the
# tests execute the workflow's own bytes instead of a restatement of them.
step_script() {  # <step-name>
  awk -v want="$1" '
    $0 == "      - name: " want { in_step = 1; next }
    in_step && /^      - / { exit }
    in_step && $0 == "        run: |" { collecting = 1; next }
    collecting {
      if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^          /) exit
      sub(/^          /, "")
      print
    }
  ' "$WORKFLOW"
}

ATTEST_SH="$TMP_ROOT/attestation.sh"
GATE_SH="$TMP_ROOT/gate.sh"
VERIFY_STEP_SH="$TMP_ROOT/verify-step.sh"
step_script 'Verify no-mistakes signature in PR body' > "$ATTEST_SH"
step_script 'Gate on the CI testing waiver' > "$GATE_SH"
step_script 'Verify the CI testing waiver' > "$VERIFY_STEP_SH"
[ -s "$ATTEST_SH" ] || fail "could not extract the attestation step's script from $WORKFLOW"
[ -s "$GATE_SH" ] || fail "could not extract the waiver gate step's script from $WORKFLOW"
[ -s "$VERIFY_STEP_SH" ] || fail "could not extract the waiver verify step's script from $WORKFLOW"

# The attestation marker, read from the workflow rather than restated here, so
# this suite cannot drift from the string the check actually greps for.
MARKER=$(sed -n "s/^ *marker='\(.*\)'\$/\1/p" "$WORKFLOW")
[ -n "$MARKER" ] || fail "could not read the attestation marker out of $WORKFLOW"

run_attestation() {  # <pr-body>
  PR_BODY="$1" PR_AUTHOR=some-agent PR_NUMBER=42 bash "$ATTEST_SH" 2>&1
}

run_gate() {  # <ci-waiver job result> <waived output>
  WAIVER_RESULT="$1" WAIVED="$2" bash "$GATE_SH" 2>&1
}

run_verify() {  # <secret> <claim> <head-sha>
  FM_CI_WAIVER_SECRET="$1" \
    FM_CI_WAIVER_CLAIM="$2" \
    FM_CI_WAIVER_HEAD_SHA="$3" \
    GITHUB_OUTPUT='' \
    "$VERIFY" 2>&1
}

# A firstmate home holding a secret and one genuinely dispatched --ci-skip task,
# built exactly as bin/fm-spawn.sh builds it. Echoes the home dir.
make_dispatched_home() {  # <name> <task-id>
  local home=$1 id=$2 auth
  home="$TMP_ROOT/$home"
  mkdir -p "$home/config" "$home/state"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' "$WAIVER" init >/dev/null \
    || fail "could not initialize a waiver secret for $home"
  auth=$(bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_dispatch_token "$1"' \
    "$ROOT" "$id" < "$home/config/ci-waiver-secret")
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "ci_skip=on" "ci_skip_auth=$auth"
  printf '%s\n' "$home"
}

# The key this repository's CI holds: derived from the home's master for that
# repo alone, never the master itself (bin/fm-ci-waiver-lib.sh owns why).
repo_key() {  # <home>
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; fm_ci_waiver_repo_key "$1"' \
    "$ROOT" "$REPO" < "$1/config/ci-waiver-secret"
}

sign_for() {  # <home> <task-id> <sha>
  FM_ROOT_OVERRIDE='' FM_HOME="$1" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' "$WAIVER" sign "$2" "$3" "$REPO" 2>&1
}

ORDINARY_BODY='## Summary

Adds a thing and a test for it.'

# --- (a)(b) the attestation script itself is unchanged in behaviour ----------

test_ordinary_body_still_fails_the_attestation() {
  local out status
  out=$(run_attestation "$ORDINARY_BODY"); status=$?
  [ "$status" -ne 0 ] || fail "a PR body with no attestation must still fail the check"
  assert_contains "$out" "::error::This PR was not raised through no-mistakes." \
    "the refusal no longer names the reason"
  pass "attestation: an ordinary PR body with no pipeline attestation still fails"
}

test_attested_body_still_passes() {
  local out status
  out=$(run_attestation "## Pipeline

$MARKER
"); status=$?
  expect_code 0 $status "an attested PR body must still pass"$'\n'"$out"
  assert_contains "$out" "Found no-mistakes signature" "the pass path no longer reports itself"
  pass "attestation: a PR body carrying the pipeline attestation still passes"
}

# --- (c) the wiring -----------------------------------------------------------

test_workflow_wires_the_check_to_the_waiver_verdict() {
  local body
  body=$(cat "$WORKFLOW")
  assert_contains "$(cat "$VERIFY_STEP_SH")" "bin/fm-ci-waiver-verify.sh" \
    "the exemption must come from the verifier, not from a second grep"
  assert_contains "$body" "FM_CI_WAIVER_SECRET: \${{ secrets.FM_CI_WAIVER_SECRET }}" \
    "the waiver job does not read this repository's secret"
  assert_contains "$body" "FM_CI_WAIVER_HEAD_SHA: \${{ github.event.pull_request.head.sha }}" \
    "the waiver job does not bind the verdict to the PR head commit"
  assert_contains "$body" "needs: ci-waiver" "the check job does not depend on the waiver job"
  assert_contains "$body" "if: needs.ci-waiver.outputs.waived != 'true'" \
    "the attestation step is not conditioned on the waiver verdict"
  # A skipped job reads as PASSING to bin/fm-pr-merge.sh, so the check must
  # never be skipped by a FAILED dependency; it reports and the gate step decides.
  # It must not be `always()` though: that also runs on a CANCELLED workflow run,
  # and this workflow sets cancel-in-progress, so a superseded run would hard-fail
  # the required check for no reason.
  assert_contains "$body" '!cancelled() &&' \
    "the check job must keep reporting rather than being skipped by its dependency"
  assert_not_contains "$body" "always() &&" \
    "always() also runs on a cancelled run, which would red-flag every superseded run"
  pass "workflow: only the verified waiver verdict gates the attestation step"
}

# --- (d)(e)(f) end to end, through the real verifier ---------------------------

# Apply the exact condition the workflow puts on the attestation step. Echoes
# "runs" or "skipped".
attestation_step_disposition() {  # <waived>
  if [ "$1" != "true" ]; then printf 'runs\n'; else printf 'skipped\n'; fi
}

test_ordinary_pr_is_not_waived_and_still_fails() {
  local home secret out waived status
  home=$(make_dispatched_home e2e-ordinary ord-a1)
  secret=$(repo_key "$home")
  out=$(run_verify "$secret" "$ORDINARY_BODY" "$SHA")
  assert_contains "$out" "waived=false" "an ordinary PR body was somehow waived"
  waived=$(printf '%s\n' "$out" | sed -n 's/^waived=//p')
  [ "$(attestation_step_disposition "$waived")" = "runs" ] \
    || fail "an unwaived PR must still run the attestation step"
  out=$(run_attestation "$ORDINARY_BODY"); status=$?
  [ "$status" -ne 0 ] || fail "the attestation step passed an unattested, unwaived PR"
  pass "end to end: an ordinary PR is not waived, so the attestation still fails it"
}

test_verified_waiver_exempts_the_attestation() {
  local home secret line out waived
  home=$(make_dispatched_home e2e-waived skip-a1)
  secret=$(repo_key "$home")
  line=$(sign_for "$home" skip-a1 "$SHA")
  assert_contains "$line" "fm-ci-waiver: v1 skip-a1 $SHA " "sign did not print a waiver line"
  # A skipped worker's PR body: a real summary, no pipeline attestation
  # anywhere, and the captain-issued waiver line.
  out=$(run_verify "$secret" "$ORDINARY_BODY

$line" "$SHA")
  assert_contains "$out" "waived=true" "a genuine waiver did not verify"
  assert_not_contains "$ORDINARY_BODY" "$MARKER" \
    "the waived body must not carry the attestation - the exemption is the signature, not the string"
  waived=$(printf '%s\n' "$out" | sed -n 's/^waived=//p')
  [ "$(attestation_step_disposition "$waived")" = "skipped" ] \
    || fail "a verified waiver did not exempt the attestation step"
  pass "end to end: a verified waiver exempts the attestation, with no marker typed"
}

test_forged_waiver_does_not_exempt_anything() {
  local home secret line forged out waived status
  home=$(make_dispatched_home e2e-forged forge-a1)
  secret=$(repo_key "$home")
  line=$(sign_for "$home" forge-a1 "$SHA")
  forged="${line% *} 0000000000000000000000000000000000000000000000000000000000000000"
  out=$(run_verify "$secret" "$ORDINARY_BODY

$forged" "$SHA")
  assert_contains "$out" "waived=false" "a forged signature exempted the attestation"
  waived=$(printf '%s\n' "$out" | sed -n 's/^waived=//p')
  [ "$(attestation_step_disposition "$waived")" = "runs" ] \
    || fail "a forged signature skipped the attestation step"
  out=$(run_attestation "$ORDINARY_BODY

$forged"); status=$?
  [ "$status" -ne 0 ] || fail "a forged waiver line satisfied the attestation grep"
  pass "end to end: a forged signature exempts nothing and the attestation still fails"
}

# --- (g) the gate step --------------------------------------------------------

test_gate_hard_fails_when_the_waiver_job_did_not_complete() {
  local out status
  out=$(run_gate failure ''); status=$?
  [ "$status" -ne 0 ] || fail "a crashed waiver job must not silently exempt the PR"
  assert_contains "$out" "::error::" "the crashed waiver job was not reported"
  assert_contains "$out" "did not complete" "the failure did not name its reason"
  out=$(run_gate cancelled 'true'); status=$?
  [ "$status" -ne 0 ] || fail "a cancelled waiver job must not be trusted for its output"
  pass "gate: a waiver job that did not succeed hard-fails instead of exempting"
}

test_gate_passes_and_announces_each_verdict() {
  local out
  out=$(run_gate success 'false')
  expect_code 0 $? "an unwaived PR must pass the gate step"$'\n'"$out"
  assert_not_contains "$out" "::warning::" "an ordinary PR must not be annotated"
  out=$(run_gate success 'true')
  expect_code 0 $? "a waived PR must pass the gate step"$'\n'"$out"
  assert_contains "$out" "::warning::" "a waived attestation must be announced, never silent"
  assert_contains "$out" "WAIVED" "the announcement did not name the waiver"
  pass "gate: an ordinary PR is quiet, a waived one is announced loudly"
}

# --- (h) the bootstrap case ---------------------------------------------------

# The waiver job checks out the BASE ref, so on any base predating the waiver
# there is no verifier to run. An unguarded invocation would exit 127, fail the
# job, and (g) above would then hard-fail the required check on every open PR.
run_verify_step() {  # <cwd> <github-output-file>
  ( cd "$1" \
      && FM_CI_WAIVER_SECRET='' FM_CI_WAIVER_CLAIM='' FM_CI_WAIVER_HEAD_SHA='' \
        GITHUB_OUTPUT="$2" bash "$VERIFY_STEP_SH" 2>&1 )
}

test_base_without_a_verifier_is_unwaived_not_a_job_failure() {
  local bare gho out status
  bare="$TMP_ROOT/base-without-verifier"
  mkdir -p "$bare"
  gho="$bare/github-output"
  : > "$gho"
  out=$(run_verify_step "$bare" "$gho"); status=$?
  expect_code 0 $status "a base with no verifier must not fail the waiver job"$'\n'"$out"
  assert_contains "$out" "::warning::" "the missing verifier was not announced"
  assert_grep "waived=false" "$gho" \
    "the fallback must publish its verdict to GITHUB_OUTPUT, or the job output is empty"
  pass "verify step: a base carrying no verifier is unwaived, loudly, and exits 0"
}

test_verify_step_runs_the_real_verifier_when_present() {
  local gho out status
  gho="$TMP_ROOT/github-output-present"
  : > "$gho"
  out=$(run_verify_step "$ROOT" "$gho"); status=$?
  expect_code 0 $status "the verify step must exit 0 when the verifier is present"$'\n'"$out"
  assert_not_contains "$out" "carries no CI waiver verifier" \
    "the bootstrap fallback swallowed the real verifier"
  assert_grep "waived=false" "$gho" "the real verifier did not publish its verdict"
  pass "verify step: the guard defers to the real verifier whenever it exists"
}

# The two workflows carry the same ci-waiver job, and the bootstrap defect this
# guards against was present in both. Byte parity is what stops one being fixed
# and the other quietly left behind.
test_both_workflows_run_the_same_verify_step() {
  local ci_step
  ci_step="$TMP_ROOT/ci-verify-step.sh"
  ( WORKFLOW="$ROOT/.github/workflows/ci.yml"; step_script 'Verify the CI testing waiver' ) > "$ci_step"
  [ -s "$ci_step" ] || fail "could not extract the waiver verify step's script from ci.yml"
  diff -u "$VERIFY_STEP_SH" "$ci_step" >/dev/null \
    || fail "the two ci-waiver jobs' verify steps have drifted apart"$'\n'"$(diff -u "$VERIFY_STEP_SH" "$ci_step")"
  pass "workflow: both ci-waiver jobs run byte-identical verify steps"
}

test_ordinary_body_still_fails_the_attestation
test_attested_body_still_passes
test_workflow_wires_the_check_to_the_waiver_verdict
test_ordinary_pr_is_not_waived_and_still_fails
test_verified_waiver_exempts_the_attestation
test_forged_waiver_does_not_exempt_anything
test_gate_hard_fails_when_the_waiver_job_did_not_complete
test_gate_passes_and_announces_each_verdict
test_base_without_a_verifier_is_unwaived_not_a_job_failure
test_verify_step_runs_the_real_verifier_when_present
test_both_workflows_run_the_same_verify_step
