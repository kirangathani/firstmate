---
name: reset-accounts
description: Reset every tracked Claude Code agent instance onto a newly-logged-in Claude account so they pick up the new limits/credits. Use when the captain says they switched accounts, logged into a different Claude account, reset accounts, or when agents are stalling/freezing on spend-limit or usage-limit dialogs and the captain has tokens available on a new account.
---

# reset-accounts

The captain has logged into a **different Claude account** which has tokens/credits available.
Every Claude Code agent instance firstmate is following is still stuck on the old account's exhausted limits, either sitting idle or frozen on a usage/spend-limit dialog.
This skill resets each instance so it picks up the new account and its new limits.

## The core mechanic

A stalled instance recovers when it is given a trivial input to process: send a single `.` and Enter, and it re-authenticates against the currently-configured account and resumes.

The complication is that some instances are **blocked at a decision point** (a modal dialog) and will not accept a plain `.` while that dialog owns the input. For those, **press Escape first** to back out of the decision, *then* send the dot.

## Protocol

1. **Enumerate every tracked agent session.** `tmux ls`, cross-referenced with the windows firstmate is actually supervising. Do not touch sessions outside firstmate's tracked set.

2. **Classify each pane** by capturing it (`tmux capture-pane -t <session> -p`) and looking for a blocking decision point. Dialog signatures include:
   - `What do you want to do?`
   - `Adjust monthly spend limit`
   - `Wait for limit to reset`
   - `Upgrade to Max` / `Upgrade your plan`
   - `Enter to confirm · Esc to cancel`
   - `Press → to raise the limit`
   - `You've hit your monthly spend limit`

3. **Reset each instance:**
   - **If a blocking dialog is present:** send `Escape` first (backs out of the decision without answering it), wait ~1s, then send `.` + Enter.
   - **If no dialog:** just send `.` + Enter.

   ```sh
   # blocked at a decision point
   tmux send-keys -t <session> Escape; sleep 1; tmux send-keys -t <session> "." Enter
   # not blocked
   tmux send-keys -t <session> "." Enter
   ```

4. **Verify recovery.** Wait a few seconds, re-capture every pane, and confirm each instance is back at a normal prompt or actively working, with no dialog and no limit error.

5. **Report** which instances recovered and which are still stuck. For any still stuck, surface it to the captain — do not keep hammering it.

## HARD RULE: never make the financial decision

Escape **avoids** the decision; it does not answer it.
Firstmate must **never**:
- adjust or raise a monthly spend limit,
- remove a spend limit (`Del`),
- upgrade a plan.

Those are the captain's money and his call alone. If Escape + dot does not clear an instance, escalate it to the captain with what the dialog is asking, and let him decide.

## Notes

- The account the instances resolve to is whatever is currently configured; confirm it if the captain asks (`emailAddress` in `~/.claude.json`).
- Instances that were mid-task generally resume their work; ones whose context was wiped by the limit may come back at 0% context — check whether they still hold their task, and re-brief or hand off if not.
- After resetting, re-arm firstmate's supervision (poller / watchers) as normal, since a stalled fleet may have left wakes unhandled.
