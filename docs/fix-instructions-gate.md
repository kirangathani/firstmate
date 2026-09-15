# Carrying worker context into no-mistakes gate agents

This document is the authoritative human-readable contract for the mechanisms that carry a crewmate's own context through a no-mistakes run, and for the gate that makes the sanctioned attach command the only one available.
`bin/fm-fix-instructions-policy.mjs` owns every refusal decision, `bin/fm-fix-instructions-check.sh` is only its harness transport, `bin/fm-nm-attach.sh` owns attaching to a run, `bin/fm-nm-intent.sh` owns the run intent string, and `bin/fm-nm-decision.sh` owns the durable gate-decision record and the amendment that carries each decision into that intent.
`bin/fm-brief.sh` is the one place that instructs a worker to use them.

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

## Part A: the no-mistakes command seatbelt

`bin/fm-spawn.sh` installs `bin/fm-fix-instructions-check.sh` as a PreToolUse-equivalent deny check in each crewmate's own worktree hook file, following the three primary-side precedents `bin/fm-arm-pretool-check.sh`, `bin/fm-cd-pretool-check.sh`, and `bin/fm-continuity-pretool-check.sh`.
A newly spawned crewmate receives it automatically; there is no per-task wiring.
A secondmate does not, because a secondmate is a firstmate in its own home, not a worker driving a gate.

### What it refuses: the raw attach

It refuses any command whose executed program is `no-mistakes` and whose subcommand is `axi run` or `axi respond`, naming `bin/fm-nm-attach.sh` as the route to use instead.
Reason code `nm-raw-attach`.

Those two subcommands are the only ones that block on the daemon: they ATTACH to the branch's run and hold until the next gate, decision point, or outcome, or until `--wait` (default 8m) elapses.
A full run is 25-35 minutes, so in the foreground the wait elapses three or four times per run, each return costing a turn and carrying no news.
Measured 2026-09-15 on task `eln-location-no-project-l3`: three consecutive foreground holds, three `error: wait of 8m0s elapsed while driving the run` returns, no progress.
Worse, the daemon pushes nothing, so an ask-user finding parks a step at `awaiting_approval` and waits indefinitely, noticed only when somebody happens to reattach.

**Backgrounding had to be owned rather than inspected.** A PreToolUse hook sees only the model's command string, and `bin/fm-arm-pretool-check.sh`'s header records the reason that is not enough: harness-native tracked background execution is not itself a policy signal.
So the hook cannot verify that a command was backgrounded with a long wait; it can only refuse the command and name one that always is.
Part D owns what the wrapper guarantees.

`axi status`, `axi logs`, `axi sync` and `axi abort` all return immediately and are untouched, as are `no-mistakes doctor`, `no-mistakes init`, and `--version`.

An invocation carrying a literal `--help` or `-h` WORD also allows, and that is exact rather than lenient: no-mistakes is a Cobra program, so help short-circuits the command and nothing is driven, and the generated brief itself points a worker at `no-mistakes axi run --help`.
The test is on a whole word in the argument list, so a `--help` appearing inside a flag's VALUE is a different token and still denies - `no-mistakes axi run --intent "x --help y"` is refused, `no-mistakes axi run --intent x --help` is not, and the suite pins both.

This rule fires ahead of the substance floor below, so through this transport every fix round now denies as `nm-raw-attach`.
The floor is not weakened by that: the wrapper calls this same policy owner in `--fix-instructions-only` mode before it sends a response, which is the one remaining place the floor can fire, and `tests/fm-fix-instructions-check.test.sh` pins its whole acceptance set in that mode.

### What it refuses: a context-free fix round, and the settled limits of that

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

| Code | Meaning | Mode |
| --- | --- | --- |
| `nm-raw-attach` | A raw `no-mistakes axi run` or `axi respond`, which `bin/fm-nm-attach.sh` owns. | default only |
| `fix-instructions-missing` | A fix round carries no `--instructions` at all. | both |
| `fix-instructions-thin` | The instructions are shorter than `MIN_INSTRUCTIONS_CHARS`. | both |

`--fix-instructions-only` on the policy CLI selects the second mode, which skips the raw-attach rule.
It exists for exactly one caller, `bin/fm-nm-attach.sh`, because the default mode would refuse the very command that script exists to run.

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

### Codex crewmates launch with hook trust bypassed

