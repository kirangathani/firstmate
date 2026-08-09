#!/usr/bin/env bash
# Durable record of the decisions a worker submits at no-mistakes gates, and the
# gate that proves each one survived to the end of the run.
#
# THIS SCRIPT IS THE ONE OWNER of that record. It lives at
# data/<task-id>/decisions.md, alongside the task's brief and report, so it
# survives worktree teardown exactly as they do and is readable by firstmate.
#
# WHY IT EXISTS. Upstream no-mistakes issue #591 (kunchenguid/no-mistakes, open,
# filed 2026-07-26 by a third party against v1.40.0) documents this sequence: an
# operator answered three ask-user findings through the supported
# `--action fix` path WITH guidance in --instructions and no --yes; the gate
# recorded them resolved and applied them; a LATER step's auto-fix in the same
# run reverted all three and added a contract test pinning one reversal in place;
# the pipeline's final review step then passed with 0 findings and reported the
# PR ready. The reporter's diagnosis, which firstmate takes as the design fact:
# decisions recorded at a gate are treated as input to the step that raised them,
# not as constraints on later steps, and the final review evaluates against
# --intent, which was written before any decision existed and therefore always
# describes the pre-decision state. The pipeline self-certified a state that
# contradicted three explicit decisions, and it was caught only because the
# driving agent diffed by hand instead of trusting `checks-passed`.
#
# no-mistakes is third-party and this fleet does not own its source, so the guard
# is firstmate-side: the worker records what each decision REQUIRED in concrete,
# checkable terms, then must check each one against the final diff before
# reporting a PR ready. `checks-passed` is not evidence that a decision survived;
# in #591 it was emitted over the reverted state.
#
# Usage:
#   fm-nm-decision.sh record <task-id> --finding <id> --key <key> --requires <text> [--step <step>]
#   fm-nm-decision.sh verify <task-id> --finding <id> --evidence <text>
#   fm-nm-decision.sh reverted <task-id> --finding <id> --evidence <text>
#   fm-nm-decision.sh list <task-id>
#   fm-nm-decision.sh check <task-id>
#   fm-nm-decision.sh path <task-id>
#
#   record    appends one decision, state `pending`. Run it at the moment the
#             decision is submitted to the gate, not later from memory.
#   verify    marks a decision `satisfied` with the evidence that proves it still
#             holds in the final diff (a diff hunk, a file:line, a test name).
#   reverted  marks a decision `contradicted`. `check` then always refuses, and
#             the worker must stop and escalate rather than report done.
#   list      prints the record.
#   check     exit 0 only when every recorded decision is `satisfied`. Exit 1
#             naming every pending or contradicted decision. A task with no
#             recorded decisions passes: a run with no gate decisions has nothing
#             to survive. Exit 2 for a usage error.
#   path      prints the record path (it may not exist yet).
#
# The record is append-mostly: `verify` and `reverted` rewrite only the state and
# evidence lines of the named decision, never its `requires` text, so what the
# decision demanded cannot be edited after the fact to match what shipped.
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
  -h|--help|"") usage; exit 0 ;;
esac

ACTION=$1
shift

case "${1:-}" in
  ""|-*) echo "error: usage: fm-nm-decision.sh $ACTION <task-id> ..." >&2; exit 2 ;;
esac
ID=$1
shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD="$DATA/$ID/decisions.md"

FINDING=
KEY=
REQUIRES=
EVIDENCE=
STEP=

need_value() {
  [ "$2" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --finding) need_value "$1" "$#"; FINDING=$2; shift 2 ;;
    --key) need_value "$1" "$#"; KEY=$2; shift 2 ;;
    --requires) need_value "$1" "$#"; REQUIRES=$2; shift 2 ;;
    --evidence) need_value "$1" "$#"; EVIDENCE=$2; shift 2 ;;
    --step) need_value "$1" "$#"; STEP=$2; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# One line per field, so a rewrite of a state line can never disturb the
