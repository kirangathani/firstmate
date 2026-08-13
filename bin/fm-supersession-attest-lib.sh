#!/usr/bin/env bash
# Shared wire format for the captain-signed SUPERSESSION ATTESTATION: the one
# thing that carries a captain's approval of a superseded base assertion into
# CI, which cannot read the approval record itself.
#
# THE PROBLEM IT EXISTS FOR. bin/fm-pr-merge.sh honours an approved entry in
# $FM_HOME/data/supersessions/<project>.md and proceeds. The required check
# `Base assertions re-verified` re-runs the same base assertions on a GitHub
# runner, cannot see that record - it is captain-private and gitignored by
# design - reports the same findings, and goes red. Nothing the branch pushes
# fixes that, because the branch is not what is wrong: it is the APPROVAL that
# CI cannot read. Without this file the only ways out are a mislabelled CI
# waiver or a GitHub-UI merge, which is the exact bypass that check exists to
# prevent.
#
# THIS FILE IS THE SINGLE OWNER of the attestation's cryptographic contract:
# the signed payload's exact bytes, the token that carries the approved entries,
# and the published line's grammar. Both sides source it - the signer
# (bin/fm-supersession-attest.sh, on the captain's machine) and the verifier
# (bin/fm-supersession-verify.sh, inside CI) - because a drift between two
# copies of the payload definition would either invalidate every real
# attestation or, far worse, let one PR's approval verify on another's code.
#
# It owns the WIRE only. What an entry means, and whether one covers a finding,
# stays with bin/fm-supersession-lib.sh, which is the one matcher every reader
# of the record and of this token goes through. The HMAC itself, and the
# per-repository key derivation, stay with bin/fm-ci-waiver-lib.sh, which is
# this fleet's one implementation of both. This file adds a wire format and
# borrows both; it reimplements neither.
#
# WHAT IS PUBLISHED, and what is deliberately not. The token carries the
# MATCHING HALF of each approved entry and nothing else: its identifier or glob,
# and the finding class it excuses. The captain's stated REASON and the DATE of
# the approval never leave the private record - they are the fleet's own
# deliberation, the matcher has never read them, and a PR body is a public
# place. bin/fm-supersession-lib.sh's canonical entry line is that half's exact
# form.
#
# Signed payload, exactly these bytes and no trailing newline:
#
#     fm-supersession.v1\n<task-id>\n<commit-sha>.<entries-token>
#
# THE SHA IS THE LOCK, for the same reason it is in a CI waiver
# (bin/fm-ci-waiver-lib.sh owns that reasoning): the verifier accepts a line
# SOLELY on its signature matching the CURRENT head, and never checks that the
# task named in it has anything to do with the pull request carrying it. A
# signature bound to a task id alone would therefore excuse those identifiers in
# any PR of that repository the line was pasted into - and the line is published
# in a PR body. The accepted consequence is the same too: every new head commit
# needs a fresh attestation.
#
# THE ENTRIES ARE IN THE PAYLOAD, not merely beside it, so the set the captain
# approved cannot be widened after signing. Editing one character of the token
# is a different payload and a signature that no longer verifies.
#
# The two are ONE payload field, joined by a dot, because bin/fm-ci-waiver-lib.sh's
# payload has exactly two fields and its shape must not grow a third: every
# signature and dispatch token already in flight is bytes under the current
# shape, and adding a field would change all of them at once. The join is
# unambiguous by construction - the SHA is validated as exactly 40 hex digits
# and the token's alphabet excludes the dot - so no two different (sha, token)
# pairs can produce the same field.
#
# Published line grammar, one line anywhere in the PR body:
#
#     fm-supersession: v1 <task-id> <commit-sha> <entries-token> <hmac-sha256-hex>
#
# Publishing it is harmless by design: it is bound to one commit, it carries no
# private text, and it reveals nothing about the secret.
#
# THE LABEL IS NOT THE CI WAIVER'S, deliberately, and neither is the key. The
# two mean opposite things: a waiver says there is NO test evidence, so nothing
# ran; an attestation says there IS evidence and the captain has overridden a
# specific assertion the evidence reports. Rendering them the same way in a
# check's output would make a merge log unreadable exactly where it matters
# most. The separate HMAC domain below enforces that at the wire: neither line
# can ever verify as the other, whichever body it is pasted into.

FM_SUPERSESSION_ATTEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourced here rather than left to each caller, so no caller can end up with
# this file's wire format and a missing matcher or a missing HMAC.
# shellcheck source=bin/fm-ci-waiver-lib.sh
# shellcheck disable=SC1091
. "$FM_SUPERSESSION_ATTEST_LIB_DIR/fm-ci-waiver-lib.sh"
# shellcheck source=bin/fm-supersession-lib.sh
# shellcheck disable=SC1091
. "$FM_SUPERSESSION_ATTEST_LIB_DIR/fm-supersession-lib.sh"

