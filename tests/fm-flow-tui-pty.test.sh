#!/usr/bin/env bash
# Behavior tests that drive the fleet pipeline view through a REAL terminal.
#
# Every other assertion about this renderer calls render() directly, which is
# the right boundary for what it draws and no boundary at all for what happens
# when a key is pressed. The keyboard path only exists in watch mode: it opens
# /dev/tty, puts it in raw mode, and runs a command with the selected agent in
# its environment. None of that is reachable without a controlling terminal, so
# the parts of this view the captain actually touches had no test.
#
# The harness is a pseudo-terminal from python3's own `pty`, which is already on
# every machine that runs this suite. `node-pty` is deliberately not introduced:
# a dependency for one test file is a worse trade than twenty lines of stdlib.
#
# The child's stdin is reopened onto the snapshot FILE after the fork, because
# the two channels are separate by design (docs/flow-tui.md): the document
# arrives on stdin and the keys come from /dev/tty, which the fork has already
# made the slave side of this pty.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TUI="$ROOT/bin/fm-flow-tui.mjs"
TMP_ROOT=$(fm_test_tmproot fm-flow-tui-pty)
mkdir -p "$TMP_ROOT"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
python3 -c 'import pty' 2>/dev/null || { echo "skip: python3 has no pty module"; exit 0; }

# Where each PR cell is, from the renderer's own layout. Stdin is /dev/null for
# the reason tests/fm-flow-tui.test.sh states at its own probe: importing this
# module by path runs its main(), which otherwise waits on stdin forever.
read -r PR_CELL CI_CELL <<EOF
$(node --input-type=module -e \
  'const m = await import(process.argv[1]); process.stdout.write([...m.PR_CELLS].sort((a,b)=>a-b).join(" "))' \
  "$TUI" 2>/dev/null </dev/null)
EOF
[ -n "$PR_CELL" ] && [ -n "$CI_CELL" ] || fail "the renderer states no PR cells to drive"

PR_URL="https://github.com/kirangathani/firstmate/pull/126"

cat >"$TMP_ROOT/drive.py" <<'PY'
"""Run the viewer on a pty, send keys, return what reached the screen.

argv: <snapshot-file> <tui> <marker-dir> <keys> -- <extra tui args...>
`keys` is a comma-separated list of right/enter/quit.
"""
import os, pty, select, sys, time

snap, tui, markers, keys = sys.argv[1:5]
extra = sys.argv[6:] if len(sys.argv) > 5 else []
KEY = {"right": b"\x1b[C", "left": b"\x1b[D", "down": b"\x1b[B",
       "enter": b"\r", "quit": b"q"}

pid, fd = pty.fork()
if pid == 0:
    # The fork made the slave our controlling terminal, which is what the
    # viewer opens as /dev/tty for keys. stdin is then free to be the document.
    os.dup2(os.open(snap, os.O_RDONLY), 0)
    os.environ["TERM"] = "xterm-256color"
    os.execvp("node", ["node", tui, "--watch", "--cols", "200", "--rows", "60",
                       "--tick", "0"] + extra)

seen = b""
def pump(until, limit=15.0):
    global seen
    end = time.time() + limit
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            seen += chunk
        if until and until in seen:
            return True
    return False

pump(b"fleet pipeline", 15.0)
for k in keys.split(","):
    if not k:
        continue
    os.write(fd, KEY[k])
    # One frame's worth. The viewer repaints on every key, so this is enough
    # for the effect of that key to have reached the screen and for a command
    # it launched to have been started.
    pump(None, 0.6)
# A command the viewer ran in the background needs a moment to land its marker.
deadline = time.time() + 8
while time.time() < deadline and not os.listdir(markers):
    pump(None, 0.3)
os.write(fd, KEY["quit"])
pump(None, 1.0)
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
os.waitpid(pid, 0)
sys.stdout.buffer.write(seen)
PY

snapshot() {  # <agents-json> -> file
  local f="$TMP_ROOT/snap.$$.$RANDOM.json"
  jq -n --argjson agents "$1" '{
    schema:"fm-flow-snapshot.v2", generated:"2026-09-24T10:15:00Z",
    generated_epoch:1790000000, fm_home:"/home/x/firstmate", agents:$agents
  }' >"$f"
  printf '%s\n' "$f"
}