Codex gates project hooks on folder hook-trust, and the recorded validations elsewhere in `docs/` reached Codex project hooks only by passing `--dangerously-bypass-hook-trust` explicitly.
`bin/fm-spawn.sh` will not establish that trust by writing Codex's managed trust store, so without the flag `<worktree>/.codex/hooks.json` would be inert rather than wrong: the seatbelt simply would not fire, exactly as if the file were absent.

**So the Codex CREWMATE launch template in `bin/fm-spawn.sh` now passes `--dangerously-bypass-hook-trust`.**
This is stated here rather than buried in the script because it is a launch-time trust posture change, not a detail.
The cost was put to the captain before he ruled, and he accepted it: a Codex crewmate runs a repository's own hook code at launch with no trust check, in any repo this fleet clones, which is a standing route for a hostile repository to execute code at launch.

The ruling covers the Codex crewmate launch only.
It does not extend to any other harness, to any other Codex safety flag, or to a Codex secondmate launch, which still launches without the flag.

**Unverified, and it must stay labelled that way.** Codex was not installed in the environment where this was built, so whether the flag in fact makes the hook fire on Codex was never observed here.
It follows from Codex's documented trust gate, which is an inference, not a measurement.
The first session with Codex installed should confirm it.
`tests/fm-fix-instructions-check.test.sh` pins the flag's presence on the crewmate launch and its absence on the secondmate launch, so the scope cannot be silently widened or the flag silently dropped, but a passing test proves only what `fm-spawn` emits, never that Codex honors it.

If the flag is ever removed or fails to apply, this section and the enforcement's own reporting must say the seatbelt is NOT active on that launch rather than staying quiet.

## Part B: the pinned run intent

`bin/fm-nm-intent.sh` is the ONE owner of the `--intent` string.
It prints the `# Task` section of `data/<task-id>/brief.md`, whitespace-normalized to a single line.
That section includes the `## Gate decisions` subsection Part C writes into it, so the intent tracks the decided goal rather than the goal as first dispatched.
Nothing else is consulted, so there is no second copy to keep in sync.

The generated no-mistakes ship brief no longer emits that command.
It names `bin/fm-nm-attach.sh` (Part D), which composes the intent through this owner itself:

```sh
FM_HOME=<firstmate-home> <firstmate-root>/bin/fm-nm-attach.sh <task-id>
```

So the intent has one owner and one caller, and a worker cannot start a run with a paraphrase even by accident, because it never assembles the `--intent` flag at all.

The `FM_HOME=` prefix is load-bearing, not decoration, and `bin/fm-brief.sh` embeds the resolved home into every command it emits for every helper.
The helpers read `data/<task-id>/` under the HOME while the scripts come from the shared tracked code ROOT, and a crewmate pane is launched with no `FM_HOME` of its own: only a `--secondmate` launch carries that env prefix.
In the main home the two paths coincide, so a root-anchored command happens to work; in a secondmate home they do not, which is the entire point of the `FM_HOME` split.
Root-anchored, a secondmate's crewmate resolved `data/` to the code root, found no brief, and could not start a run at all.
`tests/fm-nm-gate-context.test.sh` runs the brief's own emitted command with `FM_HOME` scrubbed from the environment, so the root-anchored form cannot return.

The WHOLE Task section is emitted, acceptance criteria and constraints included, not just its first paragraph.
That is deliberate: the pipeline's final review step scores the diff against the intent, so handing it the full stated criteria makes that review stricter, and any truncation rule would silently decide which of the captain's requirements stop being checked.

It refuses loudly (exit 1, nothing on stdout) when the brief is missing, has no `# Task` section content, or still carries an unreplaced `{TASK}` placeholder.
A silent empty intent would be worse than a stop.

## Part C: a gate decision amends the pinned intent

Upstream issue #591 documents this sequence on `v1.40.0`: an operator answered three ask-user findings through the supported `--action fix` path with guidance in `--instructions` and no `--yes`; the gate recorded them resolved and applied them; a later step's auto-fix in the same run reverted all three and added a contract test pinning one reversal in place; the pipeline's final review step then passed with 0 findings and reported the PR ready.

The reporter's diagnosis, which firstmate takes as the design fact: decisions recorded at a gate are treated as input to the step that raised them, not as constraints on later steps, and the final review evaluates against `--intent`, which was written before any decision existed and therefore always describes the pre-decision state.

The stale `--intent` is the root cause, and it costs more than the reverted-decision case that exposed it.
A run scored against a goal the captain has since changed can fail code that correctly matches the DECIDED goal, which is the more expensive half: the pipeline then spends fix rounds undoing a decision the captain made.
So the fix moves the intent rather than auditing the diff after the fact.

