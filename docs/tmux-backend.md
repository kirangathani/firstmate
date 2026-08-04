# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, Orca, or cmux) - it is the fully verified reference path for secondmate homes, while Orca and cmux are the backends that do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Endpoint existence probe: `display-message` is not one (2026-08-03)

`tmux display-message -p -t <session>:<window-name>` does **not** fail on an unmatched window name.
It silently falls back to the session's current window and exits 0, so a probe that only reads its exit status reports every window name as alive as long as the session exists.
Verified with real tmux 3.4 on Linux (WSL2), 2026-08-03, in a session holding only the window `fm-real`:

```sh
$ tmux display-message -p -t 'fmtest:fm-bogus' '#{pane_id} #{window_name}'
%41 fm-real
rc=0
$ tmux display-message -p -t 'fmtest:=fm-bogus' '#{pane_id} #{window_name}'
%41 fm-real
rc=0
$ tmux display-message -p -t '%9999' '#{window_name}'

rc=0
```

The `=` exact-match prefix does not help, and a stale pane id is accepted the same way.
Consequence while `fm_backend_target_exists` used that command: the session-start fleet digest and `bin/fm-fleet-snapshot.sh` reported every task in an existing session as `endpoint: alive`, so a dead ordinary crewmate was undetectable there (observed 2026-08-03: six tasks reported alive while one window existed).

`tmux list-panes -t <target>` resolves the target through tmux's own parser and fails loudly, which is why it is now the primitive (`fm_backend_tmux_target_exists`, `bin/backends/tmux.sh`).
Same session and version:

```sh
$ tmux list-panes -t 'fmtest:fm-real'     ; echo rc=$?   # rc=0
$ tmux list-panes -t 'fmtest:fm-bogus'    ; echo rc=$?   # can't find window: fm-bogus     rc=1
$ tmux list-panes -t 'nosuchsess:fm-real' ; echo rc=$?   # can't find session: nosuchsess  rc=1
$ tmux list-panes -t '%9999'              ; echo rc=$?   # can't find pane: %9999          rc=1
```

Existence is that exit status, never the emptiness of `list-panes`' output.
A live pane whose window name is the empty string prints an empty line at rc=0, so treating empty output as "gone" would report a healthy pane dead.
Verified with real tmux 3.4 on Linux (WSL2), 2026-08-03:

```sh
$ tmux rename-window -t %0 ''
$ tmux list-panes -t %0 -F '#{window_name}' ; echo rc=$?   # (empty line)  rc=0
```

False negatives are the worse direction here.
A spurious "gone" verdict licenses `bin/fm-bootstrap.sh`'s secondmate sweep to kill and respawn a live agent, and aborts the away-mode daemon's startup on a live supervisor pane.
The expected-label comparison is therefore applied only when the caller passed a non-empty label.

It was preferred over enumerating `tmux list-windows -t <session> -F '#{window_name}'` and matching, because enumeration makes the caller split the target back into session and window, and tmux window names may themselves contain `:` (a target may equally be a pane id, a window id, or `session:window.pane`).
`list-panes` needs no splitting: rc=0 was confirmed the same session for pane-id, window-id, bare-session, and `session:index.pane` targets, so there is no false-negative shape to trip over.

One residual sharp edge is covered by the optional expected-label argument: tmux target matching is a unique-prefix match, so `fmtest:fm-re` resolves to `fm-real` when that prefix is unambiguous.
Callers that know the owning task label (the digests pass `fm-<id>`) require the resolved `#{window_name}` to equal it exactly, mirroring the zellij and cmux arms; callers with no label (`bin/fm-send.sh`'s explicit-target escape hatch, the away-mode daemon's supervisor pane) keep tmux's own resolution, which for them is the very window tmux would act on.

Regression coverage lives in `tests/fm-backend-tmux-smoke.test.sh`, the one suite that talks to a real tmux server.

### The exact-label check needs a pinned window name to be safe

An exact `#{window_name}` comparison is only sound while the name cannot drift.
`fm_backend_tmux_create_task` (`bin/backends/tmux.sh`) pins it by turning `automatic-rename` and `allow-rename` off on the new window, and that pin is now a HARD requirement: if either option cannot be set, the freshly created window is killed again and the spawn is refused with an error, rather than leaving behind a window whose name no reader can trust.
Both options were confirmed settable through `set-window-option` on real tmux 3.4 (Linux, WSL2, 2026-08-03).

`bin/fm-spawn.sh` records that guarantee in the task meta as `tmux_window_pinned=1`, written for tmux spawns only.
Readers ask `fm_backend_expected_label_of_meta` (`bin/fm-backend.sh`) for the label to pass, and it returns `fm-<id>` only when the record carries the guarantee.
A tmux meta written before the pin became mandatory returns an empty label and so reads through tmux's own resolution, unchanged from before the label existed.
That asymmetry is deliberate: demanding an exact name match on a record whose window may legitimately have been renamed would report a LIVE crewmate as dead in the session-start digest, the fleet snapshot, `bin/fm-crew-state.sh`, and the secondmate sweep all at once, which is the worse direction.
Every other backend pins its label by construction, so the helper always returns the label for them.

The one place the label matters most is the secondmate liveness sweep (`bin/fm-bootstrap.sh`), the only probe whose verdict acts destructively.
Without it, a gone secondmate `sm` prefix-resolves to a live task's window `fm-sm-2` and inherits that task's verdict: either the dead secondmate is never respawned, or the sweep kills the unrelated task's window.
The sweep therefore also guards its kill on the endpoint still resolving to the secondmate's own window, so a target it could not verify is respawned without anything being killed.

Leniency stops at that destructive path.
An empty label means the record's endpoint identity is UNVERIFIED, not that it may be acted on with tmux's own resolution: a target that resolves may be a neighbour reached by prefix matching rather than the secondmate's own window, and the guard would pass on exactly the ambiguity it exists to refuse.
So when the sweep reaches a `dead` verdict for a record carrying no pin guarantee, it skips the kill AND the respawn and reports the record instead (`SECONDMATE_LIVENESS: secondmate <id>: skipped: endpoint identity unverifiable`).
Nothing backfills the guarantee onto an existing record; respawning that secondmate deliberately writes it, since every tmux spawn now pins the window name or refuses.
The other readers stay lenient as described above, because reporting an unpinned record's endpoint state is not a destructive act.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).
The 2026-07-30 U+00A0 composer incident was reproduced and fixed on this backend but is owned by [Incident (2026-07-30): claude pads its prompt glyph with U+00A0](herdr-backend.md#incident-2026-07-30-claude-pads-its-prompt-glyph-with-u00a0-so-every-empty-claude-composer-read-as-pending-input).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

The classifier resolves the target strictly (through `fm_backend_tmux_target_exists`) before reading any command name, because `#{pane_current_command}` comes from `display-message` and would otherwise answer from a neighbouring window for a target that no longer exists (see the section above).
It takes the same optional expected-label as that primitive and passes it straight through, so a caller with a pinned record gets the exact-name check on this path too.
A structurally-gone window maps to `dead`, the same mapping herdr's arm already uses for a structurally-gone pane; if the tmux server itself did not answer, nothing was confidently read and the verdict stays `unknown`, so a momentary server glitch can never license a respawn.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Limitations

None specific to tmux for the reference path itself - it is the fully verified reference backend, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above has one known gap (`pi`'s generic `node` process name, see above).
