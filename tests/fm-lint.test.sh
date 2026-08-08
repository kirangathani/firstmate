#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
#
# Second contract, added when fm-lint.sh stopped being one big ShellCheck call:
# the sharded, cached fast path must report EXACTLY the findings the canonical
# whole-set command reports. Speed work on a gate is only safe while that holds,
# so the fixture tests below assert it directly rather than trusting the
# argument for it. One of them pins a real regression caught during that work:
# an empty cache manifest inverted an awk NR==FNR lookup, the work set came out
# empty, and the gate reported all 152 files clean without running ShellCheck at
# all. A lint gate that silently passes everything is worse than a slow one.
#
# Third contract, added when the cache moved from the worktree-private git dir
# to the repository's common one: the cache is only worth having if it survives
# the way this gate is actually run, which is once per fresh disposable
# worktree. The worktree cases below assert the shared location, the resulting
# cross-worktree hit, and the two documented escape hatches. Sharing one
# directory also means two runs can publish at once, so the last two cases pin
# the atomic-publication rule that makes that safe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The authoritative file set the one owner must run.
CANON='shellcheck --norc bin/*.sh bin/backends/*.sh tests/*.sh'
# The pinned version, read from the single source (the one owner itself).
# It is deliberately kept OUT of every pass NAME below and reported only in fail
# messages: it is read from the tree under test, so naming an assertion with it
# made bin/fm-assert-tests-kept.sh see every one of them vanish on any PR that
# bumps the pin (data/turnend-timing-block-h7/report.md §3).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

# fm_lint_fixture <dir>: build a miniature repo with the canonical layout
# (bin/*.sh, bin/backends/*.sh, tests/*.sh) and a REAL source graph, so the
# sharding and closure logic is exercised rather than mocked. fm-lint.sh
# resolves its root from its own location, so the fixture gets its own copy.
fm_lint_fixture() {
  local root=$1
  mkdir -p "$root/bin/backends" "$root/tests"
  cp "$LINT" "$root/bin/fm-lint.sh"
  cp "$ROOT/bin/fm-lint-plan.awk" "$root/bin/fm-lint-plan.awk"
  chmod +x "$root/bin/fm-lint.sh"
  cat > "$root/bin/lib-core.sh" <<'SH'
#!/usr/bin/env bash
CORE_READY=1
core_ready() { printf '%s\n' "$CORE_READY"; }
SH
  # Sources a library through a variable path, so ShellCheck can only follow it
  # via the source= directive AND only when the target is also an input.
  cat > "$root/bin/app.sh" <<'SH'
#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib-core.sh
. "$SCRIPT_DIR/lib-core.sh"
core_ready
SH
  cat > "$root/bin/backends/be.sh" <<'SH'
#!/usr/bin/env bash
be_name() { printf 'be\n'; }
SH
  # Exported so the library is clean on its own: an unexported, locally unused
  # assignment is itself an SC2034 finding, which would make the "clean"
  # fixture dirty for a reason that has nothing to do with what is being tested.
  cat > "$root/tests/lib.sh" <<'SH'
#!/usr/bin/env bash
TEST_LIB=1
export TEST_LIB
SH
  cat > "$root/tests/a.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
printf '%s\n' "$TEST_LIB"
SH
}

# fm_lint_worktree_fixture <tmp> [n]: build the fixture at "$tmp/repo" as a REAL
# git repository and add <n> LINKED worktrees at "$tmp/w1".."$tmp/wN".
# The whole point of the cache-directory contract is the difference between a
# linked worktree's PRIVATE git dir and the repository's COMMON one, and that
# difference only exists in a genuine linked worktree, so these tests create one
# rather than simulating the paths.
fm_lint_worktree_fixture() {
  local tmp=$1 n=${2:-2} i=0
  fm_lint_fixture "$tmp/repo"
  git -C "$tmp/repo" init -q
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    git -C "$tmp/repo" worktree add --quiet --detach "$tmp/w$i" HEAD
  done
}

# A genuine default-severity finding (SC1007), appended to any fixture file.
fm_lint_plant_defect() {
  cat >> "$1" <<'SH'

planted() {
  local x= y=
  echo "$x$y"
}
planted
SH
}

