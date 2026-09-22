# Bookkeeping that should not be foreground work

Firstmate spends model turns on commands and documents that need no model in the loop.
This document owns which ones, what each costs, how they run instead, and where the change does not pay.

The captain's framing, 2026-09-16 evening, in his words:

> Theoretically the only thing that differs you from a background agent that you quickly set up is your context and your learnings.
> As long as you pipe those into the background agent and set it up, that takes 2 seconds and then you background it and you're free to do something else.
> It makes you far more streamlined.
> As soon as the background agent finishes writing, which takes maybe 10 seconds, then the background agent dies so we're not using up loads of RAM because these background agents are all dying repeatedly.

The test applied throughout: a command needs the foreground only if the model must read its result before its very next action.
Everything else is bookkeeping.

## 1. What it costs today, measured

### 1.1 Commands

[F] Source: `data/fm-foreground-audit-f9/report.md` and its `commands.csv`, from 7401 Bash and Monitor calls firstmate made between 2026-09-04 and 2026-09-17.
Durations are what the model waited, which includes the command text streaming and 0.72 s of hooks, not pure script time.

| command | calls (13d) | fg median | p90 | max | verdict |
|---|---|---|---|---|---|
| `fm-pr-merge.sh` | 135 | 16.7 s | 73 s | 391 s | detaches itself |
| `fm-merge-green.sh` | 50 | 28.0 s | 101 s | 279 s | detaches itself |
| `fm-teardown.sh` | 103 | 8.7 s | 20 s | 78 s | detaches itself |
| `fm-spawn.sh` | 140 | 5.7 s | 15 s | 66 s | stays foreground; see section 4 |
| `fm-pr-check.sh` | 106 | 6.0 s | 9 s | 14 s | detaches itself |
| `fm-review-attest.sh` | 53 | 4.7 s | 8 s | 22 s | background |
| `fm-decision-hold.sh` | 58 | 3.8 s | 11 s | 41 s | background |
| `fm-fleet-sync.sh` | 25 | 12.1 s | 24 s | 24 s | detaches itself |
| `fm-ci-waiver.sh` | 14 | 4.7 s | 13 s | 13 s | `waive` detaches itself |
| `sleep N; <read>` | 72 | 12.1 s | 20 s | 50 s | eliminate |
| foreground CI-polling loops | 4 | 158 s | 536 s | 563 s | eliminate |
| `fm-peek.sh` | 215 | 4.7 s | 20 s | 81 s | stays foreground |
| `fm-crew-state.sh` | 64 | 3.1 s | 7 s | 12 s | stays foreground |
| `fm-brief.sh` | 112 | 3.2 s | 10 s | 25 s | stays foreground |
| `fm-session-start.sh` | 33 | 13.6 s | 25 s | 25 s | stays foreground |

[F] The largest single foreground cost in that sample, the per-wake drain (1605 calls, 1.4 s median), was already removed by the arm draining on its way out.

### 1.2 Documents

[F] Measured 2026-09-17 from firstmate's own transcripts, over every document written into a firstmate home's `data/` between 2026-09-07 and 2026-09-16.
The compose window for one document is the gap between the model being handed the turn and the message carrying the document's text; a document written in parts sums its parts.

| document | n | total | p50 | p90 | max | p50 size |
|---|---|---|---|---|---|---|
| handoff document | 6 | 344 s | 53 s | 87 s | 87 s | 8.7 KB |
| other `data/` document | 16 | 591 s | 34 s | 67 s | 94 s | 7.3 KB |
| crewmate brief | 4 | 123 s | 33 s | 58 s | 58 s | 6.5 KB |
| pause / resume record | 3 | 46 s | 13 s | 26 s | 26 s | 3.6 KB |
| learnings | 1 | 7 s | 7 s | 7 s | 7 s | 0.9 KB |

[F] That is 1111 s of firstmate's own compose time in ten days, on 30 documents, excluding the 5 scout reports in the same sample, which crewmates write.
[O] Only the transcripts still on disk were measured, so the ten-day window is what survives, not the whole history.

## 2. The short-lived writer

