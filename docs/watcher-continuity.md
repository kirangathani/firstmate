# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its new PreToolUse continuity gate allows wake drain and arm recovery but refuses only other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The existing turn-end guard implementation and adapters are unchanged.
They remain the final backstop rather than the normal continuity mechanism.

## The watcher outlives its arm

The arm is the harness's own background task, and a harness kills it for reasons that have nothing to do with supervision.
Claude Code's low-memory protection stopped it at least nine times between 23:30 and 11:00 on 2026-09-07/08, every time while `MemAvailable` still read 7-12 GB of a 20 GB box and only page-cache-excluded `MemFree` had dipped; nothing in the arm uses memory, so the arm cannot avoid being picked.
Each of those kills took the watcher down with it - the next arm reported `watcher: started ...` rather than `attached` - cost a full turn to notice, drain and re-arm, and left the fleet unsupervised for minutes.

`bin/fm-watch-arm.sh` now starts the watcher through `setsid(1)`, in its own session and process group with stdio off the task's pipe, and stops reaping it on TERM and INT once it is confirmed, so a kill aimed at the arm task does not reach it.
The arm still follows it exactly as before: `setsid` does not fork when the child is not already a process-group leader, which the arm guarantees by switching job control off, so the watcher stays the arm's direct child, `wait` still returns its exit, and the arm's own exit is still the harness's wake signal.
That script's header owns the mechanics.
Nothing about the wake contract, the beacon, the singleton lock, `state/.wake-queue`, or the continuity gate changes.

A killed arm therefore means "re-run the arm to re-attach", not "the watcher is gone", and the next arm reports `watcher: attached ...` through the ordinary singleton path with no change to the identity or beacon checks.
Two cases still reap deliberately.
An unconfirmed child is reaped on any interrupt, because a watcher that never proved itself live and fresh would only contend for the singleton with the next arm's child.
HUP still reaps this arm's own confirmed child, and that split is measured rather than assumed: the captain's live cycle ledger holds 778 records, 37 of them a catchable arm interrupt, and every one is `signal=TERM`, including the five overnight kills on 2026-09-08 at 01:02, 01:32, 01:36, 01:46 and 01:58 - `signal=HUP` has never been recorded once.
It also means something different: TERM says the task was stopped while the session lives on and a re-arm will follow, whereas HUP says the session that owned the arm is gone, and a detached watcher in its own session would never receive that hangup itself, so nothing would ever follow it.
If a harness kill ever arrives as HUP, that is the branch to revisit, and the ledger's `signal=` field is where it shows up.

