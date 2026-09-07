#!/usr/bin/env bash
# Behavior tests for bin/fm-timeline.sh and bin/fm-spawned-at-lib.sh - the task
# timeline ledger.
#
# What is under test is a MEASUREMENT, so the whole value of it is that the
# numbers are right. Every case here therefore asserts exact cell values against
# a fixture whose timings were chosen so that a plausible wrong reading produces
# a visibly different answer:
#
#   - wall versus active. `review` runs for 7442 wall seconds of which only 642
#     are active. A step column that reported active time, or a parked column
#     computed the other way round, cannot pass.
#   - SECONDS versus MILLISECONDS. Every *_at column in that database is epoch
#     SECONDS while every *_ms column is milliseconds, and dividing a timestamp
#     by 1000 yields a 1970 date with no error at all
#     (data/perf-remainder-e2e-w8/report.md section 1.1). The fixture's active
#     times are all sub-multiples that would land far from the asserted value if
#     the /1000 were applied to the wrong column, and `test_step_seconds_are_wall`
#     asserts the timestamps themselves come through unscaled.
#   - a step whose recorded active time OVERRUNS its own wall span, which must
#     clamp rather than make parked time negative.
#
# Hermetic: a fixture sqlite database built from the real schema, a fake `gh`
# serving captured GitHub payloads through the real jq, and one temp root. No
# network, no fleet, and the live no-mistakes database is never opened.
# tests/fixtures/timeline/README.md records where each capture came from.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-timeline)
TIMELINE="$ROOT/bin/fm-timeline.sh"
FIXTURES="$ROOT/tests/fixtures/timeline"

command -v sqlite3 >/dev/null 2>&1 || { echo "ok - skipped: sqlite3 not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "ok - skipped: jq not installed"; exit 0; }

# --- the fixture pipeline database ------------------------------------------
#
# One task, one run, and one step per pipeline step. The wall span of each step
# is what the ledger must report; the active time is deliberately far from it so
# the two cannot be confused.
#
#   step       wall(s)  active(s)  park(s)
#   intent          11          1       10
#   rebase           2          2        0
#   review        7442        642     6800
#   test           735        735        0
#   document        74         74        0
#   lint           175        175        0
#   push             3          3        0
#   pr              34         34        0
#   ci           12920      12920        0   <- active recorded ABOVE wall; clamps
#                                    -----
#                                    6810

RUN_START=1788696922          # runs.created_at, epoch SECONDS
STEP_WALL="intent 11 1
rebase 2 2
review 7442 642
test 735 735
document 74 74
lint 175 175
push 3 3
pr 34 34
ci 12920 13000"
EXPECT_PARKED=6810

init_db() {  # <db-path>
  sqlite3 "$1" < "$FIXTURES/schema.sql"
  sqlite3 "$1" "
    INSERT INTO repos (id, working_path, upstream_url, default_branch, created_at)
      VALUES ('repo1', '/fixture/project', 'https://github.com/o/r', 'main', $RUN_START);"
}

add_run() {  # <db-path> <run-id> <branch>
  local db=$1 run=$2 branch=$3 t=$RUN_START order=0 name wall active
  sqlite3 "$db" "
    INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at)
      VALUES ('$run', 'repo1', '$branch', 'headsha', 'basesha', 'passed', $RUN_START, $RUN_START);"
  while read -r name wall active; do
    [ -n "$name" ] || continue
    order=$((order + 1))
    sqlite3 "$db" "
      INSERT INTO step_results
        (id, run_id, step_name, step_order, status, duration_ms, started_at, completed_at)
      VALUES ('$run-s$order', '$run', '$name', $order, 'passed', $((active * 1000)), $t, $((t + wall)));"
    t=$((t + wall))
  done <<< "$STEP_WALL"
  # Two review-fix rounds and one review round, so review_rounds counts the FIX
  # rounds rather than every invocation or every round.
  sqlite3 "$db" "
    INSERT INTO agent_invocations
      (id, run_id, step_name, round, purpose, agent, session_mode, started_at, completed_at, duration_ms, exit_status)
    VALUES
      ('$run-a1','$run','review',1,'review','claude','fresh',$RUN_START,$RUN_START,1000,'ok'),
      ('$run-a2','$run','review',1,'review-fix','claude','fresh',$RUN_START,$RUN_START,1000,'ok'),
      ('$run-a3','$run','review',2,'review-fix','claude','fresh',$RUN_START,$RUN_START,1000,'ok');"
}

