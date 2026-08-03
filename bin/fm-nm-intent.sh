#!/usr/bin/env bash
# Print the canonical no-mistakes `--intent` string for a task.
#
# THIS SCRIPT IS THE ONE OWNER of that string. `no-mistakes axi run --intent` is
# required to start a run and is described by its own help as "what the user set
# out to accomplish (the goal behind the change, not a description of the diff)".
# Left to the worker it becomes a paraphrase written at run time, days of context
# after the goal was actually stated, and the pipeline's final review step then
# evaluates the diff against that paraphrase. Pinning it here means the run is
# always evaluated against the goal as written, never against a restatement.
#
# The source of truth is the `# Task` section of the task's own brief at
# data/<task-id>/brief.md - the exact text firstmate wrote when it dispatched the
# work. Nothing else is consulted; there is no second place to keep in sync.
#
# The WHOLE Task section is emitted, acceptance criteria and constraints
# included, not just its first paragraph. That is deliberate: no-mistakes' final
# review step scores the diff against the intent, so handing it the full stated
# criteria makes that review stricter, and any truncation rule would silently
# decide which of the captain's requirements stop being checked. Output is
# whitespace-normalized to a single line so it is safe to hand to a CLI flag.
#
# Usage:
#   fm-nm-intent.sh <task-id>
#
# Typical use, from inside a task worktree:
#   no-mistakes axi run --intent "$(<firstmate-root>/bin/fm-nm-intent.sh <task-id>)"
#
# Refuses loudly (exit 1, nothing on stdout) when the brief is missing, has no
# `# Task` section, or still carries the unreplaced {TASK} placeholder. A silent
# empty intent would be worse than a stop: no-mistakes would either reject the
# run or evaluate against nothing.
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
  -h|--help) usage; exit 0 ;;
  "") echo "error: usage: fm-nm-intent.sh <task-id>" >&2; exit 1 ;;
esac

ID=$1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BRIEF="$DATA/$ID/brief.md"

[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF; cannot derive the run intent" >&2; exit 1; }

# The brief scaffold (bin/fm-brief.sh) writes `# Task` as its own heading line and
# every later section as another `# ` heading, so the section is everything
# between them.
SECTION=$(awk '
  /^# Task$/ { inside = 1; next }
  inside && /^# / { exit }
  inside { print }
' "$BRIEF")

# Collapse all whitespace runs to single spaces and trim. A brief Task section is
# multi-line markdown; an intent is one CLI argument.
INTENT=$(printf '%s' "$SECTION" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')

[ -n "$INTENT" ] || { echo "error: $BRIEF has no '# Task' section content; cannot derive the run intent" >&2; exit 1; }
case "$INTENT" in
  *'{TASK}'*)
    echo "error: $BRIEF still carries the unreplaced {TASK} placeholder; the task was dispatched without a real task description" >&2
    exit 1
    ;;
esac

printf '%s\n' "$INTENT"
