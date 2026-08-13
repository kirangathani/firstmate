#!/usr/bin/env bash
# Issue and provision captain-signed SUPERSESSION ATTESTATIONS. FIRSTMATE-SIDE
# ONLY: this script reads the master key and the captain's private approval
# record, so it runs on the captain's machine, never in a worker's worktree and
# never in CI.
#
# Usage:
#   fm-supersession-attest.sh publish <owner/repo>      push that repo's derived
#                                                       key to its Actions secrets
#   fm-supersession-attest.sh sign <task-id> <sha> <owner/repo>
#                                                       print the publishable line
#   fm-supersession-attest.sh attest <task-id> [--print-only]
#                                                       sign for the PR's CURRENT
#                                                       head and publish the line
#                                                       into its body
#
# WHAT THIS IS FOR. bin/fm-pr-merge.sh honours a captain-approved entry in
# $FM_HOME/data/supersessions/<project>.md and lets the merge proceed. The
# required check `Base assertions re-verified` re-runs the same base assertions
# on a GitHub runner, cannot see that record, reports the same findings and goes
# red - permanently, because the branch is not what is wrong. This script is how
# the approval reaches CI: bin/fm-supersession-attest-lib.sh owns the wire it
# travels on, and bin/fm-supersession-verify.sh is what reads it there.
#
# THE SECRET is the same MASTER key the CI waiver uses, at
# $FM_HOME/config/ci-waiver-secret (local, gitignored, mode 0600, created by
# `fm-ci-waiver.sh init`). The master is never published anywhere. What each
# repository receives is a key DERIVED for that repository AND for this purpose
# alone, published as the Actions secret FM_SUPERSESSION_SECRET;
# bin/fm-supersession-attest-lib.sh owns the derivation and the reasoning,
# including why it is deliberately not the repository's CI-waiver key.
#
# Run `publish` once per project whose CI must honour supersessions. It is
# independent of `fm-ci-waiver.sh publish`: a repository can hold either secret,
# both, or neither, and each grants only its own thing.
#
# THE AUTHORITY CHECK, and why it is the record rather than a dispatch flag.
# What a worker may not be able to do is excuse its OWN findings, so the test to
# apply is whether the entity being checked could have produced the thing being
# checked. Two things are required to mint an attestation and a worker is
# invited to neither:
#   - the master key, which lives only in the captain's config/ and is never
#     handed to a worker in any form;
#   - a fully-formed entry in the captain's private approval record, which no
#     brief, scaffold, or status protocol ever points a worker at. That is the
#     same standing bin/fm-pr-merge.sh's attestation exemption gives
#     $FM_HOME/data/projects.md, and for the same stated reason: it is not a
#     file a worker is invited to touch, unlike the state/ directory it appends
#     its own status lines into.
# bin/fm-ci-waiver-lib.sh states the residual same-user limit no design in this
# space can remove; it applies here unchanged.
#
# NO DISPATCH FLAG GATES THIS, deliberately, and the difference from
# fm-ci-waiver.sh's `sign` is worth naming: a CI waiver is a decision made at
# DISPATCH about a task that has not run yet, so a token minted at dispatch is
# exactly the right authority for it. A supersession is the opposite: it can
# only be decided AFTER the gate has reported which assertion the branch
# supersedes, so there is nothing to have flagged in advance. The record IS the
# decision, and it is written by the captain's approval and nothing else.
#
# WHAT IS SIGNED, and what is never published: the matching half of every
# well-formed entry in that project's record - the identifier or glob, and the
# finding class it excuses - bound to this task and to ONE commit. The captain's
# stated reason and the approval date stay in the private record, which is where
# the fleet's deliberation belongs; a PR body is public.
#
# WHY IT IS SIGNED FOR THE PR'S CURRENT HEAD, and why `attest` reads that head
# from GitHub rather than from the task's own record: the signature is bound to
# one commit (bin/fm-supersession-attest-lib.sh owns why), and a recorded
# pr_head= is only as fresh as the last time it was written. A signature for a
# commit that is no longer the head verifies nowhere and would look like a
# broken attestation rather than a stale one.
#
# EDITING THE PR BODY DOES NOT RE-TRIGGER THE CHECK, and does not need to: the
# re-verification workflow exists to be re-run in place, and its verifier reads
# the body live at job time for exactly this reason. `attest` prints the one
# command that re-runs it.
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

# shellcheck source=bin/fm-supersession-attest-lib.sh
. "$SCRIPT_DIR/fm-supersession-attest-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECRET_FILE="$CONFIG/ci-waiver-secret"
GH_CMD=${FM_SUPERSESSION_GH:-gh}

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
    echo "error: no signing secret at $SECRET_FILE; run 'fm-ci-waiver.sh init' first (both signers share this home's one master key)" >&2
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

