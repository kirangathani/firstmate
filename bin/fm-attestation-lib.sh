#!/usr/bin/env bash
# fm-attestation-lib.sh - the ONE owner of the no-mistakes attestation check's
# name and of the two authorities that may excuse it.
#
# The policy itself - what that check is, why it fails on a PR the pipeline did
# not raise, what the exemption does and does not grant, and why the name is
# matched by exact string equality - is owned and documented by
# bin/fm-pr-merge.sh's header. This file is its single implementation, extracted
# for the same reason bin/fm-supersession-lib.sh was: bin/fm-pr-merge.sh decides
# whether a merge proceeds, and the read-only fleet pipeline view
# (bin/fm-flow-snapshot.sh) only classifies the same check for display. Both
# must answer "is this check excused here?" identically.
#
# They previously did not, and the cost was the whole point of that view. Every
# firstmate PR is opened with `gh pr create` because the project is registered
# direct-PR, so this check fails on every one of them by construction; the
# viewer knew nothing about the exemption and painted a permanent red `10/11
# FAIL` over healthy PRs. Observed on the captain's own screen 2026-08-09, on
# two live agents at once, with GitHub reporting 10 passed and 1 failed of 11 on
# both. An indicator that is red whatever happens is an indicator nobody reads.
#
# fm_attestation_check_name
#   Prints the exact check name. Duplicated from
#   .github/workflows/no-mistakes-required.yml's `check` job by necessity - no
#   script here can read a workflow that lives in another repository - so
#   tests/fm-pr-merge.test.sh asserts the two still agree. A rename therefore
#   stops the exemption applying, in the safe direction: the renamed check is no
#   longer recognised, so it is no longer excused, so a failing one refuses the
#   merge. A rename can only ever cost a merge, never grant one.
#
# fm_attestation_authority <task-id> <meta-file> <config-dir> <fm-home> <bin-dir>
#   Prints the newline-delimited authority lines that excuse that one check for
#   that one task, and returns 0 iff there is at least one. Empty output plus a
#   non-zero return means nothing is excused, which is the answer every
#   unverifiable path gives.
#
#   Both authorities are read on the captain's machine, from records the PR
#   cannot influence, and both are stated in full by bin/fm-pr-merge.sh's
#   header. Neither the flag line nor the registry is taken on trust: the flag
#   line is worthless without a signature this home's own key reproduces for
#   this task id, and the registry is firstmate's own private navigation record
#   that no brief or status protocol ever points a worker at.
#
# Diagnostics go to stderr, and every one of them explains a refusal rather than
# a grant. FM_ATTESTATION_QUIET=1 suppresses them for a caller that re-resolves
# on a timer and would otherwise repeat the same note every refresh; it changes
# no verdict, and the loud place for an unexcused red check is the merge that
# refuses it, not a view redrawn every ten seconds.

FM_ATTESTATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-ci-waiver-lib.sh
# shellcheck disable=SC1091
. "$FM_ATTESTATION_LIB_DIR/fm-ci-waiver-lib.sh"
# shellcheck source=bin/fm-testing-skip-lib.sh
# shellcheck disable=SC1091
. "$FM_ATTESTATION_LIB_DIR/fm-testing-skip-lib.sh"

# The ONE check name whose failure may be excused, and only ever by exact string
# equality against a rollup entry's name - never a prefix, a substring, or a
# pattern.
FM_ATTESTATION_CHECK_NAME='PR must be raised via no-mistakes'

fm_attestation_check_name() {
  printf '%s' "$FM_ATTESTATION_CHECK_NAME"
}

fm_attestation_note() {  # <message>
  [ -n "${FM_ATTESTATION_QUIET:-}" ] || echo "$1" >&2
}

# fm_attestation_signed_skip: 0 iff this task's meta pairs a testing-skip flag
# with a token this home's own secret reproduces for THIS task id. The pairing
# is the whole point: the flag line alone is reachable by the worker, the token
# is not. Every failure path here - no flag, no token, a malformed token, no
# secret, no node - returns non-zero, so an unverifiable claim is never an
# authorization.
fm_attestation_signed_skip() {  # <task-id> <meta-file> <secret-file> <meta-field> <checker-fn> <label>
  local id=$1 meta=$2 secret=$3 field=$4 checker=$5 label=$6 auth
  auth=$(grep -m1 "^$field=" "$meta" | cut -d= -f2- || true)
  if [ -z "$auth" ] || ! fm_ci_waiver_valid_sig "$auth"; then
    fm_attestation_note "note: this task records a $label but no usable $field= signature, so the skip authorizes nothing here"
    return 1
  fi
  if ! fm_ci_waiver_secret_readable "$secret"; then
    fm_attestation_note "note: this task records a $label with a $field= signature, but this home has no signing key at $secret to check it against, so the skip authorizes nothing here"
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    fm_attestation_note "note: node is unavailable, so this task's $field= signature cannot be checked and the skip authorizes nothing here"
    return 1
  fi
  if ! "$checker" "$id" "$auth" < "$secret"; then
    fm_attestation_note "error: this task records a $label whose $field= signature this home's key does NOT reproduce for $id; treating it as unauthorized"
    fm_attestation_note "error: that pairing means the flag line was not written by this home's own dispatch - re-dispatch the task with the flag rather than editing its record"
    return 1
  fi
  return 0
}

fm_attestation_authority() {  # <task-id> <meta-file> <config-dir> <fm-home> <bin-dir>
  local id=$1 meta=$2 config=$3 home=$4 bindir=$5
  local out='' secret mode yolo proj_path proj_name

  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1

  secret="$config/ci-waiver-secret"
  fm_testing_skip_read "$meta"

  if [ "$FM_TESTING_SKIP_LOCAL" = on ] \
    && fm_attestation_signed_skip "$id" "$meta" "$secret" \
         local_skip_auth fm_ci_waiver_dispatch_local_check "captain-authorized local-pipeline skip"; then
    out="${out}${out:+
}a captain-authorized local-pipeline skip on this task, signed at dispatch by this home's own key"
  fi
  if [ "$FM_TESTING_SKIP_CI" = on ] \
    && fm_attestation_signed_skip "$id" "$meta" "$secret" \
         ci_skip_auth fm_ci_waiver_dispatch_check "captain-authorized CI skip"; then
    out="${out}${out:+
}a captain-authorized CI skip on this task, signed at dispatch by this home's own key"
  fi

  proj_path=$(grep '^project=' "$meta" | tail -1 | cut -d= -f2- || true)
  proj_name=
  [ -z "$proj_path" ] || proj_name=$(basename "$proj_path")
  if [ -n "$proj_name" ] && [ -x "$bindir/fm-project-mode.sh" ]; then
    read -r mode yolo <<EOF_MODE
$(FM_HOME="$home" "$bindir/fm-project-mode.sh" "$proj_name")
EOF_MODE
    : "$yolo"
    if [ "$mode" = direct-PR ]; then
      out="${out}${out:+
}$proj_name is registered as a direct-PR project, whose PRs are raised without the pipeline by design"
    fi
  fi

  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
  return 0
}
