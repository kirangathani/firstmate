# The fleet pipeline view

A captain-facing instrument that renders every live worker as one row: a full horizontal no-mistakes pipeline for a ship task, and a compact identity-and-state row for a worker that runs no pipeline.
It is not part of the supervision loop: the captain runs it as a plain command, and firstmate never opens it.

`bin/fm-nm-flow.sh` remains the single-task detail view, unchanged; the fleet view now has a key that drills into it rather than leaving the captain to know its name.

The view is split across two programs so that neither can drift into the other's job.

- `bin/fm-flow-snapshot.sh` owns data.
  It performs every outside read and emits one JSON document.
  This document is the single owner of that wire format.
- `bin/fm-flow-tui.mjs` owns pixels and input.
  It reads the JSON on stdin and shells out to nothing.

That seam is what makes golden-frame tests possible: a renderer that cannot read the world can be fed exact recorded bytes and asserted against an exact frame.

`bin/fm-flow.sh` is the captain-facing entry point and the only invocation that is live and interactive.
It runs the collector, feeds the result in as the first frame, and hands the viewer that same command back so the live view can refresh itself.

## Two channels, one of which cannot be stdin

The snapshot arrives on stdin, so stdin is a pipe.
A pipe is not a keyboard, and `process.stdin.isTTY` is false for every invocation that has data in it.
The first version of the viewer armed its whole key handler behind exactly that test, so no keystroke ever reached it: arrow keys fell through to the shell and printed their escape sequences at the captain's prompt.
There was no invocation of that code which was both fed and interactive.

The two requirements are not in conflict once they stop sharing a file descriptor.
Keys are read from the controlling terminal directly, `fs.openSync("/dev/tty", "r")` wrapped in a `tty.ReadStream`, which is a different descriptor from stdin and is unaffected by what stdin is carrying.
The data seam above is untouched.

`/dev/tty` cannot always be opened - a cron run, a CI job, a session whose output is redirected.
That is a legitimate way to use the program, not an error, so `--watch` in that situation draws one frame, says on stderr why it is not watching, and exits 0.
The alternative, two timers spinning forever with nobody there to press `q`, is the worse failure.

### Where a watch loop's fresh data comes from

stdin ends the moment the first document has been read, so the viewer has no second document to read from it.
A fix that only addressed keystrokes would leave `--watch` animating a border over a frame frozen at the moment it started, which is precisely the class of lie the data-age counter exists to prevent.

The renderer therefore has to re-run the collector - but it will not guess how.
The collector's arguments change what it collects (`--no-ci`, `--task`, and `FM_HOME` from the environment), so a viewer that re-ran a hardcoded `fm-flow-snapshot.sh --json` could silently start reporting a different home or a wider fleet than the frame the captain opened.

So the command is handed in whole, and only ever by the operator:

- `--refresh-cmd <command>` is opt-in with no default.
  Without it, `--watch` is honestly static and the header says `static snapshot` beside the climbing age.
- `bin/fm-flow.sh` builds the collector argv exactly once, uses it for the first frame, and passes the same quoted argv as `--refresh-cmd`, so the two cannot diverge.
  `tests/fm-flow.test.sh` asserts that equality rather than trusting it.
- `--open-cmd <command>` is the same shape for the enter key.

The no-outside-reads property the golden-frame tests rely on is unchanged by this.
`render()` is a pure function of the snapshot plus the frame options; one-shot mode never shells out at all; and a run that shells out does so only to a command it was explicitly given, which no test passes.

## Fitting the terminal

Nine cells at full spacing need 143 columns.
The first version drew all 143 whatever `--cols` said, and that single fact produced both of the defects seen on the captain's first run.

An over-wide line wraps.
A wrapped line occupies two terminal rows while the flicker-free repaint below still addresses it as one, so every absolute cursor address after it points at the wrong row: the right-hand column arrived as fragments, and a row of durations survived under the header with no boxes above it after its own agent had scrolled away.
An over-tall frame does the same thing by scrolling the whole terminal.

`render()` therefore guarantees two invariants, asserted directly in `tests/fm-flow-tui.test.sh` across a sweep of sizes:

- no line is wider than `cols`;
- no frame is taller than `rows`.

Width is recovered without ever cutting a box in half, in this order:

1. tighten the arrow gutter, 5 to 3 to 1 columns, until all nine cells fit - this alone fits the whole pipeline into 130 columns;
2. only if the tightest spacing still overflows, draw a contiguous window of whole cells and name it in the header (`stages 1-6 of 9`), with left/right moving the window.

