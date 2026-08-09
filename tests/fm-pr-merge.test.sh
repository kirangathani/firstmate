#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a branch missing a test identifier the base already had is refused
#       before gh-axi pr merge (bin/fm-assert-tests-kept.sh gate); the clean
#       branch in (a)/(c)/(e)/(g) passing through that same gate covers the
#       merge-normally side
#   (j) a branch that keeps a base test's name but rewrites its assertion body
#       (the Z/K case) is refused before gh-axi pr merge (check 2)
#   (k) a clean branch whose base tests actually execute merges normally
#   (l) a failing base assertion with a VALID captain supersession entry in
#       data/supersessions/<project>.md merges normally
#   (m) a supersession entry missing a required field is NOT honored
#
# Three-class finding consumption and the batch supersession format are driven
# off a CONSTRUCTED fm-assert-tests-kept.sh stdout + exit code (make_stub_case),
# because the unexecuted: class comes from detector-side execution work that
# lands separately; see that helper's comment for the shim mechanics.
#   (n) an unexecuted finding with no per-project exec-gate marker is
#       informational and merges (today's warn-only behavior)
#   (o) the same unexecuted finding with the marker present refuses
#   (p) missing/failing refuse whether or not the marker is present
#   (p2) an EXCUSED missing finding alongside a gated unexecuted one still
#       refuses: the decision comes from all three classes' counts, never from a
#       single-class path (the leak this series closes)
#   (q) a legacy single-id entry excuses exactly its own identifier, no more
#   (r) an ids: glob batch excuses every matching identifier
#   (s) an ids: glob batch does not excuse a non-matching identifier
#   (t) kind: restricts a batch, so an `ids: * | kind: unexecuted` entry can
#       never excuse a missing finding
#   (u) `ids: *` with NO kind excuses every class (documented back-compat)
#   (v) an invalid kind, or any field written after reason, is warned and
#       ignored, never silently treated as kind: any
#   (w) an entry carrying neither id: nor ids: is warned and ignored
#   (x) exit 1 with no parseable finding line refuses as unverified
#   (y) exit 2 still refuses as unverifiable
#
# Checks-green gate (classification table and zero-checks contract in
# bin/fm-pr-merge.sh's header), driven off a mocked statusCheckRollup answer:
# AI-attribution gate (contract in docs/attribution-gate.md), driven off a
# mocked body/commits answer. The commit-msg hook half of the same rule, and the
# local-only landing gate, are in tests/fm-attribution-gate.test.sh:
#   (aa1) a PR whose commit message carries a coauthor trailer is refused
#   (aa2) a PR whose DESCRIPTION carries a generated-with footer is refused, and
#         the refusal says the body is already public
#   (aa3) the gate refuses before the kept-tests gate spends its run, proven on a
#         branch that would fail both
#   (aa4) an unreadable body/commits query refuses as unverified
#
#   (z1) a red PR is refused with the failing check named, before gh-axi
#   (z2) a pending PR is refused distinctly from a red one
#   (z3) a red check outranks a pending one in the refusal
#   (z4) a green PR (including NEUTRAL/SKIPPED conclusions) merges unchanged;
#        every earlier merge-success case also passes through this gate via the
#        mock's default green rollup
#   (z5) zero checks with no data/no-pr-ci/<project> marker refuses
#   (z6) zero checks with the captain's marker present merges with a note
#   (z7) an unreadable rollup (gh query failure) refuses as unverified
#   (z8) an entry the classification table cannot classify refuses as
#        unverified rather than guessed at
#
# Testing-waiver disclosure (contract in bin/fm-pr-merge.sh's header), driven off
# the skip fields bin/fm-spawn.sh records in the task's own meta:
#   (w1) a waived PR merges and prints the banner both before the gates and on
#        the line before the merge
#   (w2) an unflagged task's merge log is byte-unchanged
#   (w3) the waiver does not excuse a red PR
#   (w4) the waiver does not excuse a PR reporting zero checks
#   (w5) the kept-tests gate still runs, and still refuses, under every
#        skip-flag combination
#
# The branch-suite premise behind check 2's identical-file skip (contract in
# bin/fm-pr-merge.sh's header), asserted from the stub detector's own argv:
#   (p1) an ordinary merge passes --assume-branch-suite-green, since its own
#        checks-green gate is what holds that premise up
#   (p2) a ci_skip=on task does NOT, and says the gate re-ran in full: a waiver
#        removes the very suite the premise names
#   (p3) a project with the no-pr-ci marker does NOT either, since that marker
#        lets an EMPTY rollup pass the checks-green gate
#   (p4) `assumed-covered:` lines are disclosed with a count in the merge log
#        and are never treated as a finding
#
# The attestation exemption (contract in bin/fm-pr-merge.sh's header): exactly
# one named check may be excused, and only on authority the PR cannot supply.
#   (x1) a direct-PR project merges past a FAILED attestation check, and the log
#        names the exemption and its authority
#   (x2) the same PR with any OTHER check failing refuses
#   (x3) the same PR with a check still pending refuses, distinctly
#   (x4) a skip-flagged task whose meta carries a VALID signature merges past it
#   (x5) the same flag with a MISSING signature refuses - the forgery this whole
#        design exists to stop, since a worker can append the flag line itself
#   (x6) the same flag with a WRONG signature refuses, and says the key does not
#        reproduce it
#   (x7) a signature minted under the OTHER flag's payload domain does not
#        transfer, so one authorized skip never widens into the other
#   (x8) a no-mistakes project with no skip flag refuses exactly as before
#   (x9) an exempted check is not evidence, so a rollup holding nothing else
#        refuses as a zero-check PR would
#   (x10) a RENAMED attestation check is no longer recognized, so it is no longer
#        excused and refuses (the rename direction that costs a merge, never
#        grants one)
#   (x11) the excused name still equals the workflow job name that reports it
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta, a
# fakebin with a gh-axi mock that records how it was invoked, and a real
# project repo plus fm/task-x1 worktree (identical to main, one baseline shell
# test) so the bin/fm-assert-tests-kept.sh merge gate can resolve and pass.
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git init -q -b main "$case_dir/project" 2>/dev/null || {
    git init -q "$case_dir/project"
    git -C "$case_dir/project" checkout -q -b main
  }
  mkdir -p "$case_dir/project/tests"
  # Self-contained (pass/fail helpers inline) so the merge gate's check 2 can
  # actually execute it. An unexecutable base test file is a finding in its own
  # right, which would refuse every merge these cases are trying to exercise.
  cat > "$case_dir/project/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass "alpha holds"
EOF
  git -C "$case_dir/project" add -A
  git -C "$case_dir/project" commit -qm baseline
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup plus statusCheckRollup for the
# checks-green gate. The rollup answer is the case's pr-checks.tsv when present
# (lines in the gate's own TSV shape: typename, status, conclusion, state,
# name), one green CheckRun by default, and a query failure when the
# pr-checks-unreadable marker exists. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *baseRefName*) printf '%s\n' 'main' ; exit 0 ;;
      *" body "*)
        # The AI-attribution gate's one API read: the PR description as raw
        # text. The case's pr-body.txt when present, nothing otherwise - an
        # empty description is a real PR state and carries no attribution. The
        # pr-body-unreadable marker makes the read FAIL, which is the case that
        # must still refuse.
        if [ -e '$case_dir/pr-body-unreadable' ]; then
          echo 'mock: body query failed' >&2
          exit 1
        fi
        if [ -f '$case_dir/pr-body.txt' ]; then
          cat '$case_dir/pr-body.txt'
        fi
        exit 0
        ;;
      *statusCheckRollup*)
        if [ -e '$case_dir/pr-checks-unreadable' ]; then
          echo 'mock: rollup query failed' >&2
          exit 1
        fi
        if [ -f '$case_dir/pr-checks.tsv' ]; then
          cat '$case_dir/pr-checks.tsv'
        else
          printf 'CheckRun\tCOMPLETED\tSUCCESS\t-\tmock-default-ci\n'
        fi
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step. The gh mock
# answers the checks-green gate's rollup query green so the run reaches the
# merge call it is testing.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *statusCheckRollup*) printf 'CheckRun\tCOMPLETED\tSUCCESS\t-\tmock-default-ci\n' ;;
  *baseRefName*) printf 'main\n' ;;
  *" body "*) ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# FM_HOME is pinned to a per-case dir so the supersession lookup at
# $FM_HOME/data/supersessions/<project>.md is hermetic and never reads the real
# firstmate home's records.
run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/fmhome" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

# make_zk_case <name>: like make_case, but the project fixture is the plan's
# Z/K worked example with a runnable self-contained shell test (pass/fail
# helpers inline), so the merge gate's check 2 actually executes it: main has
# app.sh producing Z and tests/x.test.sh asserting Z under the stable name
# "X behaves". The fm/task-x1 worktree starts identical to main. Echoes the
# case dir.
make_zk_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git init -q -b main "$case_dir/project" 2>/dev/null || {
    git init -q "$case_dir/project"
    git -C "$case_dir/project" checkout -q -b main
  }
  mkdir -p "$case_dir/project/tests"
  printf '#!/usr/bin/env bash\necho Z\n' > "$case_dir/project/app.sh"
  cat > "$case_dir/project/tests/x.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
out=$(bash ./app.sh)
[ "$out" = "Z" ] || fail "X behaves"
pass "X behaves"
EOF
  git -C "$case_dir/project" add -A
  git -C "$case_dir/project" commit -qm baseline
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf '%s\n' "$case_dir"
}

