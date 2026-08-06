#!/usr/bin/env bash
# Issue and provision CI testing waivers. FIRSTMATE-SIDE ONLY: this script reads
# the waiver secret, so it runs on the captain's machine, never in a worker's
# worktree and never in CI.
#
# Usage:
#   fm-ci-waiver.sh init [--rotate]                generate and store the master key
#   fm-ci-waiver.sh publish <owner/repo>           push that repo's derived key to its Actions secrets
#   fm-ci-waiver.sh sign <task-id> <sha> <owner/repo>   print the publishable waiver line
#
# THE SECRET
# One MASTER key per firstmate home, stored at $FM_HOME/config/ci-waiver-secret
# (local, gitignored, mode 0600). The master is never published anywhere. What
# each repository receives as the Actions secret FM_CI_WAIVER_SECRET is a key
# DERIVED for that repository alone, so a theft from one repository's secrets is
# contained to that repository and reveals nothing about the master or any other
# repository; bin/fm-ci-waiver-lib.sh owns the derivation and the reasoning.
#
# That containment is the point: the ci-waiver job necessarily holds the secret
# in its environment, and on a pull_request build it sits beside PR-authored
# code, so a repository key is the realistic thing to lose.
#
# Nothing is ever committed, printed, or given to a worker: `init` writes the
# master straight to the file, and `publish` derives and pipes the repository key
# straight into gh-axi through a shell builtin, so no value reaches a terminal,
# an argv list, or an environment variable.
#
# `publish` and `sign` both take an explicit <owner/repo> rather than guessing
# one. Run `publish` once per project whose CI must honour waivers; `init` stays
# a one-off per home.
#
# THE AUTHORITY CHECK
# `sign` refuses unless the task's own state/<id>.meta records BOTH ci_skip=on
# and a ci_skip_auth= token that this home's secret reproduces for that task id.
# That refusal is the whole authorization model.
#
# The second half is not belt-and-braces. A worker appends its status lines into
# the firstmate home's state/ directory, so it can append `ci_skip=on` to its own
# record just as easily - and a check that accepted the bare flag would be an
# agent authorizing its own waiver by typing one line, which is the exact failure
# this design exists to prevent. The token is an HMAC minted only by
# bin/fm-spawn.sh at dispatch, so the flag can only have come from a dispatch the
# captain actually made. bin/fm-ci-waiver-lib.sh states the residual same-user
# limit that no design in this space can remove.
#
# WHY THE WORKER MUST ASK AFTER ITS FINAL COMMIT
# The signature covers the head commit SHA (bin/fm-ci-waiver-lib.sh owns why),
# so it cannot exist before the code does, and CI must see it on the PR's first
# run - editing a body after the fact does not re-trigger the workflow. The flow
# that satisfies both is: the worker commits, pushes its branch (pushing a
# feature branch triggers no workflow), reports its head SHA, receives the line
# from firstmate, and only then opens the PR with that line in the body.
# bin/fm-brief.sh writes those instructions into a --ci-skip brief.
#
# Publishing the signature is harmless: it is bound to one commit and reveals
# nothing about the secret.
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

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECRET_FILE="$CONFIG/ci-waiver-secret"

require_node() {
  command -v node >/dev/null 2>&1 && return 0
  echo "error: node is required to compute the waiver signature (docs/configuration.md \"Toolchain\")" >&2
  return 1
}

