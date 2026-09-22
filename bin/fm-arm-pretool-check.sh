#!/usr/bin/env bash
# Stable PreToolUse transport for the watcher-arm command policy.
#
# A firstmate primary must arm the watcher or run a Codex checkpoint as a
# standalone verified harness call.
# bin/fm-arm-command-policy.mjs is the sole owner of shell classification,
# protected execution identity, the blessed setup tree, and deny reason codes.
# This wrapper only acquires the harness payload, discovers the active roots,
# invokes that policy, and renders the established harness-specific responses.
# It never executes, sources, evaluates, or expands the submitted command.
# See docs/arm-pretool-check.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-arm-pretool-check.sh
#   bin/fm-arm-pretool-check.sh --command '<cmd>' [--background true|false]
#                              [--tool <name>] [--claude]
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex, and the tool name from .tool_name or .toolName.
# CLI mode is used by OpenCode and Pi after their adapters extract the exact
# command string; --tool carries the tool name when the adapter knows it.
# --background remains accepted for compatibility, but harness-native tracked
# background execution is not itself a policy signal.
#
# --claude is the one signal that this harness has the Monitor tool, so it alone
# turns on the steer-under-bash rule: bin/fm-send.sh and bin/fm-ack.sh are denied
# in an executed position, because a Monitor-issued one stays alive as a waiting
# arm and a Bash-issued one cannot. Only the Claude registration passes it.
# The rule is further scoped to a tool name that is empty or Bash, so a future
# wildcard registration cannot deny the Monitor it recommends. Claude Code's
# tracked registration uses the Bash matcher, which a Monitor call does not
# match at all; docs/arm-pretool-check.md records that evidence.
#
# Exit/output contract:
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

# --- latency telemetry, before anything else and after nothing -------------
#
# This hook is the one harness-portable place that sees EVERY command before it
# runs, in every verified primary harness, which is what makes it the only
# portable way to observe model thinking time: the gap between two hook events
# holds no command execution. bin/fm-latency-lib.sh owns what is recorded and
# docs/configuration.md's "Self-latency ledger" section the reading.
#
# IT CANNOT CHANGE WHAT THIS HOOK DENIES. It runs before argument parsing so it
# also covers the fast-allow paths below, it reads no stdin - the payload this
# hook consumes later must arrive untouched - it writes only an append to a
# private ledger, every failure inside it is a silent no-op, and it never
# exits. The block is a statement of fact about the call, not a decision about
# it.
#
# Scoped, because this file is tracked and is therefore checked out into every
# worktree of this repo, including crewmate and scout task worktrees whose tool
# calls belong to no home's ledger. The scope test is one stat and no fork, for
# a hook on the pre-command path of every single tool call.
_fm_arm_lat_dir=${BASH_SOURCE[0]%/*}
if [ -r "$_fm_arm_lat_dir/fm-latency-lib.sh" ]; then
  # shellcheck source=bin/fm-latency-lib.sh
  # shellcheck disable=SC1091 # tests/fm-arm-pretool-check.test.sh runs plain
  # `shellcheck` on this file, without -x, so the sibling cannot be followed.
  . "$_fm_arm_lat_dir/fm-latency-lib.sh" 2>/dev/null || true
  if command -v fm_latency_scope_ok >/dev/null 2>&1 \
    && fm_latency_scope_ok "${_fm_arm_lat_dir%/*}"; then
    # The hook matcher is Bash in every tracked harness config, so the tool is
    # known without reading the payload this hook must leave on stdin.
    fm_latency_tool_event bash || true
  fi
fi

CMD=""
CMD_SET=0
BACKGROUND=""
TOOL=""
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false]
                               [--tool <name>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command), and the tool name from
tool_name or toolName.
--claude additionally denies bin/fm-send.sh and bin/fm-ack.sh in an executed
position, for a tool name that is empty or Bash.
Exits 0 to allow and 2 to deny.
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
    --background)
      [ "$#" -gt 1 ] || { echo "error: --background requires a value" >&2; exit 2; }
      BACKGROUND=$2
      shift 2
      ;;
    --background=*)
      BACKGROUND=${1#--background=}
      shift
      ;;
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
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
  [ -n "$CMD" ] || exit 0
  # Kept for transport parity only.
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || TOOL=""
fi

# The steer-under-bash rule applies only where the Monitor replacement exists.
STEER=0
if [ "$CLAUDE_MODE" -eq 1 ]; then
  case "$TOOL" in
    ""|Bash) STEER=1 ;;
  esac
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification semantics).
# Every protected watcher execution and every broad watcher kill resolves to the
# fm-watch byte sequence AFTER the classifier's byte normalization, so a command
# that cannot contain fm-watch even after that normalization can never be a
# deniable watcher command and is fast-allowed without the Node policy owner.
# We mirror the classifier's cheapest byte transforms here (drop line-
# continuation and escape backslashes, quotes, and newlines) so obfuscated
# protected paths such as fm-watc\<newline>h-arm.sh or fm-"watch"-arm.sh still
# delegate. Stripping only these non-alphanumeric bytes can never destroy an
# existing fm-watch run.
#
# The fast path may allow ONLY when BOTH hold: (a) the stripped/normalized text
# lacks the fm-watch watcher substring, AND (b) the raw command carries no
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"..."), both of which the classifier
# decodes and can therefore reconstruct fm-watch from bytes this cheap byte
# strip cannot. This marker set is COUPLED to the classifier's decoder set in
# bin/fm-arm-command-policy.mjs: adding any new quote/expansion form the
# classifier decodes REQUIRES extending this marker set in the same change, or
# the prefilter stops being a strict superset. Otherwise the command always
# delegates to the classifier - the single owner of every decision. Any deeper
# decode-required obfuscation stays the classifier's and the post-arm liveness
# guards' responsibility.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
DELEGATE=0
case "$PREFILTER" in
  *fm-watch*) DELEGATE=1 ;;
esac
# The steer scripts join the prefilter's substring set only while the rule that
# can deny them is on, so an unsteered call keeps today's fast path exactly.
if [ "$STEER" -eq 1 ]; then
  case "$PREFILTER" in
    *fm-send*|*fm-ack*) DELEGATE=1 ;;
  esac
fi
case "$CMD" in
  *"\$'"*|*'$"'*) DELEGATE=1 ;;
esac
[ "$DELEGATE" -eq 1 ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
ACTIVE_HOME=${FM_HOME:-$ROOT}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_ARGS=(--command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME")
[ "$STEER" -eq 1 ] && POLICY_ARGS+=(--steer)
POLICY_OUTPUT=$(node "$POLICY" "${POLICY_ARGS[@]}" 2>/dev/null) || exit 0
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
