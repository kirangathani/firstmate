# The fleet pipeline view

A captain-facing instrument that renders every agent's no-mistakes pipeline as one horizontal row per agent.
It is not part of the supervision loop: the captain runs it as a plain command, and firstmate never opens it.

`bin/fm-nm-flow.sh` remains the single-task detail view and is unchanged by this work.

The view is split across two programs so that neither can drift into the other's job.

- `bin/fm-flow-snapshot.sh` owns data.
  It performs every outside read and emits one JSON document.
  This document is the single owner of that wire format.
- `bin/fm-flow-tui.mjs` owns pixels and input.
  It reads the JSON on stdin and shells out to nothing.

That seam is what makes golden-frame tests possible: a renderer that cannot read the world can be fed exact recorded bytes and asserted against an exact frame.

## Resolving which pipeline run belongs to which agent

This is the part that is easy to get wrong, and the reasoning matters more than the code.

`no-mistakes axi status` resolves the **active or most recent run for the repository**, not the run belonging to the worktree it is invoked in.
Its own `--help` says so, and it is directly observable.

Evidence, 2026-08-08, no-mistakes v1.37.0:

```
$ cd /home/kiran/.treehouse/firstmate-16c429/12/firstmate   # detached HEAD
$ no-mistakes axi status | grep branch
  branch: fm/lint-cache-shared-w8

$ cd /home/kiran/projects/gits/firstmate                    # on the default branch
$ no-mistakes axi status | grep branch
  branch: fm/lint-cache-shared-w8
```

Two different worktrees, neither of them checked out on `fm/lint-cache-shared-w8`, both answering for it.
At the same moment the daemon held ten runs in `running` state across ten different branches.
So a collector that ran `axi status` once per worktree would draw the identical pipeline on every row of the fleet.

`no-mistakes axi status --run <id>` does scope correctly, from any directory inside the repository, in about 90ms.
The remaining problem is obtaining `<id>`, because no command emits one:

- `no-mistakes runs` lists status, branch, head, and timestamp, but not the run id, and has no flag to add it.
- `no-mistakes axi` has exactly five subcommands (`abort`, `logs`, `respond`, `run`, `status`), none of which enumerate runs.
- `--run` accepts only the ULID.
  A head SHA or a branch name is refused with `run "<value>" not found`.

Release notes for v1.38.0 through v1.45.4 add no run id to `runs` output and no branch filter.
The closest change, v1.40.0 "reattach active AXI runs by submitted head", exposes the submitted head SHA to `axi run` for its own reattachment and not to an outside observer.

### Why the run id is not recorded by the worker

The obvious alternative is to have each crewmate write its run id into `state/<id>.meta` when it starts validation.
That is rejected on the captain's standing test: could the entity being checked have produced the thing being checked?
It could.
A worker that restarted, or that drove no-mistakes twice, would record an id that no longer describes the pipeline the view is drawing, and the view would present it with total confidence.
Self-reported identity is bookkeeping, not a boundary.

### What is read instead

The branch is the key, and it is already a contract rather than a report.
`bin/fm-brief.sh` scaffolds `git checkout -b fm/$ID`, git refuses to check one branch out in two worktrees of a repository, and `bin/fm-crew-state.sh` already keys run attribution on `fm/<id>` for the same reason after the 2026-07-30 recycled-slot incident.

So `bin/fm-flow-snapshot.sh` resolves the run id from the daemon's own database, which the worker cannot forge:

```
/home/kiran/.no-mistakes/state.sqlite
```

That file is local to the host, holds one row per repository in `repos`, and is opened **read-only**.
`repos.working_path` records the primary checkout, so worktrees do not fragment it, and it matches the `project=` value already present in `state/<id>.meta` without any transformation.

The read is deliberately confined to a run index, three columns wide:

```sql
SELECT r.id, r.status, r.updated_at
  FROM runs r JOIN repos p ON p.id = r.repo_id
 WHERE p.working_path = ?1 AND r.branch = ?2
 ORDER BY r.created_at DESC LIMIT 1;
```

Every fact that reaches the screen - step names, statuses, finding counts, durations - is then read through `no-mistakes axi status --run <id>`, the documented CLI.
`step_results` is never read.
That table is a private undocumented schema and the installed binary is eight minor versions behind current, so the risk of it changing is real; the run index is the smallest surface that solves the problem.

### The stale `running` trap

`runs.status` records the last state written, not whether anything is running now.
On 2026-08-08 ten firstmate runs were marked `running` and four had not been touched in five to nine days, the oldest last updated 2026-07-30.
Those are workers that died without finalising their run.

A collector that trusted the column would animate four dead pipelines forever, which is exactly the class of lie the data-age display exists to prevent.

