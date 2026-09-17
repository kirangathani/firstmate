# Implementation plan: vehicle-adaptive command execution

Working document for task `fm-force-backgrounder`.
The durable parts fold into `docs/background-bookkeeping.md` and `AGENTS.md` before the PR; this file is deleted in the final commit.

## 1. The design in one sentence

Every firstmate command that needs no model in the loop decides for itself how to run, from the vehicle it detects it was issued in, so firstmate cannot get it wrong and pays nothing when it does.

Two behaviours, chosen at runtime:

- **Detach** - fork the real work to a `setsid` child, return in about 6 ms, deliver the verdict on the next wake through the results channel.
- **Lurk** - do the work in place, then `exec` the dormant arm and become one of the pool's waiting ears.

## 2. The buckets

A command's bucket decides which library call it makes, not what firstmate has to remember.

**Detach always (3).**
These can exceed the thirty-minute Monitor cap or flood the event channel, so their work must never run inside a harness task.

| command | reason |
| --- | --- |
| `fm-pr-merge.sh` | 391 s max measured; 20-35 min under a full `fm-assert-tests-kept.sh` run |
| `fm-merge-green.sh` | loops candidates each calling the merge; one member measured at 1149 s; emits a multi-line report |
| `fm-fleet-sync.sh` | one line per project, and a Monitor emitting too many events is auto-stopped |

**Detach unless issued as a Monitor (14).**
Short, bounded, modest output.
Issued as a Monitor they lurk and yield an ear; issued any other way they detach and cost 6 ms.

`fm-send.sh`, `fm-ack.sh`, `fm-spawn.sh`, `fm-pr-check.sh`, `fm-teardown.sh`, `fm-decision-hold.sh` (hold, resolve), `fm-review-attest.sh` (attest), `fm-ci-waiver.sh` (waive), `fm-write.sh`, `fm-merge-local.sh`, `fm-stale-base.sh --ack`, `fm-nm-stall.sh --ack`, `fm-monitor.sh --exempt`, `fm-nm-questions.sh answer`.

**Unchanged foreground.**
Every read whose output is firstmate's next action, plus four the brief listed as Set A that do not belong there: `fm-update.sh` (its output lines are the next actions, and it rewrites the scripts underneath itself), `fm-promote.sh` (prints the `next:` steer firstmate uses), `fm-handoff.sh arm` and `consume` (a marker written and a marker deleted), `fm-config-push.sh` (rare, multi-line report).

Scripts with both a read form and a write form detach only the write form: `fm-stale-base.sh`, `fm-nm-stall.sh`, `fm-nm-questions.sh`, `fm-monitor.sh`, `fm-decision-hold.sh`, `fm-ack.sh --list`.
Parse the subcommand before calling the library.

## 3. New file: `bin/fm-detach-lib.sh`

Sourced after `SCRIPT_DIR` is resolved, because the library re-executes `$0` and needs to know where it is.

### Two entry points

- `fm_detach "$@"` - detach unless already the child. For the detach-always bucket.
- `fm_detach_or_lurk "$@"` - detach unless already the child **or** the vehicle is a Monitor. For the lurk bucket.

Both return to the caller when the body should run here; otherwise they fork and exit 0.

### `FM_INLINE`

One variable meaning "run the body here and now, neither detach nor lurk".
The detached child exports it, so any firstmate script it calls runs inline and returns a true exit code - `fm-merge-green.sh` reads `fm-pr-merge.sh`'s exit, `fm-ci-waiver.sh` reads `fm-send.sh`'s, and both would break otherwise.
The four `bin/` scripts that steer on firstmate's behalf set it, and `tests/lib.sh` sets it as the suite baseline.
It replaces `FM_ARM_POOL_NO_REFILL`, which #114 introduces for exactly this purpose on the lurk half.

### Vehicle detection

`fm_vehicle` returns `monitor` when `readlink /proc/$$/fd/1` matches `^socket:`, and `other` otherwise.

Measured 2026-09-17, Claude Code on Linux, identical probe through each vehicle twice:

| vehicle | inherited stdin | inherited stdout |
| --- | --- | --- |
| foreground Bash | `socket:[...]` | file under `<session>/tasks/` |
| Monitor | `/dev/null` | `socket:[...]` |
| `run_in_background` | `/dev/null` | file under `<session>/tasks/` |

Environment and process ancestry are byte-identical across all three, so stdout is the only discriminator.
`[ -S /dev/fd/1 ]` does not work and was tested; only the `/proc` readlink does.

Every failure mode resolves to `other`, which means detach: safe on macOS where `/proc` is absent, safe on the four harnesses with no Monitor, and safe if the harness rewires its stdio.
The cost of being wrong is a missing ear, never a hung turn.

### The fork

Same shape as `bin/fm-watch-arm.sh:868`, which has survived 107 reapings of the task that launched it.

```sh
setsid "$0" "$@" >"$LOG" 2>&1 </dev/null &
```

Job control is off in non-interactive bash, so `setsid` does not fork and the child is the direct child.
The parent prints nothing and exits 0.

Log at `state/.detach/<script>-<epoch>-<pid>.log`, pruned to the most recent 200.

### Stdin

Spilled to a file and handed to the child only when the script sets `FM_DETACH_STDIN=1` before calling.
`bin/fm-write.sh` is the only one that does.
Unconditional spilling would leave the parent of a no-stdin script blocked reading a foreground stdin that is a socket, not `/dev/null`.

### Result delivery

An `EXIT` trap in the child writes one line through `bin/fm-wake-pending.sh --result`, which `bin/fm-write.sh:277` already demonstrates.

