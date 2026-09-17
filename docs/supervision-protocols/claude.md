Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`, at SESSION START only; an ordinary wake arrives already drained (item 8).
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: issue six waiting arms in ONE reply, each as its own Monitor with `timeout_ms` at the 1800000 maximum, running exactly `bin/fm-watch-arm.sh --dormant <N> 2>&1` and nothing else.
   `<N>` is that arm's pool number, 1 to 6, and the Monitor's description is exactly `dormant arm <N>` - no other wording, and never a letter.
   Pass the same number in the command and in the description, because the arm reports that number back in its own wake line and two labels for one arm is the confusion this numbering removes.
   A refill reuses the numbers that were freed rather than counting on from six: the arms still waiting keep their numbers, and the turn-end guard's refill block names the free ones.
   One of them takes the watcher and the other five wait their turn, so the wake after this one needs no arming call at all.
   Monitor rather than a background task, for two measured reasons (2026-09-16/17, overnight, this fleet): a Monitor delivers each stdout line as a notification, so the watcher's reason reaches the model with no call at all; and the harness's low-memory reaper killed background shells within a minute of about thirty minutes' captain inactivity, with 18 GB free, while never taking a Monitor.
   A Monitor is capped at thirty minutes and is killed at expiry with a notice: re-arm the expired members then, which is the same one-reply refill as any other.
   An expired member that was the one WATCHING leaves its watcher running, because the watcher is detached from it; the others stay asleep until that watcher fires, and its wake waits in the durable queue until the next cycle drains it, so it arrives late rather than not at all.
   `bin/fm-arm-pool-lib.sh` owns how many and how few; the turn-end guard asks for a refill when too few are left.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. A waiting arm says nothing when it takes the watcher or hands it on; those lines go to `state/.watch-arm.log`, because a handover is the pool working rather than news.
   Proof that a live cycle exists is the turn-end guard and `bin/fm-guard.sh`, not a line in the chat.
   Do NOT arm a plain `bin/fm-watch-arm.sh` (no `--dormant`) while the pool is live: it follows the successor chain and prints `watcher: attached ...` on every handover, which is one extra notification per wake for a fact nobody acts on.
   A plain arm still prints `watcher: started ...` and `watcher: attached ...`, and remains the right tool for `--restart` recovery, when no pool is running.
7. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. Ordinary wake: a waiting arm prints exactly ONE line, and it is the wake.
   Its shape is `dormant arm <N>: watcher exited, firstmate woken, watcher replenished from the pool, <M> dormant watchers lurking - <the crewmate's words>`, where `<N>` is the arm that fired and `<M>` is how many are still asleep behind it.
   Act on the words. The records are already drained - the arm drains on its way out and deliberately does not print them a second time - so there is nothing left to drain and no call to spend on draining it.
   A line that says the pool is empty instead of replenished is the one to act on: nothing is waiting for the next wake, so refill as item 3 says.
   The harness also emits its own "stream ended" notice for each finished Monitor. That one comes from the harness, not from firstmate, and cannot be suppressed from this side; one wake line plus that notice is the floor.
   Do NOT arm anything first. Another waiting arm has already taken the watcher, so supervision never lapsed and a call spent on re-arming is a call not spent on the work.
   Refill only when the turn-end guard asks for it, or when a Monitor reports its own expiry, by issuing six waiting arms in one reply exactly as item 3 says.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
   A `watcher: cycle-complete ...` close is handled the same way and is not a failure: an attached cycle ended by delivering its wake to the arm that owns that watcher.
9. Refill for free: run `bin/fm-send.sh --refill ...` and `bin/fm-ack.sh --refill ...` each as its own Monitor, the same way and for the same reasons as item 3.
   These take no pool number: they become a member only if there is room, and the pool gives them the lowest free number when they do.
   A successful one stays alive as a waiting arm while the pool has room, so ordinary steering keeps the pool topped up and the turn-end refill is only ever reached in a turn that sent nothing.
   Their output is not something to act on, which is why they can be spent this way; a failed send or ack exits at once with its error instead.
   Never pass `--refill` to anything you are waiting on in the foreground: that process becomes the thing that waits, so the call would never come back.
10. Ended arm, not a wake: if a waiting arm ends without a wake line - a Monitor expiry, a stopped task, or a session restart - the watcher is still running.
   The arm starts it detached from the task's process group and session, so a kill of the task does not reach it.
   Issue a fresh waiting arm to replace it, reusing the number the ended one freed; the pool carries on regardless.
   Do not use `--restart` here: that would stop a healthy watcher and leave a real gap where there was none.
11. The continuity PreToolUse gate allows wake drain and watcher arm recovery, and refuses only other `bin/fm-*.sh` fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
12. The existing turn-end guard remains unchanged as the final backstop and is not replaced by this command gate.
13. Recovery only: if a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Monitor mechanism.
14. Do not send idle progress while the watcher is parked.
15. Bookkeeping runs as a Monitor, not in the foreground: a fleet command needs the foreground only when its result is your very next action.
    Merges, teardown, spawn, acks, attestations, waivers, holds, backlog writes, fleet sync, and `bin/fm-write.sh` all qualify; reads whose output IS the next action - peek, crew-state, the session-start digest, backlog and fleet views - stay foreground.
    Redirect with `2>&1` so failures arrive as events too, filter to the few lines that are the verdict, and never `sleep` waiting for something the watcher or a PR poll already wakes you for.
    [`background-bookkeeping.md`](../background-bookkeeping.md) owns the per-command table, the exact shapes, the one merge that must not use a Monitor, and what each was measured to cost.

A waiting arm's own stdout is the wake mechanism: each line it prints arrives as a notification, which is why the wake carries the watcher's reason rather than a pointer to it - and why it carries nothing else.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
