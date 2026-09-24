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
# How many cells the row has, read from the renderer's own layout rather than
# written down here: a cell added to STEPS changes what a narrowed frame must
# say it is showing, and a number copied into this file would go on asserting
# the old row.
# Stdin is /dev/null on both probes below, and that is load-bearing rather than
# tidiness. The renderer decides it was invoked directly by comparing
# import.meta.url with process.argv[1], and under `node -e <script> <path>` the
# path IS argv[1], so importing it here runs its main() - which waits on stdin
# for a snapshot. With stdin an open pipe (a CI runner, a background shell) that
# wait never ends and the whole suite hangs on line one with no output at all.
NCELLS=$(node --input-type=module -e \
  'const m = await import(process.argv[1]); process.stdout.write(String(m.CELL_WIDTHS.length))' \
  "$TUI" 2>/dev/null </dev/null)
# Which box the push+PR stage is, counting from the left. The connector label
# below is read as the field just after it, so this comes from the renderer's
# own step list rather than from a position that a step inserted anywhere to its
# left or right would quietly move.
PRBOX=$(node --input-type=module -e \
  'const m = await import(process.argv[1]); process.stdout.write(String(m.STEPS.findIndex((s) => s.key === "pr") + 1))' \
  "$TUI" 2>/dev/null </dev/null)
TMP_ROOT=$(fm_test_tmproot fm-flow-tui)
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

node --check "$TUI" || fail "renderer is not syntactically valid"
pass "renderer passes node --check"

# --- fixture snapshot -------------------------------------------------------

snap() {  # <agents-json>
  jq -n --argjson agents "$1" '{
    schema:"fm-flow-snapshot.v2",
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

# A CI rollup result in the shape bin/fm-flow-snapshot.sh emits, with a PR to
# hang it on. Every class is named so a case can never accidentally leave one
# undefined and assert against a default.
#
# `pr_state` is the PR's OWN lifecycle, which the collector reads in the same
# call as the checks, and it defaults to the open PR every case below describes:
# a check tally is only a decision for the captain while the PR is still open,
# and the merged and closed cases are asserted in their own block further down.
ci_result() {  # <total> <passed> <failed> <pending> <skipped> <excused> [<pr-state>]
  jq -n --argjson t "$1" --argjson p "$2" --argjson f "$3" \
        --argjson w "$4" --argjson s "$5" --argjson x "$6" \
        --arg state "${7:-OPEN}" '{
    pr:{url:"https://github.com/kirangathani/firstmate/pull/51",number:51},
    ci:{collection:{ok:true,reason:""},checks:[],
        total:$t,passed:$p,failed:$f,pending:$w,skipped:$s,excused:$x,
        pr_state:$state,
        excused_authority:(if $x > 0
          then ["firstmate is registered as a direct-PR project, whose PRs are raised without the pipeline by design"]
          else [] end)}
  }'
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

# A PR whose checks are all green, and which GitHub still reports OPEN, parks on
# the pre-merge box asking for the captain, because that gate does not run until
# a merge is attempted. Both halves are needed: green checks on a PR that has
# already landed are not a decision, and the merged case is asserted below.
green='{"pr":{"url":"https://github.com/o/r/pull/7","number":7},
        "ci":{"collection":{"ok":true,"reason":""},"checks":[],"total":9,"passed":9,"failed":0,"pending":0,
              "pr_state":"OPEN"}}'
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
assert_contains "$out" "fm-flow-snapshot.v2" "the expected schema was not named"
# v1 defined `agents` as the live SHIP tasks only, so a v1 document fed to this
# renderer would put pipeline boxes over workers that have none. The refusal is
# what makes the two ship together or not at all.
out=$(printf '{"schema":"fm-flow-snapshot.v1","agents":[]}' | node "$TUI" 2>&1); rc=$?
expect_code 1 $rc "a v1 document must be refused, not rendered"
pass "refuses input that is not a snapshot it understands"

# --- the frame fits the terminal it is drawn on -----------------------------
#
# The shipped renderer drew all 143 columns of its stages whatever --cols
# said. On the captain's terminal the tail of every row wrapped onto the row
# below, so the right-hand column arrived as fragments (a bare `+-----`, a bare
# `GIT`), and the wrapped rows desynchronised the in-place repaint. Both the
# clipped column and the orphaned row of durations came from that one fact.
#
# The assertion is therefore the invariant, not a golden frame: no line may be
# wider than --cols and no frame may be taller than --rows, at any size.

FLEET13=$(jq -n '[range(0;13) | {
  id:("task-"+(tostring)), branch:("fm/task-"+(tostring)),
  project:"/p/firstmate", worktree:"/wt", window:"fm:1",
  kind:"ship", mode:"no-mistakes", endpoint_alive:true,
  pr:{url:"https://github.com/o/r/pull/1",number:1},
  collection:{ok:true,reason:"",at:"t",epoch:1786000000},
  run:{present:true,id:"01K",status:"running",db_updated_epoch:1786000000,db_age_seconds:0},
  steps:(["intent","rebase","review","test","document","lint","push","pr","ci"]
         | map({step:., status:"completed", findings:0, duration_ms:4400000})),
  active_steps:[],
  ci:{collection:{ok:true,reason:""},checks:[],total:11,passed:11,failed:0,pending:0}
}]')
BIG=$(snap "$FLEET13")

for cols in 40 60 80 100 120 130 145 200; do
  for rows in 8 10 14 24 45; do
    frame=$(printf '%s' "$BIG" | node "$TUI" --cols "$cols" --rows "$rows" --tick 0)
    printf '%s\n' "$frame" |
      sed 's/\x1b\[[0-9;]*m//g' |
      awk -v c="$cols" -v r="$rows" '
        { if (length($0) > c) wide++ }
        END { if (wide > 0) printf "%d line(s) wider than %d cols\n", wide, c
              if (NR > r) printf "%d lines in a %d row frame\n", NR, r }
      ' > "$TMP_ROOT/fit.$cols.$rows"
    [ -s "$TMP_ROOT/fit.$cols.$rows" ] &&
      fail "frame at ${cols}x${rows}: $(cat "$TMP_ROOT/fit.$cols.$rows")"
  done
done
pass "no frame is ever wider or taller than the terminal it renders for"

# Fitting must not be achieved by cutting a box in half: whatever the width, a
# drawn cell is drawn whole. Every stage box is 11 columns of `+---------+` or
# `┌─────────┐`, so a run of box border that is not one of the known cell
# widths means a cell was truncated.
narrow=$(printf '%s' "$BIG" | node "$TUI" --cols 80 --rows 24 --tick 0 | sed 's/\x1b\[[0-9;]*m//g')
bad=$(printf '%s\n' "$narrow" | grep -oE '[┌└+][─-]+[┐┘+]' | awk '{ n=length($0); if (n != 11 && n != 15) print n }' | head -1)
[ -z "$bad" ] || fail "a stage box was cut to $bad columns at --cols 80"
pass "every stage box drawn at 80 columns is drawn whole"

# When a stage cannot fit it is dropped from the window, and the header says so
# rather than letting the captain believe they are seeing every one.
assert_contains "$narrow" "stages 1-" "a narrowed view did not state which stages it is showing"
assert_contains "$narrow" "of $NCELLS" "a narrowed view did not state how many stages exist"
wide=$(printf '%s' "$BIG" | node "$TUI" --cols 200 --rows 24 --tick 0 | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$wide" "pre-merge" "the last stage is missing at a width that fits every stage"
assert_not_contains "$wide" "of $NCELLS" "a full-width view claimed to be showing a subset"
pass "a narrowed view names its stage window and a full one does not"

# --- the visible window and the rows on screen agree ------------------------
#
# With 13 agents and 3 rows of space the shipped renderer emitted more lines
# than the terminal had. The terminal scrolled, every absolute cursor address
# in the repaint then pointed one row too high, and the top agent's row of
# durations survived under the header with no boxes above it. Nothing may leave
# render() that the frame has no room for.

for rows in 8 9 10 15 16 21 22 28; do
  lines=$(printf '%s' "$BIG" | node "$TUI" --cols 130 --rows "$rows" --tick 0 | wc -l)
  [ "$lines" -le "$rows" ] || fail "a $rows row frame emitted $lines lines"
done
pass "a fleet longer than the window never emits more lines than the window has"

# The durations belong to a specific agent's boxes. Counting them proves the
# agent rows and the timing rows agree: three visible agents means exactly
# three rows of durations, never a fourth left over from a scrolled-out row.
three=$(printf '%s' "$BIG" | node "$TUI" --cols 130 --rows 24 --tick 0 | sed 's/\x1b\[[0-9;]*m//g')
heads=$(printf '%s\n' "$three" | grep -c 'Agent [0-9]')
timers=$(printf '%s\n' "$three" | grep -cE '^ +1h13m ')
[ "$heads" = "$timers" ] ||
  fail "$heads agent rows but $timers timing rows: a timing row outlived its agent"
pass "every timing row on screen belongs to an agent row on screen"

# --- non-interactive --watch is a legitimate use, not a crash ---------------
#
# The snapshot arrives on stdin, so keys are read from /dev/tty instead. A cron
# run, a CI job or a redirected session has no /dev/tty to open, and must still
# get its frame and exit rather than crashing or spinning two timers forever
# with nobody there to press q.

out=$(setsid node "$TUI" --watch --cols 130 --rows 24 --tick 0 <<<"$BIG" 2>"$TMP_ROOT/watch.err"); rc=$?
expect_code 0 $rc "a --watch run with no controlling terminal must exit 0"
assert_contains "$out" "fleet pipeline" "the non-interactive fallback emitted no frame"
assert_contains "$(cat "$TMP_ROOT/watch.err")" "one frame" "the fallback did not say why it is not watching"
printf '%s' "$out" | grep -q $'\x1b\[?1049h' &&
  fail "the non-interactive fallback entered the alternate screen"
lines=$(printf '%s\n' "$out" | wc -l)
[ "$lines" -le 24 ] || fail "the non-interactive fallback emitted $lines lines for a 24 row frame"
pass "--watch with no controlling terminal draws one frame and exits 0"

# --watch without a refresh command cannot pretend to be live.
assert_contains "$out" "static snapshot" "a watch with no refresh source did not admit it is static"
pass "a watch with no data source says the frame is static"

# --- the flags that shell out are opt-in and watch-only ---------------------

out=$(node "$TUI" --refresh-cmd 'echo hi' <<<"$BIG" 2>&1); rc=$?
expect_code 2 $rc "--refresh-cmd outside --watch must be a usage error"
assert_contains "$out" "--watch" "the usage error did not name the flag it needs"
out=$(node "$TUI" --open-cmd 'true' <<<"$BIG" 2>&1); rc=$?
expect_code 2 $rc "--open-cmd outside --watch must be a usage error"
pass "the two shell-out flags are refused outside watch mode"

# --- no cell is cut without saying so ---------------------------------------
#
# The captain's pre-merge summary read `11/11 - your wo`: cut mid-word at the
# cell's right edge, with no ellipsis and no wrap. A value shortened in silence
# is unreadable AND indistinguishable from one that is really that short.
#
# The assertion is over EVERY variable-length cell, not the one instance that
# was reported: a timer that does not fit must end in the ellipsis, and the
# phrase that produced the report must now fit whole.

green11='{"pr":{"url":"https://github.com/o/r/pull/7","number":7},
          "ci":{"collection":{"ok":true,"reason":""},"checks":[],"total":11,"passed":11,"failed":0,"pending":0,
                "pr_state":"OPEN"}}'
out=$(render "$(snap "[$(agent_with t1 "$(steps_all completed)" "$green11")]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "11/11 passed" "the all-green summary still does not fit its cell"
assert_not_contains "$out" "passe…" "the all-green summary is being shortened when it fits"
# The captain's word is asked for on the pre-merge box, the gate that actually
# waits for it, and it fits that nine-wide box whole too.
assert_contains "$out" "your word" "an all-green PR did not ask for the captain's word on pre-merge"
assert_not_contains "$out" "your wo…" "the pre-merge summary is being shortened when it fits"
pass "the CI verdict and the pre-merge summary each fit their cell whole at real fleet check counts"

# Every variable-length value any cell can hold, swept across the widths that
# produce them. Whatever reaches the screen is either the whole value or a
# value that ends in the ellipsis; a bare prefix is neither.
sweep() {  # <extra-json> <needle-prefix>
  local out
  out=$(render "$(snap "[$(agent_with sw "$(steps_all completed)" "$1")]")" | sed 's/\x1b\[[0-9;]*m//g')
  printf '%s\n' "$out" | grep -oE "$2[^ ]*" | head -1
}
for spec in \
  '11/11:{"pr":{"url":"u/7","number":7},"ci":{"collection":{"ok":true},"checks":[],"total":11,"passed":11,"failed":0,"pending":0}}' \
  '120/120:{"pr":{"url":"u/7","number":7},"ci":{"collection":{"ok":true},"checks":[],"total":120,"passed":120,"failed":0,"pending":0}}' \
  '9/13:{"pr":{"url":"u/7","number":7},"ci":{"collection":{"ok":true},"checks":[],"total":13,"passed":9,"failed":4,"pending":0}}' \
  '4/13:{"pr":{"url":"u/7","number":7},"ci":{"collection":{"ok":true},"checks":[],"total":13,"passed":4,"failed":0,"pending":9}}' \
  '1234/1234:{"pr":{"url":"u/7","number":7},"ci":{"collection":{"ok":true},"checks":[],"total":1234,"passed":1234,"failed":0,"pending":0}}'
do
  needle=${spec%%:*}
  extra=${spec#*:}
  got=$(sweep "$extra" "$needle")
  [ -n "$got" ] || fail "no cell rendered for $needle"
  case $got in
    *…) ;;                       # deliberately shortened, and it says so
    *[a-z]) ;;                   # ends on a word, so nothing was cut
    *[0-9]) ;;                   # a bare count, complete in itself
    *) fail "cell '$got' ends mid-value with no ellipsis" ;;
  esac
done
pass "every variable-length cell either fits or ends in an ellipsis"

# A long free-text value on a line, rather than in a cell, takes the same rule.
long='{"id":"a-task-id-far-longer-than-any-terminal-column-count-could-hold"}'
out=$(render "$(snap "[$(agent_with x1 "$(steps_all completed)" "$long")]")" --cols 44 | sed 's/\x1b\[[0-9;]*m//g')
printf '%s\n' "$out" | grep -q '…' || fail "an over-wide line was cut with no ellipsis"
pass "a line too wide for the terminal ends in an ellipsis rather than mid-word"

