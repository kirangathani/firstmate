#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#        fm-brief.sh --apply-testing-skip <task-id> --mode <delivery-mode> [<skip-flag>]
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   SCAFFOLDING TAKES NO TESTING-SKIP FLAG. --local-skip, --ci-skip,
#   --all-testing-skip, and --skip-testing all refuse here and name
#   bin/fm-spawn.sh, which is the one place a testing skip is authorized: it
#   mints the keyed authorization AND then rewrites this brief's own half by
#   calling back into --apply-testing-skip below. So the captain names a skip
#   once, at dispatch, and there is no second invocation to keep in agreement -
#   nor any way to half-specify one and get an ordinary task instead.
#   --apply-testing-skip rewrites, in place, ONLY the three regions of an
#   existing ship brief whose text depends on the delivery mode and the skip:
#   the branch/setup steps, rule 1, and the definition of done (with the CI
#   waiver handshake when one applies). Those regions are delimited in the
#   scaffold by <!-- fm:... --> markers, and the definition-of-done marker
#   records which skip the brief was written for, so an apply that would change
#   nothing rewrites nothing. A brief with no markers at all is left untouched
#   when no skip is asked for and refuses when one is; a brief with partial or
#   duplicated markers always refuses.
#   This path carries no authority whatsoever: it writes worker-facing prose,
#   never a token, a meta field, or a signature. A brief that talks about a skip
#   has never been evidence that one was granted - bin/fm-ci-waiver.sh and
#   bin/fm-pr-merge.sh read the keyed authorization in state/<task-id>.meta, and
#   only bin/fm-spawn.sh can mint that.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see the project-management skill
# and AGENTS.md task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship rules carry a commit-early cadence rule and scout setup carries an
# incremental-report rule as scaffold text, not per-task advice: leaving that
# cadence to hand-added brief notes measurably failed (2026-08-02, four
# high-context crewmates in two sessions each holding a large uncommitted diff
# behind healthy-looking signals), so the contract every crewmate reads now
# carries it structurally. Uncommitted work survives context compaction on
# disk, but the worker loses its memory of what the diff means and worktree
# recycling then discards the diff, so only committed (ship) or written-down
# (scout) work is durable.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-testing-skip-lib.sh
. "$SCRIPT_DIR/fm-testing-skip-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
APPLY_SKIP=0
APPLY_MODE=
fm_testing_skip_reset
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      mode) APPLY_MODE=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --apply-testing-skip) APPLY_SKIP=1 ;;
    --mode) want_value=mode ;;
    --mode=*) APPLY_MODE=${a#--mode=} ;;
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --local-skip|--ci-skip|--all-testing-skip|--skip-testing) fm_testing_skip_note "$a" ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
ID=${POS[0]:-}
[ -n "$ID" ] || { echo "error: usage: fm-brief.sh <task-id> <repo-name> [...]" >&2; exit 1; }

# A testing skip is authorized at DISPATCH and nowhere else. Scaffolding takes no
# skip flag at all, so there is no second invocation to keep in agreement with
# the first and no way to half-specify one: passing it here is a hard refusal
# naming the one script that owns it, never a brief that quietly asks for a skip
# the dispatch never granted.
if [ "$APPLY_SKIP" -eq 0 ] && [ -n "$FM_TESTING_SKIP_FLAGS" ]; then
  echo "error: '$FM_TESTING_SKIP_FLAGS' is a bin/fm-spawn.sh flag, not a bin/fm-brief.sh one: only a dispatch can authorize a testing skip." >&2
  echo "error: scaffold this brief with no skip flag, then dispatch with 'bin/fm-spawn.sh $ID <project> $FM_TESTING_SKIP_FLAGS'; spawn mints the authorization and rewrites this brief's own half from the same flag." >&2
  exit 1
fi

