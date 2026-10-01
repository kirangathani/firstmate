#!/usr/bin/env bash
# Behavior tests for bin/fm-release-watch.sh - the "a project's post-merge
# release workflow failed on its default branch" sweep.
#
# THE FIXTURES ARE REAL. tests/fixtures/release-watch/ holds the exact stdout of
# gh 2.100.0 against kirangathani/eln on 2026-10-01, during the incident that
# motivated this sweep (deploy-production.yml failing on every push to main):
#   run-list-in-progress-over-failure.json
#     gh run list --workflow deploy-production.yml --branch main --limit 10 \
#       --json databaseId,status,conclusion,headSha,url,displayTitle
#     (newest run still in_progress, the next ones completed failures)
#   run-list-success.json
#     the same query with --status success --limit 3
#   run-view-jobs.json
#     gh run view 36866987087 --json jobs
# The in-progress-only case is the first element of the first capture.
#
# Hermetic: a fake `gh` serving those bytes, a throwaway clone whose origin
# merely names the GitHub repo, and a home under one temp root. No network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-release-watch)
WATCH="$ROOT/bin/fm-release-watch.sh"
FIXTURES="$ROOT/tests/fixtures/release-watch"
FAILED_RUN_URL=https://github.com/kirangathani/eln/actions/runs/36866987087

# make_home <name> [opt-in]: a home with an eln clone, and the opt-in record
# only when a second argument is given. Prints the home path.
make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state"
  fm_git_init_commit "$home/projects/eln" >/dev/null
  git -C "$home/projects/eln" remote add origin git@github.com:kirangathani/eln.git
  git -C "$home/projects/eln" update-ref refs/remotes/origin/main HEAD
  git -C "$home/projects/eln" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  if [ $# -ge 2 ]; then
    mkdir -p "$home/data/release-workflows"
    printf '# production release\ndeploy-production.yml\n' > "$home/data/release-workflows/eln"
  fi
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "run list") cat "$FAKE_RUN_LIST" ;;
  "run view") cat "$FAKE_RUN_VIEW" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$fakebin/gh"
  printf '%s\n' "$home"
}

# sweep <home> <run-list-file>: one sweep against the given run listing.
sweep() {
  local home=$1
  FM_HOME="$home" env -u FM_STATE_OVERRIDE PATH="$home/fakebin:$PATH" \
    FAKE_GH_LOG="$home/gh.log" FAKE_RUN_LIST="$2" FAKE_RUN_VIEW="$FIXTURES/run-view-jobs.json" \
    "$WATCH" --surface
}

test_a_new_failed_run_wakes_once_naming_commit_step_and_url() {
  local home out
  home=$(make_home fail on)
  out=$(sweep "$home" "$FIXTURES/run-list-in-progress-over-failure.json")
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "expected exactly one wake line, got: $out"
  assert_contains "$out" "project eln" "the wake does not name the project"
  assert_contains "$out" "deploy-production.yml" "the wake does not name the workflow"
  assert_contains "$out" "ab19b50" "the wake does not name the commit"
  assert_contains "$out" 'job "release" failed at step "What would be pushed (dry run)"' "the wake does not name the failed job and step"
  assert_contains "$out" "$FAILED_RUN_URL" "the wake does not carry the run URL"
  pass "fm-release-watch: a new failed release run wakes once naming commit, step and run link"
}

test_the_same_failed_run_does_not_wake_twice() {
  local home out
  home=$(make_home repeat on)
  sweep "$home" "$FIXTURES/run-list-in-progress-over-failure.json" >/dev/null
  out=$(sweep "$home" "$FIXTURES/run-list-in-progress-over-failure.json")
  [ -z "$out" ] || fail "an already reported run woke again: $out"
  pass "fm-release-watch: an already reported failed run does not wake again"
}

test_a_successful_latest_run_is_silent() {
  local home out
  home=$(make_home success on)
  out=$(sweep "$home" "$FIXTURES/run-list-success.json")
  [ -z "$out" ] || fail "a successful release woke firstmate: $out"
  pass "fm-release-watch: a successful latest release run is silent"
}

test_an_in_progress_run_is_silent() {
  local home out
  home=$(make_home progress on)
  jq '[.[0]]' "$FIXTURES/run-list-in-progress-over-failure.json" > "$home/in-progress.json"
  [ "$(jq -r '.[0].status' "$home/in-progress.json")" = in_progress ] \
    || fail "precondition: the first captured run must be in progress"
  out=$(sweep "$home" "$home/in-progress.json")
  [ -z "$out" ] || fail "an in-progress release woke firstmate: $out"
  pass "fm-release-watch: an in-progress release run is silent"
}

test_a_project_without_opt_in_is_never_queried() {
  local home out
  home=$(make_home none)
  out=$(sweep "$home" "$FIXTURES/run-list-in-progress-over-failure.json")
  [ -z "$out" ] || fail "a project with no opt-in woke firstmate: $out"
  [ ! -s "$home/gh.log" ] || fail "a project with no opt-in was queried: $(cat "$home/gh.log")"
  pass "fm-release-watch: a project with no opt-in is never queried"
}

test_a_new_failed_run_wakes_once_naming_commit_step_and_url
test_the_same_failed_run_does_not_wake_twice
test_a_successful_latest_run_is_silent
test_an_in_progress_run_is_silent
test_a_project_without_opt_in_is_never_queried
