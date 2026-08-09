# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
Dependency bots are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:kunchenguid/firstmate.git`).
2. Create a branch and make your changes.
3. Initialize the gate with your fork as the push target: `no-mistakes init --fork-url git@github.com:<you>/firstmate.git` (firstmate expects **no-mistakes v1.31.2+**; without a fork, plain `no-mistakes init` still works for maintainers with push access).
4. Commit your changes.
5. Push through the gate instead of pushing to `origin`:

   ```sh
   git push no-mistakes
   ```

6. Run `no-mistakes` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed no-mistakes version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch to your fork and opens the PR against the parent repo for you.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled firstmate skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces firstmate's routine backlog updates to hand-editing and stays gitignored; validated secondmate handoffs still delegate through `tasks-axi mv`.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, and pinned shellcheck version), and both CI and the no-mistakes pre-push gate run it, so local and CI can never diverge.
  It pins one exact shellcheck version and refuses to run under any other; print it with `bin/fm-lint.sh --required-version` and install that build locally.
  It shards the file set and caches clean results under the shared git common dir, so every worktree of one clone reads and writes one cache: an unchanged tree costs well under a second, and a fresh linked worktree is served from what another worktree already linted instead of starting cold.
  Only a genuinely cold cache - a fresh clone, or CI, which never inherits one - pays about half of what the old single command did.
  The script's usage header owns the cache location and the `FM_LINT_CACHE_DIR` and `FM_LINT_NO_CACHE` escape hatches.
  If you change how it plans, shards, or caches, run `bin/fm-lint.sh --verify-parity`: it runs the canonical single-process command (`bin/fm-lint.sh --whole-set`) against the fast path and fails on any difference in findings.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) need empirical adapter notes in the relevant backend guide: `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, `docs/cmux-backend.md`, or `docs/codex-app-backend.md` for blocked Codex App transport work.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: `ask-user` findings route to the captain through firstmate, and crewmates avoid `--yes` because it silently resolves captain-owned decisions without escalation.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory and pins the gate's lint and portable behavior commands to the Linux CI jobs, while `.github/workflows/ci.yml` owns additional platform-specific compatibility lanes.
That is firstmate-specific; do not commit `.no-mistakes/evidence/` here even when another no-mistakes-managed target project keeps committed PR evidence.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
bin/fm-lint.sh   # lint the toolbelt and behavior tests; the single owner CI and the no-mistakes gate both run
bin/fm-test.sh --local   # behavior tests the working change can affect, in parallel; what no-mistakes commands.test runs
bin/fm-test.sh   # the canonical whole set, serial: the definition of the suite, and what --local is measured against

[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (the scratch state has no session lock, so it notes that first, then prints arm status and an actionable signal)
```

`bin/fm-test.sh` is the single owner of the suite: CI runs it as `--shard K/N` and stays exhaustive, the pre-push gate runs `--local`.
`--local` selects through the reference closure in `bin/fm-test-plan.awk`, so a test that exercises an edited script runs even when the test file itself is untouched, and any changed file the planner cannot attribute to a test escalates the run to the whole set, prose (`*.md`, `*.txt`) being the one deliberate exception the planner's header argues for.
Use `--list-local` to see what it would run and `--verify-parity` to re-derive the claim that the selected parallel path agrees with the whole set file for file.
Reproduce one CI shard with `--shard K/N`.

Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so run one directly to focus on a subject.
Tests that need a real optional backend or an explicit opt-in (real herdr/zellij/cmux smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the run-all command above is always safe.
`tests/fm-assert-tests-kept.test.sh` is the deliberate exception: it needs `python3` with `venv` plus the pinned `pytest`, either already importable at exactly that pinned version or installable with `pip`, and `node` with `npm` plus network or a warm npm cache to install the pinned `vitest`/`jest` its JS cases run, because it builds those environments to prove the kept-tests gate really executes Python and JavaScript assertions, and it fails loudly rather than skipping when it cannot, since a silent skip would drop exactly the coverage that proves assertions ran.
Those environments are cached under the shared git common dir in directories named for the version they hold, so a local run pays the install only on a cold or broken cache and on the first run after a pin is bumped; the test file itself owns the pins, the cache rules, and the coverage trade that caching accepts.
CI does not add its own guard step for those prerequisites: it relies on the `ubuntu-latest` runner already providing `python3`, `venv`, `pip`, `node`, and `npm`, and on this test failing loudly rather than skipping if that ever stops being true, and it always starts cold, so every CI run still exercises the full provisioning path.

### Re-verifying a PR after `main` moves

GitHub re-runs a PR's checks only when the PR's own head changes, so a green result stays green after `main` has moved underneath it, measured against a base that no longer exists.
The `Base re-verification` workflow is the cheap way back: re-run it (`gh run rerun <run-id>`) and it re-fetches the base at job time and re-runs only the base test files that differ from the branch's copies, with no new push and nothing else re-run.
It is its own workflow rather than a job inside `ci.yml` precisely so that re-running it is one command against the run, and so it never drags the four behaviour shards along with it.
`bin/fm-assert-tests-kept.sh` is the single owner of which files those are, and `bin/fm-reverify-base.sh` is the thin caller that renders its verdict; neither the workflow nor anything else re-spells that selection.
It is a required check and it refuses rather than passing whenever it cannot evaluate, so a green reading always means assertions were actually compared.
It re-runs the base's assertions against the branch, so it never merges the base's source in and cannot see the two sets of source changes conflicting; merging the moved base forward is still what settles that.

When that forward merge conflicts, resolve it yourself whenever the resolution keeps everything both sides brought - reordering, re-indenting, renumbering, and fusing two sentences into one are all yours to choose, and none of it needs asking.
A resolution that DELETES either side's content is not yours to choose: keep both sides in the merge, then delete the content in its own commit so the decision is visible in the diff, and say what you dropped and why.
Both halves are enforced rather than trusted - a `commit-msg` hook refuses the deleting resolution as you commit it, and `bin/fm-pr-merge.sh` refuses it again over the merges the PR would land, with no override on either.
`docs/merge-resolution-gate.md` owns that contract and is honest about what the check cannot catch.
Never rebase to resolve a conflict: pushing a rebased branch is denied outright, so the forward merge is the only supported path.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
