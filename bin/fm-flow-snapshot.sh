#!/usr/bin/env bash
# fm-flow-snapshot.sh - read-only per-agent no-mistakes pipeline snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-flow-snapshot.v1`. docs/flow-tui.md owns that wire format, the run
# resolution reasoning, and the verification evidence; this header owns the
# flags, environment knobs, and exit codes.
#
# The command is read-only. It does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, write reports, or open the no-mistakes
# database for anything but reading. Every write path is absent rather than
# guarded.
#
# It layers over bin/fm-fleet-snapshot.sh, which stays the single owner of
# fleet state, and adds two things that view does not carry: the named pipeline
# step each agent is on, and its GitHub check rollup.
#
# An agent in this document is a task with a LIVE worker behind it. A
# `state/<id>.meta` outlives the window it names - firstmate stands finished
# workers down by killing the window, and the record is what recovery reads
# afterwards - so enumerating the records alone put finished workers on screen
# beside running ones with nothing to tell them apart. Every task is therefore
# checked against its recorded endpoint, through the same
# `fm_backend_target_exists` the rest of the fleet resolves liveness with, and
# one that no longer resolves moves to `omitted` instead of `agents`: named,
# counted, and not drawn. --include-dead puts them back for diagnosis.
#
# Cleaning up the leftover records is a SEPARATE question, and not this
# command's: the record is durable state other tools depend on, and this one is
# read-only by contract.
#
# Usage:
#   fm-flow-snapshot.sh [--json] [--no-ci] [--task <id>] [--include-dead]
#
#   --json        emit the snapshot (default; accepted explicitly for symmetry
#                 with bin/fm-fleet-snapshot.sh)
#   --no-ci       skip every GitHub read, so the whole snapshot is local. The
#                 fast collector cadence uses this; only the slow cadence pays
#                 for the network.
#   --task <id>   restrict the snapshot to one task, for a targeted refresh
#                 rather than a whole-fleet sweep.
#   --include-dead  keep tasks whose recorded endpoint no longer resolves. They
#                 arrive as ordinary agents carrying endpoint_alive:false, which
#                 the renderer marks "worker gone". For looking at a record
#                 after its worker is gone, never for the live view.
#
# Environment knobs:
#   FM_FLOW_SNAPSHOT_NM_TIMEOUT   seconds bounding one `no-mistakes axi status`
#                                 (default 10, matching fm-nm-flow.sh's budget)
#   FM_FLOW_SNAPSHOT_GH_TIMEOUT   seconds bounding one `gh pr view` (default 20)
#   FM_FLOW_SNAPSHOT_DB           override the no-mistakes state database path
#                                 (default $HOME/.no-mistakes/state.sqlite).
#                                 Tests point this at a fixture database.
#   FM_FLOW_SNAPSHOT_FLEET_JSON   consume this file instead of running
#                                 bin/fm-fleet-snapshot.sh. Tests use it to feed
#                                 a recorded fleet document.
#
# Exit codes: 0 snapshot emitted, 1 a dependency or the fleet read failed,
# 2 usage error. A per-agent collection failure is NOT an error: it is reported
# in that agent's `collection` object and the snapshot still succeeds, because
# one wedged worker must not blank the whole view.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

NM_TIMEOUT=${FM_FLOW_SNAPSHOT_NM_TIMEOUT:-10}
GH_TIMEOUT=${FM_FLOW_SNAPSHOT_GH_TIMEOUT:-20}
NM_DB=${FM_FLOW_SNAPSHOT_DB:-$HOME/.no-mistakes/state.sqlite}

WANT_CI=1
ONLY_TASK=
INCLUDE_DEAD=0