`bin/fm-write.sh` hands one document to a writer that has firstmate's context piped into it, and dies the moment the document exists.
Its header owns the flags and the mechanics; `bin/fm-worktree-facts.sh` owns the per-task git facts it pipes in.

What it does with the captain's premise: the context and the learnings are collected and handed over mechanically, so setting one up is one tool call rather than a composition.

```sh
bin/fm-handoff.sh path                      # or any other data/ path
bin/fm-write.sh --out data/pause-2026-09-17-network-resume.md <<'EOF'
Write the resume record for the pause I am about to take for a network outage.
Workers were told to WIP-commit, start no network operation, leave any pipeline
run alone, write their handover, append one paused: line, and wait.
Cover: per-task state at pause, what is already safe, what to do on resume and in
what order, the captain decisions outstanding, and what was filed but not dispatched.
EOF
```

Run it as a Monitor, as section 3 says.

### 2.1 What it costs, measured 2026-09-17 on this fleet

[F] The model's own cost is one tool call.
[F] Assembling the bundle takes about 5 s, dominated by the fleet snapshot, all of it after the model has let go.
[F] The writer takes 26 to 65 s for a 6 to 10 KB document.
[F] A resume record equivalent to `data/pause-2026-09-16-network-resume.md` came back in 37 s end to end, at 8335 bytes.

So the captain's stated budget is met on setup and missed on writing: about 2 s to set up, and 30 to 40 s rather than 10 s to write.
The gain is not the clock.
Firstmate writing that same document inline measured 13 s at p50 and 53 s for a handoff, and every one of those seconds was the model's, during which the fleet went unsupervised and the captain went unanswered.
The writer's seconds are nobody's.

### 2.2 Why the writer has no tools

[F] `--tools ""` removes every built-in tool, so the writer can only use what is in the bundle.
That is the note-taking discipline enforced by construction: a writer that cannot read a file cannot introduce a fact nobody checked.

[F] Measured failure this guards, 2026-09-17: given no tools and no warning that it had none, a writer announced a plan, attempted one tool call, and returned 395 bytes instead of a document.
Two things fix it, and both are in the code: the bundle states plainly that there are no tools, and the output is checked against a floor before anything is written, so a run that fails this way reports `write-failed:` and leaves the target untouched.

### 2.3 Why the whole of `captain.md` and `learnings.md` go in

[F] Measured 2026-09-17: the same trivial request took 6.4 s with no context, 4.0 s with 8.6 KB, 5.6 s with 80 KB and 5.9 s with 300 KB.
Prefill is free at this scale, so there is no reason to select down from a 72 KB preferences file and a 222 KB learnings file, and every reason not to: the selection would be a judgement the writer then could not revisit.

[F] The prompt must go in on STDIN, not in argv.
A 300 KB argv died with a too-long argument list, and passing the prompt as an argument while stdin is a pipe produced `Warning: no stdin data received` and no output.

### 2.4 Why it starts lean

[F] Measured 2026-09-17: `--strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources=` cuts the writer's start-up from 6 to 10 s down to 1.4 to 3.4 s.
Loading this machine's MCP servers and settings files was most of a headless start.

### 2.5 The writers die

[F] Verified 2026-09-17 by recording every writer pid and checking liveness after the command returned: no writer process outlives `fm-write.sh`, including a writer that had to be stopped on its timeout and that writer's own children.
[F] `timeout` runs its command in a new process group and signals the group, which is what makes the descendants die too.
`tests/fm-write.test.sh` keeps that asserted rather than assumed.

### 2.6 Where a writer pays, and where it was checked and does not

It pays where a document is mostly collected facts plus a short narrative, and where firstmate relays only that the document exists rather than its prose.
The resume and pause record is the clearest case and the captain's own example: 13 s at p50 and 26 s at worst of firstmate's own time in the measurement above, now none of it, and the document came back better because the facts were piped in rather than remembered.
Any similar per-task or per-project summary is the same shape.

Two candidates were examined and rejected, each for its own reason, so that nobody re-derives them:

