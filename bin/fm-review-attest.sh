#!/usr/bin/env bash
# Publish and check the PIPELINE-REVIEWED ATTESTATION: a signed statement that
# the no-mistakes pipeline's `review` step completed on one exact commit, so a
# project's own GitHub AI review can skip that commit as already reviewed.
#
# Usage:
#   fm-review-attest.sh attest <task-id> [--print-only]
#                        sign for the PR's CURRENT head and publish the line
#                        into its body; --print-only publishes nothing
#   fm-review-attest.sh verify <owner/repo> <task-id> <sha> <line>
#                        recompute the signature and compare; exit 0 only on a
#                        line that matches all three
#
# WHAT THIS IS FOR. A ship task's PR is reviewed by the no-mistakes pipeline
# before it is ever opened - repeatedly, across a run's review and review-fix
# rounds. A project that also runs an AI review job on its PRs therefore reviews
# the same diff again, and on the ELN those jobs timed out or could not run at
# all on PRs the pipeline had already reviewed five times (captain order,
# 2026-09-07). This publishes the evidence that lets such a job stand down.
#
# THE EVIDENCE IS THE PIPELINE'S OWN RECORD, not this script's word for it.
# `attest` refuses unless ~/.no-mistakes/state.sqlite holds a run for the task's
# branch whose recorded head commit IS the PR's current head and whose `review`
# step reached `completed`. The database is opened READ-ONLY through a
# `file:...?mode=ro` URI; the shared daemon's state is never written by this
# script. bin/fm-nm-db-lib.sh owns that read-only contract, including why the
# live file is read rather than a copy, and this script borrows its guard and
# its SQL quoting rather than rolling a second pair; bin/fm-timeline.sh's header
# and tests/fixtures/timeline/README.md own the schema facts, including that the
# timestamps are epoch SECONDS. The question asked here - was THIS commit
# reviewed - is its own query, because the library's own entry points answer the
# viewer's question, which is what a branch's newest run is doing now. A `skipped` review counts only when the captain's decision to skip it
# is on record (see THE SKIPPED-REVIEW CASE below); anything else refuses and
# names what is missing.
#
# Signed payload, exactly these bytes and no trailing newline:
#
#     review-attest\n<owner/repo>\n<task-id>\n<head-sha>
#
# reproducible with any HMAC tool, which is what lets an operator audit a
# published line without this script:
#
#     printf 'review-attest\n<owner/repo>\n<task-id>\n<sha>' \
#       | openssl dgst -sha256 -mac HMAC -macopt key:<repo key> -r
#
# THE `review-attest` DOMAIN keeps this signature distinct from every other one
# the same key could produce, above all the CI testing waiver's: a waiver skips
# a PR's entire test suite, this skips a duplicate code review, and a signature
# minted for either must never verify as the other whichever body it is pasted
# into. bin/fm-ci-waiver-lib.sh owns the HMAC itself and the other domains.
#
# THE REPOSITORY IS IN THE PAYLOAD, which the CI waiver's is not. It can be,
# because this domain is new and has no signatures already in flight, and it
# should be: the key is derived per repository already, so the field is
# belt-and-braces against a future scheme that derives differently.
#
# Published line grammar, one line in its own paragraph of the PR body:
#
#     fm-review-attest: v1 <task-id> <head-sha> <hmac-sha256-hex>
#
# Publishing it is harmless by design: it is bound to one commit and reveals
# nothing about the secret.
#
# THE KEY is the repository's already-provisioned CI-waiver key,
# HMAC(master, "fm-ci-waiver-repo.v1", <owner/repo>), the same value
# `bin/fm-ci-waiver.sh publish <owner/repo>` sets as the Actions secret
# FM_CI_WAIVER_SECRET. Sharing the key is deliberate: a repository that has been
# enrolled for waivers needs no second `publish` and no second Actions secret to
# honour these, and the domain string above is what keeps the two grants apart.
# A repository that holds no secret cannot verify a line, so the review simply
# runs - the same inert-until-enrolled behaviour the waiver has.
#
# WHAT IT DOES NOT COVER, stated because a narrower guarantee that reads as a
# broader one is the failure this family of gates exists to prevent: the line
# names ONE commit, so ANY later push invalidates it - including a merge of the
# base branch, which is a commit the pipeline never reviewed. That is the
# intended behaviour rather than a limitation to work around: the review runs on
# every commit the pipeline did not review. A task that pushes after being
# attested needs a fresh attestation, and until it has one its PR is reviewed in
# full.
#
# It also does not say the pipeline APPROVED anything. It says one named step
# completed on one named commit. Whether a completed review is sufficient
# grounds to skip a second one is the consuming project's decision, taken in its
# own workflow.
#
# WHO ASKS FOR IT. Firstmate runs `attest` when a no-mistakes ship worker
# reports its PR green, or when the worker appends
# `review-attest needed for <sha> on <owner>/<repo>` to its status file, which
# bin/fm-brief.sh's no-mistakes ship brief instructs it to do as soon as the
# pipeline's `pr` step has opened the PR - early enough that the line is usually
# in the body before the review job starts.
#
# THE SKIPPED-REVIEW CASE. A pipeline run can record `review` as `skipped`. That
# is not evidence of a review, so it is attestable only when
# data/<task-id>/decisions.md carries a decision recorded under the key
# `review-skip` (bin/fm-nm-decision.sh owns that record). The decision's own
# `requires` text is printed at signing time, so firstmate reads what it is
# endorsing rather than being told a check passed. That record is one a worker
# could also write, so it is a guard against attesting an unreviewed commit by
# accident, not a cryptographic barrier; the barrier is the master key, which no
# worker is ever given. bin/fm-ci-waiver-lib.sh states the residual same-user
# limit that applies here unchanged.
#
# EDITING THE PR BODY DOES NOT RE-TRIGGER A WORKFLOW. A review job that has
# already started reads the body it reads; publishing before the job starts is
# what the brief's ordering is for, and a job that missed the line simply
# reviews the PR, which is the safe direction.
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
  -h|--help|'') usage; exit 0 ;;
