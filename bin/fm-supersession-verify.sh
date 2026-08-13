#!/usr/bin/env bash
# Verify a published supersession attestation. CI-SIDE ONLY: this is the job
# that decides which base-assertion findings the re-verification check may
# excuse.
#
# Inputs, all from the environment so that no untrusted text is ever
# interpolated into a shell command by the workflow:
#   FM_SUPERSESSION_SECRET    the Actions repository secret; absent means no verdict
#   FM_SUPERSESSION_HEAD_SHA  the PR's full head commit SHA
#   FM_SUPERSESSION_REPO      owner/repo the PR lives in
#   FM_SUPERSESSION_PR        the PR number whose body carries the attestation
#   FM_SUPERSESSION_GH        overrides the `gh` command, for tests only
#
# Output:
#   stdout          "superseded=true" or "superseded=false", then, when true,
#                   one `entry: <sel> <kind> <value>` line per approved entry so
#                   the log says in plain words what may be excused and by what
#   $GITHUB_OUTPUT  superseded=<verdict>, and on true a multi-line `entries`
#                   holding the canonical entry lines
#                   (bin/fm-supersession-lib.sh owns that format)
#   exit status     0 whenever the check completed, whatever the verdict
#
# THE BODY IS READ LIVE, never from the workflow event's payload, and that is
# load-bearing rather than incidental. A supersession is approved AFTER the
# check has already reported red, so the line always arrives by an edit to an
# existing PR - and editing a body triggers no workflow. The remedy is to re-run
# the re-verification in place, which the workflow is built for, but a re-run
# replays the ORIGINAL event payload, whose body predates the edit. Reading the
# body from the API at job time is what makes the re-run see the attestation at
# all.
#
# The verdict is superseded=true ONLY when a line in the body carries a
# signature that this repository's secret reproduces over the CURRENT head SHA.
# Every other outcome - no line, no secret, no head SHA, an unreadable body, a
# malformed line, a line bound to a different commit, a wrong signature, an
# undecodable token, an entry this fleet's matcher cannot read, no node - is
# superseded=false, which reproduces the behaviour before this check existed
# exactly: every finding blocks. A verification failure is therefore never
# treated as an excuse, and every failure that is not simply "no attestation was
# offered" is annotated loudly rather than passed over in silence.
#
# The job exits 0 even when it refuses an attestation, deliberately. Failing the
# job instead would leave the required check that depends on it with a failed
# dependency, and the re-verification's whole point is to report a verdict on
# every PR; refusing an attestation is a verdict (excuse nothing), not an error.
#
# NOTHING HERE DECIDES WHAT IS EXCUSED. It decides only what the captain
# approved and signed. bin/fm-reverify-base.sh applies those entries to the
# findings, through the same matcher bin/fm-pr-merge.sh uses at merge time, so
# an identifier is excused in CI exactly when it is excused at the merge - and a
# finding no entry covers still blocks, unchanged.
#
# The signed payload, the token and the published line's grammar are owned by
# bin/fm-supersession-attest-lib.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supersession-attest-lib.sh
. "$SCRIPT_DIR/fm-supersession-attest-lib.sh"

HEAD_SHA=${FM_SUPERSESSION_HEAD_SHA-}
SECRET=${FM_SUPERSESSION_SECRET-}
REPO=${FM_SUPERSESSION_REPO-}
PR=${FM_SUPERSESSION_PR-}
GH_CMD=${FM_SUPERSESSION_GH:-gh}

# The heredoc delimiter for the multi-line GITHUB_OUTPUT value. Content that
# contains it is refused rather than written, because a value that closes its
# own heredoc early would hand the next job a truncated approval set.
OUT_DELIM='FM_SUPERSESSION_ENTRIES_EOF'

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-supersession-verify.XXXXXX")
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

annotate() {  # <level> <message>
  printf '::%s::%s\n' "$1" "$2"
}