- **The handoff document.**
  Its content test is "would the next instance make a worse decision without this line?", and the answer lives in this session's own conversation, which no collector can reach.
  Piping enough context for a writer to answer it means writing the expensive half by hand first, so the 53 s measured at p50 is mostly irreducible.
  `/handoff` keeps writing inline.
- **The bearings report.**
  Its chat digest has to be internally consistent with the report file, so delegating the file means reading it back to write the digest, which costs what it saved.
  `/bearings` keeps composing both.

[O] The crewmate brief (33 s at p50, 112 calls in 13 days) looks like a fit on the numbers, because the next action after a finished brief is the spawn rather than an edit.
It is left alone deliberately: a brief is a safety contract whose generated sections must survive verbatim, and handing that to a writer needs a design of its own rather than a flag.

### 2.7 On the quality standard

[F] Measured 2026-09-17 on identical bundles: the smaller model filled a per-task table it had no data for with "unknown" cells and some inference, while `claude-sonnet-5` stated plainly which facts the bundle did not contain and named the commands that would establish them.
For a document the next session will trust, that difference is the whole point, which is why `fm-write.sh` defaults to the larger model even though it is off the critical path either way.

## 3. How a background result reaches the model

### 3.0 The vehicle: a command that detaches itself

The routes below are how a result gets back once a command is off the critical path.
What puts it there is the command itself.

`bin/fm-detach-lib.sh` re-launches the script with the same arguments through `setsid(1)`, and the foreground copy exits in about 6 ms having done nothing but fork.
[F] Measured 2026-09-17 on this machine: 16 to 27 ms for the parent, against a 2 to 3 s inline run of the same fixture.
The caller sees an ordinary tool call that finished quickly, so there is no completion notification and nothing to re-read, which is the difference from every route below.

This exists because instructing firstmate did not work.
[F] Every one of the 135 merges in section 1.1 was issued in the foreground after `docs/supervision-protocols/claude.md` already asked for a Monitor, and #114 records the same for steering: the protocol asked for the pool-refill form and on 2026-09-17 every steer went out plain, draining the pool to its floor twice.

[F] The detached child is outside everything that kills a harness task.
It is in its own session and process group with its stdio on a file, which is the shape `bin/fm-watch-arm.sh` has used for the watcher since 2026-09-08: through 107 reapings of the arm in 13 days, the watcher it had launched was never killed once.
`tests/fm-detach.test.sh` asserts that directly by killing the parent's process group mid-run and requiring the work to finish anyway.
The thirty-minute Monitor cap does not apply either, because nothing is holding the child to time.

[O] Not covered: `SIGKILL`, which no trap can catch, so a hard-killed child dies without recording anything.
Its verdict would then be missing rather than wrong, and the command is no longer in the class of process anything routinely hard-kills.

Three routes, in order of preference.

1. **A Monitor event.**
   [F] Each stdout line of a Monitor arrives as a notification with no read call.
   Verified overnight 2026-09-16 into 2026-09-17: a merge Monitor delivered its kept-tests summary and then `merged: ... status: ok` as events, and the model's next action followed with no call spent reading anything.
   Stderr is not an event, so a Monitor command must redirect with `2>&1`.
   Lines within 200 ms batch into one notification, and a Monitor producing too many events is auto-stopped, which is why the shapes below filter.

2. **The results channel.**
   A command records one line with `bin/fm-wake-pending.sh --result`, and the arm prints it with the next wake and clears it.
   Use it as the copy that survives a Monitor expiry, not as the only route.

3. **A poll wake.**
   A merged PR wakes firstmate through its own armed poll whoever merged it, which is the safety net under every merge shape.

[F] A plain `run_in_background` Bash task is the weakest route: its completion notification carries the exit code and nothing of stdout, so the model has to spend a call reading the output file.
[F] It is also the only one the harness's low-memory reaper takes: 108 kills in 13 days, one of them a merge 10 s after launch, and zero Monitors killed in the same window.
Use `run_in_background` only where the exit code is the whole verdict, and then either avoid the pipe or set `-o pipefail`, because a piped command reports the filter's exit code, not the command's.

## 4. The shapes

