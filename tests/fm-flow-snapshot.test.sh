#!/usr/bin/env bash
# Behavior tests for the per-agent pipeline snapshot behind the fleet flow view.
#
# The fixtures below are EXACT bytes captured from the real tools on
# 2026-08-08 against no-mistakes v1.37.0 (78e4dcb) and kirangathani/firstmate
# PR 25, not hand-written approximations. That distinction has bitten this repo
# before: every composer fixture once carried an ASCII space where claude emits
# U+00A0, which hid a reproducible bin/fm-send.sh failure behind a green suite
# (docs/herdr-backend.md, 2026-07-30).
#
# Capture commands, for refreshing them:
#   no-mistakes axi status --run 01KZETHEHPT5RQFB14A83FMZCK
#   no-mistakes axi status --run 01KZGM44YAB57YWGBN0E0XFZF4
#   gh pr view 25 --repo kirangathani/firstmate --json statusCheckRollup
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-flow-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-snapshot)
# fm_test_tmproot registers its cleanup trap inside the command substitution's
# own subshell, so the directory is already gone by the time the path is
# returned. Siblings survive this only because they mkdir their subdirectories
# afterwards; this file writes at the root, so it recreates it explicitly.
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; exit 0; }

# A real directory, created here rather than a path that happens to exist on one
# machine. The collector now runs `no-mistakes axi status --run` from the task's
# own project - that command resolves the repository from its working directory -
# so a fixture project that does not exist is a fixture whose run cannot be read
# at all. This used to be a hardcoded absolute path, which existed on the author's
# machine and on no CI runner, and every assertion about a step reaching the wire
# failed there and nowhere else.
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT"
# Physically resolved, because the cwd probe below compares against `pwd -P` and
# a temp root reached through a symlink would otherwise never match.
PROJECT=$(cd "$PROJECT" && pwd -P)

# --- captured fixtures ------------------------------------------------------

cat > "$TMP_ROOT/axi-running.txt" <<'TOON'
run:
  id: "01KZETHEHPT5RQFB14A83FMZCK"
  branch: fm/eager-dispatch-e2
  status: running
  head: bb73f233
  pr: "https://github.com/kirangathani/firstmate/pull/25"
  findings: 2 info
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,22
    rebase,completed,0,981
    review,completed,0,176257
    test,completed,1,249567
    document,completed,1,149799
    lint,completed,0,1127597
    push,completed,0,2411
    pr,completed,0,36162
    ci,running,0,0
  active_steps[3]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,18h32m,"37s ago: log: warning: could not check CI: gh pr checks: exit status 1","",starting
    review,running,2w3d,"","",starting
    document,running,12m,"","",starting
TOON

cat > "$TMP_ROOT/axi-failed.txt" <<'TOON'
run:
  id: "01KZGM44YAB57YWGBN0E0XFZF4"
  branch: fm/arm-lock-gate-q4
  status: failed
  head: 653a676f
  findings: "4 awaiting, 3 auto-fix"
  steps[9]{step,status,findings,duration_ms}:
    intent,skipped,0,6
    rebase,completed,0,811
    review,failed,7,444127
    test,pending,0,0
    document,pending,0,0
    lint,pending,0,0
    push,pending,0,0
    pr,pending,0,0
    ci,pending,0,0
outcome: failed
error: "step review failed: agent fix: claude start: fork/exec /home/kiran/.local/bin/claude: argument list too long"
TOON

# Two workflows carry a check of the SAME name ("CI testing waiver"), which is
# why the rollup is keyed on workflow plus name rather than name alone.
#
# The last three entries are the two shapes that made these counts disagree with
# `gh pr checks`, both captured from real PRs on 2026-08-09:
#   - PR 40 held TWO attempts of "PR must be raised via no-mistakes" after a
#     re-run. Counting both reported 11/13 with two failures where gh reports
#     10/11 with one, so the older attempt must be superseded, not counted.
#   - PR 33's "Repo invariants" was IN_PROGRESS while still carrying the SUCCESS
#     conclusion of its previous attempt. Reading the conclusion without the
#     status put it in the passed AND the pending bucket, 8+3+1 over 11 checks.
cat > "$TMP_ROOT/ci-rollup.json" <<'JSON'
{"statusCheckRollup":[
{"__typename":"CheckRun","name":"CI testing waiver","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},
{"__typename":"CheckRun","name":"CI testing waiver","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"Require no-mistakes"},
{"__typename":"CheckRun","name":"Lint shell scripts","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},
{"__typename":"CheckRun","name":"Behavior tests (shard 1)","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI"},
{"__typename":"CheckRun","name":"Behavior tests (shard 2)","status":"IN_PROGRESS","conclusion":"","workflowName":"CI"},
{"__typename":"CheckRun","name":"PR must be raised via no-mistakes","status":"COMPLETED","conclusion":"FAILURE","workflowName":"Require no-mistakes","startedAt":"2026-08-09T11:49:46Z"},
{"__typename":"CheckRun","name":"PR must be raised via no-mistakes","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"Require no-mistakes","startedAt":"2026-08-09T11:59:26Z"},
{"__typename":"CheckRun","name":"Repo invariants","status":"IN_PROGRESS","conclusion":"SUCCESS","workflowName":"CI","startedAt":"2026-08-09T12:15:59Z"}
]}
JSON

# --- fixture no-mistakes database -------------------------------------------
# Schema copied from the live database (sqlite3 state.sqlite '.schema runs'),
# trimmed to the columns this script reads plus the keys they depend on.

NM_DB="$TMP_ROOT/state.sqlite"
sqlite3 "$NM_DB" <<SQL
CREATE TABLE repos (
  id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL,
  fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);
CREATE TABLE runs (
  id TEXT PRIMARY KEY, repo_id TEXT NOT NULL REFERENCES repos(id), branch TEXT NOT NULL,
  head_sha TEXT NOT NULL, base_sha TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
  pr_url TEXT, error TEXT, awaiting_agent_since INTEGER,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
INSERT INTO repos VALUES ('repo1','$PROJECT','git@github.com:x/y.git',NULL,'main',1000);
INSERT INTO runs VALUES
  ('01KZETHEHPT5RQFB14A83FMZCK','repo1','fm/eager-dispatch-e2','bb73f233','base','running',NULL,NULL,NULL,2000,2500),
  ('01KZGM44YAB57YWGBN0E0XFZF4','repo1','fm/arm-lock-gate-q4','653a676f','base','failed',NULL,NULL,NULL,3000,3500),
  ('01KZOLDOLDOLDOLDOLDOLDOLDX','repo1','fm/arm-lock-gate-q4','aaaaaaa','base','completed',NULL,NULL,NULL,1500,1600),
  ('01KZWEDGEDWEDGEDWEDGEDWEDG','repo1','fm/stale-runner-s9','ccccccc','base','running',NULL,NULL,NULL,500,600);
SQL

# --- fake tools -------------------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
# The real binary writes its version-update banner to stderr, so stdout stays
# clean TOON. Reproduced here so a parser that wrongly reads stderr would fail.
printf 'A new version of no-mistakes is available\n' >&2
run=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--run" ] && run=\$a
  prev=\$a
done
case "\$run" in
  01KZETHEHPT5RQFB14A83FMZCK) cat "$TMP_ROOT/axi-running.txt" ;;
  01KZGM44YAB57YWGBN0E0XFZF4) cat "$TMP_ROOT/axi-failed.txt" ;;
  01KZWEDGEDWEDGEDWEDGEDWEDG)
    # The real binary prints its diagnosis on STDOUT; stderr carries only the
    # version banner, which every successful call writes too.
    printf 'error: could not open the run database\n'
    exit 1 ;;
  *) exit 1 ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
cat "$TMP_ROOT/ci-rollup.json"
SH
# A worker with no pipeline carries a state read through the REAL
# bin/fm-crew-state.sh, so that reader's own pane primitives have to resolve.
# This is the same fake tmux tests/fm-crew-state.test.sh drives it with: an
# endpoint that exists, an agent process behind it, and a busy banner under
# FM_FAKE_BUSY.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for arg in "$@"; do
      if [ "$arg" = '#{pane_current_command}' ]; then
        printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-claude}"
        exit 0
      fi
    done
    printf '%%1\n' ;;
  list-panes)
    _t=""; _p=""
    for _a in "$@"; do [ "$_p" = "-t" ] && _t="$_a"; _p="$_a"; done
    printf '%s\n' "${_t##*:}" ;;
  capture-pane)
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/gh" "$FAKEBIN/tmux"

