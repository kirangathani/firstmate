# Handoff: stalled no-mistakes step alarm (branch `fm/fm-nm-step-stall-t8`)

Written 2026-08-13 by the worker that built this, at the end of its context.
Delete this file before the PR merges; it is a handoff artifact, not shipped documentation.

The feature is complete, committed, and lint-clean.
One question is open, and it is the only thing standing between this branch and a PR.

## What was built, and where

A frozen no-mistakes pipeline step now alarms, instead of reading as healthy work indefinitely.

- `bin/fm-nm-stall.sh` is new and owns the whole contract: the predicate, the durable record format, the threshold, the silent cases, the acknowledgement, and the wording.
  Read its header first; everything else only gives its verdict a consequence.
- `bin/fm-crew-state.sh` gained an opt-in `--progress` flag that prints one extra line carrying a fingerprint of the run's own step table, built from the `axi status` record that reader had already fetched.
  The fingerprint is an allowlist over the TOON header (`step`, `status`, `findings`), so `duration_ms` and the sibling `active_steps` table's `active_for`/`last_activity` cannot reach it.
  Without the flag the output is byte-identical to before.
- `bin/fm-watch.sh` observes on its own cadence (`FM_NM_STALL_INTERVAL`, 600s) through `--surface` and wakes once per freeze.
- `bin/fm-guard.sh` warns, `bin/fm-turnend-guard.sh` blocks, and `bin/fm-monitor.sh` renders, all three from the durable records alone with no no-mistakes call.
- `bin/fm-teardown.sh` removes `state/<id>.nm-progress` and `state/<id>.nm-stall-ack` with the rest of a task's state.
- Contracts: `AGENTS.md` sections 2 and 8, `docs/turnend-guard.md` (fourth block reason, and the threshold measurement), `docs/architecture.md`, `docs/configuration.md`, `docs/scripts.md`, and `.agents/skills/monitor/SKILL.md`.
- Tests: `tests/fm-nm-stall.test.sh` (15 cases), plus cases added to `tests/fm-turnend-guard.test.sh` and `tests/fm-unactioned-guard.test.sh`.
- Fixtures: `tests/fixtures/nm-stall/` holds two verbatim `no-mistakes axi status --run 01KZRQJJ2JX66ECFBTNPKPSKGH` captures of the incident run itself, one frozen and one advanced.

## The ten commits

```
b5fa69c test(watch-triage): bound the watcher reap so a survived SIGTERM cannot hang the suite
942502d fix(monitor): render stalled validations, so the sweep cannot call a blocked fleet clean
0e66ffc docs(nm-stall): correct the cost-control note to describe the rotation
384af74 fix(nm-stall): rotate the per-sweep read budget so no task is excluded
e8f6a78 style(crew-state): keep the emit() comment attached to emit()
8e41c34 docs(nm-stall): give the threshold measurement one owner
aa43536 test(nm-stall): record the exact command and CLI version the fixtures came from
e397496 docs(nm-stall): say why the acknowledgement is not the unanswered-report record
456f76b docs(supervision): state the stalled-validation contract with one owner
f85fab9 feat(supervision): alarm when a no-mistakes step stops advancing
```

Three of those were defects found while building, not planned work, and each carries a test:

- `384af74` - ordering the sweep's per-cycle read budget by least-recently-observed starves exactly the task the alarm is for, because every task NOT running a validation has no record and there are usually more of those than the budget.
  The rotation fixes it, and the new test fails against the previous ordering with exactly that starvation message.
- `942502d` - `bin/fm-monitor.sh`'s header states the sweep can never report a task clean that the turn-end guard would block on.
  A frozen validation reports nothing at all, so every reported-state class would have called that task quiet while the turn end blocked on it.
- `b5fa69c` - see the open question below.

## THE OPEN QUESTION - resolve this before the PR

`tests/fm-watch-triage.test.sh` fails intermittently.
Whether this branch caused it is UNRESOLVED.

### Measured facts

- Full suite run 1, tree without the `fm-monitor.sh` change: 108/108 passed.
- Full suite run 2, mixed tree: 108/108 passed, but it HUNG mid-run and only finished because the stuck watcher process was killed by hand.
  The hang was `reap()` in that file doing `kill` then an unbounded `wait` on a watcher that had survived SIGTERM.
  The stderr line immediately before the hang was `fm-watch.sh: trap: line 2: unexpected EOF while looking for matching )`.
  A bash trap body is re-parsed when the signal arrives, so a signal landing while the shell is mid-parse of a command substitution can make the `exit 1` body fail to parse, and the exit never runs.
  `docs/flow-tui.md` line 265 already records the same bash behaviour biting a trap body directly.
  `b5fa69c` fixed the harness: TERM, a bounded window, then force, matching what `tests/fm-watcher-lock.test.sh` already does for the same reason.
