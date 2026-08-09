#!/usr/bin/env bash
# tests/fm-drift-check.test.sh - behavior tests for bin/fm-drift-check.sh, the
# reconciler between data/backlog.md's In flight section and live reality.
#
# The condition under test: the durable queue and the runtime records disagree
# and nothing notices. On 2026-08-09 this repo's own home opened a session with
# a backlog claiming 17 tasks in flight against 2 running agents, twelve stale
# runtime records, ten already-merged PRs, and 33 ready items left undispatched
# because the queue looked busy.
#
# Both directions are covered deliberately, per class. A detector verified only
# on its firing path has verified nothing, so every firing case here is paired
# with a same-fixture case that must stay quiet - a live worker beside a dead
# one, an open PR beside a merged one, a secondmate record beside an orphan, a
# captain-gated row beside a real in-flight one.
#
# The render contract is tested as behavior in its own right, because a `0` that
# means "did not look" is the failure this whole script exists to prevent: an
# unevaluated class must print a dash, a partially evaluated class must print an
# `incomplete:` note, and `ok` must appear only when all four are genuinely
# clear.
#
# Hermetic: one temp home per case, fake tmux and fake gh built into a fakebin,
# and a PATH derived from the real tree at run time so removing `gh` or `tmux`
# from it cannot silently remove jq or coreutils with them. No network, no real
# fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-drift-check)
DRIFT="$ROOT/bin/fm-drift-check.sh"

