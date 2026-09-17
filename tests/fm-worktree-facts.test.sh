#!/usr/bin/env bash
# tests/fm-worktree-facts.test.sh - the per-task git facts a resume, pause, or
# handoff document states about each worktree.
#
# Every case builds real git repositories in a throwaway directory and points
# the script at a throwaway home, so nothing reads or touches the live fleet.
# The facts under test are the ones a document is wrong without: the branch, the
# head, how much is unpushed, and how much is uncommitted.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-worktree-facts.sh"

TMP=
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

TMP=$(mktemp -d)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state"

git_quiet() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}" >/dev/null 2>&1; }

# A bare "remote" plus clones of it, so pushed and unpushed are real states and
# not simulated by writing refs by hand.
REMOTE="$TMP/remote.git"
git init -q --bare "$REMOTE"

make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git init -q -b main "$dir"
  git -C "$dir" remote add origin "$REMOTE"
  echo one > "$dir/f"
  git_quiet "$dir" add f
  git_quiet "$dir" commit -m first
}

register() {
  printf 'worktree=%s\nkind=ship\n' "$2" > "$HOME_DIR/state/$1.meta"
}

run() { FM_HOME="$HOME_DIR" bash "$SCRIPT" "$@"; }

# --- a clean tree reports a measured zero ------------------------------------
# The failure this guards: counting dirty paths with `grep -c .` makes a CLEAN
# tree take the error branch, because grep exits 1 when it matches nothing. A
# clean tree is the commonest case and the one a resume record most needs
# stated, so reporting it as unmeasurable is the worst possible direction.
CLEAN="$TMP/clean"
make_repo "$CLEAN"
register clean-task "$CLEAN"
out=$(run --tsv clean-task)
dirty=$(printf '%s\n' "$out" | awk -F'\t' '$1=="clean-task"{print $7}')
if [ "$dirty" != 0 ]; then
  printf 'measured dirty count: %s\n' "$dirty" >&2
  fail "a clean worktree reports zero dirty paths rather than an unmeasurable marker"
fi
pass "a clean worktree reports zero dirty paths rather than an unmeasurable marker"

# --- uncommitted work is counted ---------------------------------------------
echo two > "$CLEAN/g"
echo changed > "$CLEAN/f"
out=$(run --tsv clean-task)
dirty=$(printf '%s\n' "$out" | awk -F'\t' '$1=="clean-task"{print $7}')
if [ "$dirty" != 2 ]; then
  printf 'measured dirty count: %s\n' "$dirty" >&2
  fail "uncommitted paths are counted"
fi
pass "uncommitted paths are counted"

# --- a branch pushed without a tracking ref is still compared -----------------
# `git push origin HEAD` pushes a branch and sets no upstream. Reporting such a
# branch as having no comparison at all reads as "never pushed", which is the
# opposite of the truth, so the fallback to origin/<branch> is load-bearing.
PUSHED="$TMP/pushed"
make_repo "$PUSHED"
git_quiet "$PUSHED" checkout -b feature
echo x > "$PUSHED/h"
git_quiet "$PUSHED" add h
git_quiet "$PUSHED" commit -m second
git_quiet "$PUSHED" push origin HEAD
git_quiet "$PUSHED" branch --unset-upstream
echo y > "$PUSHED/i"
git_quiet "$PUSHED" add i
git_quiet "$PUSHED" commit -m third
register pushed-task "$PUSHED"
out=$(run --tsv pushed-task)
unpushed=$(printf '%s\n' "$out" | awk -F'\t' '$1=="pushed-task"{print $6}')
if [ "$unpushed" != 1 ]; then
  printf 'measured unpushed count: %s\n' "$unpushed" >&2
  fail "a branch pushed without a tracking ref is compared against its origin branch"
fi
pass "a branch pushed without a tracking ref is compared against its origin branch"

# --- a branch that was never pushed says so -----------------------------------
NEVER="$TMP/never"
make_repo "$NEVER"
git_quiet "$NEVER" checkout -b lonely
register never-task "$NEVER"
out=$(run --tsv never-task)
unpushed=$(printf '%s\n' "$out" | awk -F'\t' '$1=="never-task"{print $6}')
if [ "$unpushed" != never-pushed ]; then
  printf 'measured unpushed field: %s\n' "$unpushed" >&2
  fail "a branch with no remote counterpart is named rather than given a count"
fi
pass "a branch with no remote counterpart is named rather than given a count"

# --- a missing worktree is reported, never dropped ----------------------------
# A silently short table reads as "nothing to report here", so a task whose
# worktree is gone has to appear with its absence stated.
register gone-task "$TMP/does-not-exist"
out=$(run --tsv gone-task)
state=$(printf '%s\n' "$out" | awk -F'\t' '$1=="gone-task"{print $3}')
if [ "$state" != absent ]; then
  printf 'measured worktree state: %s\n' "$state" >&2
  fail "a task whose worktree is gone is reported rather than dropped from the table"
fi
pass "a task whose worktree is gone is reported rather than dropped from the table"

# --- every registered task appears when none are named ------------------------
rows=$(run --tsv | tail -n +2 | grep -c .)
registered=$(find "$HOME_DIR/state" -maxdepth 1 -name '*.meta' | grep -c .)
if [ "$rows" != "$registered" ]; then
  printf 'rows: %s registered: %s\n' "$rows" "$registered" >&2
  fail "every registered task appears when no task is named"
fi
pass "every registered task appears when no task is named"

# --- the machine form carries a header ----------------------------------------
head1=$(run --tsv | head -1)
case "$head1" in
  task*worktree*branch*head*unpushed*dirty_paths) : ;;
  *) printf 'header line: %s\n' "$head1" >&2
     fail "the machine form leads with a header naming its columns" ;;
esac
pass "the machine form leads with a header naming its columns"

# --- the document form is a markdown table ------------------------------------
doc=$(run)
printf '%s\n' "$doc" | grep -q '^|---' \
  || fail "the document form emits a markdown table carrying the task rows"
printf '%s\n' "$doc" | grep -q 'clean-task' \
  || fail "the document form emits a markdown table carrying the task rows"
pass "the document form emits a markdown table carrying the task rows"

# --- the unpushed caveat travels with the number ------------------------------
# The count is measured against a local ref with nothing fetched, so a reader
# who takes it as a live comparison is being misled by an unlabelled number.
printf '%s\n' "$doc" | grep -qi 'overstate' \
  || fail "the document form states that the unpushed count can overstate"
pass "the document form states that the unpushed count can overstate"

cleanup
