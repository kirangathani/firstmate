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
#                      The next argument is taken as the interval only when it
#                      is all digits, so `--watch <task-id>` works too; a
#                      digits-plus-unit interval (5s, 10m) is refused by name.
#   --tests-gate       Also run bin/fm-assert-tests-kept.sh ONCE (cached across
#                      watch frames) in its explicit --worktree/--base mode and
#                      show missing/failing counts in the merge-gate box, read
#                      from its `summary:` stdout line (per-line grep fallback).
#                      Explicit mode never fetches, so the base may lag origin;
#                      it executes the base's own test files (check 2), so
#                      it costs real time - that is why it is opt-in, why the
#                      first watch frame renders the box as "checking..." and
#                      only frame 2 carries the result, why the probe is bounded
#                      by FM_NM_FLOW_TESTS_TIMEOUT (default 300s) and refuses to
#                      run at all when nothing on the host can bound it, and why
#                      two legend lines under the diagram name the base the run
#                      compared against and how many of its files that run could
#                      verify by name only. A base assertion the probe reports
#                      as `unexecuted:` was verified by NAME ONLY, so the row
#                      then reads "(N unexecuted)" and NEVER a bare "ok": a
#                      green that means nothing ran reads as verified, which is
#                      the one thing this display must never show. The box row
#                      itself carries only the counts, so no base ref length can
#                      push it past 80 columns. Without the flag the box renders
#                      as pending.
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
# Height: in watch mode a frame is bounded the way width is, to FM_NM_FLOW_ROWS
# when it is a sane number, else the detected terminal height on a tty, else a
# hard 24 rows; an unbounded frame scrolls its own header - the line naming the
# task - off the top of an 80x24 pane. The one-shot render is never bounded:
# scrollback makes trimming pointless there, so it always emits the complete
# frame. The budget counts terminal ROWS, not frame lines: a line longer than
# the render width (the PR URL, which is never truncated) wraps, and each line
# is charged ceil(len/width) rows after stripping display attributes. Over
# budget, only legend lines are dropped - lowest value first, never the header,
# the banner or a step row - and the count dropped is printed where they were.
# Two qualifiers are structurally undroppable whenever the merge-gate box shows
# a result: the compared-base legend and the name-only legend rank as core, and
# when a pane is too short to carry them the box itself degrades to a pending
# form, so a green can never appear separated from its qualifiers at any pane
# size. When even the core lines cannot fit, the frame says so plainly instead
# of claiming it was made to fit.
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
# unparseable status answer -> a STATUS UNREADABLE banner, never a guess; a
# worktree that disappears mid-watch -> a TORN DOWN banner, because teardown is
# the last box in this flow and an empty `symbolic-ref` answer for a directory
# that no longer exists must not be reported as a detached HEAD.
#
# Read-only guarantee: this viewer only ever runs `no-mistakes axi status`,
# `no-mistakes axi logs`, `no-mistakes runs`, git ref reads, and (opt-in) the
# report-only fm-assert-tests-kept.sh explicit mode. It never responds to
# gates, never writes outside its own mktemp dir, and never mutates task state.
#
# Exit status: 0 on a successful render (any state), 1 when the task/worktree
# cannot be resolved, 2 on a usage error, 130 when interrupted (INT/TERM, both
# modes - one handler, so no reader has to wonder which of two traps ran).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

