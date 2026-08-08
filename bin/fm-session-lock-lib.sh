#!/usr/bin/env bash
# Single owner of firstmate SESSION-LOCK ownership resolution.
#
# state/.lock is the SESSION lock: it records the harness process of the one
# firstmate session that controls this home's fleet.
# state/.watch.lock is a different lock with a confusingly similar name: it is
# the watcher singleton (a symlink to an owner directory) owned by
# bin/fm-wake-lib.sh, and it only decides which PROCESS is the single watcher.
# Nothing in this file reads, writes, or reasons about the watcher singleton.
# Conflating the two has already produced one wrong analysis; keep them apart.
#
# Every caller that must answer "does THIS process's session control the fleet?"
# resolves it here and nowhere else: bin/fm-lock.sh (including its `ownership`
# subcommand, which is how the OpenCode and Pi adapters ask), bin/fm-watch-arm.sh,
# bin/fm-turnend-guard.sh, bin/fm-sessionstart-nudge.sh, and bin/fm-statusline.sh.
# Four near-identical private copies of this walk are what let the Claude path
# drift into arming a watcher for a home a different session owned.
#
# Sourcing has no side effects: no state directory is created, nothing is
# written, and no lock is acquired.

# Ownership is resolved by ANCESTRY, never by the immediate parent: a watcher
# sits at least three shell levels below its session (verified live:
# watcher <- bash <- bash <- claude), so a parent-only check would fail for every
# harness. Eight parents is the depth the adapters and docs/sessionstart-nudge.md
# already record.
FM_SESSION_LOCK_ANCESTRY_DEPTH=8

# Known harness command names; extend when a new adapter is verified.
FM_SESSION_HARNESS_RE='claude|codex|opencode|grok|^pi$'

# One parent hop. Prints the parent pid, or fails at pid 1, an unknown pid, or
# any unparseable ps output.
fm_pid_parent() {
  local pid=$1 parent
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  case "$parent" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$parent" -gt 1 ] || return 1
  printf '%s\n' "$parent"
}

# True when $1 is $2 (default: this script's own pid) or one of its ancestors,
# walking at most $3 (default FM_SESSION_LOCK_ANCESTRY_DEPTH) parents.
fm_pid_ancestry_contains() {
  local target=$1 pid=${2:-$$} depth=${3:-$FM_SESSION_LOCK_ANCESTRY_DEPTH} i=0
  case "$target" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "$i" -lt "$depth" ]; do
    [ "$pid" = "$target" ] && return 0
    pid=$(fm_pid_parent "$pid") || return 1
    i=$((i + 1))
  done
  [ "$pid" = "$target" ]
}

# The pid recorded in $1/.lock, or failure when the lock is absent, unreadable,
# empty, non-numeric, or names pid 0/1 (never a real harness).
fm_session_lock_holder() {
  local state=$1 pid=
  # stderr is redirected BEFORE the input redirect: redirections apply left to
  # right, so a trailing 2>/dev/null would arrive too late to swallow the open
  # failure for an absent lock (the same trap bin/fm-wake-lib.sh documents).
  IFS= read -r pid 2>/dev/null < "$state/.lock" || return 1
  pid=${pid//[[:space:]]/}
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

# Resolve this process's relationship to the session lock in state dir $1,
# starting the ancestry walk at $2 (default: this script's own pid). Always
# exits 0 and prints exactly one word:
#   owned   - the recorded holder is this process or one of its ancestors
#   other   - a different, still-live session holds the lock
#   missing - no lock, an unreadable or malformed lock, or a dead holder
# Liveness here is a bare kill -0 on purpose: requiring the holder to look like a
# harness would let a recycled pid be read as a live rival forever.
fm_session_lock_ownership() {
  local state=$1 start=${2:-$$} holder
  holder=$(fm_session_lock_holder "$state") || { printf 'missing\n'; return 0; }
  if fm_pid_ancestry_contains "$holder" "$start"; then
    printf 'owned\n'
    return 0
  fi
  if kill -0 "$holder" 2>/dev/null; then
    printf 'other\n'
  else
    printf 'missing\n'
  fi
}

# Convenience predicate for callers that only care about the owned case.
fm_session_lock_owned() {
  [ "$(fm_session_lock_ownership "$@")" = owned ]
}

# --- acquisition-side helpers (bin/fm-lock.sh) -------------------------------
# Acquiring writes the HARNESS pid found by walking the shell's ancestry, which
# lives as long as the firstmate session - unlike the transient subshell pid of
# any one tool call, which is dead moments after it is written.

fm_session_harness_pid() {
  local pid=${1:-$$} comm args i=0
  while [ "$i" -lt "$FM_SESSION_LOCK_ANCESTRY_DEPTH" ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_SESSION_HARNESS_RE"; then
      printf '%s\n' "$pid"
      return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_SESSION_HARNESS_RE" && { printf '%s\n' "$pid"; return 0; } ;;
    esac
    pid=$(fm_pid_parent "$pid") || return 1
    i=$((i + 1))
  done
  return 1
}

# True when $1 is a live process that still looks like a harness. Acquisition
# uses this stricter test so a recycled pid cannot keep a dead session's lock
# alive; ownership resolution above deliberately does not.
fm_session_lock_holder_is_harness() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_SESSION_HARNESS_RE"
}
