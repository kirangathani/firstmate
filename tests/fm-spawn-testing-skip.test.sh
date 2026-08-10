#!/usr/bin/env bash
# tests/fm-spawn-testing-skip.test.sh - behavior tests for bin/fm-spawn.sh's
# testing-skip flags (--local-skip, --ci-skip, --all-testing-skip).
#
# The load-bearing case is (l): --local-skip must ENFORCE the skip, not request
# it, so that test does not assert the shim exists - it runs the real thing
# through the exact environment the spawn installs and shows that a genuine
# no-mistakes invocation never reaches the real binary. Case (m) is its
# necessary other half: the same enforcement must not leak into any other
# environment.
#
# Matrix:
#   (a) two skip flags on one command line refuse, naming --all-testing-skip
#   (b) a scout spawn refuses every skip flag
#   (c) a secondmate spawn refuses every skip flag
#   (d) local-only refuses every skip flag (no pipeline, no PR, no CI)
#   (e) direct-PR refuses --local-skip (it already runs no local pipeline)
#   (f) no-mistakes refuses --ci-skip alone (the pipeline owns push and PR, so a
#       commit-bound waiver cannot reach the PR's first CI run)
#   (g) every refusal happens before any backend or worktree work
#   (h) --all-testing-skip on a no-mistakes project records both meta fields
#   (i) --ci-skip on a direct-PR project records ci_skip= only, and installs no
#       shim, because that mode's local pipeline is untouched
#   (j) an unflagged spawn records neither field, so existing meta is unchanged
#   (j2) a CI skip also records the dispatch authorization the signer requires,
#        and refuses outright when no secret exists to mint one
#   (j3) a LOCAL skip records its own dispatch authorization, under its own
#        payload domain so the two tokens differ for the same task, and the value
#        recorded is one this home's key actually reproduces
#   (j4) a local skip with NO secret still spawns - the enforcement below needs
#        none - but says on stderr exactly what the missing key costs and how to
#        get it back, rather than silently recording an unusable flag
#   (k) --local-skip puts the shim FIRST on the worker pane's own PATH
#   (l) a real `no-mistakes` invocation under that PATH never reaches the real
#       binary, exits 0, and is told the skip was intentional
#   (m) the same real invocation outside that PATH still reaches the real binary,
#       so the shim is scoped to the one worker and leaks nowhere
#   (n) the shim says the same thing on stdout as on stderr, so a caller that
#       parses stdout alone cannot read exit 0 as a pipeline that ran and passed
#   (o) a symlink planted at the predictable per-task temp root is refused before
#       anything is written through it
#
# One action (the defect these were added for): a skip used to need the flag on
# this script AND the same flag on bin/fm-brief.sh, and giving it to only one
# silently produced an ordinary task.
#   (q1) one flag writes both halves - the authorization the signer checks and
#        the instructions the worker reads
#   (q2) an unflagged dispatch of a brief that still carries skip text restores
#        the ordinary instructions and records no skip, so a brief can never
#        outlive the dispatch that justified it
#   (q3) --skip-testing resolves to the most each delivery mode can honour, says
#        what it resolved to, and refuses local-only rather than resolving to a
#        no-op
#   (q4) every mode refusal prints the accepted matrix
#   (q5) a brief that cannot carry the skip stops the dispatch before any
#        worktree, terminal, or temp root exists
#   (q6) a relaunch that forgets the flag names the authorized skip it is
#        dropping, since the record is rewritten wholesale
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-testing-skip)