# --- fixture fleet document -------------------------------------------------
#
# The live home behind it. bin/fm-crew-state.sh reads each worker's own
# state/<id>.meta and refuses to read a worktree that is not there, so the two
# non-ship workers get real records over real directories rather than a canned
# verdict: what this file asserts is then the reader's actual bytes.
LIVE_HOME="$TMP_ROOT/home-live"
mkdir -p "$LIVE_HOME/state" "$TMP_ROOT/wt/scout" "$TMP_ROOT/wt/sm"
printf 'window=fm:5\nworktree=%s\nproject=%s\nkind=scout\nharness=claude\n' \
  "$TMP_ROOT/wt/scout" "$PROJECT" > "$LIVE_HOME/state/some-scout-x1.meta"
printf 'window=fm:6\nworktree=%s\nproject=%s\nkind=secondmate\nharness=claude\n' \
  "$TMP_ROOT/wt/sm" "$PROJECT" > "$LIVE_HOME/state/idle-sm-z2.meta"

make_fleet() {  # <file>
  jq -n --arg p "$PROJECT" --arg h "$LIVE_HOME" --arg w "$TMP_ROOT/wt" '{tasks:[
    {id:"eager-dispatch-e2",kind:"ship",mode:"no-mistakes",project:$p,
     paths:{worktree:{path:"/wt/1"}},endpoint:{target:"fm:1",exists:true},
     pr:{url:"https://github.com/kirangathani/firstmate/pull/25"}},
    {id:"arm-lock-gate-q4",kind:"ship",mode:"no-mistakes",project:$p,
     paths:{worktree:{path:"/wt/2"}},endpoint:{target:"fm:2",exists:true},
     pr:{url:null}},
    {id:"stale-runner-s9",kind:"ship",mode:"no-mistakes",project:$p,
     paths:{worktree:{path:"/wt/3"}},endpoint:{target:"fm:3",exists:false},
     pr:{url:null}},
    {id:"no-run-yet-n1",kind:"ship",mode:"no-mistakes",project:$p,
     paths:{worktree:{path:"/wt/4"}},endpoint:{target:"fm:4",exists:true},
     pr:{url:null}},
    {id:"some-scout-x1",kind:"scout",mode:"local-only",project:$p,
     paths:{worktree:{path:($w+"/scout")},
            meta:{path:($h+"/state/some-scout-x1.meta"),present:true}},
     endpoint:{target:"fm:5",exists:true},pr:{url:null}},
    {id:"idle-sm-z2",kind:"secondmate",mode:"",project:$p,
     paths:{worktree:{path:($w+"/sm")},
            meta:{path:($h+"/state/idle-sm-z2.meta"),present:true}},
     endpoint:{target:"fm:6",exists:true},pr:{url:null}},
    {id:"gone-scout-d4",kind:"scout",mode:"local-only",project:$p,
     paths:{worktree:{path:"/wt/7"}},endpoint:{target:"fm:7",exists:false},
     pr:{url:null}}
  ]}' > "$1"
}
make_fleet "$TMP_ROOT/fleet.json"

run_snapshot() {  # <extra args...>
  PATH="$FAKEBIN:$PATH" \
  FM_HOME="${FM_HOME:-$LIVE_HOME}" \
  FM_FAKE_BUSY=1 \
  FM_FLOW_SNAPSHOT_DB="$NM_DB" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/fleet.json" \
  FM_FLOW_SNAPSHOT_NOW_EPOCH=10000 \
    "$SNAPSHOT" "$@"
}

OUT="$TMP_ROOT/out.json"
run_snapshot --no-ci > "$OUT" 2>"$TMP_ROOT/err.txt"
expect_code 0 $? "snapshot exits clean"
[ -s "$OUT" ] || fail "snapshot produced no output"

# --- schema -----------------------------------------------------------------

got=$(jq -r '.schema' "$OUT")
[ "$got" = "fm-flow-snapshot.v2" ] || fail "wrong schema id: $got"
pass "emits the fm-flow-snapshot.v2 schema id"

# --- an agent is a task with a LIVE worker behind it, of ANY kind ------------
#
# `state/<id>.meta` outlives the window it names: firstmate stands a finished
# worker down by killing the window, and the record stays for recovery to read.
# Enumerating records alone put finished workers on screen as though they were
# running - the captain's second run showed 14 agents against two live windows.
# A task whose recorded endpoint no longer resolves is named in `omitted` and
# drawn nowhere.
#
# Liveness is the WHOLE membership test, and it was not always: the shipped
# collector additionally required kind=ship, so a live scout was filtered into
# a count the renderer drew as one dim word. Both directions are pinned here,
# because a change that only draws the live worker and forgets the dead one
# puts a finished worker back on screen beside running ones.
got=$(jq -r '[.agents[].id] | sort | join(",")' "$OUT")
[ "$got" = "arm-lock-gate-q4,eager-dispatch-e2,idle-sm-z2,no-run-yet-n1,some-scout-x1" ] \
  || fail "unexpected agent set: $got"
pass "every task with a live endpoint is an agent, whatever its kind"

got=$(jq -r '[.omitted[].id] | sort | join(",")' "$OUT")
[ "$got" = "gone-scout-d4,stale-runner-s9" ] || fail "unexpected omitted set: $got"
got=$(jq -r '.omitted[] | select(.id=="stale-runner-s9") | .reason' "$OUT")
assert_contains "$got" "no longer exists" "the omission gave no reason"
# The dead SCOUT is the direction the shipped collector dropped entirely: it was
# in neither the agent list, nor `omitted`, nor `out_of_scope`.
got=$(jq -r '.omitted[] | select(.id=="gone-scout-d4") | .kind' "$OUT")
[ "$got" = "scout" ] || fail "a held-back non-ship record lost its kind: $got"
pass "a task whose recorded endpoint is gone is named in omitted, not drawn as an agent"

# `out_of_scope` was the field naming live workers the view refused to draw.
# The view draws them, so the field is gone rather than left empty: an empty
# array would mean the opposite of what it used to.
got=$(jq -r 'has("out_of_scope")' "$OUT")
[ "$got" = "false" ] || fail "out_of_scope survived into v2"
pass "out_of_scope is removed rather than emitted empty"

# The record is still readable on request - the point is that it is not drawn
# beside running workers by default.
got=$(run_snapshot --no-ci --include-dead | jq -r '[.agents[].id] | sort | join(",")')
[ "$got" = "arm-lock-gate-q4,eager-dispatch-e2,gone-scout-d4,idle-sm-z2,no-run-yet-n1,some-scout-x1,stale-runner-s9" ] \
  || fail "--include-dead did not restore the dead records: $got"
got=$(run_snapshot --no-ci --include-dead | jq -r '.omitted | length')
[ "$got" = 0 ] || fail "--include-dead still omitted $got task(s)"
pass "--include-dead puts the gone-worker records back for diagnosis"

