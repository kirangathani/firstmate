#!/usr/bin/env bash
# tests/fm-reverify-premise.test.sh - behavior tests for
# bin/fm-reverify-premise.sh, which establishes the one premise the cheap base
# re-verification rests on: this head's own behaviour suite is verified green.
#
# Why this is worth its own suite. The premise is what licenses skipping a base
# test file the branch's copy matches byte for byte - 83 of 85 files on this
# repo. Get it wrong in the permissive direction and the whole re-verification
# goes green having run almost nothing, which is precisely the false green it
# exists to remove. So every case here is about the boundary between the three
# answers, and above all about the shapes that must NOT read as green: a fan-in
# check that passed on a CI waiver with no shard having run, a shard that failed
# under a fan-in that passed anyway, a suite still running, and an API read that
# did not come back at all.
#
# Hermetic: a fake `gh` per case, injected through FM_REVERIFY_PREMISE_GH, whose
# scripted responses are the exact TSV the real `--jq` template produces. No
# network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reverify-premise)
PREMISE="$ROOT/bin/fm-reverify-premise.sh"

FANIN='Behavior tests complete'
SHARD_PREFIX='Behavior tests (shard '

# fake_gh <slug>: a `gh` whose successive invocations print successive response
# files, so a case can drive the poll loop through more than one reading. Each
# response is one file named <n>; the last one is repeated once exhausted, and
# a response file holding the single token EXIT1 makes that call fail instead.
# Echoes the fake's path.
fake_gh() {  # <slug>
  local slug=$1 d
  d="$TMP_ROOT/$slug"
  mkdir -p "$d/responses"
  cat > "$d/gh" <<EOF
#!/usr/bin/env bash
d="$d"
n=\$(cat "\$d/calls" 2>/dev/null || echo 0)
n=\$((n + 1))
printf '%s\\n' "\$n" > "\$d/calls"
f="\$d/responses/\$n"
if [ ! -f "\$f" ]; then
  # Past the scripted end: keep answering with the last scripted response, so a
  # loop that polls more times than a case scripted still terminates on content
  # rather than on a missing file.
  f=\$(ls "\$d/responses" | sort -n | tail -1)
  f="\$d/responses/\$f"
fi
[ -f "\$f" ] || exit 1
if [ "\$(cat "\$f")" = "EXIT1" ]; then
  echo "gh: read failed" >&2
  exit 1
fi
cat "\$f"
EOF
  chmod +x "$d/gh"
  printf '%s\n' "$d"
}

# respond <fake-dir> <n>: write response <n> from stdin.
respond() {  # <fake-dir> <n>
  cat > "$1/responses/$2"
}

# checks_tsv: the exact shape `gh api ... --jq '[.name,.status,.conclusion]|@tsv'`
# emits, built here so every case states real bytes rather than a shape invented
# beside the assertion.
shard_line() {  # <n> <status> <conclusion>
  printf '%s%s)\t%s\t%s\n' "$SHARD_PREFIX" "$1" "$2" "$3"
}
fanin_line() {  # <status> <conclusion>
  printf '%s\t%s\t%s\n' "$FANIN" "$1" "$2"
}

RC=0
OUT=
run_premise() {  # <fake-dir> [<extra arg>...]
  local d=$1
  shift
  RC=0
  OUT=$(env -u GITHUB_OUTPUT FM_REVERIFY_PREMISE_GH="$d/gh" \
    "$PREMISE" --repo o/r --sha deadbeef \
    --fanin-check "$FANIN" --shard-check-prefix "$SHARD_PREFIX" \
    --timeout-seconds 0 --poll-seconds 0 "$@" 2>/dev/null) || RC=$?
}

test_every_shard_green_under_a_green_fanin_is_the_premise() {
  local d
  d=$(fake_gh green)
  {
    fanin_line completed success
    shard_line 1 completed success
    shard_line 2 completed success
    shard_line 3 completed success
    shard_line 4 completed success
  } | respond "$d" 1
  run_premise "$d"

  expect_code 0 "$RC" "green: an established premise must not block"
  assert_contains "$OUT" 'premise: green' \
    "green: a fully green suite for this head is the premise"
  assert_contains "$OUT" 'all 4 behaviour shard(s) succeeded' \
    "green: the detail must name how many shards it actually read"
  pass "a green fan-in over every-shard-success establishes the premise"
}

