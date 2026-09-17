# When the captain is driving a worker

A worker the captain is driving himself is not firstmate's to watch.
This document owns the mechanics; `bin/fm-ack-lib.sh`'s `fm_captain_driven` is the predicate every surface asks, and `bin/fm-captain-driven-lib.sh` owns the automatic half of it.

## What happened

On 2026-09-17 the captain opened the tmux window of a running task and started driving that worker by hand.
The watcher kept watching it.
The pane went quiet while the captain read it, so `bin/fm-watch.sh` fired a stale wake; firstmate peeked at the pane, saw the worker asking a question, and surfaced that question to the captain as a decision dialog.
The captain was already answering it in the window.

His words were: "I am driving that agent, why are you watching it? When I am driving it, the watcher needs to stop watching it."
Earlier the same day he had asked for a second task to be "labelled captain only" so firstmate would leave it alone entirely.

The signed monitoring exemption (`bin/fm-monitor.sh --exempt`) was the nearest thing that existed, and it was applied to both tasks.
It was not enough on two counts.
It silenced only the alarms, so `bin/fm-watch.sh` - which never read the record at all - went on spending a waiting arm and a firstmate turn on every status append and every quiet pane.
And it had to be typed every time he sat down at a window.

## What is true now

A task is captain-driven when either source says so, and the signed record wins when both do because it carries the captain's own stated reason.

1. **Signed.** `state/<id>.monitor-exempt` verifies against this home's master key.
   `bin/fm-monitor.sh` owns minting it and the record format; `bin/fm-ack-lib.sh` owns verifying it.
2. **Attached.** A tmux client is viewing the window recorded in `state/<id>.meta` and its last keystroke was inside `FM_CAPTAIN_DRIVEN_GRACE`.
   `bin/fm-captain-driven-lib.sh` owns that reading.

While a task is captain-driven, all of the following go quiet for it, and each reads the one predicate rather than either source:

- `bin/fm-watch.sh` does not wake firstmate for it: no wake on its status appends, none on its quiet pane, no wedge escalation, and no mention in the heartbeat backstop.
  None of its wakes reach the durable queue, so none of them spends a waiting arm.
- The unactioned-direct-report predicate (`bin/fm-ack-lib.sh`) classifies it captain-driven instead of owed, which is what takes it out of the turn-end guard and out of `bin/fm-monitor.sh`'s needs-action count.
- The stale-base sweep (`bin/fm-stale-base.sh`) leaves it out of its findings.
- The stalled-validation sweep (`bin/fm-nm-stall.sh`) leaves it out of its findings, while still observing it, so its record is current the moment supervision resumes.

Firstmate never peeks at it, steers it, acks it, or relays a dialog out of it.
Direct captain intervention in a worker's window is already authoritative under AGENTS.md rule 4; this makes it exclusive for as long as it lasts.

It still appears, labelled, in `bin/fm-monitor.sh`'s sweep, in the fleet view's `captain_driving` field, and in the session-start digest's `MONITOR_EXEMPT:` lines.
A worker firstmate is not watching has to be a blind spot the captain can see, not one he has to remember.

## What keeps running

The task's PR merge poll keeps running.
That poll is about the PR, not the pane: a PR the captain merges himself still leaves the clone to refresh and still leaves sibling branches measuring their checks against a base that has moved.
Silencing it would trade a wake firstmate cannot act on for a landing nobody notices.

The review-question sweep (`bin/fm-nm-questions.sh`) also keeps running, for the same shape of reason: those questions come from the validation pipeline's own reviewer rather than from the pane, they are answered through `axi answer` rather than by steering the worker, and they route to the captain either way.

## The tmux reading, and the evidence for it

Measured 2026-09-17 on tmux 3.4, on an isolated `tmux -L fmtest` server so the live fleet was never touched.

`#{window_active_clients}` is the number of attached clients viewing a window.
On the live fleet it read 1 for the one window the captain was on and 0 for the other ten.

`#{client_activity}` is the client's own last input time, and all three directions that matter came out right.

| Event | `client_activity` advances |
| --- | --- |
| The viewed window produced output every 2s for 31s | No - it held at 1789646058 across seven samples |
| `tmux send-keys`, which is how firstmate steers a worker | No |
| A real keystroke from the attached client | Yes, within 2s (1789646103 to 1789646115) |

So a chatty worker cannot make its own window look driven, and firstmate's own traffic never counts as a human.
Firstmate never runs `tmux attach`; every primitive it uses is a one-shot command, so it owns no client and every client tmux lists is a human terminal.

The exact reading is `tmux list-clients -F '#{client_activity}\t#{client_session}:#{window_name}\t#{client_session}:#{window_index}\t#{window_id}'`, matched against the task's recorded `window=`.
Three spellings are compared because a recorded target may be any of them; `bin/fm-spawn.sh` writes the name form, which `tmux_window_pinned=1` guarantees cannot drift.
The read is memoized for the current second, so a twenty-task sweep forks tmux once rather than twenty times.

This is a tmux-only reading, and deliberately so: no other runtime backend exposes "which window is a human looking at".
A task on another backend is simply never attached-driven, and the signed record still works there, so nothing is silently unsupervised.

## Resumption

The signed record ends with `bin/fm-monitor.sh --unexempt <id>`.

The attached reading ends on its own.
Switching window or detaching ends it immediately, because the client is then viewing something else; `FM_CAPTAIN_DRIVEN_GRACE` (default 600 seconds, the documented constant in `bin/fm-captain-driven-lib.sh`) only covers a window left selected while the captain is away from the keyboard.

Resumption never replays what it suppressed.
The watcher advances each skipped signal's suppression marker as it skips it, and clears the skipped window's pending wedge bookkeeping on every poll, so there is no backlog of wakes waiting to arrive at once.
The first ordinary poll after the captain leaves simply reads current state.
If he left a worker genuinely needing something, the heartbeat backstop finds it there and surfaces it once, which is the intended safety net rather than a leak.