# project_for_task <meta>: the project name whose approval record governs this
# task - the basename of the meta's project= path, exactly as bin/fm-pr-merge.sh
# resolves it, so the signer and the merge gate can never read two different
# records for one task.
project_for_task() {
  local meta=$1 proj_path
  proj_path=$(grep -m1 '^project=' "$meta" | cut -d= -f2- || true)
  [ -n "$proj_path" ] || return 1
  basename "$proj_path"
}

# sign_attestation <task-id> <sha> <owner/repo>: validate, read the captain's
# approvals, and print the one publishable line. THE authority check lives here,
# and both `sign` and `attest` go through this single function, so no
# convenience path can accumulate a weaker version of it.
sign_attestation() {
  local ID=$1 SHA=$2 REPO=$3
  local META RECORD PROJ TOKEN SIG REPO_KEY TASK_REPO REPO_LOWER ENTRIES COUNT
  fm_ci_waiver_valid_task_id "$ID" || { echo "error: invalid task id" >&2; exit 2; }
  [ -n "$REPO" ] || {
    echo "error: sign requires the <owner/repo> the PR is open against" >&2
    echo "error: each repository verifies against its own derived key, so a signature must name the repository it is for" >&2
    exit 2
  }
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
  # shared resolver: the verifier accepts a line on its signature alone and
  # never checks that the task named in it has anything to do with the pull
  # request carrying it, so a signature issued for a repository this task has
  # nothing to do with would excuse findings on someone else's PR. A repository
  # that cannot be resolved at all is allowed, because that is the state of a
  # project with no GitHub origin, and nothing about it is a mismatch.
  TASK_REPO=$(fm_ci_waiver_task_repo_slug "$META") || TASK_REPO=
  REPO_LOWER=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  if [ -n "$TASK_REPO" ] && [ "$TASK_REPO" != "$REPO_LOWER" ]; then
    echo "error: task $ID's own checkout pushes to $TASK_REPO, not $REPO; refusing to sign an attestation for a repository this task does not belong to" >&2
    exit 1
  fi
  PROJ=$(project_for_task "$META") || {
    echo "error: task $ID's record names no project, so there is no approval record to read" >&2
    exit 1
  }
  RECORD="$DATA/supersessions/$PROJ.md"
  if [ ! -f "$RECORD" ] || [ -L "$RECORD" ]; then
    echo "error: $PROJ has no captain-approved supersession record at $RECORD, so there is nothing to attest" >&2
    echo "error: an attestation carries approvals that already exist; it never creates one. If the branch deliberately supersedes the base's behaviour, that is the captain's decision to record first (entry format in bin/fm-pr-merge.sh's header)" >&2
    exit 1
  fi
  # The ONE reader of the record's grammar, shared with the merge gate that
  # enforces it, so what CI is told was approved and what the merge gate excuses
  # cannot be two different sets.
  ENTRIES=$(fm_supersession_entries_extract "$RECORD" "$PROJ")
  COUNT=$(printf '%s' "$ENTRIES" | grep -c . || true)
  if [ "${COUNT:-0}" -eq 0 ]; then
    echo "error: $RECORD holds no fully-formed entry for $PROJ, so there is nothing to attest" >&2
    echo "error: any malformed entry is named above; a refused entry excuses nothing at merge time either" >&2
    exit 1
  fi
  require_node || exit 1
  read_secret_or_die
  TOKEN=$(printf '%s\n' "$ENTRIES" | fm_supersession_token_encode) || {
    echo "error: could not encode the approved entries" >&2
    exit 1
  }
  fm_supersession_valid_token "$TOKEN" || {
    echo "error: encoding the approved entries produced an unusable token" >&2
    exit 1
  }
  # Signed with the key derived for THIS repository and THIS purpose, which is
  # the only key its re-verification job holds.
  REPO_KEY=$(fm_supersession_attest_repo_key "$REPO" < "$SECRET_FILE") || {
    echo "error: could not derive the repository key for $REPO" >&2
    exit 1
  }
  SIG=$(printf '%s' "$REPO_KEY" | fm_supersession_attest_sign "$ID" "$SHA" "$TOKEN") || {
    echo "error: could not compute the attestation signature" >&2
    exit 1
  }
  fm_ci_waiver_valid_sig "$SIG" || { echo "error: signature computation produced an unusable value" >&2; exit 1; }
  echo "attesting $COUNT captain-approved entry(ies) from $RECORD for $ID at $SHA on $REPO" >&2
  fm_supersession_attest_line "$ID" "$SHA" "$TOKEN" "$SIG"
}

