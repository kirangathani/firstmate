#!/usr/bin/env bash
# The detached child of bin/fm-detach-lib.sh: run one firstmate command with the
# model already let go, then put its verdict where the next wake will carry it.
# Usage: FM_DETACH_LOG=<log-path> fm-detach-run.sh <script> [args...]
#
# NOT CALLED BY HAND. fm_detach forks this; its header owns why the reporting
# lives here rather than in an EXIT trap inside each script.
#
# WHAT IT REPORTS, AND WHY EACH SHAPE
# A detached command has no route to the model of its own, so silence from one is
# indistinguishable from success. That is the failure mode this file exists to
# prevent, and it is why every outcome writes a line through
# bin/fm-wake-pending.sh --result, which the arm prints on its way out
# (bin/fm-watch-arm.sh's print_pending_results_on_exit) and then clears.
#
#   success   the command's own verdict lines, selected not tailed, and NO log
#             path: there is nothing to chase, so a path would be noise on the
#             one outcome that happens most.
#   failure   one line naming the command, its exit code and its log, FOLLOWED by
#             the selected lines themselves. Firstmate then needs no read call to
#             know what went wrong, which is the same trick bin/fm-watch.sh plays
#             when it puts a crewmate's own words in the wake payload instead of
#             a pointer to the status file.
#   crash     the command died on a signal or an unset variable and printed no
#             verdict. The exit code and the log still go out, because the whole
#             point is that nothing fails silently.
#
# SELECTED, NEVER TAILED. A failed merge log carries gate and test output; a raw
# tail would put that in firstmate's context on every failure. FM_DETACH_SELECT
# is the extended regular expression that picks the verdict lines, defaulting to
# the union of the shapes these commands actually emit. The merge half of that
# default is the filter proved on the overnight background merges of
# 2026-09-16/17 (docs/background-bookkeeping.md section 4). Output is bounded the
# way bin/fm-watch.sh bounds crewmate text, and the log path is the fallback for
# whatever the selector drops.
#
# A COMMAND THAT DETACHES OWES THIS FILE ITS VERDICT SHAPES. Adding the detach
# call without adding the line prefixes it prints leaves the command silently
# reporting a bare `<name>: ok`, which is the same blind success this file exists
# to prevent. `teardown `, `Backlog: ` and `REFUSED` carry bin/fm-teardown.sh;
# `waived ` carries bin/fm-ci-waiver.sh; `armed:` carries bin/fm-pr-check.sh.
# `STALE BASE`/`PARKED BASE` carry bin/fm-stale-base.sh's findings wherever they
# surface - from bin/fm-fleet-sync.sh detached on its own, and from the same
# sweep running inline inside a detached bin/fm-teardown.sh.
#
# IT NEVER FAILS THE WORK. Every step of the reporting tolerates its own failure:
# a verdict that cannot be recorded must not change what the command did.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$#" -ge 1 ] || { echo "usage: FM_DETACH_LOG=<log> fm-detach-run.sh <script> [args...]" >&2; exit 2; }
LOG=${FM_DETACH_LOG:-}
TARGET=$1
shift

# This process owns the log, not the parent: the parent's descriptors are the
# harness's own tool-result pipe, which it is about to close, and a child still
# writing down it would take SIGPIPE - the exact death bin/fm-watch-arm.sh's
# detach exists to avoid.
[ -z "$LOG" ] || exec >"$LOG" 2>&1

NAME=$(basename "$TARGET" .sh)
MAX_LINES=${FM_DETACH_REPORT_MAX_LINES:-20}
SELECT=${FM_DETACH_SELECT:-'^(merged:|  (number|status):|fm-pr-merge-refusal:|error:|REFUSED|summary:|note: captain-approved|TESTING WAIVER|ATTESTATION CHECK EXEMPTED|BASE RE-VERIFICATION EXEMPTED|NO CI EVIDENCE|[^:]+: (STUCK|recovered|pruned):|next to land:|parked behind |write-failed:|armed:|spawned |teardown |waived |Backlog: |STALE BASE|PARKED BASE)'}

# FM_INLINE is what stops the target detaching again, and it is EXPORTED so a
# firstmate script the target calls in turn runs inline and hands back a true
# exit code rather than forking a second detached copy of itself.
export FM_INLINE=1
"$TARGET" "$@"
RC=$?

selected() {
  [ -r "$LOG" ] || return 0
  grep -aE "$SELECT" "$LOG" 2>/dev/null | tail -n "$MAX_LINES" || true
}

report() {
  local lines
  lines=$(selected)
  if [ "$RC" -eq 0 ]; then
    if [ -n "$lines" ]; then
      printf '%s\n' "$lines"
    else
      printf '%s: ok\n' "$NAME"
    fi
  else
    printf '%s: exit %s (log: %s)\n' "$NAME" "$RC" "$LOG"
    [ -z "$lines" ] || printf '%s\n' "$lines"
  fi
}

report | FM_HOME="${FM_HOME:-}" "$SCRIPT_DIR/fm-wake-pending.sh" --result 2>/dev/null || true
command rm -f -- "$LOG.stdin" 2>/dev/null || true
exit "$RC"
