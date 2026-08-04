#!/usr/bin/env bash
# Shared wall-clock bound for external calls that can hang (network-backed CLIs
# such as no-mistakes, gh, or treehouse).
#
# This library owns the bounder-selection ladder for new call sites adopting a
# bounded external call; reach for it rather than hand-rolling another ladder.
# It does not yet describe the whole repo: `fm-bearings-snapshot.sh`,
# `fm-watch-checkpoint.sh`, `fm-fleet-snapshot.sh`, and `fm-watch.sh` still
# carry their own inline timeout/gtimeout ladders, and migrating them is not
# mechanical (none has a perl arm today, `fm-watch.sh` uses `exec`, and
# `fm-watch-checkpoint.sh` captures a return code around redirections).
#
# GNU `timeout` is the first choice; macOS ships neither `timeout` nor
# `gtimeout` without coreutils, so `gtimeout` (Homebrew coreutils) and then
# `perl` (in the macOS base system) follow. The perl arm runs the child in its
# own process group and group-kills on SIGALRM, so a wedged child's own
# children die too, and exits 124 on expiry to match GNU timeout.
#
# Callers decide what a bounder-less host means for them, because the safe
# answer differs: skipping the call entirely, or running it unwrapped. Gate on
# fm_bounded_available before calling fm_bounded_run.
#
#   fm_bounded_available            -> 0 when some bounder exists, 1 when none
#   fm_bounded_run <secs> <cmd...>  -> runs <cmd...> bounded; exit 124 on expiry
#
# fm_bounded_run passes stdout/stderr through untouched; redirect at the call
# site. It returns 125 if invoked on a host with no bounder at all, which is a
# caller bug rather than a command result.

FM_BOUNDER=none
if command -v timeout >/dev/null 2>&1; then FM_BOUNDER=timeout
elif command -v gtimeout >/dev/null 2>&1; then FM_BOUNDER=gtimeout
elif command -v perl >/dev/null 2>&1; then FM_BOUNDER=perl
fi

fm_bounded_available() {
  [ "$FM_BOUNDER" != none ]
}

fm_bounded_run() {  # <secs> <cmd...>
  local secs=$1
  shift
  case "$FM_BOUNDER" in
    timeout)  timeout "$secs" "$@" ;;
    gtimeout) gtimeout "$secs" "$@" ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@" ;;
    *)        return 125 ;;
  esac
}
