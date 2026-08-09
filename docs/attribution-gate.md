# The AI-attribution gate

This document is the authoritative human-readable contract for firstmate's refusal of AI attribution in shipped artefacts.
`bin/fm-attribution-lib.sh` is the single owner of the pattern set.
`bin/fm-commit-msg-check.sh` is the authorship-time checker, `bin/fm-install-commit-hook.sh` installs it, and `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` own the landing refusal.

**Where the enforcement physically lives:** in `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`, the two scripts firstmate runs to land work, which read the commit messages and PR description the worker already produced and exit non-zero rather than merging; a git `commit-msg` hook installed into each project's own repository catches the same patterns earlier, and a setting in the worker's harness config stops one harness generating them at all.

## The rule and why a written rule was not enough

The captain's standing rule is that no AI attribution appears in any shipped artefact.
That means no AI coauthor trailer, no session-link trailer, and no "generated with `<tool>`" footer, in a commit message, a PR body, release notes, or anything else that leaves the machine.

The rule was written in `/home/kiran/projects/gits/CLAUDE.md`.
It never reached a worker, for a structural reason: crewmates run in worktrees under `/home/kiran/.treehouse/...`, which is not inside `/home/kiran/projects/gits/`, so no harness ever loaded that file.
Every crewmate that has ever run was blind to it.

The damage is recorded, not inferred.
botoverflow PR 3 shipped a `Co-Authored-By` trailer naming an AI, a `Claude-Session:` line in its commit message, and a "Generated with Claude Code" footer in its PR description; botoverflow PR 2 shipped the same three.
On 2026-08-09 firstmate hand-edited both PR descriptions and hand-wrote squash-merge commit messages to keep the attribution off the default branch.
That is manual work standing in for a missing control, on every PR, and it only worked because someone happened to check.

The captain's test for whether a control is real: could the entity being checked have produced the thing being checked?
If yes, it is bookkeeping rather than a boundary.
Putting the rule in a brief fails that test outright, because a worker asked not to emit a trailer will sometimes emit one anyway - which is the entire observed failure.
So the layers below are described by what they actually constrain, and the ones that are not boundaries say so.

## The layers, and which of them is load-bearing

### 1. The landing gate - this is the boundary

`bin/fm-pr-merge.sh` reads the branch's commit messages out of the task's local copy with git, reads the PR description through one `gh pr view --json body` call, and refuses the merge when either carries attribution.
`bin/fm-merge-local.sh` does the same over every commit message a local-only fast-forward would put on the default branch.

This is the boundary because firstmate runs it, over an artefact the worker has already finished producing, through a script the worker never invokes and cannot reach.
No `--no-verify`, no deleted hook, and no instruction the worker declined changes its answer.
There is no override flag.
A read that fails refuses as unverified rather than passing, matching how every other gate in `bin/fm-pr-merge.sh` treats evidence it could not obtain.

### Where each half is read, and why not both from the API

The commit messages come from git, in the task's own local copy. Git is the authority for what a commit message says, the read costs no network call, and nothing but git can answer it wrongly.
The ref it reads is chosen exactly as `bin/fm-assert-tests-kept.sh` chooses its compare side: the PR head when that is recorded and resolvable locally, and the local branch with a warning when it is not.
That is deliberate rather than convenient - the merge already trusts that same resolution for its test verdict, so the attribution verdict is measured against the same commits and never a second opinion about which they are.

The PR description has no local source, so it is the one API read, and it asks for the field as raw text rather than as JSON.
On a real PR the answer is the description; a PR with no description answers with nothing, which carries no attribution and is therefore not a finding.
A read that actually fails still exits non-zero and still refuses.

The limit of that choice, stated rather than left implicit: this cannot distinguish "this PR has no description" from "the tool returned nothing". In production `gh` either errors, which refuses, or prints the field, which is scanned. The half that reaches the default branch - the commit messages - is not subject to that ambiguity at all, because git either has the commits or the merge has already been refused for not resolving them.