esac

# shellcheck source=bin/fm-ci-waiver-lib.sh
. "$SCRIPT_DIR/fm-ci-waiver-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-db-lib.sh
. "$SCRIPT_DIR/fm-nm-db-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECRET_FILE="$CONFIG/ci-waiver-secret"
GH_CMD=${FM_REVIEW_ATTEST_GH:-gh}
# The shared daemon's database. Overridable so the tests can drive a fixture;
# production never sets it.
NM_DB=${FM_REVIEW_ATTEST_DB:-$HOME/.no-mistakes/state.sqlite}

# Domain-separation tag that opens the signed payload. Bumping it invalidates
# every previously issued attestation, which is the intended effect of a scheme
# change.
FM_REVIEW_ATTEST_SCHEME='review-attest'
FM_REVIEW_ATTEST_LINE_VERSION='v1'
FM_REVIEW_ATTEST_LINE_PREFIX='fm-review-attest:'
# The decision key that makes a `skipped` review attestable.
FM_REVIEW_ATTEST_SKIP_KEY='review-skip'

# fm_review_attest_line <task-id> <sha> <hex>: the publishable PR-body line.
fm_review_attest_line() {
  printf '%s %s %s %s %s\n' \
    "$FM_REVIEW_ATTEST_LINE_PREFIX" "$FM_REVIEW_ATTEST_LINE_VERSION" "$1" "$2" "$3"
}

# fm_review_attest_sign <owner/repo> <task-id> <sha>; the REPOSITORY key on
# stdin. The four payload fields, in the order the header states.
fm_review_attest_sign() {
  fm_ci_waiver_hmac_hex_n "$FM_REVIEW_ATTEST_SCHEME" "$1" "$2" "$3"
}

# fm_review_attest_check <owner/repo> <task-id> <sha> <candidate-hex>; the
# REPOSITORY key on stdin. A non-zero exit is NEVER an attestation.
fm_review_attest_check() {
  fm_ci_waiver_hmac_check_n "$4" "$FM_REVIEW_ATTEST_SCHEME" "$1" "$2" "$3"
}

