#!/usr/bin/env bash
# fm-nm-flow.sh - live, read-only ASCII flow view of a task's no-mistakes delivery pipeline.
#
# Purpose: a terminal-viewable block-flow diagram of the FULL delivery flow -
# intent -> rebase -> review -> test -> document -> lint -> push -> PR ->
# CI monitor -> firstmate merge gate (fm-assert-tests-kept + captain-approved
# supersessions) -> captain merge -> teardown - with the current step
# highlighted, so the captain can keep it open in a tmux window while a run is
# in flight. Each box is labeled LLM or deterministic (det), and the two LLM
# conflict-resolution points (the rebase step, and the CI monitor's automatic
# rebase when the PR falls behind) carry a one-line warning that they can
# silently drop base-branch code - the deterministic prior-tests merge gate
# exists to catch exactly that.
#
# Usage:
#   fm-nm-flow.sh <task-id> [--watch [seconds]] [--tests-gate]
#       Resolve worktree= and project= from state/<task-id>.meta, the same
#       resolution fm-crew-state.sh uses (FM_HOME / FM_STATE_OVERRIDE honored).
#   fm-nm-flow.sh --worktree <path> [--watch [seconds]] [--tests-gate]
#       Explicit mode: no meta needed; read the given worktree directly.
#
# Flags:
#   --watch [seconds]  Clear and re-render in a loop (default every 5s) until
#                      interrupted; without it, render once and exit. The test
#                      hook FM_NM_FLOW_WATCH_MAX=<n> bounds the loop to n frames.
#   --tests-gate       Also run bin/fm-assert-tests-kept.sh ONCE (cached across
#                      watch frames) in its explicit --worktree/--base mode and
#                      show missing:/failing: counts in the merge-gate box.
#                      Explicit mode never fetches, so the base may lag origin;
#                      it executes the base's own shell test files (check 2), so
#                      it costs real time - that is why it is opt-in, why the
#                      first watch frame renders the box as "checking..." and
#                      only frame 2 carries the result, and why a legend line
#                      under the diagram names how many base files that run
#                      could verify by name only. Without the flag the
#                      merge-gate box renders as pending.
#   -h, --help         Print this usage on stdout and exit 0.
#
# Width: the diagram is drawn for a plain 80-column pane and the header line is
# bounded to the render width, which is FM_NM_FLOW_COLS when it is a sane
# number, else the detected terminal width when stdout is a tty and that width
# is wider than 80, else 80. Only the title segment is shortened, always with
# an ellipsis marking the elision, and the fixed "no-mistakes flow: " prefix is
# dropped before the title shrinks further, because which task the pane shows
# outranks decoration. The branch and the run id are NEVER truncated - a
# partial ULID still reads as a run id while being useless to paste back into
# the CLI - so an extreme width lets the header wrap rather than mutilating
# either.
#
# Step kinds: the test and lint boxes are deterministic only when the target
# project defines commands.test / commands.lint in its .no-mistakes.yaml;
# without them no-mistakes delegates that step to an agent. Those two boxes are
# labeled from the worktree's own config, and fall back to `det|LLM` when no
# config is readable or its `commands:` block cannot be read confidently.
#
# Run-state source: `no-mistakes axi status` executed in the target worktree
# (bounded by FM_NM_FLOW_NM_TIMEOUT, default 10s), attributed to the worktree's
# current branch; when the answer is another branch's run, the coarse top-level
# `no-mistakes runs` list gives a last-run status for this branch. The TOON and
# plain-text output shapes parsed here follow bin/fm-crew-state.sh, whose
# comments record the empirical verification against the real installed CLI
# (v1.32.2, including the `no-mistakes runs` column layout and the ci-step log
# markers); tests/fm-crew-state.test.sh maintains the same shapes as fixtures.
# Re-verified 2026-07-26 on v1.37.0 for the no-runs shapes: `axi status` with
# no runs prints `runs: 0 runs yet in this repository`, and `no-mistakes runs`
# prints a "no runs yet" banner (neither is an error).
#
# Degradation: no active run for the branch -> the branch's last run (coarse);
# no run at all -> the static diagram with an IDLE banner; an empty or
# unparseable status answer -> a STATUS UNREADABLE banner, never a guess.
#
# Read-only guarantee: this viewer only ever runs `no-mistakes axi status`,
# `no-mistakes axi logs`, `no-mistakes runs`, git ref reads, and (opt-in) the
# report-only fm-assert-tests-kept.sh explicit mode. It never responds to
# gates, never writes outside its own mktemp dir, and never mutates task state.
#
# Exit status: 0 on a successful render (any state), 1 when the task/worktree
# cannot be resolved, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

