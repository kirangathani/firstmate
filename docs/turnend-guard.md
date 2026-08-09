# Primary turn-end supervision guard

This is the authoritative contract for the "no turn ends blind" primary guard referenced from AGENTS.md section 8.
The turn-end supervision predicate lives in `bin/fm-turnend-guard.sh`.
Its primary-checkout scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge documented in `docs/sessionstart-nudge.md`.
Harness-specific tracked hook files only adapt each verified harness's real turn-end mechanism to that shared predicate.
Two related but separate PreToolUse seatbelts deny a bad command shape before it runs rather than detecting a blind turn end afterward: the watcher-arm seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) and the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`).
Each seatbelt's own document defines its scope; they do not share the turn-end guard's marker-aware primary detection.

## Gap Closed

`bin/fm-guard.sh` is pull-based: it warns whenever some other supervision script happens to run, and prints nothing otherwise.
The primary can otherwise end a turn after handling wakes without resuming supervision, then sit blind until another fleet command happens to run.
On 2026-07-04, that exact gap left a parked no-mistakes gate unwatched for about nine hours.

`bin/fm-turnend-guard.sh` closes the gap by checking the primary's own turn-end path.
When tasks are in flight and there is no live identity-matched watcher with a fresh beacon, a harness hook must either block the turn end or force a bounded follow-up turn that tells the primary to repair the missing or failed watcher cycle using the recovery instruction in its emitted session-start protocol.

## Shared Predicate

The guard first calls the shared primary scope to constrain itself to a real primary checkout.
A secondmate home runs its own primary firstmate session, so a genuine `.fm-secondmate-home` marker force-includes it whether treehouse leased it as a linked worktree or it is a git-cloned plain checkout.
The marker must be a regular non-symlink file whose first line, after all whitespace is removed, contains a non-empty identifier made only of letters, digits, dots, underscores, and dashes.
An unmarked checkout, or one with an invalid marker, falls through to the git-dir check.
That check keeps crewmate and scout worktrees inert because firstmate provisions them as linked git worktrees, where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`.
It also requires `AGENTS.md`, `bin/`, and the effective state directory to exist.