Two mechanisms keep it honest, and neither is a staleness threshold.
A timestamp cutoff was considered and rejected: a legitimately parked run also sits still for hours, so a cutoff misclassifies it.

1. The agent list comes from `bin/fm-fleet-snapshot.sh`, so a torn-down task never appears at all, whatever its abandoned row still claims.
2. For a task that is still present, the snapshot emits the run's `updated_at` age and the task's endpoint liveness as separate fields, and the renderer draws a live-looking state only when the fleet still considers that worker alive.

## Wire format

Schema id `fm-flow-snapshot.v1`, emitted by `bin/fm-flow-snapshot.sh --json`.
Exact fields, flags, and environment knobs are owned by that script's header and `--help`; this section owns the shape and the guarantees.

```json
{
  "schema": "fm-flow-snapshot.v1",
  "generated": "2026-08-08T16:30:00Z",
  "generated_epoch": 1786000000,
  "fm_home": "/home/kiran/projects/gits/firstmate",
  "agents": [
    {
      "id": "fm-eager-dispatch-e2",
      "branch": "fm/fm-eager-dispatch-e2",
      "project": "/home/kiran/projects/gits/firstmate",
      "worktree": "/home/kiran/.treehouse/firstmate-16c429/1/firstmate",
      "window": "firstmate:fm-fm-eager-dispatch-e2",
      "kind": "ship",
      "mode": "no-mistakes",
      "endpoint_alive": true,
      "pr": { "url": "https://github.com/kirangathani/firstmate/pull/25", "number": 25 },
      "collection": { "ok": true, "reason": "", "at": "2026-08-08T16:30:00Z", "epoch": 1786000000 },
      "run": {
        "present": true,
        "id": "01KZETHEHPT5RQFB14A83FMZCK",
        "status": "running",
        "head": "bb73f233",
        "findings": "2 info",
        "db_updated_epoch": 1785999000,
        "db_age_seconds": 1000
      },
      "steps": [
        { "step": "intent", "status": "completed", "findings": 0, "duration_ms": 22 }
      ],
      "active_steps": [
        {
          "step": "ci",
          "status": "running",
          "active_for": "18h32m",
          "last_activity": "37s ago: log: warning: could not check CI",
          "round": "starting"
        }
      ],
      "ci": {
        "collection": { "ok": true, "reason": "" },
        "checks": [
          { "workflow": "CI", "name": "Lint shell scripts", "status": "COMPLETED", "conclusion": "SUCCESS" }
        ],
        "total": 11, "passed": 11, "failed": 0, "pending": 0
      }
    }
  ]
}
```

Guarantees the renderer is entitled to rely on:

- `steps` carries all nine no-mistakes steps in pipeline order whenever `collection.ok` is true, using the tool's own step names.
  Folding `push` and `pr` into one box is a rendering decision and is not done here.
- Step `status` strings are passed through verbatim, never mapped.
  Mapping a status onto one of the five display states is the renderer's job and is asserted exhaustively in its own tests, so a status this script has never seen still reaches the renderer intact rather than being flattened here.
- `collection.ok` false means the read failed or timed out.
  `steps` is then empty and the renderer must draw the agent as unknown, never as pending and never as its last-known state.
  These are different claims: pending reads as "not started yet", which is a fact this snapshot does not have.
- `ci.collection` is separate from the agent's `collection`, because a GitHub read can fail while the local read succeeds.
- `run.present` false means no pipeline run exists for that branch, which is the ordinary state of a task that has not yet started validating.

## Cost

Measured 2026-08-08 on this host, no-mistakes v1.37.0.

| Read | Cost | Cadence |
|---|---|---|
| `no-mistakes axi status --run <id>` | 91ms | local, fast cadence |
| run-index query against `state.sqlite` | under 10ms | local, fast cadence |
| `gh pr view --json statusCheckRollup` | 500 to 630ms | network, slow cadence |
| `bin/fm-fleet-snapshot.sh --json`, one-task home | 664ms | slow cadence |

The local reads are roughly two orders of magnitude cheaper than the 10s worst-case timeout `bin/fm-nm-flow.sh` budgets for them, so the two-cadence split exists to spare GitHub rather than to spare the daemon.

The cost of `bin/fm-fleet-snapshot.sh` at real fleet size is not yet recorded here.
At the captain's fleet size that command currently fails outright, tracked separately; the 664ms above is a one-task fixture home and is not a fleet-scale figure.

## Verification evidence

Facts in this document were established by running the commands shown, on 2026-08-08, against no-mistakes v1.37.0 (78e4dcb) with the daemon running.
CI check names on this repository are not unique: `CI testing waiver` appears under both the `CI` and `Require no-mistakes` workflows on PR 25, so checks are keyed on workflow plus name.
The no-mistakes version-update banner is written to stderr, so stdout parsing does not need to strip it.
