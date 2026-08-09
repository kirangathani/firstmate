#!/usr/bin/env bash
# fm-drift-check.sh - the durable backlog read against live reality.
#
# THE FAILURE THIS EXISTS FOR (measured 2026-08-09, this repo's own home):
# session start printed a backlog claiming 17 tasks in flight while 2 agents
# were actually running. Twelve state/*.meta records named tasks whose work had
# already merged - PRs 30, 31, 32, 33, 34, 35, 38, 39, 40 and 48 were merged on
# GitHub while their tasks still read as in flight, and two scouts had delivered
# their reports days earlier. Every input needed to notice was already on disk
# or one API call away. Nothing put them side by side, so a human had to.
#
# That is not cosmetic. A queue reading 17-in-flight looks busy, so 33 ready
# items sat undispatched; and a stale meta is what makes teardown reachable
# against a worktree slot since re-leased to a LIVE task, which has already
# destroyed a running agent once.
#
# DETECTION ONLY. This script reports; it never tears down a task, never closes
# a backlog item, and never writes anything outside its own scratch dir. A
# wrong automatic teardown is precisely the destructive failure the fleet is
# already vulnerable to, so reconciliation stays firstmate's to perform.
#
# THE FOUR CLASSES, and the authoritative record each one keys on. No class is
# derived from a worker's free-text status log: prose is evidence for a human,
# never an input to a machine-consumed fact.
#
#   1 in flight, worker not running
#       data/backlog.md's In flight section x the recorded backend endpoint,
#       read through fm_backend_target_exists - the same primitive the
#       session-start digest's own per-task liveness line uses, so the two can
#       never disagree.
#   2 in flight, PR already merged
#       the PR link RECORDED in state/<id>.meta by bin/fm-pr-check.sh x
#       GitHub's answer for it (`gh pr view <url> --json state`, the same read
#       bin/fm-pr-poll.sh's merge poll makes). A task whose PR was never
#       recorded is not silently assumed clean: once its worker exits it is
#       caught by class 1 instead.
#   3 runtime record, not in flight
#       state/*.meta x the In flight section. kind=secondmate is excluded
#       because a persistent secondmate is never a backlog item (AGENTS.md
#       section 10).
#   4 in flight, no runtime record
#       the In flight section x state/*.meta. A `kind: captain` row is excluded
#       because a captain-gated thread has no worker by design.
#
# THE RENDER CONTRACT. Every class is named on every render, zeros included. A
# class that could not be evaluated prints a dash and its reason, never a `0`,
# because a `0` that means "did not look" is the exact shape of a silent false
# all-clear. A class that was only PARTIALLY evaluated prints the findings it
# did confirm plus an `incomplete:` note. The `ok` line appears only when all
# four classes are zero AND all four were fully evaluated.
#
# COST, measured 2026-08-09 on this machine, best of three each:
#   0.18-0.24s  this repo's real home - 4 in flight, 5 runtime records, no
#               recorded PR in flight, so no GitHub call at all.
#   0.37-0.45s  the same shape plus ONE real GitHub lookup.
#   1.12-1.19s  the whole 2026-08-09 incident rebuilt - 12 in flight, each with
#               a recorded PR, all 12 queried against real GitHub.
# The backlog parse is one `bin/fm-fleet-snapshot.sh --backlog-json`, 0.10s
# against this repo's real 50KB backlog, and the endpoint reads are the same
# per-task probes session start already performs. GitHub is queried ONLY for an
# in-flight task that has a recorded PR link, so a healthy fleet that has just
# dispatched work queries nothing. Lookups run FM_DRIFT_PR_PARALLEL at a time,
# are capped at FM_DRIFT_PR_LOOKUPS in total, and each is bounded by
# FM_PR_GH_TIMEOUT, so the worst case is bounded by the cap and not by how far
# the queue has drifted.
#
# WHEN GITHUB IS UNREACHABLE the class degrades VISIBLY: a lookup that fails,
# times out, or is refused for lack of `gh` leaves its task unresolved, and an
# unresolved candidate either turns the class into a dash (nothing confirmed) or
# attaches an `incomplete:` note to what was confirmed. It never reports "no
# drift" because the question could not be asked.
#
# Usage:
#   fm-drift-check.sh                report; exit 1 if anything is off
#   fm-drift-check.sh --no-github    skip every PR lookup (class 2 undetermined)
# Exit: 0 every class clear and fully evaluated, 1 anything to report, 2 usage.
#
# Environment:
#   FM_DRIFT_DETAIL       findings listed per class before "(+N more)" (default 6)
#   FM_DRIFT_PR_LOOKUPS   maximum GitHub PR lookups per run (default 20)
#   FM_DRIFT_PR_PARALLEL  concurrent GitHub PR lookups (default 8)
#   FM_PR_GH_TIMEOUT      seconds bounding one lookup (bin/fm-pr-lib.sh owns it;
#                         defaulted to 8 here rather than the library's 15,
#                         because this runs on the session-start critical path -
#                         an operator's own value still wins)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# fm_backend_of_meta, fm_backend_target_of_meta, fm_backend_target_exists,
# fm_backend_required_tool_available, fm_meta_get.
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# fm_pr_url_parse (the one PR-link parser), fm_pr_bounded, fm_task_id_path_safe.
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