The cost is deliberate and bounded in two ways.
A watcher that outlives every arm is still one-shot: it exits on the next actionable wake, a heartbeat at the latest, and a beacon that lapses without one is what `bin/fm-guard.sh` alarms on.
The arm also cannot tell a TERM memory kill from a clean harness exit that sends TERM, so a deliberate quit on that path now leaves the watcher until that same next cycle rather than removing it immediately; `tests/fm-pi-primary-live-e2e.test.sh` asserts that direction explicitly and reaps it in its own cleanup.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` has exactly five outcomes, and none of them is a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or classifies the close through `cycle_outcome` and reports it.
An attached arm follows verified identity-matched successors and takes the same classified close when that chain ends without one.
That classification is the third and fourth outcomes, and it exists because those two used to share one line.
A cycle always ends with no watcher running and the lock released, so "the cycle ended" is equally true of a healthy close and a dead one and separates nothing; reporting both as `watcher: FAILED - cycle ended without an actionable reason` made a genuine lapse unnoticeable among the benign closes that produce it several times an hour.
The discriminator is the durable wake counter `fm_wake_seq` (`bin/fm-wake-lib.sh`), snapshotted when a cycle begins: only `fm_wake_append` advances it, only `bin/fm-watch.sh` calls that, and no drain resets it, so a change across the cycle is positive proof the watcher produced a wake rather than merely stopping.

- `wake-delivered`: the counter advanced, so the cycle ended by queueing a real wake.
  The reason line went to the arm that OWNS that watcher and the wake itself is durable, so this arm prints `watcher: cycle-complete ...` and exits 0.
  It is not a failure and it is not an empty no-op.
- `lapsed`: no wake, and `state/.last-watcher-beat` is stale past `FM_GUARD_GRACE`, so nobody is supervising the fleet.
  The arm prints `watcher: FAILED - supervision LAPSED: ...` naming the beacon age and the grace it passed, and exits nonzero.
- `no-wake`: no wake, but the beacon is still inside the grace, so supervision was alive until this close and produced nothing.
  The arm keeps the original `watcher: FAILED - cycle ended without an actionable reason` wording, now carrying that beacon evidence, and exits nonzero.

The same `cycle_outcome` value is written to the ledger's `outcome=` field, so the reported line and the durable record cannot disagree.
Both adapters classify a `watcher: cycle-complete` close as a completed cycle rather than a failure, restoring continuity and delivering the line as a wake note; without that they reported a false failure AND spent a retry slot per benign close, so a fleet producing them steadily would exhaust the retry budget and declare supervision dead while it was healthy.
The fifth outcome is the session-lock refusal: when this home's session lock (`state/.lock`) is held by another live session, the arm prints one `watcher: read-only ... not arming` line and exits 0 without an actionable line.
That is a correct refusal, not a failure, so both close classifiers - `classifyArmClose` in `.opencode/plugins/fm-primary-watch-arm.js` and `classifyClose` in `.pi/extensions/fm-primary-pi-watch.ts` - match that line explicitly and neither retries it nor reports `watcher: FAILED`.
Without that case an adapter whose pre-check saw ownership change between the check and the arm's own gate would surface a supervision failure for correct behavior.
The verdict is carried through the restoration wrappers as well, not just the classifiers: a stand-down is a terminal outcome distinct from an unready successor, so `restoreAfterActionableClose` stops in both adapters and the original actionable wake is delivered with a `watcher: read-only ... stood down` note rather than a failure.
The note still names the reason, because the session does need to know supervision moved; it simply is not a `watcher: FAILED`, and nothing retries it.
The genuine failure paths - an unresolved ownership resolver, an unready successor, a successor that will not retire - are unchanged and still retry and still report, and the trailing `after N retries` sentence is now emitted only on a path that actually retried.
`bin/fm-watch-checkpoint.sh`, Codex's bounded foreground protocol, applies the same gate with the same three-way decision and the same wording, because it is the second entry point that takes the watcher singleton.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, the `cycle_outcome` classification, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

A DORMANT arm - a pool member - announces nothing on stdout except its own wake, and sends its `watcher: started ...` and `watcher: attached ...` lines to `state/.watch-arm.log` instead.
That file is size-capped through `FM_WATCH_ARM_LOG_MAX_BYTES` and `FM_WATCH_ARM_LOG_KEEP_LINES`, records each line against the arm's pid and pool slot, and is diagnostic only; nothing reads it to make a supervision decision.
The reason is that each line a member prints under Claude Code's Monitor becomes a notification the model must read, so what a member prints is what a wake costs.
Measured in the captain's home on 2026-09-17, one crewmate status append produced five: the holder's wake line, the same records again from its drain at exit, the successor's `watcher: started ...`, an ordinary attach-follow arm's `watcher: attached ...` down the successor chain, and the harness's own stream-end notice for the finished Monitor.
Four of those are now gone.
The fifth cannot be: the stream-end notice is emitted by the harness for every finished Monitor and there is nothing on this side to suppress it, so one wake line plus that notice is the floor this design can reach.
A plain arm keeps every line it ever printed, including the raw drained records, and must not be armed alongside a live pool - it follows the successor chain and announces every handover, which is the fourth notification above.
Its wake line is `dormant arm <S>: watcher exited, firstmate woken, watcher replenished from the pool, <N> dormant watchers lurking - <the crewmate's words>`, where `<S>` is the member's own pool slot and `<N>` is how many members are still asleep once the handover is done.
`bin/fm-arm-pool-lib.sh` owns the slot numbering: members are numbered 1 to the pool size, the number is passed in as `--dormant <S>` so the Monitor's description and the arm's own line agree, and a freed number is the next one handed out so a refill reuses it.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Watcher-layer ownership: re-checked every poll

The arm's gate above reads ownership once, at launch.
That was the whole of it until 2026-09-15, when a home's session lock moved under a running watcher and the watcher kept supervising a fleet its session no longer controlled, because nothing looked again after the arm.
`bin/fm-watch.sh` now re-reads ownership at the top of every cycle, beside the self-eviction check, and acts on the three verdicts `bin/fm-session-lock-lib.sh` already defines.