test_fast_path_matches_the_canonical_command() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): fast-path parity check"
    return
  fi
  # The whole justification for sharding is that a file's findings depend only
  # on itself plus the transitively sourced files present as input. Assert that
  # on a tree that actually HAS findings, in files with different closure
  # shapes: a leaf, a sourced library, and an importer of one.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-parity)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  fm_lint_plant_defect "$fx/bin/backends/be.sh"
  fm_lint_plant_defect "$fx/bin/lib-core.sh"
  fm_lint_plant_defect "$fx/tests/a.test.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" --verify-parity 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "sharded fast path disagreed with the canonical whole-set command"$'\n'"$out"
  assert_contains "$out" "PARITY OK" "--verify-parity did not confirm parity"
  pass "sharded fast path reports exactly the canonical command's findings"
}

test_cold_cache_never_reports_a_false_clean() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): cold-cache false-clean check"
    return
  fi
  # Regression: with no manifest yet, the cache lookup absorbed every file as a
  # cache hit, so the gate exited 0 having linted nothing. A cold cache must
  # lint everything and must still fail on a real defect.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-cold)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  fm_lint_plant_defect "$fx/bin/app.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache-never-written" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "cold-cache run did not fail on a planted defect (exit $rc)"$'\n'"$out"
  assert_contains "$out" "SC1007" "cold-cache run did not report the planted finding"
  assert_not_contains "$out" "unchanged since their last clean lint" \
    "cold-cache run claimed cached results it could not have had"
  pass "a cold cache lints the whole set instead of reporting a false clean"
}

test_cache_hit_does_not_hide_a_later_defect() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): cache invalidation check"
    return
  fi
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-cache)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "clean fixture failed its first lint (exit $rc)"$'\n'"$out"
  # Second run must be served from the cache, proving the cache is real.
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "second clean run failed (exit $rc)"$'\n'"$out"
  assert_contains "$out" "unchanged since their last clean lint" \
    "an unchanged tree was not served from the cache"
  # A defect introduced after that clean result must still be caught.
  fm_lint_plant_defect "$fx/bin/app.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "cached run hid a defect introduced after the cache was written (exit $rc)"$'\n'"$out"
  assert_contains "$out" "SC1007" "cached run did not report the new finding"
  pass "a cache hit never hides a defect introduced after it was recorded"
}

test_cache_key_covers_the_source_closure() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): closure invalidation check"
    return
  fi
  # A file is analysed with its sourced libraries inlined, so its cached result
  # is only valid while those libraries are byte-identical too. Editing a
  # library must put its importers back into the work set, not just itself.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-closure)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "clean fixture failed its first lint (exit $rc)"$'\n'"$out"
  printf '\nTEST_LIB_EXTRA=2\nexport TEST_LIB_EXTRA\n' >> "$fx/tests/lib.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "closure re-lint failed unexpectedly (exit $rc)"$'\n'"$out"
  # tests/lib.sh itself plus its only importer, tests/a.test.sh.
  assert_contains "$out" "linting 2 of" \
    "editing a sourced library did not invalidate its importer's cached result"
  pass "a cached result is invalidated by a change anywhere in its source closure"
}

test_literal_source_path_is_a_closure_edge() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): literal-source closure check"
    return
  fi
  # ShellCheck (without -x) also follows a plain `source <path>` whose target
  # is a variable-free literal path naming another input file - no source=
  # directive involved. The planner must model that edge too, or the sharded
  # path would emit an SC1091 the whole-set command does not, and a change to
  # the sourced library would not invalidate its importer's cached result.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-litsrc)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  cat > "$fx/bin/lit-lib.sh" <<'SH'
#!/usr/bin/env bash
LIT_READY=1
export LIT_READY
SH
  cat > "$fx/bin/lit-app.sh" <<'SH'