The header itself drops segments by stated priority rather than being clipped from the right, because the rightmost segment is the data age and that is the one fact the view exists to keep honest.

### Text that does not fit says so

Fitting the frame is not the same as fitting a cell.
On the captain's second run the pre-merge summary read `11/11 - your wo`: seventeen characters of `11/11 - your word` centred into a fifteen-column field, cut at the edge with no ellipsis and no wrap.
A value shortened in silence is unreadable, and worse, indistinguishable from a value that really is that short.

Two changes, in that order of preference.
The phrase itself was shortened to `11/11 your word`, fifteen columns at the two-digit check counts a real fleet produces, so nothing is cut at all.
Under that, `fit()` shortens anything still over-long to the cell width with a one-column ellipsis, and `clip()` does the same for a whole line that is wider than the terminal.
`tests/fm-flow-tui.test.sh` sweeps every variable-length value a cell can hold and requires each to arrive whole or ending in the ellipsis.

### The window moves only when the selector would leave it

Up and down move the selector between agent rows.
The window scrolls only when the selector is already on the top row and goes up, or already on the bottom row and goes down.

That rule needs the window position to persist between frames, and it did not: the viewer passed no `top` at all, so every frame recomputed one from the selection alone against a default of zero.
The effect is that the selector is pinned to the bottom row of the window once the fleet is longer than the window, and scrolling back up drags the window with it row for row.
`scrollWindow()` now owns the rule and the viewer holds its `top` between frames.

## Resolving which pipeline run belongs to which agent

This is the part that is easy to get wrong, and the reasoning matters more than the code.

`no-mistakes axi status` resolves the **active or most recent run for the repository**, not the run belonging to the worktree it is invoked in.
Its own `--help` says so, and it is directly observable.

Evidence, 2026-08-08, no-mistakes v1.37.0:

```
$ cd /home/kiran/.treehouse/firstmate-16c429/12/firstmate   # detached HEAD
$ no-mistakes axi status | grep branch
  branch: fm/lint-cache-shared-w8

$ cd /home/kiran/projects/gits/firstmate                    # on the default branch
$ no-mistakes axi status | grep branch
  branch: fm/lint-cache-shared-w8
```

Two different worktrees, neither of them checked out on `fm/lint-cache-shared-w8`, both answering for it.
At the same moment the daemon held ten runs in `running` state across ten different branches.
So a collector that ran `axi status` once per worktree would draw the identical pipeline on every row of the fleet.

`no-mistakes axi status --run <id>` does scope correctly, from any directory inside the repository, in about 90ms.
The remaining problem is obtaining `<id>`, because no command emits one:

- `no-mistakes runs` lists status, branch, head, and timestamp, but not the run id, and has no flag to add it.
- `no-mistakes axi` has exactly five subcommands (`abort`, `logs`, `respond`, `run`, `status`), none of which enumerate runs.
- `--run` accepts only the ULID.
  A head SHA or a branch name is refused with `run "<value>" not found`.

Release notes for v1.38.0 through v1.45.4 add no run id to `runs` output and no branch filter.
The closest change, v1.40.0 "reattach active AXI runs by submitted head", exposes the submitted head SHA to `axi run` for its own reattachment and not to an outside observer.

### Why the run id is not recorded by the worker

The obvious alternative is to have each crewmate write its run id into `state/<id>.meta` when it starts validation.
That is rejected on the captain's standing test: could the entity being checked have produced the thing being checked?
It could.
A worker that restarted, or that drove no-mistakes twice, would record an id that no longer describes the pipeline the view is drawing, and the view would present it with total confidence.
Self-reported identity is bookkeeping, not a boundary.

### What is read instead

The branch is the key, and it is already a contract rather than a report.
`bin/fm-brief.sh` scaffolds `git checkout -b fm/$ID`, git refuses to check one branch out in two worktrees of a repository, and `bin/fm-crew-state.sh` already keys run attribution on `fm/<id>` for the same reason after the 2026-07-30 recycled-slot incident.

So `bin/fm-flow-snapshot.sh` resolves the run id from the daemon's own database, which the worker cannot forge:

```
/home/kiran/.no-mistakes/state.sqlite
```

That file is local to the host, holds one row per repository in `repos`, and is opened **read-only**.
`repos.working_path` records the primary checkout, so worktrees do not fragment it, and it matches the `project=` value already present in `state/<id>.meta` without any transformation.

The read is deliberately confined to a run index, three columns wide:

```sql
SELECT r.id, r.status, r.updated_at
  FROM runs r JOIN repos p ON p.id = r.repo_id
 WHERE p.working_path = ?1 AND r.branch = ?2
 ORDER BY r.created_at DESC LIMIT 1;
```

Every fact that reaches the screen - step names, statuses, finding counts, durations - is then read through `no-mistakes axi status --run <id>`, the documented CLI.
`step_results` is never read.
That table is a private undocumented schema and the installed binary is eight minor versions behind current, so the risk of it changing is real; the run index is the smallest surface that solves the problem.

### The stale `running` trap

`runs.status` records the last state written, not whether anything is running now.
On 2026-08-08 ten firstmate runs were marked `running` and four had not been touched in five to nine days, the oldest last updated 2026-07-30.
Those are workers that died without finalising their run.

A collector that trusted the column would animate four dead pipelines forever, which is exactly the class of lie the data-age display exists to prevent.

Two mechanisms keep it honest, and neither is a staleness threshold.
A timestamp cutoff was considered and rejected: a legitimately parked run also sits still for hours, so a cutoff misclassifies it.

1. The agent list is filtered to tasks whose recorded endpoint still resolves, so a stood-down worker never appears at all, whatever its abandoned row still claims.
2. For a task that is still present, the snapshot emits the run's `updated_at` age and the task's endpoint liveness as separate fields, and the renderer draws a live-looking state only when the fleet still considers that worker alive.

## An agent is a task with a live worker behind it

The first version took the agent list to be the task list, and a task record outlives its worker.
`state/<id>.meta` is durable on purpose - it is what recovery reads after a restart - and firstmate stands a finished worker down by killing its window, which leaves the record behind.
On the captain's second run that produced fourteen agents against two live tmux windows: seventeen records, sixteen of them naming a window that no longer resolved.

The view was rendering those records faithfully.
That is the point: the view cannot fix firstmate's bookkeeping, and it must not draw a finished worker as a running one while it waits for someone to.
So the collector asks, per task, whether the recorded endpoint still resolves.

The question is not answered here.
`fm_backend_target_exists` in `bin/fm-backend.sh` already owns it for the whole fleet, `bin/fm-fleet-snapshot.sh` already calls it and publishes the answer as `endpoint.exists`, and this collector consumes that field.
A second implementation of "is this worker alive" is exactly the kind of thing that ends with two parts of firstmate disagreeing about the same window.

The split, in one line: liveness filtering belongs to the view, and cleaning up leftover records does not.
The record is durable state that other tools read, this collector is read-only by contract, and deleting a record because a window is gone would destroy what `stuck-crewmate-recovery` inspects.
The leftover records are worth fixing in the teardown path that creates them; that is separate work and does not block the view from telling the truth today.

Nothing is dropped silently.
A task whose endpoint no longer resolves moves to `omitted`, with its kind, its window, and the reason, and the header states the count.
`--include-dead` puts the held-back records back, as ordinary agents carrying `endpoint_alive: false`, which the renderer marks `worker gone`.

## Liveness decides who is drawn; kind decides only what they carry

Liveness is the whole membership test, and it was not always.
The first version took the agent list to be the SHIP tasks with a live worker, and filtered every other live worker - a scout, a secondmate - into an `out_of_scope` list the renderer drew as a single dim count.
On the captain's run that produced a header reading `0 agents` and `1 running no pipeline` with `no agents in flight` beneath it, while a scout was demonstrably alive in a window in front of him.
The view read as broken.
It was not: it was telling the truth about a set it had defined too narrowly, and a view whose body is empty while workers are running is indistinguishable from one that has failed.

The original reasoning behind the filter was sound and is preserved.
Only a ship task has a no-mistakes pipeline, so drawing a scout under the nine stage boxes would be nine permanently empty boxes - an invented journey, which is a worse lie than the omission was.
The mistake was concluding from that that the worker should not be drawn at all.

So kind decides the SHAPE of the row and nothing else:

| | drawn as | carries |
|---|---|---|
| `pipeline: true` | the full nine-cell pipeline block, seven rows | the run, its steps, its GitHub checks, its testing skips |
| `pipeline: false` | a compact block, three rows: head, state, blank | the worker's kind, its window, and one `state` object |

`pipeline` is a field the snapshot STATES rather than a kind string the renderer matches on, so a kind this renderer has never heard of still lands on the right side of the question.
A record with the field missing keeps its boxes: the failure in that direction is a scout drawn too richly, and in the other it is a ship task silently stripped of the pipeline the view exists to show.