# --- PATH, derived from the real tree ---------------------------------------
#
# Hand-listing directories would be a second copy of this machine's layout that
# rots (jq is not in /usr/bin on every host), and a test that loses jq fails for
# a reason it is not testing. Note this cannot make a tool ABSENT: `tmux` and
# `gh` share /usr/bin with coreutils on most hosts, so a case that needs one
# gone masks it with mask_command below instead of pruning the PATH.
essential_path() {
  local dirs='' tool resolved dir
  for tool in bash env jq sed grep awk cat cut head tail sort mktemp rm cp mv \
    chmod basename dirname date timeout git; do
    resolved=$(command -v "$tool" 2>/dev/null) || continue
    dir=${resolved%/*}
    case ":$dirs:" in *":$dir:"*) continue ;; esac
    dirs="${dirs:+$dirs:}$dir"
  done
  printf '%s\n' "$dirs"
}
BASE_PATH=$(essential_path)

# --- fixtures ---------------------------------------------------------------

# new_world <slug>: a home with state/ and data/ and its own fakebin.
new_world() {
  local slug=$1 w
  w="$TMP_ROOT/$slug"
  mkdir -p "$w/state" "$w/data" "$w/fakebin"
  printf '%s\n' "$w"
}

# write_backlog <home> <in-flight-line>...: a backlog in the canonical shape
# bin/fm-fleet-snapshot.sh parses, with only the In flight section populated.
write_backlog() {
  local home=$1 line
  shift
  {
    printf '# Backlog\n\n## In flight\n'
    for line in "$@"; do
      printf '%s\n' "$line"
    done
    printf '\n## Queued\n\n## Done\n'
  } > "$home/data/backlog.md"
}

in_flight_row() {  # <id> [<kind>]
  printf -- '- [ ] %s - Some work (repo: proj) (kind: %s)\n' "$1" "${2:-ship}"
}

# task_meta <home> <id> <window> [kind] [pr-url]: the record fm-spawn writes.
task_meta() {
  local home=$1 id=$2 window=$3 kind=${4:-ship} pr=${5:-}
  fm_write_meta "$home/state/$id.meta" \
    "window=$window" \
    "worktree=$home/wt-$id" \
    "project=$home/projects/proj" \
    "harness=echo" \
    "kind=$kind" \
    "mode=direct-PR" \
    "yolo=off"
  [ -z "$pr" ] || printf 'pr=%s\n' "$pr" >> "$home/state/$id.meta"
}

# make_fake_tmux <fakebin> <live-target>...: `list-panes` resolves only for the
# named "session:window" targets - the exact primitive fm_backend_target_exists
# uses. Deliberately not display-message, which real tmux answers from the
# session's current window for ANY name and so cannot distinguish live from
# dead (docs/tmux-backend.md "Endpoint existence probe").
make_fake_tmux() {
  local fakebin=$1
  shift
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
live="$*"
case "\${1:-}" in
  list-panes)
    target=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "-t" ] && target="\$a"
      prev="\$a"
    done
    for l in \$live; do
      [ "\$target" = "\$l" ] && { printf '%s\n' "\${target##*:}"; exit 0; }
    done
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# make_fake_gh <fakebin>: answers the one read bin/fm-drift-check.sh makes,
# `gh pr view <url> --json state -q .state`, from FM_FAKE_GH_MERGED (a
# space-separated URL list). FM_FAKE_GH_FAIL=1 makes every call fail, which is
# what an unreachable or unauthenticated GitHub looks like to the caller.
# Every call is appended to FM_FAKE_GH_LOG so a test can assert which PRs were
# and were not queried.
make_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
url=""
for a in "$@"; do
  case "$a" in https://*) url=$a ;; esac
done
[ -n "${FM_FAKE_GH_LOG:-}" ] && printf '%s\n' "$url" >> "$FM_FAKE_GH_LOG"
[ "${FM_FAKE_GH_FAIL:-0}" = 1 ] && exit 1
case " ${FM_FAKE_GH_MERGED:-} " in
  *" $url "*) printf 'MERGED\n'; exit 0 ;;
esac
printf 'OPEN\n'
SH
  chmod +x "$fakebin/gh"
}

# mask_command <home> <tool>...: echo a BASH_ENV file that makes `command -v
# <tool>` fail in every bash the run spawns, so a case can make a tool genuinely
# absent without pruning the directory it shares with coreutils. Same technique
# tests/fm-session-start.test.sh uses to mask tmux for a Herdr home.
mask_command() {
  local home=$1 mask tool
  shift
  mask="$home/mask-command.bash"
  {
    # shellcheck disable=SC2016 # The mask's own body must reach the file unexpanded.
    printf 'command() {\n  if [ "${1:-}" = -v ]; then\n    case "${2:-}" in\n'
    for tool in "$@"; do
      printf '      %s) return 1 ;;\n' "$tool"
    done
    printf '    esac\n  fi\n  builtin command "$@"\n}\n'
  } > "$mask"
  printf '%s\n' "$mask"
}

# run_drift <home> [VAR=VAL]... [args...]: run the checker against <home> with
# every FM_DRIFT_*/FM_PR_GH_TIMEOUT scrubbed from the ambient environment, so a
# case measures the code and its own fixture rather than the shell that happens
# to run the suite. A leading VAR=VAL is applied after the scrub, and a later
# PATH= overrides the default fakebin PATH.
run_drift() {
  local home=$1 assignments=()
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*) assignments+=("$1"); shift ;;
      *) break ;;
    esac
  done
  env -u FM_DRIFT_DETAIL -u FM_DRIFT_PR_LOOKUPS -u FM_DRIFT_PR_PARALLEL \
    -u FM_PR_GH_TIMEOUT -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$home" PATH="$home/fakebin:$BASE_PATH" \
    "${assignments[@]+"${assignments[@]}"}" \
    bash "$DRIFT" "$@"
}

# class_value <output> <label>: the count column rendered for one class, so a
# test asserts the value rather than a whole formatted line.
class_value() {
  printf '%s\n' "$1" | sed -n "s/^  $2  *\([-0-9][0-9]*\).*/\1/p" | head -1
}

assert_class() {  # <output> <label> <expected> <msg>
  local actual
  actual=$(class_value "$1" "$2")
  [ "$actual" = "$3" ] || fail "$4: class '$2' rendered '$actual', expected '$3'"$'\n'"--- output ---"$'\n'"$1"
}

LABEL_A='in flight, worker not running'
LABEL_B='in flight, PR already merged'
LABEL_C='runtime record, not in flight'
LABEL_D='in flight, no runtime record'

# --- a clean fleet: quiet, but every class still named -----------------------

