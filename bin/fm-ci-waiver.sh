#!/usr/bin/env bash
# Issue and provision CI testing waivers. FIRSTMATE-SIDE ONLY: this script reads
# the waiver secret, so it runs on the captain's machine, never in a worker's
# worktree and never in CI.
#
# Usage:
#   fm-ci-waiver.sh init [--rotate]        generate and store the local secret
#   fm-ci-waiver.sh publish <owner/repo>   push that secret to a repo's Actions secrets
#   fm-ci-waiver.sh sign <task-id> <sha>   print the publishable waiver line
#
# THE SECRET
# One secret per firstmate home, stored at $FM_HOME/config/ci-waiver-secret
# (local, gitignored, mode 0600) and mirrored into every repo that must verify
# waivers as the Actions repository secret FM_CI_WAIVER_SECRET. It is never
# committed, never printed, and never given to a worker: `init` writes it
# straight to the file and `publish` pipes it straight into gh-axi, so its value
# never reaches a terminal, an argv list, or an environment variable.
# `publish` takes an explicit <owner/repo> rather than guessing one, and one
# secret serves every repo, so run it once per project whose CI must honour
# waivers.
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
# somewhere unexpected; the secret must live in the home's own config dir.
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
    node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' > "$tmp"
    umask "$old_umask"
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "error: could not generate a waiver secret" >&2; exit 1; }
    mv "$tmp" "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    echo "wrote $SECRET_FILE (mode 600, value not printed)"
    echo "next: fm-ci-waiver.sh publish <owner/repo> for every repo whose CI must honour waivers"
    ;;

  publish)
    repo=${1:-}
    case "$repo" in
      */*) : ;;
      *) echo "error: publish requires an explicit <owner/repo>" >&2; exit 2 ;;
    esac
    case "$repo" in
      *[!A-Za-z0-9._/-]*|*/*/*) echo "error: '$repo' is not a valid <owner/repo>" >&2; exit 2 ;;
    esac
    read_secret_or_die
    command -v gh-axi >/dev/null 2>&1 || {
      echo "error: gh-axi is required to set the repository secret" >&2
      exit 1
    }
    # Piped, never echoed: gh-axi secret set reads the value only from stdin and
    # never prints it back.
    if ! gh-axi secret set FM_CI_WAIVER_SECRET -R "$repo" < "$SECRET_FILE"; then
      echo "error: could not set FM_CI_WAIVER_SECRET on $repo" >&2
      exit 1
    fi
    echo "published FM_CI_WAIVER_SECRET to $repo (value not printed)"
    ;;

  sign)
    ID=${1:-}
    SHA=${2:-}
    fm_ci_waiver_valid_task_id "$ID" || { echo "error: invalid task id" >&2; exit 2; }
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
    SIG=$(fm_ci_waiver_sign "$ID" "$SHA" < "$SECRET_FILE") || {
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
