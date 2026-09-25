#!/usr/bin/env bash
# fm-upstream-wait.sh - the machine gate behind "waiting on action from upstream",
# and the recheck that keeps it true.
#
# THE CAPTAIN'S REQUEST, 2026-09-24, and the sentence that shapes every line
# below: "if one of the coding agent pipelines is waiting on upstream ... we
# should have the ability for the FIRSTMATE, not the agent, to label the agent as
# 'waiting on upstream' ... SPECIFICALLY NOT INCLUDING a coding agent whose code
# is running through the CI process - only when the CI has been all passed and
# the agent is doing nothing but waiting." And the failure to design against:
# "the key error case to avoid is crewmates lazily pretending they are waiting on
# upstream when they are not, so we need to think about how to mechanically
# enforce this."
#
# So the crewmate's own yes is REQUIRED and never SUFFICIENT. Firstmate asks it
# the captain's question through bin/fm-send.sh and it answers by appending
#   upstream-wait-ready: <plain English action>
# to its status log. That line is one of the gate's conditions, not the gate. A
# worker holds no signing key, so it cannot mint the record, cannot extend one,
# and cannot obtain one for a task this gate refused; and the gate re-runs on the
# recheck cadence, so a wait that stops being true drops itself rather than
# standing on the signature it was granted.
#
# WHAT THIS SCRIPT OWNS: the gate, the recheck, and listing what is standing.
# bin/fm-monitor.sh owns GRANTING one (--upstream-wait / --upstream-resume),
# beside the captain's own exemption it is the sibling of; bin/fm-ack-lib.sh owns
# fm_upstream_waiting, the verdict every supervision surface asks through
# fm_supervision_suspended; docs/captain-driven.md owns the contract.
#
# Usage:
#   fm-upstream-wait.sh --gate <task-id> [--reason "<awaited action>"]
#   fm-upstream-wait.sh --recheck [<task-id>...]
#   fm-upstream-wait.sh --list
#
#   --gate     run every condition and print each verdict, writing NOTHING.
#              --reason supplies the awaited action for a scout task whose gate
#              is about the upstream issue that reason names, before any record
#              exists to read it from.
#   --recheck  re-run the gate for every standing wait (or the named ones) and
#              DROP any whose gate no longer passes, naming what changed. With
#              the record gone, ordinary supervision resumes by itself and the
#              task's real state alarms through the predicate it always did -
#              which is the wake, rather than a second wake mechanism that could
#              disagree with it.
#   --list     every standing wait, with the action it is waiting on.
#
# THE CONDITIONS, and why each one is here.
#
# A SHIP task is waiting on upstream only when there is nothing left it could do:
#   crew-said    its status log's LAST line is `upstream-wait-ready: <action>`.
#                Last, not merely present: anything appended after it is the
#                worker saying something newer, and firstmate asks again.
#   pr-recorded  state/<id>.meta carries a pr=. The captain: "I don't think we
#                will ever be waiting on the upstream until we have the complete
#                PR right?" - true for a ship task, and this is where it is
#                enforced rather than trusted.
#   pr-open      GitHub reports that PR OPEN. A merged or closed PR is not a wait.
#   worktree-clean   `git status --porcelain` is empty. An uncommitted diff is
#                work the worker still has.
#   nothing-unpushed the PR's own head contains the worktree's HEAD. This is the
#                strong form of "your code is pushed": an upstream ref can be
#                absent or stale, so the question is asked of the PR GitHub is
#                actually showing rather than of a local tracking branch.
#   checks-green bin/fm-pr-green.sh, the same authority the merge gate reaches
#                its verdict through. Reused rather than re-derived, so this can
#                never call green a PR that gate would refuse, and so the one
#                excusable check keeps exactly the one excusal it already has.
#                This is the captain's "SPECIFICALLY NOT INCLUDING a coding agent
#                whose code is running through the CI process": a pending check
#                is not green, so a task mid-CI cannot be declared waiting.
#   approval-gated  the ALTERNATIVE to checks-green, and the only one. A PR from
#                a first-time contributor to an upstream repository runs no
#                workflow at all until a maintainer presses "Approve and run",
#                so it reports ZERO checks - and zero checks is never green, so
#                checks-green alone can never declare that task waiting however
#                long it sits there. This condition replaces checks-green, and
#                ONLY when the PR reports zero checks, so no other PR's verdict
#                moves. It passes only when GitHub ITSELF says the runs are held
#                for approval; silence fails it, because "no checks and no
#                explanation" is indistinguishable from CI that has not started.
#
# WHAT GITHUB ACTUALLY RETURNS for an approval-gated PR, read 2026-09-25 against
# https://github.com/kunchenguid/firstmate/pull/5562 (gh 2.100.0), whose runs had
# sat on the maintainer's "Approve and run" button all day:
#   gh pr view 5562 --repo kunchenguid/firstmate --json statusCheckRollup
#     -> {"statusCheckRollup":[]}                             (and state OPEN,
#        isCrossRepository true, headRefOid b82269f1...)
#   gh api repos/kunchenguid/firstmate/commits/<sha>/check-runs
#     -> {"total_count":0,"check_runs":[]}
#   gh api repos/kunchenguid/firstmate/commits/<sha>/status
#     -> {"state":"pending","total_count":0,"statuses":[]}
#   gh api repos/kunchenguid/firstmate/actions/runs?head_sha=<sha>
#     -> total_count 3, every run {"status":"completed",
#        "conclusion":"action_required","event":"pull_request"}
# Note the shape: the awaiting-approval signal lives in the run's CONCLUSION and
# the run reads as "completed", NOT as a status of action_required. This script
# accepts either field carrying action_required, because GitHub documents
# action_required in both enums, but the conclusion is the one observed.
# statusCheckRollup is read for the zero-checks half because it is one field on
# a call the gate already makes and it covers check-runs and commit statuses
# together - both were empirically zero above when it was empty. A reply that
# does not carry the field at all is treated as UNKNOWN rather than as zero, so
# such a PR stays on checks-green: reading an absent field as "no checks" would
# hand the looser branch every PR GitHub answered incompletely about, which is
# the same inference from silence this condition exists to refuse.
#
# A SCOUT task has no branch to push and no PR to be green, and the captain named
# the one legitimate case: "a scouting agent who has submitted an issue and is
# waiting for it to be marked ready-for-pr before starting the PR build". So:
#   crew-said    the same last-line condition.
#   report       data/<id>/report.md exists - the scout's deliverable is done.
#   issue-open   the awaited action names a GitHub issue or pull request link,
#                and GitHub reports it OPEN. The link is what makes the wait
#                checkable at all; a scout waiting on something with no url is
#                waiting on a sentence nobody can re-verify.
#
# Exit codes: 0 the gate passed (or the recheck/list ran clean), 1 the gate
# refused or a recheck dropped a record, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-ack-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ack-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

