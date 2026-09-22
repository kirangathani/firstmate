#!/usr/bin/env bash
# fm-write.sh - hand ONE document to a short-lived writer that has firstmate's
# context piped into it, and get the model's turn back immediately.
#
# THE CAPTAIN'S PREMISE (2026-09-16): "the only thing that differs you from a
# background agent that you quickly set up is your context and your learnings.
# As long as you pipe those into the background agent and set it up, that takes
# 2 seconds and then you background it and you're free to do something else."
# So this script is not a new kind of worker. It is the mechanical hand-off of
# context and learnings, plus a writer that dies the moment the document exists.
#
# WHAT IT COSTS, measured on this fleet 2026-09-17 (docs/background-writers.md
# owns the full table and the method):
#   - the model's own cost is ONE tool call to issue this command;
#   - assembling the context takes about 5 s, all of it after the model has let
#     go;
#   - the writer takes 25-65 s for a 6-10 KB document. That is SLOWER in
#     wall-clock than firstmate writing it inline (a resume record measured 13 s
#     of in-turn compose time, a handoff 53 s). The win is not the clock. It is
#     that those seconds are no longer the model's, so the fleet keeps being
#     supervised and the captain keeps being answered while the document writes.
#
# THE WRITER HAS NO TOOLS, on purpose. Every fact it is allowed to use is in the
# bundle this script assembles, so it cannot read a file, run a command, or look
# anything up, and therefore cannot quietly introduce a fact nobody checked.
# That is the note-taking discipline enforced by construction rather than by
# instruction. The cost is that a fact left out of the bundle is a fact the
# document cannot have, which is why --context exists and why the fleet facts
# below are piped in by default.
# MEASURED FAILURE MODE this guards (2026-09-17): given no tools and no warning
# that it had none, a writer announced a plan, attempted one tool call, and
# exited having produced 395 bytes instead of a document. The bundle therefore
# states plainly that there are no tools, and the output is checked against a
# floor before anything is written, so a run that fails that way reports
# `write-failed:` and leaves the target untouched rather than replacing a good
# document with a stub.
#
# RUN IT AS A MONITOR, not in the foreground and not with shell `&`. Under a
# Monitor its single result line arrives as a notification, which is the same
# no-extra-call delivery a waiting arm's wake uses (docs/supervision-protocols/
# claude.md item 8), and the harness's low-memory reaper does not take Monitors.
# The line is ALSO recorded through bin/fm-wake-pending.sh so it survives a
# Monitor expiry and is handed over at the next wake or session start.
#
# Usage:
#   fm-write.sh [--refill] --out <path> [options] < instruction
#
#   --out <path>       where the document goes. MUST be inside $FM_HOME/data:
#                      firstmate never writes into a project (AGENTS.md rule 1),
#                      and a path check is a cheaper guarantee than a promise.
#   --force            allow overwriting an existing document (refused by default)
#   --context <file>   pipe this file in too; repeatable. Use it for anything the
#                      writer must quote and the defaults do not carry.
#   --model <model>    writer model (default: the value of FM_WRITE_MODEL, else
#                      claude-sonnet-5). Measured 2026-09-17: on the same bundle
#                      Sonnet stated plainly which facts the bundle did not
#                      contain and what to run to get them, where a smaller model
#                      filled the same cells with "unknown" and some inference.
#                      For a document the next session will trust, that
#                      difference is the whole point.
#   --no-fleet         omit the fleet snapshot and the per-task worktree facts
#   --no-learnings     omit data/learnings.md
#   --no-captain       omit data/captain.md and data/captain-shared.md
#   --context-only     print the assembled bundle and exit, writing nothing.
#                      This is how you check what the writer will and will not
#                      be able to say, before spending a writer on it.
#   --timeout <secs>   give up on the writer after this long (default 300)
#   --refill           first argument only: after a SUCCESSFUL write, stay alive
#                      as one of the dormant-arm pool's waiting arms instead of
#                      exiting, so the ear refills as a side effect of work
#                      already paid for (bin/fm-arm-pool-lib.sh owns that
#                      decision). Only ever pass it when running this as a
#                      Monitor or background task: the process becomes the thing
#                      that waits. A failed write never reaches it.
#
# The instruction is read from stdin, because it is prose about what this
# particular document must cover and it is the one part of the bundle that only
# the live session knows. Everything else is collected.
#
# HARNESS. Only `claude` is verified as a writer. AGENTS.md section 4 forbids
# dispatching on an unverified adapter, and a writer is a dispatch, so any other
# harness is refused by name rather than attempted.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# A document that came back this short is not a document. The observed failure
# produced 395 bytes; the smallest real document this fleet has written is the
# 4014-byte resume record of 2026-09-16. 800 sits between them with room either
# side, and --min-bytes moves it for a deliberately terse one.
MIN_BYTES=${FM_WRITE_MIN_BYTES:-800}
MODEL=${FM_WRITE_MODEL:-claude-sonnet-5}
TIMEOUT=${FM_WRITE_TIMEOUT:-300}
OUT=
FORCE=0
WANT_FLEET=1
WANT_LEARNINGS=1
WANT_CAPTAIN=1
CONTEXT_ONLY=0
REFILL=0
# Guarded with the `${arr[@]+...}` idiom wherever it is expanded: an empty array
# is an unbound-variable error under `set -u` on stock macOS Bash 3.2.
CONTEXT_FILES=()