For an in-scope primary checkout, it counts in-flight work from `state/*.meta`.
If no task is in flight, it exits silently.
If work is in flight, it requires `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
That is the same identity-matched live lock and fresh beacon check used by `bin/fm-watch-arm.sh`.
The process-identity primitive behind that match must not drift for a live process; see the 2026-07-30 WSL2 entry below for why, and `bin/fm-wake-lib.sh` for the format itself.
A stale beacon blocks even if a watcher pid is still live.
A fresh leftover beacon blocks if the watcher lock is missing, dead, or identity-mismatched.

It then requires this session to hold the home's SESSION lock, `state/.lock`, resolved by `bin/fm-session-lock-lib.sh` and distinct from the `state/.watch.lock` watcher singleton above.
When another live session holds it, the guard exits 0 silently, mirroring the read-only advisory mode `bin/fm-guard.sh` already has: that session cannot arm a watcher at all, because `bin/fm-watch-arm.sh` declines from there, so a blind-turn alarm would be a hard stop-hook error on nearly every turn demanding supervision work it must not do.
An absent lock or a dead holder still blocks, because nobody is supervising the in-flight work and this session is the one that should take the lock and arm.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repo-root `state/`.
`FM_GUARD_GRACE` controls the beacon freshness window and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard fails open and exits 0 because it cannot safely read loop-guard fields.

## Second Block Reason: A Base That Moved

The guard has a second, independent reason to block, added 2026-08-09 and computed by `bin/fm-stale-base.sh`, whose header owns the predicate, the silent cases, and the remedy wording.
An in-flight task whose pushed branch no longer contains its project's current `origin/<default>` has had every CI result on it measured against a base that no longer exists, so those results read as verdicts on the branch and are not.

The incident it exists to prevent: firstmate's `main` was red all afternoon on one assertion in `tests/fm-backend.test.sh`, PR 44 fixed it and merged at roughly 15:25, and PRs 41, 42, 43 and 45 were open at that moment.
Exactly one of them was steered onto the fixed base.
For about twenty minutes the other three showed a purely inherited red that was relayed as if it described those branches, and the captain noticed before firstmate did.
The detection was one command per branch - `git merge-base --is-ancestor <new-base-sha> origin/<branch>` - which nothing in the system had asked.

Two places raise it, and they are deliberately not the same place:

- Immediate: `bin/fm-fleet-sync.sh`, per project, when that clone's `origin/<default>` actually moved across the fetch. That is the first instant the new base exists in this home at all, so the answer is fresh by construction. It is not raised on the merge notification itself, because that wake fires before anything has refreshed the clone: a list computed there would be measured against the OLD base and would report all clear at the exact moment it is wrong.
- Backstop: this guard, so an absorbed wake or a skipped refresh cannot let the condition survive a whole turn.

The check reads only local refs and never fetches, so it adds no network call to the turn-end path and never writes to a project clone.
It resolves each task's branch from `git worktree list --porcelain` on the parent clone - git's own record, never anything an agent wrote - and it never touches a worker's worktree.
A determinate all-clear is silent (a scout, a secondmate record, a clone with no origin remote, a task still on the pristine detached base, an unpushed branch, or a branch that already contains the base), while anything undeterminable is reported as undeterminable rather than folded into silence.

The sweep is still bounded by `FM_STALE_BASE_TIMEOUT` (default 10 seconds, `bin/fm-bounded-lib.sh`) because this hook is the one place a hang wedges the whole session, and an expiry is reported as "no branch in flight has been checked" rather than treated as an all-clear.
Both reasons print in the same banner rather than one short-circuiting the other, so a permanently broken watcher cannot hide every stale base behind it.
The loop guard still bounds this to one forced continuation per turn.
Because the remedy is a steer whose effect only lands when the worker pushes, a finding is silenced by `bin/fm-stale-base.sh --ack <task-id>`, which records the finding's situation key in `state/<task-id>.stale-base-ack`.
The key embeds the base commit, so the acknowledgement is scoped to the base it was made at and the sweep re-alarms the moment the base moves again.
That is what keeps this backstop from decaying into the ignored-because-constant noise the `watcher: FAILED - cycle ended without an actionable reason` alarm became.

## Third Block Reason: A Reported State Left Unanswered

Added 2026-08-09 and computed by `fm_ack_unactioned` in `bin/fm-ack-lib.sh`, whose header owns the predicate, the owed states, the grace window, and both silencers.
A direct report sitting in a terminal or firstmate-owed state, past the grace window, that firstmate has not acted on, blocks the turn.

This reason adds no new detection.
`bin/fm-guard.sh` has raised exactly this finding since #35 and exits 0: it warns, the turn ends anyway, and acting on it was the agent's to choose.
The first block reason is the precedent - it too is a condition `bin/fm-guard.sh` warns about, and giving it a consequence at turn end is what has caught two supervision blackouts on this box.
The third reason is that same treatment applied to the states workers report, which is why it reuses the predicate rather than adding a second one.

The measured failure it closes, 2026-07-30: a finished ship task sat unanswered for twenty minutes.
Its wake was durably queued, correctly drained, and read - and draining is what destroys the evidence, so nothing downstream could tell that the state had been dropped rather than handled.

Quiet on a healthy fleet, by the mechanics `bin/fm-ack-lib.sh` owns rather than by a separate rule here: a ten-minute grace, an acknowledgement that silences a state firstmate has already handled for as long as the captain takes to answer, and a current-state confirm that clears a worker which has provably moved on.
Every read it makes is a local file stat except the current-state confirm, which is already capped per invocation and cached, and is additionally wall-clock bounded (`FM_ACK_CONFIRM_TIMEOUT`, default 15 seconds) for the same reason the stale-base sweep is: this hook is the one place a hang wedges a whole session, and `bin/fm-crew-state.sh` reads panes and can shell out to `no-mistakes`, so it is not a call that can be assumed to return.
Bounding the confirm is not the same as swallowing the finding.
On expiry the verdict is `unconfirmed`, which still blocks, so the bound can only ever cost accuracy about a worker's current state and can never silence a report that was left unanswered.
That is the opposite of the stale-base sweep's expiry, which has no such fallback and therefore has to report "no branch has been checked" instead.

Measured 2026-08-09 on this machine (Linux 6.6.87.2-microsoft-standard-WSL2), `fm_ack_unactioned` in-process over a synthetic ten-task home, mean of 50 calls:

```
10 healthy tasks, nothing owed              0.06280s
10 tasks, 1 unactioned, first call          0.08103s
10 tasks, 1 unactioned, confirm cached      0.08050s
```

The healthy case forks no current-state reader at all, which is what keeps it flat; the unactioned case pays one confirm and then serves it from `state/.unactioned-<id>` for the cache TTL, against a stub reader deliberately given a 0.3s delay.
For scale, the stale-base sweep already on this same path measures ~0.2s across a ten-task fleet.

The one thing that stops it is a captain-signed per-task exemption in `state/<task-id>.monitor-exempt`, written only by `bin/fm-monitor.sh --exempt`, whose header owns the record and its limits.
An unsigned or unverifiable record is not an exemption, so the alarm cannot be silenced by writing a file.
Every standing exemption is announced at session start by `bin/fm-bootstrap.sh`, which is what makes a self-granted one report itself rather than quietly drop a task out of supervision.

`bin/fm-monitor.sh` renders the same predicate for every supervised task on demand, and is what the captain's `/monitor` reaches.
The alarm surface stays silent when clean; the render surface names every task and every class including zeros, because a silent all-clear cannot be told apart from not having looked.

## Harness Integrations

All verified primary harnesses have a tracked integration:

- `claude`: `.claude/settings.json` registers a `Stop` hook command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh`.
- `codex`: `.codex/hooks.json` registers a `Stop` hook that reads the hook payload once, anchors the executable to the hook command process working directory, verifies that root is firstmate-shaped and hook-bearing, and pipes the original payload to that checkout's `bin/fm-turnend-guard.sh`.
- `opencode`: `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`, lets the watcher-arm coordinator handle normal idle supervision first, runs the shared guard only when that coordinator does not act, and uses `client.session.promptAsync` to force one follow-up prompt when the guard returns 2.
- `pi`: `.pi/extensions/fm-primary-turnend-guard.ts` listens for `agent_settled`, marks the extension version loaded for session-start checks, runs the shared guard once per logical agent run, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one follow-up prompt when the guard returns 2.
- `grok`: `.grok/hooks/fm-primary-turnend-guard.json` registers a `Stop` hook that invokes `bin/fm-turnend-guard-grok.sh`.
  The adapter runs the shared guard and, when it returns 2, invokes `grok --resume <sessionId> -p <guard-reason>` with `GROK_TURNEND_GUARD_ACTIVE=1`.
  It does not pass `--permission-mode`, so the passive Stop hook cannot grant stronger tool permissions than Grok's resumed-session default.

