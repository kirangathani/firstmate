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
    pass "SKIP (ShellCheck $REQUIRED not resolved): fast-path parity check"
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
    pass "SKIP (ShellCheck $REQUIRED not resolved): cold-cache false-clean check"
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
    pass "SKIP (ShellCheck $REQUIRED not resolved): cache invalidation check"
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
    pass "SKIP (ShellCheck $REQUIRED not resolved): closure invalidation check"
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
    pass "SKIP (ShellCheck $REQUIRED not resolved): literal-source closure check"
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
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
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
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
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
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
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
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
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