if [ "${1:-}" = "--refill" ]; then
  REFILL=1
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT=${2:-}; shift 2 || { echo "error: --out needs a path" >&2; exit 2; } ;;
    --force) FORCE=1; shift ;;
    --context)
      [ -n "${2:-}" ] || { echo "error: --context needs a file" >&2; exit 2; }
      CONTEXT_FILES+=("$2"); shift 2 ;;
    --model) MODEL=${2:-}; shift 2 || { echo "error: --model needs a value" >&2; exit 2; } ;;
    --min-bytes) MIN_BYTES=${2:-}; shift 2 || { echo "error: --min-bytes needs a value" >&2; exit 2; } ;;
    --timeout) TIMEOUT=${2:-}; shift 2 || { echo "error: --timeout needs a value" >&2; exit 2; } ;;
    --no-fleet) WANT_FLEET=0; shift ;;
    --no-learnings) WANT_LEARNINGS=0; shift ;;
    --no-captain) WANT_CAPTAIN=0; shift ;;
    --context-only) CONTEXT_ONLY=1; shift ;;
    --refill) echo "error: --refill is only accepted as the FIRST argument" >&2; exit 2 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ "$CONTEXT_ONLY" -eq 0 ] && [ -z "$OUT" ]; then
  echo "error: --out is required; usage: fm-write.sh [--refill] --out <path> [options] < instruction" >&2
  exit 2
fi

# The project-write boundary, enforced rather than promised. Resolved through
# the PARENT directory so a document that does not exist yet still resolves, and
# compared against the resolved $FM_HOME/data so a symlink or a `..` cannot walk
# out of it.
if [ -n "$OUT" ]; then
  out_dir=$(dirname -- "$OUT")
  if ! out_dir_real=$(cd "$out_dir" 2>/dev/null && pwd -P); then
    echo "error: --out directory '$out_dir' does not exist" >&2
    exit 2
  fi
  if ! data_real=$(cd "$DATA" 2>/dev/null && pwd -P); then
    echo "error: this home has no data directory at $DATA" >&2
    exit 2
  fi
  case "$out_dir_real/" in
    "$data_real/"*) : ;;
    *) echo "error: --out must be inside $data_real; firstmate writes documents into its own home, never into a project" >&2
       exit 2 ;;
  esac
  OUT="$out_dir_real/$(basename -- "$OUT")"
  if [ -e "$OUT" ] && [ "$FORCE" -eq 0 ]; then
    echo "error: $OUT already exists; pass --force to replace it" >&2
    exit 2
  fi
fi

INSTRUCTION=$(cat)
if [ -z "${INSTRUCTION//[[:space:]]/}" ]; then
  echo "error: no instruction on stdin; the writer is told what to cover, never left to guess" >&2
  exit 2
fi

# ---------------------------------------------------------------- the bundle
section() {
  # $1 tag, $2 file. A missing or unreadable file is announced inside its own
  # tag rather than skipped: the writer must be able to tell "there were no
  # learnings" from "the learnings were never offered".
  printf '<%s>\n' "$1"
  if [ -r "$2" ]; then
    cat -- "$2"
  else
    printf '(absent: %s)\n' "$2"
  fi
  printf '\n</%s>\n\n' "$1"
}

