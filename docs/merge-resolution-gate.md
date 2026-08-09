# The additive-merge-resolution gate

This document is the authoritative human-readable contract for firstmate's refusal of a merge resolution that deletes content one side introduced.
`bin/fm-merge-additive-lib.sh` is the single owner of the verdict.
`bin/fm-merge-resolution-check.sh` is the authorship-time checker, `bin/fm-install-commit-hook.sh` installs it, and `bin/fm-pr-merge.sh` owns the landing refusal.

**Where the enforcement physically lives:** in `bin/fm-pr-merge.sh`, the script firstmate runs to land work, which replays every merge commit the PR would land from its own two parents and exits non-zero rather than merging; a git `commit-msg` hook installed into each project's own repository applies the same verdict earlier, at the moment the resolution is committed.

## The rule, and why a written rule was not enough

The captain's decision, in his own framing:

- A coding agent **should** resolve a merge conflict itself, without escalating, when its resolution keeps **all** the information from both sides.
- It **must** escalate when its resolution **deletes** either side - the branch's content or the base's.

His reason for the first half: *"otherwise we're just creating friction, because I'm the one asking you anyway what we should do with this."*

The case that prompted it, on 2026-08-09: PR 46 conflicted with `main` in a documentation list where two changes had each **appended a different entry at the same spot**.
Neither replaced the other and both were true, about different subjects.
The correct answer was "both", and getting there cost a round trip through the captain for a decision he did not need to make.

The other half of the rule is not symmetric with it.
A resolution that drops a side is not friction, it is silent permanent loss, and this repository has already paid for one.
Merge `2fa63cf` dropped an entire evidence section out of `docs/watcher-continuity.md` - the paragraphs recording which watcher-continuity cases were left unfixed as a deliberate scope decision, and which two statements were read from source rather than measured.
Its own parent `15ba728` has them.
They are absent from the repository today.
`tests/fm-merge-resolution-gate.test.sh` case (k) asserts both halves of that, so the fixture fails loudly if the content is ever restored rather than quietly testing nothing.

The captain's test for whether a control is real: could the entity being checked have produced the thing being checked?
An agent judging whether its own resolution kept both sides fails that test outright.
So putting this rule in a brief would have been a non-answer, and the layers below are described by what they actually constrain.

## The verdict

A line is **content one side brought** when it is present in that side and **not** present in the merge base.
That is what makes it new information rather than something the base already said.
Every such line must still be present in the resolution.

A base line that a side deliberately removed is **not** required to survive.
Honoring a deletion is an ordinary merge outcome that git itself performs without asking, and demanding its return would flag every legitimate deletion in every merge.

Comparison is on normalized lines: whitespace runs collapse, leading and trailing whitespace goes, and a leading markdown list marker or list number is stripped.
Re-indentation and renumbering therefore never register as loss on their own.

### The two rescues, and what each one costs

An exact line-survival test alone refuses correct work, and a check that refuses correct work gets switched off, after which nothing is enforced at all.
Two rescues make it survivable.
Each is a deliberate loss of strictness and is named here rather than left implicit.

1. **Relocation.** A required line counts as present if it appears anywhere in the merge's touched paths, not only in the path it came from.
   Moving a paragraph out of `AGENTS.md` into a skill is not content loss, and this repository's own knowledge-placement rules actively encourage that move.
   This is also what makes a rename survive, since a renamed file's content is found at its new path.
2. **Reformat and blend.** A required line still missing after (1) is rescued when every word it **introduced** relative to the base still appears somewhere in that path's resolved text.
   Re-indenting a line, renumbering a list, and fusing two sentences into one all preserve those words; dropping the line does not.
   The rescue's word comparison is case-insensitive, because fusing two sentences lowercases the second one's leading word - a rescue that failed on that single letter would refuse exactly the reformat it exists to allow.
   Exact line survival, above the rescue, is not case-folded.

## The layers, and which of them is load-bearing

### 1. The landing gate - this is the boundary

`bin/fm-pr-merge.sh` enumerates the merge commits in the range the PR would land, and for each one recomputes the verdict from that merge's own two parents and their merge base.

This is the boundary because firstmate runs it, over merges the worker has already finished producing, through a script the worker never invokes and cannot reach.
No `--no-verify`, no deleted hook, and no instruction the worker declined changes its answer.

It runs after the attribution gate and before the kept-tests gate, for the same reason attribution runs first: the read is git-local and cheap, and a PR that will be refused should not first spend the 20-35 minutes the kept-tests gate costs.

