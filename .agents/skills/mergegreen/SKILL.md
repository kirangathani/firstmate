---
name: mergegreen
description: Land every open task PR that is genuinely green, one at a time, through every existing pre-merge gate. Use when the captain invokes /mergegreen, says "merge the green ones", "land everything that's ready", "force the green PRs through", or asks for the merge switch. It merges only what the gates pass, never bypasses one, and steers at most one worker per run when main has moved under its branch.
user-invocable: true
metadata:
  internal: true
---

# mergegreen

The captain's mechanical merge switch.
There is no judgement step in this skill: the gates decide, and this reports what they decided.

## What to do

1. **Run the switch.**

   ```
   bin/fm-merge-green.sh
   ```

   Add `--dry-run` only if the captain asked what it would do rather than to do it, and task ids only if the captain named specific work.
   Do not add any other flag, do not merge anything by hand, and do not re-run a candidate the switch refused.
   `bin/fm-merge-green.sh`'s header owns the order, the gates, the serial queue, and every outcome word.

2. **Relay the summary.**
   One line per candidate, in the captain's language, with the full `https://...` URL for every PR.
   Lead with what landed, then what did not and why.
   Translate the table's outcome words per `AGENTS.md` section 9 - they are internal labels:

   - `merged` - landed on main.
   - `already-merged` - was already landed before this run.
   - `needs-main-merge` - main moved under it, so its checks measured a base that no longer exists; its worker was told to bring the branch onto the new main and re-verify. Say which worker, and that the run stopped there deliberately so no other branch pays a second update cycle.
   - `queued-behind` - waiting for the branch above it; nothing was asked of it.
   - `not-green` - a check on the PR is failing, unfinished, or unreadable, so it is not ready.
   - `refused-tests-kept` - a test the base already had is missing or failing on the branch. If the branch is deliberately changing that behaviour, that is the captain's decision to make; say so and give the assertion names from the run's output.
   - `refused-attribution`, `refused-merge-resolution`, `refused-unverified`, `closed`, `unreadable` - name the concrete problem from the run's output; none of these is something to retry.
   - `would-merge` (dry run only) - it looks ready; only a real run puts it through every gate.

3. **Say what needs the captain.**
   A `refused-tests-kept` that is a deliberate behaviour change, and anything the switch could not verify, are the captain's to answer.
   Everything else is either landed, waiting on a worker, or waiting on CI.

Then carry on with the ordinary lifecycle for anything that landed.