# Per-task temp roots are a fixed /tmp/fm-<id> path that fm-teardown.sh normally
# removes, so this suite cleans up its own. Registration happens in make_case, in
# the parent shell: every spawn here is invoked as out=$(run_spawn ...), and an
# append inside that command substitution would be lost with its subshell.
SPAWNED_TASK_TMPS=()
cleanup_all() {
  local d
  for d in "${SPAWNED_TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap cleanup_all EXIT

# Fake Orca CLI. Orca is used here purely because it is the one spawn-capable
# backend that provides its own worktree, so a full successful spawn needs no
# treehouse and no terminal emulator. Same shape as the fake in
# tests/fm-backend-orca.test.sh, which owns the adapter's own tests.
make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

# Build a home with a project registry entry in <mode>, a brief, and (for the
# Orca cases) a real git worktree. Sets CASE_HOME CASE_PROJ CASE_WT CASE_LOG
# CASE_RESP CASE_FB for the case named by <id>.
make_case() {  # <id> <mode>
  local id=$1 mode=$2 dir
  SPAWNED_TASK_TMPS+=("/tmp/fm-$id")
  dir="$TMP_ROOT/$id"
  CASE_HOME="$dir/home"
  CASE_PROJ="$dir/alpha"
  CASE_WT="$dir/wt"
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/state" "$CASE_HOME/config" "$CASE_PROJ" "$dir/responses"
  touch "$CASE_HOME/state/.last-watcher-beat"
  {
    echo '# Projects'
    printf -- '- alpha [%s] - test project (added 2026-08-05)\n' "$mode"
  } > "$CASE_HOME/data/projects.md"
  # A REAL scaffolded brief rather than a stand-in string. A dispatch now
  # rewrites the brief's own testing-skip regions, so a hand-written fixture
  # would exercise a shape bin/fm-brief.sh never produces - and would pass while
  # every real dispatch refused.
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    "$ROOT/bin/fm-brief.sh" "$id" alpha >/dev/null
  CASE_LOG="$dir/log"
  CASE_RESP="$dir/responses"
  : > "$CASE_LOG"
  CASE_FB=$(make_orca_fakebin "$dir")
}

# A --ci-skip dispatch mints its authorization token from this home's waiver
# secret, so a case that exercises one needs that secret to exist.
give_case_a_waiver_secret() {
  printf '%s\n' 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff \
    > "$CASE_HOME/config/ci-waiver-secret"
  chmod 600 "$CASE_HOME/config/ci-waiver-secret"
}

# Arrange the fake Orca answers for one successful spawn into CASE_WT. The fake
# answers by call NUMBER, so a case that spawns twice re-arms between the two
# rather than running off the end of the responses the first spawn consumed.
rearm_orca_success() {
  rm -f "$CASE_RESP/.count"
  printf '1\n' > "$CASE_RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-x"}}}\n' > "$CASE_RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-x","path":"%s"},"terminal":{"handle":"term-x"}}}\n' \
    "$CASE_WT" > "$CASE_RESP/3.out"
}

arm_orca_success() {
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "fm/spawned"
  rearm_orca_success
}

run_spawn() {  # <id> [<extra spawn args>...]
  local id=$1
  shift
  PATH="$CASE_FB:$PATH" \
    FM_ORCA_LOG="$CASE_LOG" \
    FM_ORCA_RESPONSES="$CASE_RESP" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" \
    FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$CASE_PROJ" claude --backend orca "$@" 2>&1
}

# --- refusals ---------------------------------------------------------------