# rewrite_zk_branch <case_dir>: the resolver takes K's side in BOTH files -
# app.sh now produces K and the test keeps its name but asserts K, so the
# behavior main guaranteed is gone while every test name survives.
rewrite_zk_branch() {
  local case_dir=$1
  printf '#!/usr/bin/env bash\necho K\n' > "$case_dir/wt/app.sh"
  cat > "$case_dir/wt/tests/x.test.sh" <<'EOF'
#!/usr/bin/env bash
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
out=$(bash ./app.sh)
[ "$out" = "K" ] || fail "X behaves"
pass "X behaves"
EOF
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "resolver takes K in both app.sh and test"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_missing_base_test_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case test-keep-refuses)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  cat > "$case_dir/wt/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
EOF
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "drop alpha"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "test-keep-refuses: fm-pr-merge should refuse"
  assert_grep 'missing: tests/app.test.sh::alpha holds' "$case_dir/stdout" \
    "test-keep-refuses: the vanished assertion was not reported by name"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "test-keep-refuses: refusal did not explain itself"
  assert_grep 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "test-keep-refuses: pr= should still be recorded before the gate refuses"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "test-keep-refuses: gh-axi pr merge was invoked despite a missing base test"
  pass "fm-pr-merge refuses to merge when a base test identifier is missing from the branch"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_rewritten_assertion_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_zk_case zk-rewrite-refuses)
  rewrite_zk_branch "$case_dir"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "zk-rewrite-refuses: fm-pr-merge should refuse"
  assert_grep 'failing: tests/x.test.sh::X behaves' "$case_dir/stdout" \
    "zk-rewrite-refuses: the rewritten assertion was not reported as failing by name"
  assert_no_grep 'missing: tests/x.test.sh' "$case_dir/stdout" \
    "zk-rewrite-refuses: check 1 should see the surviving name (check 2 is what refuses here)"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "zk-rewrite-refuses: refusal did not explain itself"
  assert_grep 'escalate needs-decision' "$case_dir/stderr" \
    "zk-rewrite-refuses: refusal did not route the supersession decision to the captain"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "zk-rewrite-refuses: gh-axi pr merge was invoked despite a failing base assertion"
  pass "fm-pr-merge refuses a kept-name rewritten assertion (check 2) before calling gh-axi"
}

test_clean_runnable_branch_merges_normally() {
  local case_dir
  case_dir=$(make_zk_case zk-clean-merges)
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "zk-clean-merges: fm-pr-merge failed"

  grep -qxF 'pr merge 42 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "zk-clean-merges: a clean branch with executing base tests did not merge normally"
  pass "a clean branch whose base tests execute green merges normally"
}

test_valid_supersession_entry_merges_normally() {
  local case_dir
  case_dir=$(make_zk_case supersession-valid)
  rewrite_zk_branch "$case_dir"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"
  mkdir -p "$case_dir/fmhome/data/supersessions"
  cat > "$case_dir/fmhome/data/supersessions/project.md" <<'EOF'
# Supersessions for project
- id: tests/x.test.sh::X behaves | project: project | date: 2026-07-19 | reason: captain approved K superseding Z behavior
EOF

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "supersession-valid: fm-pr-merge failed"

  assert_grep 'captain-approved supersession covers: tests/x.test.sh::X behaves' "$case_dir/stderr" \
    "supersession-valid: the excused assertion was not named"
  grep -qxF 'pr merge 43 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "supersession-valid: a fully-excused failing assertion did not merge normally"
  pass "a failing base assertion with a valid captain supersession entry merges normally"
}

test_supersession_entry_missing_field_not_honored() {
  local case_dir rc
  case_dir=$(make_zk_case supersession-malformed)
  rewrite_zk_branch "$case_dir"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"
  mkdir -p "$case_dir/fmhome/data/supersessions"
  cat > "$case_dir/fmhome/data/supersessions/project.md" <<'EOF'
# Supersessions for project
- id: tests/x.test.sh::X behaves | project: project | reason: no date recorded
EOF

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "supersession-malformed: an entry missing its date field must not excuse the merge"
  assert_grep 'ignoring supersession entry missing a required field' "$case_dir/stderr" \
    "supersession-malformed: the malformed entry was not warned about"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "supersession-malformed: refusal did not explain itself"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "supersession-malformed: gh-axi pr merge was invoked despite a malformed supersession entry"
  pass "a supersession entry missing a required field is not honored"
}

### three-class finding consumption and batch supersessions ##################
#
# make_stub_case <name> <detector-exit> [<finding line>...]: a case whose merge
# gate reads a CONSTRUCTED fm-assert-tests-kept.sh result instead of the real
# detector. A shim bin/ holds symlinks to the REAL fm-pr-merge.sh and
# fm-pr-check.sh, so the code under test is the real code resolved through its
# own SCRIPT_DIR, next to a stub detector that prints the given finding lines and
# exits with the given code. This is how the unexecuted: class is exercised
# before the detector that emits it exists, and it also lets a single case mix
# finding classes that no one fixture could produce together. Echoes the case dir.
make_stub_case() {
  local name=$1 exit_code=$2
  shift 2
  local case_dir fakebin shimbin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  shimbin="$case_dir/shimbin"
  mkdir -p "$case_dir/state" "$fakebin" "$shimbin" "$case_dir/project"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # Mirror every real bin script into the shim dir so SCRIPT_DIR-relative
  # sourcing (fm-pr-lib.sh and its transitive deps) resolves, then shadow only
  # the detector with the stub written below.
  local binfile
  for binfile in "$ROOT/bin/"*.sh; do
    ln -s "$binfile" "$shimbin/$(basename "$binfile")"
  done
  rm -f "$shimbin/fm-assert-tests-kept.sh"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$case_dir/kept-findings"
  else
    : > "$case_dir/kept-findings"
  fi
  # The stub records its own argv, so the premise cases below can assert which
  # arguments fm-pr-merge.sh actually handed the detector rather than inferring
  # it from an outcome that would look the same either way.
  : > "$case_dir/kept-argv"
  cat > "$shimbin/fm-assert-tests-kept.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$case_dir/kept-argv"
cat "$case_dir/kept-findings"
exit $exit_code
SH
  chmod +x "$shimbin/fm-assert-tests-kept.sh"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

# Same environment as run_pr_merge, but invoking the shimmed fm-pr-merge.sh so
# the stub detector is the sibling it resolves.
run_pr_merge_stub() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/fmhome" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/shimbin/fm-pr-merge.sh" "$@"
}

# enable_exec_gate <case_dir>: create the per-project marker that makes
# unexecuted findings block for this case's project.
enable_exec_gate() {
  local case_dir=$1
  mkdir -p "$case_dir/fmhome/data/exec-gate"
  touch "$case_dir/fmhome/data/exec-gate/project"
}

# write_supersessions <case_dir> <entry line>...
write_supersessions() {
  local case_dir=$1
  shift
  mkdir -p "$case_dir/fmhome/data/supersessions"
  {
    printf '%s\n' "# Supersessions for project"
    printf '%s\n' "$@"
  } > "$case_dir/fmhome/data/supersessions/project.md"
}

test_unexecuted_without_marker_is_informational_and_merges() {
  local case_dir
  case_dir=$(make_stub_case unexecuted-no-marker 1 'unexecuted: tests/x.test.sh::X behaves')

  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unexecuted-no-marker: an ungated unexecuted finding must not block the merge"

  assert_grep 'note: unexecuted (not gated for project): tests/x.test.sh::X behaves' "$case_dir/stderr" \
    "unexecuted-no-marker: the ungated finding was not reported as informational"
  assert_no_grep 'refusing to merge' "$case_dir/stderr" \
    "unexecuted-no-marker: an ungated unexecuted finding caused a refusal"
  grep -qxF 'pr merge 51 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "unexecuted-no-marker: the merge did not proceed"
  pass "an unexecuted finding is informational and non-blocking when the project has no exec-gate marker"
}

test_unexecuted_with_marker_refuses() {
  local case_dir rc
  case_dir=$(make_stub_case unexecuted-marker 1 'unexecuted: tests/x.test.sh::X behaves')
  enable_exec_gate "$case_dir"

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unexecuted-marker: a gated unexecuted finding must refuse the merge"
  assert_grep 'no captain-approved supersession entry covers: tests/x.test.sh::X behaves (unexecuted)' "$case_dir/stderr" \
    "unexecuted-marker: the gated finding was not named as uncovered"
  assert_grep 'unverified rather than proven broken' "$case_dir/stderr" \
    "unexecuted-marker: the refusal did not explain what unexecuted means"
  assert_no_grep 'not gated for project' "$case_dir/stderr" \
    "unexecuted-marker: the finding was still treated as informational"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unexecuted-marker: gh-axi pr merge was invoked despite a gated unexecuted finding"
  pass "an unexecuted finding refuses the merge once the project's exec-gate marker exists"
}

