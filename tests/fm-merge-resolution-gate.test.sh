#!/usr/bin/env bash
# Behavior tests for the additive-merge-resolution refusal
# (docs/merge-resolution-gate.md).
#
# The captain's rule: a coder SHOULD resolve a conflict itself when the
# resolution keeps all the information from both sides, and MUST escalate when it
# DELETES either side's content. The rule has to bite mechanically, because a
# rule an agent is asked to follow is not enforced - the captain's test is
# "could the entity being checked have produced the thing being checked?", and an
# agent judging its own resolution fails it.
#
# So these tests hold up both mechanical layers and the honest line between them:
#
#   - bin/fm-merge-resolution-check.sh, run as part of the git commit-msg hook
#     that bin/fm-install-commit-hook.sh puts in the repository behind every task
#     worktree. Fast feedback at authorship, harness-independent, skippable with
#     --no-verify. Cases (a)-(i).
#   - bin/fm-pr-merge.sh's landing gate, which firstmate runs over the merges the
#     worker already produced, through a script the worker never invokes.
#     Exercised end to end by tests/fm-pr-merge.test.sh, where that script's PR
#     fixture lives; the verdict it calls is case (j)-(l) here.
#
# THE FIXTURE IS THIS REPO'S OWN HISTORY, NOT A HAND-WRITTEN APPROXIMATION.
# Cases (j)-(l) replay real merge commits out of firstmate's own git history, so
# the "correct additive resolution passes" claim is made against a resolution a
# human actually wrote under a real conflict rather than against a shape invented
# to suit the check.
#
# Authorship-hook cases, on a real repo and a real conflict:
#   (a) the PR-46 shape - both sides APPEND a different entry to the same list -
#       resolved by keeping both, commits. This is the reference case: getting it
#       wrong is what makes the check cry wolf and get switched off.
#   (b) the same resolution reordered, renumbered and re-indented still commits.
#       The captain named these explicitly as inside the additive case.
#   (c) a resolution that keeps both entries but FUSES them into one line commits
#       ("merging two sentences" is inside the additive case too).
#   (d) a resolution that drops the base's entry is refused, and the refusal
#       names the lost line.
#   (e) the refusal names BOTH candidate resolutions, so it can be relayed as a
#       real choice per bin/fm-brief.sh's needs-decision contract.
#   (f) `git merge -X ours` is refused. Measured on git 2.43.0: -X ours
#       auto-resolves a REAL conflict by discarding the other side and then
#       auto-commits, and it is the ONE path that never runs pre-commit. This is
#       why the hook target is commit-msg.
#   (g) `git merge -X theirs` is refused the same way, naming the branch's side.
#   (h) an ordinary non-merge commit is untouched, including one that deletes
#       content. A deliberate deletion in its own commit is exactly the escape
#       hatch the landing gate points at, so it must not be refused here.
#   (i) --no-verify skips it. Asserted, not hidden: this is precisely why the
#       landing gate exists and why the hook is not counted as the boundary.
#
# Verdict cases against real history:
#   (j) the real resolution of the reference conflict (firstmate eba7add, where
#       one side appended two FM_STATUSLINE_BASE entries and the other appended
#       two uname entries to the same list) is additive and passes.
#   (k) a real merge that PERMANENTLY LOST content is caught (firstmate 2fa63cf
#       dropped an evidence section from docs/watcher-continuity.md that its own
#       parent had and that is absent from the repo to this day).
#   (l) replaying that same reference conflict as -X ours and as -X theirs - both
#       of which discard a side by construction - is caught in both directions.
#
# Cap case:
#   (m) the printed listing is capped, and the cap is read from the script at
#       runtime rather than hardcoded here, so a changed default cannot leave
#       this asserting a number the code no longer uses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-merge-additive-lib.sh
. "$ROOT/bin/fm-merge-additive-lib.sh"

CHECK="$ROOT/bin/fm-merge-resolution-check.sh"
INSTALL="$ROOT/bin/fm-install-commit-hook.sh"

TMP=$(fm_test_tmproot fm-merge-resolution-gate)
mkdir -p "$TMP"
fm_git_identity fmtest fmtest@example.invalid

# --- the conflict fixture ----------------------------------------------------
# The PR-46 shape, reduced to its essentials: a bullet list that main and the
# branch each append a DIFFERENT entry to, at the same spot. Neither replaces the
# other and both are true; the correct answer is "both". Getting there cost a
# round trip through the captain, which is the friction this whole change exists
# to remove.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main