# One row per refused combination: <label>|<mode>|<flags>|<expected substring>.
# Every one must refuse before the fake Orca is ever called, because a spawn that
# creates a worktree and then refuses leaves an orphan behind.
test_refused_combinations() {
  local label mode flags expect id out status i=0
  while IFS='|' read -r label mode flags expect; do
    [ -n "$label" ] || continue
    i=$((i + 1))
    id="refuse$i"
    make_case "$id" "$mode"
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$id" $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a refusal"$'\n'"$out"
    assert_contains "$out" "$expect" "$label: wrong refusal"
    assert_absent "$CASE_HOME/state/$id.meta" "$label: a refused spawn wrote task metadata"
    # A readiness probe is fine; creating anything is not, because a refusal
    # after a worktree or terminal exists leaves an orphan behind.
    assert_not_contains "$(cat "$CASE_LOG")" "worktree" "$label: refused only after creating a worktree"
    assert_not_contains "$(cat "$CASE_LOG")" "terminal" "$label: refused only after creating a terminal"
    assert_absent "/tmp/fm-$id" "$label: refused only after creating the per-task temp root"
  done <<'ROWS'
two skip flags at once|no-mistakes|--local-skip --ci-skip|pass exactly one testing-skip flag
repeated skip flag|no-mistakes|--local-skip --local-skip|pass exactly one testing-skip flag
scout takes no skip|no-mistakes|--scout --local-skip|applies only to a ship task
local-only takes no skip|local-only|--all-testing-skip|does not apply to a local-only project
local-only refuses ci-skip|local-only|--ci-skip|does not apply to a local-only project
direct-PR refuses local-skip|direct-PR|--local-skip|already runs no local pipeline
direct-PR refuses all-testing-skip|direct-PR|--all-testing-skip|already runs no local pipeline
no-mistakes refuses ci-skip alone|no-mistakes|--ci-skip|cannot be honoured for a no-mistakes project
ROWS
  pass "refused skip/mode combinations stop before any backend or worktree work"
}

test_secondmate_refuses_a_skip_flag() {
  local out status
  make_case sm-refuse no-mistakes
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_HOME/state" \
    FM_DATA_OVERRIDE="$CASE_HOME/data" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" sm-refuse "$CASE_HOME/sub" --secondmate --ci-skip 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn should refuse a skip flag"
  assert_contains "$out" "applies only to a ship task" "secondmate refusal did not name the ship-only rule"
  pass "a secondmate spawn refuses every testing-skip flag"
}

# --- recorded state ---------------------------------------------------------

test_meta_records_only_the_flags_that_were_passed() {
  local out
  make_case bothskip no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn bothskip --all-testing-skip)
  expect_code 0 $? "spawn with --all-testing-skip should succeed"$'\n'"$out"
  assert_grep "local_skip=on" "$CASE_HOME/state/bothskip.meta" "--all-testing-skip did not record local_skip"
  assert_grep "ci_skip=on" "$CASE_HOME/state/bothskip.meta" "--all-testing-skip did not record ci_skip"
  assert_grep "ci_skip_auth=" "$CASE_HOME/state/bothskip.meta" \
    "--all-testing-skip did not record the dispatch authorization the signer requires"
  assert_grep "local_skip_auth=" "$CASE_HOME/state/bothskip.meta" \
    "--all-testing-skip did not record the local skip's own dispatch authorization"
  assert_contains "$out" "local_skip=on ci_skip=on" "spawn summary did not disclose the skips"

  make_case ciskip direct-PR
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn ciskip --ci-skip)
  expect_code 0 $? "spawn with --ci-skip on a direct-PR project should succeed"$'\n'"$out"
  assert_grep "ci_skip=on" "$CASE_HOME/state/ciskip.meta" "--ci-skip did not record ci_skip"
  assert_no_grep "local_skip=on" "$CASE_HOME/state/ciskip.meta" "--ci-skip wrongly recorded a local skip"
  assert_grep "ci_skip_auth=" "$CASE_HOME/state/ciskip.meta" "--ci-skip did not record its dispatch authorization"
  assert_no_grep "local_skip_auth=" "$CASE_HOME/state/ciskip.meta" \
    "--ci-skip wrongly minted the local skip's authorization"
  assert_absent "/tmp/fm-ciskip/skip-bin" "--ci-skip must not install the local-pipeline shim"

  make_case noskip no-mistakes
  arm_orca_success
  out=$(run_spawn noskip)
  expect_code 0 $? "an unflagged spawn should succeed"$'\n'"$out"
  assert_no_grep "local_skip=" "$CASE_HOME/state/noskip.meta" "an unflagged task recorded a local skip field"
  assert_no_grep "ci_skip=" "$CASE_HOME/state/noskip.meta" "an unflagged task recorded a ci skip field"
  assert_no_grep "ci_skip_auth=" "$CASE_HOME/state/noskip.meta" "an unflagged task recorded a dispatch authorization"
  assert_no_grep "local_skip_auth=" "$CASE_HOME/state/noskip.meta" \
    "an unflagged task recorded a local dispatch authorization"
  assert_absent "/tmp/fm-noskip/skip-bin" "an unflagged task must install no shim"
  pass "meta and shim record exactly the flags that were passed, and nothing else"
}