NM_TIMEOUT=${FM_NM_FLOW_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac

usage() {
  cat <<'EOF'
usage: fm-nm-flow.sh <task-id> [--watch [seconds]] [--tests-gate]
       fm-nm-flow.sh --worktree <path> [--watch [seconds]] [--tests-gate]
EOF
}
usage_error() {
  usage >&2
  exit 2
}

ID="" WT_ARG="" WATCH=0 INTERVAL=5 TESTS_GATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) shift; WT_ARG=${1:-}; [ -n "$WT_ARG" ] || usage_error ;;
    --watch)
      WATCH=1
      case "${2:-}" in
        ''|-*) : ;;
        *[!0-9]*) usage_error ;;
        *) INTERVAL=$2; shift ;;
      esac
      [ "$INTERVAL" -ge 1 ] || INTERVAL=1
      ;;
    --tests-gate) TESTS_GATE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage_error ;;
    *) [ -z "$ID" ] || usage_error; ID=$1 ;;
  esac
  shift
done
{ [ -n "$ID" ] || [ -n "$WT_ARG" ]; } || usage_error
{ [ -n "$ID" ] && [ -n "$WT_ARG" ]; } && usage_error

# --- target resolution (task-id via meta, or explicit worktree) -------------

meta_value() {  # <file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

TITLE="" PR_URL=""
if [ -n "$ID" ]; then
  META="$STATE/$ID.meta"
  if [ ! -f "$META" ]; then
    echo "fm-nm-flow.sh: no metadata for task '$ID' at $META" >&2
    exit 1
  fi
  WT=$(meta_value "$META" worktree)
  PROJECT=$(meta_value "$META" project)
  PR_URL=$(meta_value "$META" pr)
  TITLE="$ID"
  [ -n "$PROJECT" ] && TITLE="$ID (${PROJECT##*/})"
else
  WT=$WT_ARG
  TITLE="${WT_ARG%/}"
  TITLE="${TITLE##*/}"
fi
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  echo "fm-nm-flow.sh: worktree not found: '${WT:-}'" >&2
  exit 1
fi
WT=$(cd "$WT" && pwd -P)
if ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "fm-nm-flow.sh: not a git worktree: $WT" >&2
  exit 1
fi

# --- bounded read-only no-mistakes calls (pattern from fm-crew-state.sh) ----

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    perl)     ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    *)        true ;;
  esac
}

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Gate step name: `gate: <name>` scalar, else `step:` inside a `gate:` block,
# else the first steps-table row parked at awaiting_approval/fix_review.
nm_gate_name() {
  local gate row
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  gate=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  gate=$(strip_quotes "$gate")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  trim "${row%%,*}"
}

# Finding count from a findings[N]{...} header; empty when none.
nm_findings_total() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
# Per-action counts. Matches the action column token between commas; a
# description that itself contains ", ask-user," would overcount, which is
# acceptable for a display-only breakdown.
nm_action_count() {  # <action>
  printf '%s\n' "$RUN_OUT" | grep -cE ",[[:space:]]*$1[[:space:]]*," || true
}

# First steps-table row actively running or fixing, restricted to known steps.
nm_running_step() {
  local row
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(intent|rebase|review|test|document|lint|push|pr|ci),[[:space:]]*"?(running|fixing)"?(,|[[:space:]]|$)' | head -1)
  [ -n "$row" ] || return 0
  trim "${row%%,*}"
}