`bin/fm-nm-decision.sh` owns the durable record at `data/<task-id>/decisions.md`, alongside the task's brief and report, so it survives worktree teardown the same way they do.
Its `record` action writes each decision into the `# Task` section of `data/<task-id>/brief.md`, under a `## Gate decisions` subsection, as one `- <finding> [<key>]: <requires>` line.
`bin/fm-nm-intent.sh` emits that whole section and stays the one owner of the intent string, so the amendment reaches the pipeline on the very next call with no second reader and nothing to keep in sync.
Re-recording the same key rewrites its line and its record block rather than duplicating either, so a revised decision leaves exactly one current statement of itself in both places.
`record` refuses when the brief is missing or has no `# Task` section, and writes nothing at all in that case, because a decision recorded into the record but not into the intent is exactly the drift this removes.

The subsection carries no HTML marker, unlike the machine-written regions in `bin/fm-brief.sh`.
The heading is the anchor instead, because `bin/fm-nm-intent.sh` emits this text verbatim into `--intent`, where a marker would be noise the pipeline's own review has to read past.

The generated ship brief then requires the worker to:

1. `record` each decision at the moment it is submitted, with the finding id, the decision key, and what the decision required in concrete, checkable terms.
2. Start a fresh run with the same attach command once a run in which any `change` decision was recorded reaches its outcome.
   That run's review is the mechanical proof that the branch and the decided goal agree, and it is also the only thing that re-reviews whatever the later auto-fix steps (test, document, lint) changed.
3. Pass `rerun-check` before reporting done.
   It exits 0 only when every recorded `change` decision was recorded during a run older than the most recent one, and exits 1 both when such a decision is still waiting for that re-run and when the current run id cannot be read at all.

## Part D: one owner for attaching to a run

`bin/fm-nm-attach.sh` is the only sanctioned way to start, reattach to, or respond to a run, and its header owns the exact mechanics.
Three guarantees are what make it worth having, and none of them is an instruction a worker can decline:

1. **It always detaches and always returns immediately.**
   The attach runs in its own process group and session (`setsid`, `nohup` where absent) with stdin closed and both streams in the task's own temp root, and the caller gets the log path and control back at once.
   A worker cannot obtain the foreground shape from it.
2. **It always uses a multi-hour wait.**
   `FM_NM_ATTACH_WAIT` defaults to `3h`, comfortably past a 25-35 minute run, so the hold returns on a real event rather than on the clock.
3. **The hold's return becomes a wake, not a thing to notice.**
   The same detached process re-reads `no-mistakes axi status` and appends exactly one line to `state/<task-id>.status`, so the run's next event reaches firstmate even if the worker is idle, compacted, or gone.

Verified 2026-09-15 against `no-mistakes version v1.70.1`:

- `no-mistakes axi run --help` documents `--wait duration` (default `8m0s`) as "maximum time to block driving this run before returning so the caller can reattach", and states the 10-minute harness tool cap as the reason for that default.
- `--wait` accepts a multi-hour value. `no-mistakes axi run --wait 3h` in a non-repo directory clears flag parsing and fails later with `error: not in a git repository`, while `--wait 3x` fails at parse time with `invalid argument "3x" for "--wait" flag: time: unknown unit "x" in duration "3x"`. The source agrees: `internal/cli/axi_drive.go:47` registers it with `cmd.Flags().DurationVar`, so the value goes through `time.ParseDuration` and has no upper bound of its own.

Every source citation in this document was read with `git show v1.70.1:<path>` in the `projects/no-mistakes` clone, not from that clone's working tree.
The distinction matters: the clone's own checkout is at `ce2d749` (`v1.75.3-1-gce2d749`), five minor versions ahead of the installed binary, so its working tree describes a renderer this machine does not run.
`v1.70.1` resolves to `9c380d4`, the exact commit the installed tool reports.
- `no-mistakes axi respond --help` carries the identical `--wait` flag and the identical default.

### The status line, and why each verb is the one it is

`bin/fm-classify-lib.sh` owns firstmate's wake vocabulary, and the wrapper uses only verbs that library already triages, so its line is never absorbed as a no-verb signal.
Every line carries the same `[key=nm-run]` token, because a task has at most one active run and that library's keyed fold is what stops an earlier parked gate being masked by a later append.

