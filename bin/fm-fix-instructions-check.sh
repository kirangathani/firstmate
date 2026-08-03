#!/usr/bin/env bash
# Stable PreToolUse transport for the no-mistakes fix-instructions gate.
#
# A crewmate that answers a no-mistakes gate with `--action fix` hands the work
# to no-mistakes' own gate agent, which sees the finding text and the diff and
# nothing else - not the crewmate's brief (it lives in the firstmate home, not
# the project repo) and, in this repo, not AGENTS.md (`.no-mistakes.yaml` sets
# disable_project_settings: true so a gate agent never adopts the fleet-captain
# identity). A fix round with no --instructions therefore drops one of only two
# channels that carry worker context into that agent. This seatbelt denies such a
# command before it runs.
#
# bin/fm-fix-instructions-policy.mjs is the sole owner of the block/allow
# decision; it reuses the shell classifier owned by
# bin/fm-arm-command-policy.mjs. This wrapper only acquires the harness payload,
# invokes that policy, and renders the established harness responses. It never
# executes, sources, evaluates, or expands the command.
# See docs/fix-instructions-gate.md for the complete contract.
#
# Unlike bin/fm-cd-pretool-check.sh this wrapper carries NO checkout scoping,
# because it is not registered in a primary session at all: bin/fm-spawn.sh wires
# it only into a crewmate's or scout's own task worktree, so its mere presence in
# a harness hook is the scope. The one harness whose hook is global rather than
# worktree-resident is grok, and that hook's own wrapper gates on the per-task
# workspace token before ever reaching this script.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-fix-instructions-check.sh
#   bin/fm-fix-instructions-check.sh --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. CLI mode is used by OpenCode and Pi after their adapters
# extract the exact command string.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-fix-instructions-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Exits 0 to allow and 2 to deny a `no-mistakes axi respond --action fix` that
carries no --instructions, or instructions below the substance floor owned by
bin/fm-fix-instructions-policy.mjs.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Strip syntax bytes that the classifier joins within a shell word
# before looking for the no-mistakes program name, so an ordinary quoted or
# escaped fragment cannot hide a deniable fix round from the policy owner. A
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"...") - delegates too, because the
# classifier decodes those and can reconstruct the name from bytes this
# substring test cannot see. This marker set is COUPLED to the classifier's
# decoder set in bin/fm-arm-command-policy.mjs: adding any new quote/expansion
# form the classifier decodes REQUIRES extending it here in the same change, or
# the prefilter stops being a strict superset.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *no-mistakes*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
POLICY="$SCRIPT_DIR/fm-fix-instructions-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