#!/usr/bin/env bash
set -eu
source bin/lit-lib.sh
printf '%s\n' "$LIT_READY"
SH
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache-parity" "$fx/bin/fm-lint.sh" --verify-parity 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a literal source path broke fast-path parity"$'\n'"$out"
  assert_contains "$out" "PARITY OK" "--verify-parity did not confirm parity with a literal source edge"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "literal-source fixture failed its first lint (exit $rc)"$'\n'"$out"
  printf '\nLIT_EXTRA=2\nexport LIT_EXTRA\n' >> "$fx/bin/lit-lib.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "literal-source re-lint failed unexpectedly (exit $rc)"$'\n'"$out"
  # bin/lit-lib.sh itself plus its only importer, bin/lit-app.sh.
  assert_contains "$out" "linting 2 of" \
    "editing a literal-sourced library did not invalidate its importer's cached result"
  pass "a literal source path is a closure edge for parity and cache invalidation"
}

test_guarded_literal_source_is_a_closure_edge() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): guarded-source closure check"
    return
  fi
  # A literal source guarded behind a top-level separator ('[ -f x ] && . x')
  # is still followed by ShellCheck, so it must still be a closure edge: parity
  # must hold and editing the library must invalidate the importer.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-guardsrc)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  cat > "$fx/bin/guard-app.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ -f bin/lib-core.sh ] && . bin/lib-core.sh
core_ready
SH
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache-parity" "$fx/bin/fm-lint.sh" --verify-parity 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a guarded literal source broke fast-path parity"$'\n'"$out"
  assert_contains "$out" "PARITY OK" "--verify-parity did not confirm parity with a guarded source edge"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "guarded-source fixture failed its first lint (exit $rc)"$'\n'"$out"
  printf '\nCORE_EXTRA=2\nexport CORE_EXTRA\n' >> "$fx/bin/lib-core.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "guarded-source re-lint failed unexpectedly (exit $rc)"$'\n'"$out"
  # bin/lib-core.sh itself plus both importers: bin/app.sh (directive) and
  # bin/guard-app.sh (guarded literal).
  assert_contains "$out" "linting 3 of" \
    "editing a guarded-sourced library did not invalidate its importer's cached result"
  pass "a guarded literal source is a closure edge for parity and cache invalidation"
}

test_source_in_any_command_position_is_a_closure_edge() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): command-position source closure check"
    return
  fi
  # ShellCheck follows a literal source wherever it sits in command position,
  # not just at line start or after ';', '&&', '||'. Verified on the pinned
  # version: 'then . lib', a subshell '( . lib', a 'function f { . lib; }'
  # body and a redirection-prefixed '>file . lib' are all followed when the
  # target is an input, so each must be a closure edge - otherwise a shard
  # split emits an SC1091 the whole-set run does not, and editing the library
  # never invalidates the importer's cached clean result. The discovery pass
  # harvests these from ShellCheck itself, so no position list is maintained.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-anypos)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  cat > "$fx/bin/then-app.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if true; then . bin/lib-core.sh; fi
core_ready
SH
  cat > "$fx/bin/sub-app.sh" <<'SH'
#!/usr/bin/env bash
set -eu
( . bin/lib-core.sh; core_ready )
SH
  cat > "$fx/bin/fn-app.sh" <<'SH'
#!/usr/bin/env bash
set -eu
function fn_ready { . bin/lib-core.sh; }
fn_ready
SH
  cat > "$fx/bin/redir-app.sh" <<'SH'
#!/usr/bin/env bash
set -eu
>/dev/null . bin/lib-core.sh
core_ready
SH
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache-parity" "$fx/bin/fm-lint.sh" --verify-parity 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a keyword- or subshell-position source broke fast-path parity"$'\n'"$out"
  assert_contains "$out" "PARITY OK" "--verify-parity did not confirm parity with command-position source edges"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "command-position source fixture failed its first lint (exit $rc)"$'\n'"$out"
  printf '\nCORE_EXTRA=2\nexport CORE_EXTRA\n' >> "$fx/bin/lib-core.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "command-position source re-lint failed unexpectedly (exit $rc)"$'\n'"$out"
  # bin/lib-core.sh itself plus all five importers: bin/app.sh (directive),
  # bin/then-app.sh, bin/sub-app.sh, bin/fn-app.sh and bin/redir-app.sh
  # (command-position literals).
  assert_contains "$out" "linting 6 of" \
    "editing the library did not invalidate its command-position importers"
  pass "a literal source in any command position is a closure edge"
}

