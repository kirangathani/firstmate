# Carrying worker context into no-mistakes gate agents

This document is the authoritative human-readable contract for the three mechanisms that carry a crewmate's own context through a no-mistakes run.
`bin/fm-fix-instructions-policy.mjs` owns the fix-round refusal decision, `bin/fm-fix-instructions-check.sh` is only its harness transport, `bin/fm-nm-intent.sh` owns the run intent string, and `bin/fm-nm-decision.sh` owns the durable gate-decision record.
`bin/fm-brief.sh` is the one place that instructs a worker to use all three.

## The problem

A crewmate that reaches a no-mistakes gate has exactly three responses: `approve`, `fix`, `skip`.
`--action fix` hands the work to no-mistakes' own gate agent, which is not the crewmate.
That agent sees the finding text and the diff, and nothing else.

It cannot see the crewmate's brief, because the brief lives at `data/<id>/brief.md` inside the firstmate home, outside the project repo, while the gate agent runs in a gate worktree of the project.
In the firstmate repo it also cannot see `AGENTS.md`, because `.no-mistakes.yaml` sets `disable_project_settings: true` on purpose, so a gate agent never adopts the fleet-captain identity.
That setting stays; re-enabling project settings to give the gate agent context would recreate the containment failure recorded in `bin/fm-gate-refuse-lib.sh`.

So the only two channels that carry a worker's context into a gate agent are the run's `--intent` and a fix round's `--instructions`.

Measured cost of leaving that unenforced: task `nm-flow-view-r7` spent four review rounds on successive variants of ONE defect, a reporting surface implying verification it had not performed.
Each round was a fresh gate agent that fixed the symptom and reintroduced the class, because the design principle never reached it.

## Verified facts this is built on

Verified 2026-08-03 against the installed `no-mistakes version v1.37.0 (78e4dcb)`.

`no-mistakes axi respond --help`:

```text
      --action string         approve | fix | skip (required)
      --instructions string   guidance applied to the selected findings (with --action fix)
```

`no-mistakes axi run --help`:

```text
      --intent string   what the user set out to accomplish (not a description of the diff); used instead of inferring from transcripts (required to start a run)
```

`gh api repos/kunchenguid/no-mistakes/issues/591` returns issue 591, state `open`, filed 2026-07-26 by `jokim1` against `v1.40.0`, titled "Test-step auto-fix silently reverted ask-user decisions and the final review passed with 0 findings".

## Part A: the fix-instructions seatbelt

`bin/fm-spawn.sh` installs `bin/fm-fix-instructions-check.sh` as a PreToolUse-equivalent deny check in each crewmate's own worktree hook file, following the three primary-side precedents `bin/fm-arm-pretool-check.sh`, `bin/fm-cd-pretool-check.sh`, and `bin/fm-continuity-pretool-check.sh`.
A newly spawned crewmate receives it automatically; there is no per-task wiring.
A secondmate does not, because a secondmate is a firstmate in its own home, not a worker driving a gate.

### What it refuses, and the settled limits of that

It refuses a `no-mistakes axi respond --action fix` command that either carries no `--instructions` at all, or whose instructions fall below the substance floor.

**This strictness is a captain ruling and is settled.**
Presence-only was explicitly rejected, because a one-word argument satisfies it.
Additionally requiring named content checked by keyword or structure was explicitly rejected, because a structural check on prose produces false refusals.
The consequence was stated and accepted: this enforces presence and length but never quality, and a worker could route the command through a script file and sidestep the text match.
Do not widen or narrow the rule, and do not re-raise these limits as blockers.

The refusal names what is missing and what the instructions must contain: the design reasoning behind the code the finding touches, the principle the fix must preserve, and what it must not break or reintroduce.

### The substance floor

`MIN_INSTRUCTIONS_CHARS` in `bin/fm-fix-instructions-policy.mjs` is the named owner of the floor, currently 120 characters of cooked instruction text after trimming.
The refusal asks for three distinct things, and written as tersely as a real answer can be each is a clause of roughly 40 characters, so 120 is the shortest text that could plausibly carry all three.
It is calibrated as "too short to be an answer at all", not as a quality bar: high enough to reject a one-word or one-phrase argument, low enough that a genuine two-sentence answer always clears it.
`tests/fm-fix-instructions-check.test.sh` reads the constant from the module and pins the boundary to it exactly, so the number cannot drift away from the test.

### Classification

The policy never executes, sources, evaluates, or expands any part of the submitted command; it inspects lexical command positions only, reusing the tokenizer and command-position analysis owned by `bin/fm-arm-command-policy.mjs`.

