#!/usr/bin/env bash
# fm-nm-db-lib.sh - the fallback read of a no-mistakes run, straight from the
# daemon's own database, rendered as the TOON `no-mistakes axi status` prints.
#
# WHY. Measured 2026-09-07 against no-mistakes v1.37.0: `axi status --run
# 01M1YFPB01T3AR66BPT6Y6JSXM` exited 0 and printed an EMPTY stdout while the
# same command for two sibling runs printed their normal body. The run was
# healthy - ~/.no-mistakes/state.sqlite held its row and its nine step_results -
# so the database was the truth and the CLI's rendering was what failed. Exit 0
# with nothing on stdout is therefore its own outcome, neither a success nor the
# CLI failure the `exit $rc` reason describes, and it is the one this fallback
# answers.
#
# WHY TOON RATHER THAN A NEW SHAPE. bin/fm-flow-snapshot.sh and
# bin/fm-crew-state.sh each already parse that TOON, with parsers built for the
# real tool's bytes. Emitting the same bytes here keeps both of those parsers
# the single owner of their own reading and leaves this file owning one thing:
# where the facts came from. A second wire shape would have been a second parser
# in each caller, drifting from the first the moment either changed.
#
# READ-ONLY, ALWAYS, AND NEVER A COPY. Every connection is opened
# `file:<path>?mode=ro`, which is what makes a concurrent daemon write safe to
# read past and what makes it impossible for a viewer to damage a live run's
# record. Copying the file first and reading the copy is WRONG: the daemon runs
# SQLite in WAL mode, so the committed tail of every recent write lives in the
# sibling -wal file and not in state.sqlite at all. Verified 2026-09-07 on run
# 01M1YFPB01T3AR66BPT6Y6JSXM: a copy of state.sqlite alone read review=fixing
# and test=pending while the live file read `mode=ro` read review=completed and
# test=awaiting_approval. A copy that must be taken has to carry state.sqlite,
# state.sqlite-wal and state.sqlite-shm together.
#
# THE SECONDS-VERSUS-MILLISECONDS TRAP, the same one bin/fm-timeline.sh's header
# names: every *_at column is epoch SECONDS and every *_ms column is genuinely
# milliseconds. Dividing a timestamp by 1000 yields a 1970 date and no error.
#
# WHAT IS NOT EMITTED. `outcome:` has no column behind it, so it is never
# written: a run's terminal state reaches the callers through `status:` alone,
# which maps to the same verdicts. Nothing here invents a fact the database does
# not state.
#
# Functions, all setting FM_NM_DB_REASON to why they returned nothing:
#   fm_nm_db_run_for_branch <db> <branch>   -> newest run id on that branch
#   fm_nm_db_toon <db> <run-id>             -> that run's TOON on stdout
#
# Environment:
#   FM_NM_DB_NOW   override the clock used for a running step's elapsed, for tests.

# Read by every caller after a failed read, which shellcheck cannot see from
# inside a sourced library.
# shellcheck disable=SC2034
FM_NM_DB_REASON=''

fm_nm_db_lit() {  # SQL string literal body, single quotes doubled
  printf '%s' "$1" | sed "s/'/''/g"
}

# Both entry points share this guard, so neither can report a missing database
# as an empty answer.
fm_nm_db_ready() {  # <db>
  FM_NM_DB_REASON=''
  if [ ! -f "$1" ]; then
    FM_NM_DB_REASON="no database at $1"
    return 1
  fi
  if ! command -v sqlite3 >/dev/null 2>&1; then
    FM_NM_DB_REASON='sqlite3 not installed'
    return 1
  fi
  return 0
}

fm_nm_db_run_for_branch() {  # <db> <branch> -> run id, or empty
  fm_nm_db_ready "$1" || return 1
  local id
  id=$(sqlite3 "file:$1?mode=ro" \
    "SELECT id FROM runs WHERE branch = '$(fm_nm_db_lit "$2")'
      ORDER BY created_at DESC LIMIT 1;" 2>/dev/null) || {
    FM_NM_DB_REASON='database unreadable'
    return 1
  }
  if [ -z "$id" ]; then
    FM_NM_DB_REASON="no run for $2"
    return 1
  fi
  printf '%s' "$id"
}

fm_nm_db_toon() {  # <db> <run-id> -> TOON on stdout
  fm_nm_db_ready "$1" || return 1
  local db=$1 lit now row steps actives
  lit=$(fm_nm_db_lit "$2")
  now=${FM_NM_DB_NOW:-$(date +%s)}

  row=$(sqlite3 -separator '|' "file:$db?mode=ro" \
    "SELECT id, branch, status, head_sha, COALESCE(pr_url,'')
       FROM runs WHERE id = '$lit';" 2>/dev/null) || row=
  if [ -z "$row" ]; then
    FM_NM_DB_REASON="no run row for $2"
    return 1
  fi

  # step_order is the pipeline's own ordering, so the rows reach the callers in
  # the order the tool prints them rather than in whatever order the table
  # happens to return. findings_json is a whole findings document; only its
  # count is on the wire, and a row without one counts zero rather than blank.
  steps=$(sqlite3 -separator ',' "file:$db?mode=ro" \
    "SELECT step_name, status,
            COALESCE(json_array_length(findings_json, '\$.findings'), 0),
            COALESCE(duration_ms, 0)
       FROM step_results WHERE run_id = '$lit' ORDER BY step_order;" 2>/dev/null) || steps=
  if [ -z "$steps" ]; then
    FM_NM_DB_REASON="no steps recorded for $2"
    return 1
  fi

  # A step in flight: started and not yet completed. Its elapsed is stated as
  # whole seconds ("1234s") because that is a shape the callers' own active_for
  # parsers already accept, and it is exact rather than a rounded "3h54m".
  # last_activity is free text that can carry commas and quotes, and the column
  # order here is a comma-separated row, so both are stripped at the source.
  actives=$(sqlite3 -separator ',' "file:$db?mode=ro" \
    "SELECT step_name, status, ($now - started_at) || 's',
            '\"' || replace(replace(COALESCE(last_activity,''),'\"',''), char(10), ' ') || '\"',
            '\"' || COALESCE(agent_pid,'') || '\"', '\"\"'
       FROM step_results
      WHERE run_id = '$lit' AND started_at IS NOT NULL AND completed_at IS NULL
      ORDER BY step_order;" 2>/dev/null) || actives=

  local id branch status head pr rest
  id=${row%%|*};      rest=${row#*|}
  branch=${rest%%|*}; rest=${rest#*|}
  status=${rest%%|*}; rest=${rest#*|}
  head=${rest%%|*}
  pr=${rest#*|}

  printf 'run:\n'
  printf '  id: "%s"\n' "$id"
  printf '  branch: %s\n' "$branch"
  printf '  status: %s\n' "$status"
  printf '  head: %s\n' "$head"
  [ -z "$pr" ] || printf '  pr: "%s"\n' "$pr"
  printf '  steps[%s]{step,status,findings,duration_ms}:\n' "$(printf '%s\n' "$steps" | wc -l | tr -d ' ')"
  printf '%s\n' "$steps" | sed 's/^/    /'
  if [ -n "$actives" ]; then
    printf '  active_steps[%s]{step,status,active_for,last_activity,agent_pid,round}:\n' \
      "$(printf '%s\n' "$actives" | wc -l | tr -d ' ')"
    printf '%s\n' "$actives" | sed 's/^/    /'
  fi
}