Each runs as one Monitor with `timeout_ms` at the 1800000 maximum and a description naming the subject, since the description appears in every event.

**Merge, and the other two that detach themselves.** There is no shape to get right any more.

```sh
bin/fm-pr-merge.sh <id> <pr-url>
```

Call it plainly.
It returns in milliseconds, and its gates, its refusals and the poll it arms are all unchanged, running in the detached child.
The same is true of `bin/fm-merge-green.sh` and `bin/fm-fleet-sync.sh`.
Never issue one through a Monitor or a background task: the work is handed off either way, and the only difference is a completion notice for something already finished.

The verdict arrives on the next wake through the results channel.
A success carries the command's own `merged:` line and no log path, because there is nothing to chase.
A failure carries the exit code, the log path, and the selected verdict lines themselves - the same filter this section used to ask firstmate to type - so no read call is spent on it.

A successful merge also refreshes the project's clone before it reports, because the turn that used to do that no longer exists.
It does NOT tear the task down: `bin/fm-teardown.sh`'s refusal test is about unlanded work rather than unfinished intent, so a worker whose first PR has just merged has a clean tree and would be torn down mid-series.

Drop the pre-merge `bin/fm-pr-green.sh` call when the next action is the merge: the merge reads the same check rollup through the same owner and refuses on anything not green, so that call is a duplicate read.
Keep `fm-pr-green.sh` when its verdict is itself the answer to a question.

**The Monitor cap no longer reaches a merge.**
[F] A Monitor is killed at thirty minutes, and `bin/fm-assert-tests-kept.sh` puts a full run at 20 to 35 minutes; one merge under a testing waiver took 19 minutes.
That used to force a `run_in_background` merge for a task with `ci_skip=on` or a `data/no-pr-ci/<project>` marker, which was the one shape exposed to the reaper.
A detached merge is held to no deadline by anyone, so that exception is gone and both cases take the ordinary plain call.

**Teardown, `fm-pr-check.sh`, and `fm-ci-waiver.sh waive`** detach themselves the same way, so they are called plainly too.

```sh
bin/fm-teardown.sh <id>
```

Teardown no longer chains its backlog write, because there is no turn left to chain inside.
Its completion line, its `Backlog:` reminder naming the exact `tasks-axi done` to run, and every `REFUSED:` line with its `REFUSED REMEDY:` all arrive on the next wake, and the backlog write follows from there.
For a scout, its decision-hold completion still has to land before the teardown, since teardown enforces that gate.
`bin/fm-pr-check.sh --from-watcher` is exempt: that caller is `bin/fm-watch.sh`, which is not the model.
`bin/fm-ci-waiver.sh --print-only` and `sign` are exempt for the reason a dry run is - the printed line is what the caller asked for.

**Spawn stays foreground.**
It is 5.7 s at median and 66 s at worst, and all of that is upfront: the worktree lease, the isolation assertion that refuses to let a task start in the primary checkout, and the `state/<id>.meta` write that every supervision read keys off.
Detaching it would return before any of those exist, so the peek that handles a trust dialog within about 20 s of dispatch would find a shell still running `treehouse get` rather than a worker, and the fleet view, the turn-end guard and the drift report would all see a dispatch with no durable record behind it.
There is no slow tail to split off, because the slow part comes before the assertion rather than after it.

**`fm-stale-base.sh --ack` stays foreground too**, on measurement rather than on contract.
Its sweep is 0.5 to 0.65 s of real work against a live fleet (measured 2026-09-22, three runs), so almost all of its 2.9 s median is the per-call overhead a detached vehicle pays as well; 22 calls in 13 days put the whole saving at about 13 s.

**The rest of the bookkeeping set**, each 3 to 7 s and roughly 300 calls in the sample: `fm-review-attest.sh attest`, `fm-nm-stall.sh --ack`, `fm-nm-questions.sh answer`, `fm-monitor.sh --exempt`, `fm-handoff.sh arm` and `consume`, `fm-decision-hold.sh hold` and `resolve`, and backlog writes.

