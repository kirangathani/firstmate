#!/usr/bin/env bash
# tests/fm-peek.test.sh - the uncommitted-work footer bin/fm-peek.sh appends
# after its bounded capture.
#
# The footer exists because every signal firstmate routinely reads can say
# "healthy" while a crewmate accumulates a large uncommitted diff: the pane
# renders the harness's own context reading, but nothing surfaced the dirty
# worktree half of the actionable pairing owned by AGENTS.md section 8 (a high
# context reading together with an uncommitted task worktree). These tests
# assert the footer fires on a dirty recorded worktree, stays silent on a
# clean one, is skipped for scout tasks (scratch worktree by contract), and
# reports a recorded-but-missing worktree instead of silently skipping it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEEK="$ROOT/bin/fm-peek.sh"

TMP_ROOT=$(fm_test_tmproot fm-peek)

# Hermetic fake tmux: capture-pane replays a fixture file, display-message
# answers the pane-liveness probe (same shape as tests/wake-helpers.sh).
make_peek_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    fi
    exit 0 ;;
  display-message) printf '%%0\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  # Fresh watcher beacon so fm-guard's stale-watcher banner stays out of the
  # peek output these tests assert on.
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

# A minimal real git repo standing in for a task worktree.
make_worktree() {  # <path>
  local wt=$1
  mkdir -p "$wt"
  git -C "$wt" init -q
}

run_peek() {  # <dir> <target>
  local dir=$1 target=$2
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    "$PEEK" "$target" 2>/dev/null
}

test_dirty_worktree_prints_footer() {
  local dir wt out
  dir=$(make_peek_case dirty)
  wt="$dir/worktree"
  make_worktree "$wt"
  printf 'uncommitted change\n' > "$wt/half-done.txt"
  printf 'window=test:fm-dirty\nkind=ship\nworktree=%s\n' "$wt" > "$dir/state/dirty.meta"
  printf 'ctx 199k/200k (99%%)\n' > "$dir/pane.txt"
  out=$(run_peek "$dir" dirty) || fail "fm-peek exited non-zero on a dirty worktree"
  assert_contains "$out" "task worktree has 1 uncommitted path" "footer did not report the dirty worktree"
  assert_contains "$out" "AGENTS.md section 8" "footer did not point at the section 8 pairing"
  assert_contains "$out" "ctx 199k/200k (99%)" "footer displaced the captured pane content"
  pass "fm-peek: a dirty recorded worktree prints the uncommitted-work footer after the capture"
}

test_clean_worktree_is_silent() {
  local dir wt out
  dir=$(make_peek_case clean)
  wt="$dir/worktree"
  make_worktree "$wt"
  printf 'window=test:fm-clean\nkind=ship\nworktree=%s\n' "$wt" > "$dir/state/clean.meta"
  printf 'idle prompt\n' > "$dir/pane.txt"
  out=$(run_peek "$dir" clean) || fail "fm-peek exited non-zero on a clean worktree"
  printf '%s' "$out" | grep -F "fm-peek:" >/dev/null && fail "a clean worktree printed a footer: $out"
  pass "fm-peek: a clean worktree adds nothing to the capture"
}

test_scout_worktree_is_skipped() {
  local dir wt out
  dir=$(make_peek_case scout)
  wt="$dir/worktree"
  make_worktree "$wt"
  printf 'scratch experiment\n' > "$wt/scratch.txt"
  printf 'window=test:fm-scout\nkind=scout\nworktree=%s\n' "$wt" > "$dir/state/scouty.meta"
  printf 'idle prompt\n' > "$dir/pane.txt"
  out=$(run_peek "$dir" scouty) || fail "fm-peek exited non-zero for a scout"
  printf '%s' "$out" | grep -F "uncommitted path" >/dev/null && fail "a scout's scratch worktree tripped the footer: $out"
  pass "fm-peek: a scout's scratch worktree never trips the footer"
}

test_missing_worktree_is_reported() {
  local dir out
  dir=$(make_peek_case missing)
  printf 'window=test:fm-gone\nkind=ship\nworktree=%s/never-created\n' "$dir" > "$dir/state/gone.meta"
  printf 'idle prompt\n' > "$dir/pane.txt"
  out=$(run_peek "$dir" gone) || fail "fm-peek exited non-zero on a missing worktree"
  assert_contains "$out" "recorded task worktree is missing" "a missing recorded worktree was silently skipped"
  pass "fm-peek: a recorded-but-missing worktree is reported, never silently skipped"
}

test_dirty_worktree_prints_footer
test_clean_worktree_is_silent
test_scout_worktree_is_skipped
test_missing_worktree_is_reported
