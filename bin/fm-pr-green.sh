#!/usr/bin/env bash
# Report whether a task's PR is green on GitHub, addressed by the PR itself, so
# a ship worker can learn its own CI state and report done on its own evidence.
#
# WHY THIS EXISTS. The no-mistakes pipeline's own `ci` step polls `gh pr checks`
# with no PR number, from the pipeline's worktree under ~/.no-mistakes/worktrees/,
# which is at a detached HEAD. gh therefore exits 1 with "could not determine
# current branch: failed to run git: not on any branch" on every poll, the step
# never sees green, and it loops for up to 168 h emitting
# "warning: could not check CI: gh pr checks: exit status 1" while the PR is
# genuinely green on GitHub. Reproduced 2026-09-07 on two PRs (ELN 28, 21 minutes
# of looping; ELN 30, 36 polls). This command is addressed by PR URL, so it is
# immune to that failure and works from any directory, including a detached HEAD
# and a directory that is not a git repository at all.
#
# ONE OWNER. The rollup read and the classification table live in
# bin/fm-pr-lib.sh (fm_pr_rollup_read, fm_pr_rollup_classify) and are shared with
# the merge gate, so a worker can never report green on a PR
# bin/fm-pr-merge.sh would then refuse. bin/fm-pr-merge.sh's header owns the
# policy both implement.
#
# THE ONE EXCUSABLE CHECK is resolved through bin/fm-attestation-lib.sh, the
# owner the merge gate and the read-only pipeline view already share, and never
# by a second reading here. Without it this command would be useless on exactly
# the projects that need it: firstmate itself is registered direct-PR, so
# `PR must be raised via no-mistakes` fails on every one of its PRs by
# construction and every poll would report red forever (the same permanent-red
# indicator that library's header records being fixed for the pipeline view on
# 2026-08-09). An excused check is still not EVIDENCE that anything ran, so it
# is subtracted before asking whether this PR reported any checks at all,
# exactly as the merge gate subtracts it.
#
# INFRASTRUCTURE IS A DISTINCT OUTCOME from a real red, on the captain's
# standing rule of 2026-09-07: a timed-out review is an alarm, never a re-run.
# A check that never delivered a verdict about the code (it timed out, was
# cancelled, could not run, or died in seconds having written nothing) says
# nothing about the branch, so re-running it hides the alarm instead of
# answering it. Such a check is printed under the word `infrastructure` with the
# check named and the reason attached, and the brief tells the worker to report
# it and STOP rather than retry.
# THREE RULES produce it, and bin/fm-pr-lib.sh owns the first because it is part
# of the classification table the merge gate shares:
#   1. Conclusion TIMED_OUT, CANCELLED, STALE, or STARTUP_FAILURE - the check
#      itself says it never finished judging.
#   2. Conclusion FAILURE or ACTION_REQUIRED whose check-run OUTPUT text says it
#      timed out, could not run, was cancelled, lost its runner, or ran out of
#      disk. `gh pr view --json statusCheckRollup` exposes no output text at all
#      (verified 2026-09-07: its projection is __typename, completedAt,
#      conclusion, detailsUrl, name, startedAt, status, workflowName), so that
#      text is read with one extra call to repos/<o>/<r>/commits/<sha>/check-runs
#      on the head SHA already verified above.
#   3. Conclusion FAILURE that wrote NO output at all and completed within
#      FM_PR_INFRA_SECONDS (default 10) of starting - a job that died before it
#      could say anything.
# RULE 3 HAS A KNOWN FALSE POSITIVE and it is disclosed rather than hidden: a
# gate job that deliberately refuses fast looks identical from outside. This
# repo has one - `PR must be raised via no-mistakes` fails in ~2 seconds writing
# no output (observed 2026-09-07 on PR 66) - so every rule-3 finding carries
# "may instead be a gate that refused fast" in its printed reason. Nothing is
# lost by the ambiguity: both outcomes are non-green, both stop the worker, and
# the reason names the doubt for whoever reads it.
# Rules 2 and 3 live in THIS script rather than the shared table because they
# need data the rollup does not carry, and because the merge gate has no use for
# the distinction: it refuses on either. They can only ever move a check from
# failing to infrastructure, never the reverse and never to green, so a failed
# enrichment call degrades to rule 1 alone rather than weakening any verdict.
#
# WHAT THIS DOES NOT DO, deliberately, so its green is never weaker than the
# merge gate's:
#   - Zero checks is never green, and neither is a rollup left empty by
#     discounting an excused check. The merge gate has two captain authorities
#     that let an empty rollup through, because the captain decides there whether
#     absent CI was deliberate; a worker has no such decision to make, and an
#     empty rollup is indistinguishable from CI that has not reported yet.
#   - It merges nothing, records nothing, and writes nothing.
#
# THE HEAD SHA is read from the PR on GitHub (`gh pr view --json headRefOid`,
# the same reader bin/fm-pr-check.sh uses), never from a local ref: a local HEAD
# can be ahead of, behind, or unrelated to what CI actually measured. It is read
# again after the rollup and must be unchanged; a head that moved mid-read means
# the rollup and the SHA describe different commits, which is exactly the
# false-green this command exists to prevent, so that is not green either.
#
# Usage: fm-pr-green.sh <task-id> [<pr-url>]
#   The PR URL wins when given, which is the worker's case: at the moment a
#   worker polls, the pipeline has opened the PR but firstmate has not yet
#   recorded it. With no URL the task's recorded pr= is used, which is
#   firstmate's case after bin/fm-pr-check.sh has run.
# Exit 0 prints one line on stdout:  green: <url> <sha> <n> checks
# Exit 1 names every failing, infrastructure, unfinished, or unreadable check on
#   stderr. An infrastructure line is printed as
#   `infrastructure: <check name> - <reason>`.
# Exit 2 is a malformed request or an unusable PR reference.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-attestation-lib.sh
. "$SCRIPT_DIR/fm-attestation-lib.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: fm-pr-green.sh <task-id> [<pr-url>]" >&2
  exit 2