# Same argument-only refusals as bin/fm-spawn.sh, so a brief can never carry a
# combination that spawn will then refuse to launch.
fm_testing_skip_check_args "$KIND" brief || exit 1

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
if [ "$APPLY_SKIP" -eq 0 ]; then
  if [ -e "$BRIEF" ]; then
    echo "error: $BRIEF already exists" >&2
    exit 1
  fi
  mkdir -p "$DATA/$ID"
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# The gate-context helpers read the task's brief and decision record under
# FM_HOME/data, while the scripts themselves come from the shared tracked code
# root. Those are the same directory in the main home but NOT in a secondmate
# home, which is the whole point of the FM_HOME split, and a crewmate pane is
# launched with no FM_HOME of its own (only a --secondmate launch gets that
# prefix, see bin/fm-spawn.sh). Left root-anchored, a secondmate's crewmate
# would resolve data/ to the code root, find no brief there, and be unable to
# start a run at all. So the resolved home is embedded, exactly as the status
# file path above already is.
FM_HOME_ENV="FM_HOME=$(shell_quote "$FM_HOME")"
NM_DECISION_CMD="$FM_HOME_ENV $(shell_quote "$FM_ROOT/bin/fm-nm-decision.sh")"
# The one owner of attaching to a run. It composes the pinned intent itself, so
# the worker never assembles the raw command; a PreToolUse gate denies that
# command outright (bin/fm-fix-instructions-policy.mjs, docs/fix-instructions-gate.md).
NM_ATTACH_CMD="$FM_HOME_ENV $(shell_quote "$FM_ROOT/bin/fm-nm-attach.sh")"
# The follow-up a capped fix round files belongs in THIS home's backlog, and
# the worker's cwd is a project worktree where a bare `tasks-axi` would resolve
# some other workspace or none at all, so the backlog file is named outright.
# The path is .tasks.toml's markdown-backend path resolved against the home.
TASKS_ADD_CMD="tasks-axi add --file $(shell_quote "$FM_HOME/data/backlog.md")"
PR_GREEN_CMD="$FM_HOME_ENV $(shell_quote "$FM_ROOT/bin/fm-pr-green.sh")"

# --- the three machine-owned regions of a ship brief ------------------------
#
# SETUP_REGION, RULE_REGION, and DOD_REGION are exactly the text a ship brief
# carries that is a FUNCTION of the delivery mode and the captain's testing
# skip. Everything else a brief holds - the task text, the isolation assertion,
# the status protocol, the project-memory section, any adjustment firstmate made
# by hand - is written once at scaffold and is never touched again.
#
# They are rendered by one function because they are rewritten from two places:
# the scaffold below, and bin/fm-spawn.sh through --apply-testing-skip when the
# captain authorizes a skip at dispatch. Two renderings of the same three
# regions would drift, and a brief whose definition of done disagreed with the
# dispatch that launched it is the exact failure this arrangement removes.
BRIEF_REGION_SETUP_BEGIN='<!-- fm:setup-steps -->'
BRIEF_REGION_SETUP_END='<!-- /fm:setup-steps -->'
BRIEF_REGION_RULE_BEGIN='<!-- fm:rule-1 -->'
BRIEF_REGION_RULE_END='<!-- /fm:rule-1 -->'
BRIEF_REGION_DOD_PREFIX='<!-- fm:definition-of-done'
BRIEF_REGION_DOD_END='<!-- /fm:definition-of-done -->'

# brief_skip_state <local on|off> <ci on|off>: the skip state recorded on the
# definition-of-done marker, so a brief states which skip it was written for and
# an apply can tell "already correct" from "needs rewriting" without guessing.
brief_skip_state() {
  if [ "${1}" = on ] && [ "${2}" = on ]; then printf 'all'
  elif [ "${1}" = on ]; then printf 'local'
  elif [ "${2}" = on ]; then printf 'ci'
  else printf 'none'
  fi
}

