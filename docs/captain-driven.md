# When a worker is not firstmate's to watch

Two standing declarations take a worker out of supervision: the captain driving it himself, and a verified wait on somebody outside the fleet.
This document owns the mechanics of both.
`bin/fm-ack-lib.sh`'s `fm_supervision_suspended` is the predicate every surface asks, and it folds `fm_captain_driven` (whose automatic half `bin/fm-captain-driven-lib.sh` owns) with `fm_upstream_waiting`.
The two are reported as themselves everywhere a suppression is named, because "the captain has this" and "firstmate verified it is waiting on somebody outside the fleet" are different facts about a worker.

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

- `bin/fm-watch.sh` does not wake firstmate on its status appends, on a wedge escalation, or through the heartbeat backstop.
  Those wakes never reach the durable queue, so none of them spends a waiting arm.
- Its quiet pane is absorbed rather than surfaced, but on the bounded re-surface cadence a declared pause uses, so it wakes firstmate once per `FM_PAUSE_RESURFACE_SECS` and the wake says the task is the captain's.
  That is the captain's own ruling, and it is deliberately not "no wake at all": `bin/fm-watch.sh` gained that cadence for the signed record before this change, and one recheck a window is what keeps a task he has forgotten from rotting invisibly.
  Both routes to the verdict arrive at that same branch and share its wake wording, so a window he is sitting in and a record he signed behave identically; the parenthetical in the wake is what tells them apart.
- The unactioned-direct-report predicate (`bin/fm-ack-lib.sh`) classifies it captain-driven instead of owed, which is what takes it out of the turn-end guard and out of `bin/fm-monitor.sh`'s needs-action count.
- The stale-base sweep (`bin/fm-stale-base.sh`) leaves it out of its findings.
- The stalled-validation sweep (`bin/fm-nm-stall.sh`) leaves it out of its findings, while still observing it, so its record is current the moment supervision resumes.

The signal skip sits ahead of the away-mode branch, so a task the captain declared his stays his while `state/.afk` is set and the daemon owns triage, rather than being escalated the moment he steps away.
The stale branch sits below it, as it did for the signed record before this change, so away mode still hands every stale pane to the daemon.

Firstmate never peeks at it, steers it, acks it, or relays a dialog out of it.
Direct captain intervention in a worker's window is already authoritative under AGENTS.md rule 4; this makes it exclusive for as long as it lasts.

It still appears, labelled, in `bin/fm-monitor.sh`'s sweep, in the fleet view's `captain_driving` field, and in the session-start digest's `MONITOR_EXEMPT:` lines.
A worker firstmate is not watching has to be a blind spot the captain can see, not one he has to remember.

## What keeps running

The task's PR merge poll keeps running, and so does the recording of which PR the task is on.
Both are about the PR, not the pane: a PR the captain merges himself still leaves the clone to refresh and still leaves sibling branches measuring their checks against a base that has moved.
Silencing the poll would trade a wake firstmate cannot act on for a landing nobody notices.
So `bin/fm-watch.sh`'s skip still calls `record_reported_pr` on the way past, because that recorder is otherwise reached only from the surfaced branch: a worker the captain drove to a PR would keep the previous PR on record with its poll armed for a PR nobody is watching, which is the fault that recorder exists to close.

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
The watcher advances each skipped signal's suppression marker as it skips it, and the stale path's own bounded cadence keeps no backlog either, so there is no queue of wakes waiting to arrive at once.
The first ordinary poll after the captain leaves simply reads current state.
If he left a worker genuinely needing something, the heartbeat backstop finds it there and surfaces it once, which is the intended safety net rather than a leak.

# Waiting on action from upstream

The captain, 2026-09-24, in full: "if one of the coding agent pipelines is waiting on upstream (like a PR which needs upstream to merge it, a scouting agent who has submitted an issue and is waiting for it to be marked ready-for-pr before starting the PR build, a coding agent who has just resubmitted code to the upstream and is waiting on a response - SPECIFICALLY NOT INCLUDING a coding agent whose code is running through the CI process - only when the CI has been all passed and the agent is doing nothing but waiting). In this scenario we should have the ability for the FIRSTMATE, not the agent, to label the agent as 'waiting on upstream'. We keep hourly polling of these agents as we would for a captain controlled agent."

And the failure to design against, his words again: "the key error case to avoid is crewmates lazily pretending they are waiting on upstream when they are not, so we need to think about how to mechanically enforce this."

## The crewmate's yes is required and never sufficient

Firstmate asks the worker the captain's own question through `bin/fm-send.sh` - is all your code pushed, your PR active, and has the CI passed everything it needs to, so we are purely waiting on an action from somebody else - and the worker answers by appending one line to its status log:

```
upstream-wait-ready: <plain English action being awaited>
```

That line is one of the gate's conditions.
It is not the gate, and no amount of confidence in it changes anything: every other condition is a machine reading of GitHub and of the worker's own local copy, and a worker that says yes with an uncommitted diff is refused on the diff.

It has to be the LAST line in the log.
Anything appended after it is the worker saying something newer, so the answer no longer describes now and firstmate asks again.

## The gate

`bin/fm-upstream-wait.sh --gate <id>` runs every condition, prints a verdict for each, and writes nothing.
That script's header owns the exact conditions; what belongs here is why the shape is what it is.

For a SHIP task: the crewmate's answer, a PR on record, GitHub reporting that PR open, a clean local copy, nothing the PR's own head does not already contain, and `bin/fm-pr-green.sh` reporting green.

The last one is the captain's exclusion enforced rather than trusted.
A pending check is not green, so a task running through CI cannot be declared waiting, which is exactly "SPECIFICALLY NOT INCLUDING a coding agent whose code is running through the CI process".
It is the merge gate's own green reader rather than a second one, so this can never call green a PR `bin/fm-pr-merge.sh` would refuse, and the one excusable check keeps exactly the one excusal it already has.

There is exactly one alternative to that last condition, and it exists because green could never be reached at all on the PR that exposed it.
A PR opened from a fork by somebody who has not contributed to that repository before runs no workflow until a maintainer presses "Approve and run", so it reports zero checks, and zero checks is never green.
Read against `https://github.com/kunchenguid/firstmate/pull/5562` on 2026-09-25, after its runs had sat on that button all day, GitHub said:

- `gh pr view --json statusCheckRollup` returned `[]`, and both `commits/<sha>/check-runs` (`total_count` 0) and `commits/<sha>/status` (`state` pending, `total_count` 0) agreed there was nothing on the head.
- `gh api repos/kunchenguid/firstmate/actions/runs?head_sha=<sha>` returned three runs, every one of them `"status":"completed","conclusion":"action_required"`.

Note where the signal is: the run reads as completed and the awaiting-approval value is its CONCLUSION, not its status.
So the `approval-gated` condition passes only when the PR reports zero checks AND GitHub itself reports workflow runs for that head with every one of them carrying `action_required` in either field.
It replaces `checks-green` only for a PR reporting zero checks, so no PR that has any check gets a different verdict than before, and a queued or running run, no runs at all, a mixture, or a read this home is not permitted to make each refuse - a worker sitting on an unapproved PR and a worker whose CI has not started yet look identical from the outside, and the captain's rule is that a wait must be re-verifiable, so silence is never read as approval.
The evidence the record carries names which branch granted it, `checks=<n>` or `approval-gated=<n> runs`, so a reader of a standing wait can tell the two apart.

For a SCOUT task: the crewmate's answer, `data/<id>/report.md` existing, and the awaited action naming a GitHub issue or pull request that GitHub reports open.

The scout branch exists because of the captain's own second question, "I don't think we will ever be waiting on the upstream until we have the complete PR right?".
For a ship task that is true, and the `pr-recorded` condition is where it is enforced rather than assumed.
The one legitimate exception is the case he named himself in the same message: a scout that has filed an issue and is waiting for a maintainer to stamp it ready-for-pr.
It has no branch to push and no PR to be green, so the link in its awaited action is what makes the wait checkable at all - a scout waiting on a sentence with no url is waiting on something nobody can re-verify, and that is refused.

A refusal names EVERY condition that failed rather than stopping at the first.
Firstmate asks the worker one question about all of them, so a refusal that named one problem when there were three would send it round that loop three times.

## Granting it, and what a worker cannot do

`bin/fm-monitor.sh --upstream-wait <id> --reason "<what is awaited>"` runs the gate and, only if it passes, signs the record - sitting beside `--exempt`, which is the sibling it is a sibling of.
`--upstream-resume <id>` ends it, and `--list-upstream-wait` shows what is standing.

The record is `state/<id>.upstream-wait`, one line:

```
<epoch>\t<hmac-hex>\t<awaited action>\t<evidence the gate saw>
```

The HMAC is over the task id AND the awaited action, under this home's master key (`config/ci-waiver-secret`), in a signing domain of its own.
So a worker cannot mint one, cannot extend one, and cannot obtain one for a task the gate refused - it holds no key and is told about none.
Editing what a standing wait says it is waiting for invalidates it, because that sentence is signed with the task.
A domain of its own rather than the exemption's is what stops a record minted for one being moved to the other by renaming the file.

The action that gets signed is the crewmate's own words, read back out of the gate, not the `--reason` typed at the grant: what the record says is being awaited has to be the sentence the gate actually verified.