A node is relevant when its executed command word is literally `no-mistakes` (bare or path-qualified) and its positionals are `axi respond`.
Flag parsing follows `no-mistakes axi respond --help`: `--action`, `--step`, `--findings`, `--add-finding`, and `--instructions` consume the next word, everything else is boolean, and a repeated flag is last-wins.
Both `--flag value` and `--flag=value` forms are recognized.
Literal `sh|bash|zsh|dash|ksh -c` payloads, literal `eval` payloads, and subshell or brace groups are re-classified one level down, to a depth of 3.

Two deliberate allows:

- A `--instructions` or `--action` value that is not statically literal (it contains `$VAR`, `$(...)`, or a backtick) cannot be measured without running it, so it allows. A false refusal of a genuine long instruction is worse than missing a dynamic bypass, and the threat model is a forgetful worker, not an adversary.
- Syntax the classifier cannot tokenize fails open, matching the sibling cd-guard rather than the arm guard. Bypassing this gate costs a context-free fix round; it does not kill supervision.

### Stable reason codes

| Code | Meaning |
| --- | --- |
| `fix-instructions-missing` | A fix round carries no `--instructions` at all. |
| `fix-instructions-thin` | The instructions are shorter than `MIN_INSTRUCTIONS_CHARS`. |

### Output contract

Identical in shape to `bin/fm-cd-pretool-check.sh`:

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[code] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[code] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely, because Claude ignores a PreToolUse deny when stdout is non-empty.
- Malformed or empty stdin, invalid JSON, missing `jq` for stdin transport, missing Node, a missing classifier, or an invalid classifier response all fail open with exit 0 and no output.

Unlike the sibling seatbelts, this transport carries no checkout scoping.
It is never registered in a primary session: its presence in a crewmate's hook file is the scope.

### Harness wiring

`bin/fm-spawn.sh` writes each of these alongside the turn-end signal that harness already used.

| Harness | Hook location | Payload field | Adapter behavior on exit 2 |
| --- | --- | --- | --- |
| Claude | `<worktree>/.claude/settings.local.json`, `PreToolUse` matcher `Bash` | `.tool_input.command` | Blocks directly; the hook passes `--claude` so stdout stays empty. |
| Codex | `<worktree>/.codex/hooks.json`, `PreToolUse` matcher `Bash` | `.tool_input.command` | Blocks on exit 2 and displays stderr. |
| Grok | `${GROK_HOME:-$HOME/.grok}/hooks/fm-pretool-check.json` plus `fm-pretool-check.sh` | `.toolInput.command` | Consumes the stdout `decision=deny` object. |
| OpenCode | `<worktree>/.opencode/plugins/fm-turn-end.js`, `tool.execute.before` | `output.args.command` | Blocks by throwing, only for exit 2. |
| Pi | `<firstmate-home>/state/<id>.pi-ext.ts`, `tool_call` | `event.input.command` | Returns `{block: true}`, only for exit 2. |

Every worktree-resident hook is added to the worktree's `info/exclude`, exactly as the turn-end hooks already were, so it never blocks teardown's dirty check or rides into a commit.

Grok takes the global-hook route for the same reason its turn-end hook does: Grok loads project hooks only after the folder is granted hook-trust in `~/.grok/trusted_folders.toml`, which firstmate will not establish by editing Grok's managed trust store, while global hooks in `~/.grok/hooks/` always load.
The global hook is therefore a no-op for every Grok session that is not a firstmate crewmate worktree: it fires only when the workspace holds a `.fm-grok-turnend` pointer whose token matches the firstmate-owned registry.
Every `$VAR` in a Grok hook command string must carry an inline `:-default` or the hook fails to load at all, so the tracked command references none directly.

### Known gap: Codex project-hook trust

**Unverified and flagged.** Codex gates project hooks on folder hook-trust, and `bin/fm-spawn.sh`'s Codex crewmate launch (`codex --dangerously-bypass-approvals-and-sandbox`) does not establish it; the recorded validations elsewhere in `docs/` reached Codex project hooks only by passing `--dangerously-bypass-hook-trust` explicitly.
In a worktree Codex has not been trusted for hooks, `<worktree>/.codex/hooks.json` is inert rather than wrong: the seatbelt simply does not fire, exactly as if the file were absent.
Codex was not installed in the environment where this was built, so neither the loading nor the non-loading was confirmed live.

