# shellcheck shell=bash
# fm-test-exec-lib.sh - the base-test execution library for the kept-tests gate.
# Usage: . bin/fm-test-exec-lib.sh   (sourced by bin/fm-assert-tests-kept.sh)
#
# This library is the ONE OWNER of the per-language runner interface that
# bin/fm-assert-tests-kept.sh's check 2 (assertion run) drives. fm-assert stays a
# readable orchestrator: it classifies test files, materializes the base/branch
# trees, and composes findings; the mechanics of detecting, running, and parsing
# a single base test file per language live behind this interface.
#
# Runner interface (three functions, each dispatching on a runner name):
#
#   runner_for_file <worktree> <file>
#       Print the runner that executes <file>, or nothing when no supported
#       runner applies. <worktree> is the live worktree the file belongs to
#       (later runners resolve an interpreter/binary from it); it is unused by
#       the shell runner. Always returns 0.
#
#   run_base_test_file <runner> <scratch-dir> <file> <results-out> <err-out>
#       Run the single base test file <file> from <scratch-dir> using <runner>,
#       writing the machine-readable run output to <results-out> and captured
#       stderr to <err-out>. Returns the run's exit code.
#
#   passing_idents <runner> <results-out>
#       Print the sorted, unique set of passing test names <runner> recorded in
#       <results-out>. fm-assert composes the full <file>::<name> identifier from
#       these names; for the shell runner the name is the `ok - <name>` tail.
#
# The `shell` runner is the only runner in this revision. It preserves the exact
# TAP-style `ok - <name>` protocol the check has always used, so firstmate's own
# shell suite behaves byte-for-byte as before. Additional runners (pytest,
# vitest, jest) extend the same three functions.
#
# FM_ASSERT_TESTS_TIMEOUT caps each run's runtime in seconds (default 300) when a
# `timeout` binary exists; the cap is applied by run_base_test_file.

# The optional timeout wrapper, resolved once at source time.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "${FM_ASSERT_TESTS_TIMEOUT:-300}")
fi

# runner_for_file <worktree> <file>: which runner executes <file>, or nothing.
# Shell wins for tests/*.test.sh (at any depth) exactly as check 1's language
# classification does; every other path is unsupported in this revision.
runner_for_file() {
  local f=$2
  case "$f" in
    tests/*.test.sh|*/tests/*.test.sh) echo shell; return 0 ;;
  esac
  return 0
}

# run_base_test_file <runner> <scratch-dir> <file> <results-out> <err-out>:
# run one base test file from the scratch tree root, returning its exit code.
run_base_test_file() {
  local runner=$1 scratch=$2 f=$3 results=$4 errout=$5
  case "$runner" in
    shell)
      # firstmate's own env overrides are stripped so a firstmate-repo test file
      # runs against the scratch tree, never this home's live state.
      (
        cd "$scratch" || exit 125
        FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_HOME='' \
          ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} bash "$f"
      ) > "$results" 2>"$errout"
      ;;
    *)
      return 125
      ;;
  esac
}

# passing_idents <runner> <results-out>: the sorted unique passing test names of
# one run, read from that runner's machine-readable output.
passing_idents() {
  local runner=$1 results=$2
  case "$runner" in
    shell)
      sed -n 's/^ok - //p' "$results" | sort -u
      ;;
  esac
}
