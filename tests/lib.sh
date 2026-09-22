#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, resolvers for
# the shared per-repo cache paths bin/fm-test.sh owns, deterministic git identity
# and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Keep the review-question reader off the real daemon's record. bin/fm-watch.sh
# sweeps for open review questions on its own cadence, and bin/fm-pr-merge.sh
# gates on the same reader, so any test driving either would otherwise resolve a
# run out of this machine's live ~/.no-mistakes/state.sqlite - a real read of
# shared state from a test, and one whose cost lands inside the watcher cycle
# that several suites time. A path that does not exist means "no run", which is
# the correct answer for a sandbox fleet; a test that wants a conversation points
# this at its own fixture database explicitly.
export FM_NM_QUESTIONS_DB="${FM_NM_QUESTIONS_DB:-/nonexistent/fm-tests-no-nm-database.sqlite}"

# Scrub the harness session-pid markers bin/fm-session-lock-lib.sh reads
# (FM_SESSION_HARNESS_PID_ENV). Claude Code sets CLAUDE_PID in every process it
# spawns, so a suite run from a Claude Code tool shell inherits the OPERATOR's
# real session pid, and the session-lock finder would then record that pid
# instead of the fixture's - measuring the machine the suite happens to run on
# rather than the code. Scrubbing here rather than per call site makes it
# impossible for a new case to forget: sourcing this library removes it for the
# whole process and every child. A case whose SUBJECT is the marker still sets
# it explicitly for its own invocation, which wins over this baseline.
unset CLAUDE_PID

# Keep the self-latency ledger (bin/fm-latency-lib.sh) out of the operator's own
# home. Several suites run the real hooks and the real fm-send/fm-ack/fm-peek,
# and on a plain checkout those resolve to the captain's REAL data/latency.tsv,
# so a suite run would write test invocations into the record the captain reads
# as firstmate's live latency. Off for the whole process and every child; the
# suite whose subject IS the ledger clears it for its own invocations, which
# wins over this baseline.
export FM_LATENCY_OFF=1

# Keep an ordinary test send or ack out of the dormant-arm pool. Refill is the
# DEFAULT shape now (bin/fm-arm-pool-lib.sh, bin/fm-send.sh, bin/fm-ack.sh): a
# successful one execs a waiting arm instead of exiting, and in a scratch home
# with an empty pool that arm waits for a watcher lock that no test will ever
# release, so the suite would hang rather than fail. Off for the whole process
# and every child; the cases whose SUBJECT is the refill set it explicitly per
# invocation, which wins over this baseline.
export FM_ARM_POOL_NO_REFILL=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

# fm_fake_tmux_clients: install a `tmux` into <fakebin> that answers only
# `list-clients`, from the file named by FM_FAKE_TMUX_CLIENTS. This is the
# attached-client reading behind fm_captain_attached
# (bin/fm-captain-driven-lib.sh), and a suite that exercises anything reading
# that predicate MUST install it: without it the predicate forks the real tmux
# and its verdict is whatever window the operator happens to be looking at.
# A file rather than a variable so a case can change who is attached while a
# long-running subject (a watcher) is already going.
#
# Its rows are the real bytes tmux 3.4 printed for exactly the -F the library
# asks for, captured from the live fleet on 2026-09-17:
#   1789646192<TAB>firstmate:fm-nm-upstream-port-test-gate-g2<TAB>firstmate:2<TAB>@2
fm_fake_tmux_clients() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-clients" ]; then
  if [ -n "${FM_FAKE_TMUX_CLIENTS:-}" ] && [ -f "$FM_FAKE_TMUX_CLIENTS" ]; then
    cat "$FM_FAKE_TMUX_CLIENTS"
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$1/tmux"
}

# fm_fake_tmux_client_row: write one attached-client row viewing <target>, whose
# last keystroke was at <epoch>, into <file>.
fm_fake_tmux_client_row() {  # <file> <target> <epoch>
  printf '%s\t%s\t%s\t%s\n' "$3" "$2" "sess:9" "@9" > "$1"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_no_mistakes_stub_bin: echo a dir holding a healthy `no-mistakes` stub.
# Cases that run bin/fm-bootstrap.sh on the ambient PATH (rather than a pinned
# BASE_PATH) must prepend it, so bootstrap's version check and daemon probe
# never shell out to this machine's real, shared no-mistakes daemon.
#
# Callers invoke this from a command substitution (`PATH="$(...):$PATH"`), so
# it must never route through fm_test_tmproot: that registers an EXIT trap,
# which fires when the substitution's own subshell exits and deletes the dir
# before the caller can use it. The path is derived from the caller's TMP_ROOT
# and the writes are idempotent, so repeat calls are cheap and return the same
# directory without needing memo state (which a subshell could not keep anyway).
fm_no_mistakes_stub_bin() {
  local stub="${TMP_ROOT:?fm_no_mistakes_stub_bin needs TMP_ROOT}/fm-nm-stub-bin"
  mkdir -p "$stub"
  cat > "$stub/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
if [ "${1:-}" = daemon ] && [ "${2:-}" = status ]; then
  printf '  \xe2\x97\x8f daemon running (pid 1)\n'
  exit 0
fi
exit 0
SH
  chmod +x "$stub/no-mistakes"
  printf '%s\n' "$stub"
}

# --- the shared, per-repo cache location ------------------------------------
#
# bin/fm-test.sh keeps its sidecars under the git COMMON dir so every linked
# worktree shares one copy. Tests that assert something about those sidecars
# have to resolve the same path, and a private copy of the resolution rule that
# drifts from the runner's would silently point at a path that never exists -
# which turns those assertions vacuous instead of red. So the rule lives here
# once, spelled exactly as bin/fm-test.sh spells it.

# fm_test_git_common_dir <fallback>: echo the repo's git common dir, or
# <fallback> when rev-parse yields nothing. rev-parse is read with the cwd at
# ROOT and a relative answer (a primary checkout answers plain ".git") is
# resolved against ROOT, because the runner resolves it that way too.
fm_test_git_common_dir() {
  local fallback=$1 dir
  dir=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)
  case "$dir" in
    '') dir=$fallback ;;
    /*) ;;
    *) dir="$ROOT/$dir" ;;
  esac
  printf '%s\n' "$dir"
}

# fm_test_timings_file: echo the path of the shared measured-durations sidecar
# bin/fm-test.sh reads and writes, honouring FM_TEST_CACHE_DIR exactly as the
# runner does. The path is returned whether or not it exists; a sidecar is
# absent until some run records into it.
fm_test_timings_file() {
  local cache=${FM_TEST_CACHE_DIR:-}
  [ -n "$cache" ] || cache="$(fm_test_git_common_dir "$ROOT/.fm-test")/fm-test-cache"
  printf '%s/timings\n' "$cache"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
