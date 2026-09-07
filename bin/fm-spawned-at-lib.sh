#!/usr/bin/env bash
# fm_spawned_at: the ONE reader of when a task's worker started building, for
# every consumer that measures the implementation phase (bin/fm-flow-snapshot.sh's
# `building` step, bin/fm-timeline.sh's build_s).
#
# Three sources, in falling order of authority:
#   spawned_at=<epoch>  in state/<id>.meta - written by bin/fm-spawn.sh at the
#                       moment of dispatch. Authoritative: it is the only source
#                       that survives a later append to the meta file.
#   meta mtime          the fallback for a task dispatched before spawn recorded
#                       the field. Approximate: a meta appended to afterwards
#                       (pr= is appended at PR time) carries the later write.
#   status birth/mtime  the crewmate's first status append, taken when it is
#                       EARLIER than the meta mtime, because a meta that has been
#                       appended to since dispatch is later than the real start
#                       and the status file's creation is not.
#
# Nothing is invented: with no readable source this prints nothing, and the
# caller reports the phase as unknown rather than guessing a start.
fm_spawned_at() {  # <state-dir> <task-id> -> epoch seconds, or empty
  local state_dir=$1 id=$2 meta status t best=
  meta="$state_dir/$id.meta"
  status="$state_dir/$id.status"
  if [ -f "$meta" ]; then
    t=$(grep '^spawned_at=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    case "${t:-}" in
      ''|*[!0-9]*) t= ;;
    esac
    if [ -n "$t" ]; then
      printf '%s' "$t"
      return 0
    fi
  fi
  if [ -e "$meta" ]; then
    t=$(stat -c %Y "$meta" 2>/dev/null) || t=
    [ -z "$t" ] || best=$t
  fi
  if [ -e "$status" ]; then
    t=$(stat -c %W "$status" 2>/dev/null) || t=0
    [ "${t:-0}" -gt 0 ] 2>/dev/null || t=$(stat -c %Y "$status" 2>/dev/null) || t=
    if [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null; then
      if [ -z "$best" ] || [ "$t" -lt "$best" ]; then best=$t; fi
    fi
  fi
  printf '%s' "$best"
}