A local copy that does not resolve is noted, not refused. `bin/fm-assert-tests-kept.sh` runs two gates later in the same command and refuses outright when it cannot resolve the task's worktree, so a merge whose local copy is missing cannot proceed whatever this gate says. Refusing twice for one cause would only make an unrelated worktree problem surface as an attribution failure.

It runs before the kept-tests gate.
That gate is the dominant cost of landing a PR, at roughly 20-35 minutes on firstmate itself, and a PR that will be refused for attribution should not spend that time first.
`tests/fm-pr-merge.test.sh` proves the ordering on a branch that would fail both gates.

### 2. The commit-msg hook - a real mechanism, but not the boundary

`bin/fm-spawn.sh` calls `bin/fm-install-commit-hook.sh` for every task worktree it hands out, which puts a shim in the project's own hooks directory that execs `bin/fm-commit-msg-check.sh`.
The commit is rejected at the moment of authorship, with the offending lines named.

It is a mechanism and not an instruction: it runs by default, on every commit, whatever the worker was or was not told, under every harness, and whether the message arrived through `-m`, `-F`, an editor, or `--amend`.
It is not the boundary, for two reasons that are measured rather than assumed:

- `git commit --no-verify` skips every `commit-msg` hook. `tests/fm-attribution-gate.test.sh` case (k) asserts that skip works rather than hiding it.
- The hook file is an ordinary file in a directory the worker can write to, so a worker could delete it.

Its value is speed and specificity, not containment.
A worker that hits it fixes its own message in seconds, instead of firstmate discovering the same thing at merge time and bouncing the work back.

### 3. The harness attribution setting - generator removal, not enforcement

`bin/fm-spawn.sh` writes `"attribution":{"commit":"","pr":"","sessionUrl":false}` into a Claude worker's `.claude/settings.local.json`.
Read from the installed binary's own settings schema (claude 2.1.226): `commit` and `pr` are the attribution text and "Empty string hides attribution", and `sessionUrl` is documented as "Set to false to omit the Claude-Session trailer and PR-body link".
The deprecated `includeCoAuthoredBy` boolean still exists and defaults to true; `attribution` supersedes it.

This is worth having because it removes the instruction that produced the trailer in the first place, and it costs nothing.
It is explicitly not counted as enforcement.
It covers one of the five supported harnesses, and it only stops the harness appending the text - a model can still type the same line into a message by hand.

## The pattern set

`bin/fm-attribution-lib.sh` owns these and every enforcer reads them from there, so the rule is stated once.

| Rule | Fires on |
| --- | --- |
| `ai-coauthor` | A line starting a credit trailer (`co-authored-by`, `co-author`, `coauthored-by`, `assisted-by`, `generated-by`) whose value names an AI. |
| `session-trailer` | A line starting `claude-session:` with any value. |
| `generated-footer` | A line whose first letters are `generated with` or `generated by`, naming an AI tool. |

Matching is case-insensitive, and the AI and tool names are compared as plain substrings rather than assembled into a regex, so a token containing `.` or `-` cannot behave as a metacharacter.
Leading whitespace is ignored, and a leading run of non-letters is ignored for the footer rule so the robot-face emoji the real footer carries does not hide it.

### Why the patterns are line-anchored

A git trailer is only a trailer at the start of a line, and the footer is emitted at the start of its own line.
Anchoring there is what lets prose about the rule pass: "we stripped the `Co-Authored-By` trailer" mid-sentence, or the same words as a markdown bullet, is discussion rather than attribution.
This matters more than it looks.
A gate that refuses its own documentation and its own fix gets switched off, and then nothing is enforced at all.
The cost is that an attribution line deliberately placed at column zero inside a fenced code block in a PR body is refused; that is the correct trade, and it is stated here rather than discovered.

### What the commit-message checker does not scan

