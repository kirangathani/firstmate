#!/usr/bin/env bash
# Behavior tests for the "waiting on action from upstream" declaration: the gate
# that has to pass before one exists, the record's unforgeability, the recheck
# that drops one that stopped being true, and what supervision does about it.
#
# The captain's stated error case is the whole subject: "the key error case to
# avoid is crewmates lazily pretending they are waiting on upstream when they
# are not, so we need to think about how to mechanically enforce this." So the
# assertions below are mostly refusals, and the two that matter most are that a
# crewmate saying yes is not enough, and that a worker cannot write the record
# itself.
#
# Everything outside is faked at the seams the scripts already own:
# FM_ACK_SECRET_FILE for the signing key, a `gh` on PATH for GitHub, and
# FM_PR_GREEN_BIN for the green verdict - whose own reasoning is asserted by
# tests/fm-pr-green.test.sh and is not re-tested here.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-upstream-wait.sh"
MONITOR="$ROOT/bin/fm-monitor.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-wait)
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
CONFIG="$HOME_DIR/config"
BIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$DATA" "$CONFIG" "$BIN"

SECRET="$CONFIG/ci-waiver-secret"
printf 'a-master-key-for-this-home\n' > "$SECRET"
chmod 600 "$SECRET"

PR_URL="https://github.com/kunchenguid/no-mistakes/pull/1104"

# --- the fakes --------------------------------------------------------------
#
# gh answers only the two reads the gate makes, from files a case sets, so a
# case changes GitHub's answer without changing the gate.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  pr)
    [ -f "${FM_FAKE_PR_JSON:-}" ] || exit 1
    cat "$FM_FAKE_PR_JSON"
    ;;
  api)
    [ -f "${FM_FAKE_ISSUE_STATE:-}" ] || exit 1
    cat "$FM_FAKE_ISSUE_STATE"
    ;;
  *) exit 1 ;;
esac
SH
cat > "$BIN/fm-pr-green.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_GREEN:-1}" = 1 ] || { echo "not green" >&2; exit 1; }
printf 'green: %s %s 12 checks\n' "$2" "${FM_FAKE_GREEN_SHA:-deadbee}"
SH
chmod 755 "$BIN/gh" "$BIN/fm-pr-green.sh"
export PATH="$BIN:$PATH"
export FM_FAKE_PR_JSON="$TMP_ROOT/pr.json"
export FM_FAKE_ISSUE_STATE="$TMP_ROOT/issue.json"
export FM_PR_GREEN_BIN="$BIN/fm-pr-green.sh"
export FM_ACK_SECRET_FILE="$SECRET"
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"
export FM_CONFIG_OVERRIDE="$CONFIG"

pr_json() {  # <state> <head>
  jq -n --arg s "$1" --arg h "$2" '{state:$s, headRefOid:$h}' > "$FM_FAKE_PR_JSON"
}

# A ship task with a real local copy, so the worktree conditions are asked of an
# actual git repository rather than of a stub that cannot answer them.
WT="$TMP_ROOT/wt"
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" config user.email t@example.com
git -C "$WT" config user.name t
printf 'one\n' > "$WT/f"
git -C "$WT" add f
git -C "$WT" commit -q -m one
WT_HEAD=$(git -C "$WT" rev-parse HEAD)

