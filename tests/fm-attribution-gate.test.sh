#!/usr/bin/env bash
# Behavior tests for the AI-attribution refusal (docs/attribution-gate.md).
#
# The captain's rule is that no AI attribution leaves this machine. It used to
# live only in a CLAUDE.md that a task worktree never loads, so every worker was
# blind to it and two botoverflow PRs shipped a coauthor trailer, a session
# trailer and a generated-with footer. These tests hold up the two mechanical
# replacements for that missing control, and the honest line between them:
#
#   - bin/fm-commit-msg-check.sh, run as a git commit-msg hook that
#     bin/fm-install-commit-hook.sh puts in the repository behind every task
#     worktree. Fast feedback at authorship, harness-independent, skippable with
#     --no-verify. Cases (a)-(k).
#   - bin/fm-merge-local.sh's landing gate, which firstmate runs over the
#     artefact the worker already produced and the worker cannot reach. The PR
#     twin of this gate lives in bin/fm-pr-merge.sh and is exercised by
#     tests/fm-pr-merge.test.sh, where that script's PR fixture already lives.
#     Cases (l)-(n).
#
# Pattern cases:
#   (a) a coauthor trailer naming an AI is refused
#   (b) a Claude-Session trailer is refused
#   (c) a generated-with footer is refused
#   (d) a clean message passes
#   (e) prose ABOUT the rule passes: the same words mid-sentence, and as a
#       markdown bullet, are discussion and must not cost a commit. This is the
#       over-matching guard - a gate that refuses its own documentation gets
#       switched off, and then nothing is enforced at all.
#   (f) "generated with protoc" passes: the footer rule needs an AI tool name,
#       not just the phrase
#   (g) the commit-message file's git comments and the verbose diff below the
#       scissors line are not scanned, so a commit whose DIFF adds a line showing
#       one of these patterns still commits. Every commit in this very change
#       would otherwise be refused by its own gate.
#
# End-to-end hook cases, on a real repo and a real linked worktree:
#   (h) the installer resolves the repository's own hooks directory, and there is
#       no per-worktree hooks directory to install into (git 2.43.0). This is the
#       measurement the design rests on: one install covers a project and all of
#       its worktrees.
#   (i) a dirty commit from the WORKTREE is refused and nothing lands
#   (j) a clean commit from the same worktree lands normally
#   (k) --no-verify skips the hook. Asserted, not hidden: this is exactly why the
#       merge gate exists and why the hook is not counted as the boundary.
#
# Landing-gate cases:
#   (l) fm-merge-local refuses a branch whose commit message carries attribution
#   (m) the refusal happens even though the hook was never installed, which is
#       the case that matters: the boundary does not depend on the hook
#   (n) a clean branch fast-forwards normally
#
# Installer cases:
#   (o) a foreign commit-msg hook is never clobbered (exit 3)
#   (p) a second install over our own shim is idempotent (exit 0)
#   (q) an explicit core.hooksPath is honored
#   (r) the shim fails OPEN when the checker is gone, because a hook that cannot
#       find its checker must not wedge every commit in the project
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-attribution-lib.sh
. "$ROOT/bin/fm-attribution-lib.sh"

CHECK="$ROOT/bin/fm-commit-msg-check.sh"
INSTALL="$ROOT/bin/fm-install-commit-hook.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"

TMP=$(fm_test_tmproot fm-attribution-gate)
# fm_test_tmproot registers its EXIT cleanup inside the command substitution's
# own subshell, so the directory is already gone by the time the path lands here
# and every caller in tests/ recreates what it needs. Same here, explicitly.
mkdir -p "$TMP"
fm_git_identity fmtest fmtest@example.invalid

# The literal artefacts, byte for byte as they were observed on botoverflow PR 3
# rather than paraphrased: the trailers as git wrote them, and the footer with
# its leading U+1F916 ROBOT FACE, because the footer rule has to survive that
# non-letter prefix. Built here with printf so each case can compose them.
COAUTHOR_TRAILER='Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>'
SESSION_TRAILER='Claude-Session: https://claude.ai/code/session_01EaevQWW4jUNW4M4TLq2gEC'
GENERATED_FOOTER=$(printf '\xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)')

