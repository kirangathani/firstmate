#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--scout] [--skip-testing|--local-skip|--ci-skip|--all-testing-skip]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX, HERDR_ENV=1, or cmux runtime signals; bin/fm-backend.sh's
#   fm_backend_detect, with cmux fallback details in docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout.
#   --skip-testing, --local-skip, --ci-skip, and --all-testing-skip are the
#   captain's testing skips, orthogonal to delivery mode and yolo. THIS IS THE
#   ONE PLACE A TESTING SKIP IS AUTHORIZED: the flag is passed here and nowhere
#   else, and this script both mints the authorization and rewrites the worker's
#   own brief to match (see "the brief's half" below), so there is no second
#   invocation to keep in agreement and no way to half-specify a skip.
#   --skip-testing is the flag to reach for when the intent is just "skip the
#   testing": it resolves, once the project's delivery mode is known, to the most
#   that mode can honour (no-mistakes -> both; direct-PR -> CI; local-only has
#   nothing to skip and refuses), states on stderr what it resolved to, and needs
#   no knowledge of the matrix below. The three explicit flags remain for a
#   deliberately narrower skip.
#   Each records local_skip=on and/or ci_skip=on in state/<id>.meta
#   (--all-testing-skip records both); an absent field means off, so an unflagged
#   task's meta is byte-identical to before.
#   --local-skip ENFORCES the skip instead of asking for it: the launch prepends a
#   per-task shim directory to the worker's pane environment whose `no-mistakes`
#   executable explains the intentional skip and exits 0, so the worker cannot run
#   the local pipeline even if it tries. The shim lives under the per-task temp
#   root and is exported only into that pane's shell, so it reaches no other task
#   and never the captain's own environment.
#   --ci-skip only RECORDS the captain's authorization, as ci_skip=on plus a
#   ci_skip_auth= HMAC minted here from this home's config/ci-waiver-secret. The
#   flag line alone is not authority - a worker appends its status lines into the
#   same state directory and could append that line too - so the token is what
#   bin/fm-ci-waiver.sh actually checks before signing, and --ci-skip refuses
#   outright when no secret exists to mint it.
#   --local-skip mints the SAME kind of token, recorded as local_skip_auth= under
#   its own payload domain, for the same reason and against the same forgery: it
#   is what bin/fm-pr-merge.sh checks before a local skip may excuse the
#   no-mistakes attestation check at merge time. A bare local_skip=on line
#   authorizes nothing there.
#   Unlike --ci-skip, --local-skip does NOT refuse when the home has no secret to
#   mint from, because the two flags lose different amounts without one. --ci-skip
#   without a key is inert: no waiver could ever be signed for that task, so the
#   dispatch would ask a worker for a signature nobody can produce. --local-skip
#   still delivers its whole primary effect - the shim above enforces the skip
#   with or without a key - so refusing would break a working flag for every home
#   that has never run fm-ci-waiver.sh init. Minting nothing SILENTLY is the other
#   wrong answer, because the loss would surface much later as an unexplained
#   merge refusal, so the spawn proceeds and says on stderr exactly what was lost
#   and the one command that fixes it.
#   THE BRIEF'S HALF. A ship spawn calls bin/fm-brief.sh --apply-testing-skip
#   with the flag it just resolved, which rewrites the three regions of
#   data/<id>/brief.md whose text depends on the mode and the skip (that script
#   owns the regions and the markers). It runs on EVERY ship spawn, flagged or
#   not, so an unflagged dispatch of a brief that carries skip text puts the
#   ordinary instructions back rather than launching a worker whose instructions
#   and whose record disagree. A brief that has no such regions refuses the
#   dispatch when a skip was asked for, and is left untouched when none was.
#   Nothing about the AUTHORIZATION passes through the brief: it is prose, and
#   the token below is the authority.
#   Accepted flag/delivery-mode combinations are checked before launch and every
#   other combination refuses: no-mistakes takes --local-skip or
#   --all-testing-skip; direct-PR takes --ci-skip; local-only takes none, having
#   no pipeline, no PR, and no CI; scout and secondmate spawns take none.
#   --skip-testing is accepted wherever any of those are, since it resolves to
#   one of them. Every refusal prints that matrix, so it is never something to go
#   and look up.
#   --ci-skip alone is refused under no-mistakes because that pipeline owns the
#   push and the PR, so a commit-bound waiver cannot be attached before CI starts
#   unless the worker opens the PR itself.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# Every non-secondmate spawn also claims its worktree with a gitignored .fm-task
# marker naming the task, so bin/fm-teardown.sh can prove the recorded pool slot
# is still that task's before it terminates anything in it.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# followed by " local_skip=on" and/or " ci_skip=on" only when a testing skip is active.
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derived from the header block itself rather than a line range: the header is
# the contract, it grows, and a hard-coded range silently truncates --help the
# first time it does.
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-ci-waiver-lib.sh
. "$SCRIPT_DIR/fm-ci-waiver-lib.sh"
# shellcheck source=bin/fm-testing-skip-lib.sh
. "$SCRIPT_DIR/fm-testing-skip-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
fm_testing_skip_reset
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --local-skip|--ci-skip|--all-testing-skip|--skip-testing) fm_testing_skip_note "$a" ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Testing-skip validation, part 1: the argument-only rules, checked before any
# filesystem or backend work so a malformed dispatch costs nothing. Part 2 (the
# delivery-mode rules) needs the resolved project and runs after the brief check.
# Every unrecognised combination refuses rather than picking an interpretation:
# these flags remove test coverage, so guessing which one the captain meant is
# the one behaviour they must never have.
fm_testing_skip_check_args "$KIND" task || exit 1
LOCAL_SKIP=$FM_TESTING_SKIP_LOCAL
CI_SKIP=$FM_TESTING_SKIP_CI
SKIP_FLAGS=$FM_TESTING_SKIP_FLAGS

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta still carries no backend= line. It is not
# otherwise byte-identical to an older meta: a tmux spawn also writes
# tmux_window_pinned=1 (see the meta block below), the window-name pin
# guarantee that fm_backend_expected_label_of_meta keys off.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate_spawn "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1
if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=orca does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=cmux does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = orca ]; then
  fm_backend_orca_runtime_check || exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