NM_TIMEOUT=${FM_NM_FLOW_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*|0) NM_TIMEOUT=10 ;; esac
TESTS_TIMEOUT=${FM_NM_FLOW_TESTS_TIMEOUT:-300}
case "$TESTS_TIMEOUT" in ''|*[!0-9]*|0) TESTS_TIMEOUT=300 ;; esac

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
W_NEXT="" W_DIGITS="" W_SUFFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) shift; WT_ARG=${1:-}; [ -n "$WT_ARG" ] || usage_error ;;
    --watch)
      WATCH=1
      # The interval is consumed ONLY when it is all digits, so `--watch
      # <task-id>` works in either order (task ids are 26-char ULIDs, which
      # begin with digits). A digits-plus-time-unit shape is the one ambiguous
      # case worth naming: it is a mistyped interval, not a task id, and saying
      # so beats both a bare usage block and a later "no metadata" error.
      W_NEXT=${2:-}
      W_DIGITS=${W_NEXT%%[!0-9]*}
      W_SUFFIX=${W_NEXT#"$W_DIGITS"}
      case "$W_NEXT" in
        ''|-*) : ;;
        *[!0-9]*)
          if [ -n "$W_DIGITS" ]; then
            case "$W_SUFFIX" in
              s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)
                echo "fm-nm-flow.sh: --watch interval must be a whole number of seconds, not '$W_NEXT'" >&2
                exit 2
                ;;
            esac
          fi
          ;;
        *) INTERVAL=$W_NEXT; shift ;;
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
# The one bounded-command primitive every external call here goes through. With
# none of timeout/gtimeout/perl on the host it REFUSES to run the command rather
# than falling back to an unbounded call: a single hung child would freeze a
# watch pane forever, so callers degrade to a pending display instead. Expiry is
# reported as 124 by all three arms, and a signal death as 128+signal by all
# three: the perl arm must reconstruct that from the wait status itself, because
# a bare `$? >> 8` reports a SIGKILLed child as a clean exit 0 - and this rc is
# the merge-gate verdict, so that would render a green meaning nothing ran.
BOUND_REFUSED_RC=125
# Held in a variable so the exit-status contract of the arm that has no
# `timeout` to inherit it from - the only arm stock macOS takes - can be
# exercised directly by the tests. The single quotes are the point: every $ in
# it is perl's, not the shell's.
# shellcheck disable=SC2016
PERL_BOUND_PROG='my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; my $sig = $? & 127; exit($sig ? 128 + $sig : $? >> 8)'
run_bounded() {  # <seconds> <cmd...>
  local secs=$1
  shift
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$secs" "$@" ;;
    gtimeout) gtimeout "$secs" "$@" ;;
    perl)     perl -e "$PERL_BOUND_PROG" "$secs" "$@" ;;
    *)        return "$BOUND_REFUSED_RC" ;;
  esac
}
nm_run() {  # <args...>
  ( cd "$WT" && run_bounded "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true
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
# fm-crew-state.sh). Sets CI_PHASE to green, no-checks, red-failed, red-issues,
# waiting, or empty when no marker could be read at all.
#
# The no-checks marker gets its own phase rather than folding into green: the
# pipeline moves on the same way, but nothing was verified, and a green that
# means nothing ran is the one thing this display must never show. The marker
# text cannot tell a repo with no CI from checks that have yet to report, so the
# banner asserts neither - only that no checks have been reported.
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
    *"no CI checks reported - still monitoring"*) CI_PHASE=no-checks ;;
    *"checks passed"*)    CI_PHASE=green ;;
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
MGATE_BASE=""
# The probe's scratch dir is the only thing this viewer ever writes, so its
# removal is owned by the EXIT trap alone: in watch mode an interrupt is
# delivered the moment the bounded probe returns, which would otherwise exit
# past any cleanup left on the return paths and leak a directory per
# interrupted run. INT/TERM has exactly one handler for the whole script, set
# here once - a second, mode-specific trap would shadow this one and leave a
# dead handler a future reader assumes still runs. It only converts the signal
# into an exit so the EXIT trap fires; 130 is the conventional interrupted
# status either mode reports.
MGATE_TMPD=""
clean_tmpd() {
  [ -n "$MGATE_TMPD" ] && rm -rf "$MGATE_TMPD"
  MGATE_TMPD=""
}
trap clean_tmpd EXIT
trap 'exit 130' INT TERM
run_tests_gate() {
  local base out_file missing failing unexec summary
  MGATE_BASE=""
  # The probe executes the base's own test files, so it must be time-bounded.
  # Nothing to bound it with means it does not run: a viewer that hangs is
  # worse than one that says the answer is still pending.
  if [ "$HAVE_TIMEOUT" = none ]; then
    MGATE_ANN="prior-tests: pending (no timeout tool to bound it)"
    MGATE_NAMEONLY=0
    return
  fi
  if ! base=$(tests_gate_base); then
    MGATE_ANN="prior-tests: pending (no base ref found)"
    return
  fi
  local tmpd
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-flow.XXXXXX") || {
    MGATE_ANN="prior-tests: pending (tmp unavailable)"
    return
  }
  MGATE_TMPD=$tmpd
  out_file="$tmpd/kept.out"
  local rc=0
  run_bounded "$TESTS_TIMEOUT" "$SCRIPT_DIR/fm-assert-tests-kept.sh" \
    --worktree "$WT" --base "$base" > "$out_file" 2>"$tmpd/kept.err" || rc=$?
  if [ "$rc" -eq 124 ]; then
    MGATE_ANN="prior-tests: pending (probe timed out after ${TESTS_TIMEOUT}s)"
    MGATE_NAMEONLY=0
    clean_tmpd
    return
  fi
  # Counts come from the machine-readable `summary:` stdout line; the per-line
  # greps are only the fallback for an output that carries no summary. The
  # unexecuted count is per ASSERTION: each `unexecuted:` identifier was
  # verified by NAME ONLY (check 1), so a kept-name test whose assertion body
  # was rewritten would not be caught.
  summary=$(grep -m1 '^summary: ' "$out_file" || true)
  if [ -n "$summary" ]; then
    missing=$(printf '%s' "$summary" | sed -n 's/.*missing=\([0-9]\{1,\}\).*/\1/p')
    failing=$(printf '%s' "$summary" | sed -n 's/.*failing=\([0-9]\{1,\}\).*/\1/p')
    unexec=$(printf '%s' "$summary" | sed -n 's/.*unexecuted=\([0-9]\{1,\}\).*/\1/p')
  else
    missing=$(grep -c '^missing: ' "$out_file" || true)
    failing=$(grep -c '^failing: ' "$out_file" || true)
    unexec=$(grep -c '^unexecuted: ' "$out_file" || true)
  fi
  missing=${missing:-0} failing=${failing:-0} unexec=${unexec:-0}
  # One stderr `UNEXECUTED: <file>` line per base test file check 2 could not
  # execute, so this stays a FILE count for the legend line while the row
  # carries the assertion count; both stay inside 80 columns that way.
  MGATE_NAMEONLY=$(grep -c '^UNEXECUTED: ' "$tmpd/kept.err" || true)
  # Exit 0 = clean, exit 1 = reported missing/failing/unexecuted lines. ANY
  # other rc - a signal death (128+n), the refusal arm, an unforeseen code -
  # means the check itself did not run, so it lands on pending and never on a
  # false "ok", whatever counts an empty output happens to grep to. The row
  # carries the counts alone and the base ref goes on its own legend line
  # whole: a long default branch would otherwise push the row past 80 columns,
  # and an elided ref would read as real while naming no ref that exists.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    MGATE_ANN="prior-tests: pending (check could not run, exit $rc)"
    MGATE_NAMEONLY=0
  elif [ "$missing" -gt 0 ] || [ "$failing" -gt 0 ]; then
    MGATE_BASE=$base
    MGATE_ANN="prior-tests: missing $missing / failing $failing !!"
  elif [ "$unexec" -gt 0 ]; then
    # Nothing missing or failing, but not everything ran: the row must say so
    # itself, never a bare "ok" - a green that means "these assertions were
    # never executed" reads as verified, which is worse than no result at all.
    MGATE_BASE=$base
    MGATE_ANN="prior-tests: missing 0 / failing 0 ($unexec unexecuted)"
  elif [ "$rc" -eq 0 ]; then
    MGATE_BASE=$base
    MGATE_ANN="prior-tests: missing 0 / failing 0 ok"
  else
    # rc=1 with every count zero: the check claims findings this viewer could
    # not read, so the honest render is pending, not a guess either way.
    MGATE_ANN="prior-tests: pending (result not readable)"
    MGATE_NAMEONLY=0
  fi
  clean_tmpd
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
CURRENT="" BANNER="" OUTCOME="" GATE="" RUN_ID="" RUN_PR="" BRANCH="" WT_GONE=0
F_TOTAL="" F_ASK=0 F_FIX=0 F_NOOP=0 FAILED_LOOP=0

