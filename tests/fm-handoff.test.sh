#!/usr/bin/env bash
# Tests for bin/fm-handoff.sh: the handoff document's path allocation, its
# unread marker, and the SessionStart pickup announcement a post-/clear session
# receives.
#
# The two behaviors that matter most, because both are silent failures:
#   - the PICKUP PATH: a fresh session must be pointed at THAT handoff file,
#     not left to guess, and the pointer must be shaped so the harness injects
#     it as SessionStart additionalContext.
#   - the CONSUMED MARKER: exactly one pickup per handoff. A consumed handoff
#     must never announce again, and an announced-but-unread one must.
#
# Matrix:
#   (a) path allocates a dated name and never collides with an existing handoff
#   (b) arm refuses anything that is not a real non-empty file under data/
#   (c) pickup is silent with no marker, and silent where state/ does not exist
#       (the crewmate-worktree case, which is how scoping is achieved)
#   (d) pickup announces the exact armed path as SessionStart additionalContext
#   (e) consume clears the marker, after which pickup is silent again
#   (f) consume refuses to clear a marker pointing at a different handoff
#   (g) a marker pointing at a deleted handoff self-heals instead of announcing
#   (h) pickup always exits 0 - it is a hook, never a gate
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDOFF="$ROOT/bin/fm-handoff.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-tests)

# A fake firstmate home: data/ and state/ are all fm-handoff.sh needs.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

run_handoff() {
  local home=$1
  shift
  FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$HANDOFF" "$@"
}

write_handoff_doc() {
  printf '# Handoff\n\nreasoning that state files cannot reconstruct\n' > "$1"
}

test_path_allocates_dated_name_without_collision() {
  local home first second stamp
  home=$(make_home path-alloc)
  stamp=$(date +%Y-%m-%d)

  first=$(run_handoff "$home" path)
  assert_contains "$first" "HANDOFF-$stamp.md" "path: first handoff of the day is the plain dated name"

  write_handoff_doc "$first"
  second=$(run_handoff "$home" path)
  [ "$second" != "$first" ] || fail "path: must not hand back a path that already exists"
  assert_contains "$second" "HANDOFF-$stamp-session2.md" "path: second of the day gets the -sessionN suffix"
  pass "fm-handoff path allocates a dated handoff name and never overwrites an existing one"
}

test_arm_refuses_non_handoff_targets() {
  local home code out empty outside
  home=$(make_home arm-refusals)

  set +e
  out=$(run_handoff "$home" arm "$home/data/nope.md" 2>&1); code=$?
  set -e
  expect_code 1 "$code" "arm: a missing file must be refused"
  assert_contains "$out" 'not a file' "arm: must say the target is not a file"

  empty="$home/data/HANDOFF-empty.md"
  : > "$empty"
  set +e
  out=$(run_handoff "$home" arm "$empty" 2>&1); code=$?
  set -e
  expect_code 1 "$code" "arm: an empty handoff must be refused"
  assert_contains "$out" 'handoff is empty' "arm: must say the handoff is empty"

  # A handoff is firstmate-private: outside data/ it would not be gitignored.
  outside="$home/HANDOFF-stray.md"
  write_handoff_doc "$outside"
  set +e
  out=$(run_handoff "$home" arm "$outside" 2>&1); code=$?
  set -e
  expect_code 1 "$code" "arm: a handoff outside data/ must be refused"
  assert_contains "$out" 'must live under' "arm: must explain the data/ requirement"

  assert_absent "$home/state/.handoff-unread" "arm: a refused arm must not leave a marker behind"
  pass "fm-handoff arm refuses missing, empty, and non-private handoff targets"
}