| Situation | Line | Why that verb |
| --- | --- | --- |
| parked at a gate | `needs-decision [key=nm-run]: run <id> parked at <step> (<gate-status>) - respond through ...` | captain-relevant, and it OPENS the keyed decision so a park cannot rot silently |
| run passed | `resolved [key=nm-run]: run <id> <passed\|checks-passed>` | CLOSES the key, since nothing is owed at the gate. Not captain-relevant by verb, which is correct: the watcher then asks `bin/fm-crew-state.sh` whether the crew is provably working, and a finished run is not, so the wake surfaces on the real state rather than on a hardcoded word |
| run failed or cancelled | `blocked [key=nm-run]: run <id> <outcome>: <error>` | captain-relevant, and `blocked` REPLACES the record under the same key: what firstmate owes moved from answering the gate to dealing with a dead run, which is one open decision, not two |
| `--wait` elapsed, run still live | `paused [key=nm-run]: run <id> still <status> at <step> after <wait>; reattach with ...` | the library's exact declared-external-wait case: expected to clear on its own, so an idle pane is not escalated as a possible wedge |
| daemon did not answer | `blocked [key=nm-daemon]: daemon unreachable while attached to run <id>` | its own key, because a dead daemon is not this run's gate |
| no run for this branch | `blocked [key=nm-run]: no run exists for fm/<id> after attaching (rc=<n>)` | the attach started nothing, and nothing will clear on its own |

A `--respond` attach appends one further line at SEND time, `resolved [key=nm-run]: responded to the gate ...`, because sending the response is what answers the park.
Without it, a park opened by a previous hold would stay open behind a later `paused` or `resolved` return and firstmate would keep chasing a gate that had already been answered.

A record whose own `branch:` is not `fm/<task-id>` is discarded rather than reported.
`no-mistakes axi status` answers with another branch's run under `other_branch_run:` (`internal/cli/axi_query.go` lines 84-88 pick the key and add the leading `current_branch:` only in that case), and that body carries the same `id:`, `status:` and `outcome:` fields, so a positional read would pin another task's failure on this one.

### What it refuses, all before anything is launched

- A working directory that is not a git worktree on `fm/<task-id>`. Both `axi run` and `axi status` answer for the worktree they are called in, so a wrong cwd drives another task's run.
- `--yes` anywhere in the respond arguments.
- A fix round below the substance floor, delegated to `bin/fm-fix-instructions-policy.mjs --fix-instructions-only`. The PreToolUse gate never sees a fix round again, so this is where that floor now lives.
- A second attach while one is already alive for the task, pointing at the live log. The marker holds the follower's pid, and a pid that is no longer alive is treated as a dead hold's leftover rather than as a reason to strand the task.
- A composed intent over the push-option size limit, with the measured size.

### Reporting is unconditional, with one stated gap

The status line is the only thing that tells firstmate the run moved, because the worker's turn ended the moment the wrapper returned.
So the hold reports on every exit path once it is running: a classified return, an unreadable run, and being killed all append a line, and the same handler clears the liveness marker so no path can leave one behind.
`tests/fm-nm-attach.test.sh` proves the killed case by signalling the hold's own process group mid-attach, which works because bash runs an `EXIT` trap on `SIGTERM`.

The one gap, stated rather than papered over: a hold killed in the few milliseconds between the wrapper returning and the re-executed follower installing its handler cannot report.
It has not started the attach either, so there is nothing about the run to report, and the only trace is a marker naming a dead pid, which the next attach clears rather than being blocked by.

### The intent size cap

The pinned intent travels as a base64 git push option, whose limit is 65520 bytes encoded - 49140 raw, since base64 emits 4 characters per 3-byte group.
`INTENT_B64_LIMIT` in `bin/fm-nm-attach.sh` is the named owner, and `tests/fm-nm-attach.test.sh` sizes its boundary cases by reading that constant at run time rather than from a number that happens to fit today.

The cap is also what keeps the intent safe on argv.
The detached half is this same script re-executed and the intent is handed to it as one argument, so it is subject to the kernel's per-argument limit - `MAX_ARG_STRLEN`, 131072 bytes on Linux, measured 2026-09-15 as 131071 execing and 131072 not.
An argv payload dies at its threshold rather than degrading, which is why firstmate normally keeps growing payloads off argv entirely; it is safe here only because the cap is enforced before the exec and leaves 2.7x of headroom.
`tests/fm-nm-attach.test.sh` measures the real limit at run time and asserts the cap stays under it, so a later cap raise cannot silently cross it.

The refusal names the measured size and points at the brief's own `## Gate decisions` subsection, which is the only part of the intent that grows without bound.
**Compaction is deliberately not implemented here**; task `fm-nm-intent-size-cap-i6` owns it.
This is the refusal only.

