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

# A CI rollup result in the shape bin/fm-flow-snapshot.sh emits, with a PR to
# hang it on. Every class is named so a case can never accidentally leave one
# undefined and assert against a default.
ci_result() {  # <total> <passed> <failed> <pending> <skipped> <excused>
  jq -n --argjson t "$1" --argjson p "$2" --argjson f "$3" \
        --argjson w "$4" --argjson s "$5" --argjson x "$6" '{
    pr:{url:"https://github.com/kirangathani/firstmate/pull/51",number:51},
    ci:{collection:{ok:true,reason:""},checks:[],
        total:$t,passed:$p,failed:$f,pending:$w,skipped:$s,excused:$x,
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

# --- the frame fits the terminal it is drawn on -----------------------------
#
# The shipped renderer drew all 143 columns of the nine stages whatever --cols
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
# rather than letting the captain believe they are seeing all nine.
assert_contains "$narrow" "stages 1-" "a narrowed view did not state which stages it is showing"
assert_contains "$narrow" "of 9" "a narrowed view did not state how many stages exist"
wide=$(printf '%s' "$BIG" | node "$TUI" --cols 200 --rows 24 --tick 0 | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$wide" "pre-merge" "the last stage is missing at a width that fits every stage"
assert_not_contains "$wide" "of 9" "a full-width view claimed to be showing a subset"
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
          "ci":{"collection":{"ok":true,"reason":""},"checks":[],"total":11,"passed":11,"failed":0,"pending":0}}'
out=$(render "$(snap "[$(agent_with t1 "$(steps_all completed)" "$green11")]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "11/11 your word" "the all-green summary still does not fit its cell"
assert_not_contains "$out" "your wo…" "the all-green summary is being shortened when it fits"
pass "the pre-merge summary fits its cell whole at real fleet check counts"

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
const { resolveTop } = await import(process.argv[2]);
let bad = 0;
const eq = (got, want, what) => {
  if (got !== want) { console.error(`${what}: got ${got}, want ${want}`); bad++; }
};
// 6 agents, 2 visible. Walk down to the end and back up, one key at a time,
// carrying `top` exactly as the viewer does.
const VIS = 2, N = 6;
let top = 0;
const step = (sel, wantTop, what) => { top = resolveTop(top, sel, VIS, N); eq(top, wantTop, what); };
step(0, 0, "start");
step(1, 0, "down to the bottom row: window still");
step(2, 1, "down past the bottom row: window scrolls one");
step(3, 2, "down again: window scrolls one");
step(2, 2, "up FROM the bottom row: window must NOT move");
step(1, 1, "up from the top row: window scrolls one");
step(0, 0, "up from the top row again: window scrolls one");
// Jumps land the selector at an edge rather than centring it.
top = 0; eq(resolveTop(top, 5, VIS, N), 4, "jump to last");
top = 4; eq(resolveTop(top, 0, VIS, N), 0, "jump to first");
// A shrinking fleet must not leave the window pointing past the end.
eq(resolveTop(4, 1, VIS, 3), 1, "fleet shrank under the window");
// More room than agents: there is nowhere to scroll to.
eq(resolveTop(0, 2, 9, 3), 0, "window taller than the fleet");
process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/scroll.mjs" "$TUI" || fail "the scroll rule moved the window off an edge"
pass "the window moves only when the selector would otherwise leave it"

# --- records with no worker are not agents -----------------------------------
#
# The collector holds them back; the renderer must not quietly absorb the
# difference. They are stated, and they are not in the agent count.

omitted='{"omitted":[{"id":"gone-1","window":"fm:9","reason":"recorded window no longer exists"},
                     {"id":"gone-2","window":"fm:8","reason":"recorded window no longer exists"}],
          "out_of_scope":[{"id":"scout-1","kind":"scout","window":"fm:7"}]}'
DOC2=$(snap "[$(agent_with live2 "$(steps_all running)")]" | jq ". * $omitted")
out=$(render "$DOC2" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "1 agents" "the held-back records were counted as agents"
assert_contains "$out" "2 hidden" "the held-back records were not stated"
assert_contains "$out" "1 running no pipeline" "a live worker with no row was not stated"
assert_not_contains "$out" "gone-1" "a held-back record was drawn as an agent"
pass "held-back records are stated in the header and never drawn or counted"

# --- what enter does is stated on the selected row, whatever cell is on -------
#
# Stepping right onto GITHUB CI used to leave a highlighted cell and nothing
# saying what enter would do to it. Enter is agent-scoped, no cell carries an
# action of its own, and the row says so on every frame.

DOC3=$(snap "[$(agent_with e1 "$(steps_all completed)")]")
out=$(render "$DOC3" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "enter: open this worker's window" "the selected row does not say what enter does"

# The cell is only reachable through the arrow keys, so the frame is asked for
# directly. Cell 7 is GITHUB CI, the one the captain pressed enter on.
cat >"$TMP_ROOT/hint.mjs" <<'JS'
const { render } = await import(process.argv[2]);
const snap = JSON.parse(process.argv[3]);
const plain = (f) => f.join("\n").replace(/\x1b\[[0-9;]*m/g, "");
let bad = 0;
for (const cell of [-1, 0, 4, 7, 8]) {
  const out = plain(render(snap, { rows: 60, cols: 200, sel: 0, cell }));
  if (!out.includes("enter: open this worker's window")) {
    console.error(`cell ${cell}: the selected row does not say what enter does`);
    bad++;
  }
}
const custom = plain(render(snap, {
  rows: 60, cols: 200, sel: 0, cell: 7, openHint: "enter: attach (detach to come back)",
}));
if (!custom.includes("detach to come back")) { console.error("--open-hint did not reach the row"); bad++; }
if (custom.includes("open this worker's window")) { console.error("--open-hint did not replace the default"); bad++; }
process.exit(bad ? 1 : 0);
JS
node "$TMP_ROOT/hint.mjs" "$TUI" "$DOC3" ||
  fail "the enter hint is missing on some cell, or the caller's hint did not reach it"
pass "the selected agent states what enter does whichever cell is highlighted"

# The caller owns that sentence end to end: only it knows what its --open-cmd
# does to the captain's terminal and how to get back.
out=$(setsid node "$TUI" --watch --cols 200 --rows 60 --tick 0 \
  --open-hint 'enter: attach (detach to come back)' <<<"$DOC3" 2>/dev/null |
  sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "detach to come back" "--open-hint did not survive the flag path"
pass "--open-hint replaces the default sentence about what enter does"

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
assert_contains "$excused" "10/11 your word" "an excused-only red PR did not park for the captain"
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
[ "$dashes" = "CI checks:  - pass  - fail  - excused  - skipped  - pending  (no PR yet)" ] ||
  fail "an unevaluated row did not render dashes with its reason: $dashes"
pass "a class that was never evaluated renders as a dash and says why"

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
const { render, layout, CELL_WIDTHS, LOCAL_SKIP_STAGES, STEPS } =
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
  for (const w of CELL_WIDTHS) { offsets.push(x); x += w + lay.gap; }
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
  steps: [],
  pr: { url: "https://github.com/kirangathani/firstmate/pull/51", number: 51 },
  collection: { ok: true, reason: "no pipeline run for this branch", at: "t", epoch: 1 },
});

// local_skip switches the whole local pipeline off, so every validation stage
// is skipped - but push and PR still happen, by hand, which is why that box is
// NOT skipped and why the CI cell beside it carries real checks.
const localCells = timerCells(withSkips({ local: true, ci: false }));
STEPS.forEach((s, i) => {
  const want = LOCAL_SKIP_STAGES.has(s.key) ? "skipped" : "by hand";
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
assert_contains "$bothout" "captain-authorised skip: local pipeline and CI test jobs" \
  "a task carrying both skips named only one of them"
ciout=$(render "$(snap "[$(agent_with sk3 "$(steps_all completed)" "$CISKIP")]")" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$ciout" "captain-authorised skip: CI test jobs" \
  "a CI-only skip was not disclosed"
assert_not_contains "$ciout" "local pipeline" "a CI-only skip claimed the local pipeline was skipped"
# Which STAGES each flag touches is asserted cell by cell above; this half is
# only about the sentence naming them.
pass "the skip is disclosed in plain words, naming exactly which halves were skipped"

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
skipcolour=$(render "$(snap "[$(agent_with sk4 '[]' "$LOCALSKIP")]")" |
  grep -o $'\x1b\\[94m' | head -1)
[ -n "$skipcolour" ] || fail "a skipped stage is not drawn in its own colour"
pending_only=$(render "$(snap "[$(agent_with sk5 "$(steps_all pending)")]")")
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

# --- the drill-in, and the way back, are stated on screen --------------------

assert_contains "$plainoff" "pipeline detail" "the key line does not offer the pipeline drill-in"
assert_contains "$plainoff" "ctrl-c back" "the key line does not say how to come back from the drill-in"
out=$(setsid node "$TUI" --watch --cols 200 --rows 60 --tick 0 \
  --detail-hint 'd: the pipeline, esc to return' <<<"$WITHOFF" 2>/dev/null |
  sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$out" "esc to return" "--detail-hint did not survive the flag path"
assert_not_contains "$out" "ctrl-c back" "--detail-hint did not replace the default"
pass "the drill-in key and its way back are on screen, and the caller owns the wording"

out=$(node "$TUI" --detail-cmd 'true' <<<"$WITHOFF" 2>&1); rc=$?
expect_code 2 $rc "--detail-cmd outside --watch must be a usage error"
assert_contains "$out" "--watch" "the usage error did not name the flag it needs"
out=$(node "$TUI" --detail-hint 'x' <<<"$WITHOFF" 2>&1); rc=$?
expect_code 2 $rc "--detail-hint outside --watch must be a usage error"
pass "the drill-in flags are refused outside watch mode, like the others"

# --- every tracked .mjs stays syntactically valid ---------------------------
#
# bin/fm-lint.sh covers bin/*.sh, bin/backends/*.sh and tests/*.sh only, so no
# .mjs file has a lint owner. This is the cheap mechanical floor for them.

for f in "$ROOT"/bin/*.mjs; do
  [ -e "$f" ] || continue
  node --check "$f" || fail "node --check failed for $f"
done
pass "every tracked bin/*.mjs passes node --check"