orca_spawn_abort_cleanup() {
  local status=$?
  [ "$ORCA_ABORT_CLEANUP" = 1 ] || return "$status"
  ORCA_ABORT_CLEANUP=0
  if [ -n "${ORCA_TERMINAL:-}" ]; then
    fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null || true
  fi
  if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
    if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
      mkdir -p "$STATE" 2>/dev/null || true
      if [ -d "$STATE" ]; then
        {
          echo "window=$W"
          echo "worktree=${WT:-}"
          echo "project=$PROJ_ABS"
          echo "harness=$HARNESS"
          echo "kind=$KIND"
          echo "mode=${MODE:-no-mistakes}"
          echo "yolo=${YOLO:-off}"
          echo "tasktmp=${TASK_TMP:-}"
          echo "model=${MODEL:-default}"
          echo "effort=${EFFORT:-default}"
          [ "$LOCAL_SKIP" = off ] || echo "local_skip=on"
          [ -z "${LOCAL_SKIP_AUTH:-}" ] || echo "local_skip_auth=$LOCAL_SKIP_AUTH"
          [ "$CI_SKIP" = off ] || echo "ci_skip=on"
          [ -z "${CI_SKIP_AUTH:-}" ] || echo "ci_skip_auth=$CI_SKIP_AUTH"
          echo "backend=orca"
          echo "orca_worktree_id=$ORCA_WORKTREE_ID"
          [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
        } > "$STATE/$ID.meta" 2>/dev/null || true
      fi
    fi
  fi
  return "$status"
}
trap orca_spawn_abort_cleanup EXIT

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  # The single validated skip flag applies to every pair in the batch, exactly
  # like --harness/--model/--effort. Each re-exec re-validates it against its own
  # project's delivery mode, so one unsuitable project fails its pair alone.
  [ -z "$SKIP_FLAGS" ] || shared_args+=("$SKIP_FLAGS")
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    # --dangerously-bypass-hook-trust is on the CREWMATE launch only, by explicit
    # captain ruling recorded in docs/fix-instructions-gate.md. Codex gates project
    # hooks on folder hook-trust, which this launch does not otherwise establish, so
    # without it the fix-instructions seatbelt written to <worktree>/.codex/hooks.json
    # is inert and every surface would read as though the rule were enforced. The
    # accepted cost, stated before the ruling: a codex crewmate then runs a
    # repository's own hook code at launch with no trust check, in any repo we clone.
    # The ruling does NOT extend to the secondmate launch below, to any other
    # harness, or to any other codex safety flag.
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into this secondmate home (fm-config-inherit-lib.sh).
  propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
    || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; the project-management skill and AGENTS.md task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
# Resolved HERE, before any backend container or worktree exists, so the
# testing-skip validation below can refuse an unsuitable combination without
# leaving an orphaned window behind.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

# Testing-skip validation, part 2: which skip a delivery mode can honour. Each
# rule below refuses a combination the mode CANNOT actually deliver, rather than
# accepting it and silently doing nothing, so a captain who asks for less testing
# always learns whether they got it. This is also where --skip-testing resolves,
# because "all the testing this project has" has no answer until the mode is
# known, so LOCAL_SKIP/CI_SKIP are re-read from the library afterwards.
fm_testing_skip_check_mode "$MODE" || exit 1
LOCAL_SKIP=$FM_TESTING_SKIP_LOCAL
CI_SKIP=$FM_TESTING_SKIP_CI
RESOLVED_SKIP_FLAG=$(fm_testing_skip_resolved_flag)

# The dispatch-authorization token for a CI skip, minted here and only here.
# ci_skip=on on its own is not authority: the worker appends its status lines
# into this same state directory, so it can append that line to its own record
# too. The token is an HMAC the worker cannot compute, and bin/fm-ci-waiver.sh
# refuses to sign without a valid one (bin/fm-ci-waiver-lib.sh owns the domain
# separation and the residual same-user limit).
#
# This is why --ci-skip requires an initialized secret while --local-skip does
# not: without the secret no waiver could ever be signed for this task anyway,
# so refusing here turns a useless dispatch into an immediate, fixable message.
CI_SKIP_AUTH=
if [ "$CI_SKIP" = on ]; then
  CI_WAIVER_SECRET_FILE="$CONFIG/ci-waiver-secret"
  if ! fm_ci_waiver_secret_readable "$CI_WAIVER_SECRET_FILE"; then
    echo "error: --ci-skip needs this home's CI waiver secret at $CI_WAIVER_SECRET_FILE; run 'bin/fm-ci-waiver.sh init' (and 'publish <owner/repo>') first" >&2
    exit 1
  fi
  command -v node >/dev/null 2>&1 || {
    echo "error: --ci-skip needs node to mint this task's dispatch authorization (docs/configuration.md \"Toolchain\")" >&2
    exit 1
  }
  CI_SKIP_AUTH=$(fm_ci_waiver_dispatch_token "$ID" < "$CI_WAIVER_SECRET_FILE") || CI_SKIP_AUTH=
  fm_ci_waiver_valid_sig "$CI_SKIP_AUTH" || {
    echo "error: could not mint the CI-skip dispatch authorization for $ID" >&2
    exit 1
  }
fi

# The same dispatch authorization for a LOCAL skip, under its own payload domain
# so neither token can stand in for the other. bin/fm-pr-merge.sh checks it
# before a local skip may excuse the no-mistakes attestation check, for exactly
# the reason bin/fm-ci-waiver.sh checks the CI one: `local_skip=on` on its own is
# a line the worker could append to its own record.
#
# A missing secret WARNS here rather than refusing, and the header owns why: a
# --local-skip dispatch still delivers its enforcement without a key, so the
# spawn proceeds, states the one thing that was lost, and names the fix.
LOCAL_SKIP_AUTH=
if [ "$LOCAL_SKIP" = on ]; then
  LOCAL_SKIP_SECRET_FILE="$CONFIG/ci-waiver-secret"
  if ! fm_ci_waiver_secret_readable "$LOCAL_SKIP_SECRET_FILE"; then
    echo "warn: no signing key at $LOCAL_SKIP_SECRET_FILE, so this --local-skip dispatch records the skip WITHOUT an authorization token" >&2
    echo "warn: the skip itself is still enforced; what it cannot do is authorize bin/fm-pr-merge.sh to merge past the no-mistakes attestation check, which will refuse this task's PR instead" >&2
    echo "warn: run 'bin/fm-ci-waiver.sh init' and re-dispatch if this task's PR needs that" >&2
  else
    # A secret that EXISTS but cannot be used is a malfunction rather than a
    # supported configuration, so this half refuses exactly like --ci-skip does.
    command -v node >/dev/null 2>&1 || {
      echo "error: --local-skip needs node to mint this task's dispatch authorization (docs/configuration.md \"Toolchain\")" >&2
      exit 1
    }
    LOCAL_SKIP_AUTH=$(fm_ci_waiver_dispatch_local_token "$ID" < "$LOCAL_SKIP_SECRET_FILE") || LOCAL_SKIP_AUTH=
    fm_ci_waiver_valid_sig "$LOCAL_SKIP_AUTH" || {
      echo "error: could not mint the local-skip dispatch authorization for $ID" >&2
      exit 1
    }
  fi
fi

# The worker-facing half of the skip, written from the SAME flag that minted the
# authorization above, so a testing skip is one action at dispatch and there is
# no second invocation anywhere that has to agree with this one. It runs for
# every ship spawn, flagged or not: an unflagged dispatch of a brief that carries
# skip text puts the ordinary instructions back, so a brief can never quietly
# outlive the dispatch that justified it.
#
# This grants nothing. bin/fm-brief.sh writes prose; the authority is the keyed
# token written into this task's meta below, which is what bin/fm-ci-waiver.sh
# and bin/fm-pr-merge.sh actually read.
#
# Placed here, before any backend container, worktree, or temp root exists, so a
# brief this dispatch cannot bring into agreement refuses without leaving an
# orphan behind.
#
# A respawn that omits the flag is a real downgrade rather than a no-op, because
# the meta written below replaces the previous record wholesale and takes the
# skip and its token with it. Said out loud for the same reason the rest of this
# is mechanical: a skip that quietly evaporates on a recovery relaunch is the
# same silent half-skip in a different place.
if [ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
  if [ "$LOCAL_SKIP" = off ] && grep -qx 'local_skip=on' "$STATE/$ID.meta"; then
    echo "warn: $ID's existing record carries local_skip=on, but this dispatch passed no local skip, so that skip and its authorization are being dropped; re-run with --local-skip or --skip-testing to keep it" >&2
  fi
  if [ "$CI_SKIP" = off ] && grep -qx 'ci_skip=on' "$STATE/$ID.meta"; then
    echo "warn: $ID's existing record carries ci_skip=on, but this dispatch passed no CI skip, so that skip and its authorization are being dropped; re-run with --ci-skip or --skip-testing to keep it" >&2
  fi
fi
if [ "$KIND" = ship ]; then
  brief_apply_args=("$ID" --mode "$MODE")
  [ -z "$RESOLVED_SKIP_FLAG" ] || brief_apply_args+=("$RESOLVED_SKIP_FLAG")
  if ! FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_DATA_OVERRIDE="$DATA" \
    FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$FM_ROOT/bin/fm-brief.sh" --apply-testing-skip "${brief_apply_args[@]}"; then
    echo "error: could not bring $ID's brief into agreement with this dispatch; nothing was launched" >&2
    exit 1
  fi
fi

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Every backend's own current-path read (tmux's pane_current_path, herdr's
# foreground_cwd, zellij/cmux's active pwd probe against the live shell) can
# report the OS-level, physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real proj_real wt_top wt_top_real
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=$PROJ_ABS_REAL
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

W="fm-$ID"
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once
    # treehouse cd's into the worktree. WT_TARGET carries that stable id for the
    # rename-critical worktree-detection steps below; the persisted window= handle
    # stays $T (the name form), which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1
    WT_TARGET="$WID"
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary's "firstmate" one.
    HERDR_LABEL_HOME=$FM_HOME
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
    fi
    HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
    # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
    # (the second field empty when this call ADOPTED a pre-existing workspace
    # rather than creating a fresh one). Split on the guaranteed single tab
    # character; the seeded tab id is threaded through to create_task
    # untouched, which is the only function permitted to prune it (never
    # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
    CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
    HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
    HERDR_SES=${CONTAINER%%:*}
    HERDR_WORKSPACE_ID=${CONTAINER#*:}
    HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$PROJ_ABS" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$PROJ_ABS") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$PROJ_ABS") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  orca)
    set +e
    ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
    ORCA_WT_STATUS=$?
    set -e
    if [ "$ORCA_WT_STATUS" -ne 0 ]; then
      if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
        if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
          ORCA_ABORT_CLEANUP=1
        fi
      fi
      exit 1
    fi
    parse_orca_worktree_result "$ORCA_WT_RAW" || true
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
# #134 robustness: only tmux needs a worktree-detection target distinct from $T -
# its rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend) - the shared treehouse-get +
# worktree-detection steps below must never reference an unbound WT_TARGET under set -u.
: "${WT_TARGET:=$T}"
spawn_send_text_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_text_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
  esac
}
spawn_current_path() {  # <target>
  case "$BACKEND" in
    tmux) fm_backend_tmux_current_path "$1" ;;
    herdr) fm_backend_herdr_current_path "$1" ;;
    zellij) fm_backend_zellij_current_path "$1" "$W" ;;
    cmux) fm_backend_cmux_current_path "$1" "$W" ;;
  esac
}
spawn_send_literal() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_literal "$1" "$2" ;;
    herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
    zellij) fm_backend_zellij_send_literal "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_literal "$1" "$2" ;;
    cmux) fm_backend_cmux_send_literal "$1" "$2" "$W" ;;
  esac
}
spawn_send_key() {  # <target> <key>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_key "$1" "$2" ;;
    herdr) fm_backend_herdr_send_key "$1" "$2" ;;
    zellij) fm_backend_zellij_send_key "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_key "$1" "$2" ;;
    cmux) fm_backend_cmux_send_key "$1" "$2" "$W" ;;
  esac
}
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_send_text_line "$WT_TARGET" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # Compare against PROJ_ABS_REAL (physical), not PROJ_ABS: a symlinked project
  # prefix would otherwise make the pane's OS-level cwd read differ from
  # PROJ_ABS on the very first poll, before the pane has actually moved.
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" != "$PROJ_ABS_REAL" ]; then
      WT="$p"
      break
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"
fi

exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}

# Slot-occupancy marker: which task the worktree currently belongs to.
# A pooled worktree PATH is a lease, not an identity - treehouse returns a slot
# to the pool when a task ends and leases the same path to a later task - so a
# stale `worktree=` in an old meta can name a slot a DIFFERENT task now holds.
# bin/fm-teardown.sh reads this marker to refuse acting on a slot that is no
# longer this task's; it is written here, at the earliest point $WT is final for
# every non-secondmate backend, so the slot is claimed before the agent starts.
# A secondmate home carries .fm-secondmate-home instead, written by
# bin/fm-home-seed.sh and enforced by the same script's home-removal check.
# It is excluded rather than left untracked because an untracked file makes
# treehouse report the slot dirty, which permanently withholds a crashed task's
# slot from the pool (verified 2026-08-09, treehouse v2.0.0: a slot holding only
# an excluded file reports `available`, one holding an untracked file reports
# `dirty` and is never handed out again).
if [ "$KIND" != secondmate ]; then
  printf 'id=%s\n' "$ID" > "$WT/.fm-task"
  exclude_path '.fm-task'
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
#
# Ownership, checked before anything is written into the root: /tmp/fm-<id> is a
# predictable path under a world-writable sticky directory, so another local user
# can pre-create it. The spawn refuses when it is already there as a symlink, or
# already there owned by somebody else, rather than writing through a path it does
# not control. -e and -O both FOLLOW a symlink, so the -L test is the one that
# actually rejects a planted link, and it is asked first for that reason. The guard
# covers EVERY spawn, not only a --local-skip one: writing this task's Go temp
# through a link somebody else chose is wrong on its own terms, and for the shim
# installed below - which goes at the FRONT of a worker's PATH - it would be code
# execution as this user. It refuses outright and never falls back to another path:
# fm-teardown.sh removes exactly $TASK_TMP and the PATH export names exactly that
# directory, so a silent fallback would strand both.
TASK_TMP="/tmp/fm-$ID"
if [ -L "$TASK_TMP" ] || { [ -e "$TASK_TMP" ] && [ ! -O "$TASK_TMP" ]; }; then
  echo "error: refusing to use $TASK_TMP as this task's temp root: it already exists as a symlink or is not owned by this user, so nothing written under it can be trusted" >&2
  exit 1