test_a_green_fanin_with_no_shard_run_is_the_waiver_not_the_premise() {
  local d
  # The exact shape a verified CI waiver leaves: the fan-in reports success while
  # every shard was skipped. Reading the fan-in alone would take this as a green
  # suite and skip 83 of 85 base test files on the strength of tests that never
  # ran - the single most dangerous misreading available here.
  d=$(fake_gh waived)
  {
    fanin_line completed success
    shard_line 1 completed skipped
    shard_line 2 completed skipped
    shard_line 3 completed skipped
    shard_line 4 completed skipped
  } | respond "$d" 1
  run_premise "$d"

  expect_code 0 "$RC" "waived: a captain-authorized waiver must not block"
  assert_contains "$OUT" 'premise: waived' \
    "waived: a fan-in that passed on a waiver must never read as a green suite"
  assert_not_contains "$OUT" 'premise: green' \
    "waived: no shard ran, so there is no verified suite to rest the skip on"
  pass "a green fan-in with every shard skipped reads as the waiver, never as the premise"
}

test_a_green_fanin_with_no_shard_checks_at_all_is_the_waiver() {
  local d
  # Same situation, different rendering by the platform: a job skipped by its
  # own condition may publish no check run at all rather than a skipped one.
  d=$(fake_gh waived-absent)
  fanin_line completed success | respond "$d" 1
  run_premise "$d"

  expect_code 0 "$RC" "waived-absent: a waiver that published no shard checks must not block"
  assert_contains "$OUT" 'premise: waived' \
    "waived-absent: a fan-in that succeeded with no shard present is still the waiver path"
  pass "a green fan-in with no shard check present at all reads as the waiver"
}

test_a_failed_shard_under_a_green_fanin_is_unavailable() {
  local d
  # The fan-in can be made to pass while a shard did not succeed. The shards are
  # therefore read in their own right rather than through it.
  d=$(fake_gh shard-failed)
  {
    fanin_line completed success
    shard_line 1 completed success
    shard_line 2 completed failure
  } | respond "$d" 1
  run_premise "$d"

  expect_code 1 "$RC" "shard-failed: a shard that did not succeed must block"
  assert_contains "$OUT" 'premise: unavailable' \
    "shard-failed: a suite with a failed shard is not a verified-green suite"
  assert_contains "$OUT" 'failure' \
    "shard-failed: the detail must name the conclusion it refused"
  pass "a failed shard under a green fan-in leaves the premise unavailable"
}

test_a_failed_fanin_is_unavailable() {
  local d
  d=$(fake_gh fanin-failed)
  {
    fanin_line completed failure
    shard_line 1 completed failure
  } | respond "$d" 1
  run_premise "$d"

  expect_code 1 "$RC" "fanin-failed: a red suite must block"
  assert_contains "$OUT" 'premise: unavailable' \
    "fanin-failed: a red suite is not a premise"
  assert_contains "$OUT" 'fix the suite first' \
    "fanin-failed: the detail must point at the real problem rather than at this check"
  pass "a failed fan-in check leaves the premise unavailable"
}

test_a_mixed_shard_state_is_unavailable() {
  local d
  # Neither all-green nor all-skipped. There is no reading of this that supports
  # the skip, and falling to either named answer would be inventing one.
  d=$(fake_gh mixed)
  {
    fanin_line completed success
    shard_line 1 completed success
    shard_line 2 completed skipped
  } | respond "$d" 1
  run_premise "$d"

  expect_code 1 "$RC" "mixed: a partially-run suite must block"
  assert_contains "$OUT" 'premise: unavailable' \
    "mixed: a suite that only partly ran supports neither answer"
  pass "a suite whose shards are neither all green nor all skipped leaves the premise unavailable"
}

test_a_suite_still_running_is_unavailable_once_the_wait_runs_out() {
  local d
  d=$(fake_gh still-running)
  {
    fanin_line in_progress ''
    shard_line 1 in_progress ''
  } | respond "$d" 1
  run_premise "$d"

  expect_code 1 "$RC" "still-running: an unfinished suite must block rather than pass"
  assert_contains "$OUT" 'premise: unavailable' \
    "still-running: a suite that has not concluded is not a green one"
  assert_contains "$OUT" 'still running' \
    "still-running: the detail must name what it was waiting for"
  pass "a suite still running leaves the premise unavailable once the wait runs out"
}

test_an_absent_fanin_check_is_unavailable() {
  local d
  d=$(fake_gh fanin-absent)
  printf 'Lint shell scripts\tcompleted\tsuccess\n' | respond "$d" 1
  run_premise "$d"

  expect_code 1 "$RC" "fanin-absent: no suite result at all must block"
  assert_contains "$OUT" 'premise: unavailable' \
    "fanin-absent: a head whose suite never reported has no premise"
  pass "a head with no fan-in check at all leaves the premise unavailable"
}

test_a_failed_api_read_is_unavailable() {
  local d
  d=$(fake_gh api-failed)
  printf 'EXIT1\n' > "$d/responses/1"
  run_premise "$d"

  expect_code 1 "$RC" "api-failed: an unreadable API must block"
  assert_contains "$OUT" 'premise: unavailable' \
    "api-failed: a read that did not come back says nothing about the suite"
  pass "an API read that failed leaves the premise unavailable"
}

