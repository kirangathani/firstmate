#!/usr/bin/env bash
# Behavior tests for the fleet pipeline renderer.
#
# The renderer reads JSON on stdin and shells out to nothing, so a recorded
# snapshot with a fixed --tick and fixed dimensions yields a byte-identical
# frame. These assertions are over rendered output the renderer cannot
# negotiate with, which is what makes them a boundary rather than bookkeeping.
#
# The status list in the exhaustiveness case is every value observed across the
# live fleet on 2026-08-08 (no-mistakes v1.37.0):
#   jq -r '[.agents[].steps[].status] | unique | join(" ")'
#   -> awaiting_approval completed failed fix_review fixing pending running skipped
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TUI="$ROOT/bin/fm-flow-tui.mjs"
TMP_ROOT=$(fm_test_tmproot fm-flow-tui)
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

node --check "$TUI" || fail "renderer is not syntactically valid"
pass "renderer passes node --check"

# --- fixture snapshot -------------------------------------------------------

snap() {  # <agents-json>
  jq -n --argjson agents "$1" '{
    schema:"fm-flow-snapshot.v1",
    generated:"2026-08-08T16:00:00Z",
    generated_epoch:1786000000,
    fm_home:"/home/x/firstmate",
    agents:$agents
  }'
}

steps_all() {  # <status>
  jq -n --arg s "$1" '[
    "intent","rebase","review","test","document","lint","push","pr","ci"
  ] | map({step:., status:$s, findings:0, duration_ms:1000})'
}

agent_with() {  # <id> <steps-json> [extra-json]
  local extra=${3:-}
  [ -n "$extra" ] || extra='{}'
  jq -n --arg id "$1" --argjson steps "$2" --argjson extra "$extra" '{
    id:$id, branch:("fm/"+$id), project:"/p/firstmate", worktree:"/wt",
    window:"fm:1", kind:"ship", mode:"no-mistakes",
    endpoint_alive:true, agent_alive:"alive",
    pr:{url:null,number:null},
    collection:{ok:true,reason:"",at:"2026-08-08T16:00:00Z",epoch:1786000000},
    run:{present:true,id:"01K",status:"running",db_updated_epoch:1786000000,db_age_seconds:0},
    steps:$steps, active_steps:[],
    ci:{collection:{ok:false,reason:"skipped"},checks:[],total:0,passed:0,failed:0,pending:0}
  } * $extra'
}

render() {  # <snapshot-json> [extra args]
  local doc=$1; shift
  printf '%s' "$doc" | node "$TUI" --cols 200 --rows 60 --tick 0 "$@"
}

# --- determinism ------------------------------------------------------------
#
# Without this every other assertion here is worthless: a frame that varies
# between identical runs cannot be asserted byte-for-byte.

DOC=$(snap "[$(agent_with alpha "$(steps_all completed)")]")
a=$(render "$DOC")
b=$(render "$DOC")
[ "$a" = "$b" ] || fail "same snapshot and tick produced different frames"
pass "identical input and tick render byte-identical frames"

# --- state-model exhaustiveness ---------------------------------------------
#
# Every status the tool can emit must land on exactly one display state, and an
# unrecognised status must NOT be drawn as pending. Pending reads as "not
# started yet", which is a different claim from "we do not recognise this".

for status in awaiting_approval completed failed fix_review fixing pending running skipped; do
  out=$(render "$(snap "[$(agent_with s1 "$(steps_all "$status")")]")")
  [ -n "$out" ] || fail "status $status rendered nothing"
  case $status in
    running|fixing)
      assert_contains "$out" "running" "status $status did not render as live" ;;
    awaiting_approval|fix_review)
      assert_contains "$out" "parked" "status $status did not render as waiting" ;;
    failed)
      assert_contains "$out" "FAIL" "status failed did not render as failed" ;;
    skipped)
      assert_contains "$out" "skipped" "status skipped was not labelled" ;;
  esac
done
pass "every observed status renders with its own distinct label"

# The design prototype mapped `skipped` to pending, which claims a deliberately
# skipped gate has not started. Guard that specific regression.
out=$(render "$(snap "[$(agent_with s2 "$(steps_all skipped)")]")")
assert_contains "$out" "skipped" "skipped collapsed into another state"
pass "skipped is not folded into pending"