- `owned`: continue, which is the whole cost on the healthy path - one file read, and a short ancestry walk only when the holder is not this process.
- `missing`: attempt the sanctioned re-acquire, `bin/fm-lock.sh` itself, which is idempotent for the owner.
  The watcher is the owner's descendant, so a successful re-acquire re-records the owner's own pid and supervision continues with nothing surfaced.
  That re-acquire can only fail when no live session sits above this watcher at all, which means the session that armed it is gone; the watcher then queues one reason naming `bin/fm-session-start.sh` and stands down.
- `other`: never recoverable here, because a watcher whose session no longer owns this home must stop supervising it.
  It queues one reason carrying the shared holder description and the remedy, naming `bin/fm-lock.sh status`, and stands down.

Both stand-downs go through `fm_wake_append` before exiting, so the reason waits in `state/.wake-queue` for the next session start rather than depending on anyone reading a pane.
Detection latency is one poll, `FM_POLL`, default 15 seconds.

The check arms only for a watcher that read `owned` at startup, recorded once before the loop.
A watcher that did not own the home when it started never had ownership to lose: the arm armed it deliberately, with its own announced notice, and the blind-turn alarm already covers that home.
Arming the check for it would turn that announced state into a stand-down on the first poll, which is why the condition is ownership LOST rather than ownership absent.

Because a `missing` verdict now leads to a re-acquire and possibly a stand-down, a reader that lands inside a lock write matters in a way it did not before.
`fm_session_lock_write` therefore writes a temporary file in the same directory and renames it over `state/.lock`, so every reader sees the old holder or the new one and never a half-written file.
It is the only writer of that format, so one change covers every reader.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, proves an in-flight `read-only` refusal is not served to a request made after the lock was acquired, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination, and both cycle-end directions: a cycle that delivers a real wake through the real registered-check path is reported complete with exit 0 and its wake is drained to prove the claim, while a dead watcher whose beacon is backdated past the production grace still fails loudly with the lapse wording.
It also covers the detach directly: a `TERM` and a `KILL` of the arm task's whole process group each leave the watcher alive and still publishing beacons, the next arm attaches to that survivor instead of starting a rival, a hard-killed watcher with a lapsed beacon still gets a fresh start rather than an attach, and an arm's own `HUP` still reaps its own child and its temp output, the base assertion preserved unchanged.
Those cases launch the arm through `setsid` themselves so it is its own process-group leader, which both reproduces the harness's kill without signalling the test run and makes surviving it proof of the detach rather than proof that a trap was removed.
That file reaps its own background processes from the shell's job table on EXIT, because `fail()` exits the whole file and any failing assertion previously orphaned a real watcher.
It now also reaps each fixture's recorded watcher pid, because a watcher that deliberately survives its arm is no longer covered by the job table alone.
`tests/fm-pi-watch-extension.test.sh` covers the adapter half of the same contract for Pi and OpenCode, using the exact captured `watcher: cycle-complete` bytes and a guard that fails if `bin/fm-watch-arm.sh` stops emitting that line.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.
`tests/fm-watcher-lock.test.sh` also owns the per-poll ownership check, driving the real watcher for each verdict: an owning watcher keeps supervising and still delivers an ordinary wake, a home taken by a live session outside its ancestry stands it down with the remedy in its durable queue and the singleton released, a lock that vanishes under a live session is re-acquired rather than surfaced, the same vanished lock stands it down when no harness sits above it, and a watcher armed with no lock at all never stands down.
The unrecoverable case sizes itself from `FM_SESSION_LOCK_ANCESTRY_DEPTH`, read at runtime, so the re-acquire fails for the same reason on a machine with a real session above the suite and on one without.
The recoverable case builds a real process whose command name is `claude` above the watcher for the same reason, rather than relying on whatever happens to be running the suite.
`tests/fm-session-lock-gate.test.sh` owns the session-lock gate itself: the `bin/fm-lock.sh ownership` verdicts and their read-only contract, the arm and checkpoint refusing for a live rival owner while still arming for an absent, dead, or pid-reused holder, ownership recognized several process levels down, the status line, and an assertion that only `bin/fm-session-lock-lib.sh` implements the walk.

## OpenCode arm coalescing: measured behavior, 2026-08-03 and 2026-08-04

`.opencode/plugins/fm-primary-watch-arm.js` guards launches with a module-level `launchInFlight` promise, and the `session.idle` handler calls `ensureArm` fire-and-forget, so a second request can arrive while the first is still running its asynchronous precondition checks.
`beginArm` refuses with `read-only` when the session does not own the fleet lock.
Before this fix, a second request made after the session acquired the lock was served that first request's `read-only` refusal, so it never armed and nothing on that path retried.
The guard coalesced two requests whose lock-ownership preconditions differed.

