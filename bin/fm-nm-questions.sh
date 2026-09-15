#!/usr/bin/env bash
# fm-nm-questions.sh - the reviewer's open questions for a task, read straight
# from the run's own review conversation, plus the one composer for the answer
# steer that sends one back.
#
# THE CHANNEL IT READS. no-mistakes' review step is a two-way channel as of fork
# commit 31b58c7 (kirangathani/no-mistakes PR 3, merged 2026-09-15), whose
# concept doc docs/src/content/docs/concepts/review-conversation.md owns the wire
# format this file parses. Two append-only ndjson files live in the run's
# evidence directory:
#
#   <evidence-root>/<run-id>/review/questions.ndjson   the reviewer appends
#   <evidence-root>/<run-id>/review/answers.ndjson     the operator appends
#
# The reviewer appends each larger question THE MOMENT it has one, with 2-4
# `options`, and keeps reviewing other areas. That is the whole reason this
# reads the file rather than `no-mistakes axi status`: axi can only show a
# question once the pass has ENDED and the run has parked, and the captain's
# ruling of 2026-09-15 is that he gets the question while the reviewer is still
# working, so an early answer can redirect the rest of the pass instead of
# arriving after the effort is spent.
#
# THE RESOLUTION RULES ARE THE FORK'S, NOT A SECOND SET.
# internal/reviewqa/reviewqa.go owns the protocol and this file mirrors its
# Load(): a later line with the same id supersedes the earlier one and revives a
# retraction; a `kind: "retract"` line closes a question; a retraction for an
# unknown id, an answer for an unknown id, a line with no id, a question with no
# text, and a malformed line are each skipped rather than failing the read; a
# `weight: "minor"` question is dropped, because routing by weight is the
# reviewer's own job. A question is OPEN when it is neither retracted nor
# answered.
#
# WHY THIS IS A FLEET SWEEP AND NOT A PER-TASK state/<id>.check.sh. The wake
# travels on the watcher's existing `check:` channel either way; what differs is
# where the poll lives. A per-task check has to live at state/<id>.check.sh, and
# that path has ONE slot which bin/fm-pr-check.sh already owns for the PR merge
# poll. Two owners of one path means whichever armed last silently disarms the
# other, and a task that re-enters the review step after its PR exists - a CI
# repair's RestartFrom: review - is exactly when both would want it. So
# `--surface` follows bin/fm-nm-stall.sh's shape instead: one repository-owned
# sweep the watcher runs on its own cadence, printing a line only when firstmate
# should wake and nothing otherwise. Same wake kind, same contract, no shared
# slot.
#
# THE ANSWER PATH NEVER TOUCHES THE RUN. AGENTS.md section 7 gives the task
# worker sole ownership of its own run, and bin/fm-nm-attach.sh's header owns
# why. So `answer` writes NOTHING to the conversation: it records the decision
# durably through bin/fm-nm-decision.sh - which is what carries it into the
# pinned intent the next cold reviewer is scored against - and composes the one
# line firstmate sends the worker, which runs `no-mistakes axi answer` itself
# from inside its own worktree and appends its own `resolved [key=<qid>]`.
#
# WHAT IT DOES NOT COVER, stated rather than hidden:
#   - The evidence root is resolved from NM_HOME and, when set there, from the
#     GLOBAL no-mistakes config's `test.evidence.local_root`. A PER-REPOSITORY
#     config that relocates it is NOT read, so on such a repository this reader
#     would find no conversation and report no questions. The path it looked at
#     is printed by `list`, so a wrong answer is visible rather than silent, and
#     FM_NM_QUESTIONS_EVIDENCE_ROOT overrides it outright.
#   - A run whose id cannot be resolved from the daemon's database (no sqlite3,
#     no database, no run yet on fm/<id>) has no conversation to read. `gate`
#     treats that as "no open questions", because there is no run that could
#     hold one; it refuses only when a conversation file EXISTS and cannot be
#     read, which is the one case where an open question could be invisible.
#   - `surface` skips a task whose conversation it cannot read rather than
#     alarming: a half-written trailing line is expected while the reviewer is
#     still appending, and an alarm on every sweep for it would be noise. The
#     merge gate above is what makes that safe - nothing ships past an
#     unreadable conversation even though nothing woke firstmate about it.
#
# Usage:
#   fm-nm-questions.sh list <task-id>     the open questions, one block each
#   fm-nm-questions.sh gate <task-id>     exit 0 none open, 1 open, 2 unreadable
#   fm-nm-questions.sh surface            sweep the fleet, print only NEW ones
#   fm-nm-questions.sh answer <task-id> --question <id> --answer <text>
#                                         [--by captain|firstmate] [--outcome change]
#
# Environment:
#   FM_NM_QUESTIONS_DB             no-mistakes state database
#                                  (default $HOME/.no-mistakes/state.sqlite)
#   FM_NM_QUESTIONS_EVIDENCE_ROOT  evidence root holding <run-id>/review/
#   FM_NM_QUESTIONS_NM_HOME        no-mistakes home (default $NM_HOME, else
#                                  $HOME/.no-mistakes)
#   FM_NM_DECISION_BIN             the decision recorder, for tests
#
# Exit: 0 fine, 1 the named condition, 2 usage or an unreadable conversation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-jq-lib.sh
. "$SCRIPT_DIR/fm-jq-lib.sh"
# shellcheck source=bin/fm-nm-db-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-nm-db-lib.sh"