GH_TIMEOUT=${FM_UPSTREAM_WAIT_GH_TIMEOUT:-25}
# The green verdict's owner, overridable the way bin/fm-nm-stall.sh overrides
# its current-state reader: the gate's own subject is the CONDITIONS, and a test
# that had to drive the real green reader through a faked gh would be testing
# that reader instead. The default is the real one, so nothing in production
# reads a second opinion.
PR_GREEN_BIN=${FM_PR_GREEN_BIN:-$SCRIPT_DIR/fm-pr-green.sh}

usage() { sed -n '2,114p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=
TARGET=
REASON=
TARGETS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --gate)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      MODE=gate; TARGET=$2; shift 2 ;;
    --recheck) MODE=recheck; shift ;;
    --list) MODE=list; shift ;;
    --reason)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REASON=$2; shift 2 ;;
    -*) usage >&2; exit 2 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; exit 2; }

run_bounded() {  # <seconds> <command...>
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Each condition prints its own verdict line, and the gate runs EVERY one rather
# than stopping at the first refusal. A refusal that named one problem when there
# were three would send firstmate round this loop three times, and the captain's
# question to the worker is a single question about all of them.
GATE_FAILED=0
ok() { printf 'gate ok: %s\n' "$1"; }
no() { printf 'gate FAIL: %s\n' "$1"; GATE_FAILED=1; }

# The crewmate's own answer to the captain's question. Last line, so anything it
# said afterwards re-opens the question.
GATE_ACTION=
gate_crew_said() {  # <id>
  local log last
  log="$STATE/$1.status"
  if [ ! -f "$log" ]; then
    no "crew-said: $1 has no status log, so it has not answered the question"
    return
  fi
  last=$(tail -n 1 "$log" 2>/dev/null || true)
  # The optional "[t=<epoch>] " report stamp is the status grammar's, and
  # bin/fm-classify-lib.sh owns that both forms are permanent.
  last=${last#\[t=*\] }
  case "$last" in
    upstream-wait-ready:*)
      GATE_ACTION=${last#upstream-wait-ready:}
      GATE_ACTION=${GATE_ACTION# }
      if [ -z "$GATE_ACTION" ]; then
        no "crew-said: $1 answered upstream-wait-ready with no action named"
        return
      fi
      ok "crew-said: $1 reports it is waiting on \"$GATE_ACTION\""
      ;;
    *)
      no "crew-said: $1's last report is not an upstream-wait-ready line, so ask it the question again"
      ;;
  esac
}

# One `gh pr view` for the PR's lifecycle and head, qualified with --repo from
# the recorded link through the one owner of that grammar: a bare number resolves
# against the working directory's repository, which is never the task's.
PR_STATE=
PR_HEAD=
PR_CHECKS=
gh_pr_read() {  # <url> -> 0 and sets PR_STATE/PR_HEAD/PR_CHECKS
  local raw
  PR_STATE=; PR_HEAD=; PR_CHECKS=
  fm_pr_url_parse "$1" || return 1
  command -v gh >/dev/null 2>&1 || return 1
  raw=$(run_bounded "$GH_TIMEOUT" gh pr view "$FM_PR_NUMBER" \
    --repo "$FM_PR_OWNER/$FM_PR_REPO" --json state,headRefOid,statusCheckRollup 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  PR_STATE=$(printf '%s' "$raw" | jq -r '.state // ""' 2>/dev/null) || return 1
  PR_HEAD=$(printf '%s' "$raw" | jq -r '.headRefOid // ""' 2>/dev/null) || return 1
  # The rollup carries check-runs and commit statuses together, so its length is
  # the whole "has anything reported on this head" question in one field of a
  # call already being made.
  #
  # ABSENT is not zero, and the difference decides which branch judges the PR.
  # An answer that does not carry the field at all is GitHub not telling this
  # home about the head, which is the same silence the approval-gated condition
  # refuses on - so an empty PR_CHECKS keeps the PR on checks-green, the
  # stricter condition it was always judged by. Only a rollup GitHub actually
  # returned, and returned empty, means there is nothing on the head.
  PR_CHECKS=$(printf '%s' "$raw" |
    jq -r 'if has("statusCheckRollup") and .statusCheckRollup != null then ([.statusCheckRollup[]] | length) else "" end' 2>/dev/null) || return 1
  [ -n "$PR_STATE" ]
}

# The first http(s) GitHub issue or pull-request link in the awaited action.
issue_url_of() {  # <text>
  printf '%s' "$1" |
    grep -oE 'https://[A-Za-z0-9.-]*github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[0-9]+' |
    head -1 || true
}

GATE_EVIDENCE=

# The alternative to checks-green, asked ONLY of a PR reporting zero checks.
# GitHub's own word is the whole condition: a run for this head that it reports
# as action_required is it saying "this is held for a maintainer's approval".
# Every other answer - no runs at all, a run queued or running or finished, or a
# read this home is not permitted to make - refuses, because the captain's rule
# is that a wait has to be re-verifiable and silence re-verifies nothing.
APPROVAL_GATED_RUNS=
gate_approval_gated() {  # <pr-url>, with PR_HEAD already read -> 0 pass
  local raw total seen gated
  APPROVAL_GATED_RUNS=
  if ! command -v gh >/dev/null 2>&1 || ! fm_pr_url_parse "$1"; then
    no "approval-gated: $1 reports no checks at all, and this home cannot ask GitHub why, so nothing about it is verified"
    return 1
  fi
  raw=$(run_bounded "$GH_TIMEOUT" gh api \
    "repos/$FM_PR_OWNER/$FM_PR_REPO/actions/runs?head_sha=$PR_HEAD&per_page=100" 2>/dev/null) || raw=
  total=$(printf '%s' "$raw" | jq -r '.total_count // empty' 2>/dev/null) || total=
  if [ -z "$total" ]; then
    no "approval-gated: $1 reports no checks at all, and GitHub would not tell this home the workflow runs for $PR_HEAD, so nothing says they are held for approval"
    return 1
  fi
  seen=$(printf '%s' "$raw" | jq -r '[.workflow_runs[]?] | length' 2>/dev/null) || seen=0
  if [ "$total" -eq 0 ]; then
    no "approval-gated: $1 reports no checks at all and GitHub reports no workflow runs for $PR_HEAD either, so its CI has not started rather than being held for approval"
    return 1
  fi
  if [ "$seen" -lt "$total" ]; then
    no "approval-gated: GitHub reports $total workflow runs for $PR_HEAD but returned only $seen, so this home cannot say every one of them is held for approval"
    return 1
  fi
  # action_required in EITHER field: the conclusion is what PR 5562 carried, the
  # status is the other place GitHub documents the same value.
  gated=$(printf '%s' "$raw" |
    jq -r '[.workflow_runs[]? | select(.status == "action_required" or .conclusion == "action_required")] | length' 2>/dev/null) || gated=
  if [ -z "$gated" ]; then
    no "approval-gated: could not read the workflow run states for $PR_HEAD, so nothing about them is verified"
    return 1
  fi
  if [ "$gated" -lt "$total" ]; then
    no "approval-gated: $((total - gated)) of $total workflow runs for $PR_HEAD are not held for approval, so this task is still running through CI rather than waiting"
    return 1
  fi
  APPROVAL_GATED_RUNS=$total
  ok "approval-gated: $1 reports no checks at all because GitHub is holding all $total of its workflow runs for a maintainer's approval"
  return 0
}

gate_ship() {  # <id> <meta>
  local id=$1 meta=$2 pr wt head green n
  pr=$(meta_field "$meta" pr)
  if [ -z "$pr" ]; then
    no "pr-recorded: $id has no PR on record, and a ship task with no PR still has work of its own to do"
    return
  fi
  ok "pr-recorded: $pr"

  if ! gh_pr_read "$pr"; then
    no "pr-open: could not read $pr from GitHub, so nothing about it is verified"
    return
  fi
  if [ "$PR_STATE" != OPEN ]; then
    no "pr-open: GitHub reports $pr $PR_STATE, which is not a wait - it is over"
    return
  fi
  ok "pr-open: GitHub reports it OPEN"

  wt=$(meta_field "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    no "worktree-clean: $id has no local copy left to check for unfinished work"
  elif [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    no "worktree-clean: $id has uncommitted changes, which is work it still has"
  else
    ok "worktree-clean: nothing uncommitted"
    head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
    if [ -z "$head" ]; then
      no "nothing-unpushed: could not read $id's local HEAD"
    elif [ "$head" = "$PR_HEAD" ]; then
      ok "nothing-unpushed: the PR's head is this copy's HEAD ($PR_HEAD)"
    elif git -C "$wt" merge-base --is-ancestor "$head" "$PR_HEAD" 2>/dev/null; then
      ok "nothing-unpushed: the PR's head already contains this copy's HEAD"
    else
      no "nothing-unpushed: $id holds commits the PR does not, so its work is not all pushed"
    fi
  fi

  # Zero checks is the ONLY thing that sends this to the other branch, and zero
  # checks is never green, so checks-green's verdict is untouched for every PR
  # that has any. Which branch decided it is named in the evidence, so a reader
  # of a standing wait can tell the two grants apart.
  if [ "${PR_CHECKS:-}" = 0 ]; then
    if gate_approval_gated "$pr"; then
      GATE_EVIDENCE="pr=$pr head=$PR_HEAD approval-gated=$APPROVAL_GATED_RUNS runs"
    fi
  elif green=$(FM_HOME="$FM_HOME" "$PR_GREEN_BIN" "$id" "$pr" 2>/dev/null); then
    n=$(printf '%s' "$green" | awk '{print $4}')
    ok "checks-green: $pr is green at $PR_HEAD (${n:-?} checks)"
    GATE_EVIDENCE="pr=$pr head=$PR_HEAD checks=${n:-?}"
  else
    # The count is in the refusal because this is also the line a recheck relays
    # when an approval-gated wait ends: the maintainer pressed the button, a run
    # started, and a check has appeared on the head that had none.
    no "checks-green: $pr is not green${PR_CHECKS:+ with $PR_CHECKS check(s) now reported on its head}, so this task is running through CI rather than waiting"
  fi
}

gate_scout() {  # <id>
  local id=$1 url report api
  report="$DATA/$id/report.md"
  if [ -f "$report" ]; then
    ok "report: $report exists, so the investigation itself is finished"
  else
    no "report: $id has written no report yet, so it is still working rather than waiting"
  fi
  url=$(issue_url_of "${REASON:-$GATE_ACTION}")
  if [ -z "$url" ]; then
    no "issue-open: the awaited action names no GitHub issue or pull request link, so nobody can re-verify it"
    return
  fi
  if ! gh_pr_read "$url"; then
    # An ISSUE is not a pull request, and `gh pr view` will not read one. The
    # api read answers for both, addressed by the url's own owner/repo/number so
    # it cannot resolve against this directory.
    api=${url#https://}
    api=${api#*/}
    api=$(printf '%s' "$api" | sed 's|/pull/|/issues/|')
    PR_STATE=$(run_bounded "$GH_TIMEOUT" gh api "repos/$api" --jq '.state // ""' 2>/dev/null) || PR_STATE=
  fi
  case "$(printf '%s' "$PR_STATE" | tr '[:upper:]' '[:lower:]')" in
    open)
      ok "issue-open: GitHub reports $url open"
      GATE_EVIDENCE="issue=$url state=OPEN report=$report"
      ;;
    '')
      no "issue-open: could not read $url from GitHub, so nothing about it is verified"
      ;;
    *)
      no "issue-open: GitHub reports $url $PR_STATE, which is not a wait - it is over"
      ;;
  esac
}

run_gate() {  # <id> -> 0 pass; sets GATE_ACTION and GATE_EVIDENCE
  local id=$1 meta kind
  GATE_FAILED=0
  GATE_ACTION=
  GATE_EVIDENCE=
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    no "known-task: there is no record for $id in $STATE"
    return 1
  fi
  gate_crew_said "$id"
  kind=$(meta_field "$meta" kind)
  case "$kind" in
    scout) gate_scout "$id" ;;
    *) gate_ship "$id" "$meta" ;;
  esac
  [ "$GATE_FAILED" -eq 0 ]
}

case "$MODE" in
  gate)
    if run_gate "$TARGET"; then
      printf 'gate PASSED: %s is purely waiting on upstream\n' "$TARGET"
      printf 'gate action: %s\n' "$GATE_ACTION"
      printf 'gate evidence: %s\n' "$GATE_EVIDENCE"
      exit 0
    fi
    printf 'gate REFUSED: %s is not purely waiting on upstream; nothing was recorded\n' "$TARGET"
    exit 1
    ;;
  list)
    found=0
    for f in "$STATE"/*.upstream-wait; do
      [ -e "$f" ] || continue
      id=${f##*/}; id=${id%.upstream-wait}
      if fm_upstream_waiting "$STATE" "$id"; then
        printf 'waiting\t%s\t%s\t%s\n' "$id" "$FM_UPSTREAM_WAIT_ACTION" "$FM_UPSTREAM_WAIT_EVIDENCE"
      else
        # Reported, never dropped silently: an unverifiable record is either a
        # forged wait or a real one this home can no longer check, and both are
        # things the captain needs to see.
        printf 'INVALID\t%s\t%s\n' "$id" "does not verify against this home's key - not waiting, and still supervised"
      fi
      found=1
    done
    [ "$found" = 1 ] || printf 'no standing upstream waits\n'
    exit 0
    ;;
  recheck)
    ids=()
    if [ "${#TARGETS[@]}" -gt 0 ]; then
      ids=("${TARGETS[@]}")
    else
      for f in "$STATE"/*.upstream-wait; do
        [ -e "$f" ] || continue
        id=${f##*/}; ids+=("${id%.upstream-wait}")
      done
    fi
    dropped=0
    for id in ${ids[@]+"${ids[@]}"}; do
      fm_upstream_waiting "$STATE" "$id" || continue
      if gate_out=$(run_gate "$id" 2>&1); then
        printf 'UPSTREAM_WAIT: %s still waiting on %s\n' "$id" "$FM_UPSTREAM_WAIT_ACTION"
        continue
      fi
      # The gate's own refusal lines are what say WHAT changed, so they are
      # relayed rather than summarised: "it stopped being true" is not an
      # answer firstmate can act on. They are captured from the run that made
      # the decision, never from a second run, which could disagree with it.
      find "$STATE" -maxdepth 1 -name "$id.upstream-wait" -delete 2>/dev/null || true
      printf 'UPSTREAM_WAIT: dropped %s - it is no longer purely waiting, so supervision resumes\n' "$id"
      # A wait granted because GitHub was holding its runs for approval ends the
      # moment a maintainer presses the button: a check appears on the head, the
      # gate takes the checks-green branch instead, and that branch's refusal is
      # relayed below. Named here so the drop reads as the release it is rather
      # than as a PR that went red.
      case "$FM_UPSTREAM_WAIT_EVIDENCE" in
        *approval-gated=*)
          printf 'UPSTREAM_WAIT: %s was waiting because GitHub held its workflow runs for a maintainer to approve; that hold is over - the line below says whether a run has started or the PR itself closed\n' "$id" ;;
      esac
      printf '%s\n' "$gate_out" | grep '^gate FAIL: ' | while IFS= read -r l; do
        printf 'UPSTREAM_WAIT: %s\n' "$l"
      done
      dropped=$((dropped + 1))
    done
    [ "$dropped" -eq 0 ] || exit 1
    exit 0
    ;;
esac