Because every live worker is now an agent, `N agents` counts every drawn row without a companion count to reconcile, and `no agents in flight` prints only when nothing at all is live.
The header still names how many of them run no pipeline, so `N agents` cannot be misread as N pipelines.

### The compact row's state is read, never derived

`bin/fm-crew-state.sh` already owns reconciling a crew's current state out of its run step, its pane, and its append-only status log, and that reconciliation is not trivial - `state/<id>.status` is a wake-EVENT log whose last line goes stale the moment a crew resumes.
The collector therefore calls that reader and passes its answer through as `state`, verbatim, split into its stated fields.
A second reading in this view would be a second answer to a question the fleet has one owner for, and the two would eventually disagree about the same worker.

A read that fails or times out reports `state.ok: false`, and the row says `state not read`.
It never falls back to the status log's last line.

### A quiet second mate is healthy, and must not be painted as a fault

`AGENTS.md` section 8 is explicit: a secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than on its pane being busy.
`bin/fm-crew-state.sh` encodes the same rule by skipping the pane busy-check for `kind=secondmate`, so a secondmate with no outstanding status event has no state source at all and reads `unknown` **by construction**.

`unknown` is magenta everywhere else in this view, which is correct where it means nobody could find out and wrong here where it means there is nothing to report.
So a secondmate reading `unknown` renders the word `idle` in dim, and its detail is dropped with it: `no current-state source available` is the reason that read is unknown, and printing it beside `idle` reads as the explanation for an alarm that is not there.
Every other state a secondmate can report - `blocked`, `failed`, `parked` - keeps its own colour, because those come from its status log and are real.

### Blocks are two heights, so the window is solved once

A compact block is three rows and a pipeline block is seven, so how many blocks fit depends on which one is first.
Dividing the available rows by a single constant would answer for a frame that is not being drawn, and that disagreement is not cosmetic: an over-tall frame scrolls the terminal and desynchronises every absolute cursor address in the repaint.

`scrollWindow(heights, avail, top, sel)` therefore returns the window start and the block count together, greedily fitting heights from `top` in the same shape `layout()` already uses for the horizontal cell window.
The captain's scroll rule is unchanged and is the three clauses in that function: pull back to the selector when it is above the window, never strand the window past the point where the whole remainder fits, and advance only while the selector would otherwise fall off the bottom.

## A skip-flagged task is drawn as the journey it actually takes

The captain's own words: a task dispatched with a testing skip "wouldn't actually run through all of those steps", so drawing the full chain leaves him watching boxes that were never going to light.

The authority is `state/<id>.meta`, which `bin/fm-spawn.sh` writes at dispatch and nothing else does - never a status log, never the brief.
It is read through `bin/fm-testing-skip-lib.sh`, the same owner `bin/fm-pr-merge.sh`'s waiver banner reads, and a test in `tests/fm-spawn-testing-skip.test.sh` reads back the meta a real spawn just wrote so the writer and the readers cannot drift.

The two flags are independent and remove different stages.
Reading either as "skip everything before merge" would put the same lie back in a new place:

| Flag | What it removes | How the row draws it |
|---|---|---|
| `local_skip=on` | the whole local pipeline, mechanically: the `no-mistakes` on the worker's PATH is a shim that explains the skip and exits, so no run exists at all | `intent`, `rebase`, `review`, `test`, `docs`, `lint` are `skipped`; `push+PR` is `by hand`, because the brief sends the worker straight to `git push` and `gh-axi`, and the CI cell beside it carries real checks |
| `ci_skip=on` | the PR's expensive lint and test JOBS, by a signature CI itself verifies | no local stage at all; its whole effect lands in the CI cell, where the waived jobs report as skipped checks |
| either, or both | never the pre-merge gate | `bin/fm-pr-merge.sh` runs the base's own test assertions under every flag combination and no skip can disable them, so that cell is never drawn as skipped |

`skipped` has a colour slot of its own rather than sharing dim with `pending`: deliberately-not-run and not-yet-run are different facts and must not be told apart by squinting at the four-letter word underneath.
The row also states in plain words that the skip is captain-authorised, naming which halves, so a short chain never reads as a broken one.

## Enter opens the worker's window, or it says it did not

Enter is agent-scoped.
It opens the selected worker's window whatever cell is highlighted; no cell carries an action of its own, including `GITHUB CI`, and the selected agent's row says what enter does on every frame rather than leaving the captain to discover it by pressing.