# --- the fake gh ------------------------------------------------------------
#
# It serves the captured payloads through the REAL jq and the REAL --jq
# expression the script passes, so the ISO-8601 conversion is tested rather than
# stubbed past. `--fail` makes it refuse every call, for the unreadable-PR case.
make_gh() {  # <dir> [--fail]
  local dir=$1 mode=${2:-ok}
  mkdir -p "$dir"
  cat > "$dir/gh" <<SH
#!/usr/bin/env bash
[ "$mode" = ok ] || exit 1
sub=\$1
payload=
case "\$sub" in
  pr) payload='$FIXTURES/pr-view.json' ;;
  api) payload='$FIXTURES/check-runs.json' ;;
  *) exit 1 ;;
esac
expr=
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --jq ]; then expr=\$2; break; fi
  shift
done
[ -n "\$expr" ] || exit 1
printf '%s\n' "\$@" > /dev/null
jq -r "\$expr" "\$payload"
SH
  chmod +x "$dir/gh"
}

# --- a home -----------------------------------------------------------------

make_home() {  # <name> <task-id> [pr-url] [mode] [extra-meta-line...] -> home path
  local name=$1 id=$2 pr=${3:-} mode=${4:-no-mistakes} home extra
  shift 4 2>/dev/null || shift $#
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data"
  {
    echo "window=firstmate:fm-$id"
    echo "worktree=$home/wt"
    echo "project=/fixture/alpha"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=$mode"
    echo "yolo=off"
    echo "model=opus-5"
    echo "effort=xhigh"
    echo "spawned_at=$((RUN_START - 3922))"
    [ -z "$pr" ] || echo "pr=$pr"
    for extra in "$@"; do printf '%s\n' "$extra"; done
  } > "$home/state/$id.meta"
  printf '%s\n' "$home"
}

# field <ledger> <task-id> <column-name>: the row's value in that named column,
# resolved through the header so a column added later cannot silently shift
# every assertion onto its neighbour.
field() {
  awk -F'\t' -v id="$2" -v want="$3" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == want) c = i; next }
    $1 == id { print (c ? $c : "MISSING-COLUMN"); found = 1; exit }
    END { if (!found) print "NO-ROW" }' "$1"
}

expect_field() {  # <ledger> <task> <column> <expected> <label>
  local got
  got=$(field "$1" "$2" "$3")
  [ "$got" = "$4" ] || fail "$5: $3 expected '$4', got '$got'"
}

run_record() {  # <home> <task-id> [extra env assignments...]
  local home=$1 id=$2
  shift 2
  ( cd "$TMP_ROOT" && env FM_HOME="$home" FM_TIMELINE_GH="$GH_DIR/gh" \
      FM_TIMELINE_DB="$DB" FM_TIMELINE_NOW=1788789513 "$@" "$TIMELINE" record "$id" )
}

GH_DIR="$TMP_ROOT/gh-ok"
make_gh "$GH_DIR"
GH_FAIL_DIR="$TMP_ROOT/gh-fail"
make_gh "$GH_FAIL_DIR" --fail
DB="$TMP_ROOT/full.sqlite"
init_db "$DB"
add_run "$DB" run1 fm/alpha-full-a1
add_run "$DB" run2 fm/alpha-nopr-b2

# --- cases ------------------------------------------------------------------