# Domain-separation tag that opens every signed attestation payload. Bumping it
# invalidates every previously issued attestation, which is the intended effect
# of a scheme change.
FM_SUPERSESSION_ATTEST_SCHEME='fm-supersession.v1'
# A SEPARATE domain for deriving the per-repository key an attestation is signed
# with, so that key is not the repository's CI-waiver key either.
#
# It is derived from the same master (bin/fm-ci-waiver.sh's header owns why the
# master is never published), so the containment property is unchanged: a theft
# from one repository's Actions secrets reveals nothing about the master and
# therefore nothing about any other repository.
#
# It is a DIFFERENT published key from FM_CI_WAIVER_SECRET for one reason worth
# stating plainly: the waiver key is strictly the more powerful grant, since it
# skips a PR's entire test suite, while this one only excuses findings the
# captain has already approved by name. Two keys mean a theft of this one cannot
# escalate into that one, and each Actions secret has an answerable "what can
# this authorize?".
FM_SUPERSESSION_REPO_SCHEME='fm-supersession-repo.v1'
# Version token in the published line, paired one-to-one with the scheme above.
FM_SUPERSESSION_LINE_VERSION='v1'
FM_SUPERSESSION_LINE_PREFIX='fm-supersession:'
# The Actions secret name a repository holds this attestation's key under.
# Stated here rather than only in the workflow so the publisher and the
# workflow cannot drift into two different names.
# shellcheck disable=SC2034  # read by the publisher and the verifier that source this file
FM_SUPERSESSION_SECRET_NAME='FM_SUPERSESSION_SECRET'

# base64url without padding, so the token is one whitespace-free field that
# survives a PR body, a Markdown renderer and a copy-paste. It is an ENCODING
# and not a secrecy measure: anyone can decode it, and the plain-text entries it
# holds are test identifiers from a public repository. What keeps the private
# half private is that it was never put in here.
# shellcheck disable=SC2016  # deliberately literal: this is a node program, not shell
FM_SUPERSESSION_ENCODE_PROGRAM='
const fs = require("fs");
process.stdout.write(fs.readFileSync(0).toString("base64url"));
'
# Decoding REFUSES a token that is not the canonical encoding of what it
# decodes to - standard base64, padding, stray characters - rather than
# accepting a second spelling of the same bytes. The signature covers the token
# as written, so a second spelling could never verify anyway; refusing here as
# well means the failure reads as "this is not a token" rather than as "this
# signature is wrong".
# shellcheck disable=SC2016  # deliberately literal: this is a node program, not shell
FM_SUPERSESSION_DECODE_PROGRAM='
const token = process.argv[1] || "";
const bytes = Buffer.from(token, "base64url");
if (bytes.toString("base64url") !== token) { process.exitCode = 1; }
else { process.stdout.write(bytes); }
'

# fm_supersession_valid_token <token>: 0 iff <token> is a non-empty unpadded
# base64url string. Length is bounded because the token rides in a PR body and
# an unbounded one would be a way to make that body unusable; a fleet whose
# approval record outgrows it has a record to prune, not a limit to raise.
fm_supersession_valid_token() {
  local token=${1-}
  local LC_ALL=C
  case "$token" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#token}" -le 60000 ]
}

# fm_supersession_token_encode: canonical entry lines on stdin, token on stdout.
fm_supersession_token_encode() {
  node -e "$FM_SUPERSESSION_ENCODE_PROGRAM"
}

# fm_supersession_token_decode <token>: canonical entry lines on stdout. Exit 1
# when the argument is not a canonical unpadded base64url token.
fm_supersession_token_decode() {
  fm_supersession_valid_token "${1-}" || return 1
  node -e "$FM_SUPERSESSION_DECODE_PROGRAM" "$1"
}

# fm_supersession_attest_sign <task-id> <sha> <token>; the REPOSITORY key on
# stdin. Prints the hex digest.
fm_supersession_attest_sign() {
  fm_ci_waiver_hmac_hex "$FM_SUPERSESSION_ATTEST_SCHEME" "$1" "$2.$3"
}

# fm_supersession_attest_check <task-id> <sha> <token> <candidate-hex>; the
# repository key on stdin. Exit 0 iff the candidate matches in constant time, 1
# if it does not, 3 if the secret was empty. A non-zero exit is NEVER an
# authorization.
fm_supersession_attest_check() {
  fm_ci_waiver_hmac_check "$FM_SUPERSESSION_ATTEST_SCHEME" "$1" "$2.$3" "$4"
}

# fm_supersession_attest_repo_key <owner/repo>; the MASTER secret on stdin.
# Prints the hex secret that repository's CI verifies attestations against, and
# the only value the publisher ever sends to GitHub.
fm_supersession_attest_repo_key() {
  fm_ci_waiver_hmac_hex "$FM_SUPERSESSION_REPO_SCHEME" "$1" ''
}

# fm_supersession_attest_line <task-id> <sha> <token> <hex>: the publishable
# PR-body line.
fm_supersession_attest_line() {
  printf '%s %s %s %s %s %s\n' \
    "$FM_SUPERSESSION_LINE_PREFIX" "$FM_SUPERSESSION_LINE_VERSION" "$1" "$2" "$3" "$4"
}