Claude and Codex support a direct blocking Stop hook.
For those harnesses, exit status 2 plus stderr from `bin/fm-turnend-guard.sh` blocks the stop and feeds the reason back into the model.
Both payloads include `stop_hook_active`; when it is true, the shared guard exits 0 so the harness can end after one forced continuation.

OpenCode, Pi, and Grok expose passive lifecycle callbacks for this purpose.
Their adapters fail open at the hook boundary to avoid corrupting a user session, but they force one follow-up turn when the shared predicate blocks.
Each adapter carries its own in-process or environment loop guard so the forced follow-up does not recursively schedule another follow-up.
Pi keeps that latch active across every internal tool turn and clears it only when the generated guard follow-up reaches `agent_settled`, or immediately when follow-up delivery fails.
If a passive adapter cannot call its SDK method, cannot find `grok`, or cannot recover the Grok session id, it fails open and relies on the pull-based `fm-guard.sh` warning at the next fleet command.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it points back to the active harness protocol instead of hardcoding one background-arm command.

## Empirical Validation

All harnesses were validated on 2026-07-08 in scratch repos or throwaway homes, not against the captain's live primary fleet state.

Claude Code 2.1.204 preserved the existing behavior.
Hook file used: `.claude/settings.json`.
Command run: `claude -p "Say hi in exactly one word." --dangerously-skip-permissions --output-format json` with a scratch Stop hook that printed `SMOKETEST: you must say the word BANANA before stopping` and exited 2.
Observed output: the first stop payload had `stop_hook_active=false`, the stop was blocked, the model continued with `BANANA`, and the second stop payload had `stop_hook_active=true` and was allowed.
Earlier validation on 2026-07-04 also verified that `CLAUDE_PROJECT_DIR` is set to the settings-loaded project root, while the hook command itself runs from the session cwd.