DETAIL_LIMIT=${FM_DRIFT_DETAIL:-6}
case "$DETAIL_LIMIT" in ''|*[!0-9]*|0) DETAIL_LIMIT=6 ;; esac
PR_LOOKUPS=${FM_DRIFT_PR_LOOKUPS:-20}
case "$PR_LOOKUPS" in ''|*[!0-9]*) PR_LOOKUPS=20 ;; esac
PR_PARALLEL=${FM_DRIFT_PR_PARALLEL:-8}
case "$PR_PARALLEL" in ''|*[!0-9]*|0) PR_PARALLEL=8 ;; esac
FM_PR_GH_TIMEOUT=${FM_PR_GH_TIMEOUT:-8}
export FM_PR_GH_TIMEOUT

usage() {
  cat <<EOF
usage: fm-drift-check.sh [--no-github]

Report drift between data/backlog.md's In flight section and live reality.
Detection only: it never tears down a task or edits the backlog.

  --no-github   make no GitHub call; the merged-PR class reports undetermined.

Exit 0 when every class is clear and was fully evaluated, 1 when anything is
off or could not be determined, 2 on a usage error.

Defaults: FM_DRIFT_DETAIL=$DETAIL_LIMIT FM_DRIFT_PR_LOOKUPS=$PR_LOOKUPS FM_DRIFT_PR_PARALLEL=$PR_PARALLEL FM_PR_GH_TIMEOUT=$FM_PR_GH_TIMEOUT
EOF
}

USE_GITHUB=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-github) USE_GITHUB=0; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

TMP_DIR=
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-drift-check.XXXXXX") || {
  echo "fm-drift-check: could not create a scratch dir" >&2
  exit 2
}

TAB=$'\t'

# --- the in-flight set, from the canonical backlog parser -------------------
#
# bin/fm-fleet-snapshot.sh owns the reading of data/backlog.md. Parsing it a
# second time here would be a copy that rots the moment only one is edited, so
# this asks that owner for its backlog object and nothing else.
IN_FLIGHT=$'\n'          # "\n<id>\n<id>\n", membership-tested by pattern
IN_FLIGHT_WORKED=$'\n'   # the subset a worker is expected for (kind != captain)
BACKLOG_REASON=
backlog_json=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-json 2>/dev/null) || backlog_json=
if [ -z "$backlog_json" ]; then
  BACKLOG_REASON='the backlog could not be read'
elif ! printf '%s' "$backlog_json" | jq -e '.present == true' >/dev/null 2>&1; then
  BACKLOG_REASON='no backlog file'
else
  while IFS=$TAB read -r id kind; do
    [ -n "$id" ] || continue
    # An id becomes a state/<id>.meta path below, so it is judged by the same
    # rule every other consumer of a task id uses before it is ever joined.
    fm_task_id_path_safe "$id" || continue
    IN_FLIGHT="$IN_FLIGHT$id"$'\n'
    [ "$kind" = captain ] || IN_FLIGHT_WORKED="$IN_FLIGHT_WORKED$id"$'\n'
  done <<EOF
$(printf '%s' "$backlog_json" | jq -r '
  .records[]?
  | select(.state == "in_flight" and .structured == true and .id != null)
  | .id + "\t" + (.kind // "")')
EOF
fi

in_flight() {  # <id>
  case "$IN_FLIGHT" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# --- class accumulators ------------------------------------------------------
#
# Per class: a finding count, the findings themselves, an evaluated flag, an
# unresolved count, and the reason it could not be (fully) evaluated. Four
# parallel sets rather than one array-of-struct, because macOS still ships
# bash 3.2 and has no associative arrays.
A_N=0; A_TEXT=; A_EVAL=1; A_UNRESOLVED=0; A_WHY=
B_N=0; B_TEXT=; B_EVAL=1; B_UNRESOLVED=0; B_WHY=
C_N=0; C_TEXT=; C_EVAL=1; C_UNRESOLVED=0; C_WHY=
D_N=0; D_TEXT=; D_EVAL=1; D_UNRESOLVED=0; D_WHY=

record() {  # <class-letter> <sentence>
  case "$1" in
    A) A_N=$((A_N + 1)); A_TEXT="$A_TEXT$2"$'\n' ;;
    B) B_N=$((B_N + 1)); B_TEXT="$B_TEXT$2"$'\n' ;;
    C) C_N=$((C_N + 1)); C_TEXT="$C_TEXT$2"$'\n' ;;
    D) D_N=$((D_N + 1)); D_TEXT="$D_TEXT$2"$'\n' ;;
  esac
}