fi
mkdir -p "$TASK_TMP/gotmp"

# --local-skip enforcement. A brief that merely ASKS a worker not to run the
# pipeline is probabilistic - the agent decides, and agents do not reliably
# decide - so the skip is made mechanical instead: a shim directory goes on the
# front of the worker's PATH holding a `no-mistakes` executable that refuses to
# be the real one.
#
# Scope: the shim lives under this task's own temp root, and the only thing that
# puts it on a PATH is the export sent into this task's pane below. It is never
# written to a shell rc file and never exported by this process, so it cannot
# reach another task's worker or the captain's own shell, and fm-teardown.sh
# removes it with the rest of $TASK_TMP.
#
# Exit status: the shim exits 0, deliberately. A non-zero exit reads to an agent
# as a broken toolchain, and the repair it would reach for - reinstalling
# no-mistakes, hunting for another copy, or restarting the shared daemon that
# serves every other lane - is far more damaging than the skip itself. Exiting 0
# with a message that names the flag and points straight at push-and-PR keeps the
# worker on the intended path instead of into a repair loop.
#
# Permissions: this directory is not the inert scratch space the sibling gotmp dir
# is - it goes at the FRONT of an agent's PATH and shadows a real tool by name, so
# it is created mode 700 and nobody else can swap the shim after it is written. The
# temp root it sits under was validated for symlinks and ownership above, before
# anything was written there.
#
# Streams: the shim prints the same message on stdout AND stderr. Exit 0 paired
# with empty stdout is the worst combination for a machine reader - a worker
# running `no-mistakes axi run --json` and parsing stdout would see nothing plus a
# success status, and could read that as a pipeline that ran and passed.
SKIP_BIN=
if [ "$LOCAL_SKIP" = on ]; then
  SKIP_BIN="$TASK_TMP/skip-bin"
  mkdir -p "$SKIP_BIN"
  chmod 700 "$SKIP_BIN"
  cat > "$SKIP_BIN/no-mistakes" <<EOF