# `requires` text and a reader needs no markdown parser.
one_line() {
  printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

case "$ACTION" in
  path)
    printf '%s\n' "$RECORD"
    ;;

  record)
    [ -n "$FINDING" ] || { echo "error: record requires --finding <id>" >&2; exit 2; }
    [ -n "$KEY" ] || { echo "error: record requires --key <decision-key>" >&2; exit 2; }
    [ -n "$REQUIRES" ] || { echo "error: record requires --requires <what the decision required, in concrete checkable terms>" >&2; exit 2; }
    mkdir -p "$DATA/$ID"
    if [ ! -e "$RECORD" ]; then
      cat > "$RECORD" <<EOF
# Gate decisions - $ID

Written by bin/fm-nm-decision.sh. One block per decision submitted at a
no-mistakes gate, with what it required and whether that requirement still holds
in the final diff. See that script's header and upstream no-mistakes issue #591
for why a run's own \`checks-passed\` is not evidence that a decision survived.
EOF
    fi
    if grep -qxF -- "- finding: $FINDING" "$RECORD" 2>/dev/null; then
      echo "error: finding $FINDING is already recorded in $RECORD" >&2
      exit 2
    fi
    {
      printf '\n## %s\n' "$(one_line "$FINDING")"
      printf -- '- finding: %s\n' "$(one_line "$FINDING")"
      printf -- '- key: %s\n' "$(one_line "$KEY")"
      printf -- '- step: %s\n' "$(one_line "${STEP:-unrecorded}")"
      printf -- '- recorded: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf -- '- requires: %s\n' "$(one_line "$REQUIRES")"
      printf -- '- state: pending\n'
      printf -- '- evidence: (none yet)\n'
    } >> "$RECORD"
    printf 'recorded: %s (%s) in %s\n' "$FINDING" "$KEY" "$RECORD"
    ;;

  verify|reverted)
    [ -n "$FINDING" ] || { echo "error: $ACTION requires --finding <id>" >&2; exit 2; }
    [ -n "$EVIDENCE" ] || { echo "error: $ACTION requires --evidence <what proves it in the final diff>" >&2; exit 2; }
    [ -f "$RECORD" ] || { echo "error: no decision record at $RECORD" >&2; exit 2; }
    grep -qxF -- "- finding: $FINDING" "$RECORD" || { echo "error: finding $FINDING is not recorded in $RECORD" >&2; exit 2; }
    if [ "$ACTION" = verify ]; then NEW_STATE=satisfied; else NEW_STATE=contradicted; fi
    TMP="$RECORD.tmp.$$"
    # Rewrites only the state and evidence lines of the named decision's block.
    # `active` opens on that block's `- finding:` line and closes at its evidence
    # line or the next block heading, so no other decision is touched and the
    # `requires` text is never rewritten.
    awk -v want="- finding: $FINDING" -v state="$NEW_STATE" -v evidence="- evidence: $(one_line "$EVIDENCE")" '
      /^## / { active = 0 }
      $0 == want { active = 1; print; next }
      active && /^- state: / { print "- state: " state; next }
      active && /^- evidence: / { print evidence; active = 0; next }
      { print }
    ' "$RECORD" > "$TMP"
    mv "$TMP" "$RECORD"
    printf '%s: %s in %s\n' "$NEW_STATE" "$FINDING" "$RECORD"
    ;;

  list)
    [ -f "$RECORD" ] || { echo "no decision record at $RECORD"; exit 0; }
    cat "$RECORD"
    ;;

  check)
    if [ ! -f "$RECORD" ]; then
      echo "check: no gate decisions recorded for $ID; nothing to verify"
      exit 0
    fi
    UNRESOLVED=$(awk '
      /^- finding: / { finding = substr($0, 12) }
      /^- state: pending$/ { print "pending     " finding }
      /^- state: contradicted$/ { print "contradicted " finding }
    ' "$RECORD")
    if [ -n "$UNRESOLVED" ]; then
      echo "check: REFUSED - these gate decisions are not proven to survive the final diff:" >&2
      printf '%s\n' "$UNRESOLVED" >&2
      echo "Do not report done. Verify each against the final diff with 'verify', or escalate a 'contradicted' decision to firstmate naming the decision and the reverting commit." >&2
      exit 1
    fi
    COUNT=$(grep -c '^- state: satisfied$' "$RECORD" || true)
    printf 'check: all %s recorded gate decisions verified against the final diff\n' "$COUNT"
    ;;

  *)
    echo "error: unknown action: $ACTION" >&2
    usage >&2
    exit 2
    ;;
esac