fi
ID=$1
RAW_URL=${2-}
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid task id" >&2
  exit 2
fi

if [ -n "$RAW_URL" ]; then
  if ! fm_pr_url_parse "$RAW_URL"; then
    echo "error: not a GitHub pull request link: $RAW_URL" >&2
    exit 2
  fi
else
  # Task-derived paths are constructed only after the canonical ID validation.
  META="$STATE/$ID.meta"
  if ! fm_pr_metadata_identity_parse "$META"; then
    echo "error: no PR is recorded for $ID, and none was given" >&2
    echo "error: pass the PR link the pipeline printed: fm-pr-green.sh $ID <pr-url>" >&2
    exit 2
  fi
  fm_pr_url_parse "$FM_PR_META_URL" || exit 2
fi
URL=$FM_PR_URL

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is not installed, so the PR's checks cannot be read" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-green.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ERR="$WORK/gh.err"

# head_read: print the PR's head SHA from GitHub, or fail. Bounded, because a
# worker calls this on a loop and a hung read would wedge it.
head_read() {
  local sha
  sha=$(fm_pr_bounded gh pr view "$URL" --json headRefOid -q .headRefOid 2> "$ERR") || return 1
  fm_pr_head_valid "$sha" || return 1
  printf '%s' "$sha"
}

if ! HEAD_BEFORE=$(head_read); then
  cat "$ERR" >&2
  echo "error: could not read the PR's head commit (see above); not green" >&2
  exit 1
fi

set +e
fm_pr_rollup_read "$URL" "$ERR"
rollup_rc=$?
set -e
if [ "$rollup_rc" -ne 0 ]; then
  cat "$ERR" >&2
  echo "error: could not read the PR's checks (gh exit $rollup_rc, see above); not green" >&2
  exit 1
fi

if ! HEAD_AFTER=$(head_read); then
  cat "$ERR" >&2
  echo "error: could not re-read the PR's head commit (see above); not green" >&2
  exit 1
fi
if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ]; then
  echo "error: the PR's head moved from $HEAD_BEFORE to $HEAD_AFTER while its checks were being read, so those checks do not describe the current head; not green" >&2
  exit 1
fi

# The one excusable check is diverted rather than counted, and its authority is
# resolved once afterwards, only if it turned out to be failing at all.
ATTESTATION_CHECK_NAME=$(fm_attestation_check_name)
fm_pr_rollup_classify "$FM_PR_ROLLUP_TSV" "$ATTESTATION_CHECK_NAME"

checks_exempted=0
if [ "$FM_PR_ROLLUP_EXEMPT_FAILING" -gt 0 ]; then
  if authority=$(fm_attestation_authority "$ID" "$STATE/$ID.meta" \
      "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$FM_HOME" "$SCRIPT_DIR"); then
    checks_exempted=$FM_PR_ROLLUP_EXEMPT_FAILING
    echo "note: PR check excused: $ATTESTATION_CHECK_NAME ($(printf '%s' "$authority" | head -1))" >&2
  else
    # Fed back into the ordinary failing list rather than reported here, so it
    # goes through the one reporting and counting path below like any other red
    # and cannot be counted without being named. One entry per occurrence,
    # because a re-run can leave the name in the rollup twice.
    seen=0
    while [ "$seen" -lt "$FM_PR_ROLLUP_EXEMPT_FAILING" ]; do
      seen=$((seen + 1))
      FM_PR_ROLLUP_FAILING_NAMES=$FM_PR_ROLLUP_FAILING_NAMES$ATTESTATION_CHECK_NAME$'\n'
    done
  fi
fi

