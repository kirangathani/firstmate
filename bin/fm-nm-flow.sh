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
#                      show its counts in the merge-gate box, read from its
#                      `summary:` stdout line (per-line grep fallback).
#                      Whenever the box shows a result it names ALL SEVEN classes
#                      - miss / fail / unex / excu / skip / unac / unst - every
#                      render,
#                      INCLUDING the zeros. There is no ordering, threshold or
#                      non-zero test that can hide one behind another: a class
#                      folded into a sibling, or dropped because a louder sibling
#                      was non-zero, is a different lie in each direction, and the
#                      captain reading a live pane cannot tell a hidden count
#                      from an absent one. `skip` and `unac` are the check's own
#                      `skipped:` and `unaccounted:` classes: an identifier a
#                      green baseline run reported an explicit skip for, and one
#                      it produced no result for at all. NEITHER affects
#                      fm-assert-tests-kept.sh's exit code (its exit 0 means only
#                      that missing/failing/unexecuted are empty), so neither may
#                      be read off that exit code, and both mean the assertion was
#                      never verified. `unst` is the check's `unstable:` class:
#                      a base assertion whose own NAME changed between the
#                      check's two runs of the identical base file, so nothing
#                      could be compared over it. It DOES key the exit code, and
#                      like miss and fail it raises the row's `!!` flag, because
#                      it refuses a merge for every project.
#                      A class this run never EVALUATED renders as a dash, never
#                      as 0: never-checked and checked-and-clean are different
#                      facts and a captain cannot be asked to tell them apart from
#                      an identical `0`. Three paths reach it - excusal in explicit
#                      --worktree mode (no project, so no record to consult), a
#                      `summary:` line that carries no field for a class at all
#                      (a check with no concept of it, i.e. version skew: counting
#                      its absent finding lines would manufacture a 0 out of
#                      nothing), and stdout with no content at all (a check that
#                      printed nothing reads exactly like one that never ran, so
#                      counting its seven absent classes to seven zeros would
#                      manufacture the whole row). Finding LINES are positive
#                      evidence and are
#                      believed whenever present; only their absence proves
#                      nothing. A dash also suppresses `ok`, since `ok` asserts
#                      every class is an ESTABLISHED zero.
#                      `excused` is the identifiers the captain has already
#                      excused by a supersession entry. They are subtracted from
#                      their raw class and counted here instead, never folded
#                      into passing, failing or unexecuted. Excusal is resolved
#                      per identifier from the run's own finding lines, only in
#                      task-id mode (the record is keyed by project, and explicit
#                      --worktree mode knows no project, so no record is consulted
#                      at all there: every identifier stays in its raw class and
#                      the excused cell renders as a DASH, not as the 0 a run that
#                      really did read the record would show). Knowing the project
#                      and finding no record IS an evaluation, so that renders 0.
#                      Unexecuted findings
#                      are matched against the record only when
#                      data/exec-gate/<project> exists, mirroring the order
#                      bin/fm-pr-merge.sh applies its two policy layers in, so
#                      "excused" means exactly "a captain-approved entry covers
#                      this", never "this project does not gate that class".
#                      The row carries `!!` when miss or fail is non-zero, and
#                      `ok` ONLY when every one of the six counts is an
#                      established zero - it is derived from the COUNTS, never
#                      from the probe's exit status, and an unexecuted, excused,
#                      skipped, unaccounted or unevaluated class each suppress it
#                      on their own, because a green that means "nothing ran",
#                      "we decided not to look" or "we never checked" reads as
#                      verified, which is the one thing this display must never
#                      show.
#                      Fitting six counts into a plain 80-column row is done by
#                      LABELLING, never by dropping data: the row spends the
#                      `prior-tests: ` prefix (which every legend line below the
#                      diagram carries anyway) first, then the space between each
#                      label and its count, and only then lets the line wrap -
#                      it never spends a digit.
#                      Explicit mode never fetches, so the base may lag origin;
#                      it executes the base's own test files (check 2), so
#                      it costs real time - that is why it is opt-in, why the
#                      first watch frame renders the box as "checking..." and
#                      only frame 2 carries the result, why the probe is bounded
#                      by FM_NM_FLOW_TESTS_TIMEOUT (default 300s) and refuses to
#                      run at all when nothing on the host can bound it, and why
#                      three legend lines under the diagram qualify the result
#                      the row is showing: which base it compared against and
#                      that that base is a LOCAL ref this viewer deliberately
#                      never fetched (the merge gate refetches it, so the two can
#                      disagree); the DATE, time and pipeline step the snapshot
#                      was taken at (the probe runs ONCE per invocation, so every
#                      later watch frame re-renders that same point-in-time
#                      result, never a live verdict on current HEAD, and a bare
#                      clock reading would scan as this morning's on a pane left
#                      open overnight); and what the row's compact labels mean. A
#                      fourth names how many of the base's files that run could
#                      verify by name only (an identifier the probe reports as
#                      `unexecuted:` was verified by NAME ONLY). The box row
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
# Every other line that interpolates a value of a length this viewer does not
# control is bounded to the render width the same way, with the elision marked:
# the banner (which carries gate names, outcomes, statuses and branches read out
# of the run) and the merge-gate snapshot's step label. That is not tidiness -
# an overlong line wraps, costs the frame a row it was not budgeted, and the row
# budget answers by degrading the merge-gate box to pending, so an unbounded
# LABEL buys its own space with the six counts the captain opted in for. Labels
# shrink; data does not. The exceptions are the values a marked elision would
# not save - the branch, the run id, the PR URL, the base ref and the counts -
# which the captain reads to act on, and which wrap and are charged their real
# rows instead.
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
# The merge-gate result's qualifiers are structurally undroppable whenever the
# box shows one, and there are FOUR core lines at most: three that are always up
# with a result (the local-unfetched base, the snapshot stamp, the compact class
# legend) and the name-only line when any file was verified by name alone. They
# are deliberately packed into that count - the plain 80x24 pane is the hard
# constraint, the diagram plus banner plus PR line plus fail loop already spend
# 18 rows, and a fifth core qualifier would push a full result past the budget
# and degrade the box to pending, costing the captain the six counts they opted
# in for. Splitting one for readability means re-checking that arithmetic. When
# a pane is too short even for these, the box degrades to a pending form, so a
# green can never appear separated from its qualifiers at any pane size; when
# even the core lines cannot fit, the frame says so plainly instead of claiming
# it was made to fit.
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
# `no-mistakes axi logs`, `no-mistakes runs`, git ref reads, plain reads of the
# captain's supersession record and exec-gate marker, and (opt-in) the
# report-only fm-assert-tests-kept.sh explicit mode. It never responds to
# gates, never writes outside its own mktemp dir, and never mutates task state.
# The probe is run with FM_GUARD_READ_ONLY=1 AND FM_STATE_OVERRIDE pointed at
# the probe's own scratch dir for that last claim to be literally true.
# fm-assert-tests-kept.sh calls bin/fm-guard.sh unconditionally, and the guard
# in write mode creates, rewrites or deletes
# $FM_HOME/state/.guard-watcher-stale-banner (plus its lock). That is a fleet-
# state write, and worse, claiming the episode consumes the one-per-episode
# WATCHER DOWN banner into this viewer's discarded stderr, leaving the next
# genuinely guarded command with only the one-line reminder. Read-only mode
# reports the same lapse without claiming it. The state override covers what
# read-only mode does not: bin/fm-wake-lib.sh runs `mkdir -p "$STATE"` at
# SOURCE time, with no read-only branch, so a `--worktree <path> --tests-gate`
# run against a fresh FM_HOME would otherwise create its state/ directory.
# Redirecting STATE is safe precisely because the probe is always invoked in
# explicit --worktree mode, where fm-assert-tests-kept.sh never reads STATE at
# all (it resolves one only for a task id), and it confines any future guard
# state to a directory the EXIT trap deletes.
#
# Display classification, NEVER policy: bin/fm-pr-merge.sh is the single
# authority on whether a merge proceeds, and nothing here changes that. This
# viewer reads data/supersessions/<project>.md and data/exec-gate/<project> for
# ONE purpose - to show a deliberately-excused identifier under its own label
# instead of folding it into the passing, failing or unexecuted counts - and it
# reads that record through bin/fm-supersession-lib.sh, the same matcher the
# gate itself uses, so the two cannot drift. A future reader must not mistake
# this classification for the decision: the viewer never decides anything.
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