# CI-monitor phase: `axi status` reports "waiting on checks", "checks red" and
# "checks green, waiting on merge" all as a running ci step; the ci step's own
# log is the only place the distinction shows (marker list verified in
# fm-crew-state.sh). Sets CI_PHASE to green, red-failed, red-issues, waiting,
# or empty when no marker could be read at all.
CI_PHASE=""
nm_ci_phase() {
  local run_id log_tail marker
  CI_PHASE=""
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || return 0
  log_tail=$(nm_run axi logs --step ci --run "$run_id")
  [ -n "$log_tail" ] || return 0
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  [ -n "$marker" ] || return 0
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) CI_PHASE=green ;;
    *"checks failed"*)    CI_PHASE=red-failed ;;
    *"issues detected"*)  CI_PHASE=red-issues ;;
    *)                    CI_PHASE=waiting ;;
  esac
}

# Coarse last-run status for a branch from the plain-text `no-mistakes runs`
# list: "<status> <branch> <short-sha> <date> [<pr-url>]", newest first.
nm_runs_status_for_branch() {  # <branch>
  local out row st rest br
  out=$(nm_run runs --limit 200)
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=$(trim "${row#* }")
    br=${rest%% *}
    if [ "$br" = "$1" ]; then
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# --- optional merge-gate probe (opt-in, once per invocation) -----------------

# Explicit-mode base ref: origin's default branch when a remote-tracking ref is
# present (never fetched here - read-only), else the local main/master.
tests_gate_base() {
  local sym cand
  sym=$(git -C "$WT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$sym" ]; then
    printf '%s' "${sym#refs/remotes/}"
    return 0
  fi
  for cand in origin/main origin/master main master; do
    if git -C "$WT" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

MGATE_ANN="prior-tests: pending (checked at merge)"
MGATE_NAMEONLY=0
run_tests_gate() {
  local base out_file missing failing
  if ! base=$(tests_gate_base); then
    MGATE_ANN="prior-tests: pending (no base ref found)"
    return
  fi
  local tmpd
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-flow.XXXXXX") || {
    MGATE_ANN="prior-tests: pending (tmp unavailable)"
    return
  }
  out_file="$tmpd/kept.out"
  local rc=0
  "$SCRIPT_DIR/fm-assert-tests-kept.sh" --worktree "$WT" --base "$base" \
    > "$out_file" 2>"$tmpd/kept.err" || rc=$?
  missing=$(grep -c '^missing: ' "$out_file" || true)
  failing=$(grep -c '^failing: ' "$out_file" || true)
  # One `name-check only: <file>` line per base test file check 2 could not
  # execute; those files are verified by NAME ONLY, so a kept-name test whose
  # assertion body was rewritten would not be caught. Counting the per-file
  # lines (never the fixed WARNING header lines) keeps the number a file count,
  # and it is reported on its own legend line so the box stays inside 80 cols.
  MGATE_NAMEONLY=$(grep -c '^WARNING:[[:space:]]*name-check only: ' "$tmpd/kept.err" || true)
  # Exit 0 = clean, exit 1 = reported missing/failing lines; anything else
  # means the check itself did not run, so never render a false "ok".
  if [ "$rc" -eq 0 ] && [ "$missing" -eq 0 ] && [ "$failing" -eq 0 ]; then
    MGATE_ANN="prior-tests vs $base: missing 0 / failing 0 ok"
  elif [ "$rc" -le 1 ]; then
    MGATE_ANN="prior-tests vs $base: missing $missing / failing $failing !!"
  else
    MGATE_ANN="prior-tests: pending (check could not run, exit $rc)"
    MGATE_NAMEONLY=0
  fi
  rm -rf "$tmpd"
}
# The probe executes the base's own test files, so it is deferred past the
# first frame: a watch pane shows the diagram immediately with the box marked
# as still checking, and frame 2 carries the real result.
TESTS_GATE_PENDING=0
if [ "$TESTS_GATE" = 1 ]; then
  TESTS_GATE_PENDING=1
  MGATE_ANN="prior-tests: checking... (running the base suite)"
fi

# --- step kinds derived from the target project's own config -----------------

# no-mistakes runs the test and lint steps deterministically only when the
# project defines commands.test / commands.lint; without them it delegates the
# step to an agent. Read that from the worktree's .no-mistakes.yaml with the
# shell tools already used here (no YAML dependency): a top-level `commands:`
# block key with an inline non-empty value means det, and a key genuinely
# absent from that block means LLM. Everything else - no config, an unreadable
# config, an inline/flow `commands:` mapping, or a key whose value is not
# readable inline (a nested list or mapping, or a trailing comment) - stays the
# conditional `det|LLM` rather than asserting either.
step_kind_from_config() {  # <commands key>
  local cfg="" c block
  for c in "$WT/.no-mistakes.yaml" "$WT/.no-mistakes.yml"; do
    if [ -f "$c" ] && [ -r "$c" ]; then cfg=$c; break; fi
  done
  if [ -z "$cfg" ]; then printf 'det|LLM'; return; fi
  if ! grep -qE '^commands:' "$cfg" 2>/dev/null; then printf 'LLM'; return; fi
  if ! grep -qE '^commands:[[:space:]]*(#.*)?$' "$cfg" 2>/dev/null; then
    printf 'det|LLM'
    return
  fi
  block=$(sed -n '/^commands:[[:space:]]*\(#.*\)\{0,1\}$/,/^[^[:space:]#]/p' "$cfg" 2>/dev/null)
  if printf '%s\n' "$block" | grep -qE "^[[:space:]]+$1:[[:space:]]*[^[:space:]#]"; then
    printf 'det'
  elif printf '%s\n' "$block" | grep -qE "^[[:space:]]+$1:([[:space:]]|$)"; then
    printf 'det|LLM'
  else
    printf 'LLM'
  fi
}
KIND_TEST=$(step_kind_from_config test)
KIND_LINT=$(step_kind_from_config lint)

# --- probe: classify the run state for one frame -----------------------------

# Globals set per frame for the renderer.
CURRENT="" BANNER="" OUTCOME="" GATE="" RUN_ID="" RUN_PR="" BRANCH=""
F_TOTAL="" F_ASK=0 F_FIX=0 F_NOOP=0 FAILED_LOOP=0

probe() {
  CURRENT="" BANNER="" OUTCOME="" GATE="" RUN_ID="" RUN_PR=""
  F_TOTAL="" F_ASK=0 F_FIX=0 F_NOOP=0 FAILED_LOOP=0
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  if ! command -v no-mistakes >/dev/null 2>&1; then
    BANNER="STATUS UNREADABLE: no-mistakes CLI not found - static flow shown"
    return
  fi
  if [ -z "$BRANCH" ]; then
    BANNER="IDLE: detached HEAD, no branch to attribute a run to - static flow shown"
    return
  fi

  RUN_OUT=$(nm_run axi status)
  if [ -z "$RUN_OUT" ]; then
    BANNER="STATUS UNREADABLE: no answer from no-mistakes in ${NM_TIMEOUT}s - static flow shown"
    return
  fi

  local run_branch coarse status
  run_branch=$(strip_quotes "$(nm_field branch)")
  if [ -z "$run_branch" ] || [ "$run_branch" != "$BRANCH" ]; then
    coarse=$(nm_runs_status_for_branch "$BRANCH")
    if [ -n "$coarse" ]; then
      case "$coarse" in
        running) BANNER="background run: running (no step detail for this branch)" ;;
        *)       BANNER="last run for this branch: $coarse (no step detail)" ;;
      esac
    else
      BANNER="IDLE: no run for branch $BRANCH - static flow shown"
    fi
    return
  fi

  RUN_ID=$(strip_quotes "$(nm_field id)")
  RUN_PR=$(strip_quotes "$(nm_field pr)")
  status=$(strip_quotes "$(nm_field status)")
  OUTCOME=$(strip_quotes "$(nm_field outcome)")

  if [ -n "$OUTCOME" ]; then
    case "$OUTCOME" in
      checks-passed)
        CURRENT=mgate
        BANNER="OUTCOME: checks-passed - CI green, PR ready for merge gate + captain"
        ;;
      passed)
        CURRENT=teardown
        BANNER="OUTCOME: passed - PR merged/closed"
        ;;
      failed|cancelled)
        FAILED_LOOP=1
        BANNER="OUTCOME: $OUTCOME - commit a fix on the branch, fresh run (fail loop)"
        ;;
      *)
        BANNER="OUTCOME: $OUTCOME"
        ;;
    esac
    return
  fi

  GATE=$(nm_gate_name)
  local awaiting
  awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  if [ -n "$GATE" ] || [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ]; then
    [ -n "$GATE" ] || GATE=gate
    CURRENT=$GATE
    F_TOTAL=$(nm_findings_total)
    F_ASK=$(nm_action_count ask-user)
    F_FIX=$(nm_action_count auto-fix)
    F_NOOP=$(nm_action_count no-op)
    BANNER="PARKED at $GATE gate: ${F_TOTAL:-0} findings ($F_ASK ask-user, $F_FIX auto-fix, $F_NOOP no-op)"
    return
  fi

  CURRENT=$(nm_running_step)
  [ -n "$CURRENT" ] || { [ "$status" = ci ] && CURRENT=ci; }
  if [ "$CURRENT" = ci ] && [ "$status" != fixing ]; then
    nm_ci_phase
    case "$CI_PHASE" in
      green)
        CURRENT=mgate
        BANNER="CI GREEN: monitoring until merge/close - merge gate + captain next"
        return
        ;;
      red-failed)
        BANNER="CI RED: checks failed - pipeline fixing"
        return
        ;;
      red-issues)
        BANNER="CI RED: issues detected - pipeline fixing"
        return
        ;;
    esac
  fi
  if [ -n "$CURRENT" ]; then
    BANNER="state: $status @ $CURRENT"
  else
    BANNER="state: ${status:-active} (step not reported)"
  fi
}