test_a_missing_github_cli_is_unavailable() {
  local d out rc=0
  d=$(fake_gh no-gh)
  out=$(env -u GITHUB_OUTPUT FM_REVERIFY_PREMISE_GH="$d/definitely-not-here" \
    "$PREMISE" --repo o/r --sha deadbeef \
    --fanin-check "$FANIN" --shard-check-prefix "$SHARD_PREFIX" \
    --timeout-seconds 0 --poll-seconds 0 2>/dev/null) || rc=$?

  expect_code 1 "$rc" "no-gh: no way to read the premise must block"
  assert_contains "$out" 'premise: unavailable' \
    "no-gh: an unreadable premise is never an established one"
  pass "a missing GitHub CLI leaves the premise unavailable"
}

test_a_missing_argument_still_renders_an_answer() {
  local d out rc=0
  d=$(fake_gh no-repo)
  out=$(env -u GITHUB_OUTPUT FM_REVERIFY_PREMISE_GH="$d/gh" \
    "$PREMISE" --sha deadbeef --fanin-check "$FANIN" \
    --shard-check-prefix "$SHARD_PREFIX" 2>/dev/null) || rc=$?

  expect_code 1 "$rc" "no-repo: a caller that passed too little must block"
  assert_contains "$out" 'premise: unavailable' \
    "no-repo: anything reading the first line must still get one of the three answers"
  pass "a missing required argument still renders an answer and blocks"
}

test_it_waits_for_a_suite_that_has_not_finished_yet() {
  local d
  # The whole point of the wait: on a fresh PR this workflow starts alongside the
  # behaviour suite, so answering on the first reading would report unavailable
  # on every PR. The fake's second response is what proves it read twice.
  d=$(fake_gh polls)
  {
    fanin_line in_progress ''
    shard_line 1 in_progress ''
  } | respond "$d" 1
  {
    fanin_line completed success
    shard_line 1 completed success
  } | respond "$d" 2
  RC=0
  OUT=$(env -u GITHUB_OUTPUT FM_REVERIFY_PREMISE_GH="$d/gh" \
    "$PREMISE" --repo o/r --sha deadbeef \
    --fanin-check "$FANIN" --shard-check-prefix "$SHARD_PREFIX" \
    --timeout-seconds 30 --poll-seconds 1 2>/dev/null) || RC=$?

  expect_code 0 "$RC" "polls: a suite that finishes during the wait must establish the premise"
  assert_contains "$OUT" 'premise: green' \
    "polls: the answer must come from the reading that concluded, not the first one"
  [ "$(cat "$d/calls")" -ge 2 ] || fail "polls: the premise was answered on a single reading, so it never waited"
  pass "a suite that has not finished yet is waited for rather than refused"
}

test_the_answer_is_published_to_the_github_output() {
  local d out file rc=0
  d=$(fake_gh output)
  file="$TMP_ROOT/gh-output"
  : > "$file"
  {
    fanin_line completed success
    shard_line 1 completed success
  } | respond "$d" 1
  out=$(GITHUB_OUTPUT="$file" FM_REVERIFY_PREMISE_GH="$d/gh" \
    "$PREMISE" --repo o/r --sha deadbeef \
    --fanin-check "$FANIN" --shard-check-prefix "$SHARD_PREFIX" \
    --timeout-seconds 0 --poll-seconds 0 2>/dev/null) || rc=$?

  expect_code 0 "$rc" "output: a green premise must not block"
  assert_contains "$(cat "$file")" 'premise=green' \
    "output: the workflow must be able to branch on the answer without parsing the log"
  assert_contains "$out" 'premise: green' \
    "output: publishing the answer must not replace the stdout contract"
  pass "the answer is published to the workflow output as well as to stdout"
}

test_every_shard_green_under_a_green_fanin_is_the_premise
test_a_green_fanin_with_no_shard_run_is_the_waiver_not_the_premise
test_a_green_fanin_with_no_shard_checks_at_all_is_the_waiver
test_a_failed_shard_under_a_green_fanin_is_unavailable
test_a_failed_fanin_is_unavailable
test_a_mixed_shard_state_is_unavailable
test_a_suite_still_running_is_unavailable_once_the_wait_runs_out
test_an_absent_fanin_check_is_unavailable
test_a_failed_api_read_is_unavailable
test_a_missing_github_cli_is_unavailable
test_a_missing_argument_still_renders_an_answer
test_it_waits_for_a_suite_that_has_not_finished_yet
test_the_answer_is_published_to_the_github_output