# render_ship_regions <mode> <local-skip on|off> <ci-skip on|off>
# Sets SETUP_REGION, RULE_REGION, DOD_REGION.
render_ship_regions() {
  local mode=$1 local_skip=$2 ci_skip=$3
  local pr_order done_head done_loop round_order ci_section setup2 rule1 dod

  # The definition-of-done sentence and the waiver handshake must not each give
  # their own PR order. The handshake is the only authority when it applies: the
  # signature covers the head commit and CI must see it on the PR's FIRST run,
  # so a worker that opened the PR on the DOD sentence's word would get a PR the
  # waiver can never cover. A brief that states two orders is exactly the "the
  # agent decides" failure the mechanical skip exists to remove, so the DOD
  # sentence stops at push and defers to the handshake whenever one follows.
  if [ "$ci_skip" = on ]; then
    pr_order='push your branch, then follow the CI waiver handshake below for when and how to open the PR.'
  else
    # shellcheck disable=SC2016 # the backticks are literal brief text, not expansions.
    pr_order='push your branch and open a PR with `gh-axi`.'
  fi

  # DONE_HEAD and DONE_LOOP state the definition of done as a LOOP over every
  # change to the branch, not as a first-pass sequence. Measured 2026-09-16 on
  # fm-brief-attach-ownership-a3: the worker made its fix commit 0b16c1b3,
  # reported `done: PR .../97`, and stopped with the PR's head still at the
  # pre-fix 8b2da7d5, so firstmate read a red that was CI's verdict on the
  # version BEFORE the fix. That worker did exactly what the brief said. The two
  # defects being fixed here are that completion was defined as COMMITTED, and
  # that the push instruction was welded to opening the PR - an event that
  # happens once, so a later fix round was addressed by nothing but "append
  # done: and stop". The remedy is to define done as PUSHED AND VERIFIED and to
  # make bin/fm-pr-green.sh's verdict the required evidence, rather than leaving
  # the worker to judge for itself whether it is finished. That command reads the
  # PR's OWN head commit, so it is exactly the read that catches an unpushed fix;
  # a stale red is worse than no result, because it looks like a genuine failure
  # and invites debugging code that is already fixed.
  done_head='The task is complete only when your work is PUSHED and the PR carrying it is green. A commit is not done.'

  # The loop's own push order defers to the waiver handshake for the same reason
  # the DOD sentence does: on a waived task a later push needs its fresh line in
  # the PR body BEFORE it starts CI, so a bare "commit, push" here would state a
  # second, wrong order for exactly the rounds this loop exists to address.
  if [ "$ci_skip" = on ]; then
    round_order='commit, take the handshake step 5 below (it puts a fresh waiver line in the PR body, then pushes)'
  else
    round_order='commit, push'
  fi
  done_loop=$(cat <<EOF
Every time you change this branch after the PR exists - a fix round, a review finding, anything - the same loop applies, not just the first time: $round_order, then confirm with ONE read of \`$PR_GREEN_CMD $ID {url}\`, never a polling loop.
That read is the evidence behind your report: when it exits 0 it prints \`green: {url} {sha} {n} checks\`, and only then do you append \`done: PR {url} checks green at {sha}\` quoting the exact sha it printed, and stop.
Reporting done on an unpushed commit publishes a verdict about the version BEFORE your change, which reads as a real failure of code that is already fixed and sends somebody to debug it.
**An \`infrastructure:\` line is not a red and is never re-run.** It means a check never delivered a verdict about your branch at all - it timed out, was cancelled, could not run, or died having written nothing. Append \`blocked: infrastructure - {the infrastructure line verbatim}\` to the status file and stop. Do not re-run that check and do not push an empty commit to retrigger it.
EOF
)

  # The waiver handshake, appended to whichever definition of done applies. Its
  # order is load-bearing: the signature covers the head commit, so it cannot
  # exist before the final commit, and CI must see it on the PR's FIRST run
  # because editing a PR body afterwards does not re-run the workflow. Pushing a
  # feature branch triggers no workflow, so pushing before the PR costs nothing.
  if [ "$ci_skip" = on ]; then
    ci_section=$(cat <<EOF

## CI waiver handshake - follow this order exactly
CI's expensive jobs are waived for this task, but only by a signature you cannot produce and must not try to produce.
It is computed from a secret only the captain's machine holds, and it covers your exact head commit, so it can only be issued after your final commit.
1. Commit everything, then push your branch: \`git push -u origin fm/$ID\`. Pushing a branch runs no CI, so this step is free.
2. Read your head commit: \`git rev-parse HEAD\`.
3. Append \`blocked: ci-waiver needed for {full-40-char-sha} on {owner}/{repo}\` to the status file and stop. Firstmate replies with a single line.
   Write that sentence exactly, with the full 40-character commit and the owner/repo: firstmate issues the waiver straight from this line, and a reworded or abbreviated one cannot be read.
4. When that line arrives, append \`resolved: ci waiver received\`, then open the PR with \`gh-axi\` and put the line VERBATIM on its own line in the PR body.
5. Every later change needs its own line, and in a DIFFERENT order from the first round, because the PR already exists: commit, read the new head with \`git rev-parse HEAD\`, ask for a fresh line the same way, replace the old line in the PR body with it, and only THEN push.
   The body has to carry the new line before the push starts CI; editing it afterwards does not re-run anything, so a line added after the push waives nothing.
Never invent, guess, edit, reformat, or reuse a line for another commit.
A wrong or stale line is not a failure - CI simply runs in full - so there is nothing to be gained by improvising one.
EOF
)
  else
    ci_section=""
  fi

  case "$mode" in
    direct-PR)
      setup2=""
      rule1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
      dod=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
$done_head
When it is first implemented and committed, $pr_order
$done_loop
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
$ci_section
EOF
)
      ;;
    local-only)
      setup2=""
      rule1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
      dod=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch able to fast-forward onto the current default branch. If \`main\` advances under you, merge it forward only when firstmate tells you to - NEVER rebase - and resolve conflicts additively, keeping both sides. Firstmate lands one branch at a time, so a branch waits its turn rather than merging \`main\` every time another one lands.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
)
      ;;
    *)  # no-mistakes (default)
      if [ "$local_skip" = on ]; then
      # The pipeline is off, so the doctor/init setup step would only send the
      # worker into the shim it is not meant to fight.
      setup2=""
      rule1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
      dod=$(cat <<EOF
# Definition of done
This task was dispatched with **local testing skipped**: the captain switched the local validation pipeline off for it.
That skip is enforced, not requested - the \`no-mistakes\` on your PATH is a shim that explains the skip and exits without running anything.
Nothing is broken. Do not look for another copy of it, do not install one, do not change your PATH, and do not touch the shared daemon.
$done_head
When it is first implemented and committed, $pr_order
$done_loop
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
$ci_section
EOF
)
      else
      setup2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
      rule1='1. Never push to the default branch. Never merge a PR.'
      dod=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary - with one exception, below: you never run \`axi run\` or \`axi respond\` yourself, whatever that guidance shows.

**REVIEW findings are yours to fix, in your own worktree.** You wrote the code, so you fix it: edit, commit and push on your branch while the run is parked at review.
That push supersedes the parked run and a fresh, cold reviewer re-reads the result, which is the independence the pipeline is actually built on - so a mid-run commit for a review finding is the expected path, not a fault, and you do not need \`--instructions\` for a fix you apply yourself.
Everything else the pipeline still owns: a TEST, DOCUMENT or LINT finding is applied by the pipeline's own fixer through the gate, so do not hand-edit those while a run is active.
Escalating a decision is unchanged whichever kind it is (see the ask-user rules below).

Six firstmate-specific rules layer on top of that guidance:

- **An ask-user finding of severity \`info\` or \`suggestion\` is YOURS to answer.** Answer it yourself, choosing the option that keeps the decisions already recorded for this task and this brief's own \`# Task\` section true, record it under your own name with \`record --outcome <change|no-change>\` (see below), and list it in the PR description under a \`Decisions taken by the worker (info severity)\` heading with the finding id, the option you took, and the one-line reason.
  An info finding that RE-RAISES a decision already in this brief's \`## Gate decisions\` subsection is answered by citing that key, and recorded \`--outcome no-change\`; do not re-open a settled question.
  A finding about a security, credential, or data-loss risk escalates no matter what severity it carries.
- **Ask-user findings of severity \`warning\` or \`error\` are not yours to answer**: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`$NM_ATTACH_CMD $ID --respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- **A review QUESTION is not yours.** The reviewer can ask a question while it works; firstmate reads it, puts it to the captain, and answers the reviewer directly with its own command. You are not in that loop: nothing is relayed to you, you owe no \`resolved\` line for it, and you never run \`axi answer\` yourself.
  The run may therefore resume without you having done anything, which is normal. An answer settles only the question it answers.
- Avoid \`--yes\`: it silently auto-resolves EVERY ask-user finding, including the warning and error ones the captain owns. The attach owner refuses it outright.
- **Start, reattach and respond ONLY through the attach owner.** Never call \`no-mistakes axi run\` or \`axi respond\` yourself; a gate refuses those commands before they run.
  \`$NM_ATTACH_CMD $ID\` starts the run, or reattaches to it.
  \`$NM_ATTACH_CMD $ID --respond --action <approve|fix|skip> ...\` answers a gate, taking the same flags \`axi respond\` takes.
  Run it from inside this worktree; it refuses anywhere else. It composes the pinned intent for you from its one owner - the \`# Task\` section of this brief verbatim, never a paraphrase, which matters because the pipeline's final review scores the diff against it.
  **It returns immediately, on purpose, while the run is still going.** That is not a failure and there is nothing to wait for: it holds the attach in the background for hours, so instead of the \`error: wait of 8m0s elapsed\` you would get in the foreground several times per run, the hold returns only when the run actually reaches a gate or an outcome, and then appends ONE line to your status file. That line is what wakes firstmate, whether or not you are still watching. So do not poll it, do not re-attach to "check", and do not treat its immediate return as something to retry.
  \`no-mistakes axi status\` is the cheap look if you want to see where the run is; \`axi logs\`, \`axi sync\` and \`axi abort\` are unaffected too.
- **Every \`--action fix\` needs substantive \`--instructions\`.** Pass them through the attach owner like any other flag. The gate agent that applies a fix is not you: it sees the finding text and the diff and nothing else, and it cannot read this brief or the project's AGENTS.md. So \`--instructions\` must carry the design reasoning behind the code the finding touches, the principle the fix must preserve, and what the fix must not break or reintroduce. A bare or one-phrase \`--instructions\` is refused before it runs; that refusal is the rule working, not a tool fault, so answer it rather than routing around it.

# Gate decisions become part of the goal
A decision you submit at a gate changes what this branch is supposed to be, but the pipeline's final review scores the diff against \`--intent\`, which was written before that decision existed - upstream no-mistakes issue #591 (open, third-party, v1.40.0) documents a run whose later auto-fix reverted three submitted decisions and still reported \`checks-passed\`. Recording a decision closes that gap mechanically: it writes the decision into this brief's \`# Task\` section, so the attach command above already carries it the very next time you run it.

1. Record every decision the moment you submit it, not later from memory:
   \`$NM_DECISION_CMD record $ID --finding <finding-id> --key <decision-key> --requires "<what the decision requires, in concrete checkable terms>" --step <step>\`
   Pass \`--outcome no-change\` when the answer leaves the branch exactly as it is - "no change needed", "already decided at \`<key>\`", a documentation wording accepted as written - and \`--outcome change\` (the default) when it changes what the branch must contain.
   Add \`--fixed "<finding ids>"\` naming the findings this round submitted a fix for; recording one of those as \`no-change\` is refused, because a round that changed code owes the re-run that re-scores it.
2. When a run in which you recorded any \`change\` decision reaches its outcome, start a fresh run with the same attach command.
   That run's review is what proves the branch and the decided goal agree, and it is also the only thing that re-reviews whatever the later auto-fix steps (test, document, lint) changed.
   A round whose decisions were all \`no-change\` needs no fresh run: nothing on the branch moved, so a fresh 25-35 minute run would re-score exactly what the last one already scored.
3. \`$NM_DECISION_CMD rerun-check $ID\` must exit 0 before you report done. It refuses while any \`change\` decision was recorded during the run that is still the most recent one, which is exactly the case where nothing has yet scored the branch against the decided goal.

# Two fix rounds on the same findings, then file a follow-up - a convention, not a cap
THERE IS NO ROUND CAP. Nothing in the pipeline limits fix rounds, nothing here adds one, and none may be added.
What follows is a working convention for your own judgement: after about two further rounds on the SAME set of findings, a finding that keeps coming back is usually better as a follow-up than as a third attempt.
When you judge that, file it with \`$TASKS_ADD_CMD "<title from the finding>" --mint --blocked-by $ID\`, which prints the id it minted; name it in the PR description under a \`Deferred to follow-up\` heading with its finding id and the new task id, and carry on with the run.
This is a normal outcome, not a failure: do not append \`failed:\` or \`blocked:\` for a deferred finding, and do not abort the run over one.
Equally, a finding you are genuinely converging on is yours to keep working; the convention never forces you to stop.

# Reporting done: let the run's own \`ci\` step watch the PR
Do NOT abort a run to shortcut its \`ci\` step, and do not poll the PR yourself while the run is live. That step watches the PR it opened by PR number from the run record, so it sees your PR go green from this detached-HEAD worktree.

You are detached from the run while it monitors: the attach owner holds it in the background and appends the one status line that wakes firstmate at the run's next gate or outcome. A run that stays active until the PR merges therefore costs you nothing.

1. When the run reaches its CI-green outcome, the attach owner appends \`resolved [key=nm-run]: run {id} checks-passed\`. Confirm it with ONE read of \`$PR_GREEN_CMD $ID {url}\`, passing the PR link the pipeline printed - one read, never a polling loop.
   **An \`infrastructure:\` line is not a red and is never re-run.** It means a check never delivered a verdict about your branch at all - it timed out, was cancelled, could not run, or died having written nothing. A timed-out review is an alarm, not a retry. Append \`blocked: infrastructure - {the infrastructure line verbatim}\` to the status file and stop. Do not re-run that check, do not push an empty commit to retrigger it, and do not keep waiting for it to pass on its own.
2. When that read exits 0 it prints \`green: {url} {sha} {n} checks\`. Run that \`rerun-check\`, then append \`done: PR {url} checks green at {sha}\` quoting the exact sha it printed, and stop. You are finished.

# The pipeline's review is worth telling the PR about
The moment the pipeline's \`pr\` step has opened the PR, append \`review-attest needed for {full-40-char-sha} on {owner}/{repo}\` to the status file, with the PR's head commit and the owner/repo, and carry straight on driving the run - this is a note to firstmate, not a stop.
Firstmate replies by publishing a signed line into the PR body recording that this pipeline already reviewed that exact commit, so the project's own AI review job can stand down instead of reviewing the same diff again.
Write that sentence exactly, with the full 40-character commit and the owner/repo: firstmate issues the attestation straight from this line, and a reworded or abbreviated one cannot be read.
Ask as early as you can, because a review job that has already started reads the body as it was when it started.
The line covers one commit, so if anything pushes to the branch afterwards - including the pipeline's own later steps - ask again for the new head; an uncovered commit is simply reviewed in full, which is the safe outcome and nothing to work around.
EOF
)
      fi
      ;;
  esac

  SETUP_REGION="1. First action: create your branch: \`git checkout -b fm/$ID\`$setup2"
  RULE_REGION="$rule1"
  DOD_REGION="$dod"
}

# --apply-testing-skip: rewrite ONLY those three regions of an existing ship
# brief, in place, from the delivery mode and the resolved skip flag its
# dispatch was validated against. bin/fm-spawn.sh is the only caller.
#
# This is what makes the captain's flag a single action: spawn already mints the
# authorization, so it also brings the brief the worker actually reads into
# agreement with it, and there is no second invocation here to remember or to
# get wrong. Nothing about the AUTHORIZATION passes through this path - it
# writes worker-facing prose and no token, no meta field, and no signature -
# which is why a brief carrying skip text has never been, and still is not,
# evidence that a skip was granted.
if [ "$APPLY_SKIP" -eq 1 ]; then
  [ -n "$APPLY_MODE" ] || { echo "error: --apply-testing-skip requires --mode <delivery-mode>" >&2; exit 1; }
  if [ ! -f "$BRIEF" ] || [ -L "$BRIEF" ]; then
    echo "error: --apply-testing-skip needs a regular brief file at $BRIEF" >&2
    exit 1
  fi
  # Defence in depth: spawn validated this pair already, so a refusal here means
  # the two disagree, which must stop rather than write half an answer.
  fm_testing_skip_check_mode "$APPLY_MODE" || exit 1
  LOCAL_SKIP=$FM_TESTING_SKIP_LOCAL
  CI_SKIP=$FM_TESTING_SKIP_CI
  WANT_STATE=$(brief_skip_state "$LOCAL_SKIP" "$CI_SKIP")

  count_fixed() { grep -cFx -- "$1" "$BRIEF" || true; }
  n_sb=$(count_fixed "$BRIEF_REGION_SETUP_BEGIN")
  n_se=$(count_fixed "$BRIEF_REGION_SETUP_END")
  n_rb=$(count_fixed "$BRIEF_REGION_RULE_BEGIN")
  n_re=$(count_fixed "$BRIEF_REGION_RULE_END")
  n_de=$(count_fixed "$BRIEF_REGION_DOD_END")
  n_db=$(grep -c "^$BRIEF_REGION_DOD_PREFIX " "$BRIEF" || true)
  MARKER_TOTAL=$((n_sb + n_se + n_rb + n_re + n_db + n_de))

  if [ "$MARKER_TOTAL" -eq 0 ]; then
    # A brief scaffolded before this contract existed. With no skip asked for
    # there is nothing to do and nothing is lost, so say so and continue; with a
    # skip asked for there is no region to write it into, and launching a worker
    # on ordinary instructions while its record says the testing was skipped is
    # exactly the silent half-skip this design removes.
    if [ "$WANT_STATE" = none ]; then
      echo "note: $BRIEF predates the machine-written testing-skip regions; nothing to apply"
      exit 0
    fi
    echo "error: $BRIEF has no machine-written testing-skip regions, so the worker's own instructions cannot be brought into agreement with this dispatch." >&2
    echo "error: that brief was scaffolded before this contract (or written by hand); re-scaffold it with bin/fm-brief.sh and re-dispatch, rather than launching a worker whose instructions and whose record disagree." >&2
    exit 1
  fi
  if [ "$n_sb" -ne 1 ] || [ "$n_se" -ne 1 ] || [ "$n_rb" -ne 1 ] \
    || [ "$n_re" -ne 1 ] || [ "$n_db" -ne 1 ] || [ "$n_de" -ne 1 ]; then
    echo "error: $BRIEF does not carry exactly one of each machine-written region marker (setup $n_sb/$n_se, rule $n_rb/$n_re, done $n_db/$n_de); refusing to rewrite a brief whose structure is not the scaffold's." >&2
    exit 1
  fi

  HAVE_STATE=$(sed -n "s|^$BRIEF_REGION_DOD_PREFIX skip=\([a-z]*\) -->\$|\1|p" "$BRIEF")
  if [ "$HAVE_STATE" = "$WANT_STATE" ]; then
    # Byte-identical is not merely an optimization: an unchanged brief is never
    # rewritten, so a respawn cannot silently revert an adjustment firstmate made
    # by hand to a region it happens to own.
    exit 0
  fi

  render_ship_regions "$APPLY_MODE" "$LOCAL_SKIP" "$CI_SKIP"
  TMPD="$BRIEF.apply.$$"
  mkdir -p "$TMPD"
  trap 'rm -rf "$TMPD"' EXIT
  printf '%s\n' "$SETUP_REGION" > "$TMPD/setup"
  printf '%s\n' "$RULE_REGION" > "$TMPD/rule"
  printf '%s\n' "$DOD_REGION" > "$TMPD/dod"
  awk -v sb="$BRIEF_REGION_SETUP_BEGIN" -v se="$BRIEF_REGION_SETUP_END" \
      -v rb="$BRIEF_REGION_RULE_BEGIN" -v re="$BRIEF_REGION_RULE_END" \
      -v dp="$BRIEF_REGION_DOD_PREFIX" -v de="$BRIEF_REGION_DOD_END" \
      -v state="$WANT_STATE" \
      -v sf="$TMPD/setup" -v rf="$TMPD/rule" -v df="$TMPD/dod" '
    function emit(f,   line) { while ((getline line < f) > 0) print line; close(f) }
    skipping && $0 == endmark { print; skipping = 0; next }
    skipping { next }
    $0 == sb { print; emit(sf); endmark = se; skipping = 1; next }
    $0 == rb { print; emit(rf); endmark = re; skipping = 1; next }
    index($0, dp " ") == 1 { print dp " skip=" state " -->"; emit(df); endmark = de; skipping = 1; next }
    { print }
  ' "$BRIEF" > "$TMPD/out"
  # A brief that lost its closing markers on the way out would leave the next
  # apply unable to find its regions, so the result is re-checked before it
  # replaces the original rather than after.
  for m in "$BRIEF_REGION_SETUP_END" "$BRIEF_REGION_RULE_END" "$BRIEF_REGION_DOD_END"; do
    grep -qFx -- "$m" "$TMPD/out" || {
      echo "error: rewriting $BRIEF lost the '$m' marker; the original is unchanged" >&2
      exit 1
    }
  done
  # Renamed rather than written over the original, so an interruption mid-write
  # can never leave the worker a truncated brief; the temp dir is a sibling, so
  # the rename is atomic.
  mv "$TMPD/out" "$BRIEF"
  echo "applied: $BRIEF (mode=$APPLY_MODE, testing skip $HAVE_STATE -> $WANT_STATE)"
  exit 0
fi

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Give every routed-work phase a stable key: open it with \`working [key=<work-slug>]: {material phase}\`, and use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved [key=<slug>]: {how it was decided or unblocked}\` with the SAME key you opened it under, so it is durably closed instead of resurfacing behind later unrelated events.
The key token goes before the colon, exactly as written here: \`resolved [key=api-shape]: ...\`, never \`resolved: [key=api-shape] ...\`.
A \`resolved:\` with no key closes only the unkeyed decision, so a mismatched or missing key leaves the real one open and firstmate keeps chasing it.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
HERDR_SECTION=$(cat <<'EOF'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
)
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.
Write findings into the report file as you go rather than composing it at the end, so an interruption or context compaction cannot erase what you have learned.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   If you may have more than one decision or blocker open at once, give each a key when you OPEN it - \`needs-decision [key=<slug>]: {summary}\`, \`blocked [key=<slug>]: {why}\` - so they can be closed independently.
   When firstmate replies or a blocker clears and you resume, append \`resolved [key=<slug>]: {how it was decided or unblocked}\` with the SAME key, so that decision or blocker is durably closed and does not keep resurfacing.
   The key token goes before the colon, exactly as written here: \`resolved [key=api-shape]: ...\`, never \`resolved: [key=api-shape] ...\`.
   A \`resolved:\` with no key closes only the unkeyed decision, so closing the wrong key leaves the real request open and firstmate keeps chasing it.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

# A scaffold never carries a testing skip: the flags are refused above, and
# bin/fm-spawn.sh rewrites the three regions below at dispatch when the captain
# authorizes one. So a brief is always born in its ordinary shape.
render_ship_regions "$MODE" off off
SKIP_STATE=$(brief_skip_state off off)

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

$BRIEF_REGION_SETUP_BEGIN
$SETUP_REGION
$BRIEF_REGION_SETUP_END

# Rules
$BRIEF_REGION_RULE_BEGIN
$RULE_REGION
$BRIEF_REGION_RULE_END
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   If you may have more than one decision or blocker open at once, give each a key when you OPEN it - \`needs-decision [key=<slug>]: {summary}\`, \`blocked [key=<slug>]: {why}\` - so they can be closed independently.
   When firstmate replies or a blocker clears and you resume, append \`resolved [key=<slug>]: {how it was decided or unblocked}\` with the SAME key, so that decision or blocker is durably closed and does not keep resurfacing.
   The key token goes before the colon, exactly as written here: \`resolved [key=api-shape]: ...\`, never \`resolved: [key=api-shape] ...\`.
   A \`resolved:\` with no key closes only the unkeyed decision, so closing the wrong key leaves the real request open and firstmate keeps chasing it.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. Commit early and often on your branch: whenever a coherent unit of work builds or passes,
   commit it before moving on, and never sit on one large uncommitted diff. Uncommitted changes
   are invisible to firstmate's monitoring and are discarded when this worktree is recycled;
   commits survive any interruption, restart, or context compaction.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$BRIEF_REGION_DOD_PREFIX skip=$SKIP_STATE -->
$DOD_REGION
$BRIEF_REGION_DOD_END
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