test_disabled_sc1091_source_is_still_a_closure_edge() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): suppressed-SC1091 closure check"
    return
  fi
  # An in-file disable of SC1091 suppresses the very note the discovery pass
  # reads. Discovery therefore rewrites SC1091 inside directive lines on its
  # input stream, so the note still surfaces and the edge is still found:
  # no whole-set fallback, and editing the library re-lints the suppressing
  # importer. The directive is assembled at runtime so this test file never
  # carries a file-wide suppression itself.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-dis1091)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck %s\n' 'disable=SC1091'
    printf 'set -eu\n. bin/lib-core.sh\ncore_ready\n'
  } > "$fx/bin/dis-app.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "suppressed-SC1091 fixture failed its first lint (exit $rc)"$'\n'"$out"
  assert_not_contains "$out" "falling back to the canonical command" \
    "a plain disable=SC1091 must not force the whole-set fallback"
  printf '\nCORE_EXTRA=2\nexport CORE_EXTRA\n' >> "$fx/bin/lib-core.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "suppressed-SC1091 re-lint failed unexpectedly (exit $rc)"$'\n'"$out"
  # bin/lib-core.sh itself plus both importers: bin/app.sh (directive) and
  # bin/dis-app.sh (literal source under a file-wide SC1091 suppression).
  assert_contains "$out" "linting 3 of" \
    "a disable=SC1091 importer was not re-linted after its library changed"
  pass "a source suppressed by disable=SC1091 is still a closure edge"
}

test_unclassifiable_disable_falls_back_to_whole_set() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): unclassifiable-disable fallback check"
    return
  fi
  # 'disable=all' (or an SCnnnn-SCnnnn range) can suppress SC1091 in a form
  # the discovery rewrite does not recognise, which would hide edges silently;
  # the planner must force the whole-set fallback instead.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-disall)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf '# shellcheck %s\n' 'disable=all'
    printf 'true\n'
  } > "$fx/bin/da-app.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "whole-set fallback run failed on a clean fixture (exit $rc)"$'\n'"$out"
  assert_contains "$out" "falling back to the canonical command" \
    "an unclassifiable disable= item did not trigger the whole-set fallback"
  assert_contains "$out" "da-app.sh" "the fallback message did not name the offending file"
  pass "an unclassifiable disable= item falls back to the whole-set command"
}

test_verify_parity_fails_when_fast_path_falls_back() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): vacuous-parity regression check"
    return
  fi
  # Regression: the inner fast-path run's output was discarded, so a planner
  # tripwire made it fall back to the whole-set command, no findings file was
  # emitted, and verify-parity compared the reference against a fabricated
  # empty file - reporting PARITY OK without the fast path ever executing.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-vacuous)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf '# shellcheck %s\n' 'source-path=bin'
    printf 'true\n'
  } > "$fx/bin/sp-app.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" --verify-parity 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "--verify-parity reported success without a sharded fast-path run"$'\n'"$out"
  assert_contains "$out" "PARITY BROKEN" "--verify-parity did not report the vacuous run as a failure"
  assert_contains "$out" "falling back to the canonical command" \
    "--verify-parity hid the inner run's stderr naming the cause"
  assert_not_contains "$out" "PARITY OK" "--verify-parity claimed parity it never measured"
  pass "--verify-parity fails when the fast path falls back instead of sharding"
}

test_exec_lines_carry_exactly_lint_flags() {
  # --verify-parity re-spells the file set with $LINT_FLAGS and never executes
  # the literal `exec shellcheck` commands, so it cannot detect drift between
  # the two. This assertion is the actual guard: every literal exec line must
  # carry exactly the flags LINT_FLAGS holds.
  local flags mismatch
  flags=$(sed -n "s/^LINT_FLAGS='\(.*\)'$/\1/p" "$LINT")
  [ -n "$flags" ] || fail "could not read LINT_FLAGS from bin/fm-lint.sh"
  mismatch=$(awk -v want="$flags" '
    /exec shellcheck/ {
      got = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^-/) got = got (got == "" ? "" : " ") $i
      if (got != want) print FNR ": " $0
    }
  ' "$LINT")
  [ -z "$mismatch" ] || fail "exec shellcheck flags drifted from LINT_FLAGS ($flags):"$'\n'"$mismatch"
  pass "the literal exec shellcheck commands carry exactly LINT_FLAGS"
}