# --- a worker with no pipeline carries a state, and no pipeline --------------
#
# Being drawn is what liveness earns; what kind decides is only what the row
# CARRIES. Nine permanently empty boxes over a scout would be an invented
# journey, so the collector states `pipeline:false` and emits no steps, no run
# and no checks for it.
got=$(jq -r '[.agents[] | "\(.id):\(.pipeline)"] | sort | join(" ")' "$OUT")
[ "$got" = "arm-lock-gate-q4:true eager-dispatch-e2:true idle-sm-z2:false no-run-yet-n1:true some-scout-x1:false" ] \
  || fail "pipeline flags wrong: $got"
pass "pipeline is stated per agent rather than left to be inferred from the kind"

got=$(jq -r '.agents[] | select(.id=="some-scout-x1")
  | "\(.steps|length)/\(.active_steps|length)/\(.run.present)/\(.ci.checks|length)"' "$OUT")
[ "$got" = "0/0/false/0" ] || fail "a worker with no pipeline was given one: $got"
# collection.ok stays TRUE: nothing failed to read. A false there is what the
# renderer draws as `unreadable`, and a scout is not unreadable, it is pipeline-
# less. The two are different claims.
got=$(jq -r '.agents[] | select(.id=="some-scout-x1") | .collection.ok' "$OUT")
[ "$got" = "true" ] || fail "a pipeline-less worker was reported as an unreadable one"
pass "no run, no steps and no checks for a worker that has none of them"

# Ordered pipeline-first, so the wire order is the draw order and the renderer
# needs no sort of its own.
got=$(jq -r '[.agents[].pipeline] | join(",")' "$OUT")
[ "$got" = "true,true,true,false,false" ] || fail "agents not ordered pipeline-first: $got"
pass "pipeline agents are emitted before the compact ones"

# The state is READ, through bin/fm-crew-state.sh - the fleet's own owner of a
# crew's current state - and not derived here. These are that reader's real
# bytes over real records: the scout's pane is busy, so it reports working from
# the pane; the second mate's is skipped by that reader on purpose (AGENTS.md
# section 8: a quiet second mate is healthy), so it reports unknown with no
# source, which the renderer draws as idle rather than as a fault.
got=$(jq -r '.agents[] | select(.id=="some-scout-x1")
  | "\(.state.ok)/\(.state.value)/\(.state.source)/\(.state.detail)"' "$OUT")
[ "$got" = "true/working/pane/harness busy" ] || fail "scout state not read through the owner: $got"
got=$(jq -r '.agents[] | select(.id=="idle-sm-z2")
  | "\(.state.ok)/\(.state.value)/\(.state.source)"' "$OUT")
[ "$got" = "true/unknown/none" ] || fail "second mate state not read through the owner: $got"
# A pipeline agent pays none of that cost and carries no state at all.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .state' "$OUT")
[ "$got" = "null" ] || fail "a pipeline agent was given a state reading: $got"
pass "a compact agent's state comes from bin/fm-crew-state.sh, split into its own fields"

# --- the defect this script exists to fix -----------------------------------
#
# `no-mistakes axi status` without --run answers for the repository's most
# recent run regardless of which worktree it is called from, so a collector
# built on it draws one identical pipeline across every row. Each agent must
# resolve to the run for its OWN fm/<id> branch.

a=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .run.id' "$OUT")
b=$(jq -r '.agents[] | select(.id=="arm-lock-gate-q4") | .run.id' "$OUT")
[ "$a" = "01KZETHEHPT5RQFB14A83FMZCK" ] || fail "eager-dispatch resolved to $a"
[ "$b" = "01KZGM44YAB57YWGBN0E0XFZF4" ] || fail "arm-lock-gate resolved to $b"
[ "$a" != "$b" ] || fail "two branches collapsed onto one run"
pass "each agent resolves the run for its own fm/<id> branch"

# The branch has an older completed run as well as the newest failed one.
# Picking the newest by created_at is what keeps a finished attempt from
# masking the current one.
got=$(jq -r '.agents[] | select(.id=="arm-lock-gate-q4") | .run.status' "$OUT")
[ "$got" = "failed" ] || fail "expected the newest run for the branch, got status $got"
pass "resolves the newest run when a branch has several"

# --- status passthrough -----------------------------------------------------
#
# Mapping a status onto a display state belongs to the renderer, which asserts
# that mapping exhaustively. The snapshot must not flatten an unfamiliar status
# on the way through: `skipped` is a real status the five-state model in the
# design report never enumerated.

got=$(jq -r '.agents[] | select(.id=="arm-lock-gate-q4") | .steps[] | select(.step=="intent") | .status' "$OUT")
[ "$got" = "skipped" ] || fail "status not passed through verbatim: $got"
pass "passes unfamiliar step statuses through unmapped"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .steps | length' "$OUT")
[ "$got" = 10 ] || fail "expected 10 steps, got $got"
# The tool's own nine, in its own order, unchanged - that is what this assertion
# has always been for and its name stays exactly as it was.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | [.steps[] | select(.step != "building") | .step] | join(",")' "$OUT")
[ "$got" = "intent,rebase,review,test,document,lint,push,pr,ci" ] || fail "step order wrong: $got"
pass "carries all nine steps in pipeline order"

# The worker's building phase sits in front of them, so the row covers the whole
# of a task's life rather than only the part the pipeline owns.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .steps[0].step' "$OUT")
[ "$got" = "building" ] || fail "building is not the first step of the row: $got"
pass "the building phase leads the row, in front of the pipeline's own steps"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .steps[] | select(.step=="lint") | .duration_ms' "$OUT")
[ "$got" = 1127597 ] || fail "duration lost: $got"
pass "preserves step durations and finding counts"

# active_steps carries a quoted field containing commas; splitting on every
# comma rather than on unquoted ones truncates it.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[0].last_activity' "$OUT")
assert_contains "$got" "gh pr checks: exit status 1" "active_steps last_activity truncated at an embedded comma"
pass "parses quoted active_steps fields containing commas"

# A RUNNING step's steps[] duration_ms is 0 until it ends - the fixture above
# carries `ci,running,0,0` - so the humanised active_for is the only elapsed the
# tool states for it. It is parsed to milliseconds HERE, on the collector side
# of the seam, because the renderer performs no outside reads and may not invent
# a time of its own.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[0].active_for' "$OUT")
[ "$got" = "18h32m" ] || fail "active_for lost: $got"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[0].active_ms' "$OUT")
[ "$got" = 66720000 ] || fail "18h32m did not parse to milliseconds: $got"
pass "a running step's elapsed reaches the wire as milliseconds"

# The parse is validated END TO END, so a value carrying a unit it does not know
# emits null and the viewer says nothing. Summing only the tokens it recognised
# would report the fixture's `2w3d` as three days - a materially understated
# time, and a guessed time on this view is worse than no time at all.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[1].active_for' "$OUT")
[ "$got" = "2w3d" ] || fail "the unparseable active_for was not passed through verbatim: $got"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[1].active_ms' "$OUT")
[ "$got" = "null" ] || fail "an unrecognised active_for shape parsed to a number: $got"
pass "an active_for shape the parser does not recognise reaches the wire as null"

# --- failure renders as unknown, never as pending ---------------------------
#
# A read that failed and a step that has not started are different claims. If a
# timed-out collection emitted pending steps, the view would state as fact that
# the pipeline has not begun.

# Read through --include-dead: the only fixture task with a failing axi read is
# also the one whose endpoint is gone, and the default view no longer draws it.
DEADOUT="$TMP_ROOT/out-include-dead.json"
run_snapshot --no-ci --include-dead > "$DEADOUT" 2>/dev/null

ok=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .collection.ok' "$DEADOUT")
[ "$ok" = "false" ] || fail "failed axi read reported collection.ok=$ok"
n=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .steps | length' "$DEADOUT")
[ "$n" = 0 ] || fail "failed collection still emitted $n steps"
pass "a failed read reports collection.ok false and emits no steps"

# A task with no run at all is a distinct third case: collection succeeded and
# the answer is genuinely "nothing has started".
p=$(jq -r '.agents[] | select(.id=="no-run-yet-n1") | .run.present' "$OUT")
ok=$(jq -r '.agents[] | select(.id=="no-run-yet-n1") | .collection.ok' "$OUT")
[ "$p" = "false" ] || fail "no-run task reported run.present=$p"
[ "$ok" = "true" ] || fail "no-run task conflated with a failed read"
pass "no run yet is distinct from a failed read"

# --- the stale running row --------------------------------------------------
#
# runs.status records the last state written, not whether anything runs now. On
# the live host four rows read `running` with no update for five to nine days.
# The age must reach the renderer so a dead pipeline cannot be animated.

age=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .run.db_age_seconds' "$DEADOUT")
[ "$age" = 9400 ] || fail "expected db_age_seconds 9400, got $age"
alive=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .endpoint_alive' "$DEADOUT")
[ "$alive" = "false" ] || fail "endpoint liveness not carried through: $alive"
pass "carries run age and endpoint liveness so staleness cannot be hidden"

# --- CI rollup --------------------------------------------------------------

CIOUT="$TMP_ROOT/ci-out.json"
run_snapshot > "$CIOUT" 2>/dev/null
expect_code 0 $? "snapshot with CI exits clean"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .ci.total' "$CIOUT")
[ "$got" = 7 ] || fail "expected 7 checks from 8 rollup entries, got $got"
# Both same-named checks must survive: keying on name alone drops one.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | [.ci.checks[] | select(.name=="CI testing waiver")] | length' "$CIOUT")
[ "$got" = 2 ] || fail "duplicate check name collapsed: kept $got of 2"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | [.ci.checks[] | select(.name=="CI testing waiver") | .workflow] | sort | join(",")' "$CIOUT")
[ "$got" = "CI,Require no-mistakes" ] || fail "workflow not distinguishing same-named checks: $got"
pass "keys checks on workflow plus name so duplicates both survive"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | "\(.ci.passed)/\(.ci.failed)/\(.ci.pending)"' "$CIOUT")
[ "$got" = "4/1/2" ] || fail "rollup counts wrong (passed/failed/pending): $got"
pass "rolls up passed, failed, and pending counts"

# --- the counts must agree with `gh pr checks` ------------------------------
#
# That is the comparison the captain makes, so these are the two ways the
# rollup disagreed with it.

# A re-run leaves the earlier attempt in the rollup. The LATEST attempt of a
# workflow-plus-name is the verdict; counting the superseded one as well turned
# one failing check into two.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | [.ci.checks[] | select(.name=="PR must be raised via no-mistakes")] | length' "$CIOUT")
[ "$got" = 1 ] || fail "a superseded re-run was counted: kept $got attempts, want 1"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | .ci.checks[] | select(.name=="PR must be raised via no-mistakes") | .conclusion' "$CIOUT")
[ "$got" = "SUCCESS" ] || fail "kept the superseded attempt, not the latest: $got"
pass "a re-run supersedes its earlier attempt instead of being counted twice"

# Every class must PARTITION the checks. A check still running carries whatever
# conclusion its previous attempt left behind, and reading that without the
# status put it in two buckets at once. The sum is over all five classes: a
# class added without being counted here would go missing silently.
sum=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | .ci | (.passed + .failed + .pending + .skipped + .excused)' "$CIOUT")
tot=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .ci.total' "$CIOUT")
[ "$sum" = "$tot" ] || fail "buckets overlap or leak: class counts sum to $sum over $tot checks"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | .ci.checks[] | select(.name=="Repo invariants") | .verdict' "$CIOUT")
[ "$got" = "pending" ] || fail "a running check with a stale conclusion counted as $got"
pass "a check that has not completed is pending and nothing else"

# An agent with no PR must not be reported as having a clean CI result.
got=$(jq -r '.agents[] | select(.id=="arm-lock-gate-q4") | .ci.collection.ok' "$CIOUT")
[ "$got" = "false" ] || fail "agent without a PR reported a CI collection as ok"
pass "an agent with no PR reports no CI result rather than an empty pass"

# --- read-only --------------------------------------------------------------
#
# A viewer documented not to write is not a boundary. Hash the home before and
# after, including the fixture database, and require them identical.

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
printf 'x\n' > "$HOME_DIR/state/some.meta"
printf 'y\n' > "$HOME_DIR/data/backlog.md"
hash_tree() {  # <dir>
  { find "$1" -type f -exec cksum {} \; ; cksum "$NM_DB"; } | LC_ALL=C sort
}
before=$(hash_tree "$HOME_DIR")
FM_HOME="$HOME_DIR" run_snapshot >/dev/null 2>&1
after=$(hash_tree "$HOME_DIR")
[ "$before" = "$after" ] || fail "snapshot mutated state, data, or the no-mistakes database"
pass "leaves state, data, and the no-mistakes database byte-identical"

# Measured again over the home the COMPACT path reads, because that path calls
# a whole second script - bin/fm-crew-state.sh - per pipeline-less worker, and
# the read-only contract has to hold across it. The reader is documented
# side-effect free; this is what makes that a boundary rather than a claim.
before=$(hash_tree "$LIVE_HOME")
run_snapshot --no-ci >/dev/null 2>&1
after=$(hash_tree "$LIVE_HOME")
[ "$before" = "$after" ] || fail "reading a pipeline-less worker's state mutated the home it read"
pass "reading a compact worker's current state writes nothing"

# --- refusing to invent an empty fleet --------------------------------------
#
# fm-fleet-snapshot.sh can fail outright (it exceeds ARG_MAX at real fleet
# size). Emitting an empty agents array on that failure would read as "no work
# in flight", which is a false and much more dangerous claim than an error.

printf 'not json\n' > "$TMP_ROOT/broken.json"
out=$(PATH="$FAKEBIN:$PATH" FM_FLOW_SNAPSHOT_DB="$NM_DB" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/broken.json" "$SNAPSHOT" 2>&1)
rc=$?
expect_code 1 $rc "unreadable fleet document must fail loudly"
assert_contains "$out" "refusing to emit an empty fleet" "no explanation for the refusal"
pass "refuses to emit an empty fleet when the fleet read fails"

# --- targeted refresh -------------------------------------------------------

got=$(run_snapshot --no-ci --task eager-dispatch-e2 | jq -r '[.agents[].id] | join(",")')
[ "$got" = "eager-dispatch-e2" ] || fail "--task did not restrict the snapshot: $got"
pass "--task restricts the snapshot to one agent"

# --- the excused attestation check ------------------------------------------
#
# `PR must be raised via no-mistakes` cannot pass on a PR the pipeline did not
# raise, so it fails on every firstmate PR by construction and bin/fm-pr-merge.sh
# excuses it on exactly that authority. Counting it as a plain failure is what
# painted a permanent red over healthy PRs on the captain's screen 2026-08-09.
#
# The verdict is resolved through bin/fm-attestation-lib.sh, the same owner the
# merge gate reaches its verdict through, so the two cannot disagree - and the
# authority is what decides, never the name alone. Both directions are asserted.

ATT_HOME="$TMP_ROOT/att"
mkdir -p "$ATT_HOME/state" "$ATT_HOME/data" "$ATT_HOME/config"
{
  echo '# Projects'
  echo '- shipped [direct-PR] - a project whose PRs are raised without the pipeline (added 2026-08-09)'
  echo '- gated [no-mistakes] - a project whose PRs must come from the pipeline (added 2026-08-09)'
} > "$ATT_HOME/data/projects.md"

# Minimal task records: only the fields the excusal reads. The format they are
# written in is bin/fm-spawn.sh's, and tests/fm-spawn-testing-skip.test.sh holds
# the drift guard between what that script writes and what this one reads.
while IFS=' ' read -r task proj; do
  [ -n "$task" ] || continue
  printf 'window=fm:%s\nworktree=/wt/%s\nproject=/p/%s\nkind=ship\n' "$task" "$task" "$proj" \
    > "$ATT_HOME/state/$task.meta"
done <<'ROWS'
shipped-a1 shipped
gated-b2 gated
ROWS

cat > "$TMP_ROOT/att-rollup.json" <<'JSON'
{"statusCheckRollup":[
{"__typename":"CheckRun","name":"Lint shell scripts","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},
{"__typename":"CheckRun","name":"Behavior tests (shard 1)","status":"COMPLETED","conclusion":"SKIPPED","workflowName":"CI"},
{"__typename":"CheckRun","name":"PR must be raised via no-mistakes","status":"COMPLETED","conclusion":"FAILURE","workflowName":"Require no-mistakes"}
]}
JSON
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
cat "\${FM_TEST_ROLLUP:-$TMP_ROOT/ci-rollup.json}"
SH
chmod +x "$FAKEBIN/gh"

jq -n --arg h "$ATT_HOME" '{tasks:[
  {id:"shipped-a1",kind:"ship",mode:"direct-PR",project:"/p/shipped",
   paths:{worktree:{path:"/wt/1"},meta:{path:($h+"/state/shipped-a1.meta"),present:true}},
   endpoint:{target:"fm:1",exists:true},
   pr:{url:"https://github.com/o/r/pull/51"}},
  {id:"gated-b2",kind:"ship",mode:"no-mistakes",project:"/p/gated",
   paths:{worktree:{path:"/wt/2"},meta:{path:($h+"/state/gated-b2.meta"),present:true}},
   endpoint:{target:"fm:2",exists:true},
   pr:{url:"https://github.com/o/r/pull/52"}}
]}' > "$TMP_ROOT/att-fleet.json"

ATTOUT="$TMP_ROOT/att-out.json"
# Hashed across this run too, not only the earlier one: resolving the exemption
# reads a signing key, a project registry and a task record, and a viewer that
# is documented not to write is not a boundary until it is measured on the path
# that reads the most.
att_hash() { find "$ATT_HOME" -type f -exec cksum {} \; | LC_ALL=C sort; }
att_before=$(att_hash)
PATH="$FAKEBIN:$PATH" FM_HOME="$ATT_HOME" \
  FM_TEST_ROLLUP="$TMP_ROOT/att-rollup.json" \
  FM_FLOW_SNAPSHOT_DB="$TMP_ROOT/absent.sqlite" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/att-fleet.json" \
  "$SNAPSHOT" --json > "$ATTOUT" 2>/dev/null
expect_code 0 $? "the attestation snapshot exits clean"
[ "$att_before" = "$(att_hash)" ] ||
  fail "resolving the attestation exemption mutated the home it read"

got=$(jq -r '.agents[] | select(.id=="shipped-a1")
  | "\(.ci.failed)/\(.ci.excused)/\(.ci.passed)/\(.ci.skipped)"' "$ATTOUT")
[ "$got" = "0/1/1/1" ] ||
  fail "a direct-PR project's excused check was not moved out of failing (failed/excused/passed/skipped: $got)"
got=$(jq -r '.agents[] | select(.id=="shipped-a1") | .ci.excused_authority[0]' "$ATTOUT")
assert_contains "$got" "direct-PR" "the excusal did not record what authorised it"
pass "the one excusable check is counted as excused when an authority exists"

got=$(jq -r '.agents[] | select(.id=="gated-b2")
  | "\(.ci.failed)/\(.ci.excused)"' "$ATTOUT")
[ "$got" = "1/0" ] ||
  fail "the same red check was excused with no authority for it (failed/excused: $got)"
got=$(jq -r '.agents[] | select(.id=="gated-b2") | .ci.excused_authority | length' "$ATTOUT")
[ "$got" = 0 ] || fail "an unexcused check still recorded an authority"
pass "the same check with no authority behind it stays a failure"

# The name is matched by exact equality and taken from the merge gate's own
# owner, so a rename stops the exemption applying in the safe direction: the
# renamed check is not recognised, so it is not excused.
ATT_NAME=$(bash -c '. "'"$ROOT"'/bin/fm-attestation-lib.sh"; printf "%s" "$FM_ATTESTATION_CHECK_NAME"')
[ -n "$ATT_NAME" ] || fail "bin/fm-attestation-lib.sh names no excusable check"
assert_grep "$ATT_NAME" "$ROOT/.github/workflows/no-mistakes-required.yml" \
  "the excused name no longer matches the workflow job that reports it"
sed "s/$ATT_NAME/PR must be raised via the pipeline/" "$TMP_ROOT/att-rollup.json" \
  > "$TMP_ROOT/att-renamed.json"
got=$(PATH="$FAKEBIN:$PATH" FM_HOME="$ATT_HOME" \
  FM_TEST_ROLLUP="$TMP_ROOT/att-renamed.json" \
  FM_FLOW_SNAPSHOT_DB="$TMP_ROOT/absent.sqlite" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/att-fleet.json" \
  "$SNAPSHOT" --json 2>/dev/null |
  jq -r '.agents[] | select(.id=="shipped-a1") | "\(.ci.failed)/\(.ci.excused)"')
[ "$got" = "1/0" ] || fail "a differently-named red check was excused (failed/excused: $got)"
pass "only the exact excused name is excused; a renamed check stays a failure"

# --- the captain's testing skips reach the view ------------------------------
#
# Read from the task's own record and nothing else. A worker writes its status
# lines into this same directory, so the flag is disclosure-grade evidence, not
# authority - which is why it is read through the flags' own owner and not by a
# grep invented here.

printf 'local_skip=on\nci_skip=on\n' >> "$ATT_HOME/state/shipped-a1.meta"
got=$(PATH="$FAKEBIN:$PATH" FM_HOME="$ATT_HOME" \
  FM_TEST_ROLLUP="$TMP_ROOT/att-rollup.json" \
  FM_FLOW_SNAPSHOT_DB="$TMP_ROOT/absent.sqlite" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/att-fleet.json" \
  "$SNAPSHOT" --json 2>/dev/null |
  jq -r '.agents[] | "\(.id):\(.skips.local)/\(.skips.ci)"' | sort | tr '\n' ' ')
[ "$got" = "gated-b2:false/false shipped-a1:true/true " ] ||
  fail "the recorded testing skips did not reach the view: $got"
pass "a task's recorded testing skips reach the view, and an unflagged task's do not"

# --- the CI read must name the PR's OWN repository ---------------------------
#
# `gh pr view <n>` with no --repo resolves the repository from the process's
# working directory, and this view runs from the firstmate root while a task's
# PR belongs to that task's project. Measured 2026-09-07: an ELN PR 28 carrying
# four checks rendered as 11/11 because firstmate PR 28 is a merged, green,
# eleven-check PR of the same number.

cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$TMP_ROOT/gh-args.txt"
cat "\${FM_TEST_ROLLUP:-$TMP_ROOT/ci-rollup.json}"
SH
chmod +x "$FAKEBIN/gh"

jq -n --arg h "$ATT_HOME" '{tasks:[
  {id:"shipped-a1",kind:"ship",mode:"direct-PR",project:"/p/shipped",
   paths:{worktree:{path:"/wt/1"},meta:{path:($h+"/state/shipped-a1.meta"),present:true}},
   endpoint:{target:"fm:1",exists:true},
   pr:{url:"https://github.com/kirangathani/eln/pull/28"}}
]}' > "$TMP_ROOT/repo-fleet.json"

REPOOUT="$TMP_ROOT/repo-out.json"
: > "$TMP_ROOT/gh-args.txt"
PATH="$FAKEBIN:$PATH" FM_HOME="$ATT_HOME" \
  FM_FLOW_SNAPSHOT_DB="$TMP_ROOT/absent.sqlite" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/repo-fleet.json" \
  "$SNAPSHOT" --json > "$REPOOUT" 2>/dev/null
expect_code 0 $? "the cross-repository snapshot exits clean"
got=$(cat "$TMP_ROOT/gh-args.txt")
assert_contains "$got" "--repo kirangathani/eln" \
  "the CI read did not name the recorded link's own repository"
assert_contains "$got" "pr view 28" "the CI read did not ask for the recorded PR number"
pass "a PR link naming another repository is queried with --repo, not against the cwd repo"

got=$(jq -r '.agents[] | select(.id=="shipped-a1") | .pr.number' "$REPOOUT")
[ "$got" = 28 ] || fail "the PR number was not taken from the parsed link: $got"
pass "the PR number comes from the parsed link"

# A link the one parser refuses is NOT EVALUATED. Guessing a number off it is
# exactly how a query landed on another repository's PR of that number.
jq -n --arg h "$ATT_HOME" '{tasks:[
  {id:"shipped-a1",kind:"ship",mode:"direct-PR",project:"/p/shipped",
   paths:{worktree:{path:"/wt/1"},meta:{path:($h+"/state/shipped-a1.meta"),present:true}},
   endpoint:{target:"fm:1",exists:true},
   pr:{url:"https://example.invalid/kirangathani/eln/pull/28"}}
]}' > "$TMP_ROOT/badlink-fleet.json"

BADOUT="$TMP_ROOT/badlink-out.json"
: > "$TMP_ROOT/gh-args.txt"
PATH="$FAKEBIN:$PATH" FM_HOME="$ATT_HOME" \
  FM_FLOW_SNAPSHOT_DB="$TMP_ROOT/absent.sqlite" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/badlink-fleet.json" \
  "$SNAPSHOT" --json > "$BADOUT" 2>/dev/null
expect_code 0 $? "the unparseable-link snapshot exits clean"
got=$(jq -r '.agents[] | select(.id=="shipped-a1")
  | "\(.ci.collection.ok)/\(.ci.total)/\(.pr.number)"' "$BADOUT")
[ "$got" = "false/0/null" ] ||
  fail "an unparseable PR link was evaluated instead of reported unread: $got"
got=$(jq -r '.agents[] | select(.id=="shipped-a1") | .ci.collection.reason' "$BADOUT")
[ -n "$got" ] || fail "an unread CI cell carried no reason"
[ ! -s "$TMP_ROOT/gh-args.txt" ] || fail "an unparseable PR link still cost a gh query"
pass "an unparseable PR link yields an unread CI cell with a reason and no query"
# --- which LLM is doing the work --------------------------------------------
#
# Two different questions with two different machine records behind them, and
# neither may be answered from prose or from a config file's intention.
#
# The WORKER's model and effort are the fields bin/fm-spawn.sh wrote into the
# task's own state/<id>.meta at dispatch.
#
# A PIPELINE STEP's model is what the run actually launched that step's agent
# as, and the only machine record of it is the transcript Claude Code writes
# from the run's own worktree, in a directory whose name ends in the run's ULID.
# A session is attributed to the step whose active window its start falls in.
#
# The two records below are EXACT bytes, captured on 2026-09-07 from
#   ~/.claude/projects/-home-kiran--no-mistakes-worktrees-3b169b9eb68e-01M1VAGQM160X68A8GQS5YND1Z/
# by grepping each record out by its own "uuid" field:
#   grep -h -F '"uuid":"f0b24c05-6bc4-49e6-b2e2-4999061064f5"' <dir>/*.jsonl
#   grep -h -F '"uuid":"6f85f260-33ce-4cc0-83f6-48ea5617f2c7"' <dir>/*.jsonl
# Nothing is redacted: `.type`, `.message.model` and `.effort` are exactly what
# the parser reads, and the run id inside the captured `cwd` is what named the
# directory it came from.
#
# The synthetic record is written LAST on purpose. It is the newest assistant
# record in the file and it carries a `model`, so a parser that simply took the
# last one would report `<synthetic>` as the model.
#
# Only the FIRST line is generated rather than captured, and it must be: it is
# the record whose timestamp says when the session started, and attribution
# compares that against a window measured back from now. A captured absolute
# time would fall out of every window as the clock moved on and the test would
# start passing for the wrong reason. Its shape is the queue-operation record a
# real session file opens with.

MODEL_HOME="$TMP_ROOT/home-model"
TRANSCRIPTS="$TMP_ROOT/transcripts"
RUN_WITH_TRANSCRIPT=01KZETHEHPT5RQFB14A83FMZCK
MODEL_DIR="$TRANSCRIPTS/-home-kiran--no-mistakes-worktrees-3b169b9eb68e-$RUN_WITH_TRANSCRIPT"
mkdir -p "$MODEL_HOME/state" "$MODEL_DIR"
{
  # Epoch 9880, which is two minutes before the pinned clock of 10000 below and
  # therefore inside the fixture's 12m `document` window and nothing narrower.
  printf '{"type":"queue-operation","operation":"enqueue","timestamp":"%s","sessionId":"251866a3-c09a-4a88-8ef5-3fec8ba0935a","content":"Workspace boundary (important):"}\n' \
    "$(date -u -d @9880 +%Y-%m-%dT%H:%M:%S.000Z)"
  cat <<'REAL'
{"parentUuid":"33e6910a-cc77-435f-98df-10cb8265a120","isSidechain":false,"message":{"model":"claude-opus-5","id":"msg_011CeoEagoQYT6K9LEkm9iYE","type":"message","role":"assistant","content":[{"type":"text","text":"Phase 8 of 18."}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":635,"cache_read_input_tokens":281915,"output_tokens":141,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":635,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":2,"output_tokens":141,"cache_read_input_tokens":281915,"cache_creation_input_tokens":635,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":635},"type":"message"}],"speed":"standard"},"diagnostics":null},"apiBlockIndex":0,"requestId":"req_011CeoEa6eq4LrywaMZN5d7d","type":"assistant","uuid":"f0b24c05-6bc4-49e6-b2e2-4999061064f5","timestamp":"2026-09-07T01:46:25.013Z","effort":"high","userType":"external","entrypoint":"sdk-cli","cwd":"/home/kiran/.no-mistakes/worktrees/3b169b9eb68e/01M1VAGQM160X68A8GQS5YND1Z","sessionId":"251866a3-c09a-4a88-8ef5-3fec8ba0935a","version":"2.1.263","gitBranch":"HEAD"}
REAL
  cat <<'SYNTHETIC'
{"parentUuid":"83bb96f5-4d5f-4c35-8d0e-3ebb2ddbcfda","isSidechain":false,"type":"assistant","uuid":"6f85f260-33ce-4cc0-83f6-48ea5617f2c7","timestamp":"2026-09-06T21:32:20.150Z","message":{"diagnostics":null,"id":"c0f998d5-e07a-4649-b75e-5b53d0359deb","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"output_tokens_details":null,"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":null,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":null,"iterations":null,"speed":null},"content":[{"type":"text","text":"No response requested."}],"context_management":null},"isApiErrorMessage":false,"userType":"external","entrypoint":"sdk-cli","cwd":"/home/kiran/.no-mistakes/worktrees/3b169b9eb68e/01M1VAGQM160X68A8GQS5YND1Z","sessionId":"4d6070dc-37d8-47a7-a2f2-f28e4791066a","version":"2.1.263","gitBranch":"HEAD"}
SYNTHETIC
} > "$MODEL_DIR/251866a3-c09a-4a88-8ef5-3fec8ba0935a.jsonl"