ship_meta() {  # <id> [pr]
  {
    printf 'window=firstmate:fm-%s\n' "$1"
    printf 'worktree=%s\n' "$WT"
    printf 'project=%s\n' "$ROOT"
    printf 'kind=ship\n'
    [ $# -lt 2 ] || printf 'pr=%s\n' "$2"
  } > "$STATE/$1.meta"
}

crew_says() {  # <id> <line>
  printf '[t=1790000000] %s\n' "$2" >> "$STATE/$1.status"
}

reset_task() {  # <id>
  find "$STATE" -maxdepth 1 -name "$1.*" -delete 2>/dev/null || true
}

gate() {  # <id> [args...]
  "$GATE" --gate "$@"
}

# --- the happy path, so every refusal below is a refusal of something --------

pr_json OPEN "$WT_HEAD"
ship_meta ship-ok "$PR_URL"
crew_says ship-ok "upstream-wait-ready: the no-mistakes maintainer has to merge PR 1104"
out=$(gate ship-ok); rc=$?
expect_code 0 $rc "the gate refused a task that meets every condition"
assert_contains "$out" "gate PASSED" "a passing gate did not say so"
assert_contains "$out" "gate action: the no-mistakes maintainer has to merge PR 1104" \
  "the gate did not carry the crew's own words back"
assert_contains "$out" "checks=12" "the gate recorded no check evidence"
pass "a ship task that is pushed, open, clean and green passes the gate and carries the crew's own words back"

# --- the crewmate's yes is required ------------------------------------------

reset_task ship-said
ship_meta ship-said "$PR_URL"
out=$(gate ship-said 2>&1); rc=$?
expect_code 1 $rc "a task that never answered the question passed the gate"
assert_contains "$out" "crew-said" "the refusal did not name the missing answer"
pass "a task whose crewmate never answered the question is refused"

# Present is not enough: LAST. Anything appended afterwards is the worker saying
# something newer, and the question has to be asked again.
crew_says ship-said "upstream-wait-ready: waiting on the maintainer"
crew_says ship-said "working: found one more thing to fix"
out=$(gate ship-said 2>&1); rc=$?
expect_code 1 $rc "a stale upstream-wait-ready line behind newer work passed the gate"
assert_contains "$out" "is not an upstream-wait-ready line" "the refusal did not say why the answer no longer counts"
pass "an upstream-wait-ready line the worker has spoken past no longer counts as its answer"

# --- and the crewmate's yes is NEVER sufficient ------------------------------
#
# This is the captain's error case. Each case below has the worker saying
# exactly the right thing and one machine condition false, and each one is
# refused on that condition rather than on the worker's word.

reset_task ship-nopr
ship_meta ship-nopr
crew_says ship-nopr "upstream-wait-ready: waiting on the maintainer"
out=$(gate ship-nopr 2>&1); rc=$?
expect_code 1 $rc "a ship task with no PR at all was declared waiting"
assert_contains "$out" "pr-recorded" "the refusal did not name the missing PR"
pass "a ship task with no PR is refused however confidently its crewmate says it is waiting"

reset_task ship-dirty
ship_meta ship-dirty "$PR_URL"
crew_says ship-dirty "upstream-wait-ready: waiting on the maintainer"
printf 'uncommitted\n' > "$WT/scratch"
out=$(gate ship-dirty 2>&1); rc=$?
find "$WT" -maxdepth 1 -name scratch -delete
expect_code 1 $rc "a task with uncommitted changes was declared waiting"
assert_contains "$out" "worktree-clean" "the refusal did not name the uncommitted work"
pass "a task holding uncommitted changes is refused: that is work it still has"

reset_task ship-unpushed
ship_meta ship-unpushed "$PR_URL"
crew_says ship-unpushed "upstream-wait-ready: waiting on the maintainer"
# The PR's head is an ancestor-less other commit, so the local HEAD is not in it.
pr_json OPEN "0000000000000000000000000000000000000000"
out=$(gate ship-unpushed 2>&1); rc=$?
expect_code 1 $rc "a task with commits the PR does not have was declared waiting"
assert_contains "$out" "nothing-unpushed" "the refusal did not name the unpushed work"
pass "a task holding commits its PR does not is refused: its work is not all pushed"

reset_task ship-closed
ship_meta ship-closed "$PR_URL"
crew_says ship-closed "upstream-wait-ready: waiting on the maintainer"
pr_json MERGED "$WT_HEAD"
out=$(gate ship-closed 2>&1); rc=$?
expect_code 1 $rc "a merged PR was declared a wait"
assert_contains "$out" "pr-open" "the refusal did not name the PR's lifecycle"
pass "a merged or closed PR is refused: that is not a wait, it is over"

# The captain's own exclusion, in his words: "SPECIFICALLY NOT INCLUDING a
# coding agent whose code is running through the CI process".
reset_task ship-ci
ship_meta ship-ci "$PR_URL"
crew_says ship-ci "upstream-wait-ready: waiting on the maintainer"
pr_json OPEN "$WT_HEAD"
out=$(FM_FAKE_GREEN=0 gate ship-ci 2>&1); rc=$?
expect_code 1 $rc "a task still running through CI was declared waiting"
assert_contains "$out" "checks-green" "the refusal did not name the checks"
pass "a task whose checks are not green is refused: it is running through CI, not waiting"

# A refusal names EVERY condition that failed, not the first: firstmate asks the
# worker one question about all of them, so going round the loop once per
# condition is a loop the captain's own question does not have.
reset_task ship-many
ship_meta ship-many
out=$(gate ship-many 2>&1); rc=$?
expect_code 1 $rc "a task failing several conditions passed"
n=$(printf '%s\n' "$out" | grep -c '^gate FAIL: ')
[ "$n" -ge 2 ] || fail "a refusal named only one failing condition when several failed"
pass "a refusal names every condition that failed, not only the first"

# --- the scout branch, which is the one legitimate no-PR case ----------------

ISSUE="https://github.com/kunchenguid/no-mistakes/issues/900"
printf 'open\n' > "$FM_FAKE_ISSUE_STATE"
reset_task scout-ok
printf 'kind=scout\nwindow=firstmate:fm-scout-ok\nproject=%s\n' "$ROOT" > "$STATE/scout-ok.meta"
mkdir -p "$DATA/scout-ok"
printf '# findings\n' > "$DATA/scout-ok/report.md"
crew_says scout-ok "upstream-wait-ready: waiting for $ISSUE to be labelled ready-for-pr"
out=$(gate scout-ok); rc=$?
expect_code 0 $rc "a scout waiting on an open issue was refused"
assert_contains "$out" "issue-open" "the scout gate did not check the issue"
assert_contains "$out" "issue=$ISSUE" "the scout gate recorded no issue evidence"
pass "a scout that filed an issue, wrote its report, and waits for a maintainer's stamp passes the gate"

reset_task scout-noreport
printf 'kind=scout\nwindow=firstmate:fm-scout-noreport\n' > "$STATE/scout-noreport.meta"
crew_says scout-noreport "upstream-wait-ready: waiting for $ISSUE to be labelled ready-for-pr"
out=$(gate scout-noreport 2>&1); rc=$?
expect_code 1 $rc "a scout with no report was declared waiting"
assert_contains "$out" "report" "the refusal did not name the missing report"
pass "a scout that has not written its report is refused: it is still working, not waiting"

reset_task scout-nourl
printf 'kind=scout\nwindow=firstmate:fm-scout-nourl\n' > "$STATE/scout-nourl.meta"
mkdir -p "$DATA/scout-nourl"
printf '# findings\n' > "$DATA/scout-nourl/report.md"
crew_says scout-nourl "upstream-wait-ready: waiting for somebody upstream to look at it"
out=$(gate scout-nourl 2>&1); rc=$?
expect_code 1 $rc "a scout waiting on a sentence with no link was declared waiting"
assert_contains "$out" "no GitHub issue or pull request link" "the refusal did not say what was missing"
pass "a scout whose awaited action names no link is refused: nobody could re-verify that wait"

reset_task scout-closed
printf 'kind=scout\nwindow=firstmate:fm-scout-closed\n' > "$STATE/scout-closed.meta"
mkdir -p "$DATA/scout-closed"
printf '# findings\n' > "$DATA/scout-closed/report.md"
crew_says scout-closed "upstream-wait-ready: waiting for $ISSUE to be labelled ready-for-pr"
printf 'closed\n' > "$FM_FAKE_ISSUE_STATE"
out=$(gate scout-closed 2>&1); rc=$?
printf 'open\n' > "$FM_FAKE_ISSUE_STATE"
expect_code 1 $rc "a scout waiting on a closed issue was declared waiting"
pass "a scout waiting on an issue GitHub reports closed is refused"

# --- granting, and what a worker cannot do -----------------------------------

pr_json OPEN "$WT_HEAD"
out=$("$MONITOR" --upstream-wait ship-ok --reason "the maintainer has to merge it"); rc=$?
expect_code 0 $rc "the grant refused a task whose gate passes"
[ -f "$STATE/ship-ok.upstream-wait" ] || fail "the grant wrote no record"
assert_contains "$out" "waiting on" "the grant did not say what is being awaited"
pass "a task whose gate passes is granted a standing upstream wait"

# The ACTION that gets signed is the crewmate's own words from the gate, not the
# --reason typed at the grant: what the record says is being awaited has to be
# the sentence the gate actually read and verified.
rec=$(cat "$STATE/ship-ok.upstream-wait")
assert_contains "$rec" "the no-mistakes maintainer has to merge PR 1104" \
  "the record carries the typed reason instead of the verified one"
pass "the record carries the action the gate verified, not the one typed at the grant"

# And the refusal writes NOTHING.
reset_task ship-refused
ship_meta ship-refused
"$MONITOR" --upstream-wait ship-refused --reason "waiting on somebody" >/dev/null 2>&1
expect_code 2 $? "granting a wait over a refused gate was not a usage refusal"
[ ! -f "$STATE/ship-refused.upstream-wait" ] || fail "a refused gate still wrote a record"
pass "a refused gate records nothing at all"

# THE WORKER CANNOT WRITE IT. A worker holds no key, so a marker it appends is
# not a record: the predicate refuses it, and every surface that reads the
# predicate goes on watching the task.
cat > "$STATE/forged.upstream-wait" <<'EOF'
1790000000	deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef	waiting on the maintainer	pr=x
EOF
# shellcheck source=bin/fm-ack-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-ack-lib.sh"
if fm_upstream_waiting "$STATE" forged; then
  fail "a hand-written upstream-wait record verified"
fi
if fm_supervision_suspended "$STATE" forged; then
  fail "a hand-written upstream-wait record suspended supervision"
fi
pass "a hand-written upstream-wait record does not verify, so supervision is never suspended by one"

# The real one does, and it reports itself as its own kind of suppression rather
# than as the captain's.
fm_upstream_waiting "$STATE" ship-ok || fail "a granted wait did not verify"
fm_supervision_suspended "$STATE" ship-ok || fail "a granted wait did not suspend supervision"
[ "$FM_SUSPENDED_SOURCE" = upstream-wait ] ||
  fail "a granted wait reported the wrong kind of suppression"
pass "a granted wait verifies, suspends supervision, and is reported as its own kind rather than as the captain's"

# Editing what it says it is waiting for breaks it, because the action is signed
# with the task: a wait's stated premise cannot be rewritten after the gate that
# verified it passed.
sed -i 's/merge PR 1104/do whatever I like/' "$STATE/ship-ok.upstream-wait"
if fm_upstream_waiting "$STATE" ship-ok; then
  fail "an upstream wait whose stated action was edited still verified"
fi
pass "editing what a wait says it is waiting for invalidates it"

# --- the recheck, which is what keeps it true --------------------------------

reset_task ship-recheck
ship_meta ship-recheck "$PR_URL"
crew_says ship-recheck "upstream-wait-ready: the maintainer has to merge PR 1104"
pr_json OPEN "$WT_HEAD"
"$MONITOR" --upstream-wait ship-recheck --reason "the maintainer has to merge PR 1104" >/dev/null ||
  fail "could not grant a wait to recheck"

out=$("$GATE" --recheck ship-recheck); rc=$?
expect_code 0 $rc "a recheck of a wait that still holds reported a drop"
assert_contains "$out" "still waiting" "a standing recheck said nothing"
[ -f "$STATE/ship-recheck.upstream-wait" ] || fail "a passing recheck dropped the record"
pass "a recheck of a wait that still holds keeps it and says so"

# The PR gets merged, which is the wait ending. The recheck drops the record and
# names what changed, and with the record gone supervision resumes by itself.
pr_json MERGED "$WT_HEAD"
out=$("$GATE" --recheck ship-recheck); rc=$?
expect_code 1 $rc "a recheck that dropped a record reported success"
assert_contains "$out" "dropped ship-recheck" "the drop was not reported"
assert_contains "$out" "pr-open" "the drop did not name what changed"
[ ! -f "$STATE/ship-recheck.upstream-wait" ] || fail "the record survived a failing recheck"
if fm_supervision_suspended "$STATE" ship-recheck; then
  fail "supervision stayed suspended after the record was dropped"
fi
pass "a recheck whose gate no longer passes drops the record, names what changed, and supervision resumes by itself"

# A check going red is the same shape and is the one that must never coexist
# with the lilac state on screen.
reset_task ship-red
ship_meta ship-red "$PR_URL"
crew_says ship-red "upstream-wait-ready: the maintainer has to merge PR 1104"
pr_json OPEN "$WT_HEAD"
"$MONITOR" --upstream-wait ship-red --reason "the maintainer has to merge PR 1104" >/dev/null ||
  fail "could not grant a wait over a green PR"
out=$(FM_FAKE_GREEN=0 "$GATE" --recheck ship-red); rc=$?
expect_code 1 $rc "a recheck over a red PR kept the record"
assert_contains "$out" "checks-green" "the drop did not name the failing checks"
[ ! -f "$STATE/ship-red.upstream-wait" ] || fail "a wait survived its PR going red"
pass "a wait whose PR goes red is dropped on the next recheck, so a red PR and a standing wait cannot coexist"

# --- resume, and what the surfaces say ---------------------------------------

reset_task ship-resume
ship_meta ship-resume "$PR_URL"
crew_says ship-resume "upstream-wait-ready: the maintainer has to merge PR 1104"
"$MONITOR" --upstream-wait ship-resume --reason "the maintainer has to merge PR 1104" >/dev/null ||
  fail "could not grant a wait to resume"
out=$("$MONITOR" --list-upstream-wait)
assert_contains "$out" "ship-resume" "a standing wait was not listed"
assert_contains "$out" "merge PR 1104" "the listing did not name the awaited action"
"$MONITOR" --upstream-resume ship-resume >/dev/null || fail "--upstream-resume failed"
[ ! -f "$STATE/ship-resume.upstream-wait" ] || fail "--upstream-resume left the record behind"
assert_not_contains "$("$MONITOR" --list-upstream-wait)" "waiting	ship-resume" \
  "a resumed wait was still listed as waiting"
pass "a standing wait is listed with its action and ends on --upstream-resume"

# The two records this suite deliberately broke - the forged one and the one
# whose action was edited - are still there, and the listing reports them rather
# than dropping them. An unverifiable record is either a forgery or a real wait
# this home can no longer check, and both are things the captain has to see.
listed=$("$MONITOR" --list-upstream-wait)
assert_contains "$listed" "INVALID	forged" "a forged record vanished from the listing"
assert_contains "$listed" "INVALID	ship-ok" "a tampered record vanished from the listing"
assert_contains "$listed" "still supervised" "the listing did not say a bad record buys nothing"
pass "a record that does not verify is reported as invalid and still supervised, never dropped in silence"