**Eliminate rather than background**: `sleep N` followed by a read, and any CI-polling loop.
The watcher wakes on every status append and turn end, and the PR poll wakes on merged and, where the standing merge rule is configured, on green.
72 sleeps cost 842 s of blocked model time in 13 days and told firstmate nothing the watcher was not already going to say.

**What stays foreground**: every read whose output is the next action - `fm-peek.sh`, `fm-crew-state.sh`, the session-start digest, backlog and fleet-view reads, `fm-pr-green.sh` when it is the answer - and `fm-brief.sh`, whose scaffold the next action edits.

## 5. The CI waiver round trip

The captain asked why a worker comes back to firstmate for a signature to skip CI instead of being given it at dispatch.

[F] The round trip is forced and must not be removed.
`bin/fm-ci-waiver.sh`'s header owns why: the signature covers the head commit, which does not exist at dispatch, and `bin/fm-ci-waiver-verify.sh` accepts a line solely on the signature matching the current head, never checking that the task named in it has anything to do with the pull request carrying it.
A signature bound to anything that does exist at dispatch would therefore verify in any other pull request in that repository it were pasted into, and the line is published in a PR body.

**It does not belong to the short-lived-writer mechanism.**
There is no document, no prose, and no context worth piping: `waive` reads the sha and the repository out of the worker's own request line and signs them.
A writer would be pure overhead on a command that composes nothing.

**Whether the watcher should do it without waking firstmate at all is a genuine question, and the answer today is no.**
The reasoning, stated plainly because it is security-shaped rather than latency-shaped:

- [F] File access is not the obstacle.
  The watcher already runs as the same user that owns `config/ci-waiver-secret`, so it can already read that file; automating the waive grants no new access.
- [F] The captain's authorisation is already recorded before the worker asks.
  `sign` refuses unless the task's own `state/<id>.meta` carries both `ci_skip=on` and a `ci_skip_auth` token that this home's secret reproduces, and that token is minted only by `bin/fm-spawn.sh` at dispatch.
  Firstmate contributes no judgement at waive time, which is exactly the captain's point.
- [F] But `sign` does not check that the requested sha is that task's head, or that the requested repository is that task's project.
  Both are read from the worker's own request line.
  So a worker holding a legitimate CI skip can ask for a signature over a commit and a repository of its choosing.
- That gap exists today, and firstmate does not check either, so automating would not create it.
  What automating removes is the last party who sees each request at all.
  Trading away the only observer of an unchecked pair, to save 14 calls at 4.7 s over 13 days, is a bad trade.

**The precondition, and the order to do it in.**
Bind the request to the task before signing it: require that the sha is reachable in that task's own recorded worktree and that the repository is that task's own project remote.
A worker could then only ever obtain a signature for its own branch's head in its own project, which is precisely what the captain authorised at dispatch, and an unattended signer would be issuing nothing a supervised firstmate would have refused.
That is an ordinary security task, not a decision, and it is worth filing.
Until it lands, run `bin/fm-ci-waiver.sh waive <id>` as a Monitor like the rest of the bookkeeping set: firstmate still sees the request and still decides to issue, and only the waiting comes off its path.

## 6. What this does not change

- No gate, refusal, or approval authority moves.
  A background merge runs the identical gates and refuses identically.
- The continuity gate applies to background and Monitor calls exactly as to foreground ones, because it reads the command text before anything launches.
- The turn-end guard knows nothing about a running background task, which is why every background command's result must reach the model by event, results line, or poll.
  Nothing at turn end will ask about it.
- `bin/fm-session-start.sh` stays foreground.
  [O] Its fleet sync could be issued separately so the digest returns in about 2 s instead of 14 s, but the digest's drift and stale-base lines depend on the sync having run, so that is a design decision for the owner of that script and is not taken here.

## Maintaining this file

This file owns which of firstmate's own commands and documents run off the model's critical path, and what that was measured to cost.
Exact flags and mechanics belong in each script's header and `--help`, not here.
The always-loaded rule and the wait shape belong in `docs/supervision-protocols/claude.md`, which points here for the table.
Replace a measurement rather than appending a second one beside it, and say when and on what it was measured.