TITLE="" PR_URL="" PROJECT=""
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

# The captain's own records, addressed exactly as bin/fm-pr-merge.sh addresses
# them and read exactly as often as it does: never in explicit --worktree mode,
# where no project is known and therefore no entry can apply.
PROJ_NAME=""
[ -n "$PROJECT" ] && PROJ_NAME=$(basename "$PROJECT")
SUPERSESSIONS_FILE="$FM_HOME/data/supersessions/$PROJ_NAME.md"
EXEC_GATE_FILE="$FM_HOME/data/exec-gate/$PROJ_NAME"
# shellcheck source=bin/fm-supersession-lib.sh
. "$SCRIPT_DIR/fm-supersession-lib.sh" || {
  echo "fm-nm-flow.sh: cannot read $SCRIPT_DIR/fm-supersession-lib.sh" >&2
  exit 1
}

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
# it is perl's, not the shell's. The child runs detached in its own process
# group so the alarm can kill the whole tree - which also means a terminal
# Ctrl-C never reaches it on its own, so the parent must forward INT/TERM to
# the group the way timeout(1) does; without that the probe would outlive an
# interrupted viewer and keep running the base suite unbounded.
# shellcheck disable=SC2016
PERL_BOUND_PROG='my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } my $reap = sub { my ($sig, $rc) = @_; kill $sig, -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit $rc }; $SIG{INT} = sub { $reap->("INT", 130) }; $SIG{TERM} = sub { $reap->("TERM", 143) }; $SIG{ALRM} = sub { $reap->("TERM", 124) }; alarm $t; waitpid $pid, 0; my $sig = $? & 127; exit($sig ? 128 + $sig : $? >> 8)'
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
# The tests-gate probe alone goes through this background variant. A foreground
# command defers a trapped INT/TERM until it returns, and timeout(1) keeps the
# probe in its own process group where a terminal Ctrl-C never lands - so the
# viewer sat uninterruptible for the probe's whole bound on exactly the arm
# most hosts take (the perl arm forwards for itself). bash's `wait` IS
# interruptible by traps, so the probe runs as a background job whose pid the
# INT/TERM handler can reap explicitly. Each arm is a simple command, so $! is
# the bounding tool itself; the refusal arm still spawns nothing. The rc
# contract is run_bounded's exactly - `wait` reports 124 on expiry, 128+signal
# on a signal death, the child's own exit otherwise, and refusal still answers
# 125 - so the caller's MGATE_* handling reads the same verdicts from both.
PROBE_PID=""
run_bounded_bg() {  # <seconds> <cmd...>
  local secs=$1 rc=0
  shift
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$secs" "$@" & ;;
    gtimeout) gtimeout "$secs" "$@" & ;;
    perl)     perl -e "$PERL_BOUND_PROG" "$secs" "$@" & ;;
    *)        return "$BOUND_REFUSED_RC" ;;
  esac
  PROBE_PID=$!
  wait "$PROBE_PID" || rc=$?
  PROBE_PID=""
  return "$rc"
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