#!/usr/bin/env bash
# Firstmate local-testing skip shim for task $ID, installed by bin/fm-spawn.sh.
# Not the real no-mistakes; see that script's --local-skip contract.
emit_skip_notice() {
cat <<'MSG'
no-mistakes is intentionally disabled for this task.

The captain dispatched it with --local-skip, so the local validation pipeline is
switched off by design. Nothing is broken: this is not a missing install, not a
PATH problem, and not a daemon fault, and there is nothing here to diagnose,
repair, reinstall, or work around. Do not look for another copy of no-mistakes,
do not install one, and do not touch the shared daemon.

Go straight to delivery instead: commit your work, push your branch, open the PR
with gh-axi, and report done exactly as your instructions say.
MSG
}
emit_skip_notice
emit_skip_notice >&2
exit 0
EOF
  chmod 755 "$SKIP_BIN/no-mistakes"
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
#
# The same per-harness hook files also carry the fix-instructions PreToolUse
# seatbelt (bin/fm-fix-instructions-check.sh, docs/fix-instructions-gate.md),
# which denies a `no-mistakes axi respond --action fix` that carries no
# substantive --instructions. It is wired here rather than per task so every
# newly spawned crewmate receives it with no hand wiring, exactly as the turn-end
# signal is. The check is referenced by absolute path into the firstmate code
# root because a task worktree is a worktree of the PROJECT, not of firstmate.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
FIXCHECK="$FM_ROOT/bin/fm-fix-instructions-check.sh"
# The commit-msg hook, carrying both authorship-time checks: AI attribution in
# the message (docs/attribution-gate.md) and a merge resolution that deletes
# content one side introduced (docs/merge-resolution-gate.md). Installed for
# every kind and every harness, because both rules bind the artefact, not the
# worker's runtime. Git hooks are per-repository, so this is one idempotent write
# per project rather than per task. A foreign hook is left alone (exit 3) and a
# failure is only ever a notice: the landing gates are what actually hold both
# lines, so nothing here may cost a spawn.
attr_hook_out=$("$FM_ROOT/bin/fm-install-commit-hook.sh" "$WT" 2>&1) || true
case "$attr_hook_out" in
  *'commit-hook: installed'*) ;;
  *)
    # Reported as a note, never as an error: a skipped hook does not fail a
    # spawn, and the word "error" here would read as one. Each line is prefixed
    # so the installer's own wording cannot be mistaken for fm-spawn's.
    while IFS= read -r attr_hook_line; do
      [ -n "$attr_hook_line" ] && echo "note: $attr_hook_line" >&2
    done <<EOF_ATTR
