# shellcheck shell=bash
# Self-detaching execution for firstmate's own bookkeeping commands.
# Usage: . bin/fm-detach-lib.sh   (after SCRIPT_DIR is resolved)
#        fm_detach "$@"          (as early as the script can usefully detach)
#
# WHY THIS EXISTS. A command that needs no model in the loop should not cost the
# model a turn waiting for it. Measured over 7401 calls between 2026-09-04 and
# 2026-09-17 (data/fm-foreground-audit-f9): 135 foreground merges at 16.7 s
# median, 73 s p90 and 391 s max, 103 teardowns, 140 spawns. PR #110 responded by
# INSTRUCTING firstmate to background these. The audit is the evidence that an
# instruction is followed most of the time: every one of those merges was issued
# in the foreground after the instruction existed.
#
# So the script decides, not the caller. fm_detach re-launches the SAME script
# with the SAME arguments, detached, and the foreground copy exits in about 6 ms
# having done nothing but fork. A process cannot make its parent stop waiting; it
# can only hand the work to a child and exit, which is how every daemon has ever
# backgrounded itself.
#
# WHY setsid, AND WHY THIS EXACT SHAPE. The child must outlive the harness task
# that launched it. Claude Code's low-memory reaper took 108 background tasks in
# those 13 days and zero Monitors, and 107 of the 108 were bin/fm-watch-arm.sh.
# Through every one of them the watcher that arm had launched SURVIVED, because
# bin/fm-watch-arm.sh starts it through setsid(1) in its own session and process
# group with its stdio off the task's pipe (see that script's header). This is
# the same shape, for the same reason. Job control is off in non-interactive
# bash, so setsid does not fork and the child is a direct child.
#
# WHY A RUNNER SCRIPT RATHER THAN AN EXIT TRAP. The verdict has to reach
# firstmate even when the work crashes, and the obvious way to guarantee that -
# an EXIT trap installed by this library - does not survive contact with the
# scripts it has to cover: bin/fm-pr-merge.sh sets its own EXIT trap at line 770
# and bin/fm-merge-green.sh at line 251, both AFTER the top of the file, so each
# would silently replace ours. Chaining is no better, because a script that gains
# a trap later reintroduces the bug with no signal. So the forked child is
# bin/fm-detach-run.sh, which runs the real script as an ordinary child and owns
# the reporting; the script's own traps are untouched and future ones cannot
# break it.
#
# WHAT THE CALLER GETS
#   FM_INLINE=1          run the body here and now, neither detaching nor
#                        lurking. Set by bin/fm-detach-run.sh for the work it
#                        runs, so a firstmate script called BY a detached script
#                        returns a true exit code to it (bin/fm-merge-green.sh
#                        reads bin/fm-pr-merge.sh's exit; bin/fm-ci-waiver.sh
#                        reads bin/fm-send.sh's). Also the test suite's baseline.
#   FM_DETACH_STDIN=1    set by the CALLER before fm_detach when the script reads
#                        its input from a pipe. The parent then spills stdin to a
#                        file and hands the child that file. It is opt-in because
#                        a foreground vehicle's stdin is a SOCKET, not /dev/null
#                        (measured 2026-09-17), so draining it unconditionally
#                        would block the parent of a script that reads no stdin.
#   FM_DETACH_LOG_DIR    override the log directory; defaults to $STATE/.detach.
#
# WHERE TO CALL IT. Wherever the script can usefully stop spending time - early
# for anything expensive, after the cheap argument checks where those are
# trivial. There is no uniform-placement rule; the point is to detach before the
# work starts, not to put the line on a particular row.

# Most recent logs to keep. A fleet lands on the order of 40 of these a day.
FM_DETACH_LOG_KEEP=${FM_DETACH_LOG_KEEP:-200}

# The absolute path of the top-level script that sourced this library.
# BASH_SOURCE's last element is the outermost caller, which is the script itself
# rather than any library between it and here.
fm_detach_self() {
  local top=${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]} dir base
  dir=$(cd "$(dirname "$top")" 2>/dev/null && pwd) || return 1
  base=$(basename "$top")
  printf '%s/%s\n' "$dir" "$base"
}

fm_detach_log_dir() {
  printf '%s\n' "${FM_DETACH_LOG_DIR:-${STATE:-${FM_HOME:-.}/state}/.detach}"
}

# Keep the newest FM_DETACH_LOG_KEEP logs. Never fails its caller: a log that
# could not be pruned is not a reason to refuse the work.
fm_detach_prune_logs() {
  local dir=$1 count
  count=$(find "$dir" -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l | tr -d '[:space:]')
  case $count in ''|*[!0-9]*) return 0 ;; esac
  [ "$count" -gt "$FM_DETACH_LOG_KEEP" ] || return 0
  find "$dir" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | head -n "$((count - FM_DETACH_LOG_KEEP))" \
    | cut -d' ' -f2- \
    | while IFS= read -r old; do command rm -f -- "$old" 2>/dev/null || true; done
  return 0
}

# Detach unless we ARE the detached work. Returns to the caller when the body
# should run here; otherwise forks and exits 0 without printing anything.
# The parent stays silent deliberately: the captain's rule is that a detached
# command costs firstmate nothing to read, and the child's own results line
# carries the log path on any outcome worth chasing.
fm_detach() {
  [ -z "${FM_INLINE:-}" ] || return 0

  local self dir log runner stdin_src=/dev/null setsid_bin
  self=$(fm_detach_self) || return 0
  runner="$(dirname "$self")/fm-detach-run.sh"
  # No runner means no way to report the verdict, and a detached command whose
  # result can never arrive is worse than a slow one. Run inline instead.
  [ -x "$runner" ] || return 0

  dir=$(fm_detach_log_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  log="$dir/$(basename "$self" .sh)-$(date +%s)-$$.log"
  fm_detach_prune_logs "$dir"

  if [ -n "${FM_DETACH_STDIN:-}" ]; then
    stdin_src="$log.stdin"
    cat > "$stdin_src" 2>/dev/null || true
  fi

  # Absent on macOS, where bin/fm-watch-arm.sh makes the same choice: keep going
  # without it rather than refuse to run at all.
  setsid_bin=$(command -v setsid 2>/dev/null || true)
  # FM_HOME goes across explicitly. Sibling scripts resolve it with
  # FM_HOME="${FM_HOME:-...}" and do not export it, so without this the child
  # would resolve a different home than the parent just did and record its
  # verdict where nothing is watching.
  if [ -n "$setsid_bin" ]; then
    FM_HOME="${FM_HOME:-}" FM_DETACH_LOG="$log" "$setsid_bin" "$runner" "$self" "$@" >"$log" 2>&1 <"$stdin_src" &
  else
    FM_HOME="${FM_HOME:-}" FM_DETACH_LOG="$log" "$runner" "$self" "$@" >"$log" 2>&1 <"$stdin_src" &
  fi
  exit 0
}