## The outcome class: a decision that changes nothing owes no run

A re-run costs 25-35 minutes, and the rule above charged that to every answer, including answers that leave the branch byte-for-byte as it was.
Measured on `plated-rating-viewers-ship-w6` on 2026-09-08: six runs, six decisions, and three of the last four runs ended in a decision that changed nothing (a count that stayed as it was, a question already decided at an earlier key and re-raised, a wording in `ISSUES.md` accepted as written).
Each of those runs was owed to this rule, not to the tool.

So `record` takes an explicit outcome class.
`--outcome change`, the default, keeps the original behavior in full.
`--outcome no-change` declares that the answer keeps the branch exactly as it is, and `rerun-check` then lists that decision without counting it as a decision owed a re-run.
A block written before the flag existed carries no outcome line and is read as `change`, so an old record keeps its old meaning.

Both the record block and the brief's `## Gate decisions` line carry the annotation, as `- <finding> [<key>] (no-change): <requires>`, so a reviewer reading the PR can see why no re-run followed that round.
Only the no-change case is annotated: the line is emitted verbatim into `--intent`, where a `(change)` on every other line would be noise the pipeline's own review has to read past.

The flag cannot launder a code change.
`record` takes `--fixed "<finding ids>"`, the findings that round submitted a fix for, and REFUSES `--outcome no-change` for a finding named there, writing nothing at all in that case.

**The exposure this leaves open.** `--fixed` is supplied by the worker, so a worker that omits a finding from its own fixed set can still record a changed finding as no-change.
Nothing here reads the diff.
The guard is against the ordinary mistake, not against a worker that misreports what it did, and the fresh run every `change` decision still forces is unchanged.

## Info-severity findings, and the fix-round cap

The generated ship brief hands the worker two further rules, both aimed at the same cost:

- An ask-user finding of severity `info` or `suggestion` is the worker's own to answer, choosing the option that keeps the recorded decisions and the brief's `# Task` section true, recorded under its own name with the outcome class above, and listed in the PR description under `Decisions taken by the worker (info severity)`.
  An info finding that re-raises a decision already in `## Gate decisions` is answered by citing that key and recorded `--outcome no-change`.
  Security, credential, and data-loss findings escalate at any severity, and `warning` and `error` findings still reach firstmate.
- After the first review of a run, at most two further fix rounds on the same set of findings.
  A finding returning a third time, or left open after that second round, is filed as a follow-up backlog item blocked by the current task, named in the PR description under `Deferred to follow-up`, and the run proceeds.

A capped round is a normal outcome, and the brief forbids reporting it as `failed:` or `blocked:`.
Nothing on firstmate's side had to change for that: `bin/fm-nm-stall.sh`'s predicate is whether the run's STEP is still advancing, and a capped round advances it, while `bin/fm-classify-lib.sh` reads the status verbs the worker writes and a capped round writes none.

`record` stores the no-mistakes run id current at the moment of recording, read from `no-mistakes axi status`, and `rerun-check` compares it against the current one.
Run ids are unique per run, so "the run I was recorded during is still the most recent run" is exactly "no fresh run has scored this branch since".
No timestamp is parsed and no run ordering is inferred.

**The exposure this leaves open.** `rerun-check` is a command the worker runs, so a worker that never runs it, or that reports done without it, is not stopped by anything here.
Nothing else in the pipeline re-reviews what the later auto-fix steps changed either, so that gap is the same gap it always was, merely narrower.
The residual case inside the check is a decision recorded while `no-mistakes axi status` was unreadable: it is stored as `run: unknown`, and `rerun-check` names it as unconfirmed on stderr rather than refusing, because refusing would leave the worker with nothing that could clear it.

`verify`, `reverted` and `check` remain, downgraded to optional diagnostics that nothing blocks on.
They are the earlier design, when the guard was a hand audit of the final diff before reporting a PR ready; that audit is now the fresh run's review, and the generated brief no longer asks for it.
They are still useful when investigating a suspect run by hand, so they were kept rather than deleted.
`verify` and `reverted` rewrite only the state and evidence lines of the named decision, never its `requires` text, so what a decision demanded cannot be edited after the fact to match what shipped.

## Validation