require_node() {
  command -v node >/dev/null 2>&1 && return 0
  echo "error: node is required to compute the attestation signature (docs/configuration.md \"Toolchain\")" >&2
  return 1
}

# The same shape rule bin/fm-ci-waiver.sh applies to the same file, and for the
# same reason: the secret must live in the home's own config dir rather than
# wherever a symlink points. Each case names its own remedy.
read_secret_or_die() {
  if [ ! -e "$SECRET_FILE" ]; then
    echo "error: no signing secret at $SECRET_FILE; run 'fm-ci-waiver.sh init' first (every signer in this home shares its one master key)" >&2
    exit 1
  fi
  if [ -L "$SECRET_FILE" ] || [ ! -f "$SECRET_FILE" ]; then
    echo "error: $SECRET_FILE must be a regular file, not a symlink or directory" >&2
    exit 1
  fi
  if [ ! -s "$SECRET_FILE" ]; then
    echo "error: $SECRET_FILE is empty; re-run 'fm-ci-waiver.sh init --rotate'" >&2
    exit 1
  fi
}

# repo_key_for <owner/repo> [<accept-env>]: the key this repository's CI
# verifies against, derived from this home's master.
#
# FM_CI_WAIVER_SECRET, when set, IS that already-derived key, which is what lets
# `verify` run on a runner where the master does not exist and must not. Only
# `verify` passes `env`, deliberately: signing must always derive from the
# master for the repository it was asked about, or an operator with that
# variable exported for one repository would sign another repository's line
# with the wrong key and never see the mismatch until the line failed to verify
# somewhere else.
repo_key_for() {
  if [ "${2-}" = env ] && [ -n "${FM_CI_WAIVER_SECRET-}" ]; then
    printf '%s\n' "$FM_CI_WAIVER_SECRET"
    return 0
  fi
  read_secret_or_die
  fm_ci_waiver_repo_key "$1" < "$SECRET_FILE"
}

# nm_query <sql>: one read-only query against the shared daemon's database,
# opened exactly as bin/fm-nm-db-lib.sh opens it. The live file is read rather
# than a copy for the WAL reason that library's header states.
nm_query() {
  sqlite3 -batch -noheader "file:$NM_DB?mode=ro" "$1"
}

# skip_decision_requires <task-id>: the `requires` text of the captain's
# recorded review-skip decision, or nothing (exit 1) when there is none. The
# record's grammar is bin/fm-nm-decision.sh's; this reads the one block whose
# key line is exactly the skip key.
skip_decision_requires() {
  local record="$DATA/$1/decisions.md"
  [ -f "$record" ] || return 1
  awk -v keyline="- key: $FM_REVIEW_ATTEST_SKIP_KEY" '
    /^## / { inblock = 1; found = 0; requires = ""; next }
    !inblock { next }
    $0 == keyline { found = 1; next }
    /^- requires: / { requires = substr($0, 13); next }
    /^- state: / { if (found) { print requires; exit 0 } }
    END { if (found && requires != "") print requires }
  ' "$record" | grep . || return 1
}