# Refuse a secret file that is a symlink or unreadable rather than following it
# somewhere unexpected; the secret must live in the home's own config dir. This
# is the single statement of that shape rule, and each case names its own
# remedy, so the three checks stay separate rather than collapsing into one.
read_secret_or_die() {
  if [ ! -e "$SECRET_FILE" ]; then
    echo "error: no CI waiver secret at $SECRET_FILE; run 'fm-ci-waiver.sh init' first" >&2
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

cmd=$1
shift

case "$cmd" in
  init)
    rotate=0
    for a in "$@"; do
      case "$a" in
        --rotate) rotate=1 ;;
        *) echo "error: unknown init argument '$a'" >&2; exit 2 ;;
      esac
    done
    require_node || exit 1
    if [ -e "$SECRET_FILE" ] && [ "$rotate" -eq 0 ]; then
      echo "error: $SECRET_FILE already exists; pass --rotate to replace it" >&2
      echo "error: rotating invalidates every signature already published on an open PR, and every repo secret must be re-published afterwards" >&2
      exit 1
    fi
    mkdir -p "$CONFIG"
    old_umask=$(umask)
    umask 077
    tmp="$SECRET_FILE.tmp.$$"
    # Guarded rather than bare, because under `set -e` a failing node would abort
    # here and leave both the tightened umask and the temp file behind.
    generated=
    if node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' > "$tmp"; then
      generated=$(cat "$tmp")
    fi
    umask "$old_umask"
    # Validated with the same rule both derived-key paths use, so a truncated
    # write refuses loudly instead of installing a short master whose every
    # signature would be weak without ever failing. The value stays in a shell
    # variable: it is never printed, and never reaches argv or the environment.
    if ! fm_ci_waiver_valid_sig "$generated"; then
      rm -f "$tmp"
      echo "error: could not generate a usable waiver secret; any existing secret is unchanged" >&2
      exit 1
    fi
    mv "$tmp" "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    echo "wrote $SECRET_FILE (mode 600, value not printed)"
    echo "next: fm-ci-waiver.sh publish <owner/repo> for every repo whose CI must honour waivers"
    ;;

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
    # The MASTER never leaves this machine. What this repository receives is a
    # key derived for it alone, so a theft from its Actions secrets is contained
    # to this one repository (bin/fm-ci-waiver-lib.sh owns why).
    repo_key=$(fm_ci_waiver_repo_key "$repo" < "$SECRET_FILE") || {
      echo "error: could not derive the repository key for $repo" >&2
      exit 1
    }
    fm_ci_waiver_valid_sig "$repo_key" || {
      echo "error: key derivation for $repo produced an unusable value" >&2
      exit 1
    }
    # printf is a shell builtin, so the value is not exposed in any argv, and
    # gh-axi secret set reads it only from stdin and never prints it back.
    if ! printf '%s' "$repo_key" | gh-axi secret set FM_CI_WAIVER_SECRET -R "$repo"; then
      echo "error: could not set FM_CI_WAIVER_SECRET on $repo" >&2
      exit 1
    fi
    echo "published FM_CI_WAIVER_SECRET to $repo (derived for that repo, value not printed)"
    ;;

  sign)
    ID=${1:-}
    SHA=${2:-}
    REPO=${3:-}
    fm_ci_waiver_valid_task_id "$ID" || { echo "error: invalid task id" >&2; exit 2; }
    [ -n "$REPO" ] || {
      echo "error: sign requires the <owner/repo> the PR will be opened against" >&2
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
    # THE authority check, in two halves. Nothing else in this script grants
    # authority, and there is no override flag: an unflagged task cannot be
    # waived at all.
    if ! grep -qx 'ci_skip=on' "$META"; then
      echo "error: task $ID was not dispatched with --ci-skip or --all-testing-skip, so its CI cannot be waived" >&2
      echo "error: the flag is set by the captain at dispatch (bin/fm-spawn.sh); re-dispatch the task with the flag rather than signing around this refusal" >&2
      exit 1
    fi
    require_node || exit 1
    read_secret_or_die
    # Second half: the flag must carry the dispatch token bin/fm-spawn.sh minted
    # for THIS task. The flag line alone is not enough, because a worker appends
    # its own status lines into this same state directory and could append that
    # line too; the token is an HMAC it cannot compute.
    AUTH=$(grep -m1 '^ci_skip_auth=' "$META" | cut -d= -f2- || true)
    if [ -z "$AUTH" ] || ! fm_ci_waiver_valid_sig "$AUTH" \
      || ! fm_ci_waiver_dispatch_check "$ID" "$AUTH" < "$SECRET_FILE"; then
      echo "error: task $ID records ci_skip=on but no valid dispatch authorization for it; refusing to sign" >&2
      echo "error: that pairing means the flag line was not written by this home's own dispatch - re-dispatch the task with --ci-skip or --all-testing-skip instead of editing its record" >&2
      exit 1
    fi
    # Signed with the key derived for THIS repository, which is the only key its
    # CI holds. The dispatch check above deliberately used the master instead, so
    # a stolen repository key cannot authorize a task the captain never flagged.
    REPO_KEY=$(fm_ci_waiver_repo_key "$REPO" < "$SECRET_FILE") || {
      echo "error: could not derive the repository key for $REPO" >&2
      exit 1
    }
    SIG=$(printf '%s' "$REPO_KEY" | fm_ci_waiver_sign "$ID" "$SHA") || {
      echo "error: could not compute the waiver signature" >&2
      exit 1
    }
    fm_ci_waiver_valid_sig "$SIG" || { echo "error: signature computation produced an unusable value" >&2; exit 1; }
    fm_ci_waiver_line "$ID" "$SHA" "$SIG"
    ;;

  *)
    echo "error: unknown subcommand '$cmd'" >&2
    exit 2
    ;;
esac
