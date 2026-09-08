#!/usr/bin/env bash
# Durable record of the decisions a worker submits at no-mistakes gates, and the
# path by which each one becomes part of the goal the pipeline scores against.
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
# describes the pre-decision state.
#
# THE FIX IS TO MOVE THE INTENT, NOT TO AUDIT THE DIFF. A stale --intent is the
# root cause, and it costs more than the reverted-decision case: a re-run and a
# final review scored against a goal the captain has since changed can also fail
# code that correctly matches the DECIDED goal. So `record` amends the task's
# pinned intent in place - it writes the decision into the `# Task` section of
# data/<task-id>/brief.md, under a `## Gate decisions` subsection - and
# bin/fm-nm-intent.sh, which reads that whole section and remains the one owner
# of "what is the intent", emits it on the very next call with no second reader
# and nothing to keep in sync. The worker then starts a fresh run on the amended
# intent, and THAT run's review is the mechanical proof that the branch and the
# decided goal agree. It also re-reviews whatever the later auto-fix steps
# (test, document, lint) changed, which nothing else in the pipeline does.
#
# Usage:
#   fm-nm-decision.sh record <task-id> --finding <id> --key <key> --requires <text> [--step <step>] [--outcome change|no-change] [--fixed "<finding ids>"]
#   fm-nm-decision.sh rerun-check <task-id>
#   fm-nm-decision.sh list <task-id>
#   fm-nm-decision.sh path <task-id>
#   fm-nm-decision.sh verify <task-id> --finding <id> --evidence <text>      (optional diagnostic)
#   fm-nm-decision.sh reverted <task-id> --finding <id> --evidence <text>    (optional diagnostic)
#   fm-nm-decision.sh check <task-id>                                        (optional diagnostic)
#
#   record       records one decision AND amends the brief's `# Task` section
#                with `- <finding> [<key>]: <requires>`. Run it at the moment the
#                decision is submitted to the gate, not later from memory.
#                Re-recording the same key rewrites that line and that decision's
#                block rather than duplicating either, so a revised decision
#                leaves one current statement of itself in both places. Refuses
#                when the brief is missing or has no `# Task` section, because a
#                decision that cannot reach the intent is the failure this exists
#                to prevent. Also stores the no-mistakes run id current at the
#                moment of recording, which is what rerun-check compares.
#                `--outcome no-change` declares that the answer leaves the branch
#                exactly as it is - "no change", "already decided at <key>", a
#                documentation wording accepted as written - so no fresh run is
#                owed for it. A no-change decision is annotated `(no-change)` in
#                both the record and the brief line, so a reviewer can see why no
#                re-run followed. `--outcome change` is the default and keeps the
#                original behavior. `--fixed "<ids>"` names the finding ids this
#                round submitted a fix for; `--outcome no-change` is REFUSED when
#                the recorded finding is among them, because a round that changed
#                code for a finding cannot also claim the branch is untouched.
#   rerun-check  the done gate. Exit 0 only when every recorded CHANGE decision
#                was recorded during a run OLDER than the most recent one, which
#                is what proves a fresh run scored the branch against the amended
#                intent. No-change decisions are listed but never demand a
#                re-run: a 25-35 minute run that re-scores a branch nothing
#                touched proves nothing, and paying it per answer is what made
#                gate rounds expensive enough to discourage answering at all.
#                Exit 1 naming every change decision still waiting for that
#                re-run, and exit 1 when the current run id cannot be read at
#                all, since an unreadable run confirms nothing either way. A task
#                with no recorded decisions passes: an unamended intent needs no
#                re-run. Exit 2 for a usage error.
#   list         prints the record.
#   path         prints the record path (it may not exist yet).
#
# The three optional diagnostics below are NOT a gate and nothing blocks on them.
# They predate the intent amendment, when the guard was a hand audit of the final
# diff; that audit is now the fresh run's review. They remain because reading
# what a decision demanded, and marking by hand what a specific inspection found,
# is still useful when investigating a suspect run:
#
#   verify    marks a decision `satisfied` with evidence that it holds.
#   reverted  marks a decision `contradicted` with the reverting commit.
#   check     exit 0 only when every recorded decision is `satisfied`, exit 1
#             naming every pending or contradicted one.
#
# `verify` and `reverted` rewrite only the state and evidence lines of the named
# decision, never its `requires` text, so what the decision demanded cannot be
# edited after the fact to match what shipped.
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
BRIEF="$DATA/$ID/brief.md"