# --- one action -------------------------------------------------------------

# The defect this suite's newest cases exist for: authorizing a skip used to
# take the flag on THIS script plus the same flag on bin/fm-brief.sh, and
# passing it to only one of the two silently produced an ordinary task. The
# dispatch now writes both halves from one flag, so the brief the worker
# actually reads and the record the signer actually checks cannot disagree.
test_one_flag_writes_both_halves() {
  local out brief
  make_case oneflag no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn oneflag --all-testing-skip)
  expect_code 0 $? "spawn with --all-testing-skip should succeed"$'\n'"$out"
  brief="$CASE_HOME/data/oneflag/brief.md"
  # The record the signer checks...
  assert_grep "ci_skip=on" "$CASE_HOME/state/oneflag.meta" "the dispatch did not record the CI skip"
  # ...and the instructions the worker reads, from that same one flag.
  assert_grep "CI waiver handshake" "$brief" \
    "the dispatch minted a CI-skip authorization but never told the worker how to use it"
  assert_grep "local testing skipped" "$brief" \
    "the dispatch switched the local pipeline off but the brief still reads as an ordinary task"
  assert_grep '<!-- fm:definition-of-done skip=all -->' "$brief" \
    "the brief does not record the skip its dispatch was authorized for"
  pass "one flag at dispatch writes both the authorization and the worker's own instructions"
}

# The other direction. A brief carrying skip text is not a skip, so a dispatch
# without the flag must put the ordinary instructions back AND record nothing -
# otherwise a brief could outlive the dispatch that justified it and quietly
# steer a later, unauthorized task.
test_an_unflagged_dispatch_undoes_a_brief_that_still_carries_a_skip() {
  local out brief
  make_case stalebrief no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  brief="$CASE_HOME/data/stalebrief/brief.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    "$ROOT/bin/fm-brief.sh" --apply-testing-skip stalebrief --mode no-mistakes --all-testing-skip >/dev/null
  assert_grep "CI waiver handshake" "$brief" "the fixture did not actually carry a skip"

  out=$(run_spawn stalebrief)
  expect_code 0 $? "an unflagged spawn should succeed"$'\n'"$out"
  assert_no_grep "ci_skip=" "$CASE_HOME/state/stalebrief.meta" \
    "a brief carrying skip text produced a recorded skip"
  assert_no_grep "local_skip=" "$CASE_HOME/state/stalebrief.meta" \
    "a brief carrying skip text produced a recorded skip"
  assert_no_grep "CI waiver handshake" "$brief" \
    "an unflagged dispatch left the worker asking for a waiver it was never authorized"
  assert_no_grep "local testing skipped" "$brief" \
    "an unflagged dispatch left the worker told its pipeline was switched off"
  assert_grep "no-mistakes doctor" "$brief" "the ordinary pipeline instructions were not restored"
  pass "an unflagged dispatch restores the ordinary brief and records no skip"
}

# A relaunch that forgets the flag DOWNGRADES the task, because the record is
# rewritten wholesale, so it says so rather than dropping an authorized skip
# quietly on the way through recovery.
test_a_relaunch_that_drops_an_authorized_skip_says_so() {
  local out
  make_case relaunch no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn relaunch --all-testing-skip)
  expect_code 0 $? "the first dispatch should succeed"$'\n'"$out"

  rearm_orca_success
  out=$(run_spawn relaunch)
  expect_code 0 $? "the relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "carries local_skip=on, but this dispatch passed no local skip" \
    "a relaunch dropped an authorized local skip without saying so"
  assert_contains "$out" "carries ci_skip=on, but this dispatch passed no CI skip" \
    "a relaunch dropped an authorized CI skip without saying so"
  assert_no_grep "ci_skip=on" "$CASE_HOME/state/relaunch.meta" \
    "the relaunch reported the drop but kept the record"
  pass "a relaunch that drops an authorized skip names exactly what was lost"
}