test_clean_fleet_names_every_class_and_says_ok() {
  local w out status
  w=$(new_world clean-fleet)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live"

  out=$(run_drift "$w"); status=$?

  expect_code 0 "$status" "a clean fleet must exit 0"
  assert_class "$out" "$LABEL_A" 0 "clean fleet"
  assert_class "$out" "$LABEL_B" 0 "clean fleet"
  assert_class "$out" "$LABEL_C" 0 "clean fleet"
  assert_class "$out" "$LABEL_D" 0 "clean fleet"
  assert_contains "$out" "DRIFT CHECK: ok - every class clear." \
    "a fully evaluated clean fleet must carry the ok line"
  assert_not_contains "$out" "DRIFT:" "a clean fleet must list no findings"
  assert_not_contains "$out" "DRIFT REMEDY" "a clean fleet must print no remedy"
  # Bounded: the header, four class rows and the ok line, nothing else.
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 6 ] \
    || fail "clean render was not bounded to 6 lines: $out"
  pass "fm-drift-check: a clean fleet names every class, adds six lines, and says ok"
}

# --- class 1: in flight, worker not running ---------------------------------

test_dead_endpoint_fires_while_the_live_one_beside_it_stays_quiet() {
  local w out status
  w=$(new_world dead-endpoint)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)" "$(in_flight_row gone)"
  task_meta "$w" live "fm-sess:fm-live"
  task_meta "$w" gone "fm-sess:fm-gone"

  out=$(run_drift "$w"); status=$?

  expect_code 1 "$status" "an in-flight task with a dead worker must report"
  assert_class "$out" "$LABEL_A" 1 "one dead worker"
  assert_contains "$out" "DRIFT: gone is in flight but its worker is gone" \
    "the finding must name the task whose worker is gone"
  assert_contains "$out" "fm-sess:fm-gone" "the finding must name the endpoint it probed"
  assert_not_contains "$out" "DRIFT: live " "the live task beside it must stay quiet"
  assert_not_contains "$out" "DRIFT CHECK: ok" "a firing render must never claim ok"
  pass "fm-drift-check: a dead worker on an in-flight task fires, its live sibling does not"
}

test_a_record_naming_no_endpoint_at_all_is_reported() {
  local w out status
  w=$(new_world no-endpoint)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row headless)"
  fm_write_meta "$w/state/headless.meta" "kind=ship" "mode=direct-PR"

  out=$(run_drift "$w"); status=$?

  expect_code 1 "$status" "an in-flight record with no endpoint must report"
  assert_class "$out" "$LABEL_A" 1 "record with no endpoint"
  assert_contains "$out" "names no worker endpoint at all" \
    "the finding must say the record names no endpoint"
  pass "fm-drift-check: an in-flight record naming no worker endpoint is reported"
}

test_an_unprobeable_backend_is_undetermined_never_declared_dead() {
  local w out status mask
  w=$(new_world unprobeable-backend)
  # The CLI the recorded backend needs is absent, so "the endpoint does not
  # exist" would be an invented death rather than an observed one.
  make_fake_gh "$w/fakebin"
  mask=$(mask_command "$w" tmux)
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live"

  out=$(run_drift "$w" BASH_ENV="$mask"); status=$?

  expect_code 1 "$status" "an undeterminable class must not exit clean"
  assert_class "$out" "$LABEL_A" 0 "unprobeable backend must not invent a finding"
  assert_contains "$out" "incomplete: 1 undetermined" \
    "an unprobeable endpoint must be disclosed as undetermined"
  assert_contains "$out" "the tmux command is not installed" \
    "the note must name the missing worker-runtime command"
  assert_not_contains "$out" "DRIFT CHECK: ok" \
    "a class that could not be probed must never read as clear"
  pass "fm-drift-check: an unprobeable worker runtime is undetermined, never declared dead"
}

# --- class 2: in flight, PR already merged ----------------------------------