test_missing_and_failing_refuse_regardless_of_marker() {
  local case_dir rc marker
  for marker in absent present; do
    case_dir=$(make_stub_case "classes-refuse-marker-$marker" 1 \
      'missing: tests/a.test.sh::alpha holds' \
      'failing: tests/b.test.sh::beta holds')
    [ "$marker" = present ] && enable_exec_gate "$case_dir"

    set +e
    run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "classes-refuse-marker-$marker: missing/failing must refuse"
    assert_grep 'covers: tests/a.test.sh::alpha holds (missing)' "$case_dir/stderr" \
      "classes-refuse-marker-$marker: the missing finding was not named"
    assert_grep 'covers: tests/b.test.sh::beta holds (failing)' "$case_dir/stderr" \
      "classes-refuse-marker-$marker: the failing finding was not named"
    assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
      "classes-refuse-marker-$marker: gh-axi pr merge was invoked despite missing/failing findings"
  done
  pass "missing and failing findings refuse the merge whether or not the exec-gate marker exists"
}

test_excused_missing_plus_gated_unexecuted_refuses() {
  local case_dir rc
  # Regression for the leak this series closes: when the ONLY counted findings
  # were missing/failing and one of them was excused, an unexecuted finding
  # alongside it was silently ignored and the merge proceeded (excused=1,
  # unexcused=0, so neither refusal condition fired). The decision must come
  # from the parsed-and-policy-applied counts of ALL THREE classes, so a gated
  # unexecuted finding refuses even when every missing/failing one is excused.
  case_dir=$(make_stub_case excused-missing-plus-unexecuted 1 \
    'missing: tests/y.test.sh::Y behaves' \
    'unexecuted: tests/x.test.sh::X behaves')
  enable_exec_gate "$case_dir"
  write_supersessions "$case_dir" \
    '- id: tests/y.test.sh::Y behaves | project: project | date: 2026-08-01 | reason: captain approved dropping Y'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "excused-missing-plus-unexecuted: a gated unexecuted finding must refuse even when the missing one is excused"
  assert_grep 'captain-approved supersession covers: tests/y.test.sh::Y behaves (missing)' "$case_dir/stderr" \
    "excused-missing-plus-unexecuted: the excused missing finding was not reported as excused"
  assert_grep 'no captain-approved supersession entry covers: tests/x.test.sh::X behaves (unexecuted)' "$case_dir/stderr" \
    "excused-missing-plus-unexecuted: the unexecuted finding was silently ignored alongside an excused finding"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "excused-missing-plus-unexecuted: gh-axi pr merge was invoked with an uncovered unexecuted finding"
  pass "an excused missing finding does not let a gated unexecuted finding through"
}