# Bound ONE variable-length value into a fixed-width line, always marking an
# elision so a shortened value can never be read as a whole one. Every core
# line that interpolates a value this viewer did not choose the length of goes
# through this, because an unbounded interpolation does not merely look untidy:
# past the render width the line wraps, the frame costs a row it was not
# budgeted, and the row budget answers by degrading the merge-gate box to
# pending - so the captain loses the six counts to make room for the prose that
# qualifies them, which is exactly backwards. LABELS are what this bounds.
# The values under an explicit never-truncate ruling - the branch, the run id,
# the PR URL, the base ref, and the counts themselves - are identifiers the
# captain reads to act on (paste, fetch, compare), where a marked elision is
# still useless, so those wrap instead and line_rows() charges the frame the
# rows they really take.
#
# Below four columns there is no room for both a value and its marker, so the
# marker wins: "something was elided here" is the honest reading, and a bare
# truncation that looks whole is the one outcome that must not happen.
clip() {  # <max-columns> <text>
  local max=$1 s=$2 dots='...'
  [ "$max" -le 0 ] && return 0
  [ "${#s}" -le "$max" ] && { printf '%s' "$s"; return 0; }
  [ "$max" -le 3 ] && { printf '%s' "${dots:0:$max}"; return 0; }
  printf '%s...' "${s:0:$((max - 3))}"
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
# When and where the single probe ran. The probe runs ONCE per invocation by
# design, so every watch frame after it re-renders the same numbers: the stamp
# is what keeps that from reading as a live verdict on whatever HEAD has become
# since.
MGATE_AT=""
MGATE_STEP=""
# The probe's scratch dir is the only thing this viewer ever writes, so its
# removal is owned by the EXIT trap alone: an interrupt lands mid-probe (the
# handler fires out of the `wait`) and exits past any cleanup left on the
# return paths, which would leak a directory per interrupted run. INT/TERM has
# exactly one handler for the whole script, set here once - a second,
# mode-specific trap would shadow this one and leave a dead handler a future
# reader assumes still runs. It TERMs the in-flight probe's tree so the job
# cannot outlive the viewer - TERM rather than the received signal, because
# bash starts background jobs with SIGINT ignored and that disposition can
# survive exec into parts of the probe's tree, while nothing in it ignores
# TERM - then converts the signal into an exit so the EXIT trap fires; 130 is
# the conventional interrupted status either mode reports.
#
# The whole DESCENDANT TREE is signalled, not just the bounding pid: TERM to
# timeout(1) is forwarded only to its own process group, and the probe nests a
# second timeout inside it (fm-assert-tests-kept.sh bounds each executed test
# file), which re-groups itself exactly like the outer one - so the group
# signal misses it and an interrupted viewer would orphan the base suite for
# that inner bound. The tree is collected first and signalled after, so a
# parent's death cannot reparent a child out of the sweep; each surviving
# timeout still forwards the TERM to its own child group, covering anything
# spawned between collect and kill. Without pgrep the bounding pid alone is
# the best effort a signal handler can make.
MGATE_TMPD=""
clean_tmpd() {
  [ -n "$MGATE_TMPD" ] && rm -rf "$MGATE_TMPD"
  MGATE_TMPD=""
}
kill_probe_tree() {  # <pid>
  local frontier=$1 pids=$1 p kids next
  if command -v pgrep >/dev/null 2>&1; then
    while [ -n "$frontier" ]; do
      next=""
      for p in $frontier; do
        kids=$(pgrep -P "$p" 2>/dev/null || true)
        [ -n "$kids" ] && next="$next $kids"
      done
      [ -n "$next" ] && pids="$pids $next"
      frontier=$next
    done
  fi
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
}
on_int_term() {
  [ -n "$PROBE_PID" ] && kill_probe_tree "$PROBE_PID"
  exit 130
}
trap clean_tmpd EXIT
trap on_int_term INT TERM
# Per-identifier excusal, for DISPLAY ONLY. Each finding line the probe wrote
# is matched against the captain's record through the shared grammar owner
# (bin/fm-supersession-lib.sh), so this viewer and bin/fm-pr-merge.sh cannot
# answer "is this covered?" differently. The two policy layers are applied in
# the gate's own order: an unexecuted finding is only matched when the project
# carries the exec-gate marker, exactly as the gate does, so "excused" here
# always means "a captain-approved entry covers this identifier" and never
# "this project does not gate that class" - two different facts that must not
# share a label. Warnings about malformed entries go to the gate's operator,
# not to a viewer pane, so they are discarded here; a malformed entry fails
# closed either way, which leaves the identifier in its raw class.
#
# Sets EX_MISSING/EX_FAILING/EX_UNEXEC/EX_UNSTABLE (excused per class),
# SEEN_MISSING/SEEN_FAILING/SEEN_UNEXEC/SEEN_UNSTABLE (findings actually parsed per class,
# used only as a floor under the summary counts so an excusal can never
# subtract more than was counted), and EX_EVAL: whether the excused class was
# EVALUATED at all. Knowing the project and finding no record is an evaluation
# - no entry exists, so nothing is excusable and the count is a real zero.
# Explicit --worktree mode is not: the record is keyed by project, so with no
# project there is no record to consult and the honest answer is "not checked",
# which the row renders as a dash rather than a zero it did not establish.
EX_MISSING=0 EX_FAILING=0 EX_UNEXEC=0 EX_UNSTABLE=0
SEEN_MISSING=0 SEEN_FAILING=0 SEEN_UNEXEC=0 SEEN_UNSTABLE=0
EX_EVAL=0
classify_excused() {  # <findings-file>
  local line ident cls exec_gated=0
  EX_MISSING=0 EX_FAILING=0 EX_UNEXEC=0 EX_UNSTABLE=0
  SEEN_MISSING=0 SEEN_FAILING=0 SEEN_UNEXEC=0 SEEN_UNSTABLE=0
  EX_EVAL=0
  [ -n "$PROJ_NAME" ] || return 0
  EX_EVAL=1
  [ -f "$SUPERSESSIONS_FILE" ] || return 0
  [ -e "$EXEC_GATE_FILE" ] && exec_gated=1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'missing: '*)    cls=missing    ; ident=${line#missing: }    ; SEEN_MISSING=$((SEEN_MISSING + 1)) ;;
      'failing: '*)    cls=failing    ; ident=${line#failing: }    ; SEEN_FAILING=$((SEEN_FAILING + 1)) ;;
      'unexecuted: '*) cls=unexecuted ; ident=${line#unexecuted: } ; SEEN_UNEXEC=$((SEEN_UNEXEC + 1)) ;;
      'unstable: '*)   cls=unstable   ; ident=${line#unstable: }   ; SEEN_UNSTABLE=$((SEEN_UNSTABLE + 1)) ;;
      *) continue ;;
    esac
    if [ "$cls" = unexecuted ] && [ "$exec_gated" -eq 0 ]; then
      continue
    fi
    if fm_supersession_approved "$SUPERSESSIONS_FILE" "$PROJ_NAME" "$ident" "$cls" 2>/dev/null; then
      case "$cls" in
        missing)    EX_MISSING=$((EX_MISSING + 1)) ;;
        failing)    EX_FAILING=$((EX_FAILING + 1)) ;;
        unexecuted) EX_UNEXEC=$((EX_UNEXEC + 1)) ;;
        unstable)   EX_UNSTABLE=$((EX_UNSTABLE + 1)) ;;
      esac
    fi
  done < "$1"
  return 0
}

