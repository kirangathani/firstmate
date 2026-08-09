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

# --- every tracked .mjs stays syntactically valid ---------------------------
#
# bin/fm-lint.sh covers bin/*.sh, bin/backends/*.sh and tests/*.sh only, so no
# .mjs file has a lint owner. This is the cheap mechanical floor for them.

for f in "$ROOT"/bin/*.mjs; do
  [ -e "$f" ] || continue
  node --check "$f" || fail "node --check failed for $f"
done
pass "every tracked bin/*.mjs passes node --check"