`ensureArm` now re-launches once when a coalesced answer is `read-only` that the current lock state contradicts, bounded at two attempts and without recursion.
It reads the lock only on that refusal, so ordinary coalescing pays nothing extra.
The single-flight guard itself stays, because it is what prevents duplicate launches.

This is what made `tests/fm-pi-watch-extension.test.sh`'s OpenCode session-lock case fail, and the widely repeated explanation for that failure was wrong.
It was recorded as a load-sensitive flake that missed the test's fixed 5-second arming poll under load.
Measured instead with a standalone reproduction of that single assertion, polling 60 seconds rather than 5, arming is bimodal:

```text
repro 1 PASS armed_after=42ms      repro 4 PASS armed_after=22ms
repro 2 FAIL never_armed 58206ms   repro 5 PASS armed_after=23ms
repro 3 PASS armed_after=22ms      repro 6 PASS armed_after=44ms
```

It arms in roughly 25ms or it never arms at all, so widening the timeout would not have fixed it.
Load only affects the trigger, meaning whether the first call's precondition checks are still running when the second request arrives.
The consequence is permanent for that event.
The same file failed 5 of 5 isolated repeats at load averages from 3.06 to 10.94, which is not flake behavior.
`tests/fm-watcher-lock.test.sh` is a separate, genuine load-sensitive flake with a different cause and passed 32 of 32 in isolation over the same period.

Two further facts were measured on 2026-08-03 against the unfixed plugin, using a reproduction that pins the first launch inside the lock-ownership walk with a blocking `ps` shim so no timing assumption is needed.

- The failure is deterministic once the race is won rather than probabilistic: 3 of 3 runs never armed within a 20-second poll.
- A later `session.idle` event does recover arming, in 48ms, 103ms, and 74ms across those same three runs, because the stale launch has settled and cleared `launchInFlight` by then.
- Forcing the same race on the pre-existing `test_opencode_primary_watch_plugin_requires_session_lock` case, by putting that `ps` shim on `PATH` for the whole file rather than adding any new assertion, turns its historically intermittent failure into a certain one against the unfixed plugin and a pass against the fixed plugin.
  That is what ties this defect to the failure that was being waved through as a flake.

Recovery on a later event is not a mitigation the fleet can rely on.
The watcher is what wakes an idle session, so when arming is denied for an idle event there is no guaranteed later turn to produce the next `session.idle`, and supervision stays off while every surface reports healthy.

The re-check covers only the `read-only` refusal, and that is deliberate: `beginArm`'s other two refusals were investigated and are not the same mechanism.

`not-needed` was tested directly on 2026-08-04, against the plugin WITHOUT any `not-needed` re-check, using the same release-file reproduction.
The session owned the lock, `state` held no `.meta` file, the first launch was pinned inside the ownership walk, a `.meta` file was then created mid-flight, and a second `session.idle` event was fired so it coalesced onto that pinned launch.
It armed in 3 of 3 runs, and the control with no `.meta` file at any point correctly did not arm.

The reason is structural.
`shouldArm` is the last check in `beginArm` and is fully synchronous, so its answer is computed after every await has already resolved, at the latest possible instant.
A coalesced caller therefore receives an answer that a launch starting at that same instant would also produce.
`read-only` is broken for the opposite reason: the ownership check reads the lock at the START of a long ancestry walk, so its answer can be older than the coalescing that inherits it.
That check was the plugin's own `sessionOwnsLock` when this was measured; it is now `resolveSessionOwnership`, which delegates the same walk to `bin/fm-lock.sh ownership`, so the read-to-answer distance it describes is unchanged.
The gap being fixed here is that distance between reading a precondition and answering with it, and `shouldArm` has no such distance.

Two consequences worth stating, because the shape looks identical from a distance and will invite the same fix again.
A regression test for `not-needed` in the usual shape is impossible: it cannot fail against the unfixed plugin, because the unfixed plugin already handles it.
This property does depend on `shouldArm` staying last and staying synchronous, so moving it before an await, or making it asynchronous, would open exactly the gap `read-only` had.

`skipped` is read from the source rather than measured: `beginArm` returns it only when the call carries no session id, and both live call sites, the `session.idle` handler and the turn-end guard's coordinator call, return early before calling in that case, so no reachable caller can be served it.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
The captured system message exactly named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
