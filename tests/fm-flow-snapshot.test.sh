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

PROJECT=/home/kiran/projects/gits/firstmate

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
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,18h32m,"37s ago: log: warning: could not check CI: gh pr checks: exit status 1","",starting
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
cat > "$TMP_ROOT/ci-rollup.json" <<'JSON'
{"statusCheckRollup":[
{"__typename":"CheckRun","name":"CI testing waiver","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},
{"__typename":"CheckRun","name":"CI testing waiver","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"Require no-mistakes"},
{"__typename":"CheckRun","name":"Lint shell scripts","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},
{"__typename":"CheckRun","name":"Behavior tests (shard 1)","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI"},
{"__typename":"CheckRun","name":"Behavior tests (shard 2)","status":"IN_PROGRESS","conclusion":"","workflowName":"CI"}
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
  01KZWEDGEDWEDGEDWEDGEDWEDG) exit 1 ;;
  *) exit 1 ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
cat "$TMP_ROOT/ci-rollup.json"
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/gh"

# --- fixture fleet document -------------------------------------------------

make_fleet() {  # <file>
  jq -n --arg p "$PROJECT" '{tasks:[
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
     paths:{worktree:{path:"/wt/5"}},endpoint:{target:"fm:5",exists:true},
     pr:{url:null}}
  ]}' > "$1"
}
make_fleet "$TMP_ROOT/fleet.json"

run_snapshot() {  # <extra args...>
  PATH="$FAKEBIN:$PATH" \
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
[ "$got" = "fm-flow-snapshot.v1" ] || fail "wrong schema id: $got"
pass "emits the fm-flow-snapshot.v1 schema id"

# Scout tasks have no pipeline of their own, so they are not agents in this view.
got=$(jq -r '[.agents[].id] | sort | join(",")' "$OUT")
[ "$got" = "arm-lock-gate-q4,eager-dispatch-e2,no-run-yet-n1,stale-runner-s9" ] \
  || fail "unexpected agent set: $got"
pass "ships become agents and scouts are excluded"

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
[ "$got" = 9 ] || fail "expected 9 steps, got $got"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | [.steps[].step] | join(",")' "$OUT")
[ "$got" = "intent,rebase,review,test,document,lint,push,pr,ci" ] || fail "step order wrong: $got"
pass "carries all nine steps in pipeline order"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .steps[] | select(.step=="lint") | .duration_ms' "$OUT")
[ "$got" = 1127597 ] || fail "duration lost: $got"
pass "preserves step durations and finding counts"

# active_steps carries a quoted field containing commas; splitting on every
# comma rather than on unquoted ones truncates it.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .active_steps[0].last_activity' "$OUT")
assert_contains "$got" "gh pr checks: exit status 1" "active_steps last_activity truncated at an embedded comma"
pass "parses quoted active_steps fields containing commas"

# --- failure renders as unknown, never as pending ---------------------------
#
# A read that failed and a step that has not started are different claims. If a
# timed-out collection emitted pending steps, the view would state as fact that
# the pipeline has not begun.

ok=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .collection.ok' "$OUT")
[ "$ok" = "false" ] || fail "failed axi read reported collection.ok=$ok"
n=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .steps | length' "$OUT")
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

age=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .run.db_age_seconds' "$OUT")
[ "$age" = 9400 ] || fail "expected db_age_seconds 9400, got $age"
alive=$(jq -r '.agents[] | select(.id=="stale-runner-s9") | .endpoint_alive' "$OUT")
[ "$alive" = "false" ] || fail "endpoint liveness not carried through: $alive"
pass "carries run age and endpoint liveness so staleness cannot be hidden"

# --- CI rollup --------------------------------------------------------------

CIOUT="$TMP_ROOT/ci-out.json"
run_snapshot > "$CIOUT" 2>/dev/null
expect_code 0 $? "snapshot with CI exits clean"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | .ci.total' "$CIOUT")
[ "$got" = 5 ] || fail "expected 5 checks, got $got"
# Both same-named checks must survive: keying on name alone drops one.
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | [.ci.checks[] | select(.name=="CI testing waiver")] | length' "$CIOUT")
[ "$got" = 2 ] || fail "duplicate check name collapsed: kept $got of 2"
got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | [.ci.checks[] | select(.name=="CI testing waiver") | .workflow] | sort | join(",")' "$CIOUT")
[ "$got" = "CI,Require no-mistakes" ] || fail "workflow not distinguishing same-named checks: $got"
pass "keys checks on workflow plus name so duplicates both survive"

got=$(jq -r '.agents[] | select(.id=="eager-dispatch-e2") | "\(.ci.passed)/\(.ci.failed)/\(.ci.pending)"' "$CIOUT")
[ "$got" = "3/1/1" ] || fail "rollup counts wrong (passed/failed/pending): $got"
pass "rolls up passed, failed, and pending counts"

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
hash_tree() {
  { find "$HOME_DIR" -type f -exec cksum {} \; ; cksum "$NM_DB"; } | LC_ALL=C sort
}
before=$(hash_tree)
FM_HOME="$HOME_DIR" run_snapshot >/dev/null 2>&1
after=$(hash_tree)
[ "$before" = "$after" ] || fail "snapshot mutated state, data, or the no-mistakes database"
pass "leaves state, data, and the no-mistakes database byte-identical"

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
