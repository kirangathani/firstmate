# Where each `no-mistakes axi status` fixture in this directory came from

`bin/fm-nm-attach.sh`'s follower classifies a returned hold by re-reading `no-mistakes axi status`, so every fixture its tests read has to be the real tool's bytes.
This file records, per fixture, exactly which bytes are a capture and which are composed, because two of the five shapes cannot be captured on this machine.

Environment: `no-mistakes version v1.70.1 (9c380d4) 2026-09-07T20:47:40Z`, checked 2026-09-15.

Source read for every composed line: the clone at `projects/no-mistakes`, **at revision `v1.70.1`**, which `git rev-parse` resolves to `9c380d4` - the exact commit the installed binary reports.
That is stated because the clone's own checkout is at `ce2d749` (`v1.75.3-1-gce2d749`), five minor versions AHEAD of the installed tool, so reading its working tree would describe a renderer this machine does not run.
Every citation below was re-read with `git show v1.70.1:<path>` for that reason, and the field order, key names, and test assertions quoted are the installed version's own.

## Captured verbatim from the installed tool

| Fixture | Command | Notes |
| --- | --- | --- |
| `axi-status-no-run.toon` | `no-mistakes axi status` in a worktree on a branch with no run | stdout only; the "a new version is available" banner is stderr and is not part of the record |
| `axi-status-other-branch.toon` | `no-mistakes axi status --run 01KZH6AZ75WXZG5JKQEMFBK6EJ` from a worktree on another branch | the `other_branch_run:` key plus a leading `current_branch:`, which is the shape the follower must refuse to read as its own run |

Two further real captures are reused rather than copied, so there is one owner per set of bytes:

| Fixture | Shape it provides |
| --- | --- |
| `../nm-stall/axi-status-ci-advanced.toon` | an on-branch `run:` that reached `outcome: passed` |
| `../nm-stall/axi-status-ci-wedged.toon` | an on-branch `run:` still `status: running` with a live `ci` step |

Both were captured from a real incident; `tests/fm-nm-stall.test.sh`'s header owns their provenance.

## Composed, and why capture was impossible

`axi-status-parked.toon` and `axi-status-failed.toon` are the run block of the real `../nm-stall/axi-status-ci-advanced.toon` capture with only the terminal fields changed.

A parked run could not be captured: gate states are not durable.
Checked 2026-09-15 against `~/.no-mistakes/state.sqlite` opened `mode=ro`, `select distinct status from step_results` returns `completed`, `failed`, `pending`, `skipped`, `running`, `fixing` - and no `awaiting_approval` or `fix_review` row across all 73 recorded runs, so there is no historical parked record to render either.

Every composed line is instead a byte-exact string the tool's own test suite asserts it emits, which is a stronger source than a hand-written approximation:

| Composed line | Asserted by |
| --- | --- |
| `    review,awaiting_approval,0,183573` (steps-table row form) | `v1.70.1:internal/cli/axi_test.go` `TestWriteRunObjectShape` (line 105), which pins `    steps[2]{step,status,findings,duration_ms}:` and `    test,awaiting_approval,0,0` |
| `gate:`, `  step: review`, `  status: awaiting_approval`, `  summary: 1 blocking issue`, `  findings[1]{id,severity,file,action,description}:` and its row | `v1.70.1:internal/cli/axi_test.go` `TestWriteGateShape` (line 348), which pins each of those strings including the finding row's quoting |
| the `note:` text on a review gate | `v1.70.1:internal/cli/axi_render.go` `gateFieldsWithHelp` (line 538) emits it verbatim when the gate step is `review` |
| the gate block's field ORDER, and that a gated run emits no `outcome:` | the same function builds step, status, summary, risk, note, findings in that order; `v1.70.1:internal/cli/axi_query.go` line 107 emits `outcome:`/`error:` only in the `else if terminalStatus(...)` arm, never alongside a gate |
| `outcome: failed` followed by `error: "..."` | the same arm, lines 108-111, which appends `error` immediately after `outcome` and only when the run carries one |
| the `run:` vs `other_branch_run:` key choice, and that only the foreign case carries a leading `current_branch:` | `v1.70.1:internal/cli/axi_query.go` lines 84-88 |

Neither composed fixture carries a `help[...]:` block.
The follower never reads one, and copying the tool's help text here would add bytes nothing asserts and that change with every release.