usage() {
  sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) ;;
    --no-ci) WANT_CI=0 ;;
    --include-dead) INCLUDE_DEAD=1 ;;
    --task)
      shift
      [ $# -gt 0 ] || { echo "fm-flow-snapshot: --task needs an id" >&2; exit 2; }
      ONLY_TASK=$1
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-flow-snapshot: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

NOW_EPOCH=${FM_FLOW_SNAPSHOT_NOW_EPOCH:-$(date -u +%s)}
NOW_ISO=${FM_FLOW_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

# Bound one external read. `timeout` is not on stock macOS, so its absence
# degrades to an unbounded call rather than to a failed snapshot: losing the
# bound is worse than losing the data, but losing both is worst.
run_bounded() {  # <seconds> <command...>
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# The run index, and the ONLY read of the no-mistakes database. Three columns,
# keyed on the primary checkout path and the task's own fm/<id> branch.
#
# Every fact that reaches the screen is read afterwards through
# `no-mistakes axi status --run <id>`, the tool's documented CLI. step_results
# is deliberately never touched: it is a private undocumented schema and the
# installed binary trails the current release by several minor versions, so
# the run index is kept as the smallest surface that solves the problem.
#
# The worker cannot forge this row. That is the whole point of reading it here
# instead of having each crewmate report its own run id, which would be the
# checked entity producing the thing being checked.
run_index() {  # <project-path> <branch> -> "<id>|<status>|<updated_at>" or empty
  [ -f "$NM_DB" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 "file:$NM_DB?mode=ro" \
    "SELECT r.id, r.status, r.updated_at
       FROM runs r JOIN repos p ON p.id = r.repo_id
      WHERE p.working_path = '$(printf '%s' "$1" | sed "s/'/''/g")'
        AND r.branch = '$(printf '%s' "$2" | sed "s/'/''/g")'
      ORDER BY r.created_at DESC LIMIT 1;" 2>/dev/null | head -1
}

# no-mistakes axi status emits TOON on stdout; the version-update banner goes to
# stderr, so stdout needs no pre-filtering. The steps block is a header line
# naming the columns followed by one comma-separated row per step.
steps_json() {  # <axi-status-output>
  printf '%s\n' "$1" | awk '
    /^  steps\[[0-9]+\]\{/ { in_steps = 1; next }
    in_steps {
      if ($0 !~ /^    [a-z]/) { in_steps = 0; next }
      line = $0
      sub(/^    /, "", line)
      n = split(line, f, ",")
      if (n < 4) next
      printf "%s{\"step\":\"%s\",\"status\":\"%s\",\"findings\":%d,\"duration_ms\":%d}",
        (emitted++ ? "," : ""), f[1], f[2], f[3], f[4]
    }
    END { }
  ' | awk 'BEGIN { printf "[" } { printf "%s", $0 } END { printf "]\n" }'
}

active_steps_json() {  # <axi-status-output>
  printf '%s\n' "$1" | awk '
    /^  active_steps\[[0-9]+\]\{/ { in_a = 1; next }
    in_a {
      if ($0 !~ /^    [a-z]/) { in_a = 0; next }
      line = $0
      sub(/^    /, "", line)
      # Fields can be quoted and can themselves contain commas, so split on
      # commas that sit outside quotes rather than on every comma.
      n = 0; cur = ""; q = 0
      delete f
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { q = !q; continue }
        if (c == "," && !q) { f[++n] = cur; cur = ""; continue }
        cur = cur c
      }
      f[++n] = cur
      if (n < 6) next
      gsub(/\\/, "\\\\", f[4]); gsub(/"/, "\\\"", f[4])
      printf "%s{\"step\":\"%s\",\"status\":\"%s\",\"active_for\":\"%s\",\"last_activity\":\"%s\",\"agent_pid\":\"%s\",\"round\":\"%s\"}",
        (emitted++ ? "," : ""), f[1], f[2], f[3], f[4], f[5], f[6]
    }
  ' | awk 'BEGIN { printf "[" } { printf "%s", $0 } END { printf "]\n" }'
}

toon_field() {  # <axi-status-output> <key>
  printf '%s\n' "$1" | awk -v key="$2" '
    $0 ~ "^  " key ": " {
      sub("^  " key ": ", "")
      gsub(/^"|"$/, "")
      print
      exit
    }'
}

ci_json() {  # <pr-url>
  local url=$1 num raw
  num=$(printf '%s' "$url" | grep -Eo '[0-9]+$' || true)
  if [ -z "$num" ]; then
    jq -n '{collection:{ok:false,reason:"no pr number"},checks:[],total:0,passed:0,failed:0,pending:0}'
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    jq -n '{collection:{ok:false,reason:"gh not found"},checks:[],total:0,passed:0,failed:0,pending:0}'
    return
  fi
  raw=$(run_bounded "$GH_TIMEOUT" gh pr view "$num" --json statusCheckRollup 2>/dev/null) || raw=
  if [ -z "$raw" ]; then
    jq -n '{collection:{ok:false,reason:"gh read failed or timed out"},checks:[],total:0,passed:0,failed:0,pending:0}'
    return
  fi
  # The counts here have ONE job: agree with what `gh pr checks <n>` prints for
  # the same PR, because that is what the captain compares them against. Two
  # things are needed for that, and the shipped version did neither.
  #
  # 1. Supersession. Checks are keyed on workflow PLUS name - names alone are
  #    not unique, "CI testing waiver" appears under both the CI and Require
  #    no-mistakes workflows on this repo - but the rollup also keeps EVERY
  #    attempt of that key, so a re-run leaves the old one in it. PR #40 held 13
  #    entries for 11 checks and was counted 11/13 with 2 failures where gh
  #    reports 10/11 and one. The latest attempt of a key wins; the rest are
  #    superseded and counted nowhere.
  # 2. Exclusive buckets. Passed, failed and pending must partition the checks.
  #    Reading `conclusion` without first checking `status` counted PR #33's
  #    re-running "Repo invariants" as both passed and pending, on the strength
  #    of a conclusion left over from its previous attempt - 8+3+1 buckets over
  #    11 checks. A check that has not COMPLETED has no verdict yet, whatever
  #    field is still lying around on it.
  #
  # A StatusContext (a commit status, not a check run) carries `state` and
  # `context` instead; gh counts those too, so they are normalised rather than
  # dropped into the pending bucket by virtue of having no `status` field.
  printf '%s' "$raw" | jq '
    def normalize:
      if (.__typename // "") == "StatusContext" then
        { workflow: "", name: (.context // ""), started: (.createdAt // ""),
          status: (if (.state // "") == "PENDING" or (.state // "") == "EXPECTED"
                   then "IN_PROGRESS" else "COMPLETED" end),
          conclusion: (if (.state // "") == "SUCCESS" then "SUCCESS" else (.state // "") end) }
      else
        { workflow: (.workflowName // ""), name: (.name // ""),
          started: (.startedAt // ""),
          status: (.status // ""), conclusion: (.conclusion // "") }
      end;
    (.statusCheckRollup // [])
    | map(normalize)
    | to_entries
    | map(.value + {seq: .key})
    | group_by([.workflow, .name])
    | map(max_by([.started, .seq]))
    | sort_by(.seq)
    | map(del(.seq))
    | map(. + {verdict:
        (if .status != "COMPLETED" then "pending"
         elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED"
         then "passed"
         else "failed" end)})
    | {
        collection: {ok: true, reason: ""},
        checks: .,
        total: length,
        passed: (map(select(.verdict == "passed")) | length),
        failed: (map(select(.verdict == "failed")) | length),
        pending: (map(select(.verdict == "pending")) | length)
      }'
}

agent_json() {  # <task-json>
  local task=$1 id kind mode project worktree window branch endpoint_alive agent_alive pr_url
  local idx run_id run_status run_updated axi rc steps actives ci

  id=$(printf '%s' "$task" | jq -r '.id')
  kind=$(printf '%s' "$task" | jq -r '.kind // ""')
  mode=$(printf '%s' "$task" | jq -r '.mode // ""')
  project=$(printf '%s' "$task" | jq -r '.project // ""')
  worktree=$(printf '%s' "$task" | jq -r '.paths.worktree.path // ""')
  window=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
  endpoint_alive=$(printf '%s' "$task" | jq -r 'if .endpoint.exists then "true" else "false" end')
  # `endpoint.exists` only says a pane is there. The deeper probe asks what is
  # RUNNING in it, which distinguishes a torn-down worker from a live one for
  # about 15ms. fm-fleet-snapshot.sh runs it for secondmates only, so it is
  # called directly here rather than widened there.
  #
  # It reports the pane's foreground command, so it cannot see a WEDGED agent:
  # a stuck claude is still claude. It upgrades "a pane exists" to "an agent
  # process exists" and nothing further, which is why the renderer treats
  # `unknown` as unknown rather than as alive.
  agent_alive=$(printf '%s' "$task" | jq -r '.endpoint.agent_alive // "not_checked"')
  if [ "$agent_alive" = "not_checked" ] && [ "$endpoint_alive" = true ] && [ -n "$window" ]; then
    local backend
    backend=$(printf '%s' "$task" | jq -r '.backend // "tmux"')
    agent_alive=$(fm_backend_agent_alive "$backend" "$window" 2>/dev/null || printf 'unknown')
  fi
  pr_url=$(printf '%s' "$task" | jq -r '.pr.url // ""')
  branch="fm/$id"

  steps='[]'
  actives='[]'
  run_id=''
  run_status=''
  run_updated=0
  local collect_ok=true collect_reason=''

  idx=$(run_index "$project" "$branch")
  if [ -z "$idx" ]; then
    collect_reason='no pipeline run for this branch'
  else
    run_id=${idx%%|*}
    local rest=${idx#*|}
    run_status=${rest%%|*}
    run_updated=${rest##*|}
    axi=$(run_bounded "$NM_TIMEOUT" no-mistakes axi status --run "$run_id" 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$axi" ]; then
      # A failed or timed-out read is reported as such. It must NOT fall back to
      # the last known state or to pending: pending reads as "not started yet",
      # which is a different claim from "we could not find out".
      collect_ok=false
      collect_reason="axi status failed (exit $rc)"
    else
      steps=$(steps_json "$axi")
      actives=$(active_steps_json "$axi")
      [ -n "$pr_url" ] || pr_url=$(toon_field "$axi" pr)
    fi
  fi

  ci='{"collection":{"ok":false,"reason":"skipped"},"checks":[],"total":0,"passed":0,"failed":0,"pending":0}'
  if [ "$WANT_CI" = 1 ] && [ -n "$pr_url" ]; then
    ci=$(ci_json "$pr_url")
  fi

  local pr_num
  pr_num=$(printf '%s' "$pr_url" | grep -Eo '[0-9]+$' || true)

  jq -n \
    --arg id "$id" \
    --arg branch "$branch" \
    --arg project "$project" \
    --arg worktree "$worktree" \
    --arg window "$window" \
    --arg kind "$kind" \
    --arg mode "$mode" \
    --arg pr_url "$pr_url" \
    --arg run_id "$run_id" \
    --arg run_status "$run_status" \
    --arg agent_alive "$agent_alive" \
    --arg collect_reason "$collect_reason" \
    --arg now_iso "$NOW_ISO" \
    --argjson now_epoch "$NOW_EPOCH" \
    --argjson run_updated "${run_updated:-0}" \
    --argjson endpoint_alive "$endpoint_alive" \
    --argjson collect_ok "$collect_ok" \
    --argjson pr_num "${pr_num:-null}" \
    --argjson steps "$steps" \
    --argjson actives "$actives" \
    --argjson ci "$ci" \
    '{
      id:$id, branch:$branch, project:$project, worktree:$worktree,
      window:$window, kind:$kind, mode:$mode,
      endpoint_alive:$endpoint_alive,
      agent_alive:$agent_alive,
      pr:{url:(if $pr_url == "" then null else $pr_url end), number:$pr_num},
      collection:{ok:$collect_ok, reason:$collect_reason, at:$now_iso, epoch:$now_epoch},
      run:{
        present:($run_id != ""),
        id:$run_id, status:$run_status,
        db_updated_epoch:$run_updated,
        db_age_seconds:(if $run_updated > 0 then ($now_epoch - $run_updated) else null end)
      },
      steps:$steps,
      active_steps:$actives,
      ci:$ci
    }'
}

if [ -n "${FM_FLOW_SNAPSHOT_FLEET_JSON:-}" ]; then
  FLEET=$(cat "$FM_FLOW_SNAPSHOT_FLEET_JSON") || {
    echo "fm-flow-snapshot: cannot read $FM_FLOW_SNAPSHOT_FLEET_JSON" >&2
    exit 1
  }
else
  FLEET=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null
  ) || FLEET=
fi

# The fleet read is the one hard dependency: without the agent list there is
# nothing to draw, and an empty document would read as an empty fleet, which is
# a different and much more dangerous claim than a failure.
if [ -z "$FLEET" ] || ! printf '%s' "$FLEET" | jq -e '.tasks' >/dev/null 2>&1; then
  echo "fm-flow-snapshot: fleet snapshot unavailable; refusing to emit an empty fleet" >&2
  exit 1
fi

SCOPED=$(printf '%s' "$FLEET" | jq -c --arg only "$ONLY_TASK" '
  [ .tasks[] | select($only == "" or .id == $only) ]')
SHIP=$(printf '%s' "$SCOPED" | jq -c '[ .[] | select(.kind == "ship") ]')

# A live worker this view does not draw. The view is the no-mistakes PIPELINE
# view and only a ship task has a pipeline, so a scout or a secondmate would be
# nine permanently empty boxes. Naming them is still owed: the captain reconciles
# this list against the windows in front of them, and a live worker that is
# simply absent from it with no explanation is the same failure as a dead one
# that is present.
OUT_OF_SCOPE=$(printf '%s' "$SCOPED" | jq -c '[
  .[]
  | select(.kind != "ship")
  | select(.endpoint.exists == true)
  | {id, kind, window:(.endpoint.target // null)}
]')

# `endpoint.exists` is bin/fm-fleet-snapshot.sh's own reading of
# fm_backend_target_exists, the fleet's single owner of "does this recorded
# endpoint still resolve". It is consumed here rather than re-derived, so the
# view can never disagree with the rest of firstmate about which workers are
# running. null means no endpoint was ever recorded, which is not a live worker
# either, and is a different reason worth naming.
if [ "$INCLUDE_DEAD" = 1 ]; then
  TASKS=$(printf '%s' "$SHIP" | jq -c '.[]')
  OMITTED='[]'
else
  TASKS=$(printf '%s' "$SHIP" | jq -c '.[] | select(.endpoint.exists == true)')
  OMITTED=$(printf '%s' "$SHIP" | jq -c '[
    .[]
    | select(.endpoint.exists != true)
    | {id, window:(.endpoint.target // null),
       reason:(if .endpoint.exists == false
               then "recorded window no longer exists"
               else "no endpoint recorded" end)}
  ]')
fi

AGENTS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-flow-agents.XXXXXX")
trap 'rm -f "$AGENTS_FILE"' EXIT INT TERM
printf '[' > "$AGENTS_FILE"
FIRST=1
while IFS= read -r task; do
  [ -n "$task" ] || continue
  [ "$FIRST" = 1 ] || printf ',' >> "$AGENTS_FILE"
  FIRST=0
  agent_json "$task" | jq -c '.' >> "$AGENTS_FILE"
done <<EOF
$TASKS
EOF
printf ']' >> "$AGENTS_FILE"

# The agents array is passed by FILE, never as an argv string. fm-fleet-snapshot.sh
# passes its whole document through a single --argjson argument, so it stops
# working entirely once the fleet outgrows ARG_MAX; this script must not inherit
# that ceiling.
jq -n \
  --arg generated "$NOW_ISO" \
  --argjson generated_epoch "$NOW_EPOCH" \
  --arg fm_home "$FM_HOME" \
  --argjson omitted "$OMITTED" \
  --argjson out_of_scope "$OUT_OF_SCOPE" \
  --slurpfile agents "$AGENTS_FILE" \
  '{
    schema:"fm-flow-snapshot.v1",
    generated:$generated,
    generated_epoch:$generated_epoch,
    fm_home:$fm_home,
    agents:($agents[0] // []),
    omitted:$omitted,
    out_of_scope:$out_of_scope
  }'