test_unmodelled_directive_falls_back_to_whole_set() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): unmodelled-directive fallback check"
    return
  fi
  # The planner does not model ShellCheck's search-path resolution, so a
  # directive key it does not understand must force the whole-set fallback
  # rather than risk a silently wrong shard plan. The directive line is
  # assembled at runtime so this test file never carries it verbatim.
  local tmp fx out rc
  tmp=$(fm_test_tmproot fm-lint-srcpath)
  fx="$tmp/repo"
  fm_lint_fixture "$fx"
  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf '# shellcheck %s\n' 'source-path=bin'
    printf 'true\n'
  } > "$fx/bin/sp-app.sh"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$tmp/cache" "$fx/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "whole-set fallback run failed on a clean fixture (exit $rc)"$'\n'"$out"
  assert_contains "$out" "falling back to the canonical command" \
    "an unmodelled shellcheck directive did not trigger the whole-set fallback"
  assert_contains "$out" "sp-app.sh" "the fallback message did not name the offending file"
  pass "an unmodelled shellcheck directive falls back to the whole-set command"
}

test_cache_lives_in_the_shared_common_git_dir() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): shared-cache location check"
    return
  fi
  # `git rev-parse --git-dir` in a linked worktree is that worktree's PRIVATE
  # directory. Every crewmate runs this gate in a fresh disposable worktree, so
  # a private cache was cold on every single run and the gate always paid full
  # price. The cache must resolve from the COMMON git dir instead, which every
  # worktree of the repository shares.
  local tmp out rc private
  tmp=$(fm_test_tmproot fm-lint-commondir)
  fm_lint_worktree_fixture "$tmp" 1
  private="$(git -C "$tmp/w1" rev-parse --git-dir)/fm-lint-cache"
  rc=0
  out=$(cd "$tmp/w1" && ./bin/fm-lint.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "clean fixture failed its first lint in a linked worktree (exit $rc)"$'\n'"$out"
  assert_present "$tmp/repo/.git/fm-lint-cache/manifest" \
    "a linked worktree did not record its clean result in the repository's common .git"
  assert_absent "$private" \
    "a linked worktree wrote a per-worktree private cache, which is cold on every fresh worktree"
  pass "the cache resolves to the repository's common git dir, not a worktree-private one"
}