probe() {
  CURRENT="" BANNER="" OUTCOME="" GATE="" RUN_ID="" RUN_PR="" WT_GONE=0
  F_TOTAL="" F_ASK=0 F_FIX=0 F_NOOP=0 FAILED_LOOP=0

  # Teardown is the last box in this very flow, so a worktree that disappears
  # mid-watch is an expected end state, not an anomaly. It has to be re-checked
  # per frame: `symbolic-ref` also answers empty for a directory that is gone,
  # which would otherwise be misreported as a detached HEAD. The header says so
  # too, rather than naming a HEAD state nothing ever observed.
  if [ ! -d "$WT" ]; then
    BRANCH=""
    WT_GONE=1
    BANNER="TORN DOWN: worktree removed - task cleaned up, static flow shown"
    return
  fi
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
    local where breakdown
    F_TOTAL=$(nm_findings_total)
    F_ASK=$(nm_action_count ask-user)
    F_FIX=$(nm_action_count auto-fix)
    F_NOOP=$(nm_action_count no-op)
    # A parked run whose gate name nothing resolves is named as such: an invented
    # "gate" would both claim a gate that does not exist and set a CURRENT that
    # matches no box, dropping the diagram's highlight in the very state the
    # captain most needs it. The highlight is simply left where the steps table
    # put it instead.
    if [ -n "$GATE" ]; then
      CURRENT=$GATE
      where="PARKED at $GATE gate"
    else
      CURRENT=$(nm_running_step)
      where="PARKED at an unnamed gate"
    fi
    # Zeros here would assert there are no findings when the truth is that none
    # could be read; only a findings[N] header or an explicit `findings: none`
    # makes the breakdown a fact worth printing.
    if [ -z "$F_TOTAL" ] && [ "$(strip_quotes "$(nm_field findings)")" = none ]; then
      F_TOTAL=0
    fi
    if [ -n "$F_TOTAL" ]; then
      breakdown="$F_TOTAL findings ($F_ASK ask-user, $F_FIX auto-fix, $F_NOOP no-op)"
    else
      breakdown="findings not readable from status"
    fi
    BANNER="$where: $breakdown"
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
      no-checks)
        CURRENT=mgate
        BANNER="CI: no checks reported - nothing verified - merge gate + captain next"
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