# --- rendering ----------------------------------------------------------------

TTY=0 REV="" BOLD="" SGR0=""
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  TTY=1
  REV=$(tput rev 2>/dev/null || true)
  BOLD=$(tput bold 2>/dev/null || true)
  SGR0=$(tput sgr0 2>/dev/null || true)
fi

# Render width: explicit override, else a tty wider than the 80-column baseline
# the diagram is drawn for, else 80. Anything non-numeric, absurd, or narrower
# than a sane floor falls back to 80 rather than a degenerate header.
COLS=80
if [ -n "${FM_NM_FLOW_COLS:-}" ]; then
  case "$FM_NM_FLOW_COLS" in
    *[!0-9]*) : ;;
    *) if [ "$FM_NM_FLOW_COLS" -ge 40 ] && [ "$FM_NM_FLOW_COLS" -le 1000 ]; then
         COLS=$FM_NM_FLOW_COLS
       fi ;;
  esac
elif [ "$TTY" = 1 ]; then
  TPUT_COLS=$(tput cols 2>/dev/null || true)
  case "$TPUT_COLS" in
    ''|*[!0-9]*) : ;;
    *) if [ "$TPUT_COLS" -gt 80 ] && [ "$TPUT_COLS" -le 1000 ]; then
         COLS=$TPUT_COLS
       fi ;;
  esac