# --- the window moves only when the selector would leave it ------------------
#
# The captain's rule: up and down move the SELECTOR between agent rows, and the
# window moves only when the selector is already on the top row and goes up, or
# already on the bottom row and goes down. The viewer passed no top at all, so
# every frame recomputed one from `sel` against a default of 0 - which pins the
# selector to the bottom row and drags the window along on the way back up.

cat >"$TMP_ROOT/scroll.mjs" <<'JS'
const { scrollWindow, BLOCK, COMPACT_BLOCK } = await import(process.argv[2]);
let bad = 0;
const eq = (got, want, what) => {
  if (got !== want) { console.error(`${what}: got ${got}, want ${want}`); bad++; }
};
// 6 agents, all pipeline blocks, with room for exactly 2. Walk down to the end
// and back up, one key at a time, carrying `top` exactly as the viewer does.
const N = 6;
const H = Array(N).fill(BLOCK);
const ROOM = 2 * BLOCK;
let top = 0;
const step = (sel, wantTop, what) => {
  const w = scrollWindow(H, ROOM, top, sel);
  top = w.top;
  eq(top, wantTop, what);
};
step(0, 0, "start");
step(1, 0, "down to the bottom row: window still");
step(2, 1, "down past the bottom row: window scrolls one");
step(3, 2, "down again: window scrolls one");
step(2, 2, "up FROM the bottom row: window must NOT move");
step(1, 1, "up from the top row: window scrolls one");
step(0, 0, "up from the top row again: window scrolls one");
// Jumps land the selector at an edge rather than centring it.
eq(scrollWindow(H, ROOM, 0, 5).top, 4, "jump to last");
eq(scrollWindow(H, ROOM, 4, 0).top, 0, "jump to first");
// A shrinking fleet must not leave the window pointing past the end.
eq(scrollWindow(H.slice(0, 3), ROOM, 4, 1).top, 1, "fleet shrank under the window");
// More room than agents: there is nowhere to scroll to.
eq(scrollWindow(H.slice(0, 3), 9 * BLOCK, 0, 2).top, 0, "window taller than the fleet");

// Blocks are two heights now, so the COUNT depends on which block is first.
// Dividing the room by one constant would answer for a frame not being drawn.
const MIX = [BLOCK, COMPACT_BLOCK, COMPACT_BLOCK, BLOCK];
eq(scrollWindow(MIX, BLOCK + COMPACT_BLOCK + COMPACT_BLOCK, 0, 0).count, 3,
   "a pipeline block plus two compact ones fit where two pipeline blocks would not");
eq(scrollWindow(MIX, 2 * BLOCK, 0, 0).count, 3,
   "room for two pipeline blocks holds three when two of them are compact");
// A terminal with room for less than one whole block still gets one whole
// block; render()'s own slice takes the overflow. Half a block is not
// information, and an empty body is the failure this view was reported for.
eq(scrollWindow(H, 1, 0, 0).count, 1, "too short for one block still draws one");
eq(scrollWindow([], 40, 0, 0).count, 0, "an empty fleet has no window");
process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/scroll.mjs" "$TUI" || fail "the scroll rule moved the window off an edge"
pass "the window moves only when the selector would otherwise leave it"

# --- records with no worker are not agents -----------------------------------
#
# The collector holds them back; the renderer must not quietly absorb the
# difference. They are stated, and they are not in the agent count.

omitted='{"omitted":[{"id":"gone-1","kind":"ship","window":"fm:9","reason":"recorded window no longer exists"},
                     {"id":"gone-2","kind":"scout","window":"fm:8","reason":"recorded window no longer exists"}]}'
DOC2=$(snap "[$(agent_with live2 "$(steps_all running)")]" | jq ". * $omitted")
out=$(render "$DOC2" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "1 agents" "the held-back records were counted as agents"
assert_contains "$out" "2 hidden" "the held-back records were not stated"
assert_not_contains "$out" "gone-1" "a held-back ship record was drawn as an agent"
assert_not_contains "$out" "gone-2" "a held-back scout record was drawn as an agent"
pass "held-back records are stated in the header and never drawn or counted"

# --- every live worker is drawn, whatever kind it is -------------------------
#
# The defect this section exists for. The view drew only ship tasks and rendered
# every other live worker as a single dim count, so a captain watching a running
# scout saw `0 agents` and `1 running no pipeline` over `no agents in flight`
# and read the view as faulty. Both directions are asserted here: a live
# non-ship worker IS in the body, and a record with no worker behind it is NOT -
# a fix that only draws the live one puts a finished worker back on screen.

compact() {  # <id> <kind> <state-json>
  jq -n --arg id "$1" --arg kind "$2" --argjson state "$3" '{
    id:$id, branch:("fm/"+$id), project:"/p/firstmate", worktree:"/wt",
    window:("fm:"+$id), kind:$kind, mode:"local-only",
    pipeline:false, state:$state,
    endpoint_alive:true, agent_alive:"alive",
    skips:{local:false,ci:false},
    pr:{url:null,number:null},
    collection:{ok:true,reason:"this worker runs no pipeline",at:"t",epoch:1786000000},
    run:{present:false,id:"",status:"",db_updated_epoch:0,db_age_seconds:null},
    steps:[], active_steps:[],
    ci:{collection:{ok:false,reason:"this worker opens no PR"},checks:[],
        total:0,passed:0,failed:0,pending:0,skipped:0,excused:0}
  }'
}
crew_state() {  # <value> <source> <detail>
  jq -n --arg v "$1" --arg s "$2" --arg d "$3" \
    '{ok:true, value:$v, source:$s, detail:$d, reason:""}'
}

SCOUT=$(compact "nm-ci-duplication-of-effort" scout "$(crew_state working pane 'harness busy')")
MATE=$(compact "infra-sm" secondmate "$(crew_state unknown none 'no current-state source available')")
MIXED=$(snap "[$(agent_with ship1 "$(steps_all running)"),$SCOUT,$MATE]")
out=$(render "$MIXED" | sed 's/\x1b\[[0-9;]*m//g')

assert_contains "$out" "nm-ci-duplication-of-effort" "a live scout was not drawn in the body"
assert_contains "$out" "infra-sm" "a live second mate was not drawn in the body"
assert_contains "$out" "3 agents" "the agent count did not include every drawn live worker"
assert_not_contains "$out" "no agents in flight" "a fleet with live workers claimed to be empty"
assert_not_contains "$out" "running no pipeline" "live workers are drawn now, not counted away"
pass "a live scout and a live second mate are drawn rows, not a count"