# --- infrastructure enrichment (rules 2 and 3; contract in this file's header)
# One extra call, keyed on the head SHA already verified above. It produces
# "<name><TAB><reason>" for every check run that looks like machinery rather
# than a verdict. A failure here is not fatal: rule 1 has already run inside the
# shared classifier, so the worst case is a check reported as a plain red.
INFRA_HINTS="$WORK/infra-hints.tsv"
: > "$INFRA_HINTS"
infra_secs=${FM_PR_INFRA_SECONDS:-10}
case "$infra_secs" in ''|*[!0-9]*) infra_secs=10 ;; esac
fm_pr_bounded gh api --paginate \
  "repos/$FM_PR_OWNER/$FM_PR_REPO/commits/$HEAD_BEFORE/check-runs?per_page=100" \
  --jq "
    .check_runs[]
    | (.conclusion // \"\" | ascii_downcase) as \$c
    | ((.output.title // \"\") + \" \" + (.output.summary // \"\")) as \$raw
    | (\$raw | ascii_downcase) as \$t
    | (if (.started_at != null and .completed_at != null)
         then ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601))
         else -1 end) as \$secs
    | if ([\"failure\", \"action_required\"] | index(\$c))
         and (\$t | test(\"timed out|timeout|could not run|cannot run|unable to run|was cancelled|was canceled|runner lost|lost communication|no space left|infrastructure failure\"))
      then [.name, \"its report says the job did not run to a verdict\"]
      elif \$c == \"failure\" and ((\$raw | gsub(\"[[:space:]]\"; \"\")) == \"\")
           and \$secs >= 0 and \$secs <= $infra_secs
      then [.name, \"it ended after \" + (\$secs | floor | tostring) + \"s having written no report, so it may never have run; it may instead be a gate that refused fast\"]
      else empty end
    | @tsv
  " > "$INFRA_HINTS" 2>/dev/null || : > "$INFRA_HINTS"

# infra_reason <check name>: print the enrichment reason for that name, or
# nothing. Matched on the whole first TSV field, so a name that is a prefix of
# another cannot borrow its reason.
infra_reason() {
  awk -F'\t' -v want="$1" '$1 == want { print $2; exit }' "$INFRA_HINTS"
}

# Rule 1's findings are already separated by the shared classifier. Rules 2 and
# 3 move a check the classifier called failing into the same class, which is the
# only direction this pass may ever move one.
infra_lines=
failing_lines=
failing_count=0
infra_count=$FM_PR_ROLLUP_INFRA
while IFS= read -r name; do
  infra_lines=$infra_lines"infrastructure: $name - it reported that it timed out, was cancelled, went stale, or failed to start"$'\n'
done < <(fm_pr_rollup_each "$FM_PR_ROLLUP_INFRA_NAMES")
while IFS= read -r name; do
  reason=$(infra_reason "$name")
  if [ -n "$reason" ]; then
    infra_count=$((infra_count + 1))
    infra_lines=$infra_lines"infrastructure: $name - $reason"$'\n'
  else
    failing_count=$((failing_count + 1))
    failing_lines=$failing_lines"error: PR check is failing: $name"$'\n'
  fi
done < <(fm_pr_rollup_each "$FM_PR_ROLLUP_FAILING_NAMES")

printf '%s' "$failing_lines" >&2
printf '%s' "$infra_lines" >&2
while IFS= read -r name; do
  echo "note: PR check has not finished: $name" >&2
done < <(fm_pr_rollup_each "$FM_PR_ROLLUP_PENDING_NAMES")
while IFS= read -r name; do
  echo "error: PR check state could not be classified: $name" >&2
done < <(fm_pr_rollup_each "$FM_PR_ROLLUP_UNKNOWN_NAMES")

# Infrastructure is reported BEFORE red, because its remedy is the one that must
# not be got wrong: a re-run buries it. A PR carrying both still reports both.
if [ "$infra_count" -gt 0 ]; then
  echo "error: $infra_count PR check(s) never delivered a verdict about this branch (named above); that is an infrastructure outcome, not a red PR" >&2
  echo "error: do NOT re-run them - a timed-out or dead check is an alarm, and a re-run hides it. Report this and stop." >&2
fi
if [ "$failing_count" -gt 0 ]; then
  echo "error: $failing_count failing PR check(s) (named above); this PR is red" >&2
fi
if [ "$infra_count" -gt 0 ] || [ "$failing_count" -gt 0 ]; then
  exit 1
fi
if [ "$FM_PR_ROLLUP_UNKNOWN" -gt 0 ]; then
  echo "error: $FM_PR_ROLLUP_UNKNOWN PR check(s) could not be classified (named above); not green" >&2
  exit 1
fi
if [ "$FM_PR_ROLLUP_PENDING" -gt 0 ]; then
  echo "error: $FM_PR_ROLLUP_PENDING PR check(s) have not finished (named above); this PR is not red, it is unfinished - wait and re-run" >&2
  exit 1
fi
# An excused check is an authorized RED, not evidence that anything ran, so it is
# subtracted before asking whether this PR reported any checks at all.
checks_evidence=$((FM_PR_ROLLUP_TOTAL - checks_exempted))
if [ "$checks_evidence" -eq 0 ]; then
  if [ "$FM_PR_ROLLUP_TOTAL" -eq 0 ]; then
    echo "error: the PR reports no checks at all; absent CI is not green - wait for CI to report, then re-run" >&2
  else
    echo "error: the PR's only check(s) were excused, so nothing on this PR actually verified the branch; that is not green - wait for CI to report, then re-run" >&2
  fi
  exit 1
fi

printf 'green: %s %s %s checks\n' "$URL" "$HEAD_BEFORE" "$checks_evidence"