# Render height, bounded exactly the way width is: an explicit override, else
# the detected terminal height when stdout is a tty, else the hard 24-row
# default of a plain pane, so a non-tty frame is deterministic. A frame that
# overflows its pane scrolls its own header - the line naming the task, branch
# and run id - off the top, which is the one line the pane exists to show.
ROWS=24
if [ -n "${FM_NM_FLOW_ROWS:-}" ]; then
  case "$FM_NM_FLOW_ROWS" in
    *[!0-9]*) : ;;
    *) if [ "$FM_NM_FLOW_ROWS" -ge 10 ] && [ "$FM_NM_FLOW_ROWS" -le 1000 ]; then
         ROWS=$FM_NM_FLOW_ROWS
       fi ;;
  esac
elif [ "$TTY" = 1 ]; then
  TPUT_LINES=$(tput lines 2>/dev/null || true)
  case "$TPUT_LINES" in
    ''|*[!0-9]*) : ;;
    *) if [ "$TPUT_LINES" -ge 10 ] && [ "$TPUT_LINES" -le 1000 ]; then
         ROWS=$TPUT_LINES
       fi ;;
  esac
fi

RULE="------------------------------------------------------------------------------"

# A frame is assembled line by line before any of it is printed, because fitting
# it to the pane is a decision about the whole frame. Every line carries a rank:
# rank 0 is structure - the header, the banner, the PR line, the rules, the step
# rows, the fail loop - and is never dropped. A positive rank marks a legend
# line, and the lowest-ranked legends go first when the frame genuinely will not
# fit, so the run-specific claims (which base was compared, how much of it was
# name-only) outlive the fixed explanatory text. Any drop is stated on its own
# line: a legend that silently vanished would read as a legend that had nothing
# to say.
FRAME_LINES=()
FRAME_RANK=()
core_line() {  # <text>
  FRAME_LINES+=("$1")
  FRAME_RANK+=(0)
}
legend_line() {  # <rank> <text>
  FRAME_LINES+=("$2")
  FRAME_RANK+=("$1")
}

