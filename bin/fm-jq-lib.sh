#!/usr/bin/env bash
# fm-jq-lib.sh - hand large JSON payloads to jq through stdin instead of argv.
#
# `jq --argjson name "$BIG"` puts the entire payload in the argument vector.
# execve() caps that vector as a whole (ARG_MAX) and, on Linux, caps each
# individual argument as well (MAX_ARG_STRLEN, a fixed 128 KiB that no ulimit
# raises). Once an accumulated payload crosses either cap, the exec fails with
# E2BIG BEFORE jq starts: the shell prints "Argument list too long", jq writes
# nothing at all, and the caller is left holding empty stdout with exit 126.
# That is a size threshold rather than a race, so it fails permanently once
# crossed and gets worse as the fleet grows.
#
# Measured 2026-08-08 on WSL2 Linux 6.6.87.2, jq-1.7.1, getconf ARG_MAX
# 2097152: a single jq argument succeeded at 131000 bytes and failed at 131100,
# and `bin/fm-fleet-snapshot.sh --json` exited 126 with zero bytes of output at
# 19 state/*.meta files and a 68737-byte data/backlog.md.
#
#   fm_jq_object <name> <json> [<name> <json>]... -- <jq-arg>...
#
# Streams {"<name>":<json>,...} to jq on stdin and runs `jq <jq-arg>...` over
# it, passing jq's exit status through. Each <name> must be a plain identifier
# and each <json> exactly one JSON value. Bind them at the top of the filter,
# before any `def`, so the rest of the filter reads exactly as it did when the
# payloads arrived through --argjson:
#
#   fm_jq_object backlog "$BACKLOG_JSON" tasks "$TASKS_JSON" -- \
#     --arg generated "$SNAPSHOT_NOW" \
#     '. as $doc
#      | $doc.backlog as $backlog
#      | $doc.tasks as $tasks
#      | def by_id($id): ($tasks[]? | select(.id == $id)) // null;
#        {generated:$generated, backlog:$backlog, tasks:$tasks}'
#
# An empty or multi-value payload makes the envelope invalid JSON, so jq exits
# non-zero with a parse error instead of silently binding the wrong value to
# the wrong name.
#
# The dividing line for callers: anything that ACCUMULATES - a records array, a
# whole-file parse, a nested home summary - goes through the envelope, because
# its size tracks the fleet. Fixed-shape values whose size is bounded by one
# path or one scalar stay on argv with --arg/--argjson, where they are cheaper
# and read better at the call site.

fm_jq_object() {  # <name> <json>... -- <jq-arg>...
  local pairs=() args=() seen_sep=0 arg i=0 seen=' '

  for arg in "$@"; do
    if [ "$seen_sep" -eq 0 ] && [ "$arg" = -- ]; then
      seen_sep=1
      continue
    fi
    if [ "$seen_sep" -eq 0 ]; then
      pairs[${#pairs[@]}]=$arg
    else
      args[${#args[@]}]=$arg
    fi
  done

  if [ "$seen_sep" -eq 0 ] || [ ${#args[@]} -eq 0 ]; then
    echo "fm_jq_object: usage: fm_jq_object <name> <json>... -- <jq-arg>..." >&2
    return 2
  fi
  if [ $(( ${#pairs[@]} % 2 )) -ne 0 ]; then
    echo "fm_jq_object: payloads must be <name> <json> pairs" >&2
    return 2
  fi
  # A non-identifier name would need JSON escaping, and a repeated name would
  # produce a duplicate key that jq resolves silently by keeping the last one.
  # Both refuse here rather than reaching the filter as a wrong binding.
  while [ "$i" -lt ${#pairs[@]} ]; do
    case ${pairs[$i]} in
      [A-Za-z_]*)
        case ${pairs[$i]} in
          *[!A-Za-z0-9_]*)
            echo "fm_jq_object: payload name is not an identifier: ${pairs[$i]}" >&2
            return 2
            ;;
        esac
        ;;
      *)
        echo "fm_jq_object: payload name is not an identifier: ${pairs[$i]}" >&2
        return 2
        ;;
    esac
    case " $seen " in
      *" ${pairs[$i]} "*)
        echo "fm_jq_object: duplicate payload name: ${pairs[$i]}" >&2
        return 2
        ;;
    esac
    seen="$seen ${pairs[$i]} "
    i=$((i + 2))
  done

  {
    printf '{'
    i=0
    while [ "$i" -lt ${#pairs[@]} ]; do
      [ "$i" -eq 0 ] || printf ','
      printf '"%s":' "${pairs[$i]}"
      printf '%s' "${pairs[$((i + 1))]}"
      i=$((i + 2))
    done
    printf '}'
  } | jq "${args[@]}"
}