# A cell is positive: numeric and above zero. A dash (a class this run never
# evaluated) is neither positive nor an established zero, so it answers no to
# this and no to the all-zero test below - it can neither raise the alarm nor
# leave a green.
mgate_pos() {  # <cell>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ]
}

# The counts row: all six classes, every time, zeros included. The only thing
# that varies with the numbers is how much LABELLING fits around them - the
# counts themselves are never truncated and never left out, because a captain
# reading a live pane cannot distinguish a count that was hidden from a class
# that had nothing to report. The labels are already compact and tightly
# separated; the row spends the `prior-tests: ` prefix, which every legend line
# under the diagram carries anyway, before it spends a digit.
#
# `!!` marks unexcused missing/failing/unstable work - unstable joins them
# because it refuses a merge for every project, with no per-project opt-in to
# soften it. `ok` is derived from the CELLS alone and never from the probe's exit
# status: fm-assert-tests-kept.sh exits 0 whenever missing/failing/unexecuted and
# unstable are empty, which says nothing at all about the skipped and unaccounted
# identifiers it also reports, and `unaccounted` means a base assertion a green
# baseline run produced no result for - never verified. So `ok` requires every one
# of the seven to be an established zero: an unexecuted, excused, skipped,
# unaccounted, unstable or never-evaluated class each suppress it alone.
mgate_counts_ann() {  # <missing> <failing> <unexec> <excused> <skipped> <unaccounted> <unstable>
  local v flag='' zero=1 spaced tight shortest body limit=$((COLS - 27))
  for v in "$@"; do
    [ "$v" = 0 ] || zero=0
  done
  if mgate_pos "$1" || mgate_pos "$2" || mgate_pos "$7"; then
    flag=' !!'
  elif [ "$zero" -eq 1 ]; then
    flag=' ok'
  fi
  # The ladder, widest first, every rung carrying all seven counts whole: the
  # `prior-tests: ` prefix goes first (every legend line under the diagram
  # carries it anyway), then the space between each label and its count, then
  # the labels' last letter. Only LABELLING is ever spent, and every rung's
  # labels stay recognizable prefixes of the legend's own `excu/skip/unac/unst`
  # spellings. A magnitude that outgrows even the shortest form is left to wrap -
  # the row budget charges the rows a wrapped line really takes - because a count
  # the captain cannot read at all is worse than a line that runs on.
  spaced="miss $1/fail $2/unex $3/excu $4/skip $5/unac $6/unst $7$flag"
  tight="miss$1/fail$2/unex$3/excu$4/skip$5/unac$6/unst$7$flag"
  shortest="mis$1/fal$2/unx$3/exc$4/skp$5/una$6/uns$7$flag"
  for body in "prior-tests: $spaced" "$spaced" "$tight" "$shortest"; do
    if [ "${#body}" -le "$limit" ]; then
      printf '%s' "$body"
      return
    fi
  done
  printf '%s' "$shortest"
}

