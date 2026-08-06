#!/usr/bin/env bash
# Verify a published CI testing waiver. CI-SIDE ONLY: this is the job that
# decides whether the expensive lint and test jobs run.
#
# Inputs, all from the environment so that no untrusted text is ever
# interpolated into a shell command by the workflow:
#   FM_CI_WAIVER_SECRET    the Actions repository secret; absent means no verdict
#   FM_CI_WAIVER_CLAIM     text to scan for waiver lines (the PR body)
#   FM_CI_WAIVER_HEAD_SHA  the PR's full head commit SHA
#
# Output:
#   stdout          "waived=true" or "waived=false"
#   $GITHUB_OUTPUT  the same key=value, when the file is provided
#   exit status     0 whenever the check completed, whatever the verdict
#
# The verdict is waived=true ONLY when a line in the claim text carries a
# signature that this repository's secret reproduces over the CURRENT head SHA.
# Every other outcome - no line, no secret, no head SHA, a malformed line, a
# line bound to a different commit, a wrong signature, no node - is
# waived=false, which reproduces today's behaviour exactly: everything runs. A
# verification failure is therefore never treated as a skip, and every failure
# that is not simply "no waiver was offered" is annotated loudly rather than
# passed over in silence.
#
# The job exits 0 even when it refuses a waiver, deliberately. Failing the job
# instead would SKIP the expensive jobs that depend on it, which is the exact
# fail-open this check exists to prevent; the dependent jobs' own conditions
# handle a non-success waiver job (see .github/workflows/ci.yml).
#
# The signed payload and the published line's grammar are owned by
# bin/fm-ci-waiver-lib.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ci-waiver-lib.sh
. "$SCRIPT_DIR/fm-ci-waiver-lib.sh"

CLAIM=${FM_CI_WAIVER_CLAIM-}
HEAD_SHA=${FM_CI_WAIVER_HEAD_SHA-}
SECRET=${FM_CI_WAIVER_SECRET-}

verdict() {  # <true|false>
  printf 'waived=%s\n' "$1"
  if [ -n "${GITHUB_OUTPUT-}" ]; then
    printf 'waived=%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
  exit 0
}

annotate() {  # <level> <message>
  printf '::%s::%s\n' "$1" "$2"
}

# A claim with no waiver line at all is the normal case for almost every PR, so
# it must stay completely quiet. Everything past this point IS a waiver attempt
# and is reported.
CANDIDATES=$(printf '%s\n' "$CLAIM" | tr -d '\r' | grep -E "^[[:space:]]*${FM_CI_WAIVER_LINE_PREFIX}" || true)
if [ -z "$CANDIDATES" ]; then
  verdict false
fi

if [ -z "$HEAD_SHA" ]; then
  annotate warning "A CI waiver line is present but this event carries no pull-request head SHA, so the waiver cannot be bound to a commit. Running the full suite."
  verdict false
fi
if ! fm_ci_waiver_valid_sha "$HEAD_SHA"; then
  annotate warning "A CI waiver line is present but the event's head SHA is not a full 40-character commit id. Running the full suite."
  verdict false
fi
if [ -z "$SECRET" ]; then
  annotate warning "A CI waiver line is present but this repository has no FM_CI_WAIVER_SECRET, so no waiver can be verified. Running the full suite. (Set it with bin/fm-ci-waiver.sh publish <owner/repo>.)"
  verdict false
fi
if ! command -v node >/dev/null 2>&1; then
  annotate warning "A CI waiver line is present but node is unavailable, so no waiver can be verified. Running the full suite."
  verdict false
fi

# Every candidate is checked. More than one line is normal after a re-push: the
# worker adds a fresh line for the new head commit, and the stale line for the
# previous commit is simply one that no longer verifies. Any single line that
# verifies against the CURRENT head SHA is a valid waiver, and one that does not
# can never become one, so scanning them all is exactly as strict as scanning a
# single line would be.
LINE_RE="^[[:space:]]*${FM_CI_WAIVER_LINE_PREFIX}[[:space:]]+${FM_CI_WAIVER_LINE_VERSION}[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]+([0-9a-f]{40})[[:space:]]+([0-9a-f]{64})[[:space:]]*$"
saw_malformed=0
saw_other_commit=
saw_bad_signature=
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [[ ! "$line" =~ $LINE_RE ]]; then
    saw_malformed=1
    continue
  fi
  claim_id=${BASH_REMATCH[1]}
  claim_sha=${BASH_REMATCH[2]}
  claim_sig=${BASH_REMATCH[3]}
  if [ "$claim_sha" != "$HEAD_SHA" ]; then
    saw_other_commit=$claim_sha
    continue
  fi
  if printf '%s' "$SECRET" | fm_ci_waiver_check "$claim_id" "$claim_sha" "$claim_sig"; then
    annotate notice "CI testing waived for task $claim_id at commit $claim_sha by a verified firstmate waiver. The lint and behaviour-test jobs will not run; this PR carries NO test evidence."
    verdict true
  fi
  saw_bad_signature=$claim_id
done <<EOF_CANDIDATES
$CANDIDATES
EOF_CANDIDATES

if [ -n "$saw_bad_signature" ]; then
  annotate warning "A CI waiver line for task $saw_bad_signature names this head commit but its signature does not verify against this repository's secret. Refusing the waiver and running the full suite."
elif [ -n "$saw_other_commit" ]; then
  annotate warning "A CI waiver line was found but it is bound to commit $saw_other_commit, not this PR's head commit $HEAD_SHA. A waiver covers exactly one commit, so a fresh one is needed after every push. Running the full suite."
elif [ "$saw_malformed" -eq 1 ]; then
  annotate warning "A line beginning '${FM_CI_WAIVER_LINE_PREFIX}' was found but does not match the waiver grammar '${FM_CI_WAIVER_LINE_PREFIX} ${FM_CI_WAIVER_LINE_VERSION} <task-id> <40-hex-sha> <64-hex-signature>'. Running the full suite."
fi
verdict false
