#!/usr/bin/env bash
# The task timeline ledger: one durable line per finished ship task recording
# how long it took from dispatch to merged PR, and how long each stage in
# between took. It exists because every one of those timestamps is already
# machine-recorded somewhere - the no-mistakes state database, GitHub, and the
# task's own meta file - and teardown deletes the last of them minutes after the
# task ends, so nothing could be read back a month later.
#
#   fm-timeline.sh record <task-id>   append this task's row (idempotent)
#   fm-timeline.sh report [--last N]  print the ledger and the trend
#
# THE LEDGER. $FM_HOME/data/timeline.tsv, append-only, tab-separated, one line
# per task under a header row written when the file is created. Captain-private,
# gitignored with the rest of data/. Every column is a bare number or empty:
# empty means "not known", never a placeholder word, so a column stays numeric
# for whatever reads it later.
#
#   task_id project mode model effort           what the task was
#   spawned_at first_run_at pr_opened_at        epoch SECONDS
#     ci_green_at merged_at torn_down_at
#   build_s                                     dispatch -> pipeline took over
#   intent_s rebase_s review_s test_s           WALL seconds per pipeline step,
#     document_s lint_s push_s pr_s ci_s        summed over every run for the branch
#   parked_s                                    of that wall time, the part spent
#                                               waiting for an agent to respond
#   review_rounds runs pr_number                counts
#   note                                        free text: why a cell is empty
#
# WALL, ACTIVE AND PARKED. step_results.duration_ms is the ACTIVE time of a step;
# completed_at - started_at is its WALL time. The difference is the time that
# step sat parked at a gate waiting for its turn, and it is the largest single
# component of a ship task (data/perf-remainder-e2e-w8/report.md section 1.1).
# The per-step columns are wall, because that is what the captain waited; parked_s
# is the total of the differences, so machine+agent time is per-step minus its
# share of parked.
#
# THE SECONDS-VERSUS-MILLISECONDS TRAP. In that database every *_at column is
# epoch SECONDS and every *_ms column is genuinely milliseconds. Dividing a
# timestamp by 1000 yields a 1970 date and no error. Same report, same section.
#
# SOURCES, all read-only:
#   state/<id>.meta       project, mode, model, effort, pr=, and spawned_at=.
#                         bin/fm-spawned-at-lib.sh owns reading the spawn time.
#   the no-mistakes state database, opened `file:...?mode=ro` and never written,
#                         matched on the task's branch fm/<task-id>.
#   GitHub, through gh, for the PR's created/merged times and the completion of
#                         the last check run on its head commit.
#
# NOTHING HERE BLOCKS TEARDOWN. bin/fm-teardown.sh calls `record` before it
# removes anything, and a missing database, missing PR, absent gh, or unreadable
# source produces an empty cell and a note, never a refusal. `record` exits
# non-zero only for a usage error; teardown reports the failure on stderr and
# proceeds regardless.
#
# IDEMPOTENT. A task already in the ledger is left exactly as it was recorded and
# `record` reports it and succeeds, so a retried teardown cannot double-count a
# task or overwrite a row with a later, worse reading.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE   as every sibling script
#   FM_TIMELINE_LEDGER   override the ledger path (default $FM_HOME/data/timeline.tsv)
#   FM_TIMELINE_DB       override the no-mistakes state database
#                        (default $HOME/.no-mistakes/state.sqlite). Tests point
#                        this at a fixture database.
#   FM_TIMELINE_GH       override the `gh` command. Tests point this at a stub.
#   FM_TIMELINE_NOW      override the recorded torn_down_at, for tests.
# Exit: 0 recorded (or already present, or recorded with gaps), 2 usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="${FM_TIMELINE_LEDGER:-$DATA/timeline.tsv}"
NM_DB="${FM_TIMELINE_DB:-$HOME/.no-mistakes/state.sqlite}"
GH="${FM_TIMELINE_GH:-gh}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-spawned-at-lib.sh
. "$SCRIPT_DIR/fm-spawned-at-lib.sh"