# run_check <file>: run the commit-msg checker over a message file, echo its
# stderr to stdout so a case can assert on it, and return its exit code.
run_check() {
  local file=$1 out rc=0
  out=$("$CHECK" "$file" 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

msg_file() {  # <name> <line>...
  local name=$1 f
  shift
  f="$TMP/$name.msg"
  : > "$f"
  printf '%s\n' "$@" >> "$f"
  printf '%s\n' "$f"
}

# --- (a)-(c) each rule fires ------------------------------------------------

f=$(msg_file coauthor 'feat: thing' '' "$COAUTHOR_TRAILER")
out=$(run_check "$f") && fail "(a) a coauthor trailer naming an AI should be refused"
assert_contains "$out" 'ai-coauthor:' "(a) the refusal should name the ai-coauthor rule"
pass "(a) an AI coauthor trailer is refused"

f=$(msg_file session 'feat: thing' '' "$SESSION_TRAILER")
out=$(run_check "$f") && fail "(b) a session-link trailer should be refused"
assert_contains "$out" 'session-trailer:' "(b) the refusal should name the session-trailer rule"
pass "(b) a session-link trailer is refused"

f=$(msg_file footer 'feat: thing' '' "$GENERATED_FOOTER")
out=$(run_check "$f") && fail "(c) a generated-with footer should be refused"
assert_contains "$out" 'generated-footer:' "(c) the refusal should name the generated-footer rule"
pass "(c) a generated-with footer is refused, leading emoji and all"

# --- (d) a clean message passes ---------------------------------------------

f=$(msg_file clean 'feat(attribution): refuse AI attribution at the merge gate' '' \
  'Enforcement is mechanical rather than an instruction a worker can decline.')
out=$(run_check "$f") || fail "(d) a clean commit message should pass: $out"
[ -z "$out" ] || fail "(d) a clean message should produce no output, got: $out"
pass "(d) a clean commit message passes with no output"

# --- (e) prose about the rule passes ----------------------------------------
#
# Each of these carries the exact forbidden words. What makes them discussion
# rather than attribution is position: a git trailer is only a trailer at the
# start of its line, so a mid-sentence mention and a markdown bullet are not.

f=$(msg_file prose 'fix: stop shipping the coauthor trailer' '' \
  "We removed the $COAUTHOR_TRAILER trailer from every template." \
  "- $COAUTHOR_TRAILER was appearing on every PR" \
  "  * $SESSION_TRAILER was appearing too")
out=$(run_check "$f") || fail "(e) prose about the rule should not be refused: $out"
pass "(e) prose about the rule commits: mid-sentence and bulleted mentions pass"

# --- (f) the footer rule needs a tool name ----------------------------------

f=$(msg_file protoc 'chore: regenerate stubs' '' 'Generated with protoc 3.21.12.')
out=$(run_check "$f") || fail "(f) a non-AI 'generated with' line should pass: $out"
pass "(f) 'generated with protoc' passes: the footer rule needs an AI tool name"

# --- (g) comments and the verbose diff are not the message ------------------
#
# Under commit.verbose the message file carries the staged diff below a scissors
# line. A diff that ADDS a documentation line showing one of these patterns must
# not read as the commit committing attribution - which is precisely the shape of
# every commit in this change.

f="$TMP/verbose.msg"
{
  printf 'docs: document the attribution patterns\n'
  printf '\n'
  printf '# Please enter the commit message for your changes. Lines starting\n'
  printf '# with %s will be ignored.\n' "'#'"
  printf '# ------------------------ >8 ------------------------\n'
  printf 'diff --git a/docs/attribution-gate.md b/docs/attribution-gate.md\n'
  printf '+%s\n' "$COAUTHOR_TRAILER"
  printf '+%s\n' "$SESSION_TRAILER"
  printf '+%s\n' "$GENERATED_FOOTER"
} > "$f"
out=$(run_check "$f") || fail "(g) the verbose diff below the scissors line should not be scanned: $out"
pass "(g) git comments and the verbose diff are excluded from the scan"

# --- (h)-(k) end to end, real repo and real linked worktree -----------------

E2E="$TMP/e2e"
mkdir -p "$E2E"
fm_git_init_commit "$E2E/proj"
git -C "$E2E/proj" worktree add -q -b feat "$E2E/wt" HEAD

install_out=$("$INSTALL" "$E2E/wt") || fail "(h) the installer should succeed against a linked worktree: $install_out"
COMMON=$(git -C "$E2E/proj" rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$E2E/proj/$COMMON" ;; esac
assert_present "$COMMON/hooks/commit-msg" "(h) the hook should land in the repository's own hooks directory"
WT_GIT_DIR=$(git -C "$E2E/wt" rev-parse --git-dir)
case "$WT_GIT_DIR" in /*) ;; *) WT_GIT_DIR="$E2E/wt/$WT_GIT_DIR" ;; esac
[ "$WT_GIT_DIR" != "$COMMON" ] || fail "(h) the fixture must be a real linked worktree, not a plain checkout"
assert_absent "$WT_GIT_DIR/hooks" "(h) git offers no per-worktree hooks directory, so the repository's is the only place to install"
pass "(h) hooks are per-repository: one install covers the project and every worktree of it"

DIRTY_MSG=$(msg_file e2e-dirty 'feat: thing' '' "$COAUTHOR_TRAILER" "$SESSION_TRAILER")
before=$(git -C "$E2E/wt" rev-parse HEAD)
printf 'change\n' >> "$E2E/wt/README.md"
git -C "$E2E/wt" add -A
commit_out=$(git -C "$E2E/wt" commit -F "$DIRTY_MSG" 2>&1) \
  && fail "(i) a commit carrying attribution should be refused from a task worktree"
assert_contains "$commit_out" 'carries AI attribution' "(i) the worker should be told why the commit was refused"
after=$(git -C "$E2E/wt" rev-parse HEAD)
[ "$before" = "$after" ] || fail "(i) the refused commit must not have landed"
pass "(i) a worker's commit carrying attribution is refused from a linked worktree, and nothing lands"

git -C "$E2E/wt" commit -qm 'feat: thing' || fail "(j) a clean commit should land normally"
[ "$(git -C "$E2E/wt" rev-parse HEAD)" != "$before" ] || fail "(j) the clean commit should have advanced the branch"
pass "(j) a clean commit from the same worktree lands normally"

printf 'again\n' >> "$E2E/wt/README.md"
git -C "$E2E/wt" add -A
git -C "$E2E/wt" commit -q --no-verify -F "$DIRTY_MSG" \
  || fail "(k) --no-verify is expected to skip the hook; the fixture itself failed"
git -C "$E2E/wt" log -1 --format=%B | grep -qF 'Co-Authored-By: Claude' \
  || fail "(k) --no-verify should have let the attribution through, which is the premise of the merge gate"
pass "(k) --no-verify skips the hook, which is why the landing gate below is the boundary"

# --- (l)-(n) the landing gate, which the worker cannot reach ----------------
#
# No hook is installed in these fixtures at all. That is the point: the gate must
# refuse on its own, over whatever the worker managed to commit.

make_local_case() {  # <name> ; echoes the case dir
  local name=$1
  local dir="$TMP/local-$name"
  mkdir -p "$dir/state"
  fm_git_init_commit "$dir/project"
  git -C "$dir/project" branch -M main
  git -C "$dir/project" worktree add -q -b fm/task-l1 "$dir/wt" main
  fm_write_meta "$dir/state/task-l1.meta" \
    "window=fm-task-l1" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$dir"
}

run_merge_local() {  # <case-dir> ; echoes combined output, returns its code
  local dir=$1 out rc=0
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/fmhome" FM_STATE_OVERRIDE="$dir/state" \
    "$MERGE_LOCAL" task-l1 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

dir=$(make_local_case dirty)
printf 'work\n' >> "$dir/wt/README.md"
git -C "$dir/wt" add -A
git -C "$dir/wt" commit -q --no-verify -F "$(msg_file local-dirty 'feat: work' '' "$COAUTHOR_TRAILER")"
main_before=$(git -C "$dir/project" rev-parse main)
out=$(run_merge_local "$dir") && fail "(l) fm-merge-local should refuse a branch carrying attribution"
assert_contains "$out" 'carry AI attribution' "(l) the refusal should say what it found"
assert_contains "$out" 'ai-coauthor:' "(l) the refusal should name the offending rule and commit"
[ "$(git -C "$dir/project" rev-parse main)" = "$main_before" ] \
  || fail "(m) the default branch must not have moved when the gate refused"
pass "(l) the landing gate refuses a branch whose commit message carries attribution"
pass "(m) it refuses with no hook installed anywhere, so the boundary does not depend on the hook"

dir=$(make_local_case clean)
printf 'work\n' >> "$dir/wt/README.md"
git -C "$dir/wt" add -A
git -C "$dir/wt" commit -qm 'feat: work'
expected=$(git -C "$dir/wt" rev-parse HEAD)
out=$(run_merge_local "$dir") || fail "(n) a clean branch should fast-forward normally: $out"
[ "$(git -C "$dir/project" rev-parse main)" = "$expected" ] \
  || fail "(n) the default branch should have fast-forwarded to the clean branch"
pass "(n) a clean branch still fast-forwards normally"

# --- (o)-(r) installer behavior ---------------------------------------------

FOREIGN="$TMP/foreign"
fm_git_init_commit "$FOREIGN/proj"
FOREIGN_COMMON=$(git -C "$FOREIGN/proj" rev-parse --absolute-git-dir)
mkdir -p "$FOREIGN_COMMON/hooks"
printf '#!/bin/sh\n# a project hook we did not write\nexit 0\n' > "$FOREIGN_COMMON/hooks/commit-msg"
chmod 755 "$FOREIGN_COMMON/hooks/commit-msg"
foreign_before=$(cat "$FOREIGN_COMMON/hooks/commit-msg")
rc=0
out=$("$INSTALL" "$FOREIGN/proj" 2>&1) || rc=$?
expect_code 3 "$rc" "(o) a foreign commit-msg hook should report exit 3"
assert_contains "$out" 'leaving it alone' "(o) the notice should say the foreign hook was left in place"
[ "$(cat "$FOREIGN_COMMON/hooks/commit-msg")" = "$foreign_before" ] \
  || fail "(o) a foreign commit-msg hook must never be overwritten"
pass "(o) a project's own commit-msg hook is never clobbered"

"$INSTALL" "$E2E/wt" >/dev/null || fail "(p) a second install should succeed"
"$INSTALL" "$E2E/wt" >/dev/null || fail "(p) a third install should succeed"
[ "$(grep -c 'fm-commit-hook-v2' "$COMMON/hooks/commit-msg")" -ge 1 ] \
  || fail "(p) the reinstalled shim should still carry its marker"
pass "(p) reinstalling over our own shim is idempotent"

HP="$TMP/hookspath"
fm_git_init_commit "$HP/proj"
git -C "$HP/proj" config core.hooksPath .githooks
"$INSTALL" "$HP/proj" >/dev/null || fail "(q) the installer should honor core.hooksPath"
assert_present "$HP/proj/.githooks/commit-msg" "(q) the hook should land under the configured core.hooksPath"
assert_absent "$(git -C "$HP/proj" rev-parse --absolute-git-dir)/hooks/commit-msg" \
  "(q) nothing should be written to the default hooks directory when core.hooksPath is set"
pass "(q) an explicit core.hooksPath is honored"

# The shim's own fail-open: point a copy of it at a checker that does not exist
# and confirm it exits 0 rather than refusing. A firstmate checkout that moved
# must not wedge every commit in every project it ever spawned into.
SHIM="$TMP/shim-failopen"
sed "s#^FM_ATTRIBUTION_CHECK=.*#FM_ATTRIBUTION_CHECK='$TMP/definitely-not-here.sh'#" \
  "$COMMON/hooks/commit-msg" > "$SHIM"
chmod 755 "$SHIM"
grep -q 'definitely-not-here' "$SHIM" || fail "(r) the fail-open fixture did not rewrite the checker path"
"$SHIM" "$(msg_file failopen 'feat: thing' '' "$COAUTHOR_TRAILER")" \
  || fail "(r) the shim must exit 0 when its checker is missing, not wedge the repository"
pass "(r) the shim fails open when the checker is gone"