test_merged_pr_fires_while_the_open_pr_beside_it_stays_quiet() {
  local w out status log
  w=$(new_world merged-pr)
  log="$w/gh.log"
  make_fake_tmux "$w/fakebin" "fm-sess:fm-merged" "fm-sess:fm-open"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row merged)" "$(in_flight_row open)"
  task_meta "$w" merged "fm-sess:fm-merged" ship https://github.com/o/r/pull/7
  task_meta "$w" open "fm-sess:fm-open" ship https://github.com/o/r/pull/8

  out=$(run_drift "$w" \
    FM_FAKE_GH_MERGED=https://github.com/o/r/pull/7 FM_FAKE_GH_LOG="$log"); status=$?

  expect_code 1 "$status" "an in-flight task on a merged PR must report"
  assert_class "$out" "$LABEL_B" 1 "one merged PR"
  assert_contains "$out" "DRIFT: merged is in flight but its recorded PR is already merged: https://github.com/o/r/pull/7" \
    "the finding must name the task and the full PR URL"
  assert_not_contains "$out" "DRIFT: open " "the open PR beside it must stay quiet"
  assert_grep "https://github.com/o/r/pull/8" "$log" \
    "the open PR must still have been asked about"
  pass "fm-drift-check: a merged PR on an in-flight task fires, an open one does not"
}