# The step columns, in pipeline order. The ledger's own header is built from
# this list, so a step added here lands in both places at once.
STEPS="intent rebase review test document lint push pr ci"

HEADER=$(
  printf 'task_id\tproject\tmode\tmodel\teffort\tspawned_at\tfirst_run_at\tpr_opened_at\tci_green_at\tmerged_at\ttorn_down_at\tbuild_s'
  for step in $STEPS; do printf '\t%s_s' "$step"; done
  printf '\tparked_s\treview_rounds\truns\tpr_number\tnote\n'
)

usage() {
  cat >&2 <<'USAGE'
usage: fm-timeline.sh record <task-id>
       fm-timeline.sh report [--last N]
USAGE
  exit 2
}

NOTE=
note_add() {  # <sentence>: append a reason a cell is empty
  if [ -z "$NOTE" ]; then NOTE=$1; else NOTE="$NOTE; $1"; fi
}

# TSV cells are single-line and tab-free by construction; the note is the only
# free text, so it is the only cell that has to be flattened.
tsv_clean() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

sql_lit() {  # SQL string literal body, single quotes doubled
  printf '%s' "$1" | sed "s/'/''/g"
}

# step_wall <step> <rows>: the wall seconds the pipeline recorded for one step,
# or empty when that step never ran. <rows> is sqlite's "step|wall|active" output.
step_wall() {
  printf '%s\n' "$2" | awk -F'|' -v s="$1" '$1 == s { print $2; exit }'
}

# --- record -----------------------------------------------------------------