# eager-dispatch-e2 owns the run that has a transcript; arm-lock-gate-q4's run
# has none, which is the ordinary state of a run that has not reached an agent
# step yet. `default` is what bin/fm-spawn.sh records when the harness picked
# the model, so it is not the name of a model and must not reach the screen.
printf 'window=fm:1\nharness=claude\nmodel=claude-opus-5\neffort=high\n' \
  > "$MODEL_HOME/state/eager-dispatch-e2.meta"
printf 'window=fm:2\nmodel=default\neffort=xhigh\n' \
  > "$MODEL_HOME/state/arm-lock-gate-q4.meta"
# No model or effort line at all, which is what a record written before those
# fields existed looks like.
printf 'window=fm:4\n' > "$MODEL_HOME/state/no-run-yet-n1.meta"

# The building phase is measured from these records' own times, so the fixture
# sets them explicitly rather than leaving them at "whenever this test ran":
# 1200 is before the fixture run's created_at of 2000, and the pinned clock
# below is 10000.
touch -d @1200 "$MODEL_HOME/state/eager-dispatch-e2.meta"
touch -d @1200 "$MODEL_HOME/state/arm-lock-gate-q4.meta"
touch -d @1200 "$MODEL_HOME/state/no-run-yet-n1.meta"

MODELOUT="$TMP_ROOT/model-out.json"
PATH="$FAKEBIN:$PATH" FM_HOME="$MODEL_HOME" \
  FM_FLOW_SNAPSHOT_NOW_EPOCH=10000 \
  FM_FLOW_SNAPSHOT_DB="$NM_DB" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/fleet.json" \
  FM_FLOW_SNAPSHOT_TRANSCRIPT_ROOT="$TRANSCRIPTS" \
  "$SNAPSHOT" --json --no-ci > "$MODELOUT" 2>/dev/null