# One class cell out of the probe's output: a count, or `-` for a class this
# run has no evidence about either way.
#
# With a `summary:` line up, that line is the check's own statement of what it
# measured. A field it does NOT carry is a check that has no concept of the
# class (version skew), and grep-counting that class's finding lines would then
# manufacture a 0 out of their absence - the never-evaluated-versus-clean
# conflation this viewer exists to prevent, arriving through the parse layer. So
# an absent field is `-`, not 0. Finding LINES for the class are still positive
# evidence and are believed when present; only their absence proves nothing.
#
# With no summary line at all, every class is being read the same way, off the
# finding lines, so a 0 there is a real reading of the whole output - PROVIDED
# the CHECK ITSELF said something. Output the check did not produce is not a
# reading of anything: every grep answers 0, and the row would go out with a full
# set of established zeros and an `ok` derived from zero positive evidence, which is
# the same manufactured green an absent summary field already refuses to
# produce. So the question is not "was there any output" but "is any of it
# shaped like this check's contract" - the probe inherits other scripts' stdout
# (fm-assert-tests-kept.sh runs bin/fm-guard.sh unredirected, and the guard's
# banners print there), and foreign lines say nothing about any class. Anything
# short of one contract line and every class renders as a dash and takes the
# green with it.
mgate_field() {  # <class> <summary-line> <stdout-file>
  local v='' n
  if [ -n "$2" ]; then
    v=$(printf '%s' "$2" | sed -n "s/.*[[:space:]]$1=\([0-9]\{1,\}\).*/\1/p")
    if [ -z "$v" ]; then
      n=$(grep -c "^$1: " "$3" || true)
      if [ "${n:-0}" -gt 0 ]; then v=$n; else v='-'; fi
    fi
  elif grep -qE '^(summary|missing|failing|unexecuted|skipped|unaccounted|unstable): ' \
    "$3" 2>/dev/null; then
    v=$(grep -c "^$1: " "$3" || true)
    v=${v:-0}
  else
    v='-'
  fi
  printf '%s' "$v"
}

# The arithmetic view of a cell: a dash contributes nothing, so a class with no
# evidence can neither raise nor lower a count derived from the others.
mgate_num() {  # <cell>
  case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# The pipeline step the snapshot was taken at, named the way its box is: the
# captain reads the stamp against the diagram above it. The box labels differ
# from the internal step keys for three steps, so they are mapped rather than
# printed raw. CURRENT is only meaningful in the shell `probe` last ran in, so
# every caller must resolve this where that assignment is visible - a step read
# out of a stale or unset CURRENT would stamp "an unknown step" forever while
# looking exactly like a run whose step genuinely could not be read.
mgate_step_label() {
  case "$CURRENT" in
    '')      printf 'an unknown step' ;;
    pr)      printf 'step open PR' ;;
    ci)      printf 'step CI monitor' ;;
    mgate)   printf 'step merge gate' ;;
    *)       printf 'step %s' "$CURRENT" ;;
  esac
}