**It has no approval record and no override flag, and it does not need either.**
That is the one design decision here worth stating on its own, because every other refusing gate in `bin/fm-pr-merge.sh` has an escape hatch and this one deliberately has none.
A deliberate deletion is still perfectly allowed - it just may not hide inside a conflict resolution.
The worker keeps both sides in the merge, then deletes the content in its **own** commit with its own message.
This gate reads only merge commits, so that lands, and the deletion then appears in the PR diff as a decision somebody can review.
An override record would have converted a visible decision back into an invisible one, which is the entire failure this gate exists to stop.

### Why it does not overlap the kept-tests gate

`bin/fm-assert-tests-kept.sh` already catches a resolution that ate the base's asserted **behavior**, by running the base's own tests against the branch.
That gate is unchanged and is not weakened by this one.

This gate catches deleted **content that no test asserts** - documentation, comments, an evidence section, a rationale paragraph.
A test suite is structurally blind to all of it.
`2fa63cf` is the proof: the kept-tests gate would have passed it, because nothing it deleted was executable.

### 2. The commit-msg hook - a real mechanism, but not the boundary

`bin/fm-spawn.sh` calls `bin/fm-install-commit-hook.sh` for every task worktree it hands out.
That installer writes one shim into the project's own hooks directory which runs two checks in turn: `bin/fm-commit-msg-check.sh` for AI attribution, then `bin/fm-merge-resolution-check.sh` for this rule.
They share one hook file because git allows a repository exactly one `commit-msg` hook, so a second installer would have silently disarmed the first.
The shim's identity marker is deliberately **not** bumped for that shape change.
Nothing keys behavior off its version, the installer rewrites its own shim on every run so a stale one is refreshed at the next spawn anyway, and recognition is a plain substring test whose failure takes the foreign-hook branch and leaves the hook alone - so a bump any reader forgot to account for would silently disarm both checks in every project already spawned into.
`bin/fm-install-commit-hook.sh`'s header owns that reasoning.

The commit is rejected at the moment of resolution, with the lost lines named and both candidate resolutions spelled out.

It is a mechanism and not an instruction: it runs by default, on every merge commit, whatever the worker was or was not told, under every harness.
It is not the boundary, for two measured reasons:

- `git commit --no-verify` skips every `commit-msg` hook. `tests/fm-merge-resolution-gate.test.sh` case (i) asserts that skip works rather than hiding it.
- The hook file is an ordinary file in a directory the worker can write to, so a worker could delete it.

Its value is speed and specificity, not containment.

#### Why the hook target is `commit-msg` and not `pre-commit`

Measured on git 2.43.0, with all four hooks installed and logging:

| what the resolver did | `pre-commit` | `commit-msg` |
| --- | --- | --- |
| conflicted merge, resolve, `git commit` | fires | fires |
| conflicted merge, resolve, `git merge --continue` | fires | fires |
| `git merge -X ours` over a real conflict | **does not fire** | fires |
| clean auto-merge, nothing to resolve | does not fire | does not fire |

`git merge -X ours` and `-X theirs` auto-resolve a genuine conflict by discarding the other side outright and then auto-commit.
That is precisely the resolution this gate exists to catch, and it is the one path that never reaches `pre-commit`.
`commit-msg` covers all three resolving paths, so the check lives there.
`tests/fm-merge-resolution-gate.test.sh` cases (f) and (g) assert both `-X` directions are refused.

A refusal leaves `MERGE_HEAD` in place, so the merge is still in progress and the worker can fix the resolution and commit again without redoing it.

## Measured performance on this repository's own history

Every number below was produced by running the shipped `fm_additive_scan` over firstmate's own git history, not by estimate.

**Noise, on resolutions humans actually wrote.**
73 merge commits in the history, 17 of them carrying a real conflict resolution.
8 merges produce findings.
Among them are `2fa63cf`, the confirmed permanent loss described above, and `3fc685e`, where the branch's resolution dropped interim paragraphs that `main` had added - a genuine product decision about whether the branch's work obsoleted them.
The rest are single prose lines that one side reworded and the resolution replaced with the other side's wording.
Those are borderline by intent: under the captain's rule a replaced line **is** deleted content, and the check does not have, and cannot have, a way to tell a reword from a deletion.

**Detection, on resolutions that discard a side by construction.**
Each of the 18 conflicted merges was replayed as `git merge -X ours` and as `git merge -X theirs`, giving 36 resolutions that drop a side by definition.
30 are caught.
4 of the remaining 6 are correct silences: for merges `2213361` and `eed5b18`, `-X ours`, `-X theirs` and the human's real resolution all produce the byte-identical tree, so those conflicts had nothing to lose.
2 are genuine misses, and both are classified under "What this does not catch" below.