Codex `codex-cli 0.142.1` was validated with a scratch `.codex/hooks.json` Stop hook.
Hook file used: `.codex/hooks.json`.
Command run: `codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Say hi in exactly one word.'`.
Observed output: the first model output was `Hi`, the Stop hook exited 2, Codex logged `hook: Stop Blocked`, the model continued with `CODEXHOOK`, and the second hook call had `stop_hook_active=true`.
The Stop payload included `cwd`.
Command run for root-signal probe: `codex exec --ephemeral --json --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Use the shell tool to run mkdir -p outside && cd outside && pwd, then use the shell tool again to run pwd. Your final answer must include the two observed outputs.'`.
Observed output: the first command printed `<scratch>/outside`, the second command printed `<scratch>`, the Stop hook process `pwd -P` printed `<scratch>`, payload `cwd` printed `<scratch>`, and `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, and `CODEX_CWD` were empty.
The tracked command therefore treats hook process PWD as the hook-loaded firstmate root and does not let payload `cwd` choose an executable.
It still passes the original payload to `bin/fm-turnend-guard.sh`, so the shared loop guard reads `stop_hook_active`.

OpenCode 1.17.6 was validated with project plugins under scratch `.opencode/plugins/`.
Hook file used: `.opencode/plugins/fm-smoke.js` for throw testing and `.opencode/plugins/fm-primary-turnend-guard.js` for follow-up testing.
Command run for passive behavior: `opencode run --print-logs --log-level DEBUG --dangerously-skip-permissions 'Say hi in exactly one word.'`.
Observed output: the plugin received `session.idle`, threw an error, and `opencode run` still exited 0 with `Hi`, proving `session.idle` cannot block directly.
Command run for follow-up behavior: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Say hi in exactly one word.' --print-logs --log-level INFO`.
Observed output: the plugin called `client.session.promptAsync`, the TUI ran a second turn, and the second model output contained `OPENCODEHOOK`.
In noninteractive `opencode run`, `promptAsync` returned successfully but the process exited before displaying the follow-up, so this adapter is trusted for primary TUI sessions and documented as passive/fail-open in headless mode.

Pi 0.80.5 was re-validated on 2026-07-09 in a disposable primary-shaped clone with isolated `PI_CODING_AGENT_DIR`, isolated `FM_HOME`, and tmux socket `fm-pi-q6-lab`.
Hook files used: the tracked `.pi/extensions/fm-primary-turnend-guard.ts` and `.pi/extensions/fm-primary-pi-watch.ts`.
Commands run inside separate interactive turns: `printf PI_E2E_BASH_ONE` through Pi's bash tool, `README.md:1-5` through Pi's read tool, and `printf PI_E2E_BASH_TWO` through Pi's bash tool.
Command used to make the shared predicate unhealthy: `: > "$FM_HOME/state/pi-e2e.meta"`.
The next no-tool prompt produced exactly one `TURN WOULD END BLIND` follow-up, and that follow-up called `fm_watch_arm_pi` once with output `watcher: started Pi extension arm child 1`.
The three earlier tool turns produced no guard follow-up because no work was in flight.
Command used to fire the watcher: `printf 'done: pi e2e watcher fire\n' > "$FM_HOME/state/pi-e2e.status"`.
Observed output after the wake: Pi ran `bin/fm-wake-drain.sh`, read the terminal status, called `fm_watch_arm_pi`, and rendered `watcher: started Pi extension arm child 2`.
This 2026-07-09 observation predates extension-owned successor continuity; [`watcher-continuity.md`](watcher-continuity.md) owns the current ordinary-wake contract.
The complete pane contained one guard message and zero foreground `bin/fm-watch-arm.sh` bash calls.
`/quit` printed `PI_EXIT=0`, and the second arm process plus its watcher child were both gone afterward.

