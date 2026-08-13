#!/usr/bin/env bash
# tests/fm-reverify-base.test.sh - behavior tests for bin/fm-reverify-base.sh,
# the cheap re-verification of a branch against a base that has moved under it,
# and for the `executed-files=` count it reads from bin/fm-assert-tests-kept.sh.
#
# The condition under test is a false green. GitHub re-runs a PR's checks only
# when the PR's own head changes, so on 2026-08-09 PRs 31-36 all showed green
# measured against a base four later merges had replaced. The cheap path re-runs
# only the base test files that DIFFER from the branch's copies - 2 of 85 on
# this repo. The hazard that buys is that "there was nothing left to run" and
# "everything ran and held" are both exit 0 with no findings, and a check that
# renders them the same way reports a never-evaluated result as verified.
#
# So the assertions here are mostly about the outcomes staying DISTINCT: every
# way the check can fail to establish a verdict - an owner that refused, an owner
# whose findings are `unexecuted:`/`unstable:`, an owner whose exit code and
# summary disagree, an owner too old to publish the count, no summary at all -
# must render as could-not-verify and BLOCK, never as a pass.
#
# The fourth outcome, `superseded`, is the same discipline applied to the
# captain's approvals: a branch that deliberately supersedes an assertion the
# base makes is not a branch whose assertions held, and rendering the two the
# same way would hide an authorized override inside a pass. Its own cases below
# pair every excusal with the finding beside it that must still block.
#
# The selection itself is not re-tested here: bin/fm-assert-tests-kept.sh owns
# it and tests/fm-assert-tests-kept.test.sh tests it. What is tested here is
# that this script stays a thin caller of it - arguments forwarded verbatim, the
# verdict read from that script's published contract - plus the end-to-end runs
# that prove the two really do compose.
#
# Hermetic: a private shim bin/ per case holding the real script beside a fake
# selection owner, and self-contained local git repos for the end-to-end cases.
# No network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reverify-base)
REVERIFY="$ROOT/bin/fm-reverify-base.sh"
CI_YML="$ROOT/.github/workflows/ci.yml"
REVERIFY_YML="$ROOT/.github/workflows/reverify-base.yml"

# --- the shim bin -----------------------------------------------------------

# shim_dir <slug>: a private bin/ holding the REAL bin/fm-reverify-base.sh, plus
# a symlink to every sibling that script names - derived from the script's own
# text at run time, never from a list kept here. A hand-kept list is a second
# copy of the dependency set that rots the moment the script gains a dependency,
# and because the shim is built against the branch's own tree the rot stays
# invisible until after the merge (tests/fm-backend.test.sh, 2026-08-09).
# fm-assert-tests-kept.sh is deliberately NOT linked: make_owner writes the fake
# in its place, which is the whole point of the shim.
shim_dir() {  # <slug>
  local slug=$1 d dep
  d="$TMP_ROOT/$slug/bin"
  mkdir -p "$d"
  cp "$REVERIFY" "$d/fm-reverify-base.sh"
  chmod +x "$d/fm-reverify-base.sh"
  # shellcheck disable=SC2016 # $SCRIPT_DIR below is the pattern being searched for, not an expansion.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    [ "$dep" != "fm-assert-tests-kept.sh" ] || continue
    [ -e "$ROOT/bin/$dep" ] || continue
    ln -sf "$ROOT/bin/$dep" "$d/$dep"
  done < <(grep -o '\$SCRIPT_DIR/[A-Za-z0-9._-]*' "$REVERIFY" | sed 's|.*/||' | sort -u)
  printf '%s\n' "$d"
}

# make_owner <shim-dir> <exit-code>: write the fake selection owner. Its stdout
# is read from THIS function's stdin, so each case states the exact contract
# bytes it is driving the classifier with. Every invocation's argv is appended
# to <shim-dir>/../argv so the forwarding case can read it back.
make_owner() {  # <shim-dir> <exit-code>  (stdout body on stdin)
  local d=$1 code=$2 body
  body=$(cat)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s/../argv"\n' "$d"
    printf 'cat <<'"'"'FM_OWNER_EOF'"'"'\n%s\nFM_OWNER_EOF\n' "$body"
    printf 'exit %s\n' "$code"
  } > "$d/fm-assert-tests-kept.sh"
  chmod +x "$d/fm-assert-tests-kept.sh"
}

# run_shim <shim-dir> [<arg>...]: run the shimmed script, capturing stdout.
# Sets RC. GITHUB_STEP_SUMMARY is scrubbed rather than inherited, so a case that
# does not set it can never measure whatever the running shell happened to
# export (tests/fm-session-lock-gate.test.sh, 2026-08-09).
RC=0
OUT=
run_shim() {  # <shim-dir> [<arg>...]
  local d=$1
  shift
  RC=0
  OUT=$(env -u GITHUB_STEP_SUMMARY -u FM_SUPERSESSION_ENTRIES \
    "$d/fm-reverify-base.sh" "$@" 2>/dev/null) || RC=$?
}

# run_shim_with_entries <shim-dir> <entries> [<arg>...]: the same, with a
# verified captain-approved entry set supplied the way the workflow supplies it.
run_shim_with_entries() {  # <shim-dir> <entries> [<arg>...]
  local d=$1 entries=$2
  shift 2
  RC=0
  OUT=$(env -u GITHUB_STEP_SUMMARY FM_SUPERSESSION_ENTRIES="$entries" \
    "$d/fm-reverify-base.sh" "$@" 2>/dev/null) || RC=$?
}