step_line() {  # <key> <label> <kind> <annotation>
  local key=$1 label=$2 kind=$3 ann=$4 rail=' | ' line
  line=$(printf '[ %-11s %-7s ]' "$label" "$kind")
  [ -n "$ann" ] && line="$line $ann"
  if [ "$key" = "$CURRENT" ]; then
    core_line ">> $REV$line$SGR0"
  else
    [ "$key" = teardown ] && rail=' v '
    core_line "$rail$line"
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
  [ "$WT_GONE" = 1 ] && tail=" | worktree removed"
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

# Terminal rows one frame line occupies: its visible length after stripping
# display attributes (the tput rev/bold/sgr0 sequences the highlight uses),
# divided across the render width. The PR URL is the line that makes this
# matter: it is never truncated, so past COLS it wraps, and a budget that
# counted frame LINES would claim a frame fits a pane it provably scrolls.
line_rows() {  # <line>
  local s=$1 esc=$'\033'
  while [[ $s =~ $esc\[[0-9\;]*[A-Za-z] ]]; do
    s=${s//"${BASH_REMATCH[0]}"/}
  done
  s=${s//"$esc(B"/}
  printf '%s' $(( ${#s} == 0 ? 1 : (${#s} - 1) / COLS + 1 ))
}

build_frame() {  # <mgate-annotation> <mgate-base> <mgate-nameonly-files>
  local ann=$1 mbase=$2 nameonly=$3
  FRAME_LINES=()
  FRAME_RANK=()
  core_line "$(header_line)"
  core_line "$BOLD$BANNER$SGR0"
  local pr="${RUN_PR:-$PR_URL}"
  [ -n "$pr" ] && core_line "PR: $pr"
  core_line "$RULE"
  step_line intent   intent       det       "goal the review judges against"
  step_line rebase   rebase       LLM       "!! LLM merge can drop base code; merge gate catches"
  step_line review   review       LLM       "gate: findings park run <--+"
  step_line test     test         "$KIND_TEST" "gate$(printf '%23s' '')|  fix round: pipeline"
  step_line document document     LLM       "gate$(printf '%23s' '')|  fixes, re-reviews step"
  step_line lint     lint         "$KIND_LINT" "gate ----------------------+"
  step_line push     push         det       ""
  step_line pr       "open PR"    det       ""
  step_line ci       "CI monitor" det+LLM   "!! LLM auto-rebase can drop base code; gate catches"
  step_line mgate    "merge gate" det       "$ann"
  step_line captain  captain      human     "explicit approval (or standing yolo)"
  step_line teardown teardown     det       "after landing confirmed"
  core_line "$RULE"
  legend_line 1 'outcomes: checks-passed=CI green, PR ready | passed=merged | failed | cancelled'
  if [ "$FAILED_LOOP" = 1 ]; then
    core_line ">> ${REV}fail loop: failed/cancelled -> commit fix on same branch -> rerun at intent$SGR0"
  else
    core_line '   fail loop: failed/cancelled -> commit fix on same branch -> rerun at intent'
  fi
  legend_line 2 'merge gate: check 1 base test names kept; check 2 base assertions vs branch'
  legend_line 3 'supersessions: captain-approved entries in data/supersessions/<project>.md'
  # The compared-base and name-only legends are the qualifiers of the result
  # the merge-gate row is showing, so while a result is up they rank as CORE:
  # a claim and its qualifiers must not be separable by any drop order a future
  # legend line could disturb. With no result up they are absent anyway.
  if [ -n "$mbase" ]; then
    core_line "prior-tests: compared against base $mbase"
  fi
  if [ "$nameonly" -gt 0 ]; then
    local noun=files
    [ "$nameonly" -eq 1 ] && noun='file'
    core_line "prior-tests: $nameonly base $noun verified by name only, not by assertion"
  fi
  if [ "$KIND_TEST" = 'det|LLM' ] || [ "$KIND_LINT" = 'det|LLM' ]; then
    legend_line 4 'det|LLM: commands.<step> not readable in .no-mistakes.yaml; det when it is set'
  fi
}

frame_core_rows() {
  local i rows=0
  for ((i = 0; i < ${#FRAME_LINES[@]}; i++)); do
    [ "${FRAME_RANK[$i]}" -eq 0 ] && rows=$((rows + $(line_rows "${FRAME_LINES[$i]}")))
  done
  printf '%s' "$rows"
}

render() {
  build_frame "$MGATE_ANN" "$MGATE_BASE" "$MGATE_NAMEONLY"
  # The backstop behind the undroppable qualifiers: a pane too short to carry
  # the result AND its qualifiers gets neither - the box degrades to a
  # non-committal pending form for the frame, so no pane size exists at which
  # a green shows up separated from what qualifies it. Watch mode only, like
  # the bound itself; the cached probe result is untouched for later frames.
  if [ "$WATCH" = 1 ] && [ -n "$MGATE_BASE" ] && [ "$(frame_core_rows)" -gt "$ROWS" ]; then
    build_frame "prior-tests: pending (pane too short for qualified result)" "" 0
  fi
  emit_frame
}

# Print the assembled frame. In watch mode, when its terminal-row footprint
# would overflow the pane, the lowest-ranked legend lines (and only legend
# lines) are dropped; kept lines stay in assembly order and the count dropped
# is stated where they were. A frame that does not fit even with every legend
# gone says so plainly - a "dropped to fit" notice on a frame that provably
# does not fit would be a claim the render cannot honor. The one-shot render
# prints everything: scrollback makes trimming pointless there.
emit_frame() {
  local n=${#FRAME_LINES[@]} i dropped=0 best bi
  local total=0 core=0 legend=0 avail short=0
  local -a drop_flag=() row_of=()
  for ((i = 0; i < n; i++)); do
    drop_flag[i]=0
    row_of[i]=$(line_rows "${FRAME_LINES[$i]}")
    total=$((total + row_of[i]))
    if [ "${FRAME_RANK[$i]}" -eq 0 ]; then
      core=$((core + row_of[i]))
    else
      legend=$((legend + row_of[i]))
    fi
  done
  if [ "$WATCH" = 1 ] && [ "$total" -gt "$ROWS" ]; then
    # One row is spent saying what was dropped, so nothing disappears silently.
    avail=$(( ROWS - core - 1 ))
    [ "$avail" -ge 0 ] || { avail=0; short=1; }
    for ((i = 0; i < n; i++)); do
      [ "${FRAME_RANK[$i]}" -eq 0 ] || { drop_flag[i]=1; dropped=$((dropped + 1)); }
    done
    while [ "$avail" -gt 0 ]; do
      best=0
      bi=-1
      for ((i = 0; i < n; i++)); do
        [ "${drop_flag[$i]}" -eq 1 ] || continue
        [ "${row_of[$i]}" -le "$avail" ] || continue
        if [ "${FRAME_RANK[$i]}" -gt "$best" ]; then
          best=${FRAME_RANK[$i]}
          bi=$i
        fi
      done
      [ "$bi" -ge 0 ] || break
      drop_flag[bi]=0
      dropped=$((dropped - 1))
      avail=$((avail - row_of[bi]))
    done
  fi
  for ((i = 0; i < n; i++)); do
    [ "${drop_flag[$i]}" -eq 0 ] && printf '%s\n' "${FRAME_LINES[$i]}"
  done
  if [ "$short" = 1 ]; then
    printf '!! frame needs %s rows; this %s-row pane will scroll it (%s legend lines dropped)\n' \
      "$core" "$ROWS" "$dropped"
  elif [ "$dropped" -gt 0 ]; then
    local noun=lines
    [ "$dropped" -eq 1 ] && noun=line
    printf '... %s legend %s dropped to fit a %s-row pane\n' "$dropped" "$noun" "$ROWS"
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

FRAMES=0
MAX_FRAMES=${FM_NM_FLOW_WATCH_MAX:-0}
case "$MAX_FRAMES" in ''|*[!0-9]*) MAX_FRAMES=0 ;; esac
while :; do
  OUT=$(frame)
  if [ "$TTY" = 1 ]; then
    # No trailing newline: it would advance past the last row and scroll a frame
    # that exactly fills the pane. The non-tty branch keeps its blank-line frame
    # separator, which is what the tests read frames back through.
    printf '\033[H\033[2J%s' "$OUT"
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