Grok 0.2.91 was validated with a scratch `GROK_HOME` and symlinked auth/config.
Hook file used for tracked project-hook loading: `<scratch-project>/.grok/hooks/fm-smoke.json`, matching the tracked `.grok/hooks/fm-primary-turnend-guard.json` location.
Command run for project-hook loading: `GROK_HOME="$scratch/grok-home" grok --trust -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the project Stop hook fired under `--trust` and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`.
Hook file used for passive behavior and forced-resume behavior: `$GROK_HOME/hooks/fm-primary-turnend-guard.json` plus `bin/fm-turnend-guard-grok.sh`.
Command run for passive behavior: `GROK_HOME="$scratch/grok-home" grok -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the global Stop hook fired and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`, but exiting 2 did not make the model continue.
Command run for forced resume behavior: the Stop hook ran `GROK_TURNEND_GUARD_ACTIVE=1 GROK_HOME="$scratch/grok-home" grok --resume "$session_id" -p 'SMOKETEST: say exactly GROKRESUMEHOOK...' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the outer turn printed `Hi`, the nested resumed turn printed `GROKRESUMEHOOK`, and the nested Stop hook saw `GROK_TURNEND_GUARD_ACTIVE=1` and did not recurse.
That validation command used `--permission-mode bypassPermissions` only to keep the scratch smoke unattended; the tracked adapter intentionally omits `--permission-mode`.
Project-local Grok hooks did not fire in scratch single mode without a trust grant.
The primary integration therefore requires the primary firstmate checkout to be trusted for Grok hooks, which can be done with `/hooks-trust` or launch-time `--trust`.
If Grok declines to load project hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.

**2026-07-09 update:** grok 0.2.93 broke the `.grok/hooks/fm-primary-turnend-guard.json` Stop hook with `hook not executed: required env var(s) not set: ${root}`, because grok's own `${VAR}` expansion over the raw `command` string does not tolerate a bare local variable assigned earlier in the same `bash -lc` script.
The hook command was fixed to reference `${GROK_WORKSPACE_ROOT:-}` directly everywhere instead of assigning it to `$root` first, and re-validated against grok 0.2.93 to fire and complete cleanly.
See `docs/arm-pretool-check.md`'s "Harness wiring" section for the same Grok expansion requirement; that document's Grok hook shares the same fix.

### 2026-07-12: secondmate-home enablement and the autonomous background-notify wake

The guard originally early-exited in every secondmate home on the `.fm-secondmate-home` marker.
That was a scoping choice inherited from the guard's primary-only origin, not a defense against any secondmate-specific hazard.
A genuinely marked secondmate home is now force-included as a guarded primary regardless of whether it is a treehouse-leased linked worktree or a git-cloned plain checkout.
Only unmarked child worktrees fall through to the linked-worktree exemption, and marker validation prevents an empty, malformed, or symlink marker from spoofing inclusion.

"No turn ends blind" for a secondmate is delivered by the same two mechanisms the main primary relies on.
Mechanism B, the turn-end backstop, is this guard; its secondmate-home behavior is covered by hermetic tests in `tests/fm-turnend-guard.test.sh` (`test_hook_blocks_in_secondmate_own_home`, `test_hook_blocks_in_treehouse_leased_secondmate_home`, `test_hook_silent_in_idle_secondmate_home`, `test_hook_secondmate_loop_guard_allows_retry`, `test_hook_secondmate_reinvoke_recovery_loop`, `test_hook_silent_in_secondmate_child_worktree`, and `test_hook_exempts_linked_worktree_with_stray_marker`).
Mechanism A, the autonomous wake, is a harness property; the emitted supervision protocol owns whether the model or an extension/plugin continues the watcher cycle after delivering that wake.
Mechanism A cannot be a hermetic CI assertion because it requires a live model session, so it is recorded here as a dated first-hand measurement while `test_hook_secondmate_reinvoke_recovery_loop` covers the guard's deterministic half of the same recovery loop.

Autonomous-re-invoke measurement, run first-hand on Claude Code 2.1.207 (Darwin 25.5.0) on 2026-07-12.
Procedure: launch a detached `run_in_background` Bash task that models a one-shot watcher - it records a launch epoch, runs `sleep 25`, then records a completion epoch just before exit, writing only to the session scratchpad - then end the turn with no further tool calls and no pending question, a genuinely idle session with no human input.
Observed marker timestamps:

```
launch_epoch    = 1783890980   (14:16:20)   turn ends, session goes idle
complete_epoch  = 1783891005   (14:16:45)   background task exits, 25s idle
reinvoke_epoch  = 1783891016   (14:16:56)   MODEL RE-INVOKED
--------------------------------------------------------------
wake latency (task complete -> model re-invoked): 11s, with ZERO human input
```

The re-invocation arrived as a `<task-notification>` whose accompanying system notice stated verbatim "No human input has been received since the last genuine user message in this conversation".
So the model was re-invoked solely by the background task's completion while idle, which is Mechanism A - the same background-notify wake the Claude supervision protocol relies on for the main primary.
This matches the harness tool contract that a `run_in_background` task "keeps running across turns and re-invokes you when it exits", and reproduces the 11s latency the task audit measured independently on the same harness version.
No Herdr command was issued and no fleet state was touched; the experiment wrote only to the session scratchpad, which was discarded.

### 2026-07-30: the WSL2 lstart drift that made the guard cry wolf every turn

The guard's identity check used to identify a process by `ps -p <pid> -o lstart= -o command=`.
`lstart` is not stored by the kernel; `ps` computes it as boot time plus the process's start ticks.
WSL2 continually re-syncs its boot-time estimate against the Windows host clock, so the same live process yields a different `lstart` string on successive reads.
`fm_watcher_lock_matches_pid` then rejected a healthy live watcher, and this guard printed `TURN WOULD END BLIND - SUPERVISION IS OFF` on every turn while supervision was in fact running.
That is worse than a missing guard: a genuine supervision failure was indistinguishable from the constant noise.

Measured first-hand on 2026-07-30, on Linux 6.6.87.2-microsoft-standard-WSL2, against a real `bin/fm-watch.sh` started in an isolated state dir and never restarted.
Procedure: sample the watcher's identity 40 times at 1.5s intervals in both forms, then run `fm_watcher_lock_matches_pid` against the lock file the watcher itself wrote.

```
lab watcher pid=2537409
recorded pid-identity: [proc-starttime:759812 bash .../bin/fm-watch.sh]
--- OLD lstart form, 40 samples over 60s ---
     18 Thu Jul 30 11:23:31 2026 bash .../bin/fm-watch.sh
     21 Thu Jul 30 11:23:33 2026 bash .../bin/fm-watch.sh
      1 Thu Jul 30 11:23:36 2026 bash .../bin/fm-watch.sh