# entry <sel> <kind> <value>: one canonical entry line, built here with a real
# tab so a case states the exact bytes bin/fm-supersession-verify.sh hands over.
# A case wanting several calls them in ONE substitution - `$(entry a; entry b)`
# - because a substitution per line would strip each line's terminator and run
# the entries together into one unreadable line.
entry() {  # <sel> <kind> <value>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# A whole summary line, so each case states the full contract it is driving and
# a field added to that contract later cannot silently change what a case means.
summary_line() {  # <missing> <failing> <unexecuted> <skipped> <unaccounted> <assumed> <unstable> <executed-files>
  printf 'summary: missing=%s failing=%s unexecuted=%s skipped=%s unaccounted=%s assumed-covered=%s unstable=%s executed-files=%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# --- the three outcomes stay three ------------------------------------------

test_executed_files_above_zero_reads_as_verified() {
  local d out
  d=$(shim_dir verified)
  make_owner "$d" 0 <<EOF
base: origin/main (explicit --base)
$(summary_line 0 0 0 0 0 40 0 2)
EOF
  run_shim "$d" --worktree . --base origin/main
  out=$OUT

  expect_code 0 "$RC" "verified: a clean run that actually re-ran files must not block"
  assert_contains "$out" 'reverify: verified' \
    "verified: the first line must name the outcome"
  assert_contains "$out" '2 base test file(s) differed' \
    "verified: the detail must name how many files were actually re-run"
  assert_not_contains "$out" 'reverify: nothing-to-verify' \
    "verified: an actual re-run must never render as nothing to verify"
  pass "a clean run that re-ran at least one base test file reads as verified"
}

test_zero_executed_files_reads_as_nothing_to_verify_not_as_verified() {
  local d out
  # The motivating false green: identical exit code, identical zero findings.
  # The ONLY thing separating this from the case above is executed-files, and a
  # classifier that ignores it reports "nothing ran" as "everything held".
  d=$(shim_dir nothing)
  make_owner "$d" 0 <<EOF
base: origin/main (explicit --base)
$(summary_line 0 0 0 0 0 1973 0 0)
EOF
  run_shim "$d" --worktree . --base origin/main
  out=$OUT

  expect_code 0 "$RC" "nothing-to-verify: a determinate empty selection must not block"
  assert_contains "$out" 'reverify: nothing-to-verify' \
    "nothing-to-verify: an empty selection must render as its own outcome"
  assert_contains "$out" 'no base test file needed re-running' \
    "nothing-to-verify: the detail must say nothing was run, not that something passed"
  assert_not_contains "$out" 'reverify: verified' \
    "nothing-to-verify: a run that verified nothing must never render as verified"
  pass "an empty selection renders as nothing-to-verify and never as verified"
}

test_the_three_outcomes_render_as_three_distinct_first_lines() {
  local d out verified nothing could superseded
  # Stated as one assertion in its own right, because the contract is not
  # "each outcome has a sentence" but "no two of them are the same string".
  d=$(shim_dir distinct-verified)
  make_owner "$d" 0 <<EOF
$(summary_line 0 0 0 0 0 40 0 2)
EOF
  run_shim "$d" --worktree .
  out=$OUT
  verified=$(printf '%s\n' "$out" | head -1)

  d=$(shim_dir distinct-nothing)
  make_owner "$d" 0 <<EOF
$(summary_line 0 0 0 0 0 40 0 0)
EOF
  run_shim "$d" --worktree .
  out=$OUT
  nothing=$(printf '%s\n' "$out" | head -1)

  d=$(shim_dir distinct-could-not)
  make_owner "$d" 1 <<EOF
unexecuted: tests/a.test.sh::x
$(summary_line 0 0 1 0 0 40 0 0)
EOF
  run_shim "$d" --worktree .
  out=$OUT
  could=$(printf '%s\n' "$out" | head -1)

  d=$(shim_dir distinct-superseded)
  make_owner "$d" 1 <<EOF
failing: tests/a.test.sh::x
$(summary_line 0 1 0 0 0 40 0 2)
EOF
  run_shim_with_entries "$d" "$(entry id failing 'tests/a.test.sh::x')" --worktree .
  out=$OUT
  superseded=$(printf '%s\n' "$out" | head -1)

  [ "$verified" != "$nothing" ] || fail "verified and nothing-to-verify rendered the same first line: $verified"
  [ "$verified" != "$could" ] || fail "verified and could-not-verify rendered the same first line: $verified"
  [ "$nothing" != "$could" ] || fail "nothing-to-verify and could-not-verify rendered the same first line: $nothing"
  [ "$verified" != "$superseded" ] || fail "verified and superseded rendered the same first line: $verified"
  [ "$nothing" != "$superseded" ] || fail "nothing-to-verify and superseded rendered the same first line: $nothing"
  [ "$could" != "$superseded" ] || fail "could-not-verify and superseded rendered the same first line: $could"
  pass "verified, nothing-to-verify, could-not-verify and superseded are four distinct rendered outcomes"
}

# --- the captain's approvals ------------------------------------------------
# The condition under test is the one this whole mechanism exists for: a branch
# the captain has APPROVED superseding the base's behaviour could not pass this
# check at all, because the approval lives in a private record no runner can
# read. What must not follow from fixing that is a blanket green, so every case
# below pairs "the approved thing is excused" with "nothing else is".

test_findings_covered_by_the_captains_approvals_read_as_superseded() {
  local d out
  d=$(shim_dir superseded)
  make_owner "$d" 1 <<EOF
missing: tests/a.test.sh::alpha holds
failing: tests/b.test.sh::beta holds
$(summary_line 1 1 0 0 0 40 0 3)
EOF
  run_shim_with_entries "$d" \
    "$(entry id any 'tests/a.test.sh::alpha holds'; entry ids failing 'tests/b.test.sh::*')" \
    --worktree .
  out=$OUT

  expect_code 0 "$RC" "superseded: an approved override must not block the merge forever"
  assert_contains "$out" 'reverify: superseded' \
    "superseded: an authorized override must render as its own outcome"
  assert_not_contains "$out" 'reverify: verified' \
    "superseded: an assertion the branch broke on purpose must never read as one that held"
  assert_contains "$out" 'superseded: tests/a.test.sh::alpha holds (missing)' \
    "superseded: every excused finding must be named, so a green check hides nothing"
  assert_contains "$out" 'superseded: tests/b.test.sh::beta holds (failing)' \
    "superseded: a glob entry's excusals must be named individually too"
  pass "findings the captain approved superseding render as superseded and do not block"
}

test_a_finding_no_approval_covers_still_blocks() {
  local d out
  # The whole point of narrowing: an approval excuses what it names and nothing
  # else, so a real regression riding alongside an approved one still refuses.
  d=$(shim_dir uncovered)
  make_owner "$d" 1 <<EOF
missing: tests/a.test.sh::alpha holds
failing: tests/b.test.sh::beta holds
$(summary_line 1 1 0 0 0 40 0 3)
EOF
  run_shim_with_entries "$d" "$(entry ids failing 'tests/b.test.sh::*')" --worktree .
  out=$OUT

  expect_code 1 "$RC" "an unapproved regression must still block, whatever else was approved"
  assert_contains "$out" 'reverify: not-verified' \
    "an unapproved finding must still render as the actionable outcome"
  assert_contains "$out" 'superseded: tests/b.test.sh::beta holds (failing)' \
    "the approved half must still be named, so the reader can see what is left"
  assert_contains "$out" 'further finding(s) are covered by captain-approved supersessions' \
    "the detail must say the counts it names are what is UNapproved, not all that was found"
  pass "a finding no captain approval covers still blocks, beside one that is covered"
}

test_an_approval_excuses_only_the_class_it_names() {
  local d out
  # `kind` is a safety feature of the record's grammar, not a convenience: an
  # entry approved for one finding class must not excuse a different one.
  d=$(shim_dir wrong-class)
  make_owner "$d" 1 <<EOF
missing: tests/a.test.sh::alpha holds
$(summary_line 1 0 0 0 0 40 0 3)
EOF
  run_shim_with_entries "$d" "$(entry id unexecuted 'tests/a.test.sh::alpha holds')" --worktree .
  out=$OUT

  expect_code 1 "$RC" "an approval for another class must not excuse a deleted assertion"
  assert_contains "$out" 'reverify: not-verified' \
    "an identifier approved only for another class must still block"
  assert_not_contains "$out" 'superseded: tests/a.test.sh::alpha holds' \
    "an approval for another class must not be reported as having excused anything"
  pass "an approval excuses only the finding class it names"
}

test_approvals_reach_the_unexecutable_and_unstable_classes_too() {
  local d out
  # Those two block as could-not-verify rather than not-verified, which is a
  # different code path; an approval must reach both or the two classes would
  # quietly be un-excusable.
  d=$(shim_dir superseded-unverifiable)
  make_owner "$d" 1 <<EOF
unexecuted: tests/a.test.sh::alpha holds
unstable: tests/b.test.sh::beta measured 41ms
$(summary_line 0 0 1 0 0 40 1 3)
EOF
  run_shim_with_entries "$d" \
    "$(entry id unexecuted 'tests/a.test.sh::alpha holds'; entry ids unstable 'tests/b.test.sh::*')" \
    --worktree .
  out=$OUT

  expect_code 0 "$RC" "an approved unexecutable or unstable finding must not block"
  assert_contains "$out" 'reverify: superseded' \
    "the two unverifiable classes must be excusable by the same approval mechanism"
  pass "captain approvals reach the unexecuted and unstable classes, not only missing and failing"
}

test_an_unreadable_approval_reads_as_could_not_verify_never_as_no_approvals() {
  local d out
  # The failure that must not happen quietly: an approval this fleet's matcher
  # cannot read is not the same thing as no approval, and treating it as either
  # "excuse nothing" or "excuse everything" states something nobody established.
  d=$(shim_dir bad-entry)
  make_owner "$d" 1 <<EOF
missing: tests/a.test.sh::alpha holds
$(summary_line 1 0 0 0 0 40 0 3)
EOF
  run_shim_with_entries "$d" 'id any tests/a.test.sh::alpha holds' --worktree .
  out=$OUT

  expect_code 1 "$RC" "an unreadable approval must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "an approval that cannot be read must render as no verdict, not as no approvals"
  assert_not_contains "$out" 'reverify: superseded' \
    "an approval that cannot be read must never excuse anything"
  pass "an approval this fleet's matcher cannot read blocks as could-not-verify"
}

test_approvals_are_refused_when_the_findings_cannot_be_matched_one_by_one() {
  local d out
  # The excusal is applied per finding LINE while the verdict counts come from
  # the summary. If the lines do not account for every counted finding, a
  # counted finding could be excused by a line that is not there.
  d=$(shim_dir finding-mismatch)
  make_owner "$d" 1 <<EOF
missing: tests/a.test.sh::alpha holds
$(summary_line 2 0 0 0 0 40 0 3)
EOF
  run_shim_with_entries "$d" "$(entry ids any '*')" --worktree .
  out=$OUT

  expect_code 1 "$RC" "an approval cannot be applied to findings that were never printed"
  assert_contains "$out" 'reverify: could-not-verify' \
    "a summary the finding lines do not account for must block rather than be excused"
  pass "approvals are refused when the owner's finding lines do not account for its own counts"
}

test_the_approvals_are_inert_when_none_are_supplied() {
  local d out
  # The ordinary PR, which is almost every PR: with no attestation the check
  # must behave exactly as it did before this mechanism existed.
  d=$(shim_dir no-approvals)
  make_owner "$d" 1 <<EOF
missing: tests/a.test.sh::alpha holds
$(summary_line 1 0 0 0 0 40 0 3)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "a PR with no attestation must block on a missing assertion exactly as before"
  assert_contains "$out" 'reverify: not-verified' \
    "with no approvals supplied the outcome must be the ordinary one"
  assert_not_contains "$out" 'superseded' \
    "with no approvals supplied nothing may be reported as excused"
  pass "the approval mechanism is inert on a PR that carries no attestation"
}

# --- every non-verdict blocks -----------------------------------------------

test_a_missing_identifier_reads_as_not_verified_and_blocks() {
  local d out
  d=$(shim_dir missing)
  make_owner "$d" 1 <<EOF
missing: tests/a.test.sh::alpha holds
$(summary_line 1 0 0 0 0 40 0 3)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "not-verified: a base assertion the branch dropped must block"
  assert_contains "$out" 'reverify: not-verified' \
    "not-verified: a real regression must render as its own outcome"
  assert_contains "$out" 'missing: tests/a.test.sh::alpha holds' \
    "not-verified: the owner's findings must stay visible in the same output"
  pass "an identifier the base has and the branch dropped blocks as not-verified"
}

test_a_failing_assertion_reads_as_not_verified_and_names_the_unverifiable_half() {
  local d out
  # Both classes at once. The actionable regression wins the outcome, but the
  # unverifiable half must not vanish from the sentence: a reader who acts only
  # on the named failures would otherwise believe the rest was checked.
  d=$(shim_dir failing)
  make_owner "$d" 1 <<EOF
failing: tests/a.test.sh::alpha holds
unexecuted: tests/b.test.sh::beta holds
$(summary_line 0 1 1 0 0 40 0 3)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "not-verified: a failed base assertion must block"
  assert_contains "$out" 'reverify: not-verified' \
    "not-verified: a failed assertion must render as the actionable outcome"
  assert_contains "$out" 'unexecuted=1' \
    "not-verified: the unverifiable half must still be named in the detail"
  pass "a failed base assertion blocks as not-verified and still names what could not be verified"
}

test_unexecuted_alone_reads_as_could_not_verify() {
  local d out
  d=$(shim_dir unexec)
  make_owner "$d" 1 <<EOF
unexecuted: tests/a.test.sh::alpha holds
$(summary_line 0 0 1 0 0 40 0 0)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: an unexecutable base assertion must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: an unexecutable assertion is not a regression and not a pass"
  pass "a base assertion that could not be executed blocks as could-not-verify"
}

test_unstable_alone_reads_as_could_not_verify() {
  local d out
  d=$(shim_dir unstable)
  make_owner "$d" 1 <<EOF
unstable: tests/a.test.sh::tag is readable (Z)
$(summary_line 0 0 0 0 0 40 1 1)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: an assertion whose name moves must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: an uncomparable assertion is not a pass"
  pass "a base assertion whose identity moves between runs blocks as could-not-verify"
}

test_owner_refusal_reads_as_could_not_verify() {
  local d out
  d=$(shim_dir refused)
  make_owner "$d" 2 </dev/null
  run_shim "$d" --worktree /nope
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: an owner that refused to run must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: exit 2 means the check never ran and must never pass"
  assert_contains "$out" 'refused to run at all' \
    "could-not-verify: the detail must say the check never ran"
  pass "a selection owner that refused to run at all blocks as could-not-verify"
}

test_an_undefined_owner_exit_code_reads_as_could_not_verify() {
  local d out
  # The owner's contract defines 0, 1 and 2. A kill (a job timeout, an OOM) lands
  # outside it, and a fall-through that treated an unknown code as "no findings"
  # would pass exactly the run that was cut short.
  d=$(shim_dir signalled)
  make_owner "$d" 137 </dev/null
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: an owner killed mid-run must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: an exit code the contract does not define is not a verdict"
  assert_contains "$out" 'exit 137' \
    "could-not-verify: the detail must name the code it could not interpret"
  pass "an owner exit code outside the contract blocks as could-not-verify"
}

test_a_green_exit_with_no_summary_reads_as_could_not_verify() {
  local d out
  # The precise false-green shape: exit 0 and nothing to contradict it. Reading
  # that as a pass is reading "no evidence" as "no findings".
  d=$(shim_dir no-summary)
  make_owner "$d" 0 <<'EOF'
base: origin/main (explicit --base)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: a green exit with no evidence must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: an unreadable result must never take the green"
  assert_contains "$out" 'printed no summary line' \
    "could-not-verify: the detail must name the missing evidence"
  pass "a green exit that printed no summary line blocks as could-not-verify"
}

test_a_summary_without_the_executed_count_reads_as_could_not_verify() {
  local d out
  # An owner predating the `executed-files=` field. The classifier cannot tell
  # verified from nothing-to-verify without it, and defaulting the absent count
  # to zero (or to one) would silently pick one of those two answers.
  d=$(shim_dir old-owner)
  make_owner "$d" 0 <<'EOF'
summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0 assumed-covered=0 unstable=0
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: a summary missing the count must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: an unreadable count must never be guessed"
  assert_contains "$out" 'no readable executed-files= count' \
    "could-not-verify: the detail must name the field it could not read"
  pass "a summary carrying no executed-files count blocks as could-not-verify"
}

test_an_exit_code_that_contradicts_the_summary_reads_as_could_not_verify() {
  local d out
  d=$(shim_dir green-with-findings)
  make_owner "$d" 0 <<EOF
failing: tests/a.test.sh::alpha holds
$(summary_line 0 1 0 0 0 40 0 3)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: a green exit alongside findings must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: two statements that disagree cannot produce a verdict"

  d=$(shim_dir red-with-nothing)
  make_owner "$d" 1 <<EOF
$(summary_line 0 0 0 0 0 40 0 3)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: a red exit reporting nothing must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: the disagreement blocks in both directions"
  pass "an owner whose exit code and summary disagree blocks as could-not-verify"
}

test_a_missing_selection_owner_reads_as_could_not_verify() {
  local d out
  d=$(shim_dir no-owner)
  rm -f "$d/fm-assert-tests-kept.sh"
  run_shim "$d" --worktree .
  out=$OUT

  expect_code 1 "$RC" "could-not-verify: no owner to call must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "could-not-verify: a missing owner is not an empty finding set"
  pass "a missing selection owner blocks as could-not-verify"
}

test_no_arguments_still_renders_an_outcome() {
  local d out
  d=$(shim_dir no-args)
  make_owner "$d" 0 </dev/null
  run_shim "$d"
  out=$OUT

  expect_code 1 "$RC" "no-args: a caller that passed nothing must block"
  assert_contains "$out" 'reverify: could-not-verify' \
    "no-args: anything reading the first line must still get an outcome"
  pass "an invocation with no arguments still renders an outcome and blocks"
}

# --- it stays a thin caller -------------------------------------------------

test_arguments_are_forwarded_to_the_selection_owner_verbatim() {
  local d out argv
  # The one-owner rule made mechanical: this script must not interpret, rewrite
  # or filter the owner's flags, because any grammar of its own here becomes a
  # second place the selection can be configured differently.
  d=$(shim_dir forward)
  make_owner "$d" 0 <<EOF
$(summary_line 0 0 0 0 0 40 0 1)
EOF
  run_shim "$d" --worktree /some/where --base origin/main --branch deadbeef \
    --assume-branch-suite-green
  out=$OUT
  argv=$(cat "$d/../argv")

  expect_code 0 "$RC" "forward: the run itself must still succeed"
  [ "$argv" = "--worktree /some/where --base origin/main --branch deadbeef --assume-branch-suite-green" ] \
    || fail "forward: arguments were not passed through verbatim, owner saw: $argv"
  pass "every argument reaches the selection owner verbatim"
}

test_the_owners_own_output_is_relayed_in_full() {
  local d out
  d=$(shim_dir relay)
  make_owner "$d" 1 <<EOF
base: origin/main (base branch of https://github.com/o/r/pull/9)
missing: tests/a.test.sh::alpha holds
failing: tests/b.test.sh::beta holds
$(summary_line 1 1 0 0 0 40 0 3)
EOF
  run_shim "$d" --worktree .
  out=$OUT

  assert_contains "$out" 'base: origin/main (base branch of https://github.com/o/r/pull/9)' \
    "relay: the base line names which tree the verdict was measured against and must survive"
  assert_contains "$out" 'missing: tests/a.test.sh::alpha holds' \
    "relay: every finding must stay readable in the same output"
  assert_contains "$out" 'failing: tests/b.test.sh::beta holds' \
    "relay: every finding must stay readable in the same output"
  pass "the selection owner's own output is relayed in full alongside the verdict"
}

test_the_outcome_is_written_to_the_github_step_summary() {
  local d out summary
  d=$(shim_dir step-summary)
  summary="$TMP_ROOT/step-summary.md"
  : > "$summary"
  make_owner "$d" 0 <<EOF
$(summary_line 0 0 0 0 0 1973 0 0)
EOF
  out=$(GITHUB_STEP_SUMMARY="$summary" "$d/fm-reverify-base.sh" --worktree . 2>/dev/null) || RC=$?

  assert_contains "$(cat "$summary")" 'reverify: nothing-to-verify' \
    "step-summary: the outcome must be legible without opening the job log"
  assert_contains "$(cat "$summary")" 'no base test file needed re-running' \
    "step-summary: the detail must accompany the outcome"
  assert_contains "$out" 'reverify: nothing-to-verify' \
    "step-summary: writing the summary must not replace the stdout contract"
  pass "the outcome and its detail are written to the GitHub step summary too"
}

# --- end to end against the real selection owner -----------------------------
#
# The cases above drive the classifier with canned contract bytes. These prove
# the two scripts actually compose: a real repo, the real owner, the real skip.

# make_repo <slug> <base-value> <branch-value> [<branch test body>]: a local repo
# whose main holds two self-contained shell test files - one reading app.sh, one
# constant - and a `work` branch that changes app.sh's value. The test file is
# left byte-identical unless a branch body is given, so which files the selection
# picks is entirely a function of the fixture.
make_repo() {  # <slug> <base-value> <branch-value> [<branch test body>]
  local slug=$1 base_value=$2 branch_value=$3 branch_body=${4:-} dir
  dir="$TMP_ROOT/$slug"
  mkdir -p "$dir/tests"
  git init -q -b main "$dir" 2>/dev/null || { git init -q "$dir"; git -C "$dir" checkout -q -b main; }
  git -C "$dir" config user.email fm@example.com
  git -C "$dir" config user.name fm
  printf '#!/usr/bin/env bash\necho %s\n' "$base_value" > "$dir/app.sh"
  chmod +x "$dir/app.sh"
  cat > "$dir/tests/app.test.sh" <<EOF
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "\$1"; }
[ "\$(bash app.sh)" = "$base_value" ] || { printf 'not ok - app emits $base_value\n'; exit 1; }
pass "app emits $base_value"
EOF
  cat > "$dir/tests/constant.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
pass "a constant that does not read the tree"
EOF
  chmod +x "$dir/tests/app.test.sh" "$dir/tests/constant.test.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
  git -C "$dir" checkout -q -b work
  printf '#!/usr/bin/env bash\necho %s\n' "$branch_value" > "$dir/app.sh"
  if [ -n "$branch_body" ]; then
    printf '%s\n' "$branch_body" > "$dir/tests/app.test.sh"
    chmod +x "$dir/tests/app.test.sh"
  fi
  git -C "$dir" add -A
  git -C "$dir" commit -qm work
  printf '%s\n' "$dir"
}

# run_real <dir> [<extra arg>...]: the real script against the real owner.
run_real() {  # <dir> [<extra arg>...]
  local dir=$1
  shift
  mkdir -p "$dir/.state"
  touch "$dir/.state/.last-watcher-beat"
  RC=0
  OUT=$(env -u GITHUB_STEP_SUMMARY FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/.state" \
    "$REVERIFY" --worktree "$dir" --base main --branch work "$@" 2>/dev/null) || RC=$?
}

test_end_to_end_an_identical_test_corpus_is_nothing_to_verify() {
  local dir out
  # Both test files byte-identical to main's, so the premise flag skips both and
  # the selection is genuinely empty. app.sh changed underneath, which is exactly
  # the state a moved base leaves: nothing for THIS check to re-run.
  dir=$(make_repo e2e-nothing Z K)
  run_real "$dir" --assume-branch-suite-green
  out=$OUT

  expect_code 0 "$RC" "e2e-nothing: an empty selection must not block"
  assert_contains "$out" 'reverify: nothing-to-verify' \
    "e2e-nothing: an all-identical corpus must render as nothing to verify"
  assert_contains "$out" 'executed-files=0' \
    "e2e-nothing: the owner must report that no file was run"
  pass "end to end, a test corpus identical to the base's renders as nothing-to-verify"
}

test_end_to_end_a_changed_base_test_file_is_actually_re_run() {
  local dir out
  # The branch ADDS an assertion to main's test file, so the file differs and
  # the selection must pick it, while main's own assertion still holds against
  # the branch's code. That is the shape a genuine re-verification takes: one
  # file actually executed, and the verdict earned rather than empty. The
  # constant file is left untouched, so it must still be skipped alongside it.
  # shellcheck disable=SC2016 # the fixture body is the generated test's own shell text; $1 must stay literal.
  dir=$(make_repo e2e-verified Z Z "$(printf '#!/usr/bin/env bash\npass() { printf "ok - %%s\\n" "$1"; }\n[ "$(bash app.sh)" = "Z" ] || { printf "not ok - app emits Z\\n"; exit 1; }\npass "app emits Z"\npass "an assertion the branch added"\n')")
  run_real "$dir" --assume-branch-suite-green
  out=$OUT

  expect_code 0 "$RC" "e2e-verified: a re-run whose assertions hold must not block"
  assert_contains "$out" 'reverify: verified' \
    "e2e-verified: a real re-run that held must render as verified"
  assert_contains "$out" 'executed-files=1' \
    "e2e-verified: exactly the one differing file must have been re-run"
  pass "end to end, a base test file that differs is actually re-run and reads as verified"
}

test_end_to_end_a_broken_base_assertion_blocks() {
  local dir out
  # Same shape as the case above, except the branch's app.sh no longer satisfies
  # main's assertion. Without the differing-file selection this is exactly the
  # regression a stale green hides.
  # shellcheck disable=SC2016 # the fixture body is the generated test's own shell text; $1 must stay literal.
  dir=$(make_repo e2e-broken Z K "$(printf '#!/usr/bin/env bash\npass() { printf "ok - %%s\\n" "$1"; }\npass "an unrelated assertion the branch added"\n')")
  run_real "$dir" --assume-branch-suite-green
  out=$OUT

  expect_code 1 "$RC" "e2e-broken: a base assertion the branch dropped must block"
  assert_contains "$out" 'reverify: not-verified' \
    "e2e-broken: a dropped base assertion must render as not-verified"
  assert_contains "$out" 'missing: tests/app.test.sh::app emits Z' \
    "e2e-broken: the dropped identifier must be named"
  pass "end to end, a base assertion the branch no longer satisfies blocks the check"
}

# --- the workflow that makes it a gate --------------------------------------
#
# Read out of .github/workflows/reverify-base.yml at run time. The workflow is
# what makes the check REQUIRED rather than advisory (captain's decision,
# 2026-08-09: merging from the GitHub UI bypasses bin/fm-pr-merge.sh's gate
# entirely), so the properties that make it a usable gate are asserted rather
# than assumed.

# workflow_code: the workflow with full-line comments removed. The negative
# assertions run against THIS, because a comment naming the thing the workflow
# must not do (a merge ref, a test file) is documentation, not a second
# implementation, and asserting over prose would only teach the next author to
# stop explaining the boundary.
workflow_code() {
  grep -v '^[[:space:]]*#' "$REVERIFY_YML"
}

test_the_workflow_exists_and_calls_the_single_selection_owner() {
  [ -f "$REVERIFY_YML" ] || fail "there is no .github/workflows/reverify-base.yml at all"
  assert_contains "$(workflow_code)" 'bin/fm-reverify-base.sh' \
    "the workflow must invoke the check rather than re-spelling it inline"
  assert_contains "$(workflow_code)" 'bin/fm-reverify-premise.sh' \
    "the workflow must establish its premise through the script that owns that read"
  pass "the re-verification workflow exists and drives the check through its scripts"
}

test_the_workflow_does_not_reimplement_the_test_file_selection() {
  local code
  # The one-owner rule, mechanically. bin/fm-assert-tests-kept.sh decides which
  # of the base's test files still need running; a workflow that names test files
  # or diffs for them is a second implementation of that decision, and the two
  # copies drift the moment only one is edited.
  code=$(workflow_code)
  assert_not_contains "$code" '.test.sh' \
    "the workflow must not name test files: selecting them is the owner's job alone"
  assert_not_contains "$code" 'git diff' \
    "the workflow must not derive its own changed-file set"
  pass "the workflow carries no second copy of the test-file selection"
}

test_the_workflow_measures_the_pr_head_not_the_merge_ref() {
  local code
  # Checking out refs/pull/N/merge would answer a different question - the base
  # is already merged in there - and answer it green every time.
  code=$(workflow_code)
  assert_contains "$code" 'pull_request.head.sha' \
    "the workflow must check out the PR's own head"
  assert_not_contains "$code" 'refs/pull' \
    "the workflow must not check out a merge ref, which would already contain the base"
  pass "the workflow measures the PR's own head, never a merge ref"
}

test_the_workflow_refetches_the_base_at_job_time() {
  local code
  # This is what makes re-running the workflow a re-verification at all: the base
  # is resolved by a network fetch when the job runs, not from whatever the
  # checkout captured when the head was last pushed.
  code=$(workflow_code)
  assert_contains "$code" 'git fetch --no-tags origin' \
    "the workflow must fetch the base branch at job time"
  assert_contains "$code" 'pull_request.base.ref' \
    "the workflow must fetch the branch the PR actually targets, never an assumed default"
  pass "the workflow re-fetches the base branch at job time, so a re-run measures the current base"
}

test_the_workflow_runs_on_every_pull_request_and_is_never_skipped() {
  local code cond
  # A required check that is skipped never reports, and branch protection then
  # waits on it forever. Every ordinary condition here is therefore on a STEP.
  # The ONE job-level condition allowed is `always()`, which is the opposite of
  # a skip: it is what makes a job with a `needs:` still run and still report
  # when that dependency failed. Anything else can skip a job.
  code=$(workflow_code)
  assert_contains "$code" 'pull_request:' \
    "the workflow must run on pull requests, which is where the check is required"
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    [ "$cond" = "if: always()" ] && continue
    fail "a job carries the job-level condition '$cond', which can skip it and leave a required check pending forever"
  done < <(printf '%s\n' "$code" | grep -E '^    if:' | sed 's/^ *//')
  pass "the job runs on every pull request and carries no condition that could skip it"
}

test_the_required_job_still_reports_when_its_dependency_fails() {
  local code job_block
  # The dependency added for the captain's approvals is the hazard this asserts
  # away: a job that `needs:` another is SKIPPED when that one fails, and a
  # skipped required check never reports at all, so branch protection waits on
  # it forever. `always()` is what makes the dependency safe.
  code=$(workflow_code)
  job_block=$(printf '%s\n' "$code" | awk '
    /^  reverify-base:/ { inblock = 1; next }
    inblock && /^  [a-z0-9_-]+:/ { inblock = 0 }
    inblock { print }
  ')
  [ -n "$job_block" ] || fail "the workflow carries no reverify-base job to check"
  if printf '%s\n' "$job_block" | grep -qE '^    needs:'; then
    assert_contains "$job_block" 'if: always()' \
      "a required job that depends on another must run even when that one fails, or a failed dependency leaves the check pending forever"
  fi
  pass "the required job reports its verdict even when the job it depends on fails"
}

test_the_signing_secret_never_reaches_the_job_that_runs_the_branchs_code() {
  local code verify_job reverify_job
  # The re-verification job runs the BRANCH's own scripts - that is what
  # re-verification means - so a secret in its environment would be a secret
  # every PR could read and exfiltrate. The verifying job runs the BASE's copy
  # instead, and hands over only its non-secret verdict.
  code=$(workflow_code)
  verify_job=$(printf '%s\n' "$code" | awk '
    /^  supersession:/ { inblock = 1; next }
    inblock && /^  [a-z0-9_-]+:/ { inblock = 0 }
    inblock { print }
  ')
  reverify_job=$(printf '%s\n' "$code" | awk '
    /^  reverify-base:/ { inblock = 1; next }
    inblock && /^  [a-z0-9_-]+:/ { inblock = 0 }
    inblock { print }
  ')
  [ -n "$verify_job" ] || fail "the workflow carries no attestation-verifying job"
  assert_contains "$verify_job" 'secrets.FM_SUPERSESSION_SECRET' \
    "the verifying job must hold the secret its verification needs"
  assert_contains "$verify_job" 'pull_request.base.sha' \
    "the verifying job must check out the BASE, so a PR cannot replace the verifier that holds the secret"
  assert_not_contains "$reverify_job" 'secrets.' \
    "the job that runs the branch's own scripts must hold no secret at all"
  pass "the attestation's secret is held only by a job checked out at the base, never beside the branch's code"
}

test_the_workflow_passes_only_the_verified_entries_to_the_verdict() {
  local code
  # The excusal must rest on what the signature check produced, never on the PR
  # body or any other value the PR itself controls.
  code=$(workflow_code)
  # shellcheck disable=SC2016 # a GitHub expression, quoted literally on purpose
  assert_contains "$code" 'FM_SUPERSESSION_ENTRIES: ${{ needs.supersession.outputs.entries }}' \
    "the verdict step must take its approvals from the verifying job's output alone"
  assert_contains "$code" 'pull-requests: read' \
    "the workflow must be able to read the PR body, where an attestation added after the fact lives"
  pass "the verdict step is handed only the entries the signature check verified"
}

test_the_workflow_blocks_rather_than_passing_when_its_premise_fails() {
  local code
  # The cheap path rests on the branch's own suite being green for this head. A
  # premise step allowed to fail softly would let the job go green having
  # verified nothing, which is the exact shape this gate family exists to remove.
  code=$(workflow_code)
  if printf '%s\n' "$code" | grep -q 'continue-on-error'; then
    fail "no step may continue on error: a premise or verdict step that fails must fail the check"
  fi
  assert_contains "$code" "steps.premise.outputs.premise == 'green'" \
    "the re-verification steps must run only once the premise is actually established"
  pass "the workflow blocks rather than passing when the premise its skip rests on fails"
}

test_the_workflow_reads_the_check_names_ci_actually_publishes() {
  local fanin shard_name shard_prefix
  # The premise is read by check-run NAME, and .github/workflows/ci.yml owns
  # those names. Both are derived from that file here rather than written down
  # twice: a job renamed there would otherwise leave this workflow polling for a
  # name nothing publishes until its timeout, every time, on every PR.
  fanin=$(awk '/^  tests-complete:/ { inblock = 1; next }
    inblock && /^  [a-z0-9_-]+:/ { inblock = 0 }
    inblock && /^    name: / { sub(/^    name: /, ""); print; exit }' "$CI_YML")
  [ -n "$fanin" ] || fail "ci.yml's tests-complete job publishes no name to read"
  assert_contains "$(workflow_code)" "$fanin" \
    "the workflow must wait on the fan-in check name ci.yml actually publishes"

  shard_name=$(awk '/^  tests:/ { inblock = 1; next }
    inblock && /^  [a-z0-9_-]+:/ { inblock = 0 }
    inblock && /^    name: / { sub(/^    name: /, ""); print; exit }' "$CI_YML")
  [ -n "$shard_name" ] || fail "ci.yml's tests job publishes no name to read"
  # Everything up to the matrix expression is the stable prefix every shard's
  # published name starts with.
  # shellcheck disable=SC2016 # the braces are the literal matrix-expression marker being cut at.
  shard_prefix=${shard_name%%'${{'*}
  [ "$shard_prefix" != "$shard_name" ] || fail "ci.yml's tests job name carries no matrix expression to derive a prefix from: $shard_name"
  assert_contains "$(workflow_code)" "$shard_prefix" \
    "the workflow must match shard checks on the prefix ci.yml actually publishes"
  pass "the workflow reads the two check names ci.yml actually publishes"
}

test_the_workflow_provisions_what_the_base_test_files_need() {
  local code tests_job dep
  # It executes the BASE's own test files, so it needs everything the behaviour
  # suite installs for them. Derived from that job at run time rather than
  # hand-listed here: a dependency added there and not here would surface as
  # `unexecuted:` - a block - on the next PR that touches a test file needing it.
  code=$(workflow_code)
  tests_job=$(awk '
    /^  tests:/ { inblock = 1; next }
    inblock && /^  [a-z0-9_-]+:/ { inblock = 0 }
    inblock { print }
  ' "$CI_YML")
  [ -n "$tests_job" ] || fail "ci.yml carries no tests job to derive the provisioning from"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    assert_contains "$code" "$dep" \
      "the re-verification workflow must install what the base's test files need: $dep"
  done < <(printf '%s\n' "$tests_job" | grep -oE 'bin/fm-install-shellcheck.sh|npm install -g [a-z-]+' | sort -u)
  pass "the workflow provisions everything the behaviour suite installs for the base's own test files"
}

test_executed_files_above_zero_reads_as_verified
test_zero_executed_files_reads_as_nothing_to_verify_not_as_verified
test_the_three_outcomes_render_as_three_distinct_first_lines
test_findings_covered_by_the_captains_approvals_read_as_superseded
test_a_finding_no_approval_covers_still_blocks
test_an_approval_excuses_only_the_class_it_names
test_approvals_reach_the_unexecutable_and_unstable_classes_too
test_an_unreadable_approval_reads_as_could_not_verify_never_as_no_approvals
test_approvals_are_refused_when_the_findings_cannot_be_matched_one_by_one
test_the_approvals_are_inert_when_none_are_supplied
test_a_missing_identifier_reads_as_not_verified_and_blocks
test_a_failing_assertion_reads_as_not_verified_and_names_the_unverifiable_half
test_unexecuted_alone_reads_as_could_not_verify
test_unstable_alone_reads_as_could_not_verify
test_owner_refusal_reads_as_could_not_verify
test_an_undefined_owner_exit_code_reads_as_could_not_verify
test_a_green_exit_with_no_summary_reads_as_could_not_verify
test_a_summary_without_the_executed_count_reads_as_could_not_verify
test_an_exit_code_that_contradicts_the_summary_reads_as_could_not_verify
test_a_missing_selection_owner_reads_as_could_not_verify
test_no_arguments_still_renders_an_outcome
test_arguments_are_forwarded_to_the_selection_owner_verbatim
test_the_owners_own_output_is_relayed_in_full
test_the_outcome_is_written_to_the_github_step_summary
test_end_to_end_an_identical_test_corpus_is_nothing_to_verify
test_end_to_end_a_changed_base_test_file_is_actually_re_run
test_end_to_end_a_broken_base_assertion_blocks
test_the_workflow_exists_and_calls_the_single_selection_owner
test_the_workflow_does_not_reimplement_the_test_file_selection
test_the_workflow_measures_the_pr_head_not_the_merge_ref
test_the_workflow_refetches_the_base_at_job_time
test_the_workflow_runs_on_every_pull_request_and_is_never_skipped
test_the_required_job_still_reports_when_its_dependency_fails
test_the_signing_secret_never_reaches_the_job_that_runs_the_branchs_code
test_the_workflow_passes_only_the_verified_entries_to_the_verdict
test_the_workflow_blocks_rather_than_passing_when_its_premise_fails
test_the_workflow_reads_the_check_names_ci_actually_publishes
test_the_workflow_provisions_what_the_base_test_files_need