# --skip-testing exists so the accepted matrix stops being something to look up.
# It must resolve to the most each mode can honour, say what it resolved to, and
# deliver both halves of that resolution.
test_skip_testing_resolves_per_delivery_mode() {
  local out status
  make_case autoall no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn autoall --skip-testing)
  expect_code 0 $? "--skip-testing should succeed on a no-mistakes project"$'\n'"$out"
  assert_contains "$out" "resolves to --all-testing-skip" "--skip-testing did not say what it resolved to"
  assert_grep "local_skip=on" "$CASE_HOME/state/autoall.meta" "--skip-testing did not take the local pipeline"
  assert_grep "ci_skip=on" "$CASE_HOME/state/autoall.meta" "--skip-testing did not take CI"
  assert_grep "local_skip_auth=" "$CASE_HOME/state/autoall.meta" \
    "--skip-testing recorded a local skip with no authorization behind it"
  assert_grep "ci_skip_auth=" "$CASE_HOME/state/autoall.meta" \
    "--skip-testing recorded a CI skip with no authorization behind it"
  assert_grep "CI waiver handshake" "$CASE_HOME/data/autoall/brief.md" \
    "--skip-testing did not write the worker's half"

  make_case autoci direct-PR
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn autoci --skip-testing)
  expect_code 0 $? "--skip-testing should succeed on a direct-PR project"$'\n'"$out"
  assert_contains "$out" "resolves to --ci-skip" "--skip-testing did not say what it resolved to"
  assert_grep "ci_skip=on" "$CASE_HOME/state/autoci.meta" "--skip-testing did not take CI on a direct-PR project"
  assert_no_grep "local_skip=on" "$CASE_HOME/state/autoci.meta" \
    "--skip-testing invented a local-pipeline skip for a mode that runs no pipeline"

  # local-only has nothing to skip, so the one flag that never needs the matrix
  # still refuses rather than resolving to a no-op.
  make_case autonone local-only
  out=$(run_spawn autonone --skip-testing); status=$?
  [ "$status" -ne 0 ] || fail "--skip-testing must refuse a local-only project"
  assert_contains "$out" "nothing to skip on a local-only project" \
    "--skip-testing on local-only did not say why there was nothing to do"
  assert_absent "$CASE_HOME/state/autonone.meta" "a refused --skip-testing spawn wrote task metadata"
  pass "--skip-testing resolves to the most each delivery mode can honour, and says so"
}

# Every mode refusal prints the matrix at the point of refusal, so the accepted
# combinations are never something to go and look up mid-dispatch.
test_refusals_print_the_accepted_matrix() {
  local out status
  make_case matrixhint direct-PR
  out=$(run_spawn matrixhint --local-skip); status=$?
  [ "$status" -ne 0 ] || fail "direct-PR must refuse --local-skip"
  assert_contains "$out" "accepted by delivery mode" "the refusal did not print the accepted matrix"
  assert_contains "$out" "or pass --skip-testing" "the refusal did not name the flag that needs no matrix"
  pass "a refused combination prints the accepted matrix and the flag that avoids it"
}

# A dispatch that cannot write the worker's half must not launch at all: a
# worker running ordinary instructions under a record that says its testing was
# skipped is precisely the silent half-skip this arrangement removes.
test_a_brief_that_cannot_carry_the_skip_stops_the_dispatch() {
  local out status
  make_case nomarkers no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  printf 'a brief written before this contract existed\n' > "$CASE_HOME/data/nomarkers/brief.md"
  out=$(run_spawn nomarkers --all-testing-skip); status=$?
  [ "$status" -ne 0 ] || fail "a spawn must refuse a brief it cannot bring into agreement"
  assert_contains "$out" "has no machine-written testing-skip regions" \
    "the refusal did not name what was wrong with the brief"
  assert_absent "$CASE_HOME/state/nomarkers.meta" "a refused spawn wrote task metadata"
  assert_not_contains "$(cat "$CASE_LOG")" "worktree" "the spawn refused only after creating a worktree"
  assert_absent "/tmp/fm-nomarkers" "the spawn refused only after creating the per-task temp root"
  pass "a brief that cannot carry the skip stops the dispatch before anything is created"
}