test_one_worktree_warms_the_next() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): cross-worktree cache-hit check"
    return
  fi
  # The consequence the shared directory exists for: a clean result recorded by
  # one worktree must serve an identical tree in a DIFFERENT worktree. This is
  # exactly the crewmate case - each task gets its own fresh worktree of the
  # same repository - so a private cache made every run a cold run.
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-crosswt)
  fm_lint_worktree_fixture "$tmp" 2
  rc=0
  out=$(cd "$tmp/w1" && ./bin/fm-lint.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "clean fixture failed its first lint in worktree 1 (exit $rc)"$'\n'"$out"
  assert_contains "$out" "(0 cached clean)" \
    "the first worktree's run was not cold, so the second worktree's hit would prove nothing"
  rc=0
  out=$(cd "$tmp/w2" && ./bin/fm-lint.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "clean fixture failed its lint in worktree 2 (exit $rc)"$'\n'"$out"
  assert_contains "$out" "unchanged since their last clean lint" \
    "a second worktree of the same repository did not reuse the first worktree's clean result"
  pass "a clean result recorded in one worktree serves an identical tree in another"
}

test_cache_dir_override_and_disable_survive_the_shared_default() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): cache override/disable check"
    return
  fi
  # Sharing the default location must not quietly change the two documented
  # escape hatches: FM_LINT_CACHE_DIR still wins outright (and nothing is then
  # written to the common git dir), and FM_LINT_NO_CACHE=1 still reads and
  # writes nothing at all, in a linked worktree just as anywhere else.
  local tmp out rc common
  tmp=$(fm_test_tmproot fm-lint-override)
  fm_lint_worktree_fixture "$tmp" 2
  common="$tmp/repo/.git/fm-lint-cache"
  rc=0
  out=$(cd "$tmp/w1" && FM_LINT_CACHE_DIR="$tmp/elsewhere" ./bin/fm-lint.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "overridden-cache run failed on a clean fixture (exit $rc)"$'\n'"$out"
  assert_present "$tmp/elsewhere/manifest" "FM_LINT_CACHE_DIR did not receive the clean result"
  assert_absent "$common" "FM_LINT_CACHE_DIR was overridden yet the common git dir was still written"
  # The override is a real cache, not just a directory that got created.
  rc=0
  out=$(cd "$tmp/w2" && FM_LINT_CACHE_DIR="$tmp/elsewhere" ./bin/fm-lint.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "second overridden-cache run failed (exit $rc)"$'\n'"$out"
  assert_contains "$out" "unchanged since their last clean lint" \
    "an overridden cache directory did not serve its recorded clean result"
  # Disabled: no hits read from the populated override, and nothing written.
  rc=0
  out=$(cd "$tmp/w2" && FM_LINT_NO_CACHE=1 FM_LINT_CACHE_DIR="$tmp/elsewhere" ./bin/fm-lint.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "cache-disabled run failed on a clean fixture (exit $rc)"$'\n'"$out"
  assert_not_contains "$out" "unchanged since their last clean lint" \
    "FM_LINT_NO_CACHE=1 still served results from the cache"
  assert_contains "$out" "(0 cached clean)" "FM_LINT_NO_CACHE=1 still counted cache hits"
  rc=0
  out=$(cd "$tmp/w1" && FM_LINT_NO_CACHE=1 ./bin/fm-lint.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "cache-disabled default-location run failed (exit $rc)"$'\n'"$out"
  assert_absent "$common" "FM_LINT_NO_CACHE=1 still created the shared cache directory"
  pass "FM_LINT_CACHE_DIR and FM_LINT_NO_CACHE=1 behave as documented under the shared default"
}

test_publication_never_uses_a_fixed_staging_name() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): staging-name check"
    return
  fi
  # Sharing one cache directory between worktrees means two runs can publish at
  # the same moment. Both files are published by writing a staging file and
  # renaming it, and the rename is atomic - but only if each run owns its own
  # staging file. With the fixed "<file>.new" both used, two runs write the SAME
  # staging path and the atomic rename then publishes a spliced mixture of both.
  #
  # A race window is probabilistic, so this asserts the property deterministically
  # instead: a sentinel parked at each old fixed staging path must survive a full
  # clean run untouched, and the run must leave no staging file of its own behind.
  local tmp cache out rc leftovers
  tmp=$(fm_test_tmproot fm-lint-staging)
  cache="$tmp/cache"
  fm_lint_fixture "$tmp/repo"
  mkdir -p "$cache"
  printf 'sentinel-manifest\n' > "$cache/manifest.new"
  printf 'sentinel-discovery\n' > "$cache/discovery.new"
  rc=0
  out=$(FM_LINT_CACHE_DIR="$cache" "$tmp/repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "clean fixture failed its lint (exit $rc)"$'\n'"$out"
  [ "$(cat "$cache/manifest.new")" = "sentinel-manifest" ] \
    || fail "the manifest was published through the fixed staging name two concurrent runs would share"
  [ "$(cat "$cache/discovery.new")" = "sentinel-discovery" ] \
    || fail "the discovery cache was published through the fixed staging name two concurrent runs would share"
  assert_present "$cache/manifest" "the run did not publish a manifest at all"
  assert_present "$cache/discovery" "the run did not publish a discovery cache at all"
  leftovers=$(find "$cache" -mindepth 1 -maxdepth 1 \
    ! -name manifest ! -name discovery ! -name manifest.new ! -name discovery.new -print)
  [ -z "$leftovers" ] || fail "the run left staging files behind in the shared cache directory:"$'\n'"$leftovers"
  pass "each run publishes through its own staging file, not a shared fixed name"
}

test_concurrent_runs_publish_a_whole_cache_not_a_spliced_one() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): concurrent-publication check"
    return
  fi
  # End-to-end companion to the staging-name check: several trees publishing to
  # ONE shared cache directory at once must leave a cache that is exactly one
  # run's complete publication, never a mixture. Each fixture carries a distinct
  # extra file, so the trees' manifests genuinely differ and a splice cannot
  # coincidentally match. Every run must also still reach a clean verdict.
  local tmp n i rc pids p out manifest
  tmp=$(fm_test_tmproot fm-lint-concurrent)
  n=6
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    fm_lint_fixture "$tmp/r$i"
    # Distinct contents AND a distinct path, so run i's manifest can never be a
    # line-for-line match for run j's.
    printf '#!/usr/bin/env bash\nUNIQ_%s=%s\nexport UNIQ_%s\n' "$i" "$i" "$i" > "$tmp/r$i/bin/uniq-$i.sh"
    # Capture what run i publishes when it is the only writer: the manifest is
    # derived from that tree alone, so this is the exact byte sequence a
    # concurrent run of it must publish too.
    rc=0
    FM_LINT_CACHE_DIR="$tmp/solo$i" "$tmp/r$i/bin/fm-lint.sh" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "concurrency fixture $i failed its solo lint (exit $rc)"
  done
  pids=
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    (
      FM_LINT_CACHE_DIR="$tmp/shared" "$tmp/r$i/bin/fm-lint.sh" >"$tmp/out.$i" 2>&1
      printf '%s\n' "$?" > "$tmp/rc.$i"
    ) &
    pids="$pids $!"
  done
  for p in $pids; do
    wait "$p" || true
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    [ -f "$tmp/rc.$i" ] || fail "concurrent run $i produced no exit status"
    rc=$(cat "$tmp/rc.$i")
    [ "$rc" -eq 0 ] || fail "concurrent run $i did not reach a clean verdict (exit $rc)"$'\n'"$(cat "$tmp/out.$i")"
  done
  manifest="$tmp/shared/manifest"
  assert_present "$manifest" "concurrent runs published no manifest at all"
  i=0
  out=
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    if cmp -s "$manifest" "$tmp/solo$i/manifest"; then
      out=matched
      break
    fi
  done
  [ "$out" = matched ] || \
    fail "the shared manifest matches no single run's publication, so concurrent writers spliced it:"$'\n'"$(cat "$manifest")"
  # The discovery cache's contents legitimately depend on what a run read, so
  # only its shape is fixed: one "<version> <flags> <sha256>\t<edges>" record per
  # line. A splice shows up here as a line that does not parse.
  awk -F'\t' -v VER="$REQUIRED" '
    NF < 2 || $1 !~ ("^" VER " --norc [0-9a-f][0-9a-f]*$") { print "malformed: " $0; bad = 1 }
    END { exit bad ? 1 : 0 }
  ' "$tmp/shared/discovery" \
    || fail "concurrent runs left a spliced discovery cache:"$'\n'"$(cat "$tmp/shared/discovery")"
  pass "concurrent runs on one shared cache publish whole files, never a splice"
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  assert_grep "$CANON" "$LINT" "fm-lint.sh must run the canonical shellcheck file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  [ "$(grep -Fc 'exec shellcheck --norc' "$LINT")" -eq 2 ] || fail "both lint modes must ignore ambient ShellCheck configuration"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

test_nomistakes_invokes_the_owner() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" || fail "no-mistakes commands.lint must map exactly to the one-owner script"
  pass "no-mistakes pre-push lint calls the one-owner script"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep "VERSION=\"\$(\"\$ROOT/bin/fm-lint.sh\" --required-version)\"" "$INSTALLER" "installer must read the version fm-lint.sh pins"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 2 ] || fail "both CI jobs must use the shared ShellCheck installer"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (pinned ShellCheck not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_fast_path_matches_the_canonical_command
test_cold_cache_never_reports_a_false_clean
test_cache_hit_does_not_hide_a_later_defect
test_cache_key_covers_the_source_closure
test_literal_source_path_is_a_closure_edge
test_guarded_literal_source_is_a_closure_edge
test_source_in_any_command_position_is_a_closure_edge
test_disabled_sc1091_source_is_still_a_closure_edge
test_unclassifiable_disable_falls_back_to_whole_set
test_verify_parity_fails_when_fast_path_falls_back
test_exec_lines_carry_exactly_lint_flags
test_unmodelled_directive_falls_back_to_whole_set
test_cache_lives_in_the_shared_common_git_dir
test_one_worktree_warms_the_next
test_cache_dir_override_and_disable_survive_the_shared_default
test_publication_never_uses_a_fixed_staging_name
test_concurrent_runs_publish_a_whole_cache_not_a_spliced_one