**Reference case.**
PR 46's actual conflict - `eba7add`, where one side appended two `FM_STATUSLINE_BASE` entries and the other appended two `uname` entries to the same list - passes with zero findings, while both of its `-X` replays are caught.
That pair is the whole contract in one commit, and `tests/fm-merge-resolution-gate.test.sh` cases (j) and (l) hold it up.

## What this does not catch

Stated so the gaps are visible rather than assumed closed.
This check answers one question - "did any line one side introduced disappear?" - and everything below is outside that question.

- **A resolution can keep every line and still be wrong.** Keeping both sides of two mutually exclusive changes - two conflicting config values, two incompatible function bodies - passes, and the result may not even work. The check measures presence, never coherence, and never correctness.
- **Duplication passes.** A resolution that keeps both sides' versions of the same reworded paragraph, side by side, is additive by this rule and is not flagged. It is redundant rather than lossy, but nothing here will say so.
- **Order is not checked.** Reordering that changes meaning - reversing steps in a procedure, moving a caveat away from the claim it qualifies - passes, because the captain explicitly placed ordering inside the coder's own discretion.
- **A reword whose words all survive elsewhere is rescued.** This is the price of rescue 2, and it is measured, not theoretical: replaying `bb5b77b` as `-X ours` drops the base's version of a `CONTRIBUTING.md` sentence, and because the two versions differ by a few words that appear elsewhere in the file, it is not flagged.
- **Content the base already had is out of scope.** If one side deleted a base line and the resolution honors that deletion, nothing fires - by design, as above. Measured consequence: replaying `b3a041d` as `-X ours` drops an eight-line `exclude_path()` function from `bin/fm-spawn.sh` that the base had and the other side kept, and it is not flagged.
- **Only paths BOTH sides changed are scanned.** A path only one side touched is merged by git without a decision, so a resolution that also deletes such a file is invisible here.
- **Binary paths are skipped.** They have no lines to keep.
- **Octopus merges are skipped.** The two-side verdict has no meaning for three parents. The authorship hook exits 0 and the landing gate reports them as unverifiable without blocking, because git cannot produce a conflicted octopus commit in the first place.
- **A squash merge erases the evidence afterwards.** The landing gate reads the branch's merge commits before the squash, so it is unaffected, but once landed the default branch's history no longer shows the resolutions the gate checked.
- **Nothing scans a push.** A branch can carry a deleting resolution on the remote until the landing gate refuses it.
- **A worktree handed out before this landed has no hook.** The installer runs at spawn, so work already in flight gets it only at its next spawn into that project. The landing gate covers those tasks meanwhile, which is the whole reason it is the boundary and the hook is not.

## Fail-open points, and why each one is deliberate

The authorship checker exits 0 when there is no `MERGE_HEAD`, when the merge is an octopus, when the repository cannot be read, or when the scan cannot complete.
A `commit-msg` hook that refuses on its own malfunction wedges every commit in the repository it was installed into, including the captain's own.
The installed shim exits 0 when a checker is not executable, so a firstmate checkout that moved cannot wedge every project it ever spawned into.
`bin/fm-spawn.sh` never fails a spawn over hook installation, and prints a notice instead.

Each of those sits in a layer that is explicitly not the boundary.
The landing gate has one non-blocking case of its own - a merge it could not read at all is reported and does not refuse - and that is bounded to the octopus shape described above.
A local copy that does not resolve is noted rather than refused, the same reasoned exception the attribution gate makes: `bin/fm-assert-tests-kept.sh` refuses that condition outright two gates later, so a merge whose local copy is missing cannot proceed regardless.

## Cost

Two `git diff --name-only` calls per merge, at most four blob reads per path both sides changed, and one blob read per touched path for the relocation corpus.
Only paths both sides changed can carry a resolution decision, so the per-path work is bounded by the conflict surface rather than by the size of the repository.
Scanning all 73 merges in this repository's history takes well under a second each.

## Escalating, when it is genuinely the captain's call

The refusal text names both candidate resolutions and hands the worker the exact line to report, because an escalation that names only the problem cannot be relayed as a choice:

```text
needs-decision: merge resolution drops <what>; (a) keep both sides, (b) drop <what> from <where>
```

That matches `bin/fm-brief.sh`'s `needs-decision: {summary of options}` contract.
`tests/fm-merge-resolution-gate.test.sh` case (e) asserts the refusal carries both candidates and that line.