# prove_reviewed <task-id> <head-sha>: exit 0 only when the pipeline's own
# record shows a run for this task's branch, at exactly this commit, whose
# review step completed. Every refusal names what is missing, because a
# refusal an operator cannot act on is a refusal they will route around.
prove_reviewed() {
  local id=$1 sha=$2 branch="fm/$1" status heads requires
  if ! fm_nm_db_ready "$NM_DB"; then
    echo "error: the pipeline's own record cannot be read ($FM_NM_DB_REASON), so there is nothing to show that anything reviewed $sha" >&2
    return 1
  fi
  # A completed review at this commit is preferred over a newer run that has
  # not reached one, because the question is whether the commit was EVER
  # reviewed, not what the branch is doing now: a re-run started for a later
  # step would otherwise mask the review that already happened. Among runs that
  # did not complete a review, the most recent is the one reported, so the
  # refusal names the state an operator would see.
  status=$(nm_query "
    SELECT s.status FROM runs r
      JOIN step_results s ON s.run_id = r.id AND s.step_name = 'review'
     WHERE r.branch = '$(fm_nm_db_lit "$branch")' AND r.head_sha = '$(fm_nm_db_lit "$sha")'
     ORDER BY (s.status = 'completed') DESC, r.created_at DESC LIMIT 1;") || {
    echo "error: could not read $NM_DB; refusing to attest a review that cannot be confirmed" >&2
    return 1
  }
  if [ -z "$status" ]; then
    heads=$(nm_query "
      SELECT DISTINCT substr(r.head_sha, 1, 12) FROM runs r
       WHERE r.branch = '$(fm_nm_db_lit "$branch")'
       ORDER BY r.created_at DESC LIMIT 5;" || true)
    if [ -z "$heads" ]; then
      echo "error: the pipeline has no run at all for branch $branch, so nothing has reviewed $sha" >&2
    else
      echo "error: the pipeline has runs for branch $branch but none at $sha, so nothing has reviewed the PR's current head" >&2
      echo "error: the commits it did run on are $(printf '%s' "$heads" | tr '\n' ' ')- a push after the last run is the usual cause, and the fix is another pipeline run, not an attestation" >&2
    fi
    return 1
  fi
  if [ "$status" = completed ]; then
    return 0
  fi
  if [ "$status" = skipped ]; then
    requires=$(skip_decision_requires "$id") || {
      echo "error: the pipeline SKIPPED the review step on $sha, and $DATA/$id/decisions.md records no '$FM_REVIEW_ATTEST_SKIP_KEY' decision, so nothing reviewed this commit and nothing approved leaving it unreviewed" >&2
      return 1
    }
    echo "note: the review step was skipped on $sha; attesting on the recorded $FM_REVIEW_ATTEST_SKIP_KEY decision: $requires" >&2
    return 0
  fi
  echo "error: the pipeline's review step for $sha is '$status', not 'completed', so the review did not finish on this commit" >&2
  return 1
}

# sign_attestation <task-id> <sha> <owner/repo>: validate, prove, and print the
# one publishable line. THE evidence check lives here, so no convenience path
# can accumulate a weaker version of it.
sign_attestation() {
  local ID=$1 SHA=$2 REPO=$3
  local META SIG REPO_KEY TASK_REPO REPO_LOWER
  fm_ci_waiver_valid_task_id "$ID" || { echo "error: invalid task id" >&2; exit 2; }
  fm_ci_waiver_valid_repo "$REPO" || { echo "error: '$REPO' is not a valid <owner/repo>" >&2; exit 2; }
  fm_ci_waiver_valid_sha "$SHA" || {
    echo "error: '<sha>' must be a full 40-character lowercase commit id; an abbreviation cannot be signed because the verifier compares against GitHub's full head SHA" >&2
    exit 2
  }
  META="$STATE/$ID.meta"
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    echo "error: no durable record for task $ID at $META; refusing to sign" >&2
    exit 1
  fi
  # The same refusal bin/fm-ci-waiver.sh's sign_waiver makes, through the same
  # shared resolver: a consuming workflow accepts a line on its signature alone
  # and never checks that the task named in it has anything to do with the pull
  # request carrying it, so a signature issued for a repository this task has
  # nothing to do with would stand down the review on someone else's PR. A
  # repository that cannot be resolved at all is allowed, because that is the
  # state of a project with no GitHub origin, and nothing about it is a
  # mismatch.
  TASK_REPO=$(fm_ci_waiver_task_repo_slug "$META") || TASK_REPO=
  REPO_LOWER=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  if [ -n "$TASK_REPO" ] && [ "$TASK_REPO" != "$REPO_LOWER" ]; then
    echo "error: task $ID's own checkout pushes to $TASK_REPO, not $REPO; refusing to attest a review for a repository this task does not belong to" >&2
    exit 1
  fi
  require_node || exit 1
  prove_reviewed "$ID" "$SHA" || exit 1
  REPO_KEY=$(repo_key_for "$REPO") || {
    echo "error: could not derive the repository key for $REPO" >&2
    exit 1
  }
  SIG=$(printf '%s' "$REPO_KEY" | fm_review_attest_sign "$REPO" "$ID" "$SHA") || {
    echo "error: could not compute the attestation signature" >&2
    exit 1
  }
  fm_ci_waiver_valid_sig "$SIG" || { echo "error: signature computation produced an unusable value" >&2; exit 1; }
  echo "attesting that the pipeline reviewed $SHA for $ID on $REPO" >&2
  fm_review_attest_line "$ID" "$SHA" "$SIG"
}

cmd=$1
shift

case "$cmd" in
  verify)
    # <owner/repo> <task-id> <sha> <line>. Prints the verdict and exits 0 only
    # on a line that matches all three, so a caller can branch on the status
    # alone; every other outcome is a refusal that names itself.
    V_REPO=${1:-}; V_ID=${2:-}; V_SHA=${3:-}; V_LINE=${4-}
    [ -n "$V_REPO" ] && [ -n "$V_ID" ] && [ -n "$V_SHA" ] || {
      echo "error: usage: fm-review-attest.sh verify <owner/repo> <task-id> <sha> <line>" >&2
      exit 2
    }
    fm_ci_waiver_valid_repo "$V_REPO" || { echo "error: '$V_REPO' is not a valid <owner/repo>" >&2; exit 2; }
    fm_ci_waiver_valid_task_id "$V_ID" || { echo "error: invalid task id" >&2; exit 2; }
    fm_ci_waiver_valid_sha "$V_SHA" || { echo "error: '<sha>' must be a full 40-character lowercase commit id" >&2; exit 2; }
    require_node || exit 1
    # Parsed field by field rather than pattern-matched, so a line that carries
    # the right words in the wrong shape is refused rather than half-read. The
    # CR strip is for GitHub, whose PR bodies are CRLF.
    V_LINE=$(printf '%s' "$V_LINE" | tr -d '\r')
    # shellcheck disable=SC2086 # deliberate: split the line into its five fields
    set -- $V_LINE
    if [ "$#" -ne 5 ] \
      || [ "$1" != "$FM_REVIEW_ATTEST_LINE_PREFIX" ] \
      || [ "$2" != "$FM_REVIEW_ATTEST_LINE_VERSION" ]; then
      echo "unverified: not a $FM_REVIEW_ATTEST_LINE_PREFIX $FM_REVIEW_ATTEST_LINE_VERSION line" >&2
      exit 1
    fi
    if [ "$3" != "$V_ID" ]; then
      echo "unverified: the line names task '$3', not '$V_ID'" >&2
      exit 1
    fi
    if [ "$4" != "$V_SHA" ]; then
      echo "unverified: the line covers commit '$4', not '$V_SHA'; a push after the attestation is the usual cause" >&2
      exit 1
    fi
    fm_ci_waiver_valid_sig "$5" || { echo "unverified: the line's signature is not a 64-character hex digest" >&2; exit 1; }
    V_KEY=$(repo_key_for "$V_REPO" env) || {
      echo "error: could not derive the repository key for $V_REPO" >&2
      exit 1
    }
    if printf '%s' "$V_KEY" | fm_review_attest_check "$V_REPO" "$V_ID" "$V_SHA" "$5"; then
      echo "verified: the pipeline reviewed $V_SHA for $V_ID on $V_REPO"
      exit 0
    fi
    echo "unverified: the signature does not match $V_REPO's key over this task and commit" >&2
    exit 1
    ;;

  attest)
    ID=${1:-}
    shift 2>/dev/null || true
    PRINT_ONLY=0
    for a in "$@"; do
      case "$a" in
        --print-only) PRINT_ONLY=1 ;;
        *) echo "error: unknown attest argument '$a'" >&2; exit 2 ;;
      esac
    done
    fm_ci_waiver_valid_task_id "$ID" || { echo "error: invalid task id" >&2; exit 2; }
    META="$STATE/$ID.meta"
    if [ ! -f "$META" ] || [ -L "$META" ]; then
      echo "error: no durable record for task $ID at $META" >&2
      exit 1
    fi
    PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
    if [ -z "$PR_URL" ]; then
      echo "error: task $ID has no recorded PR, so there is no body to publish an attestation into; run bin/fm-pr-check.sh <id> <pr url> first" >&2
      exit 1
    fi
    fm_pr_url_parse "$PR_URL" || {
      echo "error: task $ID's recorded pr= value '$PR_URL' is not a GitHub pull request link" >&2
      exit 1
    }
    PR_REPO_SLUG="$FM_PR_OWNER/$FM_PR_REPO"
    PR_NUMBER=$FM_PR_NUMBER
    command -v "$GH_CMD" >/dev/null 2>&1 || {
      echo "error: $GH_CMD is required to read the PR's current head commit" >&2
      exit 1
    }
    # Read from the PR itself rather than from a local ref or the task's own
    # record: the line covers ONE commit, and a local branch or a recorded
    # pr_head= is only as fresh as the last time it was written. A signature for
    # a commit that is no longer the head verifies nowhere and would look like a
    # broken attestation rather than a stale one.
    HEAD_SHA=$("$GH_CMD" api "repos/$PR_REPO_SLUG/pulls/$PR_NUMBER" --jq .head.sha) || {
      echo "error: could not read the current head commit of $PR_URL from GitHub; refusing to sign for a commit that cannot be confirmed" >&2
      exit 1
    }
    HEAD_SHA=$(printf '%s' "$HEAD_SHA" | tr -d '[:space:]')
    fm_ci_waiver_valid_sha "$HEAD_SHA" || {
      echo "error: GitHub reported '$HEAD_SHA' as the head of $PR_URL, which is not a full 40-character commit id" >&2
      exit 1
    }
    LINE=$(sign_attestation "$ID" "$HEAD_SHA" "$PR_REPO_SLUG") || exit 1
    # Printed before any delivery attempt, so a failed publish still leaves the
    # valid line in hand rather than losing it with the failure.
    printf '%s\n' "$LINE"
    if [ "$PRINT_ONLY" -eq 1 ]; then
      echo "attestation for $ID covers $HEAD_SHA on $PR_REPO_SLUG (not published)"
      exit 0
    fi
    BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-review-attest-body.XXXXXX") || {
      echo "error: could not create a scratch file for the PR body" >&2
      exit 1
    }
    trap 'rm -f "$BODY_FILE" "$BODY_FILE.json"' EXIT
    "$GH_CMD" api "repos/$PR_REPO_SLUG/pulls/$PR_NUMBER" --jq '.body // ""' > "$BODY_FILE" || {
      echo "error: could not read the current body of $PR_URL; the line above is valid, publish it by hand" >&2
      exit 1
    }
    if tr -d '\r' < "$BODY_FILE" | grep -qxF "$LINE"; then
      echo "the PR body already carries this exact attestation; nothing to publish"
      exit 0
    fi
    # APPENDED in its own paragraph, never rewritten: an attestation for a
    # superseded head simply stops verifying, exactly as a stale CI waiver line
    # does, so there is no reason to edit anything a human wrote.
    printf '\n%s\n' "$LINE" >> "$BODY_FILE"
    # REST PATCH rather than `gh pr edit`, which fails outright on a repository
    # that has classic projects enabled (verified 2026-09-07). The body goes
    # through a file and stdin, never argv, so a long body cannot die at an
    # argument-length limit.
    jq -Rs '{body: .}' < "$BODY_FILE" > "$BODY_FILE.json" || {
      echo "error: could not encode the PR body; the line above is valid, publish it by hand" >&2
      exit 1
    }
    if ! "$GH_CMD" api --method PATCH "repos/$PR_REPO_SLUG/pulls/$PR_NUMBER" --input "$BODY_FILE.json" >/dev/null; then
      echo "error: the attestation line above is valid but could not be published into $PR_URL; add it to the body by hand" >&2
      exit 1
    fi
    echo "published the attestation into $PR_URL"
    ;;

  *)
    echo "error: unknown subcommand '$cmd'" >&2
    exit 2
    ;;
esac