test_legacy_single_id_entry_excuses_exactly_its_identifier() {
  local case_dir rc
  case_dir=$(make_stub_case legacy-id-exact 1 \
    'failing: tests/x.test.sh::X behaves' \
    'failing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | project: project | date: 2026-07-19 | reason: captain approved K superseding Z behavior'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-id-exact: an unexcused second finding must still refuse"
  assert_grep 'captain-approved supersession covers: tests/x.test.sh::X behaves (failing)' "$case_dir/stderr" \
    "legacy-id-exact: the legacy entry did not excuse its own identifier"
  assert_grep 'no captain-approved supersession entry covers: tests/y.test.sh::Y behaves (failing)' "$case_dir/stderr" \
    "legacy-id-exact: the legacy entry excused an identifier it does not name"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "legacy-id-exact: gh-axi pr merge was invoked with one finding unexcused"
  pass "a legacy single-id supersession entry excuses exactly its own identifier and nothing else"
}

test_ids_glob_batch_excuses_matching_findings() {
  local case_dir
  case_dir=$(make_stub_case ids-glob-matches 1 \
    'failing: tests/legacy/a.test.sh::one' \
    'failing: tests/legacy/b.test.sh::two')
  write_supersessions "$case_dir" \
    '- ids: tests/legacy/*::* | project: project | kind: failing | date: 2026-08-01 | reason: captain approved the legacy suite rewrite'

  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "ids-glob-matches: a fully-excused batch did not merge"

  assert_grep 'captain-approved supersession covers: tests/legacy/a.test.sh::one (failing)' "$case_dir/stderr" \
    "ids-glob-matches: the first glob-matched finding was not excused"
  assert_grep 'captain-approved supersession covers: tests/legacy/b.test.sh::two (failing)' "$case_dir/stderr" \
    "ids-glob-matches: the second glob-matched finding was not excused"
  grep -qxF 'pr merge 55 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "ids-glob-matches: the merge did not proceed"
  pass "an ids: glob batch entry excuses every identifier it matches"
}

test_ids_glob_does_not_excuse_non_matching_finding() {
  local case_dir rc
  case_dir=$(make_stub_case ids-glob-non-match 1 \
    'failing: tests/legacy/a.test.sh::one' \
    'failing: tests/core/c.test.sh::three')
  write_supersessions "$case_dir" \
    '- ids: tests/legacy/*::* | project: project | kind: failing | date: 2026-08-01 | reason: captain approved the legacy suite rewrite'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ids-glob-non-match: a finding outside the glob must still refuse"
  assert_grep 'captain-approved supersession covers: tests/legacy/a.test.sh::one (failing)' "$case_dir/stderr" \
    "ids-glob-non-match: the glob-matched finding was not excused"
  assert_grep 'no captain-approved supersession entry covers: tests/core/c.test.sh::three (failing)' "$case_dir/stderr" \
    "ids-glob-non-match: a finding outside the glob was excused"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "ids-glob-non-match: gh-axi pr merge was invoked with a finding outside the glob"
  pass "an ids: glob batch entry does not excuse an identifier outside its glob"
}

test_kind_restricted_batch_does_not_excuse_missing() {
  local case_dir rc
  case_dir=$(make_stub_case kind-restricts-batch 1 \
    'unexecuted: tests/x.test.sh::X behaves' \
    'missing: tests/y.test.sh::Y behaves')
  enable_exec_gate "$case_dir"
  write_supersessions "$case_dir" \
    '- ids: * | project: project | kind: unexecuted | date: 2026-08-01 | reason: bumped the runner, captain reviewed the suite manually'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "kind-restricts-batch: a kind-restricted batch must not excuse a missing finding"
  assert_grep 'captain-approved supersession covers: tests/x.test.sh::X behaves (unexecuted)' "$case_dir/stderr" \
    "kind-restricts-batch: the batch did not excuse the class it names"
  assert_grep 'no captain-approved supersession entry covers: tests/y.test.sh::Y behaves (missing)' "$case_dir/stderr" \
    "kind-restricts-batch: the batch silently excused a deleted assertion"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "kind-restricts-batch: gh-axi pr merge was invoked despite an unexcused missing finding"
  pass "kind: restricts a batch entry to its own finding class, never excusing a deleted assertion"
}

test_wildcard_ids_without_kind_excuses_every_class() {
  local case_dir
  # Adversarial and deliberate: `ids: *` with an ABSENT kind is documented
  # back-compat (absent kind means any), so it excuses every class for the whole
  # project. This proves the documented behavior rather than quietly narrowing
  # it; the header warns the captain that such an entry is a loaded gun.
  case_dir=$(make_stub_case wildcard-no-kind 1 \
    'missing: tests/a.test.sh::alpha holds' \
    'failing: tests/b.test.sh::beta holds' \
    'unexecuted: tests/c.test.sh::gamma holds')
  enable_exec_gate "$case_dir"
  write_supersessions "$case_dir" \
    '- ids: * | project: project | date: 2026-08-01 | reason: captain accepted the whole-suite rewrite'

  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "wildcard-no-kind: a kindless wildcard batch must excuse every class"

  assert_grep 'covers: tests/a.test.sh::alpha holds (missing)' "$case_dir/stderr" \
    "wildcard-no-kind: the missing finding was not excused"
  assert_grep 'covers: tests/b.test.sh::beta holds (failing)' "$case_dir/stderr" \
    "wildcard-no-kind: the failing finding was not excused"
  assert_grep 'covers: tests/c.test.sh::gamma holds (unexecuted)' "$case_dir/stderr" \
    "wildcard-no-kind: the unexecuted finding was not excused"
  grep -qxF 'pr merge 58 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "wildcard-no-kind: the fully-excused merge did not proceed"
  pass "an ids: * entry with no kind excuses every finding class, as the back-compat contract documents"
}

test_invalid_kind_entry_not_honored() {
  local case_dir rc
  case_dir=$(make_stub_case invalid-kind 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | project: project | kind: whatever | date: 2026-08-01 | reason: typo must not degrade to any'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "invalid-kind: an unrecognized kind must not excuse the merge"
  assert_grep 'ignoring supersession entry whose kind is not missing, failing, unexecuted, unstable, or any' "$case_dir/stderr" \
    "invalid-kind: the invalid kind was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "invalid-kind: gh-axi pr merge was invoked despite an invalid kind"
  pass "a supersession entry naming an invalid kind is warned about and never honored"
}

test_unstable_finding_refuses_and_explains_the_test_defect() {
  local case_dir rc
  # An unstable finding means the BASE's own test named one assertion two ways
  # across the detector's two runs, so nothing could be compared. It refuses for
  # every project with no exec-gate-style opt-in, and the message must send the
  # reader at the test rather than at the branch under review.
  case_dir=$(make_stub_case unstable-refuses 1 'unstable: tests/t.test.sh::took (1s)')

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unstable-refuses: an unstable finding must refuse the merge"
  assert_grep 'no captain-approved supersession entry covers: tests/t.test.sh::took (1s) (unstable)' \
    "$case_dir/stderr" "unstable-refuses: the unstable finding was not parsed and counted"
  assert_grep "defect in the BASE's test" "$case_dir/stderr" \
    "unstable-refuses: the message must point at the test, not at the branch"
  assert_no_grep 'none of its output parsed' "$case_dir/stderr" \
    "unstable-refuses: an unstable line must parse as a finding, not fall through as unrecognized output"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unstable-refuses: gh-axi pr merge was invoked despite an unstable finding"
  pass "an unstable finding refuses the merge and names the base test as the defect"
}

test_unstable_kind_supersession_is_honored_and_scoped() {
  local case_dir
  # kind: unstable must be a recognized class - and, being a kind, must stay
  # scoped: the same entry may not excuse a genuinely deleted assertion.
  case_dir=$(make_stub_case unstable-kind 1 'unstable: tests/t.test.sh::took (1s)')
  write_supersessions "$case_dir" \
    '- ids: tests/t.test.sh::* | project: project | kind: unstable | date: 2026-08-01 | reason: captain accepted the moving name while the test fix lands'

  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unstable-kind: a kind: unstable entry must excuse an unstable finding"
  assert_grep 'covers: tests/t.test.sh::took (1s) (unstable)' "$case_dir/stderr" \
    "unstable-kind: the unstable finding was not excused by its own kind"

  case_dir=$(make_stub_case unstable-kind-scoped 1 'missing: tests/t.test.sh::took (1s)')
  write_supersessions "$case_dir" \
    '- ids: tests/t.test.sh::* | project: project | kind: unstable | date: 2026-08-01 | reason: captain accepted the moving name while the test fix lands'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  set -e
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unstable-kind: a kind: unstable entry must not excuse a deleted (missing) assertion"
  pass "kind: unstable excuses an unstable finding and nothing else"
}

test_field_after_reason_not_honored() {
  local case_dir rc
  # A kind written after reason would be swallowed into the reason text, so the
  # entry would silently widen to kind: any. That must refuse, not parse loosely.
  case_dir=$(make_stub_case field-after-reason 1 'missing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- ids: * | project: project | date: 2026-08-01 | reason: bumped the runner | kind: unexecuted'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "field-after-reason: an entry with a field after reason must not excuse the merge"
  assert_grep 'reason must be the last field' "$case_dir/stderr" \
    "field-after-reason: the misordered entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "field-after-reason: gh-axi pr merge was invoked despite a misordered entry"
  pass "a supersession entry with a field written after reason is warned about and never honored"
}

test_no_space_field_after_reason_not_honored() {
  local case_dir rc
  # The same swallowing as field-after-reason, one character narrower: without
  # the space after the colon the entry would parse as ids: * with kind: any and
  # excuse a missing finding the captain meant to scope to unexecuted.
  case_dir=$(make_stub_case field-after-reason-no-space 1 'missing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- ids: * | project: project | date: 2026-08-01 | reason: bumped the runner | kind:unexecuted'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "field-after-reason-no-space: a no-space field after reason must not excuse the merge"
  assert_grep 'reason must be the last field' "$case_dir/stderr" \
    "field-after-reason-no-space: the misordered entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "field-after-reason-no-space: gh-axi pr merge was invoked despite a misordered entry"
  pass "a field written after reason with no space after its colon is warned about and never honored"
}

test_duplicated_kind_field_not_honored() {
  local case_dir rc
  # Taking the last value would widen kind: unexecuted to kind: any and excuse a
  # genuinely missing assertion.
  case_dir=$(make_stub_case duplicate-kind 1 'missing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- ids: * | project: project | kind: unexecuted | kind: any | date: 2026-08-01 | reason: a repeat must not widen the entry'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "duplicate-kind: a duplicated kind must not excuse the merge"
  assert_grep "ignoring supersession entry with a duplicated field 'kind'" "$case_dir/stderr" \
    "duplicate-kind: the duplicated field was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "duplicate-kind: gh-axi pr merge was invoked despite a duplicated field"
  pass "a supersession entry repeating kind: is warned about and never honored"
}

test_duplicated_ids_field_not_honored() {
  local case_dir rc
  # The finding matches the second glob but not the first, so a last-wins parse
  # would excuse it and merge.
  case_dir=$(make_stub_case duplicate-ids 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- ids: tests/legacy/* | ids: * | project: project | date: 2026-08-01 | reason: a repeat must not widen the glob'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/67 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "duplicate-ids: a duplicated ids must not excuse the merge"
  assert_grep "ignoring supersession entry with a duplicated field 'ids'" "$case_dir/stderr" \
    "duplicate-ids: the duplicated field was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "duplicate-ids: gh-axi pr merge was invoked despite a duplicated field"
  pass "a supersession entry repeating ids: is warned about and never honored"
}

test_entry_with_both_id_and_ids_not_honored() {
  local case_dir rc
  case_dir=$(make_stub_case both-id-and-ids 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | ids: * | project: project | date: 2026-08-01 | reason: exactly one identifier field is allowed'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/68 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "both-id-and-ids: an entry carrying both identifier fields must not excuse the merge"
  assert_grep "carrying both 'id:' and 'ids:' (use exactly one)" "$case_dir/stderr" \
    "both-id-and-ids: the two-identifier entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "both-id-and-ids: gh-axi pr merge was invoked despite an entry carrying both id: and ids:"
  pass "a supersession entry carrying both id: and ids: is warned about and never honored"
}

test_unparseable_or_unrecognized_field_not_honored() {
  local case_dir rc
  # Two shapes of the same fail-closed branch: a field with no `key: value`
  # structure at all, and a well-formed field naming a key this grammar has no
  # meaning for. Neither may be skipped over into a partially parsed entry.
  case_dir=$(make_stub_case unrecognized-field 1 \
    'failing: tests/x.test.sh::X behaves' \
    'failing: tests/y.test.sh::Y behaves')
  write_supersessions "$case_dir" \
    '- id: tests/x.test.sh::X behaves | project: project | scope: everything | date: 2026-08-01 | reason: an unknown key must refuse' \
    '- id: tests/y.test.sh::Y behaves | project: project | oops | date: 2026-08-01 | reason: a structureless field must refuse'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/69 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unrecognized-field: neither malformed entry may excuse the merge"
  assert_grep "ignoring supersession entry with an unrecognized field 'scope'" "$case_dir/stderr" \
    "unrecognized-field: the unrecognized key was not warned about"
  assert_grep "ignoring supersession entry with an unparseable field 'oops'" "$case_dir/stderr" \
    "unrecognized-field: the structureless field was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unrecognized-field: gh-axi pr merge was invoked despite unparseable supersession entries"
  pass "a supersession entry with an unparseable or unrecognized field is warned about and never honored"
}

test_entry_without_id_or_ids_not_honored() {
  local case_dir rc
  case_dir=$(make_stub_case no-id-field 1 'failing: tests/x.test.sh::X behaves')
  write_supersessions "$case_dir" \
    '- project: project | date: 2026-08-01 | reason: forgot the identifier entirely'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-id-field: an entry with no identifier must not excuse the merge"
  assert_grep "carries neither 'id:' nor 'ids:' as its first field" "$case_dir/stderr" \
    "no-id-field: the identifier-less entry was not warned about"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "no-id-field: gh-axi pr merge was invoked despite an identifier-less entry"
  pass "a supersession entry carrying neither id: nor ids: is warned about and ignored"
}

test_findings_exit_with_no_parseable_line_refuses() {
  local case_dir rc
  case_dir=$(make_stub_case unparseable-findings 1 'something went sideways')

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unparseable-findings: exit 1 with no parseable finding must refuse"
  assert_grep 'none of its output parsed as a missing:/failing:/unexecuted:/unstable: line' "$case_dir/stderr" \
    "unparseable-findings: the refusal did not explain the unparseable output"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unparseable-findings: gh-axi pr merge was invoked on unparseable gate output"
  pass "a findings exit whose output has no parseable finding line refuses as unverified"
}

test_unverifiable_exit_refuses() {
  local case_dir rc
  case_dir=$(make_stub_case unverifiable-exit 2)

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unverifiable-exit: exit 2 must refuse as unverifiable"
  assert_grep 'could not verify the base'"'"'s tests are kept' "$case_dir/stderr" \
    "unverifiable-exit: the refusal did not explain that the check could not run"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unverifiable-exit: gh-axi pr merge was invoked on an unverifiable gate result"
  pass "an unverifiable gate exit still refuses the merge"
}

### checks-green gate ########################################################

# write_pr_checks <case_dir> <tsv line>...: set the mocked statusCheckRollup
# answer for the case. Lines use the gate's TSV shape (typename, status,
# conclusion, state, name); pass none for a zero-check PR.
write_pr_checks() {
  local case_dir=$1
  shift
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$case_dir/pr-checks.tsv"
  else
    : > "$case_dir/pr-checks.tsv"
  fi
}

# write_pr_body <case-dir> <text>: the PR description the gh mock will hand the
# AI-attribution gate.
write_pr_body() {
  printf '%s\n' "$2" > "$1/pr-body.txt"
}

# commit_on_branch <case-dir> <message>: put a real commit carrying <message> on
# the case's fm/task-x1 worktree. The attribution gate reads commit messages out
# of git rather than the API, so a case that needs a dirty commit needs a real
# one - which is also a truer fixture than a JSON string claiming to be one.
commit_on_branch() {
  local case_dir=$1 message=$2
  printf 'change\n' >> "$case_dir/wt/README.md"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -q -m "$message"
}

# enable_no_pr_ci <case_dir>: create the captain's per-project marker that lets
# a zero-check PR merge for this case's project.
enable_no_pr_ci() {
  local case_dir=$1
  mkdir -p "$case_dir/fmhome/data/no-pr-ci"
  touch "$case_dir/fmhome/data/no-pr-ci/project"
}

test_red_pr_refused_with_failing_check_named() {
  local case_dir rc
  case_dir=$(make_case checks-red)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000001
  : > "$case_dir/gh-axi.log"
  write_pr_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tlint'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "checks-red: a red PR must refuse"
  assert_grep 'error: PR check is failing: lint' "$case_dir/stderr" \
    "checks-red: the failing check was not named"
  assert_grep 'refusing to merge a red PR' "$case_dir/stderr" \
    "checks-red: the refusal did not say the PR is red"
  assert_grep 'pr=https://github.com/example/repo/pull/71' "$case_dir/state/task-x1.meta" \
    "checks-red: pr= should still be recorded before the gate refuses"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "checks-red: gh-axi pr merge was invoked despite a failing check"
  pass "a red PR is refused with the failing check named, before gh-axi pr merge"
}

test_pending_pr_refused_distinct_from_red() {
  local case_dir rc
  case_dir=$(make_case checks-pending)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000002
  : > "$case_dir/gh-axi.log"
  write_pr_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tIN_PROGRESS\t-\t-\tslow-suite' \
    $'StatusContext\t-\t-\tPENDING\texternal-gate'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "checks-pending: a pending PR must refuse"
  assert_grep 'note: PR check has not finished: slow-suite' "$case_dir/stderr" \
    "checks-pending: the pending check-run was not named"
  assert_grep 'note: PR check has not finished: external-gate' "$case_dir/stderr" \
    "checks-pending: the pending status context was not named"
  assert_grep 'not red, it is unfinished' "$case_dir/stderr" \
    "checks-pending: the refusal did not distinguish pending from red"
  assert_no_grep 'refusing to merge a red PR' "$case_dir/stderr" \
    "checks-pending: a merely-pending PR was refused as red"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "checks-pending: gh-axi pr merge was invoked despite pending checks"
  pass "a pending PR is refused distinctly from a red one"
}

test_red_outranks_pending_in_refusal() {
  local case_dir rc
  case_dir=$(make_case checks-red-and-pending)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000003
  : > "$case_dir/gh-axi.log"
  write_pr_checks "$case_dir" \
    $'CheckRun\tIN_PROGRESS\t-\t-\tslow-suite' \
    $'CheckRun\tCOMPLETED\tTIMED_OUT\t-\tintegration'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "checks-red-and-pending: must refuse"
  assert_grep 'error: PR check is failing: integration' "$case_dir/stderr" \
    "checks-red-and-pending: the failing check was not named"
  assert_grep 'refusing to merge a red PR' "$case_dir/stderr" \
    "checks-red-and-pending: a red check alongside a pending one was not refused as red"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "checks-red-and-pending: gh-axi pr merge was invoked"
  pass "a red check outranks a pending one in the refusal"
}

test_green_pr_merges_unchanged() {
  local case_dir
  case_dir=$(make_case checks-green)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000004
  : > "$case_dir/gh-axi.log"
  write_pr_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tunit-tests' \
    $'CheckRun\tCOMPLETED\tNEUTRAL\t-\toptional-scan' \
    $'CheckRun\tCOMPLETED\tSKIPPED\t-\tpath-filtered' \
    $'StatusContext\t-\t-\tSUCCESS\texternal-gate'

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "checks-green: fm-pr-merge failed"

  grep -qxF 'pr merge 74 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "checks-green: a green PR did not merge unchanged"
  pass "a green PR (including NEUTRAL/SKIPPED conclusions) merges unchanged"
}

test_zero_checks_without_marker_refuses() {
  local case_dir rc
  case_dir=$(make_case checks-zero-no-marker)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000005
  : > "$case_dir/gh-axi.log"
  write_pr_checks "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/75 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "checks-zero-no-marker: a zero-check PR must refuse without the marker"
  assert_grep 'refusing to treat absent CI as green' "$case_dir/stderr" \
    "checks-zero-no-marker: the refusal did not explain the zero-check rule"
  assert_grep 'data/no-pr-ci/project' "$case_dir/stderr" \
    "checks-zero-no-marker: the refusal did not point at the captain's marker"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "checks-zero-no-marker: gh-axi pr merge was invoked for a zero-check PR"
  pass "a PR reporting zero checks refuses without the captain's no-pr-ci marker"
}

test_zero_checks_with_marker_merges() {
  local case_dir
  case_dir=$(make_case checks-zero-marker)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000006
  : > "$case_dir/gh-axi.log"
  write_pr_checks "$case_dir"
  enable_no_pr_ci "$case_dir"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/76 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "checks-zero-marker: fm-pr-merge failed"

  assert_grep 'intentionally runs no PR CI; proceeding' "$case_dir/stderr" \
    "checks-zero-marker: the marker-approved zero-check merge was not noted"
  grep -qxF 'pr merge 76 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "checks-zero-marker: the marker-approved zero-check PR did not merge"
  pass "a zero-check PR merges with a note once the captain's no-pr-ci marker exists"
}

test_unreadable_rollup_refuses_unverified() {
  local case_dir rc
  case_dir=$(make_case checks-unreadable)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000007
  : > "$case_dir/gh-axi.log"
  touch "$case_dir/pr-checks-unreadable"
  enable_no_pr_ci "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/77 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "checks-unreadable: an unreadable rollup must refuse"
  assert_grep "could not read the PR's check status" "$case_dir/stderr" \
    "checks-unreadable: the refusal did not explain the query failure"
  assert_no_grep 'refusing to treat absent CI as green' "$case_dir/stderr" \
    "checks-unreadable: a query failure was misread as a zero-check PR"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "checks-unreadable: gh-axi pr merge was invoked on an unreadable rollup"
  pass "an unreadable check rollup refuses as unverified, even with the no-pr-ci marker present"
}

test_unclassifiable_check_refuses_unverified() {
  local case_dir rc
  case_dir=$(make_case checks-unclassifiable)
  add_gh_mocks "$case_dir" f000000000000000000000000000000000000008
  : > "$case_dir/gh-axi.log"
  write_pr_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSOMETHING_NEW\t-\tweird-check'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/78 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "checks-unclassifiable: an unclassifiable check must refuse"
  assert_grep 'PR check state could not be classified: weird-check' "$case_dir/stderr" \
    "checks-unclassifiable: the unclassifiable check was not named"
  assert_grep 'refusing to merge unverified' "$case_dir/stderr" \
    "checks-unclassifiable: the refusal did not say the state is unverified"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "checks-unclassifiable: gh-axi pr merge was invoked on an unclassifiable check"
  pass "a check the classification table cannot classify refuses as unverified"
}

# --- testing-waiver disclosure (contract in bin/fm-pr-merge.sh's header) ------
#
# A waived PR must be mergeable, must never look like a tested one in the log,
# and must not have loosened any gate on its way through.

# add_skip_flags <case_dir> <meta line>...: record a dispatch-time testing skip
# on the task, exactly as bin/fm-spawn.sh writes it. It is appended to the task's
# own meta on purpose: the disclosure is read from firstmate's durable record on
# the captain's machine, never from anything the PR carries.
add_skip_flags() {
  local case_dir=$1 line
  shift
  for line in "$@"; do
    printf '%s\n' "$line" >> "$case_dir/state/task-x1.meta"
  done
}

test_waived_pr_merges_but_announces_the_waiver() {
  local case_dir rc
  case_dir=$(make_case waiver-announced)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" a100000000000000000000000000000000000001
  : > "$case_dir/gh-axi.log"
  add_skip_flags "$case_dir" 'local_skip=on' 'ci_skip=on'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/80 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "waiver-announced: a waived PR must still be mergeable"
  grep -qxF 'pr merge 80 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "waiver-announced: the waived PR was not merged"
  assert_grep 'TESTING WAIVER' "$case_dir/stderr" "waiver-announced: no waiver banner was printed"
  assert_grep 'local pipeline:  SKIPPED' "$case_dir/stderr" "waiver-announced: the local skip was not named"
  assert_grep 'CI test jobs:    WAIVED' "$case_dir/stderr" "waiver-announced: the CI waiver was not named"
  assert_grep 'MERGING NOW' "$case_dir/stderr" "waiver-announced: the banner was not repeated at the merge"
  pass "a waived PR merges and says so loudly, twice"
}

test_unwaived_pr_prints_no_waiver_banner() {
  local case_dir
  case_dir=$(make_case waiver-absent)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" a100000000000000000000000000000000000002
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "waiver-absent: an ordinary merge failed"
  assert_no_grep 'TESTING WAIVER' "$case_dir/stderr" \
    "waiver-absent: an ordinary PR was labelled as waived"
  pass "an unflagged task's merge log is unchanged"
}

test_waiver_does_not_excuse_a_red_pr() {
  local case_dir rc
  case_dir=$(make_case waiver-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" a100000000000000000000000000000000000003
  : > "$case_dir/gh-axi.log"
  add_skip_flags "$case_dir" 'local_skip=on' 'ci_skip=on'
  write_pr_checks "$case_dir" $'CheckRun\tCOMPLETED\tFAILURE\t-\tinvariants'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "waiver-red: a waiver must not make a red PR mergeable"
  assert_grep 'PR check is failing: invariants' "$case_dir/stderr" \
    "waiver-red: the failing check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "waiver-red: a red waived PR was merged"
  pass "a testing waiver does not excuse a red PR"
}

test_waiver_does_not_excuse_zero_checks() {
  local case_dir rc
  case_dir=$(make_case waiver-zero-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" a100000000000000000000000000000000000004
  : > "$case_dir/gh-axi.log"
  add_skip_flags "$case_dir" 'ci_skip=on'
  write_pr_checks "$case_dir" ''

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/83 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "waiver-zero-checks: a waiver must not turn absent CI into green CI"
  assert_grep 'refusing to treat absent CI as green' "$case_dir/stderr" \
    "waiver-zero-checks: the zero-checks refusal did not fire"
  pass "a testing waiver does not excuse a PR that reports no checks at all"
}

# The kept-tests gate is the one check that survives every skip, because it is
# firstmate-side and it catches what a PR with no test evidence cannot.
test_kept_tests_gate_still_runs_under_every_skip() {
  local case_dir rc flags label
  for flags in 'local_skip=on' 'ci_skip=on' 'local_skip=on ci_skip=on'; do
    label=${flags// /+}
    case_dir=$(make_zk_case "waiver-kept-${label//=/}")
    add_gh_mocks "$case_dir" a100000000000000000000000000000000000005
    : > "$case_dir/gh-axi.log"
    # shellcheck disable=SC2086  # flags is an intentional word-split list
    add_skip_flags "$case_dir" $flags
    rewrite_zk_branch "$case_dir"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "waiver-kept ($flags): the kept-tests gate must still refuse"
    assert_grep 'no captain-approved supersession entry covers' "$case_dir/stderr" \
      "waiver-kept ($flags): the kept-tests finding was not reported"
    assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
      "waiver-kept ($flags): a branch that ate a base assertion was merged under a skip flag"
    assert_grep 'TESTING WAIVER' "$case_dir/stderr" \
      "waiver-kept ($flags): the waiver banner must print even when the merge is refused"
  done
  pass "the kept-tests gate runs, and still refuses, under every skip-flag combination"
}

### the premise behind check 2's identical-file skip ##########################
#
# bin/fm-assert-tests-kept.sh only skips a base test file the branch's copy
# matches byte for byte when a caller asserts the branch's own suite is verified
# green. This script is the caller that holds that premise, through its own
# checks-green gate - so these cases pin WHO asserts it and, more importantly,
# the two cases where it must not be asserted at all.

test_merge_asserts_the_branch_suite_premise_to_the_kept_gate() {
  local case_dir rc
  case_dir=$(make_stub_case premise-asserted 0)

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/90 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "premise-asserted: an ordinary green PR must merge"
  assert_grep '--assume-branch-suite-green' "$case_dir/kept-argv" \
    "premise-asserted: the ordinary path must let the gate skip files the branch's green suite already ran"
  pass "an ordinary merge asserts the branch-suite premise to the kept-tests gate"
}

test_ci_waived_task_re_runs_every_base_test_file() {
  local case_dir rc
  case_dir=$(make_stub_case premise-ci-waived 0)
  # With the PR's CI test jobs waived there is no green branch suite at all, so
  # the kept-tests gate is this merge's only test evidence and must not behave
  # as though it had one.
  add_skip_flags "$case_dir" 'ci_skip=on'

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "premise-ci-waived: a waived PR must still be mergeable"
  assert_no_grep '--assume-branch-suite-green' "$case_dir/kept-argv" \
    "premise-ci-waived: a CI-waived task must never assert a premise its own waiver removed"
  assert_grep 'were re-run in full' "$case_dir/stderr" \
    "premise-ci-waived: the full re-run must be stated in the merge log"
  assert_grep 'EVERY base test file is re-run here' "$case_dir/stderr" \
    "premise-ci-waived: the waiver banner must say the gate is running at full cost"
  pass "a CI-waived task re-runs every base test file instead of assuming coverage"
}

test_no_pr_ci_project_re_runs_every_base_test_file() {
  local case_dir rc
  case_dir=$(make_stub_case premise-no-pr-ci 0)
  # A project the captain has marked as running no PR CI passes the checks-green
  # gate on an EMPTY rollup, so that gate cannot supply the premise either.
  enable_no_pr_ci "$case_dir"
  write_pr_checks "$case_dir"

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/92 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "premise-no-pr-ci: a marked zero-check project must still merge"
  assert_no_grep '--assume-branch-suite-green' "$case_dir/kept-argv" \
    "premise-no-pr-ci: a project with no PR CI has no branch suite to assume coverage from"
  assert_grep 'were re-run in full' "$case_dir/stderr" \
    "premise-no-pr-ci: the full re-run must be stated in the merge log"
  pass "a project with no PR CI re-runs every base test file instead of assuming coverage"
}

test_assumed_covered_findings_are_disclosed_and_do_not_block() {
  local case_dir rc
  case_dir=$(make_stub_case premise-disclosed 0 \
    'assumed-covered: tests/a.test.sh::alpha holds' \
    'assumed-covered: tests/a.test.sh::beta holds' \
    'summary: missing=0 failing=0 unexecuted=0 skipped=0 unaccounted=0 assumed-covered=2 unstable=0')

  set +e
  run_pr_merge_stub "$case_dir" task-x1 https://github.com/example/repo/pull/93 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "premise-disclosed: an assumed-covered identifier is accounted for, not a finding"
  assert_grep '2 base assertion(s) were not re-run here' "$case_dir/stderr" \
    "premise-disclosed: the merge log must say how many assertions were not re-run"
  assert_no_grep 'no captain-approved supersession entry covers' "$case_dir/stderr" \
    "premise-disclosed: an assumed-covered identifier must not be treated as a finding"
  pass "assumed-covered identifiers are disclosed in the merge log and never block"
}

# --- the attestation exemption (contract in bin/fm-pr-merge.sh's header) ------
#
# The one check whose failure the merge gate may excuse. Written out here rather
# than read back out of the script, so this file is an INDEPENDENT statement of
# the name: (x11) then catches either side drifting from the workflow job that
# actually reports it.
ATTESTATION_CHECK='PR must be raised via no-mistakes'

# A rollup line for that check, failed exactly as CI reports it when a PR was not
# raised through the pipeline.
attestation_failed_line() {
  printf 'CheckRun\tCOMPLETED\tFAILURE\t-\t%s\n' "$ATTESTATION_CHECK"
}

# give_case_a_signing_key <case_dir>: a throwaway key for this case alone.
# NEVER the captain's real config/ci-waiver-secret: nothing here reads, needs, or
# could be made to accept it, and every signature below is minted from and
# verified against the value generated right here.
give_case_a_signing_key() {
  local case_dir=$1
  mkdir -p "$case_dir/fmhome/config"
  printf '%s\n' 0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0 \
    > "$case_dir/fmhome/config/ci-waiver-secret"
  chmod 600 "$case_dir/fmhome/config/ci-waiver-secret"
}

# mint_dispatch_token <case_dir> <task-id> <local|ci>: a REAL token, minted
# through the same library bin/fm-spawn.sh mints with, so a "valid signature"
# case exercises the actual HMAC rather than a constant the test and the script
# happened to agree on.
mint_dispatch_token() {
  local case_dir=$1 id=$2 kind=$3 fn=fm_ci_waiver_dispatch_local_token
  [ "$kind" = local ] || fn=fm_ci_waiver_dispatch_token
  bash -c '. "$0/bin/fm-ci-waiver-lib.sh"; "$1" "$2"' "$ROOT" "$fn" "$id" \
    < "$case_dir/fmhome/config/ci-waiver-secret"
}

# write_projects_registry <case_dir> <mode>: the private fleet registry
# bin/fm-project-mode.sh resolves a delivery mode from. make_case's project dir
# is always basenamed "project".
write_projects_registry() {
  local case_dir=$1 mode=$2
  mkdir -p "$case_dir/fmhome/data"
  {
    printf '%s\n' '# Projects'
    printf -- '- project [%s] - test project (added 2026-08-09)\n' "$mode"
  } > "$case_dir/fmhome/data/projects.md"
}

# make_attestation_case <name> <mode> [<extra rollup line>...]: a case whose PR
# reports the attestation check FAILED plus one ordinary green check, so the
# exemption is the only thing that can decide the merge.
make_attestation_case() {
  local name=$1 mode=$2 case_dir
  shift 2
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" c0ffee0000000000000000000000000000000001
  : > "$case_dir/gh-axi.log"
  write_projects_registry "$case_dir" "$mode"
  write_pr_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tLint shell scripts' \
    "$(attestation_failed_line)" \
    "$@"
  printf '%s\n' "$case_dir"
}

test_direct_pr_project_merges_past_a_failed_attestation() {
  local case_dir rc
  case_dir=$(make_attestation_case attest-direct-pr direct-PR)

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/101 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "attest-direct-pr: a direct-PR project's PR must merge past the attestation check"
  grep -qxF 'pr merge 101 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "attest-direct-pr: the PR was not merged"
  assert_grep 'ATTESTATION CHECK EXEMPTED (before the remaining gates)' "$case_dir/stderr" \
    "attest-direct-pr: the exemption was not disclosed before the gates"
  assert_grep 'ATTESTATION CHECK EXEMPTED (MERGING NOW)' "$case_dir/stderr" \
    "attest-direct-pr: the exemption was not disclosed again at the merge"
  assert_grep "$ATTESTATION_CHECK" "$case_dir/stderr" \
    "attest-direct-pr: the banner did not name the excused check"
  assert_grep 'registered as a direct-PR project' "$case_dir/stderr" \
    "attest-direct-pr: the banner did not name the authority it merged on"
  pass "a direct-PR project merges past the failed attestation check, and says so"
}

test_another_failing_check_refuses_under_the_exemption() {
  local case_dir rc
  case_dir=$(make_attestation_case attest-other-red direct-PR \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tBehavior tests (shard 1)')

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/102 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-other-red: the exemption must not carry a second failing check"
  assert_grep 'PR check is failing: Behavior tests (shard 1)' "$case_dir/stderr" \
    "attest-other-red: the genuinely failing check was not named"
  assert_grep 'refusing to merge a red PR' "$case_dir/stderr" \
    "attest-other-red: the red-PR refusal did not fire"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-other-red: a PR with an unrelated failing check was merged"
  pass "the exemption excuses one named check and nothing else that is failing"
}

test_pending_check_refuses_under_the_exemption() {
  local case_dir rc
  case_dir=$(make_attestation_case attest-pending direct-PR \
    $'CheckRun\tIN_PROGRESS\t-\t-\tBehavior tests (shard 2)')

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/103 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-pending: an unfinished check must still refuse under the exemption"
  assert_grep 'PR check has not finished: Behavior tests (shard 2)' "$case_dir/stderr" \
    "attest-pending: the unfinished check was not named"
  assert_grep 'it is unfinished' "$case_dir/stderr" \
    "attest-pending: the refusal did not distinguish unfinished from red"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-pending: a PR with an unfinished check was merged"
  pass "a pending check still refuses when the attestation check is exempted"
}

test_signed_skip_merges_past_a_failed_attestation() {
  local case_dir rc token
  case_dir=$(make_attestation_case attest-signed-skip no-mistakes)
  give_case_a_signing_key "$case_dir"
  token=$(mint_dispatch_token "$case_dir" task-x1 local)
  add_skip_flags "$case_dir" 'local_skip=on' "local_skip_auth=$token"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/104 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "attest-signed-skip: a signed testing skip must authorize the exemption"
  grep -qxF 'pr merge 104 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "attest-signed-skip: the PR was not merged"
  assert_grep 'ATTESTATION CHECK EXEMPTED' "$case_dir/stderr" \
    "attest-signed-skip: the exemption was not disclosed"
  assert_grep 'local-pipeline skip on this task, signed at dispatch' "$case_dir/stderr" \
    "attest-signed-skip: the banner did not name the signed skip as the authority"
  assert_grep 'TESTING WAIVER' "$case_dir/stderr" \
    "attest-signed-skip: the separate waiver disclosure stopped printing"
  pass "a testing skip carrying this home's own signature authorizes the exemption"
}

# THE case this whole design exists for: a worker appends its status lines into
# the same state directory, so it can append `local_skip=on` to its own record.
# That line must buy it nothing.
test_unsigned_skip_flag_refuses() {
  local case_dir rc
  case_dir=$(make_attestation_case attest-unsigned-skip no-mistakes)
  give_case_a_signing_key "$case_dir"
  add_skip_flags "$case_dir" 'local_skip=on'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/105 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-unsigned-skip: a bare skip flag must not authorize the exemption"
  assert_grep 'no usable local_skip_auth= signature' "$case_dir/stderr" \
    "attest-unsigned-skip: the missing signature was not called out"
  assert_grep "PR check is failing: $ATTESTATION_CHECK" "$case_dir/stderr" \
    "attest-unsigned-skip: the attestation check was not refused as an ordinary red check"
  assert_no_grep 'ATTESTATION CHECK EXEMPTED' "$case_dir/stderr" \
    "attest-unsigned-skip: an unsigned flag produced an exemption banner"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-unsigned-skip: a self-appended skip flag obtained a merge"
  pass "a skip flag with no signature authorizes nothing, so the merge refuses"
}

test_wrong_signature_on_skip_flag_refuses() {
  local case_dir rc
  case_dir=$(make_attestation_case attest-wrong-sig no-mistakes)
  give_case_a_signing_key "$case_dir"
  # Correctly SHAPED (64 hex) but not a value this home's key produces, which is
  # the best a forger without the secret can do.
  add_skip_flags "$case_dir" 'local_skip=on' \
    'local_skip_auth=abababababababababababababababababababababababababababababababab'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/106 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-wrong-sig: a forged signature must not authorize the exemption"
  assert_grep 'does NOT reproduce' "$case_dir/stderr" \
    "attest-wrong-sig: the refusal did not say the key does not reproduce the signature"
  assert_no_grep 'ATTESTATION CHECK EXEMPTED' "$case_dir/stderr" \
    "attest-wrong-sig: a forged signature produced an exemption banner"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-wrong-sig: a forged signature obtained a merge"
  pass "a signature this home's key does not reproduce authorizes nothing"
}

test_cross_domain_signature_does_not_transfer() {
  local case_dir rc token
  case_dir=$(make_attestation_case attest-cross-domain no-mistakes)
  give_case_a_signing_key "$case_dir"
  # A genuine token for this very task, minted under the CI-skip payload domain
  # and pasted beside the LOCAL flag.
  token=$(mint_dispatch_token "$case_dir" task-x1 ci)
  add_skip_flags "$case_dir" 'local_skip=on' "local_skip_auth=$token"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/107 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-cross-domain: a token from the other flag's domain must not transfer"
  assert_grep 'does NOT reproduce' "$case_dir/stderr" \
    "attest-cross-domain: the cross-domain token was not rejected as unreproducible"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-cross-domain: a CI-skip token authorized a local-skip exemption"
  pass "a dispatch token minted for the other skip does not authorize this one"
}

test_no_mistakes_project_without_a_skip_still_refuses() {
  local case_dir rc
  case_dir=$(make_attestation_case attest-no-authority no-mistakes)

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/108 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-no-authority: an unauthorized PR must still be refused"
  assert_grep "PR check is failing: $ATTESTATION_CHECK" "$case_dir/stderr" \
    "attest-no-authority: the attestation check was not named in the refusal"
  assert_grep 'can only be excused by' "$case_dir/stderr" \
    "attest-no-authority: the refusal did not say what would have excused it"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-no-authority: a PR with no exemption authority was merged"
  pass "a no-mistakes project with no authorized skip refuses exactly as before"
}

test_exempted_check_alone_is_not_evidence_of_ci() {
  local case_dir rc
  case_dir=$(make_case attest-only-check)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" c0ffee0000000000000000000000000000000002
  : > "$case_dir/gh-axi.log"
  write_projects_registry "$case_dir" direct-PR
  write_pr_checks "$case_dir" "$(attestation_failed_line)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/109 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-only-check: an exempted check must not count as CI having reported"
  assert_grep 'only check(s) were the exempted attestation check' "$case_dir/stderr" \
    "attest-only-check: the refusal did not explain that nothing verified the branch"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-only-check: a PR whose only check was exempted was merged"
  pass "an exempted check is not evidence, so a PR reporting nothing else refuses"
}

# A rename can only ever cost a merge, never grant one: the renamed check is no
# longer recognized, so it is no longer excused.
test_renamed_attestation_check_is_not_excused() {
  local case_dir rc
  case_dir=$(make_case attest-renamed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" c0ffee0000000000000000000000000000000003
  : > "$case_dir/gh-axi.log"
  write_projects_registry "$case_dir" direct-PR
  write_pr_checks "$case_dir" \
    $'CheckRun\tCOMPLETED\tSUCCESS\t-\tLint shell scripts' \
    $'CheckRun\tCOMPLETED\tFAILURE\t-\tPR must be raised via the pipeline'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/110 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attest-renamed: a check that is not the excused name must refuse"
  assert_grep 'PR check is failing: PR must be raised via the pipeline' "$case_dir/stderr" \
    "attest-renamed: the renamed check was not refused as an ordinary red check"
  assert_no_grep 'ATTESTATION CHECK EXEMPTED' "$case_dir/stderr" \
    "attest-renamed: a check with a different name was excused"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attest-renamed: a renamed attestation check was silently excused"
  pass "only the exact excused name is excused; a renamed check refuses"
}

# The drift guard the exemption's exact-name match depends on. The merge gate
# cannot read a workflow that lives in another repository, so the name is
# necessarily duplicated; this is what keeps the two copies equal.
#
# The name now lives in bin/fm-attestation-lib.sh, because the read-only fleet
# pipeline view has to excuse the same check the gate does and a second literal
# in the viewer is exactly the drift this guard exists to catch. So the guard
# covers both halves: the literal still equals the workflow job, and the gate
# still takes the literal from that owner rather than carrying its own.
test_exempted_check_name_matches_the_workflow_job() {
  local wf="$ROOT/.github/workflows/no-mistakes-required.yml"
  assert_grep "    name: $ATTESTATION_CHECK" "$wf" \
    "the attestation workflow's check job name no longer matches the name the merge gate excuses"
  assert_grep "FM_ATTESTATION_CHECK_NAME='$ATTESTATION_CHECK'" "$ROOT/bin/fm-attestation-lib.sh" \
    "bin/fm-attestation-lib.sh no longer excuses the name that workflow's check job reports"
  # shellcheck disable=SC2016  # the literal source line, not an expansion
  assert_grep 'ATTESTATION_CHECK_NAME=$FM_ATTESTATION_CHECK_NAME' "$ROOT/bin/fm-pr-merge.sh" \
    "bin/fm-pr-merge.sh grew its own copy of the excused name instead of reading the shared owner"
  assert_no_grep "ATTESTATION_CHECK_NAME='" "$ROOT/bin/fm-pr-merge.sh" \
    "bin/fm-pr-merge.sh carries a second literal copy of the excused check name"
  pass "the excused check name still equals the workflow job name that reports it"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_merge_asserts_the_branch_suite_premise_to_the_kept_gate
test_ci_waived_task_re_runs_every_base_test_file
test_no_pr_ci_project_re_runs_every_base_test_file
test_assumed_covered_findings_are_disclosed_and_do_not_block
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_missing_base_test_refuses_before_merge
test_rewritten_assertion_refuses_before_merge
test_clean_runnable_branch_merges_normally
test_valid_supersession_entry_merges_normally
test_supersession_entry_missing_field_not_honored
test_parses_pr_url_for_gh_axi
test_unexecuted_without_marker_is_informational_and_merges
test_unexecuted_with_marker_refuses
test_missing_and_failing_refuse_regardless_of_marker
test_excused_missing_plus_gated_unexecuted_refuses
test_legacy_single_id_entry_excuses_exactly_its_identifier
test_ids_glob_batch_excuses_matching_findings
test_ids_glob_does_not_excuse_non_matching_finding
test_kind_restricted_batch_does_not_excuse_missing
test_wildcard_ids_without_kind_excuses_every_class
test_invalid_kind_entry_not_honored
test_unstable_finding_refuses_and_explains_the_test_defect
test_unstable_kind_supersession_is_honored_and_scoped
test_field_after_reason_not_honored
test_no_space_field_after_reason_not_honored
test_duplicated_kind_field_not_honored
test_duplicated_ids_field_not_honored
test_entry_with_both_id_and_ids_not_honored
test_unparseable_or_unrecognized_field_not_honored
test_entry_without_id_or_ids_not_honored
test_findings_exit_with_no_parseable_line_refuses
test_unverifiable_exit_refuses
test_red_pr_refused_with_failing_check_named
test_pending_pr_refused_distinct_from_red
test_red_outranks_pending_in_refusal
test_green_pr_merges_unchanged
test_zero_checks_without_marker_refuses
test_zero_checks_with_marker_merges
test_unreadable_rollup_refuses_unverified
test_unclassifiable_check_refuses_unverified
test_waived_pr_merges_but_announces_the_waiver
test_unwaived_pr_prints_no_waiver_banner
test_waiver_does_not_excuse_a_red_pr
test_waiver_does_not_excuse_zero_checks
test_kept_tests_gate_still_runs_under_every_skip
test_direct_pr_project_merges_past_a_failed_attestation
test_another_failing_check_refuses_under_the_exemption
test_pending_check_refuses_under_the_exemption
test_signed_skip_merges_past_a_failed_attestation
test_unsigned_skip_flag_refuses
test_wrong_signature_on_skip_flag_refuses
test_cross_domain_signature_does_not_transfer
test_no_mistakes_project_without_a_skip_still_refuses
test_exempted_check_alone_is_not_evidence_of_ci
test_renamed_attestation_check_is_not_excused
test_exempted_check_name_matches_the_workflow_job

# --- AI-attribution gate (contract in docs/attribution-gate.md) --------------
#
# The gate firstmate runs over the artefact the worker already produced. It is
# the boundary rather than the commit-msg hook bin/fm-spawn.sh installs, because
# a worker can skip that hook with --no-verify and cannot reach this at all
# (tests/fm-attribution-gate.test.sh case (k) asserts that skip is real).

test_attribution_in_a_commit_message_refuses() {
  local case_dir rc
  case_dir=$(make_case attribution-commit)
  add_gh_mocks "$case_dir" a111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"
  commit_on_branch "$case_dir" \
    "$(printf 'feat: thing\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attribution-commit: a PR whose commit carries attribution must refuse"
  assert_grep 'carries AI attribution' "$case_dir/stderr" \
    "attribution-commit: the refusal did not say what it found"
  assert_grep 'ai-coauthor:commit ' "$case_dir/stderr" \
    "attribution-commit: the refusal did not name the rule and the offending commit"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attribution-commit: gh-axi pr merge ran despite the attribution"
  pass "fm-pr-merge refuses a PR whose commit message carries AI attribution"
}

test_attribution_in_the_pr_body_refuses() {
  local case_dir rc
  case_dir=$(make_case attribution-body)
  add_gh_mocks "$case_dir" a222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"
  write_pr_body "$case_dir" \
    "$(printf 'Adds the thing.\n\n\xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)')"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attribution-body: a PR whose description carries attribution must refuse"
  assert_grep 'generated-footer:PR body' "$case_dir/stderr" \
    "attribution-body: the refusal did not name the PR body as the source"
  assert_grep 'damage control, not' "$case_dir/stderr" \
    "attribution-body: the refusal should be honest that the body was already published"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attribution-body: gh-axi pr merge ran despite the attribution"
  pass "fm-pr-merge refuses a PR whose description carries AI attribution, and says the body is already public"
}

test_attribution_runs_before_the_kept_tests_gate() {
  local case_dir rc
  case_dir=$(make_case attribution-first)
  add_gh_mocks "$case_dir" a333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"
  # This branch would ALSO fail the kept-tests gate: it drops the base's only
  # assertion. If attribution were checked second, the refusal below would name
  # the vanished assertion instead. That it names the trailer is what proves the
  # cheap gate runs before the one that re-runs the base's tests.
  cat > "$case_dir/wt/tests/app.test.sh" <<'EOF'
#!/usr/bin/env bash
EOF
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "drop alpha"
  commit_on_branch "$case_dir" \
    "$(printf 'feat: thing\n\nClaude-Session: https://claude.ai/code/session_x')"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/83 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attribution-first: the merge must refuse"
  assert_grep 'session-trailer:' "$case_dir/stderr" \
    "attribution-first: the attribution refusal did not fire"
  assert_no_grep 'missing: tests/app.test.sh' "$case_dir/stdout" \
    "attribution-first: the expensive kept-tests gate ran before the cheap attribution read"
  pass "the attribution gate refuses before the kept-tests gate spends its run"
}

test_unreadable_pr_body_refuses_unverified() {
  local case_dir rc
  case_dir=$(make_case attribution-unreadable)
  add_gh_mocks "$case_dir" a444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/pr-body-unreadable"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "attribution-unreadable: an unreadable PR-description read must refuse"
  assert_grep 'refusing to merge unverified' "$case_dir/stderr" \
    "attribution-unreadable: the refusal did not say the merge is unverified"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "attribution-unreadable: gh-axi pr merge ran without the description read succeeding"
  pass "fm-pr-merge refuses when the PR's description cannot be read at all"
}

test_attribution_in_a_commit_message_refuses
test_attribution_in_the_pr_body_refuses
test_attribution_runs_before_the_kept_tests_gate
test_unreadable_pr_body_refuses_unverified

# --- mock-completeness canary ------------------------------------------------
#
# Why this exists: adding the AI-attribution gate added a `gh pr view --json
# body,commits` read to bin/fm-pr-merge.sh, and tests/fm-pr-check-security.test.sh
# went red on a CI shard because its own gh mock answered every OTHER query but
# not that one. An unanswered query is not a benign no-op - the mock returns
# nothing, and a gate that refuses what it cannot read correctly refuses the
# merge. The next read added to this chain would repeat that exactly.
#
# The fragile half is derived from the real tree at run time: the field sets are
# read out of the scripts a merge actually executes, so a new read appears here
# with no list to maintain. The stable half - WHICH suites stand up a gh mock
# that has to drive a merge all the way through - stays explicit, because it
# changes rarely and visibly, and guessing it from a grep over tests/ would be
# the same hand-maintained rot one level up.
test_every_merge_chain_gh_read_is_answered_by_each_merge_mock() {
  local script fields mock missing=0 found=0
  local -a chain=(fm-pr-merge.sh fm-pr-check.sh fm-assert-tests-kept.sh)
  local -a mocks=(fm-pr-merge.test.sh fm-pr-check-security.test.sh)

  for script in "${chain[@]}"; do
    [ -f "$ROOT/bin/$script" ] || fail "mock-canary: bin/$script is gone; update the merge chain this canary walks"
    while IFS= read -r fields; do
      [ -n "$fields" ] || continue
      found=$((found + 1))
      for mock in "${mocks[@]}"; do
        grep -qF -- "$fields" "$ROOT/tests/$mock" \
          || { echo "not ok - mock-canary: tests/$mock does not answer '--json $fields', read by bin/$script" >&2; missing=1; }
      done
    done < <(grep -oE 'gh pr view [^|]*--json [A-Za-z,]+' "$ROOT/bin/$script" \
      | grep -oE '\-\-json [A-Za-z,]+' | sed 's/^--json //' | sort -u)
  done

  [ "$found" -ge 4 ] \
    || fail "mock-canary: only $found gh pr view reads were derived from the merge chain; the extraction has stopped matching the scripts"
  [ "$missing" -eq 0 ] \
    || fail "mock-canary: a merge-chain gh read is unanswered by a mock that must drive a merge (named above); an unanswered read makes the gate refuse a PR it cannot read"
  pass "every gh pr view read the merge chain makes is answered by both merge-driving mocks"
}

test_every_merge_chain_gh_read_is_answered_by_each_merge_mock