Which terminal moves is the whole of `--open`, and the first version got it wrong.
`tmux select-window` changes the target session's current window and does nothing whatever to the terminal the command was typed in.
Run from a terminal that is not a client of that session - which is how the captain ran it - it exits 0 having moved a view nobody was looking at, and the viewer flashed `opened <id>` over a screen where nothing had happened.

`bin/fm-flow.sh --open` therefore picks its action from what this terminal already is, and refuses when there is nothing to move:

| This terminal | Action | Getting back |
|---|---|---|
| already a tmux client (`$TMUX` set) | `switch-client` moves this client to the worker's window | the view is still running in its own window |
| a terminal, not in tmux | `tmux attach-session`, which blocks | detach, prefix then `d` |
| not a terminal at all | refuse | nothing moved |

The refusal matters as much as the actions.
`switch-client` with no client of its own to name moves whatever client is attached to the invoking pane's session, so a script or an agent running inside a tmux pane would yank the captain's own terminal onto some other window - observed on 2026-08-09 while reproducing this defect.

Two mechanics follow from the attach case.
The viewer suspends for the command: alternate screen off, raw mode off, its own terminal handed to the child as stdin and stdout, all timers held, and the screen restored and fully repainted when the command returns.
That terminal is the viewer's own stdout, not a fresh open of `/dev/tty`, because `ttyname()` on a descriptor opened that way answers `/dev/tty` and tmux refuses a client whose terminal is that - `server_client_open`, `can't use /dev/tty`, seen exactly once in the first cut of this.

Finally, the footer reports what the command SAID it did, not what its exit code implies.
`--open` prints its own outcome line - `switched to <window>`, `back from <window>`, or the error - and the viewer flashes that.
A message reporting an action that did not occur is worse than an error, so an exit code alone is never enough to claim one.

## `d` drills into one agent's pipeline

The row states a CI verdict per agent, so the obvious next move from it is that agent's own pipeline.
Enter is not that move - it hands over the worker's terminal, which is a different and equally useful thing - so the drill-in has its own key, and enter's behaviour and its per-terminal sentence are untouched.

`bin/fm-flow.sh --detail <id>` runs `bin/fm-nm-flow.sh <id> --watch`, the read-only detailed view of one task's delivery flow that already existed and that the captain previously had to know by name and type.
It is deliberately that command rather than a second renderer, because a copy would drift from it.
The viewer suspends for it exactly as it does for enter, through the same shared hand-over.

Ctrl-C is the way back, and it is stated on the key line beside the key that goes in.
Two mechanics make it work:

- The viewer does not quit on `SIGINT`, and that follows from raw mode rather than from preference.
  With `ISIG` off, ctrl-c reaches the viewer as the byte `0x03` on its keyboard stream, never as a signal.
  So the only way the process can receive `SIGINT` is while a child owns the terminal, which is the captain closing that child - quitting on it would tear the fleet view down every time they came back.
- `--detail` traps `INT` and reports the return itself, so the footer flashes the outcome rather than an interrupt.
  That trap is a function call, not an inline string: a trap body is re-parsed when the signal arrives, so an apostrophe in it has to survive two rounds of quoting, and the first cut of this flashed `unexpected EOF while looking for matching '` at the captain instead of the outcome (observed 2026-08-09, in a live terminal).

## Wire format

Schema id `fm-flow-snapshot.v2`, emitted by `bin/fm-flow-snapshot.sh --json`.
Exact fields, flags, and environment knobs are owned by that script's header and `--help`; this section owns the shape and the guarantees.

The bump from `v1` is a genuine break in both directions, which is why it is a bump rather than an additive change.
`agents` changed meaning - it was the live SHIP tasks and is now every live worker - so a `v1` consumer reading a `v2` document would draw pipeline boxes for workers that have none.
`out_of_scope` is gone: it existed to name the live workers `agents` excluded, and `agents` now excludes none, so an empty array left in place would be a field whose emptiness meant the opposite of what it used to.
`bin/fm-flow-tui.mjs` refuses any other schema id outright, so the two ship together or neither runs.