The evidence field is deliberately NOT signed.
It is what the gate saw at the moment it passed - the PR, its head, its check count, or the issue - and the recheck replaces it wholesale, so signing it would invalidate the record every time the gate looked again.

The same residual limit `bin/fm-ci-waiver-lib.sh` states for every other signed record applies unchanged: firstmate runs as the captain's own OS user and can read the key.
What closes that gap is not the signature but non-silence, and here there is one more thing than the exemption has - the gate re-runs.

## What goes quiet, and what does not

While the record stands, `fm_supervision_suspended` is true, and every surface that already asked that question of a captain-driven task asks the same one here: no wake on its status appends, no wake on its quiet pane, no peek, no unactioned alarm, no stale-base finding, no stalled-validation finding.

It still appears, labelled, in `bin/fm-monitor.sh`'s sweep as its own `upstream-wait` class, in the fleet view, and at every session start as an `UPSTREAM_WAIT:` line.
A worker firstmate is not watching has to be a blind spot the captain can see.

A record that does not verify is reported rather than dropped, exactly as an unverifiable exemption is: it is either a forgery or a real wait this home can no longer check, and both are things the captain needs to see.
It buys nothing in the meantime - the task stays supervised.

## The recheck, which is the difference

"We keep hourly polling of these agents as we would for a captain controlled agent."

The pane's own re-surface is that polling and is unchanged: a wait that has stood a window wakes firstmate once, on the same bounded cadence a declared pause and a captain-signed exemption already use.

What this one adds is that the polling has something to check.
A captain-driven task is a claim about a person, and only he can end it.
A wait is a claim about GitHub and a local copy, and it can stop being true while nothing on screen changes at all - the PR gets merged, a maintainer closes it, a check goes red, the worker pushes another commit.
So the same cadence re-runs the gate (`bin/fm-upstream-wait.sh --recheck`), and a record whose gate no longer passes is DROPPED, with the gate's own refusal lines naming what changed.

With the record gone, supervision resumes by itself: the task's real state alarms through the predicate it always did.
That is deliberately the wake, rather than a second wake mechanism that could disagree with the first about whether the task needs anything.

Firstmate is what resumes it deliberately, by `--upstream-resume`.
Everything else is the gate resuming it because the wait ended.

## Two edge cases the captain raised

**"after one failed run we are now in the review phase of the next run and the github CI box is red from the previous run."**

That was a real defect in the view and is fixed independently: the `GITHUB CI` cell now reports a failure as its verdict only once nothing is still running, so a red box always describes the head on screen (`docs/flow-tui.md`, "A failure is the CI cell's verdict only once nothing is still running").
With that landed, the two cannot coincide: the gate refuses on a red check, and the recheck drops a record whose checks go red afterwards.
An `approval-gated` wait ends the same way and through the same recheck: the maintainer presses the button, a check appears on a head that had none, the gate takes the `checks-green` branch instead and refuses, and the record is dropped naming both that the approval hold is over and how many checks now report on the head.
A PR that closes drops it on `pr-open` exactly as any other wait does.

The renderer refuses independently anyway, and the test is named after the invariant.
"Unreachable" is a claim about a process, and the frame is its own claim: a record that survived a window it should not have, a hand-written document, or a recheck that could not reach GitHub all arrive at the renderer looking identical.
In every one of them the failure is the fact and the record is what has gone stale, so the row draws the failure in its own colour and reports the record stale in the unreadable colour - never the wait's colour over a red check, and never a silent drop either.

**"I don't think we will ever be waiting on the upstream until we have the complete PR right?"**

True for a ship task, and the `pr-recorded` condition enforces it rather than trusting it.
The one legitimate no-PR case is the scout above, which is why the gate has a scout branch at all.

## How the view draws it

`waiting on action from upstream`, followed by the recorded plain-English action, in the same slot and the same position where `captain driving directly in the window` shows.
Both can hold at once and both are drawn: the captain sitting in a window does not stop a PR waiting on a maintainer, and a row that showed one and swallowed the other would say firstmate is not watching for a reason that is only half the truth.

The `GITHUB CI` cell turns the same colour with `action needed from upstream` beneath it, and keeps its own `N/N passed` count on the row below that: the cell is saying who the ball is with, not forgetting what it knows about the PR.

The colour is lilac, `38;5;147`, and it is the one value in that view that is not a terminal palette slot.
`docs/flow-tui.md`'s colour policy says why every other colour is one, and why this meaning could not be: the sixteen-colour slots are all carrying meanings already - failure, skipped and scouting share one, unreadable has one, identity has one, waiting on the captain has one - so a seventh meaning would have made one of them ambiguous.
It is used by exactly two places drawing the same fact, so if it reads wrong against a theme there is one value to change.