fi

RULE="------------------------------------------------------------------------------"

step_line() {  # <key> <label> <kind> <annotation>
  local key=$1 label=$2 kind=$3 ann=$4 rail=' | ' line
  line=$(printf '[ %-11s %-7s ]' "$label" "$kind")
  [ -n "$ann" ] && line="$line $ann"
  if [ "$key" = "$CURRENT" ]; then
    printf '%s%s%s%s\n' ">> " "$REV" "$line" "$SGR0"
  else
    [ "$key" = teardown ] && rail=' v '
    printf '%s%s\n' "$rail" "$line"
  fi
}

# Header bounded to COLS. The title says which task's flow the pane is showing,
# so it outranks the fixed prefix: the title is shortened first, then the
# prefix is sacrificed to keep more of it, and only when even the prefix-less
# form leaves no room does the title reduce to a bare ellipsis. An elision is
# always marked, and the branch and run id segments are always emitted whole -
# a partial branch or ULID reads as real while being useless to paste back.
header_line() {
  local tail=" | branch ${BRANCH:-<detached>}" p avail t
  [ -n "$RUN_ID" ] && tail="$tail | run $RUN_ID"
  for p in 'no-mistakes flow: ' ''; do
    if [ $(( ${#p} + ${#TITLE} + ${#tail} )) -le "$COLS" ]; then
      printf '%s%s%s' "$p" "$TITLE" "$tail"
      return
    fi
    avail=$(( COLS - ${#p} - ${#tail} ))
    if [ "$avail" -ge 4 ]; then
      t=${TITLE:0:$((avail - 3))}
      t=${t%"${t##*[![:space:]]}"}
      printf '%s%s...%s' "$p" "$t" "$tail"
      return
    fi
  done
  printf '...%s' "$tail"
}

render() {
  printf '%s\n' "$(header_line)"
  printf '%s%s%s\n' "$BOLD" "$BANNER" "$SGR0"
  local pr="${RUN_PR:-$PR_URL}"
  [ -n "$pr" ] && printf 'PR: %s\n' "$pr"
  printf '%s\n' "$RULE"
  step_line intent   intent       det       "goal the review judges against"
  step_line rebase   rebase       LLM       "!! LLM merge can drop base code; merge gate catches"
  step_line review   review       LLM       "gate: findings park run <--+"
  step_line test     test         "$KIND_TEST" "gate$(printf '%23s' '')|  fix round: pipeline"
  step_line document document     LLM       "gate$(printf '%23s' '')|  fixes, re-reviews step"
  step_line lint     lint         "$KIND_LINT" "gate ----------------------+"
  step_line push     push         det       ""
  step_line pr       "open PR"    det       ""
  step_line ci       "CI monitor" det+LLM   "!! LLM auto-rebase can drop base code; gate catches"
  step_line mgate    "merge gate" det       "$MGATE_ANN"
  step_line captain  captain      human     "explicit approval (or standing yolo)"
  step_line teardown teardown     det       "after landing confirmed"
  printf '%s\n' "$RULE"
  printf 'outcomes: checks-passed=CI green, PR ready | passed=merged | failed | cancelled\n'
  if [ "$FAILED_LOOP" = 1 ]; then
    printf '%s%s%s%s\n' ">> " "$REV" "fail loop: failed/cancelled -> commit fix on same branch -> rerun at intent" "$SGR0"
  else
    printf '   fail loop: failed/cancelled -> commit fix on same branch -> rerun at intent\n'
  fi
  printf 'merge gate: check 1 base test names kept; check 2 base assertions vs branch\n'
  printf 'supersessions: captain-approved entries in data/supersessions/<project>.md\n'
  if [ "$MGATE_NAMEONLY" -gt 0 ]; then
    local noun=files
    [ "$MGATE_NAMEONLY" -eq 1 ] && noun='file'
    printf 'prior-tests: %s base %s verified by name only, not by assertion\n' \
      "$MGATE_NAMEONLY" "$noun"
  fi
  if [ "$KIND_TEST" = 'det|LLM' ] || [ "$KIND_LINT" = 'det|LLM' ]; then
    printf 'det|LLM: commands.<step> not readable in .no-mistakes.yaml; det when it is set\n'
  fi
}

frame() {
  probe
  render
}

if [ "$WATCH" = 0 ]; then
  [ "$TESTS_GATE_PENDING" = 1 ] && run_tests_gate
  frame
  exit 0
fi

trap 'exit 0' INT TERM
FRAMES=0
MAX_FRAMES=${FM_NM_FLOW_WATCH_MAX:-0}
case "$MAX_FRAMES" in ''|*[!0-9]*) MAX_FRAMES=0 ;; esac
while :; do
  OUT=$(frame)
  if [ "$TTY" = 1 ]; then
    printf '\033[H\033[2J%s\n' "$OUT"
  else
    printf '%s\n\n' "$OUT"
  fi
  FRAMES=$((FRAMES + 1))
  if [ "$MAX_FRAMES" -gt 0 ] && [ "$FRAMES" -ge "$MAX_FRAMES" ]; then
    exit 0
  fi
  if [ "$TESTS_GATE_PENDING" = 1 ]; then
    TESTS_GATE_PENDING=0
    run_tests_gate
    continue
  fi
  sleep "$INTERVAL"
done
