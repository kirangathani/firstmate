#!/usr/bin/env bash
# Shared HMAC primitives for the CI testing waiver.
#
# This file is the SINGLE owner of the waiver's cryptographic contract: the
# signed payload's exact bytes, the published line's grammar, and the
# constant-time comparison. Both sides of the waiver source it - the signer
# (bin/fm-ci-waiver.sh, on the captain's machine) and the verifier
# (bin/fm-ci-waiver-verify.sh, inside CI) - because a drift between two copies
# of the payload definition would either invalidate every real waiver or, far
# worse, make two different commits produce the same signature.
#
# Signed payload, exactly these bytes and no trailing newline:
#
#     fm-ci-waiver.v1\n<task-id>\n<commit-sha>
#
# The commit SHA is in the payload because it is the lock: a signature is bound
# to exactly the tree it was issued for, so a worker that obtains one signature
# cannot amend, rebase, or push new commits under it. The task id is in the
# payload for provenance and audit only - it identifies WHICH dispatch the
# captain waived, but on its own it would authorize an unbounded stream of
# future commits, which is precisely what signing the SHA prevents. A
# consequence, accepted rather than designed around: every new head commit
# needs a fresh signature.
#
# The payload is reproducible with any HMAC tool, which is what lets an operator
# audit a published waiver without this script:
#
#     printf 'fm-ci-waiver.v1\n<task-id>\n<sha>' | openssl dgst -sha256 -hmac "$secret" -r
#
# Published line grammar, one line anywhere in the PR body:
#
#     fm-ci-waiver: v1 <task-id> <commit-sha> <hmac-sha256-hex>
#
# Publishing that line is harmless by design: it is bound to one commit and
# reveals nothing about the secret, so no secrecy machinery guards it.
#
# The HMAC itself runs in node rather than `openssl dgst -hmac <key>` because
# every openssl form puts the key in argv, where any local process can read it
# from the process table. node takes the key on stdin instead, so the secret
# never appears in argv or in the environment, and node also provides
# crypto.timingSafeEqual for the comparison. node is a required tool in every
# firstmate home (docs/configuration.md "Toolchain") and is preinstalled on
# GitHub's runners, so this adds no dependency to either side.

# Domain-separation tag that opens every signed payload. Bumping it invalidates
# every previously issued signature, which is the intended effect of a scheme
# change.
FM_CI_WAIVER_SCHEME='fm-ci-waiver.v1'
# A SEPARATE domain for the dispatch-authorization token bin/fm-spawn.sh writes
# beside ci_skip=on in a task's meta, so a token from one domain can never be
# replayed as a signature in the other.
#
# Why that token exists at all: a worker appends its own status lines into the
# firstmate home's state/ directory, so it can also reach state/<id>.meta and
# append `ci_skip=on` to its own record. Without a token, that one line would be
# a worker authorizing its own waiver - the same "an agent can just type it"
# failure the whole design exists to avoid, only in a different file. The token
# is an HMAC over the task id under this scheme, so it cannot be produced
# without the secret and cannot be lifted from another task's record.
#
# Residual limit, stated rather than papered over: a worker runs as the same OS
# user as firstmate, so a worker that deliberately reads config/ci-waiver-secret
# defeats every check here. No same-user design can prevent that. What this does
# prevent is self-exemption from anything resembling the worker's sanctioned
# behaviour: there is no string to type and no line to append that grants a
# skip, so obtaining one requires going after a secret nothing ever told the
# worker about.
FM_CI_WAIVER_DISPATCH_SCHEME='fm-ci-dispatch.v1'
# Second payload field for a dispatch token, so the token names WHICH
# authorization it carries rather than the task alone.
FM_CI_WAIVER_DISPATCH_CI_SKIP='ci_skip'
# A THIRD domain, for deriving the per-repository secret that is published to a
# repository's Actions secrets.
#
# config/ci-waiver-secret is a MASTER key and is never published anywhere. What
# each repository receives is HMAC(master, this scheme, owner/repo). That matters
# because the realistic exposure is a repository secret, not the master: the
# ci-waiver job necessarily has the secret in its environment, and on a
# pull_request build it sits beside PR-authored code. Deriving contains such a
# theft to the repository it came from - the stolen key reveals nothing about the
# master (HMAC is one-way) and therefore nothing about any other repository's
# key, where a single shared secret would have handed over every repository at
# once and stayed valid until a rotate plus a re-publish everywhere.
#
# The dispatch token above deliberately keeps using the MASTER, so a stolen
# repository secret cannot mint one and cannot authorize a waiver for a task the
# captain never flagged.
FM_CI_WAIVER_REPO_SCHEME='fm-ci-waiver-repo.v1'
# Version token in the published line, paired one-to-one with the scheme above.
FM_CI_WAIVER_LINE_VERSION='v1'
FM_CI_WAIVER_LINE_PREFIX='fm-ci-waiver:'