test_pickup_is_silent_without_a_handoff() {
  local home out code worktree
  home=$(make_home pickup-silent)

  set +e
  out=$(run_handoff "$home" pickup 2>&1); code=$?
  set -e
  expect_code 0 "$code" "pickup: must exit 0 with nothing pending"
  [ -z "$out" ] || fail "pickup: must print nothing when no handoff is armed (got: $out)"

  # The crewmate-worktree case: state/ is gitignored so it does not exist in a
  # task worktree, and the tracked SessionStart hook must stay a silent no-op.
  worktree="$TMP_ROOT/crew-worktree"
  mkdir -p "$worktree"
  set +e
  out=$(FM_DATA_OVERRIDE="$worktree/data" FM_STATE_OVERRIDE="$worktree/state" \
    "$HANDOFF" pickup 2>&1); code=$?
  set -e
  expect_code 0 "$code" "pickup: must exit 0 where state/ does not exist"
  [ -z "$out" ] || fail "pickup: must stay silent in a worktree with no state/ (got: $out)"
  pass "fm-handoff pickup stays a silent no-op with no handoff and in a crewmate worktree"
}

test_pickup_announces_the_exact_armed_handoff() {
  local home doc out ctx
  home=$(make_home pickup-announce)
  doc=$(run_handoff "$home" path)
  write_handoff_doc "$doc"
  run_handoff "$home" arm "$doc" >/dev/null

  out=$(run_handoff "$home" pickup)
  [ -n "$out" ] || fail "pickup: must announce an armed handoff"

  # The harness only injects the pointer if it is shaped as SessionStart
  # additionalContext; a bare human-readable line would be dropped.
  if command -v jq >/dev/null 2>&1; then
    ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext') \
      || fail "pickup: output must be valid hook JSON"
    assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
      'SessionStart' "pickup: must declare the SessionStart hook event"
  else
    ctx=$out
  fi

  assert_contains "$ctx" "$doc" "pickup: must name the exact armed handoff file"
  assert_contains "$ctx" 'UNREAD HANDOFF' "pickup: must be unambiguous that the handoff is unread"
  assert_contains "$ctx" 'fm-handoff.sh consume' "pickup: must tell the fresh session how to mark it read"
  pass "fm-handoff pickup points a fresh session at the exact armed handoff"
}

test_consumed_handoff_does_not_re_announce() {
  local home doc out code
  home=$(make_home consume-once)
  doc=$(run_handoff "$home" path)
  write_handoff_doc "$doc"
  run_handoff "$home" arm "$doc" >/dev/null

  out=$(run_handoff "$home" pickup)
  assert_contains "$out" "$doc" "consume: the first pickup must announce"

  # Announcing must NOT clear the marker on its own: a session that is told and
  # then dies before reading must still be told again.
  assert_present "$home/state/.handoff-unread" "consume: pickup alone must not clear the unread marker"
  out=$(run_handoff "$home" pickup)
  assert_contains "$out" "$doc" "consume: an announced-but-unread handoff must announce again"

  run_handoff "$home" consume >/dev/null
  assert_absent "$home/state/.handoff-unread" "consume: must clear the unread marker"

  set +e
  out=$(run_handoff "$home" pickup 2>&1); code=$?
  set -e
  expect_code 0 "$code" "consume: pickup must still exit 0 after consumption"
  [ -z "$out" ] || fail "consume: a consumed handoff must never announce again (got: $out)"

  # Idempotent: a session that consumes and is then itself cleared must not error.
  set +e
  run_handoff "$home" consume >/dev/null 2>&1; code=$?
  set -e
  expect_code 0 "$code" "consume: a second consume must be a no-op, not an error"
  pass "fm-handoff consume marks a handoff read exactly once and stops it re-announcing"
}

test_consume_refuses_the_wrong_handoff() {
  local home doc other out code
  home=$(make_home consume-mismatch)
  doc=$(run_handoff "$home" path)
  write_handoff_doc "$doc"
  run_handoff "$home" arm "$doc" >/dev/null

  other="$home/data/HANDOFF-other.md"
  write_handoff_doc "$other"

  set +e
  out=$(run_handoff "$home" consume "$other" 2>&1); code=$?
  set -e
  expect_code 1 "$code" "consume: naming a different handoff must be refused"
  assert_contains "$out" 'refusing to clear the wrong handoff' "consume: must say which handoff the marker holds"
  assert_present "$home/state/.handoff-unread" "consume: a refused consume must leave the marker intact"
  pass "fm-handoff consume refuses to clear a marker pointing at a different handoff"
}