# --- enforcement ------------------------------------------------------------

# The demonstration, not an assertion: a real `no-mistakes` binary is placed on
# PATH where a worker would find it, the spawn's own exported PATH is recovered
# from what it actually sent to the worker's pane, and a genuine pipeline
# invocation is run through it.
# A --ci-skip dispatch that cannot mint its authorization is useless - no waiver
# could ever be signed for it - so it refuses immediately instead of launching a
# worker that will be told to ask for a signature nobody can produce.
test_ci_skip_without_a_secret_refuses() {
  local out status
  make_case nosecret direct-PR
  arm_orca_success
  out=$(run_spawn nosecret --ci-skip)
  status=$?
  [ "$status" -ne 0 ] || fail "--ci-skip should refuse when the home has no waiver secret"
  assert_contains "$out" "needs this home's CI waiver secret" "the refusal did not name the missing secret"
  assert_contains "$out" "fm-ci-waiver.sh init" "the refusal did not say how to fix it"
  assert_absent "$CASE_HOME/state/nosecret.meta" "a refused --ci-skip spawn wrote task metadata"
  pass "--ci-skip refuses when no waiver secret exists to authorize it"
}

# The local skip's own dispatch authorization: the value bin/fm-pr-merge.sh
# checks before that flag may excuse anything. Recomputed here through the same
# library the spawn mints with, from the throwaway key give_case_a_waiver_secret
# planted, so this asserts the RECORDED value is one the home's key reproduces
# rather than merely that some hex was written.
expected_dispatch_token() {  # <task-id> <local|ci>
  local id=$1 kind=$2 fn=fm_ci_waiver_dispatch_local_token
  [ "$kind" = local ] || fn=fm_ci_waiver_dispatch_token
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; "$1" "$2"' "$ROOT" "$fn" "$id" \
    < "$CASE_HOME/config/ci-waiver-secret"
}

test_local_skip_records_its_own_dispatch_authorization() {
  local out local_token ci_token
  make_case localauth no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn localauth --local-skip)
  expect_code 0 $? "spawn with --local-skip should succeed"$'\n'"$out"

  local_token=$(expected_dispatch_token localauth local)
  ci_token=$(expected_dispatch_token localauth ci)
  assert_grep "local_skip_auth=$local_token" "$CASE_HOME/state/localauth.meta" \
    "--local-skip did not record an authorization this home's key reproduces"
  assert_no_grep "ci_skip=" "$CASE_HOME/state/localauth.meta" \
    "--local-skip wrongly recorded a CI skip"
  [ "$local_token" != "$ci_token" ] \
    || fail "the two skip flags mint the SAME token for one task, so either would authorize the other"
  pass "--local-skip records a dispatch authorization of its own, in its own payload domain"
}

# --local-skip must keep working in a home that has never run fm-ci-waiver.sh
# init, because its enforcement needs no key at all. What it must not do is stay
# quiet: the loss only shows up much later, as a merge refusal.
test_local_skip_without_a_secret_warns_but_still_spawns() {
  local out
  make_case localnosecret no-mistakes
  arm_orca_success
  out=$(run_spawn localnosecret --local-skip)
  expect_code 0 $? "--local-skip must still spawn without a signing key"$'\n'"$out"
  assert_grep "local_skip=on" "$CASE_HOME/state/localnosecret.meta" \
    "--local-skip did not record the skip it still enforces"
  assert_no_grep "local_skip_auth=" "$CASE_HOME/state/localnosecret.meta" \
    "a spawn with no signing key recorded an authorization token anyway"
  assert_present "/tmp/fm-localnosecret/skip-bin" \
    "--local-skip did not install its enforcement shim without a key"
  assert_contains "$out" "WITHOUT an authorization token" \
    "the spawn did not say the skip was recorded unauthorized"
  assert_contains "$out" "fm-ci-waiver.sh init" \
    "the spawn did not say how to get the authorization back"
  pass "--local-skip without a signing key still spawns, and says exactly what that costs"
}