Closing it would mean adding `--dangerously-bypass-hook-trust` to the Codex crewmate launch template.
That is a launch-time trust posture change with its own blast radius (it would also trust a project's own `.codex/hooks.json`), so it is left as a captain decision rather than taken unilaterally.

## Part B: the pinned run intent

`bin/fm-nm-intent.sh` is the ONE owner of the `--intent` string.
It prints the `# Task` section of `data/<task-id>/brief.md`, whitespace-normalized to a single line.
Nothing else is consulted, so there is no second copy to keep in sync.

The generated no-mistakes ship brief instructs the worker to start every run with:

```sh
no-mistakes axi run --intent "$(<firstmate-root>/bin/fm-nm-intent.sh <task-id>)"
```

The WHOLE Task section is emitted, acceptance criteria and constraints included, not just its first paragraph.
That is deliberate: the pipeline's final review step scores the diff against the intent, so handing it the full stated criteria makes that review stricter, and any truncation rule would silently decide which of the captain's requirements stop being checked.

It refuses loudly (exit 1, nothing on stdout) when the brief is missing, has no `# Task` section content, or still carries an unreplaced `{TASK}` placeholder.
A silent empty intent would be worse than a stop.

## Part C: recorded decisions must survive the run

Upstream issue #591 documents this sequence on `v1.40.0`: an operator answered three ask-user findings through the supported `--action fix` path with guidance in `--instructions` and no `--yes`; the gate recorded them resolved and applied them; a later step's auto-fix in the same run reverted all three and added a contract test pinning one reversal in place; the pipeline's final review step then passed with 0 findings and reported the PR ready.

The reporter's diagnosis, which firstmate takes as the design fact: decisions recorded at a gate are treated as input to the step that raised them, not as constraints on later steps, and the final review evaluates against `--intent`, which was written before any decision existed and therefore always describes the pre-decision state.
The pipeline self-certified a state that contradicted three explicit decisions.
It was caught only because the driving agent diffed by hand rather than trusting `checks-passed`.

no-mistakes is third-party and this fleet does not own its source, and the standing captain ruling is not to change it, so the guard is firstmate-side.
`bin/fm-nm-decision.sh` owns the durable record at `data/<task-id>/decisions.md`, alongside the task's brief and report, so it survives worktree teardown the same way they do.

The generated ship brief requires the worker to:

1. `record` each decision at the moment it is submitted, with the finding id, the decision key, and what the decision required in concrete, checkable terms.
2. `verify` each one against the FINAL diff before reporting a PR ready, with the file:line or commit that proves it still holds, and state that verification explicitly in the completion report.
3. Mark a reverted decision `reverted` and STOP: append a blocked line naming the decision and the reverting commit, never report done, and never re-fix it alone.
4. Pass `check` before reporting done. It exits 0 only when every recorded decision is `satisfied`, and refuses while any is `pending` or `contradicted`. A task with no recorded decisions passes, because a run with no gate decisions has nothing to survive.

The record is append-mostly: `verify` and `reverted` rewrite only the state and evidence lines of the named decision, never its `requires` text, so what a decision demanded cannot be edited after the fact to match what shipped.

The brief states explicitly that **`checks-passed` alone is not evidence that a decision survived**, because that assumption is exactly what the upstream failure exploited.

## Validation

`tests/fm-fix-instructions-check.test.sh` owns the seatbelt's acceptance matrix: 35 cases across all five harness entry forms, the exact substance-floor boundary read from the named constant, transport fail-open behavior, the strict-superset prefilter, and per-harness wiring driven through the REAL `bin/fm-spawn.sh`.
The Claude, Codex and Grok hooks are proven end to end by executing the exact command string `fm-spawn` recorded, against both a refusal case and a pass case.
The OpenCode plugin and Pi extension are proven end to end by importing the generated file in Node and invoking the generated blocking callback, again both ways.
The Grok global hook is additionally proven inert for a workspace with no token pointer and for one whose pointer names an unregistered token.

`tests/fm-nm-gate-context.test.sh` owns the intent owner, the decision record lifecycle, and the generated brief's contract.

No harness binary was spawned by either suite.
**Live per-harness hook-loading was not confirmed for Codex, OpenCode, Pi, or Grok**: only `claude` (2.1.220) was installed in the environment where this was built.
The wiring shapes follow the already-verified per-harness mechanics recorded in `docs/arm-pretool-check.md` and the `harness-adapters` skill, and the generated adapter code is exercised directly by the suites above, but the step of "the harness actually loads this file" is inherited from those prior validations rather than re-observed here.

Run:

```sh
bash -n bin/fm-fix-instructions-check.sh
shellcheck bin/fm-fix-instructions-check.sh bin/fm-nm-intent.sh bin/fm-nm-decision.sh
node --check bin/fm-fix-instructions-policy.mjs
tests/fm-fix-instructions-check.test.sh
tests/fm-nm-gate-context.test.sh
bin/fm-lint.sh
bin/fm-test.sh
```