if [ -n "$BACKLOG_REASON" ]; then
  # Every class is defined against the In flight section, so without it none of
  # the four can be answered - including the two that also read state/*.meta.
  A_EVAL=0; A_WHY=$BACKLOG_REASON
  B_EVAL=0; B_WHY=$BACKLOG_REASON
  C_EVAL=0; C_WHY=$BACKLOG_REASON
  D_EVAL=0; D_WHY=$BACKLOG_REASON
fi

# --- pass 1: every runtime record -------------------------------------------
#
# One walk of state/*.meta answers class 1 (endpoint), class 3 (no in-flight
# row), and collects class 2's lookup candidates.
PR_CANDIDATES="$TMP_DIR/pr-candidates"
: > "$PR_CANDIDATES"
SEEN_META=$'\n'

if [ -d "$STATE" ] && [ -z "$BACKLOG_REASON" ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    SEEN_META="$SEEN_META$id"$'\n'

    if ! in_flight "$id"; then
      # A persistent secondmate home is deliberately not a backlog item, so its
      # runtime record having no in-flight row is the designed steady state.
      [ "$kind" = secondmate ] && continue
      record C "$id has a durable local record but no in-flight backlog item"
      continue
    fi

    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      record A "$id is in flight but its record names no worker endpoint at all"
    elif ! fm_backend_is_known "$backend" 2>/dev/null; then
      A_UNRESOLVED=$((A_UNRESOLVED + 1))
      A_WHY="a task records an unsupported worker runtime ($backend)"
    elif ! fm_backend_required_tool_available "$backend" "$backend" 2>/dev/null; then
      # Absent CLI: fm_backend_target_exists would answer "does not exist",
      # which here would be an invented death rather than an observed one.
      A_UNRESOLVED=$((A_UNRESOLVED + 1))
      A_WHY="the $backend command is not installed, so its endpoints cannot be probed"
    elif ! fm_backend_target_exists "$backend" "$target" \
        "$(fm_backend_expected_label_of_meta "$meta" "$id")" >/dev/null 2>&1; then
      record A "$id is in flight but its worker is gone ($backend endpoint $target)"
    fi

    pr=$(fm_meta_get "$meta" pr)
    if [ -n "$pr" ] && fm_pr_url_parse "$pr"; then
      printf '%s\t%s\n' "$id" "$FM_PR_URL" >> "$PR_CANDIDATES"
    fi
  done
fi

# --- pass 2: in-flight rows with no runtime record --------------------------
if [ -z "$BACKLOG_REASON" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$SEEN_META" in *$'\n'"$id"$'\n'*) continue ;; esac
    record D "$id is in flight but has no durable local record of a worker"
  done <<EOF
$(printf '%s' "$IN_FLIGHT_WORKED")
EOF
fi

# --- pass 3: which recorded PRs GitHub already merged -----------------------
#
# Bounded three ways - candidate count, concurrency, and per-call wall clock -
# because this is the only step that leaves the machine and it runs on the
# session-start critical path.
lookup_prs() {
  local total capped n=0 running=0 idx line id url
  # grep -c exits 1 on no match, so the count and the status are read separately;
  # a `|| printf 0` here would append a second line to grep's own "0".
  total=$(grep -c . "$PR_CANDIDATES" 2>/dev/null) || total=0
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  [ "$total" -gt 0 ] || return 0

  capped=$total
  if [ "$total" -gt "$PR_LOOKUPS" ]; then
    capped=$PR_LOOKUPS
    B_UNRESOLVED=$((total - PR_LOOKUPS))
    B_WHY="stopped after the first $PR_LOOKUPS PR lookup(s)"
  fi

  idx=0
  while IFS=$TAB read -r id url; do
    [ -n "$id" ] || continue
    idx=$((idx + 1))
    [ "$idx" -le "$capped" ] || break
    (
      state=$(fm_pr_bounded gh pr view "$url" --json state -q .state 2>/dev/null) || state=
      printf '%s\t%s\t%s\n' "$id" "$url" "$state" > "$TMP_DIR/pr.$idx"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$PR_PARALLEL" ]; then
      wait
      running=0
    fi
  done < "$PR_CANDIDATES"
  wait

  n=0
  while [ "$n" -lt "$capped" ]; do
    n=$((n + 1))
    line=$(cat "$TMP_DIR/pr.$n" 2>/dev/null) || line=
    if [ -z "$line" ]; then
      B_UNRESOLVED=$((B_UNRESOLVED + 1))
      [ -n "$B_WHY" ] || B_WHY='a PR lookup did not complete'
      continue
    fi
    IFS=$TAB read -r id url state <<EOF
$line
EOF
    case "$state" in
      MERGED)
        record B "$id is in flight but its recorded PR is already merged: $url"
        ;;
      '')
        B_UNRESOLVED=$((B_UNRESOLVED + 1))
        [ -n "$B_WHY" ] || B_WHY='GitHub did not answer for a recorded PR'
        ;;
    esac
  done
}

if [ -n "$BACKLOG_REASON" ]; then
  :
elif [ "$USE_GITHUB" -eq 0 ]; then
  B_EVAL=0; B_WHY='GitHub lookups disabled (--no-github)'
elif ! command -v gh >/dev/null 2>&1; then
  # Only a REAL candidate makes this a gap: with no recorded PR in flight there
  # is nothing gh could have been asked about, so the class is a true zero.
  if [ -s "$PR_CANDIDATES" ]; then
    B_EVAL=0; B_WHY='gh is not installed'
  fi
else
  lookup_prs
fi

# --- render ------------------------------------------------------------------

LABEL_A='in flight, worker not running'
LABEL_B='in flight, PR already merged'
LABEL_C='runtime record, not in flight'
LABEL_D='in flight, no runtime record'

class_note() {  # <eval> <unresolved> <why> <found>
  local eval=$1 unresolved=$2 why=$3 found=$4
  if [ "$eval" -eq 0 ]; then
    printf 'not checked: %s' "$why"
  elif [ "$unresolved" -gt 0 ]; then
    printf 'incomplete: %s undetermined (%s)' "$unresolved" "$why"
  elif [ "$found" -gt 0 ]; then
    printf 'see DRIFT lines below'
  fi
}

row() {  # <label> <eval> <count> <unresolved> <why>
  local value note
  if [ "$2" -eq 0 ]; then value='-'; else value=$3; fi
  note=$(class_note "$2" "$4" "$5" "$3")
  if [ -n "$note" ]; then
    printf '  %-33s %3s  %s\n' "$1" "$value" "$note"
  else
    printf '  %-33s %3s\n' "$1" "$value"
  fi
}

findings() {  # <text-block> <count>
  local shown=0 line
  [ "$2" -gt 0 ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    shown=$((shown + 1))
    if [ "$shown" -gt "$DETAIL_LIMIT" ]; then
      printf 'DRIFT: (+%s more)\n' "$(($2 - DETAIL_LIMIT))"
      return 0
    fi
    printf 'DRIFT: %s\n' "$line"
  done <<EOF
$1
EOF
}

TOTAL=$((A_N + B_N + C_N + D_N))
INCOMPLETE=$((A_UNRESOLVED + B_UNRESOLVED + C_UNRESOLVED + D_UNRESOLVED))
UNEVALUATED=$((4 - A_EVAL - B_EVAL - C_EVAL - D_EVAL))

printf 'DRIFT CHECK - the durable backlog against live reality\n'
row "$LABEL_A" "$A_EVAL" "$A_N" "$A_UNRESOLVED" "$A_WHY"
row "$LABEL_B" "$B_EVAL" "$B_N" "$B_UNRESOLVED" "$B_WHY"
row "$LABEL_C" "$C_EVAL" "$C_N" "$C_UNRESOLVED" "$C_WHY"
row "$LABEL_D" "$D_EVAL" "$D_N" "$D_UNRESOLVED" "$D_WHY"

if [ "$TOTAL" -eq 0 ] && [ "$INCOMPLETE" -eq 0 ] && [ "$UNEVALUATED" -eq 0 ]; then
  printf 'DRIFT CHECK: ok - every class clear.\n'
  exit 0
fi

findings "$A_TEXT" "$A_N"
findings "$B_TEXT" "$B_N"
findings "$C_TEXT" "$C_N"
findings "$D_TEXT" "$D_N"

if [ "$TOTAL" -gt 0 ]; then
  printf 'DRIFT REMEDY: reconcile each line above before dispatching against this queue - confirm where the work actually landed, then clean up and close it deliberately. This report never does that for you.\n'
  printf 'DRIFT REMEDY: a stale local record is also what lets cleanup act on a worktree slot since re-leased to a live task, so do not leave one standing.\n'
fi
if [ "$INCOMPLETE" -gt 0 ] || [ "$UNEVALUATED" -gt 0 ]; then
  printf 'DRIFT REMEDY: undetermined is not clear - a dash or an incomplete note means the question could not be asked, not that the answer was no.\n'
fi
exit 1