```json
{
  "schema": "fm-flow-snapshot.v2",
  "generated": "2026-08-08T16:30:00Z",
  "generated_epoch": 1786000000,
  "fm_home": "/home/kiran/projects/gits/firstmate",
  "agents": [
    {
      "id": "fm-eager-dispatch-e2",
      "branch": "fm/fm-eager-dispatch-e2",
      "project": "/home/kiran/projects/gits/firstmate",
      "worktree": "/home/kiran/.treehouse/firstmate-16c429/1/firstmate",
      "window": "firstmate:fm-fm-eager-dispatch-e2",
      "kind": "ship",
      "mode": "no-mistakes",
      "pipeline": true,
      "state": null,
      "endpoint_alive": true,
      "skips": { "local": false, "ci": false },
      "pr": { "url": "https://github.com/kirangathani/firstmate/pull/25", "number": 25 },
      "collection": { "ok": true, "reason": "", "at": "2026-08-08T16:30:00Z", "epoch": 1786000000 },
      "run": {
        "present": true,
        "id": "01KZETHEHPT5RQFB14A83FMZCK",
        "status": "running",
        "head": "bb73f233",
        "findings": "2 info",
        "db_updated_epoch": 1785999000,
        "db_age_seconds": 1000
      },
      "steps": [
        { "step": "intent", "status": "completed", "findings": 0, "duration_ms": 22 }
      ],
      "active_steps": [
        {
          "step": "ci",
          "status": "running",
          "active_for": "18h32m",
          "last_activity": "37s ago: log: warning: could not check CI",
          "round": "starting"
        }
      ],
      "ci": {
        "collection": { "ok": true, "reason": "" },
        "checks": [
          {
            "workflow": "CI", "name": "Lint shell scripts",
            "started": "2026-08-09T11:49:35Z",
            "status": "COMPLETED", "conclusion": "SUCCESS", "verdict": "passed"
          }
        ],
        "total": 11, "passed": 10, "failed": 0, "pending": 0,
        "skipped": 0, "excused": 1,
        "excused_authority": [
          "firstmate is registered as a direct-PR project, whose PRs are raised without the pipeline by design"
        ]
      }
    },
    {
      "id": "nm-ci-duplication-of-effort",
      "branch": "fm/nm-ci-duplication-of-effort",
      "project": "/home/kiran/projects/gits/firstmate",
      "worktree": "/home/kiran/.treehouse/firstmate-16c429/5/firstmate",
      "window": "firstmate:fm-nm-ci-duplication-of-effort",
      "kind": "scout",
      "mode": "local-only",
      "pipeline": false,
      "state": {
        "ok": true, "value": "working", "source": "pane",
        "detail": "harness busy", "reason": ""
      },
      "endpoint_alive": true,
      "skips": { "local": false, "ci": false },
      "pr": { "url": null, "number": null },
      "collection": { "ok": true, "reason": "this worker runs no pipeline", "at": "2026-08-08T16:30:00Z", "epoch": 1786000000 },
      "run": { "present": false, "id": "", "status": "", "db_updated_epoch": 0, "db_age_seconds": null },
      "steps": [],
      "active_steps": [],
      "ci": { "collection": { "ok": false, "reason": "this worker opens no PR" }, "checks": [], "total": 0 }
    }
  ],
  "omitted": [
    {
      "id": "fm-arm-lock-gate-q4",
      "kind": "ship",
      "window": "firstmate:fm-fm-arm-lock-gate-q4",
      "reason": "recorded window no longer exists"
    }
  ]
}
```

Guarantees the renderer is entitled to rely on:

- `agents` is every task whose recorded endpoint resolved at collection time, whatever its kind, ordered `pipeline: true` first so the wire order is the draw order.
- `pipeline` is always present and always a boolean.
  When it is false the agent carries `state` and empty `steps`, `active_steps` and `ci.checks`; when it is true it carries `state: null` and the pipeline fields below.
- `state` is `bin/fm-crew-state.sh`'s answer, split into its own stated fields and otherwise passed through verbatim.
  `state.ok` false means that read failed or timed out, with `state.reason` saying which; it never falls back to the status log's last line, which is a wake event and not a current state.
- `steps` carries all nine no-mistakes steps in pipeline order whenever `collection.ok` is true AND `pipeline` is true, using the tool's own step names.
  Folding `push` and `pr` into one box is a rendering decision and is not done here.
- Step `status` strings are passed through verbatim, never mapped.
  Mapping a status onto one of the five display states is the renderer's job and is asserted exhaustively in its own tests, so a status this script has never seen still reaches the renderer intact rather than being flattened here.
- `collection.ok` false means the read failed or timed out.
  `steps` is then empty and the renderer must draw the agent as unknown, never as pending and never as its last-known state.
  These are different claims: pending reads as "not started yet", which is a fact this snapshot does not have.
