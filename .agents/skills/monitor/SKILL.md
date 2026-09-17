---
name: monitor
description: Force a complete per-task monitoring sweep of every direct report this home supervises, and report what each one is owed. Use when the captain invokes /monitor, says "monitor everything", "go over every task", "heartbeat", "check on everything", "are you on top of the fleet", or asks whether anything has been left unanswered. Also use to grant or clear the captain's own standing declaration that a task is his to drive. It reads fleet state and acts on what it finds; it never tears down a task, merges a PR, or dispatches new work as a side effect of sweeping.
user-invocable: true
metadata:
  internal: true
---

# monitor

Force firstmate over every task it is supervising, deterministically, and report per task.

The captain's standing position is that a rule an agent is asked to follow is not enforced.
So this skill is not the enforcement.
`bin/fm-turnend-guard.sh` is: it blocks a turn that would end with a reported state unanswered, whether or not anyone runs this skill, and `bin/fm-ack-lib.sh` owns the predicate both use.
This skill is the on-demand render of that same predicate, for when the captain wants the whole accounting now rather than an alarm about the worst item.

## What it does

1. **Run the sweep.**
   `bin/fm-monitor.sh` is the single deterministic source; its header and `--help` own the classes, the exemption record, and the exit codes.
   Do not hand-assemble this from `state/<id>.status` tails: an append-only status log's last line goes stale, which is exactly what the sweep's current-state confirm exists to correct.
   Do not substitute `bin/fm-ack.sh --list`, which shows only the alarming class and so cannot answer "did you go over everything".

   The sweep also renders a stalled-validation count on every run, zero included, because a validation whose step has stopped advancing reports nothing at all and so falls in no reported-state class; `bin/fm-nm-stall.sh` owns that predicate and its acknowledgement.

   `NEEDS A RECHECK` is its own verdict, counted separately from `NEEDS ACTION` in `MONITOR COUNTS`, and it means something different: a task sitting in a declared external wait that has stood for hours with nobody re-verifying the premise the worker stated.

2. **Act on what it found, before reporting.**
   A `NEEDS ACTION` line is not a status to relay, it is work firstmate already owed.
   Do what each one owes now - trigger the validation, record and arm the PR, relay the decision or failure to the captain, steer the blocker - and only then record it with `bin/fm-ack.sh <id> "<what you did>"`.
   A `NEEDS A RECHECK` line owes no action at all - it owes a look: read that task's pane, re-verify what it says it is waiting on, and record what you verified with `bin/fm-ack.sh <id> "<what you verified>"`, which buys one more window before the next recheck is owed.
   Treat the worker's stated reason as a claim rather than a fact, because it is exactly the thing nobody has checked; a wrong premise is the failure this verdict exists to catch.
   A stalled validation is answered the same way and recorded with `bin/fm-nm-stall.sh --ack <id>`: read the named step, decide or relay, and never restart or abort the run on the finding alone.
   Relaying a decision or a failure to the captain IS the action for that task; record it once relayed.
   Never record an action that was not taken: the record silences that state until the worker's next report, so a false one reintroduces exactly the blind spot this exists to close.

3. **Report per task, in the captain's terms.**
   Give one line per task covering the whole fleet, not just the problems, because the point of a forced sweep is evidence that everything was looked at.
   Translate before sending, per `AGENTS.md` section 9 - the sweep's class tokens and confirm verdicts are internal labels and must not reach the captain verbatim.
   Lead with anything that needs the captain: a decision, a review-ready PR with its full `https://...` URL, a failure, a needed credential.
   Then the rest, compactly.
   If nothing needed action, say that plainly and give the count of tasks checked; do not pad it.

4. **Re-arm supervision.**
   A sweep is not a substitute for the live supervision cycle.
   If any work is under way, confirm the cycle is running per the emitted session-start operating block before the turn ends.

## Captain-driven tasks

A task the captain is driving is not firstmate's to watch: it produces no wake, owes no alarm, and is never peeked at, steered, acked, or relayed out of.
A worker with a human sitting in its window is already captain-driven with no command at all, and stops being so shortly after that human leaves; `docs/captain-driven.md` owns the mechanics.
The sweep reports every such task with its reason, so say which tasks are currently the captain's whenever you report the sweep.

The captain, and only the captain, can also declare it explicitly, for a stretch longer than a sitting:

```
bin/fm-monitor.sh --exempt <task-id> --reason "<why>"
bin/fm-monitor.sh --unexempt <task-id>
bin/fm-monitor.sh --list-exempt
```

Firstmate may run these on the captain's explicit instruction and must not grant one on its own initiative.
The reason is required and is signed along with the task id, so it cannot be edited afterwards.

Say plainly what the record is worth when the captain asks for one.
It stops firstmate alarming on that task and stops the watcher waking for it; it does not hide it.
The task still appears on every sweep and is announced at every session start until the record is cleared or the task is finished.
It survives restarts and does not expire on its own, which is exactly what distinguishes it from a sitting.

If the sweep reports a record that does not verify, treat the task as not captain-driven - it still alarms and is still watched - and tell the captain, because it means either a record that was not signed by this home or a signing key that has changed.

## Boundaries

Read the fleet and act on what it owes.
Do not tear down a task, merge a PR, dispatch queued work, or change a backlog item's state as a side effect of sweeping - those need the captain's word or the normal task lifecycle.
A sweep that finds queued work now dispatchable is reported as such; dispatching it is the ordinary intake decision, made on its own terms.