# verdict false, or verdict true <entries-file>. The only exit path.
verdict() {  # <true|false> [<entries-file>]
  local value=$1 file=${2-} line sel kind value_field rest
  printf 'superseded=%s\n' "$value"
  if [ -n "${GITHUB_OUTPUT-}" ]; then
    printf 'superseded=%s\n' "$value" >> "$GITHUB_OUTPUT"
  fi
  if [ "$value" = true ] && [ -n "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      sel=${line%%"$FM_SUPERSESSION_FIELD_SEP"*}
      rest=${line#*"$FM_SUPERSESSION_FIELD_SEP"}
      kind=${rest%%"$FM_SUPERSESSION_FIELD_SEP"*}
      value_field=${rest#*"$FM_SUPERSESSION_FIELD_SEP"}
      printf 'entry: %s %s %s\n' "$sel" "$kind" "$value_field"
    done < "$file"
    if [ -n "${GITHUB_OUTPUT-}" ]; then
      {
        printf 'entries<<%s\n' "$OUT_DELIM"
        cat "$file"
        printf '%s\n' "$OUT_DELIM"
      } >> "$GITHUB_OUTPUT"
    fi
  fi
  exit 0
}

# Reading the body needs GitHub access; without it there is no claim to check,
# which is the ordinary "no attestation" verdict rather than an error, but it is
# annotated because a PR that DOES carry one would otherwise fail silently.
if [ -z "$REPO" ] || [ -z "$PR" ]; then
  annotate warning "No pull request was named, so no supersession attestation could be read. Every base-assertion finding blocks as before."
  verdict false
fi
if ! command -v "$GH_CMD" >/dev/null 2>&1; then
  annotate warning "The GitHub CLI is unavailable, so this PR's body could not be read for a supersession attestation. Every base-assertion finding blocks as before."
  verdict false
fi
CLAIM="$TMP_DIR/claim"
if ! "$GH_CMD" pr view "$PR" --repo "$REPO" --json body -q .body > "$CLAIM" 2>"$TMP_DIR/gh.err"; then
  annotate warning "This PR's body could not be read from GitHub, so a supersession attestation could not be looked for. Every base-assertion finding blocks as before."
  sed 's/^/gh: /' "$TMP_DIR/gh.err" >&2 || true
  verdict false
fi

# A body with no attestation line at all is the normal case for almost every PR,
# so it must stay completely quiet. Everything past this point IS an attestation
# attempt and is reported.
CANDIDATES=$(tr -d '\r' < "$CLAIM" | grep -E "^[[:space:]]*${FM_SUPERSESSION_LINE_PREFIX}" || true)
if [ -z "$CANDIDATES" ]; then
  verdict false
fi

if [ -z "$HEAD_SHA" ]; then
  annotate warning "A supersession attestation is present but this event carries no pull-request head SHA, so it cannot be bound to a commit. Every base-assertion finding blocks."
  verdict false
fi
if ! fm_ci_waiver_valid_sha "$HEAD_SHA"; then
  annotate warning "A supersession attestation is present but the event's head SHA is not a full 40-character commit id. Every base-assertion finding blocks."
  verdict false
fi
if [ -z "$SECRET" ]; then
  annotate warning "A supersession attestation is present but this repository has no ${FM_SUPERSESSION_SECRET_NAME}, so no attestation can be verified. Every base-assertion finding blocks. (Set it with bin/fm-supersession-attest.sh publish <owner/repo>.)"
  verdict false
fi
if ! command -v node >/dev/null 2>&1; then
  annotate warning "A supersession attestation is present but node is unavailable, so no attestation can be verified. Every base-assertion finding blocks."
  verdict false
fi

# Every candidate is checked. More than one line is normal after a re-push: the
# captain adds a fresh line for the new head commit, and the stale line for the
# previous commit is simply one that no longer verifies. Any single line that
# verifies against the CURRENT head SHA is a valid attestation, and one that does
# not can never become one, so scanning them all is exactly as strict as scanning
# a single line would be.
LINE_RE="^[[:space:]]*${FM_SUPERSESSION_LINE_PREFIX}[[:space:]]+${FM_SUPERSESSION_LINE_VERSION}[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]+([0-9a-f]{40})[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]+([0-9a-f]{64})[[:space:]]*$"
saw_malformed=0
saw_other_commit=
saw_bad_signature=
saw_unreadable=
ENTRIES="$TMP_DIR/entries"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [[ ! "$line" =~ $LINE_RE ]]; then
    saw_malformed=1
    continue
  fi
  claim_id=${BASH_REMATCH[1]}
  claim_sha=${BASH_REMATCH[2]}
  claim_token=${BASH_REMATCH[3]}
  claim_sig=${BASH_REMATCH[4]}
  if [ "$claim_sha" != "$HEAD_SHA" ]; then
    saw_other_commit=$claim_sha
    continue
  fi
  if ! printf '%s' "$SECRET" \
    | fm_supersession_attest_check "$claim_id" "$claim_sha" "$claim_token" "$claim_sig"; then
    saw_bad_signature=$claim_id
    continue
  fi
  # Signed by this repository's key, for this commit. What it carries is still
  # validated before it is acted on: a signature proves who wrote the token, not
  # that every entry in it is one this fleet's matcher can read, and an entry
  # that cannot be read must never widen into one that is guessed at.
  if ! fm_supersession_token_decode "$claim_token" > "$ENTRIES"; then
    saw_unreadable="$claim_id (its entry token is not decodable)"
    continue
  fi
  if ! [ -s "$ENTRIES" ]; then
    saw_unreadable="$claim_id (it carries no entries at all)"
    continue
  fi
  bad_entry=
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    fm_supersession_entry_line_valid "$entry" && continue
    bad_entry=$entry
    break
  done < "$ENTRIES"
  if [ -n "$bad_entry" ]; then
    saw_unreadable="$claim_id (it carries an entry this fleet's matcher cannot read)"
    continue
  fi
  if grep -qxF "$OUT_DELIM" "$ENTRIES"; then
    saw_unreadable="$claim_id (an entry collides with this job's output delimiter)"
    continue
  fi
  annotate notice "Supersession attestation verified for task $claim_id at commit $claim_sha: the captain has approved the base assertions it names, so the re-verification may excuse THOSE findings and no others. This PR's test evidence is unaffected; the approvals' stated reasons stay in the fleet's private record."
  verdict true "$ENTRIES"
done <<EOF_CANDIDATES
$CANDIDATES
EOF_CANDIDATES

if [ -n "$saw_unreadable" ]; then
  annotate warning "A supersession attestation for task $saw_unreadable verified against this commit, but what it carries could not be read, so nothing is excused and every base-assertion finding blocks."
elif [ -n "$saw_bad_signature" ]; then
  annotate warning "A supersession attestation for task $saw_bad_signature names this head commit but its signature does not verify against this repository's secret. Refusing it; every base-assertion finding blocks."
elif [ -n "$saw_other_commit" ]; then
  annotate warning "A supersession attestation was found but it is bound to commit $saw_other_commit, not this PR's head commit $HEAD_SHA. An attestation covers exactly one commit, so a fresh one is needed after every push. Every base-assertion finding blocks."
elif [ "$saw_malformed" -eq 1 ]; then
  annotate warning "A line beginning '${FM_SUPERSESSION_LINE_PREFIX}' was found but does not match the attestation grammar '${FM_SUPERSESSION_LINE_PREFIX} ${FM_SUPERSESSION_LINE_VERSION} <task-id> <40-hex-sha> <entries-token> <64-hex-signature>'. Every base-assertion finding blocks."
fi
verdict false
