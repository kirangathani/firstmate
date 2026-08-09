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

# --- an agent is a task with a LIVE worker behind it -------------------------
#
# `state/<id>.meta` outlives the window it names: firstmate stands a finished
# worker down by killing the window, and the record stays for recovery to read.
# Enumerating records alone put finished workers on screen as though they were
# running - the captain's second run showed 14 agents against two live windows.
# A task whose recorded endpoint no longer resolves is named in `omitted` and
# drawn nowhere.
got=$(jq -r '[.agents[].id] | sort | join(",")' "$OUT")
[ "$got" = "arm-lock-gate-q4,eager-dispatch-e2,no-run-yet-n1" ] \
  || fail "unexpected agent set: $got"
pass "ships with a live endpoint become agents; scouts and dead endpoints do not"

got=$(jq -r '[.omitted[].id] | sort | join(",")' "$OUT")
[ "$got" = "stale-runner-s9" ] || fail "unexpected omitted set: $got"
got=$(jq -r '.omitted[] | select(.id=="stale-runner-s9") | .reason' "$OUT")
assert_contains "$got" "no longer exists" "the omission gave no reason"
pass "a task whose recorded endpoint is gone is named in omitted, not drawn as an agent"

# Live workers this view has no row for are stated too, so the captain can
# reconcile the list against the windows in front of them.
got=$(jq -r '[.out_of_scope[].id] | sort | join(",")' "$OUT")
[ "$got" = "some-scout-x1" ] || fail "unexpected out_of_scope set: $got"
pass "a live worker with no pipeline is named rather than silently absent"

# The record is still readable on request - the point is that it is not drawn
# beside running workers by default.
got=$(run_snapshot --no-ci --include-dead | jq -r '[.agents[].id] | sort | join(",")')
[ "$got" = "arm-lock-gate-q4,eager-dispatch-e2,no-run-yet-n1,stale-runner-s9" ] \
  || fail "--include-dead did not restore the dead record: $got"
got=$(run_snapshot --no-ci --include-dead | jq -r '.omitted | length')
[ "$got" = 0 ] || fail "--include-dead still omitted $got task(s)"
pass "--include-dead puts the gone-worker records back for diagnosis"

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
PATH="$FAKEBIN:$PATH" FM_HOME="$ATT_HOME" \
  FM_TEST_ROLLUP="$TMP_ROOT/att-rollup.json" \
  FM_FLOW_SNAPSHOT_DB="$TMP_ROOT/absent.sqlite" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/att-fleet.json" \
  "$SNAPSHOT" --json > "$ATTOUT" 2>/dev/null
expect_code 0 $? "the attestation snapshot exits clean"

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