run_tests_gate() {
  local base out_file missing failing unexec excused skipped unacct unstable summary
  MGATE_BASE=""
  # Date AND time: a pane left open overnight would otherwise stamp a bare
  # clock reading that scans as this morning's, which is exactly the age at
  # which the staleness matters most.
  MGATE_AT=$(date '+%m-%d %H:%M' 2>/dev/null || true)
  MGATE_STEP=$(mgate_step_label)
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
  # TWO mechanisms hold this viewer's read-only claim up, and NEITHER is
  # sufficient alone - do not trim one as belt-and-braces for the other, because
  # each covers a write the other misses. FM_GUARD_READ_ONLY=1 covers the guard:
  # the probe calls bin/fm-guard.sh unconditionally, and the guard writes fleet
  # state (and consumes the one-per-episode WATCHER DOWN banner) unless told it
  # is a read-only caller. FM_STATE_OVERRIDE covers the write read-only mode does
  # NOT reach - bin/fm-wake-lib.sh's unconditional source-time
  # `mkdir -p "$STATE"`, which runs before any read-only branch can be consulted
  # - by pointing STATE at this probe's scratch dir, which the EXIT trap removes;
  # the probe runs in explicit --worktree mode, which never resolves a task's
  # meta, so nothing it needs lives under STATE. Both go
  # through `env` so they apply to the probe's tree alone and never leak into
  # this shell or a later frame's calls; `env` execs the probe, so the bounding
  # tool's own pid and exit-status contract are unchanged.
  run_bounded_bg "$TESTS_TIMEOUT" env FM_GUARD_READ_ONLY=1 \
    FM_STATE_OVERRIDE="$tmpd/state" \
    "$SCRIPT_DIR/fm-assert-tests-kept.sh" \
    --worktree "$WT" --base "$base" > "$out_file" 2>"$tmpd/kept.err" || rc=$?
  if [ "$rc" -eq 124 ]; then
    MGATE_ANN="prior-tests: pending (probe timed out after ${TESTS_TIMEOUT}s)"
    MGATE_NAMEONLY=0
    clean_tmpd
    return
  fi
  # Counts come from the machine-readable `summary:` stdout line; the per-line
  # greps are only the fallback for an output that carries no summary. All SIX
  # reported classes are read, not just the ones the check's exit status keys
  # on: `skipped:` and `unaccounted:` leave the exit status at 0, and an
  # unaccounted identifier is one a green baseline run produced no result for at
  # all, so reading only the exit-status classes would let the row show a green
  # over an assertion that was never verified. The unexecuted count is per
  # ASSERTION: each `unexecuted:` identifier was verified by NAME ONLY (check 1),
  # so a kept-name test whose assertion body was rewritten would not be caught.
  summary=$(grep -m1 '^summary: ' "$out_file" || true)
  missing=$(mgate_field missing "$summary" "$out_file")
  failing=$(mgate_field failing "$summary" "$out_file")
  unexec=$(mgate_field unexecuted "$summary" "$out_file")
  skipped=$(mgate_field skipped "$summary" "$out_file")
  unacct=$(mgate_field unaccounted "$summary" "$out_file")
  unstable=$(mgate_field unstable "$summary" "$out_file")
  # An excused identifier leaves its raw class and is counted on its own, so
  # the captain sees what is being deliberately excused instead of it hiding
  # inside a pass, a failure or a not-run. The parsed per-class tally is used as
  # a floor first: excusal may only ever subtract findings that were counted, so
  # a summary line and the finding lines disagreeing can never drive a class
  # count below what was actually excused (a negative would read as green).
  # A class with no evidence stays a dash through all of this: its floor is 0
  # by construction (a finding line for it would have made it a count), so the
  # excusal arithmetic has nothing to move and must not turn it into a number.
  classify_excused "$out_file"
  if [ "$missing" != '-' ]; then
    [ "$SEEN_MISSING" -gt "$missing" ] && missing=$SEEN_MISSING
    missing=$((missing - EX_MISSING))
    [ "$missing" -lt 0 ] && missing=0
  fi
  if [ "$failing" != '-' ]; then
    [ "$SEEN_FAILING" -gt "$failing" ] && failing=$SEEN_FAILING
    failing=$((failing - EX_FAILING))
    [ "$failing" -lt 0 ] && failing=0
  fi
  if [ "$unexec" != '-' ]; then
    [ "$SEEN_UNEXEC" -gt "$unexec" ] && unexec=$SEEN_UNEXEC
    unexec=$((unexec - EX_UNEXEC))
    [ "$unexec" -lt 0 ] && unexec=0
  fi
  if [ "$unstable" != '-' ]; then
    [ "$SEEN_UNSTABLE" -gt "$unstable" ] && unstable=$SEEN_UNSTABLE
    unstable=$((unstable - EX_UNSTABLE))
    [ "$unstable" -lt 0 ] && unstable=0
  fi
  excused=$((EX_MISSING + EX_FAILING + EX_UNEXEC + EX_UNSTABLE))
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
  elif [ "$rc" -eq 1 ] && \
    [ $(( $(mgate_num "$missing") + $(mgate_num "$failing") \
          + $(mgate_num "$unexec") + $(mgate_num "$unstable") + excused )) -eq 0 ]; then
    # rc=1 with nothing read out of the four classes rc=1 is keyed on (excused
    # included, since every excused identifier came out of one of those four):
    # the check claims findings this viewer could not read, so the honest render
    # is pending, not a guess either way. skipped and unaccounted are deliberately
    # NOT summed here - both are reported at rc=0 too, so neither can turn an
    # unreadable rc=1 result into a readable one. This is a "no result to show"
    # branch, not a visibility one: it never hides a count that was read.
    MGATE_ANN="prior-tests: pending (result not readable)"
    MGATE_NAMEONLY=0
  else
    # The one result branch there is. Every class it read goes on the row,
    # zeros included, so no ordering between them can exist to hide one, and a
    # class nothing was consulted for goes on as a dash rather than borrowing
    # the appearance of a zero somebody established.
    local d_excused=$excused
    [ "$EX_EVAL" -eq 0 ] && d_excused='-'
    MGATE_BASE=$base
    MGATE_ANN=$(mgate_counts_ann "$missing" "$failing" "$unexec" "$d_excused" \
      "$skipped" "$unacct" "$unstable")
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
    # A parked run whose gate name nothing resolves is named as such: an invented
    # "gate" would both claim a gate that does not exist and set a CURRENT that
    # matches no box, dropping the diagram's highlight in the very state the
    # captain most needs it. The highlight is simply left where the steps table
    # put it instead.
    #
    # The gate NAME is the only unbounded part of this banner, and it is the
    # label half of it: the breakdown is the data the captain is reading, so the
    # name shrinks around the breakdown rather than the other way round, and it
    # is bounded here rather than by the whole-line clip in build_frame so that a
    # long name costs its own characters and never the counts behind it. The
    # fixed text it shares the line with is "PARKED at " and " gate: " - 17
    # columns, spelled out in the arithmetic so a reword cannot silently
    # invalidate it. CURRENT keeps the name WHOLE: it is matched against step
    # keys, not printed.
    if [ -n "$GATE" ]; then
      local lead="PARKED at " mid=" gate: "
      CURRENT=$GATE
      where="$lead$(clip $((COLS - ${#lead} - ${#mid} - ${#breakdown})) "$GATE") gate"
    else
      CURRENT=$(nm_running_step)
      where="PARKED at an unnamed gate"
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
  FRAME_MEASURED=0
  core_line "$(header_line)"
  # Every banner interpolates something read out of the run - a gate name, an
  # outcome, a status, a branch, a coarse runs-list column - and none of those
  # has a length this viewer controls. Bounding the assembled banner once here
  # is what makes that structural: a banner added later is bounded by
  # construction rather than by its author remembering to. Each banner puts its
  # fixed prose last, so this clip spends that prose and never the value; the
  # one banner whose data sits after a variable label (the parked gate's
  # findings breakdown) bounds the label itself in probe(), before it gets here.
  # The branch is not truncated where the captain reads it to act - the header
  # carries it whole one line up.
  core_line "$BOLD$(clip "$COLS" "$BANNER")$SGR0"
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
  # Everything that qualifies the merge-gate result ranks as CORE while a result
  # is up: a claim and its qualifiers must not be separable by any drop order a
  # future legend line could disturb. With no result up they are absent anyway.
  # None of them is conditional on a count being non-zero - a legend that
  # appeared only when its class fired would let the row's quietest reading, the
  # all-zero one, go out unqualified.
  #
  # THREE lines carry all of it, and the count is load-bearing: every core line
  # here is a row the plain 80x24 pane cannot spend on the diagram, and the six
  # counts outrank the prose that qualifies them. Do not split one of these into
  # two for readability without re-checking the 24-row budget in render().
  if [ -n "$mbase" ]; then
    # The base is whatever refs/remotes/origin/HEAD points at LOCALLY: this
    # viewer deliberately never fetches (that is what keeps it read-only and
    # cheap), so the ref can be a day stale while the row reads as agreement
    # with current main. The gate refetches, so the two can disagree and this
    # row is never proof the merge will be allowed.
    core_line "prior-tests: base $mbase: LOCAL, never fetched; the gate refetches it"
    # The probe runs once per invocation, so in watch mode this same result is
    # re-rendered for every later frame while the pipeline keeps committing.
    # Stamping the date, the time and the step it was taken at is what stops an
    # hours-old green from reading as a live verdict on current HEAD.
    #
    # The stamp keeps its explicit fallback: MGATE_AT's assignment tolerates
    # `date` failing, and this is the one line whose whole job is to make a
    # stale result self-evidently stale, so a blank where the age belongs is the
    # qualifier silently failing at exactly its own task. Name the gap instead.
    #
    # The step label is the variable part, and in the parked-gate path it is the
    # gate name, which nothing bounds at the source. It is clipped against what
    # the surrounding sentence actually leaves, measured from the strings
    # themselves rather than a constant, so rewording either half cannot quietly
    # push this line past the render width - and a line past the width wraps,
    # costs the frame an unbudgeted row, and gets the box degraded to pending,
    # taking the seven counts with it.
    local snap_pre="prior-tests: snapshot ${MGATE_AT:-unknown time} at "
    local snap_post="; not re-checked since"
    core_line "$snap_pre$(clip $((COLS - ${#snap_pre} - ${#snap_post})) "$MGATE_STEP")$snap_post"
    # The row's compact labels, spelled out in one line: "excu" is a category of
    # its own rather than any of the other six, skip and unac are assertions
    # nothing verified rather than assertions that passed, unst is an assertion
    # whose own name moved so nothing could be compared, and a dash is a class
    # with no evidence either way rather than an established zero.
    core_line "prior-tests: excu/skip/unac/unst=not a pass; excu=captain-excused; -=unchecked"
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

# The frame's one measurement pass: per-line terminal rows into FRAME_ROWS,
# with the core and total footprints derived from it. Both the pane-too-short
# backstop and the drop loop need the same numbers, so it is computed once per
# assembled frame and invalidated by build_frame - measuring twice cost a
# command substitution per line per frame and left two loops to keep in step.
CORE_ROWS=0 TOTAL_ROWS=0 FRAME_MEASURED=0
FRAME_ROWS=()
frame_measure() {
  local i r
  [ "$FRAME_MEASURED" -eq 1 ] && return 0
  CORE_ROWS=0
  TOTAL_ROWS=0
  FRAME_ROWS=()
  for ((i = 0; i < ${#FRAME_LINES[@]}; i++)); do
    r=$(line_rows "${FRAME_LINES[$i]}")
    FRAME_ROWS+=("$r")
    TOTAL_ROWS=$((TOTAL_ROWS + r))
    [ "${FRAME_RANK[$i]}" -eq 0 ] && CORE_ROWS=$((CORE_ROWS + r))
  done
  FRAME_MEASURED=1
}

render() {
  build_frame "$MGATE_ANN" "$MGATE_BASE" "$MGATE_NAMEONLY"
  # The backstop behind the undroppable qualifiers: a pane too short to carry
  # the result, its qualifiers AND the mandatory drop notice gets none of them
  # - the box degrades to a non-committal pending form for the frame, so no
  # pane size exists at which a green shows up separated from what qualifies
  # it. Watch mode only, like the bound itself; the cached probe result is
  # untouched for later frames. The notice row is part of the test: a frame
  # that fits whole needs no notice, and one that must drop legends spends a
  # row saying so.
  if [ "$WATCH" = 1 ] && [ -n "$MGATE_BASE" ]; then
    frame_measure
    if [ "$TOTAL_ROWS" -gt "$ROWS" ] && [ $((CORE_ROWS + 1)) -gt "$ROWS" ]; then
      build_frame "prior-tests: pending (pane too short to qualify)" "" 0
    fi
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
  local total core avail short=0
  local -a drop_flag=()
  frame_measure
  total=$TOTAL_ROWS
  core=$CORE_ROWS
  for ((i = 0; i < n; i++)); do
    drop_flag[i]=0
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
        [ "${FRAME_ROWS[$i]}" -le "$avail" ] || continue
        if [ "${FRAME_RANK[$i]}" -gt "$best" ]; then
          best=${FRAME_RANK[$i]}
          bi=$i
        fi
      done
      [ "$bi" -ge 0 ] || break
      drop_flag[bi]=0
      dropped=$((dropped - 1))
      avail=$((avail - FRAME_ROWS[bi]))
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

# The run state is classified in THIS shell in both modes, never inside the
# command substitution that captures a frame: a subshell's assignments die with
# it, so a `probe` run in there leaves CURRENT empty out here and the merge-gate
# snapshot would stamp "an unknown step" on every frame forever. Only the
# rendering is captured.
if [ "$WATCH" = 0 ]; then
  probe
  [ "$TESTS_GATE_PENDING" = 1 ] && run_tests_gate
  render
  exit 0
fi

FRAMES=0
MAX_FRAMES=${FM_NM_FLOW_WATCH_MAX:-0}
case "$MAX_FRAMES" in ''|*[!0-9]*) MAX_FRAMES=0 ;; esac
while :; do
  probe
  OUT=$(render)
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
