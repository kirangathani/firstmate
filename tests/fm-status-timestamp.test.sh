#!/usr/bin/env bash
# tests/fm-status-timestamp.test.sh - the optional "[t=<epoch>] " report-time
# prefix on a status line (bin/fm-classify-lib.sh owns the grammar).
#
# The prefix exists so firstmate can tell when a crew REPORTED, which is the one
# fact its own response latency cannot be derived without. The whole risk of
# adding it is the blast radius: every consumer of state/<id>.status parses
# "<verb>: <note>", and every status file that existed when the token was
# introduced is untimestamped while its live task keeps appending to it. So the
# contract these cases pin is not "the new form parses" but "a file holding BOTH
# forms parses correctly, in every consumer, permanently".
#
# Covered here: the shared parsers and both folds over a deliberately mixed log;
# the two writers that are not the crew itself; the brief template crews copy;
# and bin/fm-pr-poll.sh, the one consumer that matches a status line without
# sourcing the library and therefore has its own copy of the strip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-timestamp-tests)
# fm_test_tmproot's own header: called from a command substitution it installs
# its cleanup trap in that subshell, which fires and removes the directory
# before the caller sees it. Sibling suites hide this by only ever writing under
# a per-case mkdir -p; cases here write straight into the root, so recreate it.
mkdir -p "$TMP_ROOT"

# A status log that is part-old, part-new, exactly as a live task's log looks
# the moment a crew picks up the new template mid-run.
mixed_log() {  # <path>
  {
    printf 'working: read the brief\n'
    printf 'needs-decision [key=api-shape]: one call or two?\n'
    printf '[t=1789580400] working: still going\n'
    printf '[t=1789580500] needs-decision [key=db]: postgres or sqlite?\n'
    printf '[t=1789580600] resolved [key=api-shape]: captain chose two\n'
  } > "$1"
}