# An invented status must reach the screen as unknown, not as pending.
weird=$(jq -n '[{step:"intent",status:"quantum_flux",findings:0,duration_ms:5}]')
out=$(render "$(snap "[$(agent_with s3 "$weird")]")")
assert_contains "$out" $'\x1b[95m' "unrecognised status not drawn in the unknown colour"
pass "an unrecognised status renders as unknown rather than pending"

# --- a dead worker cannot be animated ---------------------------------------
#
# Nothing updates a dead run's row, so it reads `running` forever. Drawing
# motion there would report progress on a pipeline that stopped days ago.

live=$(render "$(snap "[$(agent_with live1 "$(steps_all running)")]")")
dead=$(render "$(snap "[$(agent_with dead1 "$(steps_all running)" '{"endpoint_alive":false}')]")")
assert_contains "$live" "running" "a live running step lost its label"
assert_contains "$dead" "worker gone" "a dead worker was not marked"
assert_not_contains "$dead" "running" "a dead worker still claimed to be running"
[ "$live" != "$dead" ] || fail "dead and live workers rendered identically"
pass "a run whose worker is gone is not drawn as live"

# --- an unreadable agent is unknown, never pending ---------------------------

broken='{"collection":{"ok":false,"reason":"axi status failed (exit 124)","at":"t","epoch":1},"steps":[]}'
out=$(render "$(snap "[$(agent_with b1 '[]' "$broken")]")")
assert_contains "$out" "unreadable" "an unreadable agent was not flagged"
assert_contains "$out" "axi status failed" "the failure reason was not surfaced"
pass "a failed collection renders as unreadable with its reason"

# --- CI that was never read is not drawn as not-started ---------------------

withpr='{"pr":{"url":"https://github.com/o/r/pull/7","number":7}}'
out=$(render "$(snap "[$(agent_with c1 "$(steps_all completed)" "$withpr")]")")
assert_contains "$out" "not read" "uncollected CI on a PR was not marked unread"
pass "CI that was not collected is distinguished from CI that has not started"

# A PR whose checks are all green parks IN the CI box asking for the captain,
# because the pre-merge gate does not run until a merge is attempted.
green='{"pr":{"url":"https://github.com/o/r/pull/7","number":7},
        "ci":{"collection":{"ok":true,"reason":""},"checks":[],"total":9,"passed":9,"failed":0,"pending":0}}'
out=$(render "$(snap "[$(agent_with c2 "$(steps_all completed)" "$green")]")")
assert_contains "$out" "your word" "all-green CI did not wait on the captain"
pass "all checks green waits for the captain rather than advancing"

# --- staleness is stated, not implied ---------------------------------------

out=$(render "$(snap "[$(agent_with d1 "$(steps_all completed)")]")")
assert_contains "$out" "updated" "the frame does not state its data age"
pass "the frame always states how old its data is"

# --- degenerate input -------------------------------------------------------

out=$(render "$(snap '[]')")
assert_contains "$out" "no agents in flight" "an empty fleet rendered nothing"
pass "an empty fleet says so"

out=$(printf 'not json' | node "$TUI" 2>&1); rc=$?
expect_code 1 $rc "invalid JSON must exit 1"
assert_contains "$out" "not valid JSON" "no explanation for invalid input"

out=$(printf '{"schema":"something.else"}' | node "$TUI" 2>&1); rc=$?
expect_code 1 $rc "wrong schema must exit 1"
assert_contains "$out" "fm-flow-snapshot.v1" "the expected schema was not named"
pass "refuses input that is not a snapshot it understands"

# --- every tracked .mjs stays syntactically valid ---------------------------
#
# bin/fm-lint.sh covers bin/*.sh, bin/backends/*.sh and tests/*.sh only, so no
# .mjs file has a lint owner. This is the cheap mechanical floor for them.

for f in "$ROOT"/bin/*.mjs; do
  [ -e "$f" ] || continue
  node --check "$f" || fail "node --check failed for $f"
done
pass "every tracked bin/*.mjs passes node --check"