# The one HMAC implementation, shared by sign and verify.
#   argv: <sign|verify> <scheme> <task-id> <sha> [<candidate-hex>]
#   stdin: the raw secret bytes
#   sign   -> prints the hex digest, exit 0
#   verify -> exit 0 iff the candidate matches in constant time, else exit 1
#   exit 3 -> empty secret (no verdict is possible)
# shellcheck disable=SC2016  # deliberately literal: this is a node program, not shell
FM_CI_WAIVER_NODE_PROGRAM='
const crypto = require("crypto");
const [mode, scheme, taskId, sha, candidate] = process.argv.slice(1);
const chunks = [];
process.stdin.on("data", (d) => chunks.push(d));
process.stdin.on("end", () => {
  const key = Buffer.concat(chunks);
  if (key.length === 0) { process.exitCode = 3; return; }
  const payload = Buffer.from([scheme, taskId, sha].join("\n"), "utf8");
  const mac = crypto.createHmac("sha256", key).update(payload).digest();
  if (mode === "sign") { process.stdout.write(mac.toString("hex") + "\n"); return; }
  const given = Buffer.from(String(candidate || ""), "hex");
  // Length is not secret (it is always 32 bytes), and timingSafeEqual requires
  // equal lengths, so the length check has to come first.
  if (given.length !== mac.length) { process.exitCode = 1; return; }
  process.exitCode = crypto.timingSafeEqual(mac, given) ? 0 : 1;
});
'

# fm_ci_waiver_valid_task_id <id>: the same slug rule the rest of firstmate uses
# for task ids, restated here so this library stands alone in CI, where
# bin/fm-pr-lib.sh's task-state helpers have nothing to operate on.
fm_ci_waiver_valid_task_id() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# fm_ci_waiver_valid_sha <sha>: a full 40-hex-digit commit id. Abbreviations are
# refused rather than expanded, because the verifier compares against GitHub's
# full head SHA and has no repository to resolve a short form against.
fm_ci_waiver_valid_sha() {
  local sha=${1-}
  local LC_ALL=C
  case "$sha" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#sha}" -eq 40 ]
}

# fm_ci_waiver_valid_sig <hex>: a 64-hex-digit HMAC-SHA256 digest.
fm_ci_waiver_valid_sig() {
  local sig=${1-}
  local LC_ALL=C
  case "$sig" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#sig}" -eq 64 ]
}

# fm_ci_waiver_hmac_hex <scheme> <field-a> <field-b>; secret on stdin.
fm_ci_waiver_hmac_hex() {
  node -e "$FM_CI_WAIVER_NODE_PROGRAM" sign "$1" "$2" "$3"
}

# fm_ci_waiver_hmac_check <scheme> <field-a> <field-b> <candidate-hex>; secret on
# stdin. Exit 0 iff the candidate matches in constant time, 1 if it does not, 3
# if the secret was empty. A non-zero exit is NEVER an authorization.
fm_ci_waiver_hmac_check() {
  node -e "$FM_CI_WAIVER_NODE_PROGRAM" verify "$1" "$2" "$3" "$4"
}

# fm_ci_waiver_sign <task-id> <sha>; secret on stdin. Prints the hex digest.
fm_ci_waiver_sign() {
  fm_ci_waiver_hmac_hex "$FM_CI_WAIVER_SCHEME" "$1" "$2"
}

# fm_ci_waiver_check <task-id> <sha> <candidate-hex>; secret on stdin.
fm_ci_waiver_check() {
  fm_ci_waiver_hmac_check "$FM_CI_WAIVER_SCHEME" "$1" "$2" "$3"
}

# fm_ci_waiver_dispatch_token <task-id>; secret on stdin. The value bin/fm-spawn.sh
# records as ci_skip_auth= beside ci_skip=on.
fm_ci_waiver_dispatch_token() {
  fm_ci_waiver_hmac_hex "$FM_CI_WAIVER_DISPATCH_SCHEME" "$1" "$FM_CI_WAIVER_DISPATCH_CI_SKIP"
}

# fm_ci_waiver_dispatch_check <task-id> <candidate-hex>; secret on stdin.
fm_ci_waiver_dispatch_check() {
  fm_ci_waiver_hmac_check "$FM_CI_WAIVER_DISPATCH_SCHEME" "$1" "$FM_CI_WAIVER_DISPATCH_CI_SKIP" "$2"
}

# fm_ci_waiver_repo_key <owner/repo>; the MASTER secret on stdin. Prints the hex
# secret that repository's CI verifies waivers against, and the only value
# `publish` ever sends to GitHub.
fm_ci_waiver_repo_key() {
  fm_ci_waiver_hmac_hex "$FM_CI_WAIVER_REPO_SCHEME" "$1" ''
}

# fm_ci_waiver_valid_repo <owner/repo>: 0 iff the argument is one safe
# owner/repo pair. Shared by publish and sign so a repository name can never
# reach gh-axi, or select a signing key, without passing the same check.
fm_ci_waiver_valid_repo() {
  local repo=${1-}
  case "$repo" in
    */*/*|*/) return 1 ;;
    */*) : ;;
    *) return 1 ;;
  esac
  case "$repo" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
    /*|-*) return 1 ;;
  esac
  return 0
}

# fm_ci_waiver_line <task-id> <sha> <hex>: the publishable PR-body line.
fm_ci_waiver_line() {
  printf '%s %s %s %s %s\n' \
    "$FM_CI_WAIVER_LINE_PREFIX" "$FM_CI_WAIVER_LINE_VERSION" "$1" "$2" "$3"
}