`tests/fm-fix-instructions-check.test.sh` owns the seatbelt's acceptance matrix: 41 cases across all five harness entry forms, the exact substance-floor boundary read from the named constant, transport fail-open behavior, the strict-superset prefilter, and per-harness wiring driven through the REAL `bin/fm-spawn.sh`.
Its raw-attach cases cover leading environment assignments, `&&` chains, pipes, subshells, a nested `bash -c`, a path-qualified program name, and `--flag=value`, plus the dynamic-value forms the substance floor deliberately let through.
It also pins the floor's whole 15-case acceptance set in `--fix-instructions-only` mode, so relocating that enforcement into the wrapper did not shrink it, and it pins that a raw-attach refusal names the wrapper command by absolute path while a floor refusal names what the instructions have to contain.
The Claude, Codex and Grok hooks are proven end to end by executing the exact command string `fm-spawn` recorded, against both a refusal case and a pass case.
The OpenCode plugin and Pi extension are proven end to end by importing the generated file in Node and invoking the generated blocking callback, again both ways.
The Grok global hook is additionally proven inert for a workspace with no token pointer and for one whose pointer names an unregistered token.

`tests/fm-nm-gate-context.test.sh` owns the intent owner, the decision record lifecycle, the intent amendment and its re-run gate, and the generated brief's contract.

`tests/fm-nm-attach.test.sh` owns the attach owner, in 31 cases: that it returns within 2 seconds while a hold that sleeps 30 is provably still running, that the hold carries `--wait 3h` and the pinned intent and never `--yes`, each classified return shape, every refusal including the size cap sized from its own named constant, and the denial through the real Claude and Grok stdin transports.
Its `no-mistakes axi status` fixtures and their provenance are recorded in `tests/fixtures/nm-attach/PROVENANCE.md`, which states per fixture which bytes were captured from the installed tool and which two shapes could not be - a gate state is not durable, and no `awaiting_approval` row exists anywhere in this machine's daemon database across all 73 recorded runs, so those two are composed from strings the tool's own test suite asserts it emits at `v1.70.1`, named line by line.

No harness binary was spawned by either suite.
**Live per-harness hook-loading was not confirmed for Codex, OpenCode, Pi, or Grok.**
The wiring shapes follow the already-verified per-harness mechanics recorded in `docs/arm-pretool-check.md` and the `harness-adapters` skill, and the generated adapter code is exercised directly by the suites above, but the step of "the harness actually loads this file" is inherited from those prior validations rather than re-observed here.

**The raw-attach denial WAS confirmed live on Claude, the harness this fleet runs.**
Verified 2026-09-15 in a real `fm-spawn`-generated crewmate worktree whose `.claude/settings.local.json` PreToolUse hook was pointed at this branch's `bin/fm-fix-instructions-check.sh --claude`.
`no-mistakes axi run --intent "..." --wait 8m` and `no-mistakes axi respond --action approve` were each blocked before executing, with the `nm-raw-attach` reason and the wrapper command returned to the model; `no-mistakes axi status` in the same session ran normally and printed its record.
In that same armed session, `bin/fm-nm-attach.sh <task-id>` was run with a stub `no-mistakes` first on `PATH`, and its recorded invocations were `axi run --intent <the real brief text>` followed by `axi status` - so the wrapper's own raw subprocess is not denied, which confirms the hook sees only the model's command string and never a command a script spawns.
No wiring changed for any harness, so Codex, Grok, OpenCode and Pi keep exactly the mechanics recorded above - only the policy module behind the shared transport changed, and each of those four is still exercised through that transport by the suite, not live.

Checked 2026-08-08 in the build environment: `claude` 2.1.226 and `opencode` 1.18.15 are installed; `codex`, `pi`, and `grok` are absent.
OpenCode being present does not upgrade its row above, and the attempt is recorded so nobody repeats it expecting a cheap win.
`opencode serve --print-logs --log-level DEBUG` was booted inside a real `fm-spawn`-generated crewmate worktree holding the generated `.opencode/plugins/fm-turn-end.js`, and its startup log named only the three global config files, never a plugin.
OpenCode loads project plugins lazily per session rather than at server start, so proving the load needs a real model turn that executes a tool call, which spends provider credits and returns a nondeterministic result.
That was left undone deliberately rather than reported as verified.

Run:

```sh
bash -n bin/fm-fix-instructions-check.sh
shellcheck bin/fm-fix-instructions-check.sh bin/fm-nm-attach.sh bin/fm-nm-intent.sh bin/fm-nm-decision.sh
node --check bin/fm-fix-instructions-policy.mjs
tests/fm-fix-instructions-check.test.sh
tests/fm-nm-attach.test.sh
tests/fm-nm-gate-context.test.sh
bin/fm-lint.sh
bin/fm-test.sh
```