Under `commit.verbose` the message file carries the staged diff below git's scissors line, and it carries git's own `#` comment lines.
Both are stripped before scanning.
Without that, a commit whose diff adds a line showing one of these patterns would be read as a commit committing attribution - which is the shape of every commit in the change that introduced this gate.

## Measured facts

Git hooks are per-repository, not per-worktree.
Verified on git 2.43.0: inside a linked worktree, `git rev-parse --git-path hooks` resolves to the common directory (`<repo>/.git/hooks`), and no `hooks` directory exists under `<repo>/.git/worktrees/<name>/`.

```text
$ git -C /home/kiran/.treehouse/firstmate-16c429/2/firstmate rev-parse --git-path hooks
/home/kiran/projects/gits/firstmate/.git/hooks
```

Three consequences follow, and the installer's design rests on them.
One install covers a project's primary checkout and every worktree of it, so a second spawn in the same project is a no-op.
There is no per-worktree hooks directory to install into even if per-worktree scoping were wanted.
`tests/fm-attribution-gate.test.sh` case (h) asserts both halves of this against a real linked worktree, so a future git that changes the resolution breaks the suite rather than silently disarming the hook.

Writing that hook puts a file under the project's `.git/`, which is local git metadata rather than project content.
It is the same class of write `bin/fm-spawn.sh` already makes to `<git-common-dir>/info/exclude` on every spawn.
It touches no tracked file, makes no commit, and moves no ref.

## Deliberate gaps

These are stated so the gap is visible rather than assumed closed.

- **A PR description is published the moment the PR is opened.** The gate refuses to merge it, which keeps the attribution off the default branch, but it cannot un-publish what GitHub already has. Anyone watching the repository saw it. The commit-msg hook has no equivalent for the body, because the body never passes through git. Closing this properly would need a check on the `gh pr create` call itself, in every harness's tool-call path; that is the shape of the existing PreToolUse seatbelts (`docs/arm-pretool-check.md`) and is not built here.
- **A project that already has its own `commit-msg` hook keeps it.** `bin/fm-install-commit-hook.sh` exits 3 and leaves the foreign hook alone, because silently replacing a project's hook would break that project in order to enforce our rule. Those projects get the landing gate only.
- **The harness setting covers claude alone.** Whether codex, opencode, pi, or grok generate attribution of their own has not been measured; the pattern set already covers the names they would plausibly use, and both gates are harness-independent, so an unmeasured generator is caught rather than shipped.
- **Nothing scans a push.** A branch pushed to a remote can carry attribution in its commit messages until the merge gate refuses it. The refusal is at landing, not at push.
- **`bin/fm-pr-merge.sh` forwards extra arguments to `gh-axi pr merge`.** A caller that passes its own `--body` there writes text the gate never read.
- **Release notes, tags, and issue comments are not covered.** Only commit messages and the PR description are.
- **A worktree handed out before this landed has no hook.** The installer runs at spawn, so work already in flight gets the hook only at its next spawn into that project. The landing gate covers those tasks meanwhile, which is the whole reason it is the boundary and the hook is not.
- **A refusal inside another tool's commit surfaces as that tool's failure.** If anything that commits on the branch on the worker's behalf - the no-mistakes pipeline, a formatter's auto-commit - ever emits attribution, the hook refuses that commit rather than rewriting it quietly. That is the intended outcome, but it appears as a stalled pipeline step, so the message to look for is the checker's own `refused: this commit message carries AI attribution`.

## Fail-open points, and why each one is deliberate

The shim exits 0 when its checker is not executable, so a firstmate checkout that moved or was removed cannot wedge every commit in every project it ever spawned into.
The checker exits 0 on a missing or unreadable message file, for the same reason: a `commit-msg` hook that refuses on its own malfunction blocks the captain's own commits too.
`bin/fm-spawn.sh` never fails a spawn over hook installation, and prints a notice instead.

Each of those is a fail-open in a layer that is explicitly not the boundary.
The landing gate has no fail-open path: an unreadable PR refuses.