bundle() {
  if [ "$WANT_CAPTAIN" -eq 1 ]; then
    section captain-preferences "$DATA/captain.md"
    [ -r "$DATA/captain-shared.md" ] && section captain-shared-preferences "$DATA/captain-shared.md"
  fi
  [ "$WANT_LEARNINGS" -eq 1 ] && section learnings "$DATA/learnings.md"
  if [ "$WANT_FLEET" -eq 1 ]; then
    printf '<fleet-state>\n'
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-bearings-snapshot.sh" 2>/dev/null \
      || printf '(the fleet snapshot could not be produced)\n'
    printf '\n</fleet-state>\n\n<worktree-facts>\n'
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-worktree-facts.sh" 2>/dev/null \
      || printf '(the worktree facts could not be measured)\n'
    printf '\n</worktree-facts>\n\n'
  fi
  local f
  for f in ${CONTEXT_FILES[@]+"${CONTEXT_FILES[@]}"}; do
    section "context-$(basename -- "$f")" "$f"
  done
  printf '<instruction>\n%s\n</instruction>\n\n' "$INSTRUCTION"
  cat <<'RULES'
<how-to-write-this>
You are writing ONE markdown document. Print the document and nothing else: no
preamble, no commentary, no sign-off, and no code fence around the whole thing.
Whatever you print IS the file.

You have NO TOOLS. You cannot read a file, run a command, or look anything up.
Everything you are allowed to use is in this message. Do not announce a plan and
do not attempt a tool call: your only output is the document.

Record only what is directly evidenced in the material above. Tag a statement
[F] when the material shows it and [O] when it is open or unverified, wherever
the distinction could mislead a reader. Never let an open question harden into
an asserted fact. Your own inferences are not facts: if you draw one, say that
you are drawing it.

If the document is supposed to state a fact that the material does not contain,
SAY SO in the place that fact belongs, and say what would establish it. A gap
named is useful; a gap filled with a plausible guess is the failure this whole
document exists to prevent, because the next session will trust what you wrote.

One sentence per line. Plain dash, never an em dash. No emoji.
</how-to-write-this>
RULES
}

if [ "$CONTEXT_ONLY" -eq 1 ]; then
  bundle
  exit 0
fi

# ---------------------------------------------------------------- the writer
case "${FM_WRITE_HARNESS:-claude}" in
  claude) ;;
  *) echo "error: '${FM_WRITE_HARNESS:-}' is not a verified writer harness; only claude is (AGENTS.md section 4)" >&2
     exit 2 ;;
esac
command -v claude >/dev/null 2>&1 || { echo "error: claude is not on PATH, so there is no writer to run" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-write.XXXXXX") || exit 1
cleanup() { command rm -rf -- "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

started=$(date +%s)
bundle > "$TMP/bundle" || { echo "write-failed: the context bundle could not be assembled"; exit 1; }

# --strict-mcp-config with an empty server set and --setting-sources= are not
# tidiness: measured 2026-09-17, they cut the writer's start-up from 6-10 s to
# 1.4-3.4 s, because loading this machine's MCP servers and settings was most of
# it. --tools "" removes every built-in tool. A 300 KB bundle costs no more to
# prefill than an empty one (6 s either way, same measurement), which is what
# makes piping the whole of captain.md and learnings.md in affordable.
set +e
timeout "$TIMEOUT" claude -p \
  --model "$MODEL" \
  --tools "" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --setting-sources= \
  --output-format text \
  < "$TMP/bundle" > "$TMP/doc" 2> "$TMP/err"
rc=$?
set -e
elapsed=$(( $(date +%s) - started ))

report() {
  # One line, because under a Monitor one line is one notification. It is also
  # recorded so a Monitor that expires before delivering it does not take it.
  printf '%s\n' "$1"
  printf '%s\n' "$1" | FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-wake-pending.sh" --result 2>/dev/null || true
}

if [ "$rc" -eq 124 ]; then
  report "write-failed: the writer for $(basename -- "$OUT") was still going after ${TIMEOUT}s and was stopped; nothing was written"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  report "write-failed: the writer for $(basename -- "$OUT") exited $rc after ${elapsed}s: $(head -c 200 "$TMP/err" | tr '\n' ' '); nothing was written"
  exit 1
fi

bytes=$(wc -c < "$TMP/doc" | tr -d '[:space:]')
if [ "${bytes:-0}" -lt "$MIN_BYTES" ]; then
  report "write-failed: the writer returned only ${bytes} bytes for $(basename -- "$OUT"), under the ${MIN_BYTES}-byte floor, so it is a stub and not a document; nothing was written"
  exit 1
fi

# Written through a temporary file in the SAME directory and moved into place,
# so a reader never sees a half-written document and a failed write never leaves
# one. data/ holds the records the next session trusts.
cp -- "$TMP/doc" "$OUT.fm-write.$$" || { report "write-failed: could not stage $OUT"; exit 1; }
mv -f -- "$OUT.fm-write.$$" "$OUT" || { report "write-failed: could not move the document into $OUT"; exit 1; }

report "wrote: $OUT (${bytes} bytes, ${elapsed}s, ${MODEL})"

# Everything this write owes is now done: the document is in place and the
# result line is both printed and recorded. So if the caller asked, spend what
# is left of this already paid-for process on being an ear.
if [ "$REFILL" -eq 1 ]; then
  trap - EXIT
  cleanup
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-arm-pool-lib.sh
  . "$SCRIPT_DIR/fm-arm-pool-lib.sh"
  fm_arm_pool_refill_opted_out || fm_arm_pool_refill_or_exit "$SCRIPT_DIR/fm-watch-arm.sh"
fi