NM_DB=${FM_NM_QUESTIONS_DB:-$HOME/.no-mistakes/state.sqlite}
NM_HOME_DIR=${FM_NM_QUESTIONS_NM_HOME:-${NM_HOME:-$HOME/.no-mistakes}}
DECISION_BIN=${FM_NM_DECISION_BIN:-$SCRIPT_DIR/fm-nm-decision.sh}
TAB=$'\t'
# The options separator inside one TSV field. A unit separator cannot occur in
# an option the reviewer wrote, so joining on it and splitting it back is
# lossless where a comma or a pipe would not be.
US=$'\037'
NL=$'\n'

usage() {
  cat >&2 <<'EOF'
usage: fm-nm-questions.sh list <task-id>
       fm-nm-questions.sh gate <task-id>
       fm-nm-questions.sh surface
       fm-nm-questions.sh answer <task-id> --question <id> --answer <text> [--by <who>] [--outcome change|no-change]
EOF
}

id_valid() {  # <task-id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    -*|*..*) return 1 ;;
  esac
  return 0
}

# --- where the conversation lives -------------------------------------------

# The evidence root, honouring an absolute test.evidence.local_root in the
# GLOBAL config exactly as internal/paths.EvidenceRoot does: a relative value is
# ignored there too, because the daemon's working directory is a bare gate repo
# and a relative path would land somewhere nobody named.
evidence_root() {
  local cfg line root='' in_test=0 in_ev=0
  if [ -n "${FM_NM_QUESTIONS_EVIDENCE_ROOT:-}" ]; then
    printf '%s' "$FM_NM_QUESTIONS_EVIDENCE_ROOT"
    return 0
  fi
  cfg="$NM_HOME_DIR/config.yaml"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '#'*) continue ;;
        'test:'*) in_test=1; in_ev=0; continue ;;
        [!' ']*) in_test=0; in_ev=0; continue ;;
      esac
      [ "$in_test" = 1 ] || continue
      case "$line" in
        '  evidence:'*) in_ev=1; continue ;;
        '  '[!' ']*) in_ev=0; continue ;;
      esac
      [ "$in_ev" = 1 ] || continue
      case "$line" in
        '    local_root:'*)
          root=${line#*:}
          root=${root#"${root%%[![:space:]]*}"}
          root=${root%"${root##*[![:space:]]}"}
          root=${root%\"}; root=${root#\"}
          ;;
      esac
    done < "$cfg"
  fi
  case "$root" in
    /*) printf '%s' "$root" ;;
    *)  printf '%s/evidence' "$NM_HOME_DIR" ;;
  esac
}

# The run whose conversation answers for this task: the newest run on the task's
# own ship branch fm/<id>, which is bin/fm-brief.sh's branch contract and the
# same key bin/fm-crew-state.sh attributes a run by. Empty when there is none.
run_for_task() {  # <task-id>
  fm_nm_db_run_for_branch "$NM_DB" "fm/$1" 2>/dev/null || true
}

conversation_dir() {  # <run-id>
  printf '%s/%s/review' "$(evidence_root)" "$1"
}

# --- reading the conversation -----------------------------------------------

# One ndjson file as a JSON array, malformed lines dropped exactly as the fork's
# readLines/Load pair drops them. `jq -n -R inputs` hands each line over as a
# raw string, so `fromjson?` can reject one bad line instead of the whole file.
ndjson_array() {  # <path>
  [ -f "$1" ] || { printf '[]'; return 0; }
  jq -n -R -c '[inputs | fromjson? // empty]' < "$1" 2>/dev/null
}

# Resolved entries for a conversation directory, as one JSON array in
# QUESTIONS_JSON. Return 2 when a file is present but could not be read at all -
# the one case where an open question could exist and be invisible.
QUESTIONS_JSON=
read_conversation() {  # <dir>
  local dir=$1 qs as
  QUESTIONS_JSON=
  command -v jq >/dev/null 2>&1 || return 2
  if [ -f "$dir/questions.ndjson" ] && [ ! -r "$dir/questions.ndjson" ]; then return 2; fi
  if [ -f "$dir/answers.ndjson" ] && [ ! -r "$dir/answers.ndjson" ]; then return 2; fi
  qs=$(ndjson_array "$dir/questions.ndjson") || return 2
  as=$(ndjson_array "$dir/answers.ndjson") || return 2
  [ -n "$qs" ] && [ -n "$as" ] || return 2
  # shellcheck disable=SC2016  # jq filter is literal: $doc and friends are jq bindings, not shell
  QUESTIONS_JSON=$(fm_jq_object questions "$qs" answers "$as" -- -c '
    def trim: tostring | sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"");
    . as $doc
    | ($doc.answers | map(select(((.id? // "") | trim | length) > 0))
                    | map(select((((.answer? // "") | trim) | length) > 0))
       | reduce .[] as $a ({}; .[($a.id | trim)] = $a)) as $ans
    | (reduce $doc.questions[] as $q ({order:[], by:{}};
        ($q.id? // "" | trim) as $id
        | if ($id | length) == 0 then .
          elif (($q.kind? // "question") | trim) == "retract" then
            (if (.by | has($id)) then .by[$id].retracted = true else . end)
          elif (($q.kind? // "question") | trim) != "question" then .
          elif ((($q.question? // "") | trim) | length) == 0 then .
          elif ((($q.weight? // "") | trim | ascii_downcase)) == "minor" then .
          elif (.by | has($id)) then (.by[$id] = {q:$q, retracted:false})
          else (.order += [$id] | .by[$id] = {q:$q, retracted:false})
          end)) as $s
    | [ $s.order[] as $id
        | $s.by[$id] as $e
        | { id: $id,
            question: ($e.q.question | trim | gsub("[\n\r\t]+"; " ")),
            options: (($e.q.options? // []) | map(trim | gsub("[\n\r\t]+"; " "))),
            file: (($e.q.file? // "") | tostring),
            line: (($e.q.line? // 0) | tonumber? // 0),
            area: (($e.q.area? // "") | tostring),
            retracted: $e.retracted,
            answer: (if ($ans | has($id)) then ($ans[$id].answer | trim | gsub("[\n\r\t]+"; " ")) else null end),
            by: (($ans[$id].answered_by? // "") | tostring) }
      ]') || return 2
  [ -n "$QUESTIONS_JSON" ] || return 2
  return 0
}

# One TAB-separated line per still-open question: id, text, options joined on
# the unit separator, file, line.
open_entries() {
  printf '%s' "$QUESTIONS_JSON" | jq -r '
    .[] | select(.retracted | not) | select(.answer == null)
    | [ .id, .question, (.options | join("")), .file, (.line | tostring) ]
    | @tsv' 2>/dev/null
}

# --- the composed answer steer ----------------------------------------------

# Single-quote a string for a shell command line, so the printed `send:` line is
# copy-runnable whatever apostrophes the chosen option contains.
shq() {  # <text>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# shellcheck disable=SC2016  # the backticks and quotes are literal steer text the worker reads, not expansions
steer_line() {  # <question-id> <answer> <who>
  printf 'review question %s is answered by the %s: run `no-mistakes axi answer --question %s --answer "%s" --by %s` from inside your worktree, then append `resolved [key=%s]: answered "%s"` to your status file' \
    "$1" "$3" "$1" "$2" "$3" "$1" "$2"
}

# --- subcommands ------------------------------------------------------------

cmd_list() {  # <task-id>
  local id=$1 run dir rc qid text opts file lineno o where
  run=$(run_for_task "$id")
  if [ -z "$run" ]; then
    printf 'no active run for %s, so its reviewer has asked nothing\n' "$id"
    return 0
  fi
  dir=$(conversation_dir "$run")
  printf 'run: %s\n' "$run"
  printf 'conversation: %s\n' "$dir"
  # The status is captured on the call itself: an `if !` resets $? to the
  # negation's own result, which would report an unreadable conversation as 0.
  rc=0
  read_conversation "$dir" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'unreadable: the review conversation at %s could not be read\n' "$dir" >&2
    return "$rc"
  fi
  while IFS=$TAB read -r qid text opts file lineno; do
    [ -n "$qid" ] || continue
    printf '\nquestion: %s\n' "$qid"
    printf 'text: %s\n' "$text"
    if [ -n "$opts" ]; then
      while IFS= read -r o; do
        [ -n "$o" ] || continue
        printf 'option: %s\n' "$o"
      done <<EOF
$(printf '%s' "$opts" | tr "$US" '\n')
EOF
    else
      printf 'note: this question carries no options, so it cannot be put as a multiple choice; ask it as written\n'
    fi
    if [ -n "$file" ]; then
      where=$file
      [ "${lineno:-0}" = 0 ] || where="$file:$lineno"
      printf 'where: %s\n' "$where"
    fi
    printf 'answer with: bin/fm-nm-questions.sh answer %s --question %s --answer "<the chosen option>" --by captain\n' "$id" "$qid"
  done <<EOF
$(open_entries)
EOF
  return 0
}

cmd_gate() {  # <task-id>
  local id=$1 run dir rc open
  run=$(run_for_task "$id")
  [ -n "$run" ] || return 0
  dir=$(conversation_dir "$run")
  rc=0
  read_conversation "$dir" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'the review conversation at %s could not be read, so whether a question is still open cannot be established\n' "$dir" >&2
    return "$rc"
  fi
  open=$(open_entries | cut -f1 | tr '\n' ' ')
  open=${open% }
  [ -n "$open" ] || return 0
  printf 'unanswered review question(s) on run %s: %s\n' "$run" "$open" >&2
  return 1
}

# Kinds that never drive a validation of their own, skipped for the reason
# bin/fm-nm-stall.sh skips them.
task_in_domain() {  # <meta-file>
  local line kind=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in kind=*) kind=${line#kind=} ;; esac
  done < "$1"
  case "$kind" in scout|secondmate) return 1 ;; esac
  return 0
}

surfaced_file() { printf '%s/%s.nm-questions' "$STATE" "$1"; }

cmd_surface() {
  local meta id run dir qid text opts file lineno marker seen any=0 nl
  nl=$'\n'
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    id_valid "$id" || continue
    task_in_domain "$meta" || continue
    run=$(run_for_task "$id")
    [ -n "$run" ] || continue
    dir=$(conversation_dir "$run")
    [ -d "$dir" ] || continue
    read_conversation "$dir" || continue
    marker=$(surfaced_file "$id")
    seen=$(cat "$marker" 2>/dev/null || true)
    [ -z "$seen" ] || seen="$seen$nl"
    while IFS=$TAB read -r qid text opts file lineno; do
      [ -n "$qid" ] || continue
      case "$nl$seen" in
        *"$nl$run$TAB$qid$nl"*) continue ;;
      esac
      printf '%s\t%s\n' "$run" "$qid" >> "$marker" 2>/dev/null || true
      seen="$seen$run$TAB$qid$nl"
      any=1
      printf 'NM QUESTION: %s is waiting on an answer to review question %s: %s' "$id" "$qid" "$text"
      [ -z "$opts" ] || printf ' (options: %s)' "$(printf '%s' "$opts" | tr "$US" '|' | sed 's/|/ | /g')"
      printf '\n'
    done <<EOF
$(open_entries)
EOF
  done
  # EVERY line starts with the same marker, for the reason bin/fm-nm-stall.sh's
  # footer gives: a relay that allowlists lines by marker must not be able to
  # strip the remedy off a finding.
  [ "$any" = 1 ] && printf 'NM QUESTION REMEDY: put each one to the captain as a multiple choice - bin/fm-nm-questions.sh list <task-id> prints the question and its own options - then send the answer with bin/fm-nm-questions.sh answer.\n'
  return 0
}

cmd_answer() {  # <task-id> --question <id> --answer <text> [--by <who>] [--outcome ...]
  local id=$1 qid='' ans='' who=captain outcome=no-change run dir found=0 qline steer
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --question) shift; [ "$#" -ge 1 ] || { usage; exit 2; }; qid=$1; shift ;;
      --answer)   shift; [ "$#" -ge 1 ] || { usage; exit 2; }; ans=$1; shift ;;
      --by)       shift; [ "$#" -ge 1 ] || { usage; exit 2; }; who=$1; shift ;;
      --outcome)  shift; [ "$#" -ge 1 ] || { usage; exit 2; }; outcome=$1; shift ;;
      *) usage; exit 2 ;;
    esac
  done
  [ -n "$qid" ] && [ -n "$ans" ] || { usage; exit 2; }
  case "$outcome" in change|no-change) ;; *) usage; exit 2 ;; esac
  case "$who" in
    captain|firstmate) ;;
    *) echo "error: --by must be captain or firstmate: an answer's authority is the captain's, or firstmate's only where the configured authority already lets it decide" >&2
       exit 2 ;;
  esac
  # The steer is one line the worker runs verbatim, so a newline would split it
  # and a double quote would end the composed --answer argument early. Both are
  # refused rather than mangled; a stated option is neither.
  case "$ans" in
    *'"'*) echo 'error: the answer contains a double quote, which would end the composed --answer argument early; answer with one of the stated options' >&2; exit 2 ;;
    *"$NL"*) echo 'error: the answer contains a newline; a steer is one line' >&2; exit 2 ;;
  esac

  run=$(run_for_task "$id")
  if [ -n "$run" ]; then
    dir=$(conversation_dir "$run")
    if read_conversation "$dir"; then
      while IFS=$TAB read -r qline _rest; do
        [ "$qline" = "$qid" ] && found=1
      done <<EOF
$(open_entries)
EOF
    fi
  fi
  if [ "$found" != 1 ]; then
    printf 'note: %s is not currently an open question on this run; the answer is still recorded, but check the id before sending the steer\n' "$qid" >&2
  fi

  # The durable half, and the one that reaches the next COLD reviewer: the
  # decision recorder writes it into the pinned intent this task is scored
  # against. An answer settles only the question it answers, and it leaves the
  # branch untouched unless it says otherwise, so no-change is the default and
  # no fresh run is owed for it.
  "$DECISION_BIN" record "$id" \
    --finding "$qid" --key "$qid" --step review --outcome "$outcome" \
    --requires "review question $qid answered by the $who: '$ans' - this settles only that question" \
    || { echo "error: the answer could not be recorded, so it must not be sent" >&2; exit 1; }

  steer=$(steer_line "$qid" "$ans" "$who")
  printf 'recorded: %s (key %s, outcome %s)\n' "$("$DECISION_BIN" path "$id")" "$qid" "$outcome"
  printf 'steer: %s\n' "$steer"
  printf 'send: %s/fm-send.sh %s %s\n' "$SCRIPT_DIR" "$id" "$(shq "$steer")"
  return 0
}

# --- run --------------------------------------------------------------------

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac
ACTION=$1
shift

case "$ACTION" in
  surface) cmd_surface; exit $? ;;
  list|gate|answer)
    [ "$#" -ge 1 ] || { usage; exit 2; }
    id_valid "$1" || { echo "error: invalid task id" >&2; exit 2; }
    case "$ACTION" in
      list) cmd_list "$1"; exit $? ;;
      gate) cmd_gate "$1"; exit $? ;;
      answer) cmd_answer "$@"; exit $? ;;
    esac
    ;;
  *) usage; exit 2 ;;
esac