$attr_hook_out
EOF_ATTR
    echo "note: the commit-msg hook was not installed for $WT; the landing gates still refuse AI attribution and a deleting merge resolution before anything lands" >&2
    ;;
esac

if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      # --claude keeps stdout empty on deny; Claude Code ignores a PreToolUse
      # deny whose stdout is non-empty (docs/arm-pretool-check.md).
      #
      # "attribution" turns OFF the three attribution strings Claude Code would
      # otherwise be instructed to append. Schema read from the installed
      # binary's own settings schema (claude 2.1.226): commit and pr are the
      # attribution TEXT and "Empty string hides attribution"; sessionUrl
      # "Set to false to omit the Claude-Session trailer and PR-body link".
      # This removes the GENERATOR, which is cheap and worth doing, but it is
      # not the control: it only covers this one harness and a model can still
      # type the trailer by hand. docs/attribution-gate.md says which layer is
      # actually load-bearing.
      cat > "$WT/.claude/settings.local.json" <<EOF
{"attribution":{"commit":"","pr":"","sessionUrl":false},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"$(json_escape "$FIXCHECK") --claude"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      # tool.execute.before blocks by throwing (verified 2026-07-09 against
      # OpenCode 1.17.15; docs/arm-pretool-check.md). Only exit 2 blocks, so a
      # missing or failing checker leaves the command alone.
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
import { spawn } from "node:child_process"

const FIX_CHECK = "$(json_escape "$FIXCHECK")"

function runFixCheck(command) {
  return new Promise((resolve) => {
    const child = spawn(FIX_CHECK, ["--command", command], { stdio: ["ignore", "ignore", "pipe"] })
    let stderr = ""
    child.stderr.on("data", (chunk) => { stderr += chunk.toString() })
    child.on("error", () => resolve({ code: 0, stderr: "" }))
    child.on("close", (code) => resolve({ code: code ?? 0, stderr }))
  })
}

export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
  "tool.execute.before": async (input, output) => {
    if (input?.tool !== "bash") return
    const command = output?.args?.command
    if (!command || typeof command !== "string") return
    const result = await runFixCheck(command)
    if (result.code !== 2) return
    throw new Error(result.stderr.trim() || "denied by the fix-instructions PreToolUse seatbelt")
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal and fix-instructions seatbelt; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
// pi.on("tool_call", ...) blocks by returning {block: true} (verified
// 2026-07-09 against pi 0.80.5; docs/arm-pretool-check.md). The seatbelt rides
// this same file so the launch needs no extra -e flag.
import { execFile, spawn } from "node:child_process";
const FIX_CHECK = "$(json_escape "$FIXCHECK")";
function runFixCheck(command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(FIX_CHECK, ["--command", command], { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
  pi.on("tool_call", async (event: any) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String(event.input?.command ?? "");
    if (!command) return {};
    const result = await runFixCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the fix-instructions PreToolUse seatbelt" };
  });
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__,
      # so this is the one harness whose worktree carried no hook file before the
      # fix-instructions seatbelt. Codex blocks on exit 2 and displays stderr, and
      # reads project hooks from <project-root>/.codex/hooks.json - the same shape
      # the firstmate primary uses. codex gates project hooks on folder hook-trust,
      # which fm-spawn will not establish by writing codex's managed trust store, so
      # the crewmate launch template above passes --dangerously-bypass-hook-trust to
      # make this file load. That flag is a captain ruling with an accepted cost; see
      # launch_template's codex comment and docs/fix-instructions-gate.md. UNVERIFIED:
      # codex is not installed here, so that the flag makes this hook fire is an
      # inference from codex's documented trust gate, not a measurement.
      mkdir -p "$WT/.codex"
      cat > "$WT/.codex/hooks.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash -lc 'payload=\$(cat 2>/dev/null || true); [ -n \"\$payload\" ] || exit 0; printf \"%s\" \"\$payload\" | $(json_escape "$(shell_quote "$FIXCHECK")")'","timeout":10}]}]}}