write_list() {  # <file> <entry>...
  local f=$1
  shift
  {
    echo '# Repo style rules'
    echo
    echo '- A backend-verification doc records empirical facts, not assumptions.'
    printf '%s\n' "$@"
    echo '- Include the date, version, exact commands run, and exact output.'
  } > "$f"
}

BRANCH_ENTRY='- A test that reads an environment variable must control that variable for the invocation.'
MAIN_ENTRY='- Resolve uname once at source time rather than forking it inside a helper.'

write_list "$REPO/SKILL.md"
git -C "$REPO" add SKILL.md
git -C "$REPO" commit -qm 'base: the shared list'

git -C "$REPO" checkout -q -b branch
write_list "$REPO/SKILL.md" "$BRANCH_ENTRY"
git -C "$REPO" commit -qam 'branch: append the env-var entry'
BRANCH_TIP=$(git -C "$REPO" rev-parse HEAD)

git -C "$REPO" checkout -q main
write_list "$REPO/SKILL.md" "$MAIN_ENTRY"
git -C "$REPO" commit -qam 'main: append the uname entry'

"$INSTALL" "$REPO" >/dev/null 2>&1 || fail "the commit-msg hook should install into the fixture repo"

# reset_branch: put the branch back at its own tip with no merge in progress, so
# every case starts from the identical conflict rather than from whatever the
# previous case left behind.
reset_branch() {
  git -C "$REPO" merge --abort >/dev/null 2>&1 || true
  git -C "$REPO" checkout -q branch
  git -C "$REPO" reset -q --hard "$BRANCH_TIP"
}