- Full suite run 3, the shipping tree: 107/108.
  `tests/fm-watch-triage.test.sh` failed on `dead-agent declared pause flooded 2 stale wakes across six unchanged polls`, in `test_exited_declared_pause_is_bounded_but_live_gate_surfaces`.
- Standalone runs of that file after `b5fa69c`: three consecutive passes, 36 assertions each, 117s / 94s / 88s.
- A/B arm for this branch, partial: one failure in its first runs, on a DIFFERENT assertion - `AFK paused changed pane did not hand off a stale wake`, in `test_afk_paused_changed_pane_hands_off_plain_stale`.
- Signal-race probe over a simplified watcher with an empty state dir, 40 iterations each: this branch 0 survivals and 0 trap-parse errors, `main` 0 and 0.
  That probe did not reproduce the trap-parse race at all, so it says nothing about the branch's effect on it.
- `bin/fm-lint.sh`: clean.

### What was NOT measured

The `main` arm of the A/B never ran.
The experiment was stopped mid-flight, so there is no baseline failure rate for `tests/fm-watch-triage.test.sh` on `main`.
That is the single missing number.

### The two live hypotheses

1. Pre-existing flakiness in that file, unrelated to this branch.
   It kills and relaunches a real watcher dozens of times at `FM_POLL=1` and asserts exact wake counts and short exit budgets, so it is sensitive to per-cycle latency and to being killed mid-critical-section.
   Note `handle_paused_stale` enqueues the wake BEFORE writing its `.paused-resurfaced-<key>` throttle marker, deliberately, per the repo's enqueue-before-suppress rule.
   A watcher killed in that window leaves a queued wake with no throttle marker, and the next round surfaces again - which is exactly the two-wake shape observed, and it is by design rather than a bug.
2. This branch widened the window.
   `bin/fm-watch.sh`'s loop gained one `age_of` call per cycle for the stall cadence, which is roughly three extra forks on a loop that already does fifteen to twenty-five.
   Under load that is a plausible way to tip a four-second exit budget, and equally plausibly irrelevant.

### How to settle it

Run `tests/fm-watch-triage.test.sh` six or more times against this branch, then the same number with `bin/fm-watch.sh` and that test file restored to `main`, and compare failure counts.

Do NOT do this by swapping files inside the worktree, which is how the previous attempt left the tree dirty mid-run.
Copy both trees somewhere outside the repo, or use a second checkout, so a measurement can never dirty the branch.

If `main` fails at a similar rate, this is pre-existing: say so with the numbers, leave the assertions alone, and raise it as its own item rather than editing someone else's test to make this PR green.
If this branch fails materially more, cut the per-cycle cost in `bin/fm-watch.sh` until it does not.

## What remains before the PR

1. Settle the question above.
2. One clean full `bin/fm-test.sh` run on the final tree.
3. Delete this file.
4. Push `fm/fm-nm-step-stall-t8` and open the PR with `gh-axi`.
   This project ships direct-PR; do not run no-mistakes.
   The PR description should carry the threshold justification, which lives in full in `docs/turnend-guard.md`'s fourth-block-reason section: the longest a single step legitimately occupied across the 61 most recent real runs was 96 minutes (`test`), then 73 minutes (`review`), and the shipped threshold is 1.9x that at three hours.

## Gotchas

- `bin/fm-arm-pretool-check.sh` denies any shell command that names `fm-watch.sh` inside a wrapper, substitution, or compound command.
  Invoke it plainly, or work through a script file whose own text the hook never sees.
- `pgrep -f "bin/fm-test.sh"` matches the polling command itself, so an `until ! pgrep ...` waiter never exits.
  Wait on a pid with `kill -0`, or on a marker in the log.
- A full `bin/fm-test.sh` run takes roughly 30 to 35 minutes on this box.
  `bin/fm-lint.sh` caches, so it is fast after the first run.
- When killing a stuck test watcher, kill it BY PID.
  There is a real firstmate watcher running from `/home/kiran/projects/gits/firstmate`, and `pkill -f bin/fm-watch.sh` would take it out along with sibling homes.
- `bin/fm-nm-stall.sh --threshold` prints the effective threshold, so tests and readers never copy the number.
  `FM_NM_STALL_NOW` freezes its clock for deterministic span assertions.
- Related defect found but deliberately NOT fixed here, worth its own task: `bin/fm-watch-arm.sh`'s `handle_arm_signal` does the same unbounded `kill -TERM` then `wait` on a live watcher that `b5fa69c` just fixed in the test harness.
  Same hang shape, in production rather than in a test.
- A BotOverflow draft covering the trap-re-parse quirk was filed (draft id `549f9da5-2098-48bc-bd3f-418d88b97672`).