test_full_row() {
  local home ledger
  home=$(make_home full alpha-full-a1 https://github.com/kirangathani/firstmate/pull/63)
  run_record "$home" alpha-full-a1 > "$TMP_ROOT/full.out" 2>&1 \
    || fail "recording a complete task failed:"$'\n'"$(cat "$TMP_ROOT/full.out")"
  ledger="$home/data/timeline.tsv"
  assert_present "$ledger" "record wrote no ledger"

  expect_field "$ledger" alpha-full-a1 project alpha "full row"
  expect_field "$ledger" alpha-full-a1 mode no-mistakes "full row"
  expect_field "$ledger" alpha-full-a1 model opus-5 "full row"
  expect_field "$ledger" alpha-full-a1 effort xhigh "full row"
  expect_field "$ledger" alpha-full-a1 spawned_at "$((RUN_START - 3922))" "full row"
  expect_field "$ledger" alpha-full-a1 first_run_at "$RUN_START" "full row"
  expect_field "$ledger" alpha-full-a1 build_s 3922 "full row"
  expect_field "$ledger" alpha-full-a1 runs 1 "full row"
  expect_field "$ledger" alpha-full-a1 review_rounds 2 "full row"
  expect_field "$ledger" alpha-full-a1 torn_down_at 1788789513 "full row"
  expect_field "$ledger" alpha-full-a1 note "" "a complete row needs no note"

  # Straight from the captured GitHub payloads: 2026-09-06T14:36:28Z and
  # 2026-09-06T18:10:46Z, and the latest completed_at among the head's 12 check
  # runs. A conversion that dropped the timezone or the seconds would not match.
  expect_field "$ledger" alpha-full-a1 pr_opened_at 1788705388 "PR times from GitHub"
  expect_field "$ledger" alpha-full-a1 merged_at 1788718246 "PR times from GitHub"
  expect_field "$ledger" alpha-full-a1 ci_green_at 1788705806 "last check run on the head"
  expect_field "$ledger" alpha-full-a1 pr_number 63 "PR number from the recorded link"
  pass "a finished ship task records every stage, and the PR times come back as epoch seconds"
}

test_step_seconds_are_wall() {
  local home ledger name wall active
  home="$TMP_ROOT/full"
  ledger="$home/data/timeline.tsv"
  while read -r name wall active; do
    [ -n "$name" ] || continue
    expect_field "$ledger" alpha-full-a1 "${name}_s" "$wall" "step column is WALL, not active ($active s)"
  done <<< "$STEP_WALL"
  expect_field "$ledger" alpha-full-a1 parked_s "$EXPECT_PARKED" "parked is wall minus active, clamped"
  # The strongest guard against the /1000 trap: first_run_at is the database's
  # own runs.created_at unchanged. A timestamp divided by 1000 would be 1788696,
  # a date in 1970, and would still be a plausible-looking integer in the cell.
  expect_field "$ledger" alpha-full-a1 first_run_at 1788696922 "timestamps are seconds and are not rescaled"
  pass "step columns are wall seconds, park is the difference, and timestamps are never divided by 1000"
}

test_idempotent() {
  local home ledger before lines
  home="$TMP_ROOT/full"
  ledger="$home/data/timeline.tsv"
  before=$(cat "$ledger")
  run_record "$home" alpha-full-a1 FM_TIMELINE_NOW=1788999999 > "$TMP_ROOT/again.out" 2>&1 \
    || fail "a repeat record must succeed, not refuse"
  assert_contains "$(cat "$TMP_ROOT/again.out")" "already recorded" "a repeat record should say so"
  [ "$(cat "$ledger")" = "$before" ] || fail "a repeat record rewrote the row"
  lines=$(wc -l < "$ledger")
  [ "$lines" -eq 2 ] || fail "expected a header and one row, got $lines lines"
  pass "a task already in the ledger is recorded once and left exactly as it was"
}

test_no_pr() {
  local home ledger
  home=$(make_home nopr alpha-nopr-b2)
  run_record "$home" alpha-nopr-b2 > "$TMP_ROOT/nopr.out" 2>&1 \
    || fail "a task with no PR must still record"
  ledger="$home/data/timeline.tsv"
  expect_field "$ledger" alpha-nopr-b2 pr_number "" "no PR means an empty cell"
  expect_field "$ledger" alpha-nopr-b2 merged_at "" "no PR means an empty cell"
  expect_field "$ledger" alpha-nopr-b2 ci_green_at "" "no PR means an empty cell"
  assert_contains "$(field "$ledger" alpha-nopr-b2 note)" "no PR recorded" \
    "the note must say why the PR cells are empty"
  # The pipeline half is still there: an empty cell is never a blanked row.
  expect_field "$ledger" alpha-nopr-b2 review_s 7442 "the pipeline half still records"
  pass "a task with no PR records its pipeline stages, empty PR cells and a note"
}

test_unreadable_sources_never_block() {
  local home ledger
  home=$(make_home broken alpha-broken-c3 https://github.com/kirangathani/firstmate/pull/63)
  # Both external sources refuse: no database at that path, and a gh that exits 1.
  ( cd "$TMP_ROOT" && env FM_HOME="$home" FM_TIMELINE_GH="$GH_FAIL_DIR/gh" \
      FM_TIMELINE_DB="$TMP_ROOT/does-not-exist.sqlite" FM_TIMELINE_NOW=1788789513 \
      "$TIMELINE" record alpha-broken-c3 ) > "$TMP_ROOT/broken.out" 2>&1
  expect_code 0 "$?" "an unreadable source must not make record fail - teardown calls this"
  ledger="$home/data/timeline.tsv"
  assert_present "$ledger" "a row must still be written when the sources are unreadable"
  expect_field "$ledger" alpha-broken-c3 review_s "" "an unread database leaves empty cells"
  expect_field "$ledger" alpha-broken-c3 merged_at "" "an unread PR leaves empty cells"
  expect_field "$ledger" alpha-broken-c3 torn_down_at 1788789513 "the row is still stamped"
  assert_contains "$(field "$ledger" alpha-broken-c3 note)" "no validation database" \
    "the note must name the missing database"
  assert_contains "$(field "$ledger" alpha-broken-c3 note)" "could not be read from GitHub" \
    "the note must say the PR could not be read"
  pass "a missing database and an unreadable PR give empty cells and a note, never a refusal"
}

test_teardown_records_before_it_removes() {
  # The ledger is the ONLY record of these durations once teardown runs, so the
  # call has to sit above the first removal. Read out of the script itself
  # rather than trusted to stay where it was put.
  local teardown call_line rm_line
  teardown="$ROOT/bin/fm-teardown.sh"
  call_line=$(grep -n 'bin/fm-timeline.sh" record' "$teardown" | head -1 | cut -d: -f1)
  # The literal line teardown removes the task's state files on. The $ signs
  # are the script's own, not this shell's, so the pattern is fixed-string.
  # shellcheck disable=SC2016
  rm_line=$(grep -nF 'rm -f "$STATE/$ID.status"' "$teardown" | head -1 | cut -d: -f1)
  [ -n "$call_line" ] || fail "bin/fm-teardown.sh no longer records the timeline ledger"
  [ -n "$rm_line" ] || fail "could not find teardown's state-file removal to order against"
  [ "$call_line" -lt "$rm_line" ] \
    || fail "teardown records the ledger at line $call_line, AFTER it removes state at line $rm_line"
  pass "teardown records the ledger before it removes the records the ledger is made of"
}

test_spawned_at_prefers_the_recorded_field() {
  local home id meta got
  # shellcheck source=bin/fm-spawned-at-lib.sh
  . "$ROOT/bin/fm-spawned-at-lib.sh"
  home="$TMP_ROOT/spawnat"
  mkdir -p "$home/state"
  id=alpha-spawn-d4
  meta="$home/state/$id.meta"
  printf 'window=w\nspawned_at=1700000000\n' > "$meta"
  # The mtime is deliberately much later, as it is for any real task whose meta
  # was appended to after dispatch. The recorded field must win over it.
  touch -d @1799999999 "$meta"
  got=$(fm_spawned_at "$home/state" "$id")
  [ "$got" = 1700000000 ] || fail "recorded spawned_at should win over the mtime, got '$got'"

  # A task dispatched before spawn recorded the field falls back to the mtime.
  printf 'window=w\n' > "$meta"
  touch -d @1700000500 "$meta"
  got=$(fm_spawned_at "$home/state" "$id")
  [ "$got" = 1700000500 ] || fail "expected the meta mtime fallback, got '$got'"

  # A field that is not a number is not a time, and must not be believed.
  printf 'window=w\nspawned_at=not-a-time\n' > "$meta"
  touch -d @1700000500 "$meta"
  got=$(fm_spawned_at "$home/state" "$id")
  [ "$got" = 1700000500 ] || fail "a non-numeric spawned_at should be ignored, got '$got'"
  pass "the recorded dispatch time wins, and an absent or malformed one falls back to the file times"
}

test_header_is_stable() {
  # The ledger is read months later by whatever can open a TSV, and every
  # assertion in this file resolves its column THROUGH this header. Pinning the
  # exact line is what makes both of those safe: a column inserted in the middle
  # of an existing ledger silently reinterprets every row already written.
  local want got
  want='task_id	project	mode	model	effort	local_skip	ci_skip	skipped_stages	spawned_at	first_run_at	pr_opened_at	ci_green_at	merged_at	torn_down_at	build_s	intent_s	rebase_s	review_s	test_s	document_s	lint_s	push_s	pr_s	ci_s	parked_s	review_rounds	runs	pr_number	note'
  got=$(head -1 "$TMP_ROOT/full/data/timeline.tsv")
  [ "$got" = "$want" ] || fail "the ledger header changed:"$'\n'"want: $want"$'\n'"got:  $got"
  pass "the ledger header is exactly the documented column list, in order"
}

test_local_skip_stages_mirror_their_owner() {
  # bin/fm-flow-tui.mjs owns which stages a direct-PR mode and a --local-skip
  # remove. bin/fm-timeline.sh mirrors that set, and a mirror nobody checks is a
  # second copy waiting to drift, so the owner's own set is read out of the
  # module HERE at run time rather than written down again.
  local owner mirror
  owner=$(sed -n 's/^export const LOCAL_SKIP_STAGES = new Set(\[\(.*\)\]);$/\1/p' \
    "$ROOT/bin/fm-flow-tui.mjs" | tr -d '" ' | tr ',' ' ')
  [ -n "$owner" ] || fail "could not read LOCAL_SKIP_STAGES out of bin/fm-flow-tui.mjs"
  mirror=$(sed -n 's/^FM_TIMELINE_LOCAL_SKIP_STAGES="\(.*\)"$/\1/p' "$ROOT/bin/fm-timeline.sh")
  [ -n "$mirror" ] || fail "could not read FM_TIMELINE_LOCAL_SKIP_STAGES out of bin/fm-timeline.sh"
  [ "$owner" = "$mirror" ] \
    || fail "the skipped-stage set drifted from its owner"$'\n'"bin/fm-flow-tui.mjs: $owner"$'\n'"bin/fm-timeline.sh:  $mirror"
  pass "the skipped-stage set matches bin/fm-flow-tui.mjs, which owns the rule"
}

test_direct_pr_names_its_skipped_stages() {
  local home ledger
  home=$(make_home directpr alpha-directpr-e5 "" direct-PR)
  run_record "$home" alpha-directpr-e5 > /dev/null 2>&1 \
    || fail "recording a direct-PR task failed"
  ledger="$home/data/timeline.tsv"
  expect_field "$ledger" alpha-directpr-e5 local_skip false "direct-PR is a delivery mode, not a testing skip"
  expect_field "$ledger" alpha-directpr-e5 ci_skip false "direct-PR is a delivery mode, not a testing skip"
  # Push and pr are deliberately NOT here: bin/fm-flow-tui.mjs's contract is that
  # a direct-PR worker still pushes and opens the PR, by hand.
  expect_field "$ledger" alpha-directpr-e5 skipped_stages \
    "intent,rebase,review,test,document,lint(direct-PR)" "direct-PR names the stages its mode removes"
  pass "a direct-PR task names the six stages its delivery mode removed, and not push or pr"
}

test_local_skip_and_ci_skip_are_separate_axes() {
  local home ledger
  home=$(make_home localskip alpha-localskip-f6 "" no-mistakes "local_skip=on")
  run_record "$home" alpha-localskip-f6 > /dev/null 2>&1 || fail "recording a local_skip task failed"
  ledger="$home/data/timeline.tsv"
  expect_field "$ledger" alpha-localskip-f6 local_skip true "the flag is read from the record"
  expect_field "$ledger" alpha-localskip-f6 ci_skip false "an absent flag is false, never empty"
  expect_field "$ledger" alpha-localskip-f6 skipped_stages \
    "intent,rebase,review,test,document,lint(local_skip)" "local_skip removes the local pipeline stages"

  home=$(make_home ciskip alpha-ciskip-g7 "" no-mistakes "ci_skip=on")
  run_record "$home" alpha-ciskip-g7 > /dev/null 2>&1 || fail "recording a ci_skip task failed"
  ledger="$home/data/timeline.tsv"
  expect_field "$ledger" alpha-ciskip-g7 ci_skip true "the flag is read from the record"
  # ci_skip removes no LOCAL stage, and the waived PR jobs are named apart from
  # this ledger's own `ci` pipeline step so the two can never be read as one.
  expect_field "$ledger" alpha-ciskip-g7 skipped_stages "ci-jobs(ci_skip)" \
    "ci_skip waives the PR's test and lint jobs, not a pipeline stage"
  pass "the two testing skips are recorded as separate axes and remove different things"
}

test_pipeline_skipped_step_is_named_and_leaves_no_seconds() {
  local home ledger db
  db="$TMP_ROOT/skipped.sqlite"
  init_db "$db"
  add_run "$db" run3 fm/alpha-pipeskip-h8
  # A gate the captain closed with --action skip. The pipeline records it with a
  # completed_at and NO started_at, which is exactly how the real database
  # writes one, so it can never enter a wall-time sum.
  sqlite3 "$db" "
    UPDATE step_results SET status = 'skipped', duration_ms = 0,
                            started_at = NULL, completed_at = $RUN_START
      WHERE run_id = 'run3' AND step_name = 'review';"
  home=$(make_home pipeskip alpha-pipeskip-h8)
  ( cd "$TMP_ROOT" && env FM_HOME="$home" FM_TIMELINE_GH="$GH_DIR/gh" \
      FM_TIMELINE_DB="$db" FM_TIMELINE_NOW=1788789513 \
      "$TIMELINE" record alpha-pipeskip-h8 ) > /dev/null 2>&1 \
    || fail "recording a task with a pipeline-skipped step failed"
  ledger="$home/data/timeline.tsv"
  expect_field "$ledger" alpha-pipeskip-h8 skipped_stages "review(pipeline)" \
    "a step the pipeline itself skipped is named under its own authority"
  expect_field "$ledger" alpha-pipeskip-h8 review_s "" \
    "a skipped step's seconds cell must be EMPTY, never 0"
  # Skipped is not unreached: the stages that DID run are still measured.
  expect_field "$ledger" alpha-pipeskip-h8 test_s 735 "the stages that ran still record"
  pass "a pipeline-skipped step is named by authority and leaves its seconds cell empty, not zero"
}

test_an_unflagged_task_names_nothing_skipped() {
  local ledger
  ledger="$TMP_ROOT/full/data/timeline.tsv"
  expect_field "$ledger" alpha-full-a1 local_skip false "an ordinary task carries no skip"
  expect_field "$ledger" alpha-full-a1 ci_skip false "an ordinary task carries no skip"
  expect_field "$ledger" alpha-full-a1 skipped_stages "" "an ordinary task skipped nothing"
  pass "an ordinary no-mistakes task records false, false and an empty skipped-stage cell"
}

test_report_medians_per_project() {
  local home ledger out header row
  home="$TMP_ROOT/report"
  mkdir -p "$home/data"
  ledger="$home/data/timeline.tsv"
  header=$(head -1 "$TMP_ROOT/full/data/timeline.tsv")
  printf '%s\n' "$header" > "$ledger"
  # Two projects. alpha's launch-to-merge spans are 1h, 2h and 3h (median 2h);
  # beta's are 10h and 20h (median 15h). The medians are per project, so one
  # project's rows must not move the other's answer.
  add_row() {  # <task> <project> <hours-to-merge> <review-seconds> [skipped-stages]
    awk -v id="$1" -v proj="$2" -v span="$(( $3 * 3600 ))" -v rev="$4" \
        -v skipped="${5:-}" -v hdr="$header" '
      BEGIN {
        n = split(hdr, h, "\t")
        for (i = 1; i <= n; i++) {
          v = ""
          if (h[i] == "task_id") v = id
          else if (h[i] == "project") v = proj
          else if (h[i] == "spawned_at") v = 1700000000
          else if (h[i] == "merged_at") v = 1700000000 + span
          else if (h[i] == "review_s") v = (skipped == "" ? rev : "")
          else if (h[i] == "skipped_stages") v = skipped
          else if (h[i] == "local_skip" || h[i] == "ci_skip") v = (skipped == "" ? "false" : "true")
          printf "%s%s", v, (i < n ? "\t" : "\n")
        }
      }' >> "$ledger"
  }
  add_row alpha-1 alpha 1 100
  add_row beta-1 beta 10 900
  add_row alpha-2 alpha 3 300
  add_row beta-2 beta 20 500
  add_row alpha-3 alpha 2 200
  # A skipped journey, and a very fast one. It must land in its own bucket: if it
  # were folded in, alpha's median would drop to 1.50 h and read as an improvement
  # that nothing about the work actually earned.
  add_row alpha-skip alpha 1 0 "intent,rebase,review,test,document,lint(local_skip)"

  out=$( cd "$TMP_ROOT" && env FM_HOME="$home" "$TIMELINE" report ) \
    || fail "report failed on a two-project ledger"
  assert_contains "$out" "alpha-3" "the report must list the ledger's rows"
  row=$(printf '%s\n' "$out" | awk '$1 == "alpha" && $2 == "no" && $3 == "recent" { print; exit }')
  [ -n "$row" ] || fail "no unskipped medians line for alpha:"$'\n'"$out"
  assert_contains "$row" "2.00" "alpha's unskipped median launch-to-merge should be 2.00 h, got: $row"
  assert_contains "$row" "0.06" "alpha's median review should be 200 s = 0.06 h, got: $row"
  assert_not_contains "$row" "1.50" \
    "the skipped row must not be folded into alpha's ordinary median, got: $row"
  row=$(printf '%s\n' "$out" | awk '$1 == "alpha" && $2 == "yes" && $3 == "recent" { print; exit }')
  [ -n "$row" ] || fail "the skipped rows need their own displayed bucket:"$'\n'"$out"
  assert_contains "$row" "1.00" "alpha's skipped bucket should median 1.00 h, got: $row"
  row=$(printf '%s\n' "$out" | awk '$1 == "beta" && $2 == "no" && $3 == "recent" { print; exit }')
  [ -n "$row" ] || fail "no medians line for beta:"$'\n'"$out"
  assert_contains "$row" "15.00" "beta's median launch-to-merge should be 15.00 h, got: $row"

  # A narrower window is a different window, and the two must be comparable:
  # alpha's newest row alone is 2 h, and the two before it median 2 h as well,
  # while beta's newest is 20 h against 10 h before it.
  out=$( cd "$TMP_ROOT" && env FM_HOME="$home" "$TIMELINE" report --last 1 ) \
    || fail "report --last 1 failed"
  row=$(printf '%s\n' "$out" | awk '$1 == "beta" && $2 == "no" && $3 == "before" { print; exit }')
  [ -n "$row" ] || fail "a narrowed window must also print the window before it:"$'\n'"$out"
  assert_contains "$row" "10.00" "beta's earlier window should be 10.00 h, got: $row"
  pass "the report medians launch-to-merge and every stage per project, in two comparable windows"
}

test_full_row
test_step_seconds_are_wall
test_idempotent
test_no_pr
test_unreadable_sources_never_block
test_teardown_records_before_it_removes
test_spawned_at_prefers_the_recorded_field
test_header_is_stable
test_local_skip_stages_mirror_their_owner
test_direct_pr_names_its_skipped_stages
test_local_skip_and_ci_skip_are_separate_axes
test_pipeline_skipped_step_is_named_and_leaves_no_seconds
test_an_unflagged_task_names_nothing_skipped
test_report_medians_per_project