# resolve_with: start the conflicting merge, write <file> as the resolution, and
# try to commit it. Echoes the combined output and returns the commit's code.
resolve_with() {  # <resolution-file> [extra git commit args...]
  local resolution=$1 out rc=0
  shift
  reset_branch
  git -C "$REPO" merge --no-edit main >/dev/null 2>&1 \
    || [ -f "$(git -C "$REPO" rev-parse --absolute-git-dir)/MERGE_HEAD" ] \
    || { echo "FIXTURE ERROR: the fixture merge did not conflict"; return 99; }
  cp "$resolution" "$REPO/SKILL.md"
  git -C "$REPO" add SKILL.md
  out=$(git -C "$REPO" commit -m 'merge: integrate main' "$@" 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

merge_with_strategy() {  # <ours|theirs>
  local side=$1 out rc=0
  reset_branch
  out=$(git -C "$REPO" merge --no-edit -X "$side" main 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# --- (a) the reference case: keep both --------------------------------------

write_list "$TMP/keep-both.md" "$BRANCH_ENTRY" "$MAIN_ENTRY"
out=$(resolve_with "$TMP/keep-both.md") \
  || fail "(a) keeping both entries must commit, but it was refused:
$out"
pass "(a) the reference conflict resolved by keeping both entries commits"

# --- (b) reordered, renumbered, re-indented ---------------------------------
# The captain named re-indenting and renumbering as inside the additive case. A
# check that refuses them cries wolf on correct work and gets disabled.

{
  echo '# Repo style rules'
  echo
  echo '  1. Resolve uname once at source time rather than forking it inside a helper.'
  echo '  2. Include the date, version, exact commands run, and exact output.'
  echo '  3. A test that reads an environment variable must control that variable for the invocation.'
  echo '  4. A backend-verification doc records empirical facts, not assumptions.'
} > "$TMP/reformatted.md"
out=$(resolve_with "$TMP/reformatted.md") \
  || fail "(b) reordering, renumbering and re-indenting what it keeps must commit, but it was refused:
$out"
pass "(b) a kept-both resolution that reorders, renumbers and re-indents commits"

# --- (c) both sides fused into one line -------------------------------------

{
  echo '# Repo style rules'
  echo
  echo '- A backend-verification doc records empirical facts, not assumptions.'
  echo '- A test that reads an environment variable must control that variable for the invocation, and resolve uname once at source time rather than forking it inside a helper.'
  echo '- Include the date, version, exact commands run, and exact output.'
} > "$TMP/fused.md"
out=$(resolve_with "$TMP/fused.md") \
  || fail "(c) fusing both sides into one line must commit, but it was refused:
$out"
pass "(c) a resolution that fuses both sides into a single line commits"

# --- (d) a resolution that drops the base's entry ---------------------------

write_list "$TMP/drop-main.md" "$BRANCH_ENTRY"
out=$(resolve_with "$TMP/drop-main.md") \
  && fail "(d) dropping the base's entry must be refused, but the commit succeeded:
$out"
assert_contains "$out" 'deletes content one side introduced' \
  "(d) the refusal should say what is wrong"
assert_contains "$out" 'Resolve uname once at source time' \
  "(d) the refusal should quote the line that was lost"
assert_contains "$out" 'the base being merged in' \
  "(d) the refusal should name which side lost content"
pass "(d) a resolution that drops the base's entry is refused, naming the lost line"

# --- (e) the refusal names both candidate resolutions -----------------------
# bin/fm-brief.sh's needs-decision contract is "append needs-decision: {summary
# of options}". An escalation that names only the problem is not relayable as a
# choice, so the refusal has to carry both candidates.

assert_contains "$out" 'KEEP BOTH' "(e) the refusal should name the keep-both candidate"
assert_contains "$out" 'DROP THEM' "(e) the refusal should name the drop candidate"
assert_contains "$out" 'needs-decision:' \
  "(e) the refusal should hand over the exact needs-decision line to report"
pass "(e) the refusal names both candidate resolutions and the needs-decision line"

# --- (f) -X ours, the path pre-commit never sees ----------------------------

out=$(merge_with_strategy ours) \
  && fail "(f) -X ours discards the base's side and must be refused, but it committed:
$out"
assert_contains "$out" 'deletes content one side introduced' \
  "(f) -X ours should hit the same refusal"
assert_contains "$out" 'Resolve uname once at source time' \
  "(f) the -X ours refusal should quote the base's lost line"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$BRANCH_TIP" ] \
  || fail "(f) nothing may land when the resolution is refused"
pass "(f) git merge -X ours is refused, and it is why the hook is on commit-msg"

# --- (g) -X theirs, the mirror image ----------------------------------------

out=$(merge_with_strategy theirs) \
  && fail "(g) -X theirs discards the branch's side and must be refused, but it committed:
$out"
assert_contains "$out" 'A test that reads an environment variable' \
  "(g) the -X theirs refusal should quote the branch's lost line"
assert_contains "$out" 'this branch' \
  "(g) the -X theirs refusal should name the branch as the side that lost content"
pass "(g) git merge -X theirs is refused, naming the branch's lost line"

# --- (h) an ordinary commit is untouched, including a deleting one -----------
# This is the escape hatch the landing gate points at: a deliberate deletion in
# its OWN commit is reviewable in the PR diff, so it must commit freely. If this
# case ever failed, the gate would have no legitimate way through and would be
# routed around instead.

reset_branch
write_list "$REPO/SKILL.md"
out=$(git -C "$REPO" commit -qam 'chore: drop the env-var entry deliberately' 2>&1) \
  || fail "(h) an ordinary deleting commit must not be refused:
$out"
pass "(h) a deliberate deletion in its own non-merge commit commits freely"
reset_branch

# --- (i) --no-verify skips it -----------------------------------------------

out=$(resolve_with "$TMP/drop-main.md" --no-verify) \
  || fail "(i) --no-verify should skip the hook entirely:
$out"
pass "(i) --no-verify skips the hook, which is why the landing gate is the boundary"
reset_branch

# --- (j)-(l) the verdict against this repo's own real history ---------------
# These read firstmate's own git history. A checkout without that history (a
# shallow clone, an export) skips them loudly rather than passing vacuously,
# because a silent skip would read as evidence the fixture never produced.

REFERENCE_MERGE=eba7add120a80dc0d0e1d8346c6075518576fb56   # the PR 46 conflict
LOSS_MERGE=2fa63cfdabf3b0b9d61ea7d08aac0ba74834892d        # dropped a docs section for good

have_history=1
for sha in "$REFERENCE_MERGE" "$LOSS_MERGE"; do
  git -C "$ROOT" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1 || have_history=0
done

verdict_for() {  # <merge-sha> -> prints findings, returns the scan code
  local sha=$1 p1 p2 base
  p1=$(git -C "$ROOT" rev-parse "$sha^1")
  p2=$(git -C "$ROOT" rev-parse "$sha^2")
  base=$(git -C "$ROOT" merge-base "$p1" "$p2" | head -1)
  fm_additive_scan "$ROOT" "$base" "$p1" "$p2" "$sha"
}

if [ "$have_history" -eq 0 ]; then
  echo "SKIP - (j)-(l) need firstmate's own merge history, which this checkout does not have" >&2
else
  rc=0
  out=$(verdict_for "$REFERENCE_MERGE") || rc=$?
  expect_code 0 "$rc" "(j) the real resolution of the reference conflict must be additive"
  [ -z "$out" ] || fail "(j) the reference resolution should produce no findings, got:
$out"
  pass "(j) the human's real resolution of the reference conflict passes"

  rc=0
  out=$(verdict_for "$LOSS_MERGE") || rc=$?
  expect_code 1 "$rc" "(k) a merge that permanently lost content must be caught"
  assert_contains "$out" 'docs/watcher-continuity.md' \
    "(k) the finding should name the file whose content was lost"
  assert_contains "$out" 'lost:theirs:' \
    "(k) the finding should name the side whose content was lost"
  # The claim that the loss is PERMANENT, not merely reworded, is what makes this
  # a real defect rather than a style difference. Assert it against the tree as
  # it stands now rather than trusting the finding.
  git -C "$ROOT" grep -q -F 'Leaving them unfixed was an explicit scope decision' -- . 2>/dev/null \
    && fail "(k) the fixture assumes this content is still absent from the repo; it is present, so pick another loss case"
  pass "(k) a real merge that permanently lost a documentation section is caught"

  # (l) the same reference conflict, replayed as the two resolutions that discard
  # a side by construction. This is the direction (j) cannot prove: (j) shows the
  # check is quiet on correct work, and only this shows it is not quiet on
  # everything.
  REPLAY="$TMP/replay"
  git -C "$ROOT" worktree list >/dev/null 2>&1
  rm -rf "$REPLAY"
  git clone -q --shared "$ROOT" "$REPLAY" 2>/dev/null || git clone -q "$ROOT" "$REPLAY"
  git -C "$REPLAY" config user.name 'Firstmate Tests'
  git -C "$REPLAY" config user.email 'tests@example.invalid'
  rp1=$(git -C "$ROOT" rev-parse "$REFERENCE_MERGE^1")
  rp2=$(git -C "$ROOT" rev-parse "$REFERENCE_MERGE^2")
  rbase=$(git -C "$ROOT" merge-base "$rp1" "$rp2" | head -1)
  for side in ours theirs; do
    git -C "$REPLAY" merge --abort >/dev/null 2>&1 || true
    git -C "$REPLAY" checkout -q --detach "$rp1" 2>/dev/null \
      || fail "(l) could not check out the reference conflict's first parent"
    git -C "$REPLAY" merge --no-edit --no-verify -X "$side" "$rp2" >/dev/null 2>&1 \
      || fail "(l) -X $side should have produced a merge commit"
    replayed=$(git -C "$REPLAY" rev-parse HEAD)
    rc=0
    out=$(fm_additive_scan "$REPLAY" "$rbase" "$rp1" "$rp2" "$replayed") || rc=$?
    expect_code 1 "$rc" "(l) -X $side discards a side of the reference conflict and must be caught"
    [ -n "$out" ] || fail "(l) -X $side should have produced findings"
  done
  pass "(l) replaying the reference conflict as -X ours and -X theirs is caught both ways"
fi

# --- (m) the printed listing is capped --------------------------------------
# The cap is read out of the script at runtime. A hardcoded 20 here would keep
# passing after someone changed the default, asserting a limit the code no longer
# has - the failure mode a boundary test exists to prevent.

CAP=$(grep -m1 '^MAX_SHOWN=' "$CHECK" | tr -dc '0-9')
case "$CAP" in
  ''|*[!0-9]*) fail "(m) could not read the listing cap out of $CHECK" ;;
esac

OVER=$((CAP + 5))
{
  echo '# Repo style rules'
  echo
  echo '- A backend-verification doc records empirical facts, not assumptions.'
} > "$TMP/cap-base.md"
cp "$TMP/cap-base.md" "$REPO/SKILL.md"
reset_branch
git -C "$REPO" checkout -q main
{
  cat "$TMP/cap-base.md"
  i=0
  while [ "$i" -lt "$OVER" ]; do
    echo "- Distinctive base entry number $i about quarantining unrepeatable evidence."
    i=$((i + 1))
  done
} > "$REPO/SKILL.md"
git -C "$REPO" commit -qam "main: append $OVER entries"
reset_branch

out=$(merge_with_strategy ours) \
  && fail "(m) -X ours over $OVER dropped base entries must be refused"
assert_contains "$out" "this listing is capped at $CAP" \
  "(m) the refusal should say the listing was capped, using the script's own cap"
shown=$(printf '%s\n' "$out" | grep -c '^      | ' || true)
[ "$shown" -le "$CAP" ] \
  || fail "(m) the refusal printed $shown lost lines, above its own cap of $CAP"
pass "(m) the printed listing is capped at the script's own limit and says so"

reset_branch
rm -rf "$TMP/replay"