EOF
      exclude_path '.codex/hooks.json'
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      # The fix-instructions seatbelt takes the same global-hook route and the
      # same workspace-token guard, for the same reason: grok loads PROJECT hooks
      # only after the folder is granted hook-trust, which firstmate will not
      # establish by editing grok's managed trust store, while GLOBAL hooks in
      # ~/.grok/hooks/ always load. The guard makes it a no-op for every grok
      # session that is not a firstmate crewmate worktree, because only those
      # carry a .fm-grok-turnend pointer into the firstmate-owned registry.
      # Every $VAR in a grok hook command string must carry an inline :-default or
      # the hook fails to load at all (docs/arm-pretool-check.md).
      sq_fixcheck=$(shell_quote "$FIXCHECK")
      cat > "$GROK_HOOKS_DIR/fm-pretool-check.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
payload=\$(cat 2>/dev/null || true)
[ -n "\$workspace" ] || exit 0
[ -n "\$payload" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
[ -f "\$auth_dir/\$token" ] || exit 0
printf '%s' "\$payload" | $sq_fixcheck
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-pretool-check.sh"
      pretool_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-pretool-check.sh")")
      printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s","timeout":10}]}]}}\n' "$pretool_command" > "$GROK_HOOKS_DIR/fm-pretool-check.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
{
  echo "window=$META_WINDOW"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  # Testing skips are written only when ON, so an unflagged task's meta stays
  # byte-identical to before these flags existed; an absent field means off.
  # ci_skip=on is the ONLY thing that lets bin/fm-ci-waiver.sh sign for this
  # task, which is why it is written here, at dispatch, on the captain's machine.
  # A worker CAN reach this directory - it appends its status lines beside this
  # file - so the flag line alone is not what protects anything; the token below
  # is, because it is an HMAC over a secret the worker was never told about.
  # Each *_auth= token is written only when one was actually minted: an absent
  # token means the flag was recorded without one, which every consumer must
  # then treat as no authority rather than as a missing file to work around.
  [ "$LOCAL_SKIP" = off ] || echo "local_skip=on"
  [ -z "$LOCAL_SKIP_AUTH" ] || echo "local_skip_auth=$LOCAL_SKIP_AUTH"
  [ "$CI_SKIP" = off ] || echo "ci_skip=on"
  [ -z "$CI_SKIP_AUTH" ] || echo "ci_skip_auth=$CI_SKIP_AUTH"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta keeps carrying no backend= line (absent backend= means
  # tmux; data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  # tmux_window_pinned=1 records that this window's name was pinned at
  # creation: fm_backend_tmux_create_task now REFUSES the spawn unless
  # automatic-rename and allow-rename could both be turned off, so reaching
  # this line on tmux proves '#{window_name}' cannot drift from $W. Readers
  # use it to decide whether an exact-label liveness check is safe
  # (fm_backend_expected_label_of_meta, bin/fm-backend.sh); a meta written
  # before this requirement carries no such line and is read leniently.
  [ "$BACKEND" = tmux ] && echo "tmux_window_pinned=1"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
sleep 0.3
# The tracked .claude/settings.json points the status line at
# bin/fm-statusline.sh, which composes beneath the operator's own status line.
# A crewmate or scout worktree is a plain git worktree: it carries that tracked
# wiring but has no config/ and no state/, so there is no file there to read.
# Forwarding the DISPATCHING home's setting is what carries a DELIBERATE per-home
# choice into the worker window; a worker that inherits no export still falls back
# to the operator's own user-level status line on its own, so absent or empty
# exports nothing and costs nothing (docs/configuration.md "Status-line
# composition"). Secondmates are excluded on purpose - they run with their own
# FM_HOME and inherit the setting as a real config file through
# FM_INHERITABLE_CONFIG, which must stay authoritative for them.
STATUSLINE_BASE=
if [ "$KIND" != secondmate ] && [ -f "$CONFIG/statusline-base" ]; then
  IFS= read -r STATUSLINE_BASE 2>/dev/null < "$CONFIG/statusline-base" || true
  STATUSLINE_BASE=${STATUSLINE_BASE#"${STATUSLINE_BASE%%[![:space:]]*}"}
  STATUSLINE_BASE=${STATUSLINE_BASE%"${STATUSLINE_BASE##*[![:space:]]}"}
fi
if [ -n "$STATUSLINE_BASE" ]; then
  spawn_send_text_line "$T" "export FM_STATUSLINE_BASE=$(shell_quote "$STATUSLINE_BASE")"
  sleep 0.3
fi
# Prepend the --local-skip shim to the pane shell's own PATH, so the agent and
# every process it starts resolve `no-mistakes` to the shim. Sent before the
# launch command so the environment is already in place when the agent starts.
if [ -n "$SKIP_BIN" ]; then
  spawn_send_text_line "$T" "export PATH=$(shell_quote "$SKIP_BIN"):\$PATH"
  sleep 0.3
fi
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
spawn_send_key "$T" Enter

SKIP_SUMMARY=
[ "$LOCAL_SKIP" = off ] || SKIP_SUMMARY="${SKIP_SUMMARY} local_skip=on"
[ "$CI_SKIP" = off ] || SKIP_SUMMARY="${SKIP_SUMMARY} ci_skip=on"
echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT$SKIP_SUMMARY"