test_local_skip_cannot_be_run_around() {
  local out real_bin export_line worker_path invoked marker on_stdout on_stderr
  make_case enforced no-mistakes
  arm_orca_success

  # A stand-in for the real no-mistakes: if the worker ever reaches it, it
  # leaves a marker, so "the pipeline ran" is directly observable.
  real_bin="$TMP_ROOT/enforced/realbin"
  marker="$TMP_ROOT/enforced/PIPELINE-RAN"
  mkdir -p "$real_bin"
  cat > "$real_bin/no-mistakes" <<SH
#!/usr/bin/env bash
printf 'real no-mistakes ran: %s\n' "\$*" > '$marker'
exit 0
SH
  chmod +x "$real_bin/no-mistakes"

  out=$(PATH="$real_bin:$PATH" run_spawn enforced --local-skip)
  expect_code 0 $? "spawn with --local-skip should succeed"$'\n'"$out"

  # What the spawn actually sent into the worker's pane, recovered from the
  # backend log rather than reconstructed here.
  export_line=$(grep -F 'export PATH=' "$CASE_LOG" | tail -1)
  [ -n "$export_line" ] || fail "spawn never sent a PATH export to the worker's pane"$'\n'"$(cat "$CASE_LOG")"
  assert_contains "$export_line" "/tmp/fm-enforced/skip-bin" "the exported PATH does not carry this task's shim"
  worker_path="/tmp/fm-enforced/skip-bin:$real_bin:$PATH"

  # A genuine pipeline invocation, exactly as a worker would make it.
  invoked=$(PATH="$worker_path" bash -c 'no-mistakes axi run --json' 2>&1)
  expect_code 0 $? "the shim must exit 0 so the agent does not try to repair its toolchain"$'\n'"$invoked"
  assert_absent "$marker" "the worker reached the real no-mistakes despite --local-skip"
  assert_contains "$invoked" "intentionally disabled" "the shim did not say the skip was intentional"
  assert_contains "$invoked" "--local-skip" "the shim did not name the flag responsible"
  assert_contains "$invoked" "open the PR" "the shim did not point the worker at push and PR"
  [ "$(PATH="$worker_path" command -v no-mistakes)" = "/tmp/fm-enforced/skip-bin/no-mistakes" ] \
    || fail "the shim is not first on the worker's PATH"

  # Both streams carry the same message. Exit 0 with an empty stdout is the one
  # combination a caller parsing stdout alone could read as a pipeline that ran
  # and passed.
  on_stdout=$(PATH="$worker_path" bash -c 'no-mistakes axi run --json' 2>/dev/null)
  on_stderr=$(PATH="$worker_path" bash -c 'no-mistakes axi run --json' 2>&1 >/dev/null)
  assert_contains "$on_stdout" "intentionally disabled" "the shim wrote nothing to stdout"
  [ "$on_stdout" = "$on_stderr" ] || fail "the shim's stdout and stderr messages differ"$'\n'"$on_stdout"$'\n---\n'"$on_stderr"

  # The other half: the enforcement is scoped to that one worker. Outside its
  # exported PATH the real binary is still reachable, so nothing global was
  # renamed, removed, or shadowed.
  PATH="$real_bin:$PATH" bash -c 'no-mistakes axi run --json' >/dev/null 2>&1
  assert_present "$marker" "the shim leaked outside the worker it was installed for"
  pass "--local-skip: a worker cannot run the pipeline, and no other environment is affected"
}

