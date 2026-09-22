#!/usr/bin/env bash
# The ONE owner of a project's landing-queue order: which task branch is at the
# head of the queue that bin/fm-merge-green.sh lands in, and therefore which one
# bin/fm-stale-base.sh reports as next to merge the base forward.
#
# Two consumers read it and neither keeps its own copy, because two copies drift
# the moment one is edited and the two scripts then disagree about which branch
# is next - which is exactly the bug this file was extracted to fix.
#
# THE ORDER. A branch carrying a recorded `pr=` is in the landing queue and
# sorts ahead of one that is not, because only a PR-bearing branch has been
# validated and has anything waiting on it to land. Within each rank the oldest
# dispatch is first, read through bin/fm-spawned-at-lib.sh, the one owner of
# when a task was dispatched; a record with no readable dispatch time sorts on 0.
# Ties are broken by task id by the caller's own sort, so the order is total and
# repeatable.
#
# The key is a fixed-width string rather than two fields so one plain `sort`
# orders it: rank, then a zero-padded epoch, both lexicographic.

# shellcheck source=bin/fm-spawned-at-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-spawned-at-lib.sh"

fm_landing_has_pr() {  # <state-dir> <task-id> -> 0 when the record carries a pr=
  local meta=$1/$2.meta
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  grep -q '^pr=' "$meta" 2>/dev/null
}

fm_landing_queue_key() {  # <state-dir> <task-id> -> "<rank>:<zero-padded epoch>"
  local rank=1 at
  fm_landing_has_pr "$1" "$2" && rank=0
  at=$(fm_spawned_at "$1" "$2")
  case "${at:-}" in ''|*[!0-9]*) at=0 ;; esac
  printf '%s:%010d' "$rank" "$at"
}