- `ci.collection` is separate from the agent's `collection`, because a GitHub read can fail while the local read succeeds.
- `run.present` false means no pipeline run exists for that branch, which is the ordinary state of a task that has not yet started validating.
- Every entry of `agents` has a recorded endpoint that resolved at collection time, unless `--include-dead` was passed.
  `omitted` names every task held back for that reason, of any kind, and is always present and empty when there is nothing to report.
- `ci.passed`, `ci.failed`, `ci.pending`, `ci.skipped` and `ci.excused` partition `ci.checks`, and their sum is always `ci.total`.
- `skips` reports the captain's testing skips as the task's own `state/<id>.meta` records them, read through `bin/fm-testing-skip-lib.sh`.
  It is a report of what the record says, never an authorization: the flag line alone is reachable by a worker, and the signature beside it is what grants anything.

### Five check classes, because three folded two facts away

The three original buckets folded two different facts into passing and failing, and both folds reached the captain's screen.

`PR must be raised via no-mistakes` greps a PR body for a string only the no-mistakes pipeline writes.
Firstmate is registered `direct-PR`, so its PRs are opened with `gh pr create` and that string is never there: the check cannot pass on a firstmate PR by construction.
`bin/fm-pr-merge.sh` has always excused exactly that check on exactly that authority, and the view knew nothing about it, so it boxed `GITHUB CI` in red with `10/11 FAIL` over PRs the merge gate would have taken - observed on both live agents at once, 2026-08-09, against GitHub reporting 10 passed and 1 failed of 11 on both.
An indicator that is red whatever happens is an indicator nobody reads, which destroys the one thing this view exists to provide.

A job GitHub reports `SKIPPED` verified nothing, and was counted as passing.
Under a captain-authorised CI waiver the expensive lint and test jobs are exactly those jobs, so a waived PR read as more verified than it was.

Both now have a class of their own.
The excusal is resolved through `bin/fm-attestation-lib.sh`, the same owner `bin/fm-pr-merge.sh` reaches its verdict through, and only when that exact named check is actually failing - so an ordinary green PR pays none of its cost, a pending check of that name is never excusable, and a renamed job simply stops being recognised, which costs a merge rather than granting one.
The authority is what decides, never the name: the same red check on a `no-mistakes` project with no signed skip stays a failure.

The split does change what `passed` means: a job GitHub reports `SKIPPED` is no longer inside it.
The total is unchanged, every check still lands in exactly one class, and every class is on screen, so the comparison against `gh pr checks` below still holds at the total and is now made against a row that distinguishes one more thing than a single pass-or-fail split can.
It changes nothing the merge gate DECIDES: `bin/fm-pr-merge.sh` still treats a `SKIPPED` check as passing, and this splits only how it is reported.

The captain's standing rule governs the display, and he has ruled it three times:
every class is named on every render, zeros included; a green or ready flag only when every class is clear; and a class that was never evaluated renders as a dash, never as a `0`.
Five counts do not fit the 15-column timer under a 13-wide cell, so they live on a line of their own with the words spelled out rather than being thinned to fit - the rule allows compact labels or a legend, never a dropped count.

That line is shared with the skip disclosure when a task carries one, and their order was measured rather than chosen.
With the sentence in front the pair ran 124 columns, so a 120-column terminal cut the tally mid-class.
The counts therefore come first: the sentence is the half that can shorten, because the stages above already say `skipped` in their own colour, so it explains what is on screen rather than being the only trace of it.

### The CI counts must agree with `gh pr checks`

That is the comparison the captain makes, and two things had to be fixed for it to hold.

A re-run leaves its earlier attempt in `statusCheckRollup`, so the rollup holds more entries than there are checks.
PR 40 held 13 entries for 11 checks and was reported as `11/13` with two failures where `gh pr checks 40` reports 10 of 11 passing and one failing.
The latest attempt of a workflow-plus-name is the verdict; the rest are superseded and counted nowhere.

The three buckets must also partition the checks.
Reading `conclusion` without first checking `status` counted PR 33's re-running `Repo invariants` as both passed and pending, on the strength of a conclusion its previous attempt had left behind - 8 + 3 + 1 buckets over 11 checks.
A check that has not `COMPLETED` has no verdict yet, whatever field is still sitting on it.

Verified 2026-08-09 against seven real PRs on this repository, comparing the collector's counts with `gh pr checks <n>`:

| PR | `gh pr checks` | collector, before | collector, after |
|---|---|---|---|
| 40 | 11 total, 10 pass, 1 fail | 13 total, 11 pass, 2 fail | 11 total, 10 pass, 1 fail |
| 33 | 11 total, 7 pass, 3 fail, 1 pending | 11 total, 8 pass, 3 fail, 1 pending | 11 total, 7 pass, 3 fail, 1 pending |
| 39, 38, 37, 36, 35 | 11 total, 10 pass, 1 fail | - | 11 total, 10 pass, 1 fail |

## Cost

Measured 2026-08-08 on this host, no-mistakes v1.37.0.

| Read | Cost | Cadence |
|---|---|---|
| `no-mistakes axi status --run <id>` | 91ms | local, fast cadence |
| run-index query against `state.sqlite` | under 10ms | local, fast cadence |
| `gh pr view --json statusCheckRollup` | 500 to 630ms | network, slow cadence |
| `bin/fm-fleet-snapshot.sh --json`, one-task home | 664ms | slow cadence |

The local reads are roughly two orders of magnitude cheaper than the 10s worst-case timeout `bin/fm-nm-flow.sh` budgets for them, so the two-cadence split exists to spare GitHub rather than to spare the daemon.

The cost of `bin/fm-fleet-snapshot.sh` at real fleet size is not yet recorded here.
At the captain's fleet size that command currently fails outright, tracked separately; the 664ms above is a one-task fixture home and is not a fleet-scale figure.

## Verification evidence

Facts in this document were established by running the commands shown, on 2026-08-08, against no-mistakes v1.37.0 (78e4dcb) with the daemon running.
CI check names on this repository are not unique: `CI testing waiver` appears under both the `CI` and `Require no-mistakes` workflows on PR 25, so checks are keyed on workflow plus name.
The no-mistakes version-update banner is written to stderr, so stdout parsing does not need to strip it.

The five rendering and input defects fixed on 2026-08-09 were each reproduced in a real terminal before being changed, and the fixed behaviour reproduced the same way afterwards, driving the actual viewer rather than asserting a helper.
The harness was a sandbox tmux session of live worker windows plus deliberately stale `state/<id>.meta` records, with the viewer run in a second session so its pane could be captured with `tmux capture-pane` and driven with `tmux send-keys`.
Two facts came out of that run rather than out of reading the code, and both are recorded where they bite: tmux refuses a client whose terminal descriptor was opened through `/dev/tty`, and `switch-client` without an explicit client moves whichever client is attached to the invoking pane's session.

### The three honesty defects, 2026-08-09

**The permanent red.**
Measured on PR 51 of this repository, feeding one fleet document to the shipped collector and to the changed one in turn, and rendering each through its own viewer at 150 columns.
`gh pr checks 51` reported 10 pass and 1 fail:

| | cell | class counts |
|---|---|---|
| shipped | `10/11 FAIL` | total 11, passed 10, failed 1 |
| changed | `10/11 your word` | total 11, passed 10, failed 0, excused 1, skipped 0, pending 0 |

The single red check was `PR must be raised via no-mistakes`, and the authority the excusal recorded was `firstmate is registered as a direct-PR project, whose PRs are raised without the pipeline by design`.
The other direction was measured too: the same rollup with that job renamed leaves `failed 1, excused 0`, and the same red check on a `no-mistakes` project with no signed skip stays `failed 1, excused 0`.

**The drill-in.**
Driven end to end in a detached 150x45 tmux session running the real `bin/fm-flow.sh` against the captain's live home, with `tmux send-keys` and `tmux capture-pane`.
`d` on the selected agent handed the terminal to `bin/fm-nm-flow.sh --watch`, which drew that task's full pipeline; ctrl-c returned to the fleet view with the footer flashing `back from the pipeline detail for fm-no-attribution-reach-a2`, and the fleet view survived the interrupt.
Enter still reported honestly in the same session: from a session with no attached client it flashed `open failed: error: this tmux session has no attached terminal to switch` rather than claiming an open.

**The skip rendering.**
Verified in the same kind of session against a home whose `state/<id>.meta` was written by a real `bin/fm-spawn.sh --all-testing-skip` dispatch rather than by hand; only the recorded endpoint was rewritten afterwards, so the flag lines the view reads are the bytes that spawn wrote.
The flagged task drew `skipped` under `intent`, `rebase`, `review`, `test`, `docs` and `lint`, `by hand` under `push+PR`, nothing under `pre-merge`, and the row read `captain-authorised skip: local pipeline, CI test jobs`.
An unflagged task in the same frame was unchanged.