# `no agents in flight` may print only when NOTHING is live. A fleet of scouts
# alone is not an empty fleet.
out=$(render "$(snap "[$SCOUT]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "$out" "no agents in flight" "a fleet of pipeline-less workers read as empty"
assert_contains "$out" "1 agents" "a pipeline-less worker was not counted"
out=$(render "$(snap '[]')" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "no agents in flight" "a genuinely empty fleet did not say so"
pass "the empty-fleet line prints only when nothing at all is live"

# The stage-window segment describes cells being DRAWN. A fleet of scouts alone
# draws none, so claiming to be showing a window of them is the same class of
# untruth as the count this whole section exists for.
out=$(printf '%s' "$(snap "[$SCOUT]")" | node "$TUI" --cols 80 --rows 24 --tick 0 |
  sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "$out" "of $NCELLS" "a frame with no stage boxes named a stage window"
out=$(printf '%s' "$MIXED" | node "$TUI" --cols 80 --rows 40 --tick 0 |
  sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "of $NCELLS" "a narrowed frame that does draw stages stopped naming its window"
pass "the stage window is named only when stage boxes are on screen"

# The original concern, kept honest: a worker with no pipeline must not be given
# pipeline boxes. The stage labels and the box borders are the observable.
out=$(render "$(snap "[$SCOUT]")" | sed 's/\x1b\[[0-9;]*m//g')
for label in intent rebase review docs lint "push+PR" "GITHUB CI" pre-merge; do
  assert_not_contains "$out" "$label" "a worker with no pipeline was drawn a '$label' box"
done
printf '%s\n' "$out" | grep -qE '[┌└+][─-]{3,}' &&
  fail "a worker with no pipeline was drawn box borders"
pass "a worker with no pipeline gets no pipeline step boxes"

# What the compact row does carry: its kind, its window, and - for a scout -
# the fixed caption this view now draws instead of the crew's own status line.
#
# The captain's ruling, 2026-09-15: a scout row must never show its raw status
# text - he read "working · captain ruled in-window - no round cap (decision
# review-round-cap answered: none); question routing..." and asked "what is
# this random text". The state word is `scouting`, blue, and the detail is the
# fixed sentence below, whatever the underlying crew-state read actually said -
# the SCOUT fixture above carries a real "working"/"harness busy" read and it
# must not reach the screen.
assert_contains "$out" "scout" "the compact row did not say what kind of worker it is"
assert_contains "$out" "fm:nm-ci-duplication-of-effort" "the compact row did not name the window"
assert_contains "$out" "scouting" "the compact row did not draw a scout's own state word"
assert_contains "$out" "no pipeline view as this is a scout agent" "the compact row did not draw a scout's fixed caption"
assert_not_contains "$out" "harness busy" "a scout row leaked its raw status text onto the screen"
pass "a scout row carries the id, kind, window and the fixed no-pipeline caption"

# The word is drawn in a slot of its own, blue rather than sharing green with
# `working`: a scout is never "working" in the pipeline sense this view
# otherwise means by that word.
colored=$(render "$(snap "[$SCOUT]")")
assert_contains "$colored" $'\x1b[94m''scouting' "scouting was not drawn in its own blue slot"
pass "a scout's state word is drawn in a palette slot of its own, not shared with working"

# A read that failed still says so for a worker that is NOT a scout: only a
# scout's caption is fixed and unconditional, and a secondmate with a genuinely
# unread state must not be told apart from one by squinting.
UNREAD=$(compact "quiet-sm" secondmate '{"ok":false,"value":"","source":"","detail":"","reason":"current-state read failed or timed out"}')
out=$(render "$(snap "[$UNREAD]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "state not read" "an unread state was not stated as unread"
pass "a state that could not be read is stated rather than guessed"

# --- the captain-driving marker: one meaning, drawn on any kind of row -------
#
# `captain_driving` is true exactly when the collector found
# state/<id>.monitor-exempt for that task - the captain has taken the window
# himself. It means the same thing whatever kind of row carries it, so it is
# drawn the same way everywhere: appended to the row's own detail with the
# same words.

DRIVEN_SCOUT=$(printf '%s' "$SCOUT" | jq '.captain_driving = true')
out=$(render "$(snap "[$DRIVEN_SCOUT]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "no pipeline view as this is a scout agent · captain driving directly in the window" \
  "a captain-driven scout did not carry the marker after its fixed caption"
pass "a captain-driven scout carries the marker after its fixed caption"

NOT_DRIVEN=$(render "$(snap "[$SCOUT]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "$NOT_DRIVEN" "captain driving" "a scout with no exemption record was drawn as captain-driven"
pass "a scout with no exemption record carries no captain-driving marker"

DRIVEN_MATE=$(printf '%s' "$MATE" | jq '.captain_driving = true')
out=$(render "$(snap "[$DRIVEN_MATE]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "captain driving directly in the window" \
  "a captain-driven second mate did not carry the marker despite its otherwise-empty idle detail"
pass "the marker reaches an idle row even when its ordinary detail is empty"

DRIVEN_SHIP=$(agent_with driven1 "$(steps_all running)" '{"captain_driving":true}')
out=$(render "$(snap "[$DRIVEN_SHIP]")" | sed 's/\x1b\[[0-9;]*m//g')
head=$(printf '%s' "$out" | grep -F 'Agent 1  driven1')
assert_contains "$head" "captain driving directly in the window" \
  "a captain-driven ship row did not carry the marker on its own head"
pass "the same marker reaches a ship row's head when the captain is driving it"

# --- a quiet second mate is healthy, and is not painted as a fault -----------
#
# AGENTS.md section 8: a second mate's idle endpoint is healthy. bin/fm-crew-state.sh
# encodes the same rule by skipping the pane busy-check for kind=secondmate, so a
# quiet one reads `unknown` BY CONSTRUCTION. `unknown` is magenta everywhere else
# in this view, which is right where it means nobody could find out and wrong
# here where it means there is nothing to report.

out=$(render "$(snap "[$MATE]")")
plain=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$plain" "idle" "a quiet second mate was not drawn as idle"
assert_not_contains "$plain" "unknown" "a quiet second mate was drawn as an unknown state"
assert_not_contains "$plain" "no current-state source available" \
  "a quiet second mate carried the reason for an alarm that is not there"
# The colour is the assertion, not the word: magenta and yellow are this view's
# remaining alarm slots and neither may appear on a healthy idle row. The
# failure slot is NOT listed, and cannot be: the captain's 2026-09-24 ruling
# moved failure onto the same pink a kind label, a scouting word and the run
# counter already wear, so its presence on a row says nothing either way.
for alarm in $'\x1b[95m' $'\x1b[93m'; do
  case $out in
    *"$alarm"*) fail "a quiet second mate's row used an alarm colour" ;;
  esac
done
assert_contains "$out" $'\x1b[2m''idle' "the idle state was not drawn in the neutral slot"
pass "an idling second mate renders neutrally, never as a fault"

# Its OTHER states are real and keep their own colour: only `unknown` is the
# by-construction one, and softening the rest would hide a second mate that is
# genuinely stuck.
BLOCKED_MATE=$(compact "infra-sm" secondmate "$(crew_state blocked status-log 'blocked: needs a credential')")
out=$(render "$(snap "[$BLOCKED_MATE]")")
assert_contains "$out" $'\x1b[93m''blocked' "a blocked second mate was softened into the idle slot"
pass "a second mate that reports a real state keeps that state's own colour"

# --- a mixed fleet still fits the terminal it is drawn on --------------------
#
# Two block heights means the row budget is no longer one constant times a
# count. An over-tall frame scrolls the terminal and desynchronises every
# absolute cursor address in the repaint, which is the defect the single-height
# sweep above was written for; it has to hold across the mix too.

MIXFLEET=$(jq -n --argjson ship "$(agent_with ship-a "$(steps_all completed)")" \
                 --argjson scout "$SCOUT" --argjson mate "$MATE" \
  '[$ship,$ship,$scout,$mate,$ship,$scout,$mate,$ship]')
for cols in 40 60 80 100 130 200; do
  for rows in 6 8 10 14 24 45; do
    printf '%s' "$(snap "$MIXFLEET")" | node "$TUI" --cols "$cols" --rows "$rows" --tick 0 |
      sed 's/\x1b\[[0-9;]*m//g' |
      awk -v c="$cols" -v r="$rows" '
        { if (length($0) > c) wide++ }
        END { if (wide > 0) printf "%d line(s) wider than %d cols\n", wide, c
              if (NR > r) printf "%d lines in a %d row frame\n", NR, r }
      ' > "$TMP_ROOT/mixfit.$cols.$rows"
    [ -s "$TMP_ROOT/mixfit.$cols.$rows" ] &&
      fail "mixed frame at ${cols}x${rows}: $(cat "$TMP_ROOT/mixfit.$cols.$rows")"
  done
done
pass "a fleet of both block heights never overflows the terminal in either direction"

# --- what enter does is stated on the selected row, for the cell it is on -----
#
# Stepping right onto GITHUB CI used to leave a highlighted cell and nothing
# saying what enter would do to it. The row says so on every frame - and since
# 2026-09-24 enter no longer does one thing, so the sentence has to be true for
# the cell the cursor is actually on rather than for the row in general.

DOC3=$(snap "[$(agent_with e1 "$(steps_all completed)")]")
out=$(render "$DOC3" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "enter: open this worker's window" "the selected row does not say what enter does"

# Every cell index comes from the renderer's own PR_CELLS rather than being
# written down: a stage inserted anywhere would move them, and a number copied
# out of one frame would go on asserting the old row.
cat >"$TMP_ROOT/hint.mjs" <<'JS'
const { render, PR_CELLS, CELL_WIDTHS } = await import(process.argv[2]);
const snap = JSON.parse(process.argv[3]);
const withPR = JSON.parse(process.argv[3]);
withPR.agents = withPR.agents.map((a) => ({
  ...a, pr: { url: "https://github.com/kirangathani/firstmate/pull/51", number: 51 },
}));
const plain = (f) => f.join("\n").replace(/\x1b\[[0-9;]*m/g, "");
let bad = 0;
const say = (m) => { console.error(m); bad++; };
const draw = (doc, o) => plain(render(doc, { rows: 60, cols: 200, sel: 0, ...o }));

const others = [-1, ...CELL_WIDTHS.map((_, i) => i).filter((i) => !PR_CELLS.has(i))];
for (const cell of others) {
  for (const [doc, label] of [[snap, "no PR"], [withPR, "with a PR"]]) {
    const out = draw(doc, { cell });
    if (!out.includes("enter: open this worker's window")) {
      say(`cell ${cell}, ${label}: the row does not say enter opens the worker`);
    }
  }
}
// The two cells that are about the PR say the other thing, and only for a row
// that HAS one.
for (const cell of PR_CELLS) {
  const has = draw(withPR, { cell });
  if (!has.includes("enter: open this PR in your browser")) {
    say(`cell ${cell}: a row with a PR does not offer to open it`);
  }
  if (has.includes("open this worker's window")) {
    say(`cell ${cell}: a PR cell still advertises the window`);
  }
  // A row with no PR says so rather than advertising an action that would do
  // nothing when pressed.
  const none = draw(snap, { cell });
  if (!none.includes("enter: no PR recorded for this task yet")) {
    say(`cell ${cell}: a row with no PR does not say so`);
  }
}

// Both sentences belong to the caller, for the same reason: only it knows what
// its own commands do to this terminal.
const custom = draw(withPR, {
  cell: 0, openHint: "enter: attach (detach to come back)",
});
if (!custom.includes("detach to come back")) say("--open-hint did not reach the row");
if (custom.includes("open this worker's window")) say("--open-hint did not replace the default");
const customPR = draw(withPR, {
  cell: [...PR_CELLS][0], openPrHint: "enter: open PR 51 on github.com",
});
if (!customPR.includes("open PR 51 on github.com")) say("--open-pr-hint did not reach the row");
if (customPR.includes("open this PR in your browser")) say("--open-pr-hint did not replace the default");

// A worker with no pipeline draws none of these cells, so the stage cursor
// says nothing about its row: enter there keeps meaning what it always did,
// whatever index the cursor is parked at.
const flat = JSON.parse(process.argv[3]);
flat.agents = flat.agents.map((a) => ({
  ...a, pipeline: false, kind: "scout",
  pr: { url: "https://github.com/kirangathani/firstmate/pull/51", number: 51 },
}));
for (const cell of PR_CELLS) {
  const out = draw(flat, { cell });
  if (!out.includes("enter: open this worker's window")) {
    say(`cell ${cell}: a row with no pipeline took a stage cell's meaning`);
  }
}
process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/hint.mjs" "$TUI" "$DOC3" ||
  fail "the enter hint is wrong for some cell, or a caller's hint did not reach it"
pass "the selected agent states what enter does for the cell the cursor is on, and a row with no PR says so instead of offering one"

# --- which cells belong to the PR, and what enter does there -----------------
#
# The captain, 2026-09-24: "We can make it so that the push+PR box can allow me
# to press enter on it to open the browser on the link to the active PR?". The
# GITHUB CI box beside it is about the same PR, so it carries the same action.
cat >"$TMP_ROOT/prcells.mjs" <<'JS'
const { PR_CELLS, opensPR, STEPS, CELL_WIDTHS } = await import(process.argv[2]);
let bad = 0;
const say = (m) => { console.error(m); bad++; };
// Exactly two cells, and they are the push+PR box and the one to its right.
const pr = STEPS.findIndex((s) => s.key === "pr");
if (PR_CELLS.size !== 2) say(`PR_CELLS holds ${PR_CELLS.size} cells`);
if (!PR_CELLS.has(pr)) say("the push+PR cell is not a PR cell");
if (!PR_CELLS.has(STEPS.length)) say("the GITHUB CI cell is not a PR cell");
// pre-merge is NOT one: it is about the merge gate, not the PR link.
if (PR_CELLS.has(CELL_WIDTHS.length - 1)) say("pre-merge was counted as a PR cell");
const ship = { pipeline: true, pr: { url: "https://x/pull/1" } };
const scout = { pipeline: false, pr: { url: "https://x/pull/1" } };
for (const cell of PR_CELLS) {
  if (!opensPR(ship, cell)) say(`opensPR said no on PR cell ${cell}`);
  if (opensPR(scout, cell)) say(`opensPR said yes on a row with no pipeline, cell ${cell}`);
}
if (opensPR(ship, -1)) say("opensPR said yes with the cursor on the head");
if (opensPR(ship, 0)) say("opensPR said yes on the building cell");
process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/prcells.mjs" "$TUI" ||
  fail "the cells enter opens the PR from are not the push+PR and GITHUB CI cells"
pass "enter opens the PR from the push+PR and GITHUB CI cells only, and never from a row with no pipeline"

# The caller owns that sentence end to end: only it knows what its --open-cmd
# does to the captain's terminal and how to get back.
out=$(setsid node "$TUI" --watch --cols 200 --rows 60 --tick 0 \
  --open-hint 'enter: attach (detach to come back)' <<<"$DOC3" 2>/dev/null |
  sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "detach to come back" "--open-hint did not survive the flag path"
pass "--open-hint replaces the default sentence about what enter does"

# The PR half of it travels the same route, and both new flags are refused
# outside watch mode exactly as the two they join.
node "$TUI" --open-pr-cmd true --cols 200 --rows 60 <<<"$DOC3" >/dev/null 2>&1
expect_code 2 $? "--open-pr-cmd outside watch mode"
node "$TUI" --open-pr-hint x --cols 200 --rows 60 <<<"$DOC3" >/dev/null 2>&1
expect_code 2 $? "--open-pr-hint outside watch mode"
pass "the PR-open flags are refused outside watch mode, like every other shell-out flag"

# --- keys arrive in chunks, and in two encodings -----------------------------
#
# Raw mode delivers whatever bytes are available: holding an arrow down sends
# "\x1b[B\x1b[B" in ONE chunk, and a terminal in application-cursor mode sends
# "\x1bOB" for the same key. The shipped version compared the whole chunk
# against one literal, so both were dropped.

cat >"$TMP_ROOT/keys.mjs" <<'JS'
const { keysOf } = await import(process.argv[2]);
const eq = (got, want, what) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    console.error(what + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want));
    process.exit(1);
  }
};
eq(keysOf("\x1b[B\x1b[B"), ["\x1b[B", "\x1b[B"], "two arrows in one chunk");
eq(keysOf("\x1bOB"), ["\x1bOB"], "application-cursor arrow");
eq(keysOf("jq"), ["j", "q"], "two plain keys");
eq(keysOf("\x1b[Aq"), ["\x1b[A", "q"], "an arrow followed by a plain key");
eq(keysOf("\r"), ["\r"], "enter");
JS
node "$TMP_ROOT/keys.mjs" "$TUI" || fail "key decoding dropped a key"
pass "a chunk holding several keys, in either arrow encoding, decodes to all of them"

# --- the excused attestation check is not a failure, and not a pass ----------
#
# The captain's own screen, 2026-08-09: both live agents boxed GITHUB CI in red
# with `10/11 FAIL`, on PRs GitHub reported as 10 passed and 1 failed of 11. The
# single red one was `PR must be raised via no-mistakes`, which cannot pass on a
# firstmate PR by construction - the project ships direct-PR, so its PRs are
# opened with `gh pr create` and carry no pipeline attestation - and which
# bin/fm-pr-merge.sh already excuses on exactly that authority. A cell that is
# red however healthy the PR is is a cell nobody reads.
#
# Both directions are asserted, because the fix is worthless if it also swallows
# a real failure.

excused=$(render "$(snap "[$(agent_with ex1 "$(steps_all completed)" "$(ci_result 11 10 0 0 0 1)")]")" |
  sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "$excused" "FAIL" "an excused-only red PR still rendered as a CI failure"
assert_contains "$excused" "10/11 passed" "an excused-only red PR did not read as passed"
assert_contains "$excused" "your word" "an excused-only red PR did not park for the captain"
assert_contains "$excused" "1 excused" "the excused check was not counted in its own category"
pass "a PR whose only red check is the excused one is not drawn as a failure"

genuine=$(render "$(snap "[$(agent_with ex2 "$(steps_all completed)" "$(ci_result 11 9 1 0 0 1)")]")" |
  sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$genuine" "9/11 FAIL" "a genuinely failing check stopped being reported as a failure"
assert_contains "$genuine" "1 fail" "the real failure lost its own count"
assert_contains "$genuine" "1 excused" "the excused check was folded away beside a real failure"
pass "a genuinely failing check is still loud, even beside an excused one"

# An excused check is an authorized RED, not evidence anything ran.
# bin/fm-pr-merge.sh refuses a PR whose only entries were excused exactly like
# one reporting no checks at all, so this cell must not read readier than that.
nothing=$(render "$(snap "[$(agent_with ex3 "$(steps_all completed)" "$(ci_result 1 0 0 0 0 1)")]")" |
  sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$nothing" "nothing ran" "a PR whose only check was excused claimed a result"
assert_not_contains "$nothing" "your word" "a PR with no evidence was offered for merge"
assert_contains "$nothing" "0 ready to merge" "a PR with no evidence was counted ready to merge"
pass "a PR whose only check was excused is not offered as ready"

# --- every check class is named on every render ------------------------------
#
# The captain's standing rule, ruled three times in one session: every class
# appears on every render, zeros included; a green or ready flag only when every
# class is clear; and a class that was never evaluated renders as a dash, never
# as a 0, because "checked, nothing found" and "never checked" are different
# facts. The 15-column timer under the CI box cannot hold five counts, so they
# live on their own line rather than being thinned to fit.

for label in pass fail excused skipped pending; do
  assert_contains "$excused" "$label" "class $label is missing from a rendered row"
done
pass "all five check classes are named on a row that has counts for them"

zeros=$(printf '%s\n' "$excused" | grep -o 'CI 11 checks:.*')
[ "$zeros" = "CI 11 checks:  10 pass  0 fail  1 excused  0 skipped  0 pending" ] ||
  fail "the tally dropped or reordered a class: $zeros"
pass "a class whose count is zero is still printed, as a 0"

# The same row for an agent that has no PR: the labels stay, the counts become
# dashes, and the reason is stated.
noci=$(render "$(snap "[$(agent_with ex4 "$(steps_all pending)")]")" | sed 's/\x1b\[[0-9;]*m//g')
dashes=$(printf '%s\n' "$noci" | grep -o 'CI checks:.*')
[ "$dashes" = "CI checks:  - pass  - fail  - excused  - skipped  - pending  (no PR)" ] ||
  fail "an unevaluated row did not render dashes with its reason: $dashes"
pass "a class that was never evaluated renders as a dash and says why"

# "no PR" is a CLAIM, and it is only made when the row actually knows. A task's
# PR reaches this row two ways - firstmate's own record of it, and the pipeline
# run's own pr: field - so when the pipeline could not be read at all, neither
# has answered and the honest word is that nobody knows.
#
# The captain watched this assert the opposite on 2026-09-16: a task with an
# open upstream PR was drawn "(no PR)" because the collector had been looking
# for its run in the wrong repository and found nothing at all to read it from.
unknown=$(render "$(snap "[$(agent_with ex5 "$(steps_all pending)" \
  '{"collection":{"ok":false,"reason":"axi status failed (exit 1)"}}')]")" |
  sed 's/\x1b\[[0-9;]*m//g')
line=$(printf '%s\n' "$unknown" | grep -o 'CI checks:.*')
[ -n "$line" ] || fail "the unreadable row rendered no CI tally line at all"
assert_not_contains "$line" "(no PR)" \
  "a row that could not read its pipeline still claimed the task has no PR"
assert_contains "$line" "PR unknown" \
  "a row that could not read its pipeline did not say the PR is unknown"
pass "a PR nobody could look for is reported unknown, never as no PR"

# --- a record reality refutes loses -----------------------------------------
#
# `direct-PR` and `local_skip` both say the same thing about the world: no
# validation pipeline runs for this task. A pipeline run the collector actually
# READ for this branch is therefore not a detail beside them, it is that claim
# being false, and the row draws what the run reports.
#
# This is the opposite of inferring a mode from an ABSENT run, which the
# renderer rightly refuses: absence is also what a wedged worker and a pipeline
# that has not started yet look like. A run that was read says something.
#
# The captain watched the record win on 2026-09-16: a task live on its eighth
# run, at the review step, drawn with intent, rebase, review, test, docs and
# lint all `skipped`, because its project ships direct-PR while its instructions
# sent it through the pipeline against another repository.

PIPELINE_STEPS='[{"step":"intent","status":"completed","findings":0,"duration_ms":288},
 {"step":"rebase","status":"completed","findings":0,"duration_ms":4066},
 {"step":"review","status":"fixing","findings":1,"duration_ms":0},
 {"step":"test","status":"pending","findings":0,"duration_ms":0},
 {"step":"document","status":"pending","findings":0,"duration_ms":0},
 {"step":"lint","status":"pending","findings":0,"duration_ms":0},
 {"step":"push","status":"pending","findings":0,"duration_ms":0},
 {"step":"pr","status":"pending","findings":0,"duration_ms":0},
 {"step":"ci","status":"pending","findings":0,"duration_ms":0}]'

# The two exported predicates, asked directly, so the assertion is over the
# decision rather than over whichever line of the frame happens to spell it.
# The agent travels in the environment, not in argv: importing the module runs
# its own argument parsing, and a stray positional is an unknown argument to it.
skip_predicates() {  # <agent-json> -> "<authority>|<legend>"
  FM_TEST_AGENT="$1" node --input-type=module -e '
    const m = await import(process.argv[1]);
    const a = JSON.parse(process.env.FM_TEST_AGENT);
    process.stdout.write((m.skipAuthority(a) || "-") + "|" +
      (m.drawsSkippedStages(a) ? "legend" : "no-legend"));
  ' "$TUI"
}

RAN_AGENT=$(agent_with ex6 "$PIPELINE_STEPS" '{"mode":"direct-PR"}')
got=$(skip_predicates "$RAN_AGENT")
[ "$got" = "-|no-legend" ] ||
  fail "a task whose own run reports stages still claimed a short journey: $got"
frame=$(render "$(snap "[$RAN_AGENT]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "$frame" "by hand" \
  "a PR the pipeline opened was reported as a hand-run delivery"
# `fixing` is a LIVE step, so its box reads `running`. Under the override every
# one of these stages would read `skipped` and no stage would be running at all.
assert_contains "$frame" "running" \
  "the review stage its own run reports as live was not drawn"
pass "stages a real pipeline run reports are drawn, not overridden by a record that denies the run"

# The other direction is untouched: a direct-PR task with no run of its own
# still draws the short journey, because nothing refutes its record. An absent
# run is also what a wedged worker looks like, so it is never read as evidence.
NORUN_AGENT=$(agent_with ex7 '[]' '{"mode":"direct-PR"}')
got=$(skip_predicates "$NORUN_AGENT")
[ "$got" = "direct-PR|legend" ] ||
  fail "a direct-PR task with no run of its own stopped drawing its short journey: $got"
frame=$(render "$(snap "[$NORUN_AGENT]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$frame" "by hand" \
  "a direct-PR task with no run stopped reporting its hand-run delivery"
pass "a direct-PR task with no run of its own still draws the short journey its mode removes"

# --- a captain-authorised skip is drawn as skipped, and said out loud --------
#
# The captain's words: a task dispatched with a skip flag "wouldn't actually run
# through all of those steps", so drawing the full chain leaves him watching
# boxes that were never going to light. The two flags are independent and remove
# DIFFERENT stages, so each is asserted against what it actually removes rather
# than against "everything before merge".
#
# The stage list comes from the renderer's own exported set, so a stage added to
# the pipeline cannot quietly fall out of this assertion.

LOCALSKIP=$(jq -n --argjson ci "$(ci_result 11 10 0 0 0 1)" '$ci * {
  skips:{local:true,ci:false},
  collection:{ok:true,reason:"no pipeline run for this branch",at:"t",epoch:1},
  run:{present:false,id:"",status:"",db_updated_epoch:0,db_age_seconds:null}}')
BOTHSKIP=$(jq -n --argjson ci "$(ci_result 11 5 0 0 5 1)" '$ci * {
  skips:{local:true,ci:true},
  collection:{ok:true,reason:"no pipeline run for this branch",at:"t",epoch:1},
  run:{present:false,id:"",status:"",db_updated_epoch:0,db_age_seconds:null}}')
CISKIP=$(jq -n --argjson ci "$(ci_result 11 5 0 0 5 1)" '$ci * {skips:{local:false,ci:true}}')

cat >"$TMP_ROOT/skips.mjs" <<'JS'
const { render, layout, CELL_WIDTHS, LOCAL_SKIP_STAGES, STEPS, gutterWidth } =
  await import(process.argv[2]);
const base = JSON.parse(process.argv[3]);
const COLS = 200, ROWS = 80;
let bad = 0;
const say = (m) => { console.error(m); bad++; };

// Address the timer row cell by cell using the renderer's OWN layout, so a
// change to a cell width or the arrow gutter moves this assertion with it
// rather than leaving it reading the wrong column.
const lay = layout(COLS, 0);
if (lay.first !== 0 || lay.count !== CELL_WIDTHS.length) {
  say(`the probe width shows only stages ${lay.first + 1}-${lay.first + lay.count}`);
}
const offsets = [];
{
  let x = 2;  // agentBlock indents every box row by two columns
  CELL_WIDTHS.forEach((w, i) => {
    x += i === 0 ? 0 : gutterWidth(i, lay.gap);
    offsets.push(x);
    x += w;
  });
}

// One agent per frame: the row indices stay trivial and a failure names the
// stage rather than a line number. head, top, mid, bot, timer, facts.
const timerCells = (agent) => {
  const frame = render({ ...base, agents: [agent] }, { rows: ROWS, cols: COLS, sel: 0, cell: -1 })
    .map((l) => l.replace(/\x1b\[[0-9;]*m/g, ""));
  const head = frame.findIndex((l) => l.includes(agent.id));
  const row = frame[head + 4] ?? "";
  return CELL_WIDTHS.map((w, i) => row.slice(offsets[i], offsets[i] + w).trim());
};

const withSkips = (skips) => ({
  ...base.agents[0],
  skips,
  // What the collector emits for a local-skip task: no pipeline run exists, so
  // the only step it can state is the worker's own building phase, which is
  // still under way.
  steps: [{ step: "building", status: "running", findings: 0, duration_ms: 0 }],
  active_steps: [{ step: "building", status: "running", active_ms: 60000 }],
  pr: { url: "https://github.com/kirangathani/firstmate/pull/51", number: 51 },
  collection: { ok: true, reason: "no pipeline run for this branch", at: "t", epoch: 1 },
});

// local_skip switches the whole local pipeline off, so every validation stage
// is skipped - but push and PR still happen, by hand, which is why that box is
// NOT skipped and why the CI cell beside it carries real checks.
// `building` is not a pipeline stage and no flag removes it: the worker still
// implements the change by hand, and under local_skip there is never a run to
// end that phase, so it stays running. Drawing it as skipped would say the
// work itself did not happen.
const localCells = timerCells(withSkips({ local: true, ci: false }));
STEPS.forEach((s, i) => {
  const want = s.key === "building"
    ? "running"
    : LOCAL_SKIP_STAGES.has(s.key) ? "skipped" : "by hand";
  if (localCells[i] !== want) {
    say(`local skip: stage ${s.key} reads "${localCells[i]}", want "${want}"`);
  }
});
if (localCells[CELL_WIDTHS.length - 1] === "skipped") {
  say("local skip: the pre-merge gate was drawn as skipped, and no flag can skip it");
}

// ci_skip removes no local stage at all. Reading it as "skip everything before
// merge" would put the same lie back in a new place.
const ciCells = timerCells(withSkips({ local: false, ci: true }));
STEPS.forEach((s, i) => {
  if (ciCells[i] === "skipped" || ciCells[i] === "by hand") {
    say(`ci-only skip: stage ${s.key} was marked "${ciCells[i]}", which that flag does not remove`);
  }
});

// A failed pipeline read does not un-skip a skipped stage. The skip comes from
// the task's own record, and under local_skip there is no pipeline run for that
// read to have failed on, so `unknown` there would be a worse answer than the
// one the record already gives.
const unreadable = withSkips({ local: true, ci: false });
unreadable.collection = { ok: false, reason: "axi status failed (exit 124)", at: "t", epoch: 1 };
const unreadableCells = timerCells(unreadable);
STEPS.filter((s) => LOCAL_SKIP_STAGES.has(s.key)).forEach((s) => {
  const i = STEPS.indexOf(s);
  if (unreadableCells[i] !== "skipped") {
    say(`unreadable + local skip: stage ${s.key} reads "${unreadableCells[i]}", want "skipped"`);
  }
});

process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/skips.mjs" "$TUI" "$(snap "[$(agent_with sk0 '[]' '{}')]")" ||
  fail "a recorded testing skip did not reach the stages it actually removes"
pass "each testing skip marks exactly the stages it removes, and never pre-merge"

localout=$(render "$(snap "[$(agent_with sk1 '[]' "$LOCALSKIP")]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$localout" "captain-authorised skip: local pipeline" \
  "a skip-flagged task did not say its short chain is authorised"
assert_contains "$localout" "skipped" "a local-skip task drew no skipped stage"
assert_contains "$localout" "by hand" "a local-skip task did not show its hand-run push and PR"
bothout=$(render "$(snap "[$(agent_with sk2 '[]' "$BOTHSKIP")]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$bothout" "captain-authorised skip: local pipeline, CI test jobs" \
  "a task carrying both skips named only one of them"
ciout=$(render "$(snap "[$(agent_with sk3 "$(steps_all completed)" "$CISKIP")]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$ciout" "captain-authorised skip: CI test jobs" \
  "a CI-only skip was not disclosed"
assert_not_contains "$ciout" "local pipeline" "a CI-only skip claimed the local pipeline was skipped"
# Which STAGES each flag touches is asserted cell by cell above; this half is
# only about the sentence naming them.
pass "the skip is disclosed in plain words, naming exactly which halves were skipped"

# --- the two states that were on screen with no time ------------------------
#
# A finished step has always shown its duration. The two states the captain
# actually sits and watches - a step that is RUNNING, and one PARKED on the
# findings it produced - said only what they were and never how long it had
# been true, which is the one number that tells him whether to wait or to go
# and look. Each now carries its elapsed on a second line directly under its
# own word, in the same dur() shape a finished step prints, so the three read
# as one column rather than as three different clocks.
#
# The rows are addressed by the renderer's OWN layout arithmetic, so a change
# to a cell width or the arrow gutter moves this assertion with it.

cat >"$TMP_ROOT/elapsed.mjs" <<'JS'
const { render, layout, CELL_WIDTHS, STEPS, dur } = await import(process.argv[2]);
const base = JSON.parse(process.argv[3]);
const COLS = 200, ROWS = 60;
let bad = 0;
const say = (m) => { console.error(m); bad++; };

const lay = layout(COLS, 0);
const offsets = [];
{
  let x = 2;  // agentBlock indents every box row by two columns
  for (const w of CELL_WIDTHS) { offsets.push(x); x += w + lay.gap; }
}

const RUNNING_MS = 179000;   // "2m59s", as the collector parsed it off active_for
const PARKED_MS = 1085436;   // the review step's own duration when its findings landed

const agent = {
  ...base.agents[0],
  steps: STEPS.map((s) => {
    if (s.key === "review") {
      return { step: "review", status: "fix_review", findings: 6, duration_ms: PARKED_MS };
    }
    if (s.key === "test") {
      return { step: "test", status: "running", findings: 0, duration_ms: 0 };
    }
    if (s.key === "intent") {
      return { step: "intent", status: "completed", findings: 0, duration_ms: 22 };
    }
    return { step: s.key, status: "pending", findings: 0, duration_ms: 0 };
  }),
  active_steps: [{
    step: "test", status: "running", active_for: "2m59s", active_ms: RUNNING_MS,
    last_activity: "", agent_pid: "", round: "1",
  }],
};

// head, top, mid, bot, word, time. The word row and the time row are read
// through the same layout arithmetic, so a width change moves both together.
const rowsFor = (a) => {
  const frame = render({ ...base, agents: [a] }, { rows: ROWS, cols: COLS, sel: 0, cell: -1 })
    .map((l) => l.replace(/\x1b\[[0-9;]*m/g, ""));
  const head = frame.findIndex((l) => l.includes(a.id));
  const cellsOf = (row) =>
    CELL_WIDTHS.map((w, i) => (frame[row] ?? "").slice(offsets[i], offsets[i] + w).trim());
  return { words: cellsOf(head + 4), times: cellsOf(head + 5) };
};

const { words, times } = rowsFor(agent);
const at = (key) => STEPS.findIndex((s) => s.key === key);

// The word line is unchanged: the elapsed is added BESIDE what the captain
// already reads, never in place of it.
if (words[at("test")] !== "running") say(`live step lost its word: "${words[at("test")]}"`);
if (words[at("review")] !== "6 find") say(`parked step lost its findings: "${words[at("review")]}"`);

if (times[at("test")] !== dur(RUNNING_MS)) {
  say(`live step shows "${times[at("test")]}" under running, want "${dur(RUNNING_MS)}"`);
}
if (times[at("review")] !== dur(PARKED_MS)) {
  say(`parked step shows "${times[at("review")]}" under its findings, want "${dur(PARKED_MS)}"`);
}

// A finished step states its duration on the first line already, and a step
// that has not started has no elapsed at all. Repeating or inventing one there
// would make the second line mean two different things.
if (times[at("intent")] !== "") say(`a finished step repeated its duration: "${times[at("intent")]}"`);
if (times[at("document")] !== "") say(`a pending step invented an elapsed: "${times[at("document")]}"`);

// A live step whose run states no elapsed says nothing rather than guessing.
const brow = rowsFor({ ...agent, active_steps: [] }).times[at("test")];
if (brow !== "") say(`a live step with no stated elapsed invented one: "${brow}"`);

// The GITHUB CI cell is the pipeline's LONGEST wait, so it counts up exactly
// like the step boxes beside it, off the same active row keyed `ci`.
const CI_MS = 66720000;   // "18h32m", as the collector parsed it off active_for
const CI = CELL_WIDTHS.length - 2;
const ciAgent = (over) => ({
  ...agent,
  pr: { url: "https://github.com/kirangathani/firstmate/pull/51", number: 51 },
  ci: {
    collection: { ok: true, reason: "" }, checks: [],
    total: 11, passed: 3, failed: 0, pending: 8, skipped: 0, excused: 0,
  },
  active_steps: [{
    step: "ci", status: "running", active_for: "18h32m", active_ms: CI_MS,
    last_activity: "", agent_pid: "", round: "starting",
  }],
  ...over,
});

const running = rowsFor(ciAgent({}));
if (running.words[CI] !== "3/11 running") say(`CI lost its word: "${running.words[CI]}"`);
if (running.times[CI] !== dur(CI_MS)) {
  say(`running CI shows "${running.times[CI]}" under its word, want "${dur(CI_MS)}"`);
}

// A CI stage that is NOT running is not counting, and an elapsed under a state
// that is not counting is the same lie the check classes exist to prevent.
const parked = rowsFor(ciAgent({
  ci: {
    collection: { ok: true, reason: "" }, checks: [],
    total: 11, passed: 11, failed: 0, pending: 0, skipped: 0, excused: 0,
  },
}));
if (parked.words[CI] !== "11/11 passed") say(`CI lost its verdict: "${parked.words[CI]}"`);
if (parked.times[CI] !== "") say(`a CI stage that is not running invented an elapsed: "${parked.times[CI]}"`);

// Nor does a cell drawn `unknown` because the fleet no longer believes its
// worker is alive: it looks live, but nothing is counting behind it.
const dead = rowsFor(ciAgent({ endpoint_alive: false })).times[CI];
if (dead !== "") say(`a CI cell whose worker is gone kept counting: "${dead}"`);

process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/elapsed.mjs" "$TUI" "$(snap "[$(agent_with el0 '[]' '{}')]")" ||
  fail "the running and parked states did not carry their elapsed"
pass "a running step and a parked one each state how long they have been so"

# The disclosure shares its line with the tally, and the captain's rule is that
# a count is never dropped to make room. With the sentence in front the pair ran
# 124 columns and a 120-column terminal cut the tally mid-class, so the counts
# come first and the sentence is the half that shortens.
#
# The width swept is derived from the line itself, not from the number that
# happened to expose it: every width from the tally's own length upwards must
# carry the whole tally.
tallyline=$(printf '%s\n' "$bothout" | grep -o 'CI 11 checks:.*pending' | head -1)
[ -n "$tallyline" ] || fail "no tally line to size this from"
# The floor is the tally's own length plus the two-column indent plus the one
# column clip() spends on the ellipsis that marks a cut. Narrower than that and
# the line is visibly shortened like any other over-wide line, on a terminal
# whose stage window is already truncated and says so in the header.
for cols in $(( ${#tallyline} + 3 )) 100 110 120 130 150 200; do
  got=$(render "$(snap "[$(agent_with sk6 '[]' "$BOTHSKIP")]")" --cols "$cols" |
    sed 's/\x1b\[[0-9;]*m//g' | grep -o 'CI 11 checks:[^·]*' | head -1)
  case $got in
    *"0 pending"*) ;;
    *) fail "at $cols columns the tally lost a count: '$got'" ;;
  esac
done
pass "every check count survives at any width the tally itself fits in"

# A skipped stage must not look like one that has simply not been reached.
# `skipped` and `pending` shared the dim slot, so the only difference on screen
# was the four-letter timer word underneath.
# The HEAD line is excluded from both reads, and deliberately: the run counter
# lives there and wears this same slot, so a whole-frame grep would find the
# skipped colour on every row whatever its stages are drawn as, and pass for a
# reason that has nothing to do with the stages this case is about.
without_head() {  # <id>
  grep -v -- "$1"
}
skipcolour=$(render "$(snap "[$(agent_with sk4 '[]' "$LOCALSKIP")]")" |
  without_head sk4 | grep -o $'\x1b\\[94m' | head -1)
[ -n "$skipcolour" ] || fail "a skipped stage is not drawn in its own colour"
pending_only=$(render "$(snap "[$(agent_with sk5 "$(steps_all pending)")]")" |
  without_head sk5)
printf '%s' "$pending_only" | grep -q $'\x1b\[94m' &&
  fail "a stage that has merely not started was drawn in the skipped colour"
pass "a skipped stage is visually distinct from one that has not been reached"

# --- a task with no skip renders exactly as it did before --------------------
#
# The field is inert when off: an agent that records no skip must be
# byte-identical to one whose record predates the field entirely.
WITHOUT=$(snap "[$(agent_with same "$(steps_all completed)")]")
WITHOFF=$(printf '%s' "$WITHOUT" | jq '.agents[0].skips = {local:false,ci:false}')
[ "$(render "$WITHOUT")" = "$(render "$WITHOFF")" ] ||
  fail "recording an off skip changed the frame"
plainoff=$(render "$WITHOFF" | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "$plainoff" "captain-authorised" "an unflagged task claimed an authorised skip"
assert_not_contains "$plainoff" "by hand" "an unflagged task's push and PR was relabelled"
assert_not_contains "$plainoff" "skipped stage" "an unflagged task grew a skipped stage"
pass "a task carrying no testing skip renders exactly as it does without the field"


# --- every tracked .mjs stays syntactically valid ---------------------------
#
# bin/fm-lint.sh covers bin/*.sh, bin/backends/*.sh and tests/*.sh only, so no
# .mjs file has a lint owner. This is the cheap mechanical floor for them.

for f in "$ROOT"/bin/*.mjs; do
  [ -e "$f" ] || continue
  node --check "$f" || fail "node --check failed for $f"
done
pass "every tracked bin/*.mjs passes node --check"

# --- which LLM is doing the work --------------------------------------------
#
# Two facts on one line, and both must be readable at a glance and honest when
# absent. The worker's model is what the task's own record says it was
# dispatched on; the gate's is what the pipeline actually launched its review,
# test, document and fix agents as.
#
# A dash is a fact here, not a placeholder: it says nothing machine-recorded
# answers that axis. AGENTS.md section 9 forbids the alternatives - a blank
# reads as "no label", and a guessed name reads as a measurement.

# The pure mapping, exercised through the module rather than through a frame,
# because every unrecognised id must survive VERBATIM and a frame can only show
# the handful this fleet happens to run.
map_out=$(node --input-type=module -e "
import { modelLabel } from '$TUI';
const cases = [
  ['claude-opus-5', 'high'],
  ['claude-fable-5-1', 'xhigh'],
  ['claude-sonnet-5', 'medium'],
  ['claude-haiku-4-5-20251001', 'low'],
  ['claude-some-model-nobody-has-shipped-yet', 'high'],
  ['claude-opus-5', null],
  [null, 'high'],
  [null, null],
];
for (const [m, e] of cases) console.log(modelLabel(m, e));
")
want='opus 5 high
fable 5.1 xhigh
sonnet 5 medium
haiku 4.5 low
claude-some-model-nobody-has-shipped-yet high
opus 5 -
- high
- -'
[ "$map_out" = "$want" ] ||
  fail "the model label mapping drifted:
$map_out"
pass "each known model id maps to the captain's short form and an unknown one is printed verbatim"

# The label rides the ACTIVE cell, under the timer, on two rows: one axis each,
# because the widest pair - `fable 5.1` and `xhigh` - is fifteen columns against
# an eleven-column cell field and shortening either half is a mid-token cut.
#
# The cells are addressed through the renderer's own layout, so a change to a
# cell width or the arrow gutter moves this assertion with it.

model_agent() {  # <id> <worker-json> <steps-json> <actives-json>
  jq -n --arg id "$1" --argjson worker "$2" \
    --argjson steps "$3" --argjson actives "$4" '{
    id:$id, branch:("fm/"+$id), project:"/p/firstmate", worktree:"/wt",
    window:"fm:1", kind:"ship", mode:"no-mistakes", pipeline:true, state:null,
    endpoint_alive:true, agent_alive:"alive", skips:{local:false,ci:false},
    worker:$worker,
    pr:{url:null,number:null},
    collection:{ok:true,reason:"",at:"t",epoch:1786000000},
    run:{present:true,id:"01K",status:"running",db_updated_epoch:1786000000,db_age_seconds:0},
    steps:$steps, active_steps:$actives,
    ci:{collection:{ok:false,reason:"skipped"},checks:[],
        total:0,passed:0,failed:0,pending:0,skipped:0,excused:0}
  }'
}

# The two label rows of a frame, one string per cell, read through the
# renderer's own layout the way the skip probe does.
cat >"$TMP_ROOT/labels.mjs" <<'JS'
const { render, layout, CELL_WIDTHS } = await import(process.argv[2]);
const doc = JSON.parse(process.argv[3]);
const cols = Number(process.argv[4]);
const lay = layout(cols, 0);
const frame = render(doc, { rows: 60, cols, sel: 0, cell: -1 })
  .map((l) => l.replace(/\x1b\[[0-9;]*m/g, ""));
const head = frame.findIndex((l) => l.includes(doc.agents[0].id));
const offsets = [];
{
  let x = 2;
  for (const w of CELL_WIDTHS) { offsets.push(x); x += w + lay.gap; }
}
// head, top, mid, bot, timer, timer2, model, effort, facts.
const cells = (row) => CELL_WIDTHS
  .slice(lay.first, lay.first + lay.count)
  .map((w, i) => (frame[head + row] ?? "").slice(offsets[i], offsets[i] + w).trim());
console.log(JSON.stringify({ model: cells(6), effort: cells(7) }));
JS

labels() {  # <agents-json> [cols]
  node "$TMP_ROOT/labels.mjs" "$TUI" "$(snap "$1")" "${2:-200}"
}

# The expected label row, written by naming only the cells that carry a label
# and letting the rest of the row come from the renderer's own cell count
# ($NCELLS above). A row spelled out as literal empty strings asserts the WIDTH
# of the row as well as its contents, so a cell added to STEPS broke every one
# of these on a fact they were never about.
label_row() {  # <index>:<value>... -> the JSON array for that axis
  local spec out
  out=$(jq -cn --argjson n "$NCELLS" '[range($n) | ""]')
  for spec in "$@"; do
    out=$(printf '%s' "$out" |
      jq -c --argjson i "${spec%%:*}" --arg v "${spec#*:}" '.[$i] = $v')
  done
  printf '%s' "$out"
}
# The two rows together, in the shape labels.mjs prints them. Specs before `--`
# are the model row, specs after it the effort row; either side may be empty.
label_rows() {  # <model-spec...> -- <effort-spec...>
  local a seen=0
  local -a model=() effort=()
  for a in "$@"; do
    if [ "$a" = -- ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then model+=("$a"); else effort+=("$a"); fi
  done
  printf '{"model":%s,"effort":%s}' \
    "$(label_row ${model[@]+"${model[@]}"})" \
    "$(label_row ${effort[@]+"${effort[@]}"})"
}

STEP_BUILD='[{"step":"building","status":"running","findings":0,"duration_ms":0}]'
ACT_BUILD='[{"step":"building","status":"running","active_ms":90000}]'

# building is the worker's own phase, so its label is the worker's own record.
BUILDING=$(model_agent building-a1 \
  '{"harness":"claude","model":"claude-fable-5-1","effort":"xhigh"}' \
  "$STEP_BUILD" "$ACT_BUILD")
out=$(labels "[$BUILDING]")
[ "$out" = "$(label_rows 0:'fable 5.1' -- 0:xhigh)" ] ||
  fail "the building cell did not carry the worker's own model and effort:
$out"
pass "the building cell names the model the worker itself runs on"

# A pipeline step's label is the model the RUN launched for it, never the
# worker's. This agent's worker is on fable and its review agent on opus, and
# the row must say both.
REVIEW=$(model_agent review-b2 \
  '{"harness":"claude","model":"claude-fable-5-1","effort":"xhigh"}' \
  "$(jq -n '[{step:"building",status:"completed",findings:0,duration_ms:60000},
             {step:"intent",status:"completed",findings:0,duration_ms:22},
             {step:"rebase",status:"completed",findings:0,duration_ms:4400},
             {step:"review",status:"running",findings:0,duration_ms:0}]')" \
  '[{"step":"review","status":"running","active_ms":600000,"model":"claude-opus-5","effort":"high"}]')
out=$(labels "[$REVIEW]")
[ "$out" = "$(label_rows 3:'opus 5' -- 3:high)" ] ||
  fail "a running review step did not carry the model the run launched for it:
$out"
pass "a pipeline step names the model the run launched for that step, not the worker's"

# Nothing machine-recorded means a dash on both axes - never a blank, which
# reads as "no label", and never a name, which reads as a measurement.
UNKNOWN=$(model_agent unknown-c3 '{"harness":"claude","model":null,"effort":null}' \
  "$STEP_BUILD" "$ACT_BUILD")
out=$(labels "[$UNKNOWN]")
[ "$out" = "$(label_rows 0:- -- 0:-)" ] ||
  fail "an agent with nothing recorded did not render both axes as dashes:
$out"
pass "an axis with no machine record behind it renders as a dash"

# A finished cell carries no label at all: the question is about work in
# progress, and a label on every finished box is six answers to a question
# nobody is asking beside the one that matters.
DONE=$(model_agent done-d4 '{"harness":"claude","model":"claude-opus-5","effort":"high"}' \
  "$(steps_all completed | jq '[{step:"building",status:"completed",findings:0,duration_ms:60000}] + .')" '[]')
out=$(labels "[$DONE]")
[ "$out" = "$(label_rows -- )" ] ||
  fail "a row with no active cell drew a label anyway:
$out"
pass "a cell that is not the active one carries no model label"

# The label rides the cells, so narrowing the frame moves it with the window
# rather than cutting it: every drawn label is one whole token.
for width in 200 161 143 130 120 100 80; do
  out=$(labels "[$REVIEW]" "$width")
  case $out in
    *'"opus 5"'*|*'"model":[]'*|*'"opus'*) ;;
    *) case $out in *opus*) fail "at $width columns a model label was cut: $out" ;; esac ;;
  esac
  printf '%s' "$(snap "[$REVIEW]")" | node "$TUI" --cols "$width" --rows 60 --tick 0 |
    sed 's/\x1b\[[0-9;]*m//g' |
    awk -v c="$width" '{ if (length($0) > c) { print "wide"; exit 1 } }' ||
    fail "at $width columns the frame ran wider than the terminal"
done
pass "a narrowed frame keeps whole labels and still fits the terminal"

# A worker with no pipeline has no step cells to hang a label on, so its own
# model rides its facts row instead - and in no alarm colour, because a healthy
# idle second mate's row carries none.
FLAT=$(printf '%s' "$SCOUT" | jq '.worker={harness:"claude",model:"claude-opus-5",effort:"xhigh"}')
out=$(render "$(snap "[$FLAT]")")
assert_contains "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')" "opus 5 xhigh" \
  "a worker with no pipeline lost its own model label"
# The failure slot is absent for the reason the idle second mate case states:
# it is shared with this row's own kind label and run counter.
for slot in '\x1b[95m' '\x1b[93m'; do
  assert_not_contains "$out" "$(printf '%b' "$slot")" \
    "a healthy pipeline-less worker's row was painted in an alarm colour"
done
pass "a worker with no pipeline carries its own label on its facts row"

# --- the PR number rides the connector leaving push+PR -----------------------
#
# The number comes from the snapshot's `pr.number`, which
# bin/fm-flow-snapshot.sh derives from the recorded link through the one owner
# of that grammar. A task with no PR recorded gets a dash there, never blank:
# not evaluated and absent are different answers and blank says neither.

pr_connector_label() {  # <snapshot-json> [render args...]
  local doc=$1; shift
  printf '%s' "$doc" | node "$TUI" --cols "${1:-200}" --rows 60 --tick 0 |
    sed 's/\x1b\[[0-9;]*m//g' |
    awk -v prbox="$PRBOX" '/push\+PR/ {
      getline
      # The box row splits into whitespace-separated cells, so the label under
      # the arrow leaving push+PR is the field just after that box. Reading it
      # this way rather than by column number means a width change moves the
      # assertion with the renderer instead of leaving it reading empty space,
      # and counting from push+PR rather than from the end of the row means a
      # cell added after it does not move the assertion onto a box.
      print $(prbox + 1)
      exit
    }'
}

WITHPR=$(agent_with pr1 "$(steps_all completed)" \
  '{"pr":{"url":"https://github.com/kirangathani/eln/pull/29","number":29}}')
got=$(pr_connector_label "$(snap "[$WITHPR]")")
[ "$got" = "#29" ] || fail "the PR number is not under the arrow leaving push+PR: '$got'"
pass "the PR number is drawn under the arrow leaving push+PR"

got=$(pr_connector_label "$(snap "[$(agent_with pr0 "$(steps_all completed)")]")")
[ "$got" = "-" ] || fail "a task with no PR left the connector blank instead of a dash: '$got'"
pass "a task with no PR recorded reads as a dash under that arrow, never blank"

# The label rides a gutter of its own width, so tightening the arrow spacing
# must not squeeze it out. 130 columns is the width that drops the frame to the
# tightest ordinary gutter.
for cols in 200 130; do
  got=$(pr_connector_label "$(snap "[$WITHPR]")" "$cols")
  [ "$got" = "#29" ] || fail "at $cols columns the PR number was lost: '$got'"
done
pass "the PR number survives every arrow spacing the frame is drawn at"

# --- a direct-PR project draws the journey its delivery mode actually takes ---
#
# `direct-PR` means the project never enters the pipeline: the worker pushes
# and opens the PR itself. That is a delivery-mode consequence read from the
# task's own record, not a captain-authorised testing skip, and the title says
# which of the two it is.

DIRECT=$(agent_with dp1 '[]' \
  '{"mode":"direct-PR","pr":{"url":"https://github.com/o/r/pull/29","number":29}}')
out=$(render "$(snap "[$DIRECT]")" | sed 's/\x1b\[[0-9;]*m//g')
head=$(printf '%s' "$out" | grep -F 'Agent 1  dp1')
assert_contains "$head" "direct-PR" "the direct-PR row does not name what authorised its short journey"
case "$head" in
  *--local-skip*|*--ci-skip*) fail "a delivery-mode skip was reported as a testing-skip flag: $head" ;;
esac
timers=$(printf '%s' "$out" | awk '/push\+PR/ { getline; getline; print; exit }')
assert_contains "$timers" "skipped" "a direct-PR row drew no stage as skipped"
pass "a direct-PR row draws its pipeline stages as skipped and names the mode that authorised it"

# A direct-PR task's building phase ENDS at its PR, and what the worker does
# afterwards is a MARKER under the push+PR box, not a stage of its own. Before
# this, `building` had no end on that path at all - the captain saw
# `building running 3h54m` beside a PR that had been open for hours - and the
# row said nothing about the review work still going on.
#
# The row keeps exactly the stages the pipeline has. A column for the aftermath
# would have said it grew one it does not.
REWORKING=$(agent_with dp3 \
  '[{"step":"building","status":"completed","findings":0,"duration_ms":600000}]' \
  '{"mode":"direct-PR","pr":{"url":"https://github.com/o/r/pull/31","number":31},
    "rework":{"active_ms":7400000}}')
out=$(render "$(snap "[$REWORKING]")" | sed 's/\x1b\[[0-9;]*m//g')
# The building phase and the push+PR box sit on the same timer line, so it is
# read CELL BY CELL: a check against the whole row would see the other cell's
# word and pass or fail for the wrong reason.
timers=$(printf '%s' "$out" | awk '/building/ { getline; getline; print; exit }')
build_cell=$(printf '%s' "$timers" | awk '{ print $1 }')
assert_contains "$build_cell" "10m" "a finished building phase did not state its duration"
assert_not_contains "$build_cell" "running" "building was still running with the PR open"
# The marker rides the SECOND timer line, under the push+PR box. 7400000ms is
# 2h03m, and `since PR 2h03m` is 14 columns against an 11-column cell, so the
# captain's own drop-rather-than-truncate rule applies: the marker says only
# `since PR`, never an ellipsis-cut duration.
marker=$(printf '%s' "$out" | awk '/building/ { getline; getline; getline; print; exit }')
assert_contains "$marker" "since PR" "post-PR work left no marker under push+PR"
assert_not_contains "$marker" "…" "a duration that does not fit the cell was truncated instead of dropped"
pass "a direct-PR row ends building at its PR and marks the work after it under push+PR"

# The plain-words case: a duration short enough to fit rides the same marker,
# rounded to bare minutes rather than the old `rework 2m03s` seconds precision
# the captain could not read at a glance.
FITS=$(agent_with dp4 \
  '[{"step":"building","status":"completed","findings":0,"duration_ms":600000}]' \
  '{"mode":"direct-PR","pr":{"url":"https://github.com/o/r/pull/32","number":32},
    "rework":{"active_ms":125000}}')
out=$(render "$(snap "[$FITS]")" | sed 's/\x1b\[[0-9;]*m//g')
marker=$(printf '%s' "$out" | awk '/building/ { getline; getline; getline; print; exit }')
assert_contains "$marker" "since PR 2m" "a duration that fits the cell was not shown in plain words"
pass "a since-PR duration that fits the cell reads in plain words, rounded to its coarsest unit"

# The row still has exactly the stages it had: the aftermath earned a marker,
# not a column.
STAGE_COUNT=$(node --input-type=module -e \
  'const m = await import(process.argv[1]); process.stdout.write(String(m.STEPS.length))' \
  "$TUI")
[ "$STAGE_COUNT" = 8 ] ||
  fail "the stage row grew or lost a cell: $STAGE_COUNT stages, want 8"
pass "the post-PR marker adds no stage to the row"

# The flag is a SEPARATE axis and is named by the flag the captain passed,
# taken from the record rather than inferred from the missing run.
BOTH=$(agent_with dp2 '[]' \
  '{"mode":"direct-PR","skips":{"local":false,"ci":true},"pr":{"url":"https://github.com/o/r/pull/30","number":30}}')
head=$(render "$(snap "[$BOTH]")" | sed 's/\x1b\[[0-9;]*m//g' | grep -F 'Agent 1  dp2')
assert_contains "$head" "direct-PR --ci-skip" \
  "a direct-PR task carrying a testing skip did not name both authorities"
pass "a testing skip beside the delivery mode is named by its own flag"

# The legend appears exactly when a skipped cell is on screen, and never
# otherwise: a legend for a colour nothing is wearing is noise.
hdr=$(render "$(snap "[$DIRECT]")" | sed 's/\x1b\[[0-9;]*m//g' | head -1)
assert_contains "$hdr" "skipped" "the skipped legend is missing while skipped cells are drawn"
hdr=$(render "$(snap "[$(agent_with ok1 "$(steps_all completed)")]")" |
  sed 's/\x1b\[[0-9;]*m//g' | head -1)
case "$hdr" in
  *skipped*) fail "the skipped legend appeared with no skipped cell on screen: $hdr" ;;
esac
pass "the skipped legend is shown when a skipped cell is drawn, and only then"

# The colour is the one already reserved for a skipped stage, not a new one, so
# the legend and the cells cannot drift apart.
coloured=$(render "$(snap "[$DIRECT]")" | head -1)
case "$coloured" in
  *$'\x1b'"[94mskipped"*) ;;
  *) fail "the skipped legend is not drawn in the skipped stage's own colour" ;;
esac
pass "the legend wears the same colour as the cells it names"

# --- detail-row alignment and the tally's spacer ----------------------------
#
# The rows under each box are a left-hand column, not four centred captions:
# every non-empty detail cell starts in its box's own first column, read
# through the renderer's own layout arithmetic so a width or gutter change
# moves the assertion with it. And one blank row always separates the last
# detail row from the check tally, including for an agent whose detail rows are
# all empty, so the tally reads as the agent's summary rather than as one more
# per-stage line.

cat >"$TMP_ROOT/align.mjs" <<'JS'
const { render, layout, CELL_WIDTHS } = await import(process.argv[2]);
const base = JSON.parse(process.argv[3]);
const COLS = 200, ROWS = 60;
let bad = 0;
const say = (m) => { console.error(m); bad++; };

const lay = layout(COLS, 0);
const offsets = [];
{
  let x = 2;  // agentBlock indents every box row by two columns
  for (const w of CELL_WIDTHS) { offsets.push(x); x += w + lay.gap; }
}

const frameFor = (agents) =>
  render({ ...base, agents }, { rows: ROWS, cols: COLS, sel: 0, cell: -1 })
    .map((l) => l.replace(/\x1b\[[0-9;]*m/g, ""));

// head, top, mid, bot, then the four detail rows, then the spacer, then facts.
const DETAIL_ROWS = [4, 5, 6, 7];

const checkAlign = (frame, id) => {
  const head = frame.findIndex((l) => l.includes(id));
  for (const r of DETAIL_ROWS) {
    const line = frame[head + r] ?? "";
    CELL_WIDTHS.forEach((w, i) => {
      const cell = line.slice(offsets[i], offsets[i] + w);
      if (cell.trim() === "") return;
      if (cell[0] === " ") {
        say(`${id} row ${r} cell ${i} is not left-aligned to its box: "${cell}"`);
      }
    });
  }
};

const checkSpacer = (frame, id) => {
  const head = frame.findIndex((l) => l.includes(id));
  const tally = frame.findIndex((l, i) => i > head && l.includes("checks:"));
  if (tally < 0) return say(`${id} rendered no check tally`);
  if ((frame[tally - 1] ?? "x").trim() !== "") {
    say(`${id} has no blank row before its tally: "${frame[tally - 1]}"`);
  }
};

// An agent with something to say on every detail row.
const busy = base.agents[0];
const f1 = frameFor([busy]);
checkAlign(f1, busy.id);
checkSpacer(f1, busy.id);

// And one whose detail rows are entirely blank: the spacer is unconditional.
const quiet = {
  ...busy,
  steps: busy.steps.map((s) => ({ ...s, status: "pending", duration_ms: 0 })),
  active_steps: [],
};
checkSpacer(frameFor([{ ...quiet, id: "quiet1" }]), "quiet1");

process.exit(bad ? 1 : 0);
JS

ALIGN=$(snap "[$(agent_with al1 "$(steps_all completed)" \
  '{"active_steps":[{"step":"test","status":"running","active_for":"2m59s","active_ms":179000,"last_activity":"","agent_pid":"","round":"1"}],"pr":{"url":"https://github.com/o/r/pull/51","number":51},"ci":{"collection":{"ok":true,"reason":""},"checks":[],"total":11,"passed":11,"failed":0,"pending":0,"skipped":0,"excused":0}}')]")
node "$TMP_ROOT/align.mjs" "$TUI" "$ALIGN" ||
  fail "a detail line did not start at its box's left column"
pass "every detail line starts in its box's own first column"
pass "a blank row always precedes the check tally"

# --- the run counter, on every row, in three named classes -------------------
#
# The captain asked for the number of runs this branch has been through the
# pipeline, next to the agent id. Both header variants carry it - the inverse
# one drawn on the selected row and the ordinary one on every other - because a
# row losing the count the moment it is selected is a count that disappears
# exactly when the captain is looking at it.
#
# It is drawn on EVERY row (2026-09-16: "make it consistent, when something is
# on the first run we still say run #1"), because a blank was saying three
# different things - no run yet, no pipeline at all, and a pipeline nobody
# could read - in the one way that says none of them.
#
# Asserted against the escapes the renderer actually emits, not against the
# plain text, because the colour is half the request: a counter in the default
# foreground would pass a plain-text assertion. The slots are read out of the
# renderer's own paint table rather than written down here, so the ruling that
# moved this from red to pink on 2026-09-24 moves the assertion with it.

cat >"$TMP_ROOT/runcount.mjs" <<'JS'
const { render, PAINT } = await import(process.argv[2]);
const snap = JSON.parse(process.argv[3]);
let bad = 0;
const say = (m) => { console.error(m); bad++; };
// The renderer's own slots, taken by painting a character with them, so the
// codes here can never be a second copy of the palette that drifts from it.
const slot = (paint) => /\x1b\[([0-9;]*)m/.exec(paint("x"))[1];
// The captain's pink: the failure slot, which is what he asked the counter to
// share. Coupling the assertion to PAINT.failed is the point - "the same pink"
// is the request, so a change that moved one and not the other must fail here.
const PINK = `\x1b[${slot(PAINT.failed)}m`;
const UNREADABLE = `\x1b[${slot(PAINT.unknown)}m`;

const headFor = (frame, id) => frame.find((l) => l.includes(id)) ?? "";
const withAgents = (fn) => {
  const doc = JSON.parse(process.argv[3]);
  doc.agents = doc.agents.map(fn);
  return render(doc, { rows: 60, cols: 200, sel: 0, cell: -1 });
};

// sel 0 puts the FIRST agent on the inverse header and leaves the second on
// the ordinary one, so one frame exercises both variants.
const frame = render(snap, { rows: 60, cols: 200, sel: 0, cell: -1 });
for (const [id, variant] of [["run3a", "inverse"], ["run3b", "ordinary"]]) {
  const head = headFor(frame, id);
  if (!head.includes(`${PINK}Run #3`)) say(`${variant} header carries no pink run counter: ${JSON.stringify(head)}`);
  if (head.includes("\x1b[91m")) say(`${variant} header still paints something in the retired red slot`);
  const idAt = head.indexOf(id);
  const runAt = head.indexOf("Run #3");
  if (idAt < 0 || runAt < idAt) say(`${variant} header did not put the counter after the id: ${JSON.stringify(head)}`);
}

// No run yet is its own mark, on both variants, and it is NOT a blank: a blank
// is what used to say this, "no pipeline at all", and "nobody could read it"
// all at once.
const blank = withAgents((a) => ({ ...a, run_number: null }));
for (const id of ["run3a", "run3b"]) {
  const head = headFor(blank, id);
  if (/Run #/.test(head)) say(`a null run number drew a numbered counter: ${JSON.stringify(head)}`);
  if (!head.includes(`${PINK}Run -`)) say(`a null run number drew no not-yet marker: ${JSON.stringify(head)}`);
}

// A pipeline the collector could not read is a third mark, in the unknown
// colour: it is not a reading at all, and must not look like one.
const unread = withAgents((a) => ({
  ...a, run_number: null, collection: { ok: false, reason: "axi status failed (exit 1)" },
}));
for (const id of ["run3a", "run3b"]) {
  const head = headFor(unread, id);
  if (!head.includes(`${UNREADABLE}Run ?`)) say(`an unreadable pipeline drew no unreadable counter: ${JSON.stringify(head)}`);
  if (head.includes("Run -")) say(`an unreadable pipeline drew the not-yet marker: ${JSON.stringify(head)}`);
}

// And a row with no pipeline of its own carries the mark too, which is the
// whole of "on every row".
const scout = withAgents((a) => ({ ...a, pipeline: false, kind: "scout", run_number: null }));
for (const id of ["run3a", "run3b"]) {
  const head = headFor(scout, id);
  if (!head.includes(`${PINK}Run -`)) say(`a row with no pipeline carries no counter: ${JSON.stringify(head)}`);
}
process.exit(bad ? 1 : 0);
JS

RUNDOC=$(snap "[$(agent_with run3a "$(steps_all completed)" '{"run_number":3}'),
                $(agent_with run3b "$(steps_all completed)" '{"run_number":3}')]")
node "$TMP_ROOT/runcount.mjs" "$TUI" "$RUNDOC" ||
  fail "the run counter is missing, mispositioned, uncoloured, or drawn from nothing"
pass "the run counter renders on every row in the pink slot, with its own mark for no run yet and for a pipeline nobody could read"

# --- a run that ended under a live worker, and a CI head that will not land ---
#
# Two frames the captain read wrong on 2026-09-15, both reproduced from live
# collector output that day (data/fm-pipeline-view-stale-run-r4/report.md, the
# scout that diagnosed them; epochs pinned here to the values it captured):
#
#   eln-live-body-coedit-b2   run 01M2GY0VXE7ERKBFP3QACX6PDH ended `failed`,
#                             `daemon shutting down`, 27 minutes before the
#                             frame; the worker was alive and building again.
#                             The row drew `building 1h29m` finished, `review
#                             FAIL`, no band, no reason.
#   eln-location-no-project-l3  Run #5 was 31 minutes into review on head
#                             d1127afd, unpushed; PR 50's checks were for head
#                             4a22cbba from a cancelled earlier run. The CI cell
#                             drew amber `4/4 your word` and the header counted
#                             it ready to merge.
#
# The captain's rulings, asserted here cell by cell through the renderer's own
# layout arithmetic: the building box runs again with the band while the failed
# step keeps its FAIL and the head line names the reason; the CI cell's colour
# is its verdict alone - green passed, red failed, yellow for a head the live
# run will replace, with his two sentences wrapped whole - and `your word`
# moves to the pre-merge box; every finished box is the runner's centre green.

cat >"$TMP_ROOT/verdicts.mjs" <<'JS'
const { render, layout, CELL_WIDTHS, STEPS, BLOCK, ciVerdict, premergeVerdict, dur, PAINT } = await import(process.argv[2]);
// The renderer's own slots, painted and read back, so a palette ruling moves
// every assertion below with it instead of leaving them asserting a colour the
// captain replaced.
const slot = (paint) => /\x1b\[([0-9;]*)m/.exec(paint("x"))[1];
const FAILED = slot(PAINT.failed);
const base = JSON.parse(process.argv[3]);
const COLS = 200, ROWS = 60;
let bad = 0;
const say = (m) => { console.error(m); bad++; };
const lay = layout(COLS, 0);
const offsets = [];
{ let x = 2; for (const w of CELL_WIDTHS) { offsets.push(x); x += w + lay.gap; } }
const plain = (l) => l.replace(/\x1b\[[0-9;]*m/g, "");
// The SGR codes painting the visible glyphs of cell i on one raw row, so a
// box's colour is read off the bytes rather than inferred from a word.
const paints = (raw, i) => {
  const out = new Set();
  const re = /\x1b\[([0-9;]*)m/g;
  let cur = "", col = 0;
  for (let k = 0; k < raw.length;) {
    re.lastIndex = k;
    const m = re.exec(raw);
    if (m && m.index === k) { cur = m[1] === "0" ? "" : m[1]; k += m[0].length; continue; }
    const ch = raw[k++];
    if (col >= offsets[i] && col < offsets[i] + CELL_WIDTHS[i] && ch !== " " && cur) out.add(cur);
    col++;
  }
  return [...out].sort().join(" ");
};
const rowsFor = (a) => {
  const raw = render({ ...base, agents: [a] }, { rows: ROWS, cols: COLS, sel: 0, cell: -1 });
  const frame = raw.map(plain);
  const head = frame.findIndex((l) => l.includes(a.id));
  const cellsOf = (row) => CELL_WIDTHS.map((w, i) => (frame[row] ?? "").slice(offsets[i], offsets[i] + w).trim());
  return {
    header: frame[0], head: frame[head], headRaw: raw[head],
    // head, top, mid, bot, then the five detail rows, a blank, and the facts.
    words: cellsOf(head + 4), times: cellsOf(head + 5),
    r3: cellsOf(head + 6), r4: cellsOf(head + 7), r5: cellsOf(head + 8),
    blank: frame[head + 9], facts: frame[head + 10],
    mid: (i) => paints(raw[head + 2], i),
  };
};
const at = (key) => STEPS.findIndex((s) => s.key === key);
const CI = CELL_WIDTHS.length - 2, PRE = CELL_WIDTHS.length - 1;
const step = (s, status, ms = 0, findings = 0) => ({ step: s, status, findings, duration_ms: ms });
const rest = (from) => ["test", "document", "lint", "push", "pr", "ci"].slice(from).map((s) => step(s, "pending"));
const T = base.agents[0];

// --- case 1: eln-live-body-coedit-b2 at 08:55:50Z ---------------------------
const stale = {
  ...T, id: "stale-run", run_number: 1, endpoint_alive: true,
  run: { present: true, id: "01M2GY0VXE7ERKBFP3QACX6PDH", status: "failed",
         error: "daemon shutting down", head: "ef1d5be5766ad8bb1df5c3b7163aad61e7922175",
         db_updated_epoch: 1789460925, db_age_seconds: 1625 },
  steps: [step("building", "running"), step("intent", "completed", 57), step("rebase", "completed", 5104),
          step("review", "failed", 12014770, 1), ...rest(0)],
  active_steps: [{ step: "building", status: "running", active_for: "", active_ms: 1625000,
                   last_activity: "", agent_pid: "", round: "" }],
};
{
  const r = rowsFor(stale);
  if (r.words[at("building")] !== "running") say(`building is not running again: "${r.words[at("building")]}"`);
  if (r.times[at("building")] !== dur(1625000)) say(`building does not count since the run ended: "${r.times[at("building")]}"`);
  if (!r.mid(at("building")).includes("1;92")) say(`no runner band on the building box: ${r.mid(at("building"))}`);
  if (r.words[at("review")] !== "FAIL") say(`the failed step lost its FAIL: "${r.words[at("review")]}"`);
  if (r.mid(at("review")) !== FAILED) say(`the failed box is not the failure colour alone: ${r.mid(at("review"))}`);
  if (r.mid(at("intent")) !== "92") say(`a finished box is not the runner's green: ${r.mid(at("intent"))}`);
  if (r.mid(at("test")) !== "2") say(`a pending box is not dim: ${r.mid(at("test"))}`);
  if (!r.head.includes("run failed: daemon shutting down")) say(`the head line does not say how the run ended: ${JSON.stringify(r.head)}`);
  if (!r.headRaw.includes(`\x1b[${FAILED}mrun failed: daemon shutting down`)) say("the run's end is not painted in the failure colour");
  if (!r.header.includes("0 ready to merge")) say(`header: ${r.header}`);
}
// The same run with the worker gone: nothing is building, nothing moves, and
// both facts are stated side by side.
{
  const r = rowsFor({ ...stale, id: "stale-gone", endpoint_alive: false });
  if (r.mid(at("building")) !== "95") say(`a gone worker's building box is not unknown: ${r.mid(at("building"))}`);
  for (let i = 0; i < CELL_WIDTHS.length; i++) {
    if (r.mid(i).includes("1;92")) say(`a runner band on cell ${i} of a gone worker`);
  }
  if (!r.head.includes("worker gone") || !r.head.includes("run failed: daemon shutting down")) {
    say(`gone worker's head line lost a fact: ${JSON.stringify(r.head)}`);
  }
}
// A cancelled run's error repeats its own status; the note says it once.
{
  const r = rowsFor({ ...stale, id: "cancelled-run",
    run: { ...stale.run, status: "cancelled", error: "cancelled: aborted by user" } });
  if (!r.head.includes("run cancelled: aborted by user")) say(`cancelled note: ${JSON.stringify(r.head)}`);
  if (r.head.includes("cancelled: cancelled")) say(`the cancelled note repeats itself: ${JSON.stringify(r.head)}`);
  const bare = rowsFor({ ...stale, id: "bare-fail", run: { ...stale.run, error: "" } });
  if (!bare.head.includes("run failed") || bare.head.includes("run failed:")) say(`empty reason: ${JSON.stringify(bare.head)}`);
}

// --- case 2: eln-location-no-project-l3 at 08:59:52Z ------------------------
const RUN_HEAD = "d1127afd90ec49611f6ebc64ca01ced2b5ca4d1f";
const CI_HEAD = "4a22cbbacc8b79651d3e41904eed193565e49b2e";
const live = {
  ...T, id: "run-five", run_number: 5, endpoint_alive: true,
  pr: { url: "https://github.com/kirangathani/eln/pull/50", number: 50 },
  run: { present: true, id: "01M2J2WDC5WZMD3M3X54H8TRQ1", status: "running", error: "", head: RUN_HEAD,
         db_updated_epoch: 1789462273, db_age_seconds: 519 },
  steps: [step("building", "completed", 52705000), step("intent", "completed", 115), step("rebase", "completed", 2889),
          step("review", "fixing", 527054), ...rest(0)],
  active_steps: [{ step: "review", status: "fixing", active_for: "31m44s", active_ms: 1904000,
                   last_activity: "", agent_pid: "", round: "2", model: "claude-opus-5", effort: "high" }],
  ci: { collection: { ok: true, reason: "" }, checks: [], total: 4, passed: 4, failed: 0, pending: 0,
        skipped: 0, excused: 0, excused_authority: [], head: CI_HEAD, pr_state: "OPEN",
        superseded: null },
};
const sup = (s) => ({ ...live, id: `sup-${Object.keys(s).filter((k) => s[k]).join("-") || "unknown"}`,
                      ci: { ...live.ci, superseded: { reason: "", ...s } } });
const expectCI = (a, want, label) => {
  const r = rowsFor(a);
  const got = [r.words[CI], r.times[CI], r.r3[CI], r.r4[CI], r.r5[CI]];
  if (JSON.stringify(got) !== JSON.stringify(want)) say(`${label}: CI rows ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  if (r.mid(CI) !== "93") say(`${label}: superseded CI box is not yellow alone: ${r.mid(CI)}`);
  if (r.words[PRE] !== "") say(`${label}: pre-merge asked for the word on a head that will not land: "${r.words[PRE]}"`);
  if (!r.header.includes("0 ready to merge")) say(`${label}: header counted a superseded PR: ${r.header}`);
  if (!r.facts.includes("checks ran on commit 4a22cbb")) say(`${label}: facts line does not name the checked commit: ${r.facts}`);
  if (ciVerdict(a) !== "superseded") say(`${label}: verdict ${ciVerdict(a)}`);
  return r;
};
expectCI(sup({ main_moved: true, new_commits: false }), ["main moved,", "must retest", "", "", ""], "main moved");
expectCI(sup({ main_moved: false, new_commits: true }), ["new branch", "commit, must", "retest", "", ""], "new commits");
expectCI(sup({ main_moved: true, new_commits: true }), ["main moved,", "must retest", "new branch", "commit, must", "retest"], "both");
expectCI(sup({ main_moved: null, new_commits: null, reason: "the run has no copy of the repository left to compare" }),
  ["branch changed,", "must retest", "", "", ""], "unreadable reason");
// The five sentences' rows never spill into the blank row or the facts.
{
  const r = rowsFor(sup({ main_moved: true, new_commits: true }));
  if (r.blank !== "") say(`the both case spilled past its five rows: ${JSON.stringify(r.blank)}`);
  if (!r.facts.startsWith("  CI 4 checks:")) say(`facts row moved: ${JSON.stringify(r.facts)}`);
}
// The same checks on the head that will land: green, and the word on pre-merge.
{
  const green = { ...live, id: "green-ci", ci: { ...live.ci, head: RUN_HEAD, superseded: null } };
  const r = rowsFor(green);
  if (r.words[CI] !== "4/4 passed") say(`green CI word: "${r.words[CI]}"`);
  if (r.mid(CI) !== "92") say(`green CI box paint: ${r.mid(CI)}`);
  if (r.words[PRE] !== "your word") say(`pre-merge does not ask for the word: "${r.words[PRE]}"`);
  if (r.mid(PRE) !== "93") say(`pre-merge asking for the word is not amber: ${r.mid(PRE)}`);
  if (!r.header.includes("1 ready to merge")) say(`header did not count the green PR: ${r.header}`);
  if (ciVerdict(green) !== "ready") say(`verdict ${ciVerdict(green)}`);
  // Finished boxes are the runner's centre green; the running one keeps its
  // white box under the band; unreached ones are dim.
  for (const k of ["building", "intent", "rebase"]) {
    if (r.mid(at(k)) !== "92") say(`finished ${k} box is not green: ${r.mid(at(k))}`);
  }
  if (!r.mid(at("review")).includes("97") || !r.mid(at("review")).includes("1;92")) say(`running box: ${r.mid(at("review"))}`);
  if (r.mid(at("document")) !== "2") say(`pending docs box: ${r.mid(at("document"))}`);
  if (!r.headRaw.includes(`\x1b[${FAILED}mRun #5`)) say("the run counter left the failure slot the captain asked it to share");
}
// A red head is a red head, superseded or not: a failure on the branch is a
// fact the captain wants, and it is not the false green this rule guards.
{
  const red = sup({ main_moved: true, new_commits: true });
  red.ci = { ...red.ci, failed: 1, passed: 3 };
  if (ciVerdict(red) !== "failed") say(`a failed check on a superseded head read as ${ciVerdict(red)}`);
}
// --- case 2b: a check that failed while its siblings are still running ------
//
// kunchenguid/no-mistakes PR 1104, head ca88ebd, 2026-09-24. The rollup GitHub
// returned held thirteen entries, every one of them a check run on that head -
// no stale head, and `PR must be raised via no-mistakes` PASSED, so the
// excusable check was never in play either. `Greptile Review` completed FAILURE
// at 10:09:48Z and `test (windows-steps)` ran until 10:24:31Z, so for fifteen
// minutes the cell drew a finished-failure verdict over a run that was still
// going: "the whole time we are progressing it just says FAIL as well and is
// red instead of showing the runner bar".
//
// The counts here are that PR at 10:15Z, which is the frame in his screenshot:
// twelve checks, seven passed, one failed, one skipped, three still pending.
{
  const midrun = {
    ...live, id: "ci-midrun",
    ci: { ...live.ci, head: RUN_HEAD, superseded: null,
          total: 12, passed: 7, failed: 1, pending: 3, skipped: 1, excused: 0 },
    active_steps: [{ step: "ci", status: "running", active_for: "8m21s", active_ms: 501000,
                     last_activity: "", agent_pid: "", round: "" }],
  };
  const r = rowsFor(midrun);
  if (ciVerdict(midrun) !== "running-failed") say(`a failure beside pending checks read as ${ciVerdict(midrun)}`);
  if (r.words[CI] !== "7/12 running") say(`the mid-run CI cell says "${r.words[CI]}"`);
  if (r.times[CI] !== dur(501000)) say(`the mid-run CI cell stopped counting: "${r.times[CI]}"`);
  if (r.r3[CI] !== "1 fail so far") say(`the failure already in is not stated: "${r.r3[CI]}"`);
  if (!r.mid(CI).includes("1;92")) say(`the mid-run CI box lost its runner band: ${r.mid(CI)}`);
  if (r.mid(CI).includes(FAILED)) say(`the mid-run CI box is painted as a finished failure: ${r.mid(CI)}`);
  if (r.words[PRE] !== "") say(`pre-merge asked for the word mid-run: "${r.words[PRE]}"`);
  if (!r.header.includes("0 ready to merge")) say(`the header counted a mid-run PR: ${r.header}`);
  // The tally has always carried the fail count and still does; the cell no
  // longer contradicts it.
  if (!r.facts.includes("1 fail")) say(`the tally lost the failure: ${r.facts}`);

  // It is the same on the FIRST pass through the box, which is what he asked
  // about - "I don't know if this is an issue the first time code reaches the
  // GitHubCI box as well". Nothing about this depends on a previous run.
  const firstRun = { ...midrun, id: "ci-midrun-first", run_number: 1 };
  if (ciVerdict(firstRun) !== "running-failed") say(`a first run read as ${ciVerdict(firstRun)}`);

  // And the moment the last check reports, it IS the verdict: red, FAIL, no
  // band. Withholding it then would be the opposite lie.
  const finished = { ...midrun, id: "ci-finished",
    ci: { ...midrun.ci, passed: 10, pending: 0 } };
  const rf = rowsFor(finished);
  if (ciVerdict(finished) !== "failed") say(`a finished red run read as ${ciVerdict(finished)}`);
  if (rf.words[CI] !== "10/12 FAIL") say(`the finished CI cell says "${rf.words[CI]}"`);
  if (rf.mid(CI) !== FAILED) say(`the finished CI box is not the failure colour alone: ${rf.mid(CI)}`);
  if (rf.r3[CI] !== "") say(`the finished CI cell still counts failures so far: "${rf.r3[CI]}"`);

  // A clean run in progress is untouched: no failure row, and the same
  // counter and band it has always had.
  const clean = { ...midrun, id: "ci-clean", ci: { ...midrun.ci, failed: 0, passed: 8 } };
  const rc2 = rowsFor(clean);
  if (ciVerdict(clean) !== "running") say(`a clean run in progress read as ${ciVerdict(clean)}`);
  if (rc2.words[CI] !== "8/12 running") say(`a clean mid-run CI cell says "${rc2.words[CI]}"`);
  if (rc2.r3[CI] !== "") say(`a clean mid-run CI cell invented a failure row: "${rc2.r3[CI]}"`);

  // A worker that is gone is not counting, whatever the rollup still says, so
  // the mid-run cell loses its band and its elapsed exactly as the clean one
  // already does.
  const gone = rowsFor({ ...midrun, id: "ci-midrun-gone", endpoint_alive: false });
  if (gone.mid(CI).includes("1;92")) say(`a gone worker's mid-run CI box kept the band: ${gone.mid(CI)}`);
  if (gone.times[CI] !== "") say(`a gone worker's mid-run CI box kept counting: "${gone.times[CI]}"`);
  if (gone.r3[CI] !== "1 fail so far") say(`a gone worker's mid-run CI box dropped the failure: "${gone.r3[CI]}"`);

  // The widest count the field has to hold, so the row never needs shortening.
  const many = { ...midrun, id: "ci-many-fail",
    ci: { ...midrun.ci, total: 99, passed: 40, failed: 12, pending: 47 } };
  const rm2 = rowsFor(many);
  if (rm2.r3[CI] !== "12 fail so far") say(`a two-digit failure count did not fit: "${rm2.r3[CI]}"`);
}

// --- case 3: a PR that is no longer the captain's to decide -----------------
//
// PR 92 merged at 2026-09-15 23:17:58Z, and the next morning the view drew it
// as `11/12 passed` beside `pre-merge your word` and counted `1 ready to
// merge`. A merged PR's checks stay green forever, so the tally cannot be what
// decides this: the PR's own state is.
{
  const landed = (state, id) => ({ ...live, id, ci: { ...live.ci, head: RUN_HEAD, superseded: null, pr_state: state } });

  // The drawn frame is asserted BEFORE the readiness owner is called, so a tree
  // where that owner does not exist yet still fails on what the captain sees
  // rather than only on a missing export.
  const merged = landed("MERGED", "merged-pr");
  const rm = rowsFor(merged);
  if (rm.words[PRE] !== "merged") say(`a merged PR's pre-merge cell says "${rm.words[PRE]}"`);
  if (!rm.header.includes("0 ready to merge")) say(`the header counted a merged PR: ${rm.header}`);
  // The checks it passed are still the checks it passed; what changed is
  // whether anyone is being asked about them.
  if (rm.words[CI] !== "4/4 passed") say(`a merged PR's checks stopped being reported: "${rm.words[CI]}"`);

  const closed = landed("CLOSED", "closed-pr");
  const rc = rowsFor(closed);
  if (rc.words[PRE] !== "closed" || rc.times[PRE] !== "not merged") {
    say(`a closed PR's pre-merge cell says "${rc.words[PRE]}" / "${rc.times[PRE]}"`);
  }
  if (!rc.header.includes("0 ready to merge")) say(`the header counted a closed PR: ${rc.header}`);
  if (premergeVerdict(merged) !== "merged") say(`a merged PR read as ${premergeVerdict(merged)}`);
  if (premergeVerdict(closed) !== "closed") say(`a closed PR read as ${premergeVerdict(closed)}`);

  // A lifecycle the collector LOOKED FOR and could not read is said, not drawn
  // clean: an empty pre-merge cell reads as "not reached", which is a different
  // claim from "nobody could find out whether this is still open". The
  // collector states that by writing the key with an empty value, which every
  // one of its unread reasons does.
  const unread = landed("", "unread-state");
  const ru = rowsFor(unread);
  if (ru.words[PRE] !== "not read") say(`an unread PR state drew "${ru.words[PRE]}"`);
  if (ru.mid(PRE) !== "95") say(`an unread PR state is not drawn in the unknown colour: ${ru.mid(PRE)}`);
  if (!ru.header.includes("0 ready to merge")) say(`the header counted a PR of unknown state: ${ru.header}`);

  if (premergeVerdict(unread) !== "unknown") say(`an unread PR state read as ${premergeVerdict(unread)}`);

  // And the other direction, which is a DIFFERENT fact from the one above: a
  // document with NO pr_state key at all makes no claim either way - it comes
  // from a collector that never asked - so it falls through to the checks
  // rather than reporting a read that never happened as a failed one. Both
  // halves are pinned here because one expression reading `pr_state ?? ""`
  // silently re-conflates them, which is what it did before 2026-09-16.
  {
    const noKey = { ...live, id: "no-state-key", ci: { ...live.ci, head: RUN_HEAD, superseded: null } };
    delete noKey.ci.pr_state;
    if ("pr_state" in noKey.ci) say("the absent-key case still carries the key");
    const rn = rowsFor(noKey);
    if (premergeVerdict(noKey) !== "ready") say(`an absent PR state read as ${premergeVerdict(noKey)}`);
    if (rn.words[PRE] !== "your word") say(`an absent PR state drew "${rn.words[PRE]}"`);
    if (!rn.header.includes("1 ready to merge")) say(`the header did not count a green PR of no stated state: ${rn.header}`);
    // A null value is no claim either, for the same reason: the collector
    // writes a string or nothing, so a null can only come from a hand-written
    // document and says as little as an absent key.
    const nulled = { ...noKey, id: "null-state", ci: { ...noKey.ci, pr_state: null } };
    if (premergeVerdict(nulled) !== "ready") say(`a null PR state read as ${premergeVerdict(nulled)}`);
    // The terminal states are still terminal on the same document shape, so
    // falling through to the checks can never swallow a merged PR.
    const mergedNoOthers = { ...noKey, id: "merged-again", ci: { ...noKey.ci, pr_state: "MERGED" } };
    if (premergeVerdict(mergedNoOthers) !== "merged") say(`a merged PR read as ${premergeVerdict(mergedNoOthers)} on that shape`);
  }

  // And the whole point: a merged PR is terminal whatever its checks did, so
  // the readiness answer never falls through to them.
  for (const [state, want] of [["MERGED", "merged"], ["CLOSED", "closed"]]) {
    const a = { ...landed(state, `red-${state}`), ci: { ...live.ci, head: RUN_HEAD, superseded: null, pr_state: state, failed: 1, passed: 3 } };
    if (premergeVerdict(a) !== want) say(`a ${state} PR with a red check read as ${premergeVerdict(a)}`);
  }
}
if (BLOCK !== 12) say(`BLOCK is ${BLOCK}; the five detail rows need 12`);
process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/verdicts.mjs" "$TUI" "$(snap "[$(agent_with tmpl '[]' '{}')]")" ||
  fail "the ended-run and superseded-CI frames do not draw as the captain ruled"
pass "an ended run rebuilds with the band and its reason, a superseded CI head is yellow with the captain's sentences, and green means passed on the head that will land"

# --- the standing upstream wait, on a row with no pipeline -------------------
#
# The captain's own no-PR case: "a scouting agent who has submitted an issue and
# is waiting for it to be marked ready-for-pr before starting the PR build". A
# scout draws no stage boxes, so its wait rides the facts row beside the state
# word, in the same colour and with the same sentence a pipeline row's head
# carries. tests/fm-flow-tui-pty.test.sh drives the pipeline row through a real
# terminal and owns the FAIL invariant; this is the compact half and the pure
# state function beneath both.

cat >"$TMP_ROOT/upstream.mjs" <<'JS'
const { render, upstreamWaitState, upstreamWaitNote, PAINT } = await import(process.argv[2]);
let bad = 0;
const say = (m) => { console.error(m); bad++; };
const slot = (p) => /\x1b\[([0-9;]*)m/.exec(p("x"))[1];
const LILAC = `\x1b[${slot(PAINT.upstream)}m`;
const plain = (f) => f.join("\n").replace(/\x1b\[[0-9;]*m/g, "");

const scout = {
  id: "scout-issue", branch: "fm/scout-issue", project: "/p/firstmate",
  worktree: "/wt", window: "fm:2", kind: "scout", pipeline: false,
  endpoint_alive: true, captain_driving: false,
  state: { ok: true, value: "working", detail: "", reason: "" },
  upstream_wait: { waiting: true, action: "issue 900 to be labelled ready-for-pr" },
};
const snap = {
  schema: "fm-flow-snapshot.v2", generated_epoch: 1790000000,
  fm_home: "/home/x/firstmate", agents: [scout],
};
const frame = render(snap, { rows: 60, cols: 200, sel: 0, cell: -1 });
const out = plain(frame);
if (!out.includes("waiting on action from upstream: issue 900 to be labelled ready-for-pr")) {
  say(`a scout row does not carry its wait: ${JSON.stringify(out)}`);
}
if (!frame.join("\n").includes(LILAC)) say("a scout's wait is not drawn in its own colour");
// The fixed scout caption is untouched: the wait is a segment beside it, never
// a replacement for the row's own words.
if (!out.includes("no pipeline view as this is a scout agent")) {
  say("the scout caption was replaced by the wait");
}

// The state function beneath every drawing of it. A row with no record says so;
// a row whose checks failed reports the record stale rather than the wait.
const none = { ...scout, upstream_wait: { waiting: false, action: "" } };
if (upstreamWaitState(none) !== "none") say(`a row with no record read ${upstreamWaitState(none)}`);
if (upstreamWaitNote(none) !== "") say("a row with no record produced a note");
if (upstreamWaitState(scout) !== "waiting") say(`a standing wait read ${upstreamWaitState(scout)}`);

const ci = (o) => ({ collection: { ok: true, reason: "" }, checks: [], excused: 0,
                     skipped: 0, pr_state: "OPEN", superseded: null, ...o });
const red = { ...scout, pipeline: true,
  pr: { url: "https://x/pull/1", number: 1 },
  ci: ci({ total: 12, passed: 10, failed: 1, pending: 0 }) };
if (upstreamWaitState(red) !== "stale") say(`a wait over a failed check read ${upstreamWaitState(red)}`);
// And while a check is still running with one already red, which is the state
// item 1 introduced: that is not a clean run either, so the record is stale
// there too rather than only once everything has reported.
const midrun = { ...red, ci: ci({ total: 12, passed: 7, failed: 1, pending: 3 }) };
if (upstreamWaitState(midrun) !== "stale") say(`a wait over a mid-run failure read ${upstreamWaitState(midrun)}`);
// A wait with no action named still says the thing it does know.
const bare = { ...scout, upstream_wait: { waiting: true, action: "" } };
if (upstreamWaitNote(bare) !== "waiting on action from upstream") {
  say(`a wait with no action named produced ${JSON.stringify(upstreamWaitNote(bare))}`);
}
process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/upstream.mjs" "$TUI" ||
  fail "a standing upstream wait is not drawn on a row with no pipeline, or its state reads wrong"
pass "a row with no pipeline carries its upstream wait beside its own caption, and a wait over a failing check reads stale rather than waiting"
