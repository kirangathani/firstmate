Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: issue six waiting arms in ONE reply, each as its own Monitor with `timeout_ms` at the 1800000 maximum, running exactly `bin/fm-watch-arm.sh --dormant 2>&1` and nothing else.
   One of them takes the watcher and the other five wait their turn, so the wake after this one needs no arming call at all.
   Monitor rather than a background task, for two measured reasons (2026-09-16/17, overnight, this fleet): a Monitor delivers each stdout line as a notification, so the watcher's reason reaches the model with no call at all; and the harness's low-memory reaper killed background shells within a minute of about thirty minutes' captain inactivity, with 18 GB free, while never taking a Monitor.
   A Monitor is capped at thirty minutes and is killed at expiry with a notice: re-arm the expired members then, which is the same one-reply refill as any other.
   An expired member that was the one WATCHING leaves its watcher running, because the watcher is detached from it; the others stay asleep until that watcher fires, and its wake waits in the durable queue until the next cycle drains it, so it arrives late rather than not at all.
   `bin/fm-arm-pool-lib.sh` owns how many and how few; the turn-end guard asks for a refill when too few are left.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. Ordinary wake: when a waiting arm reports `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes and handle the wake.
   Do NOT arm anything first. Another waiting arm has already taken the watcher, so supervision never lapsed and a call spent on re-arming is a call not spent on the work.
   Refill only when the turn-end guard asks for it, or when a Monitor reports its own expiry, by issuing six waiting arms in one reply exactly as item 3 says.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
   A `watcher: cycle-complete ...` close is handled the same way and is not a failure: an attached cycle ended by delivering its wake to the arm that owns that watcher.
9. Ended arm, not a wake: if a waiting arm ends without a wake line - a Monitor expiry, a stopped task, or a session restart - the watcher is still running.
   The arm starts it detached from the task's process group and session, so a kill of the task does not reach it.
   Issue a fresh waiting arm to replace it; the pool carries on regardless, and `watcher: attached ...` from an ordinary arm confirms supervision never lapsed.
   Do not use `--restart` here: that would stop a healthy watcher and leave a real gap where there was none.
10. The continuity PreToolUse gate allows wake drain and watcher arm recovery, and refuses only other `bin/fm-*.sh` fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
11. The existing turn-end guard remains unchanged as the final backstop and is not replaced by this command gate.
12. Recovery only: if a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
13. Do not send idle progress while the watcher is parked.

A waiting arm's own stdout is the wake mechanism: each line it prints arrives as a notification, which is why the wake carries the watcher's reason rather than a pointer to it.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
