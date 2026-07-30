# Session handoff and post-`/clear` pickup

This is the reference and verification record for the `/handoff` skill (`.agents/skills/handoff/SKILL.md`) and `bin/fm-handoff.sh`.
The skill owns what goes in a handoff document, and the script's header owns the mechanism.
This file records the empirical evidence behind the pickup path and the decisions that shaped it.

## The problem

A firstmate session's conversation holds knowledge that exists nowhere else.
Fleet state reconstructs itself at session start; the reasoning behind it does not.

This is not hypothetical.
On 2026-07-30 at 14:31 this machine rebooted and killed the fleet mid-flight, the second such loss that week.
Seven workers and every in-flight pipeline run were lost.
What survived was exactly two things: work committed to a branch, and what firstmate had written down.
Nothing from any agent conversation survived.

That sets the bar for the pickup mechanism.
It must be durable on disk, and it must fire on an unplanned restart rather than only on a deliberate `/clear`.

## Why the pickup is a `SessionStart` hook

`/clear` is a Claude Code CLI built-in handled by the harness UI.
It is not a tool the model can call, so no skill can execute it, and no skill runs after it.
The only thing that runs after `/clear` is a hook.

Claude Code re-fires `SessionStart` when the context is cleared, with a `source` discriminator distinguishing it from a cold start.
`bin/fm-handoff.sh pickup` is registered in the tracked `.claude/settings.json` as that hook and emits the pointer as `hookSpecificOutput.additionalContext`.

The hook is registered with **no matcher** deliberately.
Restricting it to `source: "clear"` would cover only the deliberate reset and miss the reboot case above, which is the case a handoff matters most for.
With no matcher it also fires on `startup` and `resume`, and the script's own unread check keeps it silent whenever there is nothing to announce.

## Verification (Claude Code 2.1.220, 2026-07-30, WSL2 Ubuntu)

Static confirmation, from the installed binary at `/home/kiran/.local/share/claude/versions/2.1.220`: the `SessionStart` hook executor is invoked from four call sites, one of them literally `HBe("clear")`, alongside `"compact"`, `"fork"`/`"resume"`, and the startup path.

Runtime confirmation is the load-bearing evidence.
A scratch project directory registered a `SessionStart` hook that logged its stdin payload and emitted a fixed marker as `additionalContext`.
A real `claude` session was launched in it under tmux, then `/clear` was typed into the session.

Both firings were observed, in order:

```
=== fired 14:37:58
{"session_id":"d6d21645-...","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}
=== fired 14:38:15
{"session_id":"fb975bbf-...","hook_event_name":"SessionStart","source":"clear"}
```

Three facts this establishes:

1. `SessionStart` does fire on `/clear`, with `source: "clear"`.
2. `/clear` mints a new `session_id`, so the post-clear context is genuinely fresh rather than a continuation.
3. The injected `additionalContext` reaches the model.
   Asked to echo the marker it had been given, the post-`/clear` instance replied with it exactly (`PROBE_CONTEXT_MARKER_ZQ7`).

Point 3 is the one worth re-running if this is ever revisited.
A hook that fires but whose output is dropped would look identical in the log.

### End-to-end, with the real script

The probe above proves the harness mechanism; this run proves this script's own output lands.
A firstmate-home-shaped sandbox (`bin/fm-handoff.sh`, `data/`, `state/`, and the same tracked hook registration) had a handoff written and armed, then a real `claude` session was launched in it and `/clear` typed.

Asked which file, if any, it had been told to read before anything else, the post-`/clear` instance answered with the exact armed path and nothing else:

```
❯ /clear
❯ What file, if any, have you been told to read before anything else? …
● …/homelab/data/HANDOFF-2026-07-30.md
```

The handoff was then consumed with `fm-handoff.sh consume` and the same session cleared again.
Asked whether its context contained the string `UNREAD HANDOFF`, it answered `NO`.
So the pickup is specific rather than a generic nudge, and a consumed handoff genuinely stops announcing.

## The unread marker, and why the reader clears it

`arm` writes one absolute path to `state/.handoff-unread`.
`pickup` announces while that marker exists, and `consume` removes it.

`pickup` deliberately does not clear the marker itself.
If it did, a session that is announced to and then dies before reading anything would lose the handoff outright, which is precisely the failure this path exists to prevent.
So the marker means "not yet read by anyone" rather than "not yet announced".
The pointer repeats until some session actually reads the document and calls `consume`, and a consumed handoff never announces again.

A marker pointing at a deleted file is self-healing: `pickup` clears it and stays silent, so a hand-deleted handoff cannot wedge every future session start.

## Scoping

No harness-side scoping is needed or used.
The tracked `.claude/settings.json` is checked out into every worktree of this repo, including crewmate and scout task worktrees, but `state/` is gitignored and absent in those, so `pickup` exits silently there.
A real firstmate home, meaning the main home or a secondmate's own home, has `state/`, and each announces only its own handoff.

## Harness coverage

This pickup path is Claude-specific, because `/clear` is.
Other harnesses have their own reset shapes and their own hook surfaces; wiring them is a separate task and needs its own verification record in this file, produced the same way.
The document half of `/handoff` is harness-independent: `bin/fm-handoff.sh path` and `arm` work anywhere, and any session that reads `state/.handoff-unread` gets the same pointer.