test_stale_marker_self_heals() {
  local home doc out code
  home=$(make_home stale-marker)
  doc=$(run_handoff "$home" path)
  write_handoff_doc "$doc"
  run_handoff "$home" arm "$doc" >/dev/null
  rm -f "$doc"

  set +e
  out=$(run_handoff "$home" pickup 2>&1); code=$?
  set -e
  expect_code 0 "$code" "stale: pickup must exit 0 when the handoff is gone"
  [ -z "$out" ] || fail "stale: must not announce a handoff that no longer exists (got: $out)"
  assert_absent "$home/state/.handoff-unread" "stale: a marker pointing at a deleted handoff must be cleared"
  pass "fm-handoff pickup self-heals a marker pointing at a deleted handoff"
}

test_status_reports_pending_state() {
  local home doc out
  home=$(make_home status-report)

  out=$(run_handoff "$home" status)
  assert_contains "$out" 'none' "status: must report nothing pending on a clean home"

  doc=$(run_handoff "$home" path)
  write_handoff_doc "$doc"
  run_handoff "$home" arm "$doc" >/dev/null
  out=$(run_handoff "$home" status)
  assert_contains "$out" 'unread' "status: must report an armed handoff as unread"
  assert_contains "$out" "$doc" "status: must name the pending handoff"
  pass "fm-handoff status reports whether a handoff is pending"
}

# The pickup path is only real if the tracked hook actually invokes it; a
# correct script wired to nothing would pass every test above.
test_sessionstart_hook_is_registered() {
  local settings
  settings="$ROOT/.claude/settings.json"
  assert_present "$settings" "hook: tracked .claude/settings.json must exist"
  assert_grep 'fm-handoff.sh pickup' "$settings" \
    "hook: settings.json must invoke fm-handoff.sh pickup"
  if command -v jq >/dev/null 2>&1; then
    assert_contains \
      "$(jq -r '.hooks.SessionStart[].hooks[].command' "$settings")" \
      'fm-handoff.sh pickup' "hook: pickup must be registered under SessionStart"
    # No matcher on purpose: a handoff must survive a reboot or crash, not just
    # a deliberate /clear. See docs/handoff.md.
    assert_contains "$(jq -r '.hooks.SessionStart[] | has("matcher") | tostring' "$settings")" \
      'false' "hook: SessionStart pickup must not be narrowed to one source"
  fi
  pass "the SessionStart pickup hook is registered in tracked settings.json"
}

# The two invariants in the skill most likely to erode silently: that firstmate
# never claims to run /clear itself, and that /handoff does not re-roll /stow's
# durable-knowledge sweep.
test_skill_contract() {
  local skill
  skill="$ROOT/.agents/skills/handoff/SKILL.md"
  assert_present "$skill" "skill: /handoff must exist as a captain-invocable skill"
  assert_grep 'user-invocable: true' "$skill" "skill: /handoff must be captain-invocable"
  assert_grep 'It is a Claude Code CLI built-in handled by the harness' "$skill" \
    "skill: must state that /clear is not the agent's to run"
  assert_grep 'Never claim to have cleared the context' "$skill" \
    "skill: must forbid pretending the reset happened"
  assert_grep 'bin/fm-handoff.sh arm' "$skill" "skill: must arm the handoff so pickup is automatic"
  assert_grep 'so every durable finding is routed to its real home' "$skill" \
    "skill: must delegate the durable half to /stow"
  pass "the /handoff skill keeps its /clear and /stow-delegation contract"
}

test_skill_contract
test_path_allocates_dated_name_without_collision
test_arm_refuses_non_handoff_targets
test_pickup_is_silent_without_a_handoff
test_pickup_announces_the_exact_armed_handoff
test_consumed_handoff_does_not_re_announce
test_consume_refuses_the_wrong_handoff
test_stale_marker_self_heals
test_status_reports_pending_state
test_sessionstart_hook_is_registered