cmd=$1
shift

case "$cmd" in
  publish)
    repo=${1:-}
    [ -n "$repo" ] || { echo "error: publish requires an explicit <owner/repo>" >&2; exit 2; }
    fm_ci_waiver_valid_repo "$repo" || {
      echo "error: '$repo' is not a valid <owner/repo>" >&2; exit 2
    }
    require_node || exit 1
    read_secret_or_die
    command -v gh-axi >/dev/null 2>&1 || {
      echo "error: gh-axi is required to set the repository secret" >&2
      exit 1
    }
    repo_key=$(fm_supersession_attest_repo_key "$repo" < "$SECRET_FILE") || {
      echo "error: could not derive the repository key for $repo" >&2
      exit 1
    }
    fm_ci_waiver_valid_sig "$repo_key" || {
      echo "error: key derivation for $repo produced an unusable value" >&2
      exit 1
    }
    # printf is a shell builtin, so the value is not exposed in any argv, and
    # gh-axi secret set reads it only from stdin and never prints it back.
    if ! printf '%s' "$repo_key" | gh-axi secret set "$FM_SUPERSESSION_SECRET_NAME" -R "$repo"; then
      echo "error: could not set $FM_SUPERSESSION_SECRET_NAME on $repo" >&2
      exit 1
    fi
    echo "published $FM_SUPERSESSION_SECRET_NAME to $repo (derived for that repo and this purpose, value not printed)"
    ;;

  sign)
    sign_attestation "${1:-}" "${2:-}" "${3:-}"
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
    # Read rather than taken from the task's record: an attestation covers ONE
    # commit, and a recorded head is only as fresh as the last time it was
    # written. gh's raw JSON is used because gh-axi's pr view renders a summary
    # rather than returning the head object id, the same reason
    # bin/fm-pr-lib.sh reads baseRefName this way.
    HEAD_SHA=$("$GH_CMD" pr view "$PR_URL" --json headRefOid -q .headRefOid) || {
      echo "error: could not read the current head commit of $PR_URL from GitHub; refusing to sign for a commit that cannot be confirmed" >&2
      exit 1
    }
    fm_ci_waiver_valid_sha "$HEAD_SHA" || {
      echo "error: GitHub reported '$HEAD_SHA' as the head of $PR_URL, which is not a full 40-character commit id" >&2
      exit 1
    }
    LINE=$(sign_attestation "$ID" "$HEAD_SHA" "$PR_REPO_SLUG") || exit 1
    # Printed before any delivery attempt, so a failed edit still leaves the
    # valid line in hand rather than losing it with the failure.
    printf '%s\n' "$LINE"
    if [ "$PRINT_ONLY" -eq 1 ]; then
      echo "attestation for $ID covers $HEAD_SHA on $PR_REPO_SLUG (not published)"
      exit 0
    fi
    BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-supersession-body.XXXXXX") || {
      echo "error: could not create a scratch file for the PR body" >&2
      exit 1
    }
    trap 'rm -f "$BODY_FILE"' EXIT
    "$GH_CMD" pr view "$PR_URL" --json body -q .body > "$BODY_FILE" || {
      echo "error: could not read the current body of $PR_URL; the line above is valid, publish it by hand" >&2
      exit 1
    }
    if grep -qxF "$LINE" "$BODY_FILE"; then
      echo "the PR body already carries this exact attestation; nothing to publish"
    else
      # APPENDED, never rewritten: an earlier attestation for a superseded head
      # simply stops verifying, exactly as a stale CI waiver line does, so there
      # is no reason to edit anything a human wrote.
      printf '\n%s\n' "$LINE" >> "$BODY_FILE"
      if ! gh-axi pr edit "$PR_NUMBER" --repo "$PR_REPO_SLUG" --body-file "$BODY_FILE"; then
        echo "error: the attestation line above is valid but could not be published into $PR_URL; add it to the body by hand" >&2
        exit 1
      fi
      echo "published the attestation into $PR_URL"
    fi
    # Editing a body triggers no workflow, and the re-verification is designed
    # to be re-run in place; its verifier reads the body live for that reason.
    echo "next: re-run the base re-verification so it reads the new body:"
    echo "  gh run rerun \$(gh run list --repo $PR_REPO_SLUG --workflow 'Base re-verification' --branch <the PR's branch> --limit 1 --json databaseId -q '.[0].databaseId')"
    ;;

  *)
    echo "error: unknown subcommand '$cmd'" >&2
    exit 2
    ;;
esac
