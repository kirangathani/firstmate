# Where each `no-mistakes axi status` fixture in this directory came from

`bin/fm-nm-attach.sh`'s follower classifies a returned hold by re-reading `no-mistakes axi status`, so every fixture its tests read has to be the real tool's bytes.
This file records, per fixture, exactly which bytes are a capture and which are composed, because two of the five shapes cannot be captured on this machine.

Environment: `no-mistakes version v1.70.1`, checked 2026-09-15.
Source read for every composed line: the clone at `projects/no-mistakes`, at the commit installed as v1.70.1.

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
| `    review,awaiting_approval,0,183573` (steps-table row form) | `internal/cli/axi_test.go` `TestWriteRunObjectShape`, which pins `    test,awaiting_approval,0,0` |
| `gate:`, `  step: review`, `  status: awaiting_approval`, `  summary: ...`, `  findings[1]{id,severity,file,action,description}:` and its row | `internal/cli/axi_test.go` `TestWriteGateShape`, which pins each of those strings including the finding row's quoting |
| the gate block's field ORDER, and that a gated run emits no `outcome:` | `internal/cli/axi_render.go` `gateFieldsWithHelp` builds step, status, summary, risk, note, findings in that order; `internal/cli/axi_query.go` emits `outcome:`/`error:` only in the `else if terminalStatus(...)` arm, never alongside a gate |
| `outcome: failed` followed by `error: "..."` | the same `axi_query.go` arm, which appends `error` immediately after `outcome` and only when the run carries one |

Neither composed fixture carries a `help[...]:` block.
The follower never reads one, and copying the tool's help text here would add bytes nothing asserts and that change with every release.