expect_eq() {  # <expected> <actual> <label>
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

test_parsers_read_both_forms() {
  expect_eq working "$(status_line_verb 'working: old form')" "old-form verb"
  expect_eq working "$(status_line_verb '[t=1789580400] working: new form')" "new-form verb"
  expect_eq 'old form' "$(status_line_note 'working: old form')" "old-form note"
  expect_eq 'new form' "$(status_line_note '[t=1789580400] working: new form')" "new-form note"
  expect_eq '' "$(status_line_epoch 'working: old form')" "old-form epoch is unknown, not zero"
  expect_eq 1789580400 "$(status_line_epoch '[t=1789580400] working: new form')" "new-form epoch"

  # The key token in both of its accepted positions, now behind a prefix.
  expect_eq api "$(_fm_decision_key '[t=1] needs-decision [key=api]: which?')" "pre-colon key behind a prefix"
  expect_eq api "$(_fm_decision_key '[t=1] resolved: [key=api] chose A')" "post-colon key behind a prefix"
  expect_eq default "$(_fm_decision_key '[t=1] resolved: chose A')" "unkeyed line behind a prefix"

  # A leading bracket that is NOT a time token is left in the body, so a note
  # or verb that merely starts with one reads exactly as it did before.
  expect_eq '[t=abc] done' "$(status_line_verb '[t=abc] done: not a time')" "non-numeric token is not a prefix"
  expect_eq '[notatime] done' "$(status_line_verb '[notatime] done: weird')" "unrelated bracket is not a prefix"

  # Indented lines: the fold trims leading whitespace, so the prefix has to be
  # found behind it too.
  expect_eq paused "$(status_line_verb '  [t=17] paused: waiting')" "indented prefixed verb"
  expect_eq 17 "$(status_line_epoch '  [t=17] paused: waiting')" "indented prefixed epoch"

  pass "status-line parsers read timestamped and untimestamped lines alike"
}

test_classifiers_read_both_forms() {
  status_is_captain_relevant '[t=5] done: PR up' || fail "timestamped done: not captain-relevant"
  status_is_captain_relevant 'done: PR up' || fail "untimestamped done: not captain-relevant"
  status_is_paused '[t=5] paused: upstream release' || fail "timestamped pause not recognised"
  ! status_is_captain_relevant '[t=5] paused: upstream release' \
    || fail "timestamped pause leaked into the captain-relevant set"
  status_is_paused_or_captain_held '[t=5] captain-held [key=x]: tracked by y' \
    || fail "timestamped captain-held not recognised"
  pass "captain-relevant, pause and captain-held classifiers read both forms"
}

test_decision_fold_over_a_mixed_log() {
  local log open
  log="$TMP_ROOT/mixed.status"
  mixed_log "$log"
  open=$(status_open_decisions "$log")
  # The timestamped resolution closes the UNtimestamped decision it names, and
  # the timestamped decision it does not name stays open. Getting either half
  # wrong is the 50-minute unanswered-captain failure the key grammar exists for.
  assert_contains "$open" "db	needs-decision	postgres or sqlite?" "timestamped open decision lost from the fold"
  assert_not_contains "$open" "api-shape" "timestamped resolution did not close the untimestamped decision"
  pass "open-decision fold is correct over a part-old, part-new log"
}

test_activity_fold_over_a_mixed_log() {
  local log open
  log="$TMP_ROOT/mixed-activity.status"
  mixed_log "$log"
  open=$(status_open_activities "$log")
  assert_contains "$open" "default	working	still going" "timestamped working phase lost from the activity fold"
  pass "open-activity fold is correct over a part-old, part-new log"
}

test_last_line_and_scan_over_a_mixed_log() {
  local state last scan
  state="$TMP_ROOT/scan-state"
  mkdir -p "$state"
  printf 'working: warming up\n[t=1789580700] done: PR https://example.invalid/pr/1 checks green\n' \
    > "$state/timestamped.status"
  printf 'done: PR https://example.invalid/pr/2 checks green\n' > "$state/legacy.status"
  last=$(last_status_line "$state/timestamped.status")
  assert_contains "$last" "[t=1789580700]" "last_status_line dropped the prefix it should hand on verbatim"
  scan=$(scan_captain_relevant_statuses "$state")
  assert_contains "$scan" "timestamped" "timestamped terminal line missed by the captain-relevant scan"
  assert_contains "$scan" "legacy" "untimestamped terminal line missed by the captain-relevant scan"
  pass "last-line read and fleet scan see both forms"
}

# bin/fm-pr-poll.sh is the one status-line consumer that cannot source the
# library: it is copied byte-for-byte to state/<id>.check.sh and runs standalone.
# Its rule is that a task whose last line is anything but done: stays silent on
# green, so a timestamped done: that failed to strip would silently disable the
# captain's standing merge wake for every task using the new template.
poll_case() {  # <last-status-line-or-empty> <label> <expect-wake yes|no>
  local line=$1 label=$2 expect=$3 home out
  home="$TMP_ROOT/poll-$label"
  mkdir -p "$home/config" "$home/state" "$home/bin"
  : > "$home/config/merge-green"
  [ -z "$line" ] || printf '%s\n' "$line" > "$home/state/poll-t1.status"
  # The poll reads green from its sibling fm-pr-green.sh; a stub that always
  # reports green isolates the status gate, which is what this case is about.
  cp "$ROOT/bin/fm-pr-poll.sh" "$home/bin/fm-pr-poll.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/bin/fm-pr-green.sh"
  chmod +x "$home/bin/fm-pr-green.sh"
  cat > "$home/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf 'OPEN\n'
GHEOF
  chmod +x "$home/bin/gh"
  out=$(PATH="$home/bin:$PATH" FM_HOME="$home" \
    "$home/bin/fm-pr-poll.sh" --validated poll-t1 https://github.com/o/r/pull/1 o r 1 2>/dev/null) || true
  if [ "$expect" = yes ]; then
    assert_contains "$out" "green:" "$label: expected the standing merge rule to wake firstmate"
  else
    assert_not_contains "$out" "green:" "$label: expected silence"
  fi
}

test_pr_poll_reads_both_forms() {
  poll_case '' "no-status" yes
  poll_case 'done: PR up, checks green' "legacy-done" yes
  poll_case '[t=1789580800] done: PR up, checks green' "timestamped-done" yes
  poll_case 'working: still going' "legacy-working" no
  poll_case '[t=1789580800] working: still going' "timestamped-working" no
  poll_case '[t=notatime] working: still going' "non-token-working" no
  pass "the standalone merge poll silences and wakes on both forms"
}

test_brief_template_carries_the_stamp() {
  local home brief count
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" stamp-t1 proj >/dev/null
  brief="$home/data/stamp-t1/brief.md"
  assert_present "$brief" "fm-brief.sh wrote no brief"
  assert_grep '[t=$(date +%s)] {state}: {one short line}' "$brief" \
    "the ship brief's status template lost the report-time stamp"
  # The stamp must be UNEXPANDED in the brief: the crew evaluates it at report
  # time, so a brief carrying the scaffold moment's epoch would timestamp every
  # line of a week-long task with the second it was dispatched.
  count=$(grep -c 't=1[0-9]\{9\}' "$brief" || true)
  expect_eq 0 "$count" "the brief expanded date at scaffold time instead of leaving it to the crew"
  pass "the generated brief hands crews the timestamped status template"
}

# The two firstmate-side appenders. Their end-to-end behavior is owned by
# tests/fm-decision-hold-lifecycle.test.sh and tests/fm-nm-attach.test.sh; what
# is pinned here is only that the line each writes carries a prefix this
# library can read back, which is what makes those lines timeable.
test_firstmate_side_appenders_are_stamped() {
  local line
  assert_grep "'[t=%s] captain-held [key=%s]: tracked by %s\\n'" "$ROOT/bin/fm-decision-hold.sh" \
    "the captain-held transfer append lost its report-time stamp"
  assert_grep "'[t=%s] resolved [key=nm-run]:" "$ROOT/bin/fm-nm-attach.sh" \
    "the gate-response append lost its report-time stamp"
  assert_grep "stamp() { printf '[t=%s] '" "$ROOT/bin/fm-nm-attach.sh" \
    "the detached hold's status appender lost its report-time stamp"
  line="[t=1789580900] captain-held [key=route]: tracked by dh-t1-route"
  expect_eq 1789580900 "$(status_line_epoch "$line")" "captain-held epoch behind a prefix"
  expect_eq captain-held "$(status_line_verb "$line")" "captain-held verb behind a prefix"
  pass "firstmate's own status appends carry a readable report-time stamp"
}

test_parsers_read_both_forms
test_classifiers_read_both_forms
test_decision_fold_over_a_mixed_log
test_activity_fold_over_a_mixed_log
test_last_line_and_scan_over_a_mixed_log
test_pr_poll_reads_both_forms
test_brief_template_carries_the_stamp
test_firstmate_side_appenders_are_stamped