expect_code 0 $? "the model-label snapshot exits clean"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | "\(.worker.harness)/\(.worker.model)/\(.worker.effort)"' "$MODELOUT")
[ "$got" = "claude/claude-opus-5/high" ] ||
  fail "the worker's recorded model and effort did not reach the view: $got"

# `default` is the harness's choice, not a model, so it is emitted as absent -
# the renderer draws a dash. The effort beside it is real and survives.
got=$(jq -r '.agents[] | select(.id=="arm-lock-gate-q4")
  | "\(.worker.model)/\(.worker.effort)"' "$MODELOUT")
[ "$got" = "null/xhigh" ] ||
  fail "model=default was reported as a known model: $got"

got=$(jq -r '.agents[] | select(.id=="no-run-yet-n1")
  | "\(.worker.model)/\(.worker.effort)"' "$MODELOUT")
[ "$got" = "null/null" ] ||
  fail "a record carrying no model or effort invented one: $got"

# Every agent carries the worker object whatever its kind.
got=$(jq -r '[.agents[] | select(.worker == null)] | length' "$MODELOUT")
[ "$got" = 0 ] || fail "$got agents reached the wire with no worker object at all"
pass "the worker's model and effort are read from its own record, and default is not a model"

# The session started two minutes ago, so it falls inside the 12m `document`
# window and not inside anything narrower. The captured record's own model and
# effort are what reach the wire, and the synthetic record after it does not.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[]
  | select(.step=="document") | "\(.model)/\(.effort)"' "$MODELOUT")
[ "$got" = "claude-opus-5/high" ] ||
  fail "the running step did not take its model from the session in its window: $got"

# `review` is an agent step whose active_for the parser cannot read, so it has
# no window to attribute against. That is a stated null - a dash on screen -
# never the value belonging to another step.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[]
  | select(.step=="review") | "\(.model)/\(.effort)"' "$MODELOUT")
[ "$got" = "null/null" ] ||
  fail "a step with no readable window was given another step's model: $got"

# `ci` launches no agent, so the question is not asked of it at all: it carries
# no model field rather than a null one, and the renderer draws no label there.
# Its 18h32m window contains the session, which is exactly why this matters.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[]
  | select(.step=="ci") | has("model")' "$MODELOUT")
[ "$got" = "false" ] ||
  fail "a step that launches no agent was given a model question anyway"
pass "a running agent step names the model of the session in its window, and only an agent step is asked"

# A run with no transcript at all - the ordinary state of one that has not
# reached an agent step - states nulls rather than borrowing another run's.
got=$(jq -r '.agents[] | select(.id=="arm-lock-gate-q4") | [.active_steps[]
  | select(has("model")) | "\(.model)"] | join(",")' "$MODELOUT")
case $got in
  *claude*) fail "a run with no transcript was given a model: $got" ;;
esac
pass "a run with no transcript of its own is not given one"

# The config file states what the NEXT run will use, so it can disagree with a
# run already under way; reading it would turn this label into a guess. The
# assertion is behavioural rather than a grep of the source, because the source
# names that file in the comment saying why it is not read: a config declaring
# a different model must not move the label of a run that is already going.
mkdir -p "$TMP_ROOT/fake-nm-config"
printf 'model: claude-haiku-4-5-20251001\n' > "$TMP_ROOT/fake-nm-config/config.yaml"
got=$(PATH="$FAKEBIN:$PATH" FM_HOME="$MODEL_HOME" \
  HOME="$TMP_ROOT/fake-nm-config-home" \
  FM_FLOW_SNAPSHOT_NOW_EPOCH=10000 \
  FM_FLOW_SNAPSHOT_DB="$NM_DB" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/fleet.json" \
  FM_FLOW_SNAPSHOT_TRANSCRIPT_ROOT="$TRANSCRIPTS" \
  "$SNAPSHOT" --json --no-ci 2>/dev/null |
  jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[]
    | select(.step=="document") | .model')
[ "$got" = "claude-opus-5" ] ||
  fail "the model moved when the environment around the run changed: $got"
pass "the model is the run's own transcript, not the config file's intention"

# --- the building phase ------------------------------------------------------
#
# The worker's own implementation phase, which no pipeline record describes. Its
# start is the earliest durable record dispatch left behind and its end is the
# run's own created_at, both machine times.

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .steps[0].step' "$MODELOUT")
[ "$got" = "building" ] || fail "building is not the first step of the row: $got"

# no-run-yet-n1 has no run at all, so it is still building and says so with an
# elapsed rather than with a duration.
got=$(jq -r '.agents[] | select(.id=="no-run-yet-n1")
  | .steps[] | select(.step=="building") | .status' "$MODELOUT")
[ "$got" = "running" ] || fail "a task with no run yet is not still building: $got"
got=$(jq -r '.agents[] | select(.id=="no-run-yet-n1")
  | [.active_steps[] | select(.step=="building") | .active_ms] | length' "$MODELOUT")
[ "$got" = 1 ] || fail "a task still building states no elapsed for it"

# eager-dispatch-e2's run exists, so building has ended and states a duration.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | .steps[] | select(.step=="building") | .status' "$MODELOUT")
[ "$got" = "completed" ] || fail "building did not end when the run began: $got"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2")
  | [.active_steps[] | select(.step=="building")] | length' "$MODELOUT")
[ "$got" = 0 ] || fail "a finished building phase was still reported as active"
pass "building runs from the record dispatch left to the moment the run began"

# A failed pipeline read leaves the whole step list unknown, and building is not
# smuggled in beside it: one fact inside a frame that says nothing is known
# would be read as the frame being readable.
n=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .steps | length' "$DEADOUT")
[ "$n" = 0 ] || fail "an unreadable agent still emitted $n steps"
pass "an unreadable pipeline emits no steps at all, building included"

# --- the run read is done in the project, not in whatever cwd we inherited ----
#
# `no-mistakes axi status --run <id>` resolves the repository from the CURRENT
# WORKING DIRECTORY. The run id scopes which run inside that repository; it does
# not say which repository. So the command inherits whatever directory the
# captain opened the view from, and from anywhere outside a git repository it
# fails on every task that has a run at all.
#
# Verified on this host, 2026-09-07, against the real binary and a real
# completed run: from ~ it exits 1 with "error: repo not initialized (run
# 'no-mistakes init' first)", from /tmp it exits 1 with "error: not in a git
# repository", and from the project it exits 0 with the run's TOON. That is what
# the captain saw as `unreadable: axi status failed (exit 1)` on every row at
# once, from a view opened in the home directory.
#
# The fake below reproduces exactly that: it answers only when its own cwd is
# the project, and the collector is run from a directory that is not a git
# repository at all.

CWDBIN=$(fm_fakebin "$TMP_ROOT/cwd")
cat > "$CWDBIN/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
printf 'A new version of no-mistakes is available\n' >&2
run=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--run" ] && run=\$a
  prev=\$a
done
if [ "\$(pwd -P)" != "$PROJECT" ]; then
  # On STDOUT, exactly where the real binary puts it.
  printf "error: repo not initialized (run 'no-mistakes init' first)\n"
  exit 1
fi
case "\$run" in
  01KZETHEHPT5RQFB14A83FMZCK) cat "$TMP_ROOT/axi-running.txt" ;;
  01KZGM44YAB57YWGBN0E0XFZF4) cat "$TMP_ROOT/axi-failed.txt" ;;
  *) exit 1 ;;
esac
SH
chmod 755 "$CWDBIN/no-mistakes"

NOTAREPO="$TMP_ROOT/not-a-repo"
mkdir -p "$NOTAREPO"
CWDOUT="$TMP_ROOT/cwd-out.json"
( cd "$NOTAREPO" && PATH="$CWDBIN:$PATH" FM_HOME="$MODEL_HOME" \
  FM_FLOW_SNAPSHOT_NOW_EPOCH=10000 \
  FM_FLOW_SNAPSHOT_DB="$NM_DB" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/fleet.json" \
  FM_FLOW_SNAPSHOT_TRANSCRIPT_ROOT="$TRANSCRIPTS" \
  "$SNAPSHOT" --json --no-ci ) > "$CWDOUT" 2>/dev/null
expect_code 0 $? "the snapshot run from a non-repo directory exits clean"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .collection.ok' "$CWDOUT")
[ "$got" = "true" ] ||
  fail "a run read from outside a repository was reported unreadable: $(
    jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .collection.reason' "$CWDOUT")"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .steps | length' "$CWDOUT")
[ "$got" = 10 ] || fail "the run read from the project produced $got steps"
pass "the run read happens in the task's own project, whatever directory the view was opened from"

# One task's directory must not be carried into the next: the collector reads
# several tasks in one pass, and the change of directory is scoped to the read.
got=$(jq -r '[.agents[] | select(.collection.ok == false)] | length' "$CWDOUT")
[ "$got" = 0 ] || fail "$got agents were left unreadable after another task's read"
pass "the directory change is scoped to one read and does not leak into the next"

# A recorded project that no longer exists is not a reason to refuse the read.
# The directory change is a precondition to satisfy, not a lookup key - the
# daemon does not scope `--run` to the resolved repository - so there is nothing
# better to do than run where we already are, which is what this did before the
# change and is no worse. Refusing instead would make a removed clone break a
# read that would otherwise have worked.
GONE_HOME="$TMP_ROOT/home-gone"
mkdir -p "$GONE_HOME/state"
cp "$MODEL_HOME/state/eager-dispatch-e2.meta" "$GONE_HOME/state/"
jq --arg p "$TMP_ROOT/project-that-was-removed" \
  '.tasks |= map(.project = $p)' "$TMP_ROOT/fleet.json" > "$TMP_ROOT/fleet-gone.json"
sqlite3 "$NM_DB" \
  "UPDATE repos SET working_path='$TMP_ROOT/project-that-was-removed' WHERE id='repo1';"
got=$(PATH="$FAKEBIN:$PATH" FM_HOME="$GONE_HOME" \
  FM_FLOW_SNAPSHOT_NOW_EPOCH=10000 \
  FM_FLOW_SNAPSHOT_DB="$NM_DB" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/fleet-gone.json" \
  FM_FLOW_SNAPSHOT_TRANSCRIPT_ROOT="$TRANSCRIPTS" \
  "$SNAPSHOT" --json --no-ci 2>/dev/null |
  jq -r '.agents[] | select(.id=="eager-dispatch-e2") | "\(.collection.ok)/\(.steps|length)"')
[ "$got" = "true/10" ] ||
  fail "a task whose project directory is gone was refused its run read: $got"
sqlite3 "$NM_DB" "UPDATE repos SET working_path='$PROJECT' WHERE id='repo1';"
pass "a task whose recorded project is gone still gets its run read, from where we already are"

# A failure that is real still says why, in the command's own words. An exit
# code alone is what hid the defect above for as long as it did. The version
# banner is on stderr of every call, successful ones included, so it is not the
# diagnosis and must not be reported as one.
reason=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .collection.reason' "$DEADOUT")
assert_contains "$reason" "could not open the run database" \
  "the failure reason did not carry the command's own first line"
assert_not_contains "$reason" "A new version" \
  "the version banner was reported as the reason the read failed"
n=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .steps | length' "$DEADOUT")
[ "$n" = 0 ] || fail "a failed read still emitted $n steps"
pass "a failed read stays unreadable and says why in the command's own words"

# stdout is where v1.37.0 puts its diagnosis, so stdout is read first. stderr is
# the fallback for a failure mode that writes there instead, and the banner is
# still not a diagnosis on that path either.
ERRBIN=$(fm_fakebin "$TMP_ROOT/onlystderr")
cat > "$ERRBIN/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
printf 'A new version of no-mistakes is available\n' >&2
printf 'error: the daemon refused the connection\n' >&2
exit 1
SH
chmod 755 "$ERRBIN/no-mistakes"

reason=$( ( cd "$NOTAREPO" && PATH="$ERRBIN:$PATH" FM_HOME="$MODEL_HOME" \
  FM_FLOW_SNAPSHOT_NOW_EPOCH=10000 \
  FM_FLOW_SNAPSHOT_DB="$NM_DB" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/fleet.json" \
  FM_FLOW_SNAPSHOT_TRANSCRIPT_ROOT="$TRANSCRIPTS" \
  "$SNAPSHOT" --json --no-ci ) 2>/dev/null |
  jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .collection.reason')
assert_contains "$reason" "the daemon refused the connection" \
  "a failure that wrote only to stderr was reported as a bare exit code"
assert_not_contains "$reason" "A new version" \
  "the version banner was reported as the reason on the stderr path"
pass "a failure that writes only to stderr still says why, and the banner is not the why"