# /tmp/fm-<id> is a predictable path under a world-writable sticky directory, so
# another local user can plant one. A symlink has to be refused on its own terms:
# -e and -O both follow it, so an ownership test alone would judge the target the
# link points at, not the link somebody else controls.
test_a_planted_temp_root_symlink_is_refused() {
  local out status target
  make_case planted no-mistakes
  arm_orca_success
  target="$TMP_ROOT/planted/attacker-target"
  mkdir -p "$target"
  rm -rf /tmp/fm-planted
  ln -s "$target" /tmp/fm-planted
  out=$(run_spawn planted --local-skip)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn should refuse a symlinked per-task temp root"$'\n'"$out"
  assert_contains "$out" "refusing to use /tmp/fm-planted" "the refusal did not name the temp root"
  assert_absent "$target/gotmp" "the spawn wrote Go's temp dir through the planted symlink"
  assert_absent "$target/skip-bin" "the spawn wrote the shim through the planted symlink"
  assert_absent "$CASE_HOME/state/planted.meta" "a refused spawn wrote task metadata"
  pass "a symlink planted at the per-task temp root is refused before anything is written"
}

# The drift guard between the flags' WRITER and their READERS. bin/fm-spawn.sh
# is the only thing that records them; bin/fm-pr-merge.sh's waiver banner and
# the fleet pipeline view's skipped-stage rendering both read them back, through
# bin/fm-testing-skip-lib.sh. A change to what spawn writes that this owner does
# not follow would leave the merge log and the captain's view quietly claiming a
# task runs stages it does not - which is exactly what the view used to do.
#
# It reads the meta the real spawn above just wrote, so there is no hand-written
# copy of the recorded format anywhere in this assertion.
test_recorded_skips_read_back_through_their_owner() {
  local out probe
  make_case readback no-mistakes
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn readback --all-testing-skip)
  expect_code 0 $? "spawn with --all-testing-skip should succeed"$'\n'"$out"

  # shellcheck disable=SC2016  # a script body for bash -c: $0/$1 are its args
  probe='. "$0/bin/fm-testing-skip-lib.sh"; fm_testing_skip_read "$1";
         printf "%s/%s\n" "$FM_TESTING_SKIP_LOCAL" "$FM_TESTING_SKIP_CI"'
  got=$(bash -c "$probe" "$ROOT" "$CASE_HOME/state/readback.meta")
  [ "$got" = "on/on" ] ||
    fail "the flags spawn recorded do not read back through their own owner: $got"

  make_case readback2 direct-PR
  give_case_a_waiver_secret
  arm_orca_success
  out=$(run_spawn readback2 --ci-skip)
  expect_code 0 $? "spawn with --ci-skip should succeed"$'\n'"$out"
  got=$(bash -c "$probe" "$ROOT" "$CASE_HOME/state/readback2.meta")
  [ "$got" = "off/on" ] || fail "a CI-only skip read back as $got"

  make_case readback3 no-mistakes
  arm_orca_success
  out=$(run_spawn readback3)
  expect_code 0 $? "an unflagged spawn should succeed"$'\n'"$out"
  got=$(bash -c "$probe" "$ROOT" "$CASE_HOME/state/readback3.meta")
  [ "$got" = "off/off" ] || fail "an unflagged task read back as $got"
  pass "what the spawn records is what the flags' own owner reads back, in all three shapes"
}

test_refused_combinations
test_secondmate_refuses_a_skip_flag
test_recorded_skips_read_back_through_their_owner
test_a_planted_temp_root_symlink_is_refused
test_meta_records_only_the_flags_that_were_passed
test_one_flag_writes_both_halves
test_an_unflagged_dispatch_undoes_a_brief_that_still_carries_a_skip
test_a_relaunch_that_drops_an_authorized_skip_says_so
test_skip_testing_resolves_per_delivery_mode
test_refusals_print_the_accepted_matrix
test_a_brief_that_cannot_carry_the_skip_stops_the_dispatch
test_ci_skip_without_a_secret_refuses
test_local_skip_records_its_own_dispatch_authorization
test_local_skip_without_a_secret_warns_but_still_spawns
test_local_skip_cannot_be_run_around