test_a_pr_recorded_on_a_task_that_is_not_in_flight_is_never_queried() {
  local w out log
  w=$(new_world pr-not-in-flight)
  log="$w/gh.log"
  : > "$log"
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live"
  task_meta "$w" stale "fm-sess:fm-stale" ship https://github.com/o/r/pull/9

  out=$(run_drift "$w" FM_FAKE_GH_LOG="$log" FM_FAKE_GH_MERGED=https://github.com/o/r/pull/9)

  assert_class "$out" "$LABEL_B" 0 "a record that is not in flight is not this class"
  assert_class "$out" "$LABEL_C" 1 "it belongs to the orphan-record class instead"
  [ ! -s "$log" ] || fail "GitHub was queried for a task that is not in flight: $(cat "$log")"
  pass "fm-drift-check: no GitHub call is made for a record that is not in flight"
}

test_a_recorded_pr_that_is_not_a_github_link_is_never_queried() {
  local w out log
  w=$(new_world pr-not-a-link)
  log="$w/gh.log"
  : > "$log"
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live" ship 'not a url at all'

  out=$(run_drift "$w" FM_FAKE_GH_LOG="$log")

  assert_class "$out" "$LABEL_B" 0 "a malformed recorded link is not a merged PR"
  [ ! -s "$log" ] || fail "a malformed recorded link still cost a query: $(cat "$log")"
  pass "fm-drift-check: a recorded value that is not a GitHub PR link costs no query"
}

# --- class 2 degradation: GitHub unreachable --------------------------------

test_github_failing_degrades_visibly_and_never_reads_as_clean() {
  local w out status
  w=$(new_world github-failing)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live" ship https://github.com/o/r/pull/7

  out=$(run_drift "$w" FM_FAKE_GH_FAIL=1); status=$?

  expect_code 1 "$status" "a class that could not be determined must not exit clean"
  assert_contains "$out" "incomplete: 1 undetermined" \
    "an unanswered lookup must be disclosed"
  assert_contains "$out" "GitHub did not answer for a recorded PR" \
    "the note must say GitHub is what did not answer"
  assert_not_contains "$out" "DRIFT CHECK: ok" \
    "an unanswered GitHub lookup must never render as no drift"
  assert_contains "$out" "DRIFT REMEDY: undetermined is not clear" \
    "the render must say a dash or incomplete note is not an answer of no"
  pass "fm-drift-check: an unreachable GitHub degrades visibly and never reads as clean"
}

test_missing_gh_renders_a_dash_not_a_zero() {
  local w out status mask
  w=$(new_world missing-gh)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  # gh is masked rather than merely absent from the fakebin, so this case can
  # never fall through to the real gh and make a live network call.
  mask=$(mask_command "$w" gh)
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live" ship https://github.com/o/r/pull/7

  out=$(run_drift "$w" BASH_ENV="$mask"); status=$?

  expect_code 1 "$status" "a class that was never evaluated must not exit clean"
  assert_class "$out" "$LABEL_B" '-' "a never-evaluated class must render a dash, not a zero"
  assert_contains "$out" "not checked: gh is not installed" \
    "the dash must be accompanied by its reason"
  assert_not_contains "$out" "DRIFT CHECK: ok" "a never-evaluated class must never read as clear"
  pass "fm-drift-check: with gh absent the merged-PR class renders a dash and its reason"
}

test_no_github_flag_makes_no_call_and_reports_the_class_undetermined() {
  local w out status log
  w=$(new_world no-github-flag)
  log="$w/gh.log"
  : > "$log"
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live" ship https://github.com/o/r/pull/7

  out=$(run_drift "$w" FM_FAKE_GH_LOG="$log" --no-github); status=$?

  expect_code 1 "$status" "--no-github leaves a class undetermined, which is not clean"
  assert_class "$out" "$LABEL_B" '-' "--no-github must render the class as a dash"
  assert_contains "$out" "GitHub lookups disabled" "the dash must name --no-github as the reason"
  [ ! -s "$log" ] || fail "--no-github still called gh: $(cat "$log")"
  pass "fm-drift-check: --no-github makes no call and reports the class undetermined"
}

test_a_fleet_with_no_recorded_pr_at_all_reports_a_true_zero() {
  local w out status
  w=$(new_world no-pr-candidates)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  # gh is available, but nothing in flight records a PR, so there is no question
  # it could have been asked: that is a real zero, not an unevaluated class.
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live"

  out=$(run_drift "$w"); status=$?

  expect_code 0 "$status" "no recorded PR in flight is genuinely clean"
  assert_class "$out" "$LABEL_B" 0 "no candidate means a true zero, not a dash"
  assert_contains "$out" "DRIFT CHECK: ok" "a genuinely clean fleet keeps the ok line"
  pass "fm-drift-check: with no recorded PR in flight the merged-PR class is a true zero"
}

# --- class 3: runtime record, not in flight ---------------------------------

test_orphan_record_fires_while_a_secondmate_record_stays_quiet() {
  local w out status
  w=$(new_world orphan-record)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live" "fm-sess:fm-mate"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live"
  task_meta "$w" orphan "fm-sess:fm-orphan"
  fm_write_secondmate_meta "$w/state/mate.meta" "$w/home-mate" "fm-sess:fm-mate"

  out=$(run_drift "$w"); status=$?

  expect_code 1 "$status" "a runtime record with no in-flight item must report"
  assert_class "$out" "$LABEL_C" 1 "exactly the orphan, not the secondmate"
  assert_contains "$out" "DRIFT: orphan has a durable local record but no in-flight backlog item" \
    "the finding must name the orphan record"
  assert_not_contains "$out" "DRIFT: mate " \
    "a persistent secondmate is never a backlog item and must stay quiet"
  pass "fm-drift-check: an orphan runtime record fires, a secondmate record does not"
}

test_a_record_whose_backlog_item_is_already_done_is_an_orphan() {
  local w out
  w=$(new_world record-vs-done)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-landed"
  make_fake_gh "$w/fakebin"
  {
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n'
    printf -- '- [x] landed - Some work (repo: proj) (kind: ship) (merged 2026-08-09)\n'
  } > "$w/data/backlog.md"
  task_meta "$w" landed "fm-sess:fm-landed"

  out=$(run_drift "$w")

  assert_class "$out" "$LABEL_C" 1 "a record left behind a completed item is drift"
  assert_contains "$out" "DRIFT: landed has a durable local record" \
    "the finding must name the task whose item is already done"
  pass "fm-drift-check: a runtime record left behind a completed backlog item is reported"
}

# --- class 4: in flight, no runtime record ----------------------------------

test_in_flight_item_without_a_record_fires_while_a_captain_row_stays_quiet() {
  local w out status
  w=$(new_world ghost-in-flight)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" \
    "$(in_flight_row live)" \
    "$(in_flight_row ghost)" \
    "$(in_flight_row decide captain)"
  task_meta "$w" live "fm-sess:fm-live"

  out=$(run_drift "$w"); status=$?

  expect_code 1 "$status" "an in-flight item with no runtime record must report"
  assert_class "$out" "$LABEL_D" 1 "exactly the ghost, not the captain-gated row"
  assert_contains "$out" "DRIFT: ghost is in flight but has no durable local record" \
    "the finding must name the item with no record"
  assert_not_contains "$out" "DRIFT: decide " \
    "a captain-gated thread has no worker by design and must stay quiet"
  pass "fm-drift-check: an in-flight item with no runtime record fires, a captain row does not"
}

# --- all four at once, the shape of the 2026-08-09 incident ------------------

test_every_class_fires_together_and_each_is_counted_separately() {
  local w out status
  w=$(new_world all-four)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" \
    "$(in_flight_row live)" \
    "$(in_flight_row gone)" \
    "$(in_flight_row shipped)" \
    "$(in_flight_row ghost)"
  task_meta "$w" live "fm-sess:fm-live"
  task_meta "$w" gone "fm-sess:fm-gone"
  task_meta "$w" shipped "fm-sess:fm-live" ship https://github.com/o/r/pull/30
  task_meta "$w" orphan "fm-sess:fm-orphan"

  out=$(run_drift "$w" FM_FAKE_GH_MERGED=https://github.com/o/r/pull/30); status=$?

  expect_code 1 "$status" "a fleet drifted in four ways must report"
  assert_class "$out" "$LABEL_A" 1 "the dead worker"
  assert_class "$out" "$LABEL_B" 1 "the merged PR"
  assert_class "$out" "$LABEL_C" 1 "the orphan record"
  assert_class "$out" "$LABEL_D" 1 "the item with no record"
  assert_contains "$out" "DRIFT REMEDY: reconcile each line above" "the render must name the remedy"
  assert_contains "$out" "since re-leased to a live task" \
    "the remedy must say why a stale record is dangerous, not just untidy"
  pass "fm-drift-check: all four classes fire together and are counted separately"
}

# --- an unreadable backlog: four dashes, never four zeros -------------------

test_absent_backlog_renders_every_class_as_a_dash() {
  local w out status
  w=$(new_world absent-backlog)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  task_meta "$w" live "fm-sess:fm-live"

  out=$(run_drift "$w"); status=$?

  expect_code 1 "$status" "with no backlog nothing was evaluated, which is not clean"
  assert_class "$out" "$LABEL_A" '-' "class 1 is defined against the In flight section"
  assert_class "$out" "$LABEL_B" '-' "class 2 is defined against the In flight section"
  assert_class "$out" "$LABEL_C" '-' "class 3 is defined against the In flight section"
  assert_class "$out" "$LABEL_D" '-' "class 4 is defined against the In flight section"
  assert_contains "$out" "not checked: no backlog file" "each dash must carry its reason"
  assert_not_contains "$out" "DRIFT CHECK: ok" "an unread backlog must never render as no drift"
  pass "fm-drift-check: an absent backlog renders four dashes, never four zeros"
}

# --- bounds -----------------------------------------------------------------

test_findings_are_bounded_by_the_documented_default_and_disclose_the_rest() {
  local w out limit n i
  w=$(new_world detail-bound)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  # The limit is read from the script's own help at run time, so this case is
  # sized from the bound it guards rather than from a number that happens to
  # work today: raising the default without raising the fixture would otherwise
  # leave the truncation path untested.
  limit=$(env -u FM_DRIFT_DETAIL bash "$DRIFT" --help \
    | sed -n 's/.*FM_DRIFT_DETAIL=\([0-9][0-9]*\).*/\1/p' | head -1)
  case "$limit" in ''|*[!0-9]*) fail "could not read FM_DRIFT_DETAIL's default from --help" ;; esac
  n=$((limit + 1))
  write_backlog "$w" "$(in_flight_row live)"
  task_meta "$w" live "fm-sess:fm-live"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    task_meta "$w" "orphan$i" "fm-sess:fm-orphan$i"
  done

  out=$(run_drift "$w")

  assert_class "$out" "$LABEL_C" "$n" "the count must report every finding, not just the listed ones"
  [ "$(printf '%s\n' "$out" | grep -c '^DRIFT: orphan')" -eq "$limit" ] \
    || fail "listed findings were not bounded to $limit: $out"
  assert_contains "$out" "DRIFT: (+1 more)" "truncation must be disclosed, never silent"
  pass "fm-drift-check: findings are bounded by the documented default and the remainder is disclosed"
}

test_the_lookup_cap_is_disclosed_rather_than_silently_truncating() {
  local w out
  w=$(new_world lookup-cap)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-a" "fm-sess:fm-b"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row a)" "$(in_flight_row b)"
  task_meta "$w" a "fm-sess:fm-a" ship https://github.com/o/r/pull/1
  task_meta "$w" b "fm-sess:fm-b" ship https://github.com/o/r/pull/2

  out=$(run_drift "$w" FM_DRIFT_PR_LOOKUPS=1 FM_FAKE_GH_MERGED=https://github.com/o/r/pull/1)

  assert_contains "$out" "incomplete: 1 undetermined" "the uncapped remainder must be disclosed"
  assert_contains "$out" "stopped after the first 1 PR lookup(s)" \
    "the note must say the cap is what stopped it"
  assert_not_contains "$out" "DRIFT CHECK: ok" "a capped run must never read as clear"
  pass "fm-drift-check: the GitHub lookup cap is disclosed rather than silently truncating"
}

# --- detection only ---------------------------------------------------------

test_the_check_mutates_nothing() {
  local w before after
  w=$(new_world no-mutation)
  make_fake_tmux "$w/fakebin" "fm-sess:fm-live"
  make_fake_gh "$w/fakebin"
  write_backlog "$w" "$(in_flight_row live)" "$(in_flight_row gone)" "$(in_flight_row ghost)"
  task_meta "$w" live "fm-sess:fm-live"
  task_meta "$w" gone "fm-sess:fm-gone"
  task_meta "$w" orphan "fm-sess:fm-orphan" ship https://github.com/o/r/pull/7

  before=$(find "$w/state" "$w/data" | sort | cksum; cat "$w/state"/*.meta "$w/data/backlog.md" | cksum)
  run_drift "$w" FM_FAKE_GH_MERGED=https://github.com/o/r/pull/7 >/dev/null
  after=$(find "$w/state" "$w/data" | sort | cksum; cat "$w/state"/*.meta "$w/data/backlog.md" | cksum)

  [ "$before" = "$after" ] \
    || fail "the drift check changed task state or the backlog"$'\n'"before: $before"$'\n'"after:  $after"
  pass "fm-drift-check: reporting drift never mutates task state or the backlog"
}

# --- run --------------------------------------------------------------------

test_clean_fleet_names_every_class_and_says_ok
test_dead_endpoint_fires_while_the_live_one_beside_it_stays_quiet
test_a_record_naming_no_endpoint_at_all_is_reported
test_an_unprobeable_backend_is_undetermined_never_declared_dead
test_merged_pr_fires_while_the_open_pr_beside_it_stays_quiet
test_a_pr_recorded_on_a_task_that_is_not_in_flight_is_never_queried
test_a_recorded_pr_that_is_not_a_github_link_is_never_queried
test_github_failing_degrades_visibly_and_never_reads_as_clean
test_missing_gh_renders_a_dash_not_a_zero
test_no_github_flag_makes_no_call_and_reports_the_class_undetermined
test_a_fleet_with_no_recorded_pr_at_all_reports_a_true_zero
test_orphan_record_fires_while_a_secondmate_record_stays_quiet
test_a_record_whose_backlog_item_is_already_done_is_an_orphan
test_in_flight_item_without_a_record_fires_while_a_captain_row_stays_quiet
test_every_class_fires_together_and_each_is_counted_separately
test_absent_backlog_renders_every_class_as_a_dash
test_findings_are_bounded_by_the_documented_default_and_disclose_the_rest
test_the_lookup_cap_is_disclosed_rather_than_silently_truncating
test_the_check_mutates_nothing
