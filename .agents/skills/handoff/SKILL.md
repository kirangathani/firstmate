---
name: handoff
description: Write a handoff document for the next instance of this firstmate session, arm it so the fresh context is pointed straight at it, and hand the captain the reset. Use when the captain invokes /handoff (e.g. "/handoff", "write a handoff and clear"), when this session is degraded, bloated, or repeatedly wrong and should be reset, or before any planned restart of this session.
user-invocable: true
metadata:
  internal: true
---

# handoff

Write down everything about the CURRENT work that would die with this conversation, point the next session at it, then tell the captain to reset.

A firstmate session's conversation is the only place some knowledge lives.
Fleet state reconstructs itself at session start from `state/`, `data/backlog.md` and the backends; the reasoning behind it does not.
When this session ends - deliberately or because the machine reboots under it - anything not on disk is gone.
This skill is how that stops being a loss.

A reset you choose gives you time to write this; a crash does not.
So do not treat `/handoff` as strictly a pre-reset ritual: when a stretch of work has produced reasoning that would be expensive to rediscover, write it down then, at the next natural breakpoint, rather than banking on getting a graceful exit.
`docs/handoff.md` records the reboot that made this concrete.

## Boundary with `/stow` - read this before doing anything

`/stow` and `/handoff` sweep the same conversation and must not both file the same finding.
The split is by lifetime, not by topic:

- **Durable knowledge belongs to `/stow`.** Anything still true next month - a captain preference, a fleet-local gotcha, a project-intrinsic fact, an undone next step that deserves a backlog item.
  `/stow` owns the sweep and the routing table for these.
  Do not re-derive that routing here and do not copy durable facts into the handoff instead of filing them.
- **Volatile working state belongs to `/handoff`.** Anything true only until the current work lands - what each in-flight task is actually doing and why, decisions made this session and the reasoning behind them, a diagnosis in progress, a trap that disappears when the fix merges, what was tried and rejected.
  This material must NOT be curated into permanent memory: it is obsolete the moment the work lands, and filing it as a learning would rot.

So step 1 below runs `/stow` and step 2 writes only what `/stow` deliberately does not keep.
A fact that fails the "still true next month" test goes in the handoff; one that passes goes to `/stow`'s destinations, and the handoff cites it by location rather than restating it.

## Procedure

1. **Run `/stow` first.**
   Load the `stow` skill and complete its sweep, so every durable finding is routed to its real home before you write anything volatile down.
   Whatever `/stow` reports it could not capture is a candidate for the handoff.

2. **Get the path, then write the document.**

   ```sh
   bin/fm-handoff.sh path            # prints the next unused data/HANDOFF-<date>[-sessionN].md
   ```

   Write the file at exactly that path.
   It lands under `data/`, which is gitignored and firstmate-private: never write a handoff into a project clone or into tracked repo material.

   Content is judged by one test, and only this test: **would the next instance make a worse decision without this line?**
   If not, cut it.
   The sections that have actually proved useful, in the order they proved useful:

   - **Reliability warning, when it applies.**
     If this session was degraded, repeatedly wrong, or working from measurements it later disproved, say so at the top and say which parts to distrust.
     A successor that trusts bad reasoning is worse off than one with no handoff at all.
   - **The through-line.**
     The one thread that explains why the rest of the session happened, in one short section.
   - **Captain decisions made this session, marked binding.**
     State the decision AND the reasoning, because the reasoning is what stops a successor reopening a settled question.
   - **In flight.**
     Per task: what it is really doing, what gates it, and what it must not do.
     Only what `state/<id>.meta` and the backlog cannot already say.
   - **Blocked, needs the captain.**
     Each with the exact evidence, and the exact command or credential that unblocks it.
   - **Traps.**
     Live false alarms, known-bad signals, and how to tell a real one from a false one.
     This is usually the highest-value section, because it is what stops the successor repeating this session's wasted work.
   - **Measured facts.**
     Numbers you actually measured, and explicitly which theories the data killed.
     Never record a plausible cause as a measured one.
   - **File pointers.**
     Where the plan, report, evidence or branch lives, by path.
     Point; do not restate.

   Two rules on content:

   - Separate FACT (with evidence), captain DECISION (attributed), and OPEN question.
     Never let an open question read as settled.
   - Uncommitted work is not state, it is a liability.
     Before writing the handoff, confirm each in-flight task's work is committed to its branch, and record by name and SHA any branch holding unpushed commits.
     A reset loses the conversation; a reboot loses everything that was not committed or written down.

3. **Arm it.**

   ```sh
   bin/fm-handoff.sh arm <the file you just wrote>
   ```

   This marks the handoff unread, so the next session start in this home is pointed straight at that exact file.
   Do not skip this: an unarmed handoff is a document nobody is told to read.

4. **Hand the captain the reset.**
   Tell them plainly, in outcome language, what the handoff covers and that they should now type `/clear` themselves.
   **You cannot run `/clear`.** It is a Claude Code CLI built-in handled by the harness, not a tool available to you, and there is no supported way to trigger it from a skill.
   Never claim to have cleared the context, and never try to fake it by sending keys to your own session.

## What the next session does

Nothing, by hand.
`/clear` restarts the session, `bin/fm-handoff.sh pickup` runs as a `SessionStart` hook and injects the pointer to that exact file, and the fresh instance reads it, runs `bin/fm-handoff.sh consume`, and continues into the normal session start.
The pointer fires on a plain startup too, so a handoff also survives a crash or a reboot rather than only a deliberate `/clear`.
`bin/fm-handoff.sh`'s header owns the mechanism; `docs/handoff.md` holds the verification evidence.

If you are the session that just received such a pointer: read the file first, `consume` it, and only then run `bin/fm-session-start.sh`.