- success - the script's own verdict line, no log path
- refusal or failure - `<script> <id>: <verdict> (log: <path>)`, plus the filtered verdict lines inlined so no read call is needed
- crash - the trap fires on any exit the shell can see and records `died exit=<rc>` with the log path

The inline dump uses a selector, never a raw tail.
For the merge, reuse the filter already validated in `docs/background-bookkeeping.md` section 4.
Bound it the way `bin/fm-watch.sh` bounds crewmate text with `SIGNAL_APPENDED_MAX_LINES`, and keep the log path as the fallback for anything the selector drops.

`SIGKILL` cannot be trapped; that residual case is stated in the docs rather than papered over.

## 4. Changes to `bin/fm-arm-pool-lib.sh`

Rename `fm_arm_pool_refill_or_exit` to `fm_arm_pool_lurk_or_exit`, and `--refill` to `--lurk` across `bin/fm-send.sh`, `bin/fm-ack.sh`, `bin/fm-write.sh`, the protocol doc, and the tests.
`--refill` stays a no-op alias for one release, as #114 already arranges.

Add the vehicle check: lurk only when `fm_vehicle` says `monitor` and the pool has room; otherwise return so the caller exits normally.
In a detached child the vehicle is never `monitor`, so the child exits rather than becoming an ear, which is correct - an ear needs a harness task to deliver through.

## 5. Chains that move inside their owning script

- **`fm-teardown.sh`** runs the backlog completion it currently only prints at lines 461-482, where it already composes the exact `tasks-axi done` command including `--pr` and `--report`. Add a `--note` passthrough. The "worker and worktree are gone, so it did not finish" branch at line 458 is a judgement for firstmate and goes to the results channel instead.
- **`fm-pr-merge.sh`** chains `fm-fleet-sync.sh` only. It never chains teardown: teardown's refusal test is about unlanded work, not unfinished intent, so a worker whose first PR just merged has a clean tree and would be destroyed mid-series.
- **`fm-spawn.sh`** - the brief asks for a backlog add, but unlike teardown this script composes no such command today, so the exact form is unspecified. Flagged rather than invented.

## 6. Documentation

- **`AGENTS.md`** gains one short rule in section 8 giving the two behaviours and pointing at `docs/background-bookkeeping.md` for the per-command table. One place only: the commands are named in about twenty lines of that file, and annotating each would be the duplication the one-owner rule exists to prevent. The file currently contains zero occurrences of "Monitor", which is why #114's audit found every steer going out in the plain foreground shape - the instruction was not in front of firstmate at the moment it steered.
- **`docs/background-bookkeeping.md`** - section 3's three routes become four with self-detach ranked first; section 4's shapes are rewritten and "the one merge that must not use a Monitor" is removed with the cap that motivated it; section 2.6 notes that the transcript is on disk, so the premise for rejecting the handoff was wrong; section 5's CI-waiver reasoning stands unchanged, since it is a lurk command.
- **`docs/supervision-protocols/claude.md`** - items 9 and 15 rewritten for the buckets. Item 14 restates `AGENTS.md` section 8 on idle progress and collapses to a cross-reference.
- **A dated evidence record** for the vehicle table, written the way `docs/*-backend.md` records empirical facts: date, version, exact commands, exact output, and the limits.

## 7. Tests

New `tests/fm-detach.test.sh`, mode 100755, assertion names constant strings with no interpolation, dependencies derived from the real tree at run time rather than hand-listed.

1. The parent returns in well under a second.
2. The child completes and records its line in the results channel.
3. A crashing child still records a line.
4. The child survives its parent's shell exiting, proved the way `tests/fm-write.test.sh` proves its writers die.
5. `FM_INLINE` skips both behaviours, so existing suites keep their shape.
6. Vehicle detection returns `monitor` for a socket on stdout and `other` for a file, driven by a fixture rather than a live Monitor.
7. A lurk-bucket command in a non-Monitor vehicle detaches instead of lurking - the wedge case.
8. `fm-write.sh` receives its piped instruction through the spill.

Size the log-pruning test from the limit read at run time, not from a number that happens to work.

## 8. Sequencing

**Phase 1, now.**
`bin/fm-detach-lib.sh`, the three detach-always scripts, their tests, and the documentation for that half.
Nothing here touches `fm-send.sh` or `fm-ack.sh`, so it cannot collide with #114 or #115.

**Phase 2, after #114 and #115 merge.**
The `--lurk` rename, the vehicle check in the pool library, the fourteen lurk-bucket scripts, the `AGENTS.md` rule, and protocol items 9, 14, and 15.

Run `bin/fm-lint.sh` once, before pushing, never after each edit.

## 9. Known limits, stated rather than hidden

- **The empty-fleet gap.** A results line is delivered by an arm on its way out or at session start. The last teardown of the last task has nothing left to wake anything, so its verdict waits for the next session. Unresolved; the alternative is a wake, which the captain has ruled against.
- **`SIGKILL` is untrappable.** A hard-killed child dies mute, and silence reads as success. Mitigated only by the child no longer being in the class of process anything routinely kills.
- **Detection is Linux-only.** macOS has no `/proc`, so a lurk command there always detaches and never yields an ear.
- **No serialisation lock.** Ordering concurrent merges is firstmate's; a real conflict errors and is visible in the results line. Lint contention is owned by #116.
- **`fm-pr-check.sh` is misnamed** next to `fm-pr-green.sh` - one arms a poll, the other reads a PR. 31 files and 56 mentions; filed as its own task rather than mixed into this diff.
