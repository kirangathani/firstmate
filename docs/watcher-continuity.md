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

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` has exactly four outcomes, and only one of them is a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.
The fourth outcome is the session-lock refusal: when this home's session lock (`state/.lock`) is held by another live session, the arm prints one `watcher: read-only ... not arming` line and exits 0 without an actionable line.
That is a correct refusal, not a failure, so both close classifiers - `classifyArmClose` in `.opencode/plugins/fm-primary-watch-arm.js` and `classifyClose` in `.pi/extensions/fm-primary-pi-watch.ts` - match that line explicitly and neither retries it nor reports `watcher: FAILED`.
Without that case an adapter whose pre-check saw ownership change between the check and the arm's own gate would surface a supervision failure for correct behavior.
The verdict is carried through the restoration wrappers as well, not just the classifiers: a stand-down is a terminal outcome distinct from an unready successor, so `restoreAfterActionableClose` stops in both adapters and the original actionable wake is delivered with a `watcher: read-only ... stood down` note rather than a failure.
The note still names the reason, because the session does need to know supervision moved; it simply is not a `watcher: FAILED`, and nothing retries it.
The genuine failure paths - an unresolved ownership resolver, an unready successor, a successor that will not retire - are unchanged and still retry and still report, and the trailing `after N retries` sentence is now emitted only on a path that actually retried.
`bin/fm-watch-checkpoint.sh`, Codex's bounded foreground protocol, applies the same gate with the same three-way decision and the same wording, because it is the second entry point that takes the watcher singleton.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, proves an in-flight `read-only` refusal is not served to a request made after the lock was acquired, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.

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
`read-only` is broken for the opposite reason: `sessionOwnsLock` reads the lock file at the START of a long `ps` ancestry walk, so its answer can be older than the coalescing that inherits it.
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