# The subsection `record` maintains inside the brief's `# Task` section. The
# heading is the anchor: it carries no HTML marker because bin/fm-nm-intent.sh
# emits this text verbatim into --intent, where a marker would be noise the
# pipeline's review has to read past.
GATE_HEADING='## Gate decisions'
GATE_LEAD='These were decided at this task'"'"'s validation gates and are part of the goal; the branch must reflect them.'

FINDING=
KEY=
REQUIRES=
EVIDENCE=
STEP=
OUTCOME=change
FIXED=

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
    --outcome) need_value "$1" "$#"; OUTCOME=$2; shift 2 ;;
    --fixed) need_value "$1" "$#"; FIXED=$2; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# One line per field, so a rewrite of a state line can never disturb the
# `requires` text and a reader needs no markdown parser.
one_line() {
  printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# The no-mistakes run id current in this directory, or empty when it cannot be
# read. Best-effort by design: `record` must never refuse a real decision just
# because the pipeline is momentarily unreadable, and `rerun-check` reports the
# unknown case rather than guessing past it.
current_run_id() {
  command -v no-mistakes >/dev/null 2>&1 || return 0
  no-mistakes axi status 2>/dev/null \
    | sed -n 's/^[[:space:]]*id:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' \
    | head -1
}

case "$ACTION" in
  path)
    printf '%s\n' "$RECORD"
    ;;

  record)
    [ -n "$FINDING" ] || { echo "error: record requires --finding <id>" >&2; exit 2; }
    [ -n "$KEY" ] || { echo "error: record requires --key <decision-key>" >&2; exit 2; }
    [ -n "$REQUIRES" ] || { echo "error: record requires --requires <what the decision required, in concrete checkable terms>" >&2; exit 2; }
    case "$OUTCOME" in
      change|no-change) ;;
      *) echo "error: --outcome must be change or no-change, got: $OUTCOME" >&2; exit 2 ;;
    esac
    FINDING=$(one_line "$FINDING")
    KEY=$(one_line "$KEY")
    REQUIRES=$(one_line "$REQUIRES")

    # A round that submitted a fix for this finding changed the branch, so it
    # cannot also be recorded as leaving the branch alone. Refusing here is what
    # stops --outcome no-change from laundering a code change past the re-run.
    if [ "$OUTCOME" = no-change ] && [ -n "$FIXED" ]; then
      for fixed_id in $(printf '%s' "$FIXED" | tr ',' ' '); do
        [ "$fixed_id" = "$FINDING" ] || continue
        echo "error: $FINDING is in this round's fixed set, so it cannot be recorded --outcome no-change; a round that changed code for a finding owes the fresh run that re-scores it" >&2
        exit 2
      done
    fi

    # The brief line carries the outcome only when it is no-change: that is the
    # case a reviewer has to be able to explain (why no re-run followed), and the
    # line is emitted verbatim into --intent, where a "(change)" on every other
    # line would be noise the pipeline's own review reads past.
    if [ "$OUTCOME" = no-change ]; then
      BRIEF_LINE="- $FINDING [$KEY] (no-change): $REQUIRES"
    else
      BRIEF_LINE="- $FINDING [$KEY]: $REQUIRES"
    fi

    # Refuse before writing anything. A decision recorded into a record but not
    # into the intent is exactly the drift this script exists to remove, so half
    # an amendment must never be the outcome.
    [ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF; a decision amends the task's pinned intent, and there is no intent to amend" >&2; exit 2; }
    grep -qx '# Task' "$BRIEF" || { echo "error: $BRIEF has no '# Task' section, so a decision has nowhere to land; bin/fm-nm-intent.sh reads the intent from that section" >&2; exit 2; }

    BRIEF_TMP="$BRIEF.tmp.$$"
    awk -v heading="$GATE_HEADING" -v lead="$GATE_LEAD" -v key="$KEY" \
        -v newline="$BRIEF_LINE" '
      function out(s) { print s; blank = (s == "") }
      # Blank lines inside the Task section are held back and re-emitted only
      # when a further line follows, so a trailing blank never lands between the
      # existing decision lines and the one being appended.
      function emit(s) { while (pending > 0) { out(""); pending-- } out(s) }
      # True only for a line this subsection owns:
      # "- <finding-id> [<key>]: ..." or "- <finding-id> [<key>] (no-change): ...",
      # with nothing but the finding id before the bracket, so a `[<key>]` that
      # appears inside some other decision'"'"'s requires text is never rewritten.
      # Matching both shapes is what lets a decision be re-recorded with a
      # different outcome and still leave exactly one line behind.
      function is_key_line(s,   p, rest) {
        if (substr(s, 1, 2) != "- ") return 0
        p = index(s, " [" key "]")
        if (p == 0) return 0
        if (index(substr(s, 3, p - 3), " ") != 0) return 0
        rest = substr(s, p + length(key) + 3)
        return (substr(rest, 1, 2) == ": " || substr(rest, 1, 2) == " (")
      }
      function flush() {
        if (emitted) return
        emitted = 1
        pending = 0
        if (!seen) { out(""); out(heading); out(lead) }
        if (!replaced) out(newline)
      }
      !intask && $0 == "# Task" { intask = 1; out($0); next }
      intask && $0 == "" { pending++; next }
      intask && /^# / { flush(); out(""); intask = 0; out($0); next }
      intask && $0 == heading { seen = 1; emit($0); next }
      intask && seen && is_key_line($0) {
        if (!replaced) { emit(newline); replaced = 1 }
        next
      }
      intask { emit($0); next }
      { out($0) }
      END { if (intask) flush() }
    ' "$BRIEF" > "$BRIEF_TMP"
    mv "$BRIEF_TMP" "$BRIEF"

    mkdir -p "$DATA/$ID"
    if [ ! -e "$RECORD" ]; then
      cat > "$RECORD" <<EOF
# Gate decisions - $ID

Written by bin/fm-nm-decision.sh. One block per decision submitted at a
no-mistakes gate, with what it required and the run it was recorded during.
Each decision is also written into the \`# Task\` section of this task's brief,
which is where the pipeline's own \`--intent\` comes from; see that script's
header and upstream no-mistakes issue #591 for why.
EOF
    fi
    RUN_ID=$(current_run_id)
    # Drop any earlier block for this key or this finding, then append the fresh
    # one, so a re-recorded decision leaves exactly one current block.
    RECORD_TMP="$RECORD.tmp.$$"
    awk -v keyline="- key: $KEY" -v findline="- finding: $FINDING" '
      function out(s) { print s; blank = (s == "") }
      function flush(   i) {
        while (n > 0 && blk[n] == "") n--
        if (n > 0 && !drop) {
          if (!blank) out("")
          for (i = 1; i <= n; i++) out(blk[i])
        }
        n = 0; drop = 0
      }
      /^## / { flush(); blk[++n] = $0; inblock = 1; next }
      inblock { blk[++n] = $0; if ($0 == keyline || $0 == findline) drop = 1; next }
      { out($0) }
      END { flush() }
    ' "$RECORD" > "$RECORD_TMP"
    mv "$RECORD_TMP" "$RECORD"
    {
      printf '\n## %s\n' "$FINDING"
      printf -- '- finding: %s\n' "$FINDING"
      printf -- '- key: %s\n' "$KEY"
      printf -- '- outcome: %s\n' "$OUTCOME"
      printf -- '- step: %s\n' "$(one_line "${STEP:-unrecorded}")"
      printf -- '- recorded: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf -- '- run: %s\n' "${RUN_ID:-unknown}"
      printf -- '- requires: %s\n' "$REQUIRES"
      printf -- '- state: pending\n'
      printf -- '- evidence: (none yet)\n'
    } >> "$RECORD"
    printf 'recorded: %s (%s, %s) in %s and in the pinned intent at %s\n' "$FINDING" "$KEY" "$OUTCOME" "$RECORD" "$BRIEF"
    ;;

  rerun-check)
    if [ ! -f "$RECORD" ]; then
      echo "rerun-check: no gate decisions recorded for $ID; the intent was never amended, so no re-run is owed"
      exit 0
    fi
    CURRENT=$(current_run_id)
    if [ -z "$CURRENT" ]; then
      echo "rerun-check: REFUSED - could not read the current no-mistakes run id from $PWD, so a re-run cannot be confirmed either way." >&2
      echo "Run this from the task worktree. If the run really is unreadable, say so when you report, rather than reporting done on an unchecked re-run." >&2
      exit 1
    fi
    # A block written before --outcome existed has no outcome line, so the
    # per-block default is `change` and an old record keeps its old meaning.
    STALE=$(awk -v cur="$CURRENT" '
      /^## / { outcome = "change" }
      /^- finding: / { finding = substr($0, 12) }
      /^- outcome: / { outcome = substr($0, 12) }
      /^- run: / { if (substr($0, 8) == cur && outcome != "no-change") print finding }
    ' "$RECORD")
    UNKNOWN=$(awk '
      /^## / { outcome = "change" }
      /^- finding: / { finding = substr($0, 12) }
      /^- outcome: / { outcome = substr($0, 12) }
      /^- run: unknown$/ { if (outcome != "no-change") print finding }
    ' "$RECORD")
    NO_CHANGE=$(awk '
      /^## / { outcome = "change" }
      /^- finding: / { finding = substr($0, 12) }
      /^- outcome: no-change$/ { print finding }
    ' "$RECORD")
    if [ -n "$NO_CHANGE" ]; then
      printf 'rerun-check: these decisions changed nothing on the branch, so no fresh run is owed for them: %s\n' \
        "$(printf '%s' "$NO_CHANGE" | tr '\n' ' ')"
    fi
    if [ -n "$STALE" ]; then
      echo "rerun-check: REFUSED - these decisions were recorded during run $CURRENT, which is still the most recent run:" >&2
      printf '%s\n' "$STALE" >&2
      echo "Nothing has yet scored the branch against the amended intent, and nothing has re-reviewed what the later auto-fix steps changed." >&2
      echo "Start a fresh run with the pinned-intent command, then run this check again." >&2
      exit 1
    fi
    if [ -n "$UNKNOWN" ]; then
      echo "rerun-check: WARNING - these decisions were recorded with no readable run id, so their re-run could not be confirmed:" >&2
      printf '%s\n' "$UNKNOWN" >&2
    fi
    COUNT=$(grep -c '^- finding: ' "$RECORD" || true)
    printf 'rerun-check: all %s recorded gate decisions predate run %s, the most recent run, or changed nothing\n' "$COUNT" "$CURRENT"
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
      echo "check: these gate decisions carry no by-hand verification (this is a diagnostic, not a gate; rerun-check is the gate):" >&2
      printf '%s\n' "$UNRESOLVED" >&2
      exit 1
    fi
    COUNT=$(grep -c '^- state: satisfied$' "$RECORD" || true)
    printf 'check: all %s recorded gate decisions carry a by-hand verification\n' "$COUNT"
    ;;

  *)
    echo "error: unknown action: $ACTION" >&2
    usage >&2
    exit 2
    ;;
esac