ship() {  # <id> <pr-json> -> one agent
  jq -n --arg id "$1" --argjson pr "$2" '{
    id:$id, branch:("fm/"+$id), project:"/p/firstmate", worktree:"/wt",
    window:("firstmate:fm-"+$id), kind:"ship", mode:"no-mistakes", pipeline:true,
    run_number:3, endpoint_alive:true, captain_driving:false, pr:$pr,
    collection:{ok:true,reason:""},
    run:{present:true,id:"01K",status:"running"},
    steps:[{step:"building",status:"completed",findings:0,duration_ms:1000}],
    active_steps:[],
    ci:{collection:{ok:true,reason:""},checks:[],total:12,passed:12,failed:0,
        pending:0,skipped:0,excused:0,excused_authority:[],head:"abc1234",
        pr_state:"OPEN",superseded:null}
  }'
}

# `right` this many times moves the stage cursor from the head (-1) onto cell N.
rights() {  # <cell-index>
  local n=$(( $1 + 1 )) out="" i
  for ((i = 0; i < n; i++)); do out="$out,right"; done
  printf '%s\n' "${out#,}"
}

# The two commands the viewer is given. `$FM_FLOW_PR` must survive THIS shell
# untouched: it is expanded by the child the viewer launches, and that the
# viewer tells that child the right row is the whole thing under test.
# shellcheck disable=SC2016
pr_cmd() { printf 'printf "%%s" "$FM_FLOW_PR" > %s/pr' "$1"; }
win_cmd() { printf 'printf window > %s/window' "$1"; }

drive() {  # <snapshot-file> <keys> <marker-dir> [tui args...]
  local snap=$1 keys=$2 markers=$3
  shift 3
  mkdir -p "$markers"
  python3 "$TMP_ROOT/drive.py" "$snap" "$TUI" "$markers" "$keys" -- "$@" 2>/dev/null
}

# --- enter on a PR cell runs the PR command, with that row's own url ---------

SNAP=$(snapshot "[$(ship alpha "$(jq -n --arg u "$PR_URL" '{url:$u,number:126}')")]")
M="$TMP_ROOT/m1"
out=$(drive "$SNAP" "$(rights "$PR_CELL"),enter" "$M" \
  --open-pr-cmd "$(pr_cmd "$M")" --open-cmd "$(win_cmd "$M")")
[ -f "$M/pr" ] || fail "enter on the push+PR cell did not run the PR command"
[ "$(cat "$M/pr")" = "$PR_URL" ] || fail "the PR command was not told this row's own PR url"
[ ! -f "$M/window" ] || fail "enter on the push+PR cell also opened the worker's window"
pass "enter on the push+PR cell runs the PR command with that row's own PR url, in a real terminal"

M="$TMP_ROOT/m2"
out=$(drive "$SNAP" "$(rights "$CI_CELL"),enter" "$M" \
  --open-pr-cmd "$(pr_cmd "$M")" --open-cmd "$(win_cmd "$M")")
[ -f "$M/pr" ] || fail "enter on the GITHUB CI cell did not run the PR command"
[ ! -f "$M/window" ] || fail "enter on the GITHUB CI cell also opened the worker's window"
pass "enter on the GITHUB CI cell opens the same PR, because those checks are that PR's"

# --- enter anywhere else still opens the worker's window ---------------------

M="$TMP_ROOT/m3"
out=$(drive "$SNAP" "enter" "$M" \
  --open-pr-cmd "$(pr_cmd "$M")" --open-cmd "$(win_cmd "$M")")
[ -f "$M/window" ] || fail "enter with the cursor on the head stopped opening the worker's window"
[ ! -f "$M/pr" ] || fail "enter with the cursor on the head opened the PR"
pass "enter with the cursor anywhere but a PR cell still opens the worker's window"

# --- a row with no PR says so, and runs nothing ------------------------------
#
# The failure this guards is silence: a key that looks like it did something
# and did not is worse than one that says it cannot.

NOPR=$(snapshot "[$(ship beta '{"url":null,"number":null}')]")
M="$TMP_ROOT/m4"
out=$(drive "$NOPR" "$(rights "$PR_CELL"),enter" "$M" \
  --open-pr-cmd "$(pr_cmd "$M")" --open-cmd "$(win_cmd "$M")")
[ ! -f "$M/pr" ] || fail "a row with no PR still ran the PR command"
[ ! -f "$M/window" ] || fail "a row with no PR fell back to opening the window"
plain=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
assert_contains "$plain" "no PR recorded for this task yet" \
  "a row with no PR did not say so on the screen the captain was looking at"
pass "a row with no PR says so on screen and runs nothing, rather than swallowing the key"