--- NEW /proc start-tick form, 40 samples over 60s ---
     40 proc-starttime:759812 bash .../bin/fm-watch.sh
--- fm_watcher_lock_matches_pid against the recorded lock file ---
LIVE WATCHER RECOGNISED
```

An earlier run of the same harness the same morning produced the same shape with a different split (5/20/15 across three lstart values, 40/40 identical on the new form).

Three distinct identities for one unchanging process, against one for the fix.
The identity is now derived from field 22 of `/proc/<pid>/stat`, the kernel's own start time in clock ticks since boot, which cannot drift however the wall clock moves.
`bin/fm-wake-lib.sh` owns that format, its non-Linux `lstart` fallback, and the `fm_pid_identity_matches` comparison every persisted identity must go through.
The command half of the identity comes from `/proc/<pid>/cmdline` rather than a `ps` fork, so on Linux the identity helpers execute no external program at all; that matters because `bin/fm-afk-launch.sh` computes one inside its lock-acquire window, before its cleanup trap is installed.

## Tests

`tests/fm-watcher-lock.test.sh` owns the regression for the process-identity primitive the match depends on: one live pid yields a byte-identical identity across repeated reads, the `/proc/<pid>/stat` parse survives a `comm` containing a space or a `)` on both synthetic lines and a real process, the `lstart` form stays the fallback when `/proc/<pid>/stat` is unreadable and stays locale-invariant there, a record written in the pre-change `lstart` format still matches its live owner, and dead, recycled, and start-marker-mismatched pids are all still rejected.
`tests/fm-turnend-guard.test.sh` covers the shared predicate, primary scoping (including a secondmate's own home being guarded like the main primary while its child worktrees stay exempt), `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the session-lock exemption (silent for a live rival owner, still alarming for this session and for a dead or absent holder), Pi logical-run latch behavior for no-tool and multi-tool runs, fail-open behavior without `jq`, tracked hook registration for all five harnesses, and the Grok adapter's forced-resume loop guard and permission-mode regression.
`tests/fm-stale-base.test.sh` owns the stale-base predicate itself in both directions: a behind pushed branch fires and names task, branch and remedy; a branch that contains the base, a scout, a secondmate record, an unpushed branch, a still-detached worker, and a clone with no origin remote are all silent; a missing clone, an absent `origin/<default>`, a detached HEAD carrying commits, and a local copy outside the project each report as undeterminable; the four-branch shape of the incident names exactly the three behind branches; and an acknowledgement is scoped to the base it was made at.
`tests/fm-turnend-guard.test.sh` covers the guard's half of it, and `tests/fm-fleet-sync.test.sh` covers the immediate half.
`tests/fm-unactioned-guard.test.sh` owns the unanswered-report predicate, the forced sweep's full accounting, and every limit of the captain-signed exemption: an unsigned or wrong-signature record, and a real signature lifted from another task, all fail to silence the alarm; the signed reason cannot be edited afterwards; removing the key restores the alarm rather than suppressing it; and the exemption is announced on every render and at session start.
`tests/fm-turnend-guard.test.sh` covers the guard's half - that a healthy watcher plus an unanswered report still blocks, that a report inside the grace window neither blocks nor prints, that acknowledging or exempting it goes silent, and that the supervision-alive assertion is still reported alongside it - with every offset derived from `FM_ACK_GRACE_DEFAULT` at run time rather than written down.
The default behavior suite does not invoke live language-model harnesses.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` opts into the isolated interactive Pi regression recorded above.
