Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: issue six dormant arms as six Claude Code background tasks in ONE reply, each running exactly `bin/fm-watch-arm.sh --dormant` and nothing else.
   One of them takes the watcher and the other five wait their turn, so the wake after this one needs no arming call at all.
   `bin/fm-arm-pool-lib.sh` owns how many and how few; the turn-end guard asks for a refill when too few are left.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. Ordinary wake: when a background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes and handle the wake.
   Do NOT arm anything first. A waiting arm has already taken the watcher, so supervision never lapsed and a call spent on re-arming is a call not spent on the work.
   Refill only when the turn-end guard asks for it, by issuing six `bin/fm-watch-arm.sh --dormant` background tasks in one reply.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
   A `watcher: cycle-complete ...` close is handled the same way and is not a failure: an attached cycle ended by delivering its wake to the arm that owns that watcher.
9. Refill for free: run `bin/fm-send.sh --refill ...` and `bin/fm-ack.sh --refill ...` as their own Claude Code background tasks.
   A successful one stays alive as a waiting arm while the pool has room, so ordinary steering keeps the pool topped up and the turn-end refill is only ever reached in a turn that sent nothing.
   Their output is not something to act on, which is why they can be spent this way; a failed send or ack exits at once with its error instead.
   Never pass `--refill` to a foreground run: that process becomes the thing that waits, so the call would never come back.
10. Killed background task, not a wake: if this background task ends without a wake line - Claude Code stopped it for low memory, or the session restarted - the watcher is still running.
   The arm starts it detached from the task's process group and session, so a kill of the task does not reach it.
   Re-run `bin/fm-watch-arm.sh` as a fresh background task to re-attach; `watcher: attached ...` is the expected result and confirms supervision never lapsed.
   Do not use `--restart` here: that would stop a healthy watcher and leave a real gap where there was none.
11. The continuity PreToolUse gate allows wake drain and watcher arm recovery, and refuses only other `bin/fm-*.sh` fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
12. The existing turn-end guard remains unchanged as the final backstop and is not replaced by this command gate.
13. Recovery only: if a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
14. Do not send idle progress while the watcher is parked.

Claude Code's background task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