cmd_record() {
  local id=${1-}
  fm_task_id_path_safe "$id" || { echo "error: invalid task id" >&2; exit 2; }

  if [ -f "$LEDGER" ] && cut -f1 "$LEDGER" | grep -qxF "$id"; then
    echo "timeline: $id already recorded in $LEDGER; left unchanged"
    return 0
  fi

  local meta="$STATE/$id.meta"
  local project='' mode='' model='' effort='' pr_url=''
  if [ -f "$meta" ]; then
    project=$(basename "$(fm_meta_get "$meta" project)")
    mode=$(fm_meta_get "$meta" mode)
    model=$(fm_meta_get "$meta" model)
    effort=$(fm_meta_get "$meta" effort)
    pr_url=$(fm_meta_get "$meta" pr)
  else
    note_add "no task record at $meta"
  fi

  local spawned_at
  spawned_at=$(fm_spawned_at "$STATE" "$id")
  [ -n "$spawned_at" ] || note_add "spawn time unknown"

  # --- the pipeline's own records -------------------------------------------
  local branch="fm/$id" step
  local runs='' first_run_at='' parked_s='' review_rounds='' step_rows=''

  if [ ! -f "$NM_DB" ]; then
    note_add "no validation database at $NM_DB"
  elif ! command -v sqlite3 >/dev/null 2>&1; then
    note_add "sqlite3 not installed, validation timings unread"
  else
    local blit row
    blit=$(sql_lit "$branch")
    row=$(sqlite3 -separator '|' "file:$NM_DB?mode=ro" \
      "SELECT COUNT(*), COALESCE(MIN(created_at),'') FROM runs WHERE branch='$blit';" 2>/dev/null) || row=
    if [ -z "$row" ]; then
      note_add "validation database unreadable"
    elif [ "${row%%|*}" = 0 ]; then
      runs=0
      note_add "no validation run for $branch"
    else
      runs=${row%%|*}
      first_run_at=${row#*|}
      # MAX/MIN with two arguments are sqlite's scalar max/min. duration_ms is
      # milliseconds while every timestamp is seconds, so the /1000 belongs to
      # that column alone; active is clamped to wall so a step whose recorded
      # active time overruns its own span cannot make parked negative.
      step_rows=$(sqlite3 -separator '|' "file:$NM_DB?mode=ro" \
        "SELECT s.step_name,
                SUM(MAX(s.completed_at - s.started_at, 0)),
                SUM(MIN(s.duration_ms / 1000, MAX(s.completed_at - s.started_at, 0)))
           FROM step_results s JOIN runs r ON r.id = s.run_id
          WHERE r.branch = '$blit'
            AND s.started_at IS NOT NULL AND s.completed_at IS NOT NULL
          GROUP BY s.step_name;" 2>/dev/null) || step_rows=
      parked_s=$(printf '%s\n' "$step_rows" | awk -F'|' '
        NF >= 3 { wall += $2; active += $3 } END { if (NR) print wall - active }')
      review_rounds=$(sqlite3 "file:$NM_DB?mode=ro" \
        "SELECT COUNT(DISTINCT a.round)
           FROM agent_invocations a JOIN runs r ON r.id = a.run_id
          WHERE r.branch = '$blit' AND a.purpose = 'review-fix';" 2>/dev/null) || review_rounds=
    fi
  fi

  # The worker's own implementation phase: dispatch to the moment the pipeline
  # created the run for this branch. A start later than that run is not a start -
  # every record of the real one has been rewritten since - so the phase is
  # reported unknown rather than as a negative interval.
  local build_s=''
  if [ -n "$spawned_at" ] && [ -n "$first_run_at" ]; then
    if [ "$first_run_at" -ge "$spawned_at" ]; then
      build_s=$((first_run_at - spawned_at))
    else
      note_add "dispatch recorded after the first validation run"
    fi
  fi

  # --- GitHub ----------------------------------------------------------------
  local pr_number='' pr_opened_at='' merged_at='' ci_green_at=''
  if [ -z "$pr_url" ]; then
    note_add "no PR recorded for this task"
  elif ! fm_pr_url_parse "$pr_url"; then
    note_add "recorded PR link is not a GitHub PR URL"
  elif ! command -v "$GH" >/dev/null 2>&1; then
    note_add "gh not available, PR times unread"
  else
    pr_number=$FM_PR_NUMBER
    local head_sha='' view
    # fromdateiso8601 does the ISO-to-epoch conversion inside jq, which gh
    # already depends on, so this never needs `date -d` - a GNU-only spelling
    # that would silently fail on macOS.
    if view=$(fm_pr_bounded "$GH" pr view "$FM_PR_NUMBER" \
        --repo "$FM_PR_OWNER/$FM_PR_REPO" --json createdAt,mergedAt,headRefOid \
        --jq '[((.createdAt // "")|(fromdateiso8601? // "")),
               ((.mergedAt  // "")|(fromdateiso8601? // "")),
               (.headRefOid // "")] | @tsv' 2>/dev/null); then
      IFS=$'\t' read -r pr_opened_at merged_at head_sha <<EOF
$view
EOF
      [ -n "$merged_at" ] || note_add "PR not merged"
    else
      note_add "PR $pr_number could not be read from GitHub"
    fi
    if [ -n "$head_sha" ]; then
      ci_green_at=$(fm_pr_bounded "$GH" api \
        "repos/$FM_PR_OWNER/$FM_PR_REPO/commits/$head_sha/check-runs" \
        --jq '[.check_runs[] | .completed_at // empty | fromdateiso8601] | max // ""' \
        2>/dev/null) || ci_green_at=
      [ -n "$ci_green_at" ] || note_add "no finished check run on the PR head"
    fi
  fi

  local torn_down_at=${FM_TIMELINE_NOW:-$(date +%s)}

  mkdir -p "$(dirname "$LEDGER")"
  # $HEADER is built by a command substitution, which strips the trailing
  # newline, so the row separator is printed here rather than carried in it.
  [ -s "$LEDGER" ] || printf '%s\n' "$HEADER" > "$LEDGER"
  {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$id" "$project" "$mode" "$model" "$effort" \
      "$spawned_at" "$first_run_at" "$pr_opened_at" "$ci_green_at" "$merged_at" \
      "$torn_down_at" "$build_s"
    for step in $STEPS; do printf '\t%s' "$(step_wall "$step" "$step_rows")"; done
    printf '\t%s\t%s\t%s\t%s\t%s\n' \
      "$parked_s" "$review_rounds" "$runs" "$pr_number" "$(tsv_clean "$NOTE")"
  } >> "$LEDGER"

  echo "timeline: recorded $id in $LEDGER${NOTE:+ ($NOTE)}"
}

# --- report -----------------------------------------------------------------

cmd_report() {
  local last=20
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --last) shift; last=${1-}; case "$last" in ''|*[!0-9]*|0) usage ;; esac ;;
      *) usage ;;
    esac
    shift
  done
  if [ ! -s "$LEDGER" ]; then
    echo "timeline: no ledger yet at $LEDGER" >&2
    return 0
  fi
  # The header plus the last N data rows, aligned. A tab-separated empty cell is
  # invisible to `column -t`, which would shift every later column left, so
  # empties are drawn as a dash for display only - the file itself keeps them empty.
  {
    head -1 "$LEDGER"
    tail -n +2 "$LEDGER" | tail -n "$last"
  } | awk -F'\t' -v OFS='\t' '{ for (i = 1; i <= NF; i++) if ($i == "") $i = "-"; print }' \
    | column -t -s "$(printf '\t')"

  echo
  printf 'medians in hours, per project; "recent" is that project'"'"'s last %s rows and "before" the %s before them\n' "$last" "$last"
  awk -v last="$last" -v FS='\t' '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    # Rows are appended in completion order, so a project'"'"'s newest rows are
    # simply its last ones.
    { p = $(col["project"]); rows[p, ++n[p]] = $0; if (!(p in seen)) { seen[p] = 1; order[++np] = p } }

    function med(vals, count,   i, j, t) {
      if (count == 0) return ""
      for (i = 2; i <= count; i++)
        for (j = i; j > 1 && vals[j-1] > vals[j]; j--) { t = vals[j-1]; vals[j-1] = vals[j]; vals[j] = t }
      if (count % 2) return vals[(count+1)/2]
      return (vals[count/2] + vals[count/2+1]) / 2
    }

    # One window of a project'"'"'s rows, from index `lo` up to `hi` inclusive.
    function window(p, lo, hi, label,   i, f, k, vals, m, s) {
      printf "%s\t%s\t%d", p, label, hi - lo + 1
      k = 0
      for (i = lo; i <= hi; i++) {
        split(rows[p, i], f, FS)
        if (f[col["merged_at"]] != "" && f[col["spawned_at"]] != "")
          vals[++k] = f[col["merged_at"]] - f[col["spawned_at"]]
      }
      m = med(vals, k)
      printf "\t%s", (m == "" ? "-" : sprintf("%.2f", m / 3600))
      for (s = 1; s <= nstage; s++) {
        k = 0; delete vals
        for (i = lo; i <= hi; i++) {
          split(rows[p, i], f, FS)
          if (f[col[stage[s] "_s"]] != "") vals[++k] = f[col[stage[s] "_s"]] + 0
        }
        m = med(vals, k)
        printf "\t%s", (m == "" ? "-" : sprintf("%.2f", m / 3600))
      }
      printf "\n"
    }

    END {
      nstage = split("build intent rebase review test document lint push pr ci parked", stage, " ")
      printf "project\twindow\tn\tlaunch_to_merge_h"
      for (s = 1; s <= nstage; s++) printf "\t%s_h", stage[s]
      printf "\n"
      for (j = 1; j <= np; j++) {
        p = order[j]
        # Two windows of the same width, so one can be read against the other:
        # a single median says how long a ship task takes, never whether that is
        # getting better or worse.
        lo = n[p] - last + 1; if (lo < 1) lo = 1
        window(p, lo, n[p], "recent")
        if (lo > 1) {
          plo = lo - last; if (plo < 1) plo = 1
          window(p, plo, lo - 1, "before")
        }
      }
    }
  ' "$LEDGER" | column -t -s "$(printf '\t')"
}

[ "$#" -ge 1 ] || usage
case "$1" in
  record) shift; [ "$#" -eq 1 ] || usage; cmd_record "$1" ;;
  report) shift; cmd_report "$@" ;;
  *) usage ;;
esac
