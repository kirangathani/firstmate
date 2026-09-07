# tests/fixtures/timeline

Verbatim captures, taken 2026-09-07 on the captain's fleet. Nothing here is hand-written.

- `schema.sql` - the exact DDL of the four no-mistakes tables `bin/fm-timeline.sh` reads,
  captured with
  `sqlite3 "file:$HOME/.no-mistakes/state.sqlite?mode=ro" ".schema repos" ".schema runs" ".schema step_results" ".schema agent_invocations"`
  on the live database (no-mistakes state.sqlite, 11046912 bytes).
  The suite builds its fixture database from this file, so a column the real schema
  does not have cannot be asserted against here.
- `pr-view.json` - the exact stdout of
  `gh pr view 63 --repo kirangathani/firstmate --json createdAt,mergedAt,headRefOid`.
- `check-runs.json` - the exact stdout of
  `gh api repos/kirangathani/firstmate/commits/420139300feeeb0948bfeaed6cd56a3c858bc500/check-runs`,
  the head of that same PR, with all 12 of its check runs.

The fake `gh` in `tests/fm-timeline.test.sh` serves these two payloads through the REAL
`jq` and the REAL `--jq` expression the script passes, so the ISO-8601-to-epoch conversion
is exercised against bytes GitHub actually returned rather than against an idea of them.
