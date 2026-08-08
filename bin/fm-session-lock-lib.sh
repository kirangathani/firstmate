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
# bin/fm-watch-checkpoint.sh, bin/fm-turnend-guard.sh,
# bin/fm-continuity-pretool-check.sh, bin/fm-sessionstart-nudge.sh, and
# bin/fm-statusline.sh.
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

# --- process start-tick identity ---------------------------------------------
# The kernel's own start time for a pid, in clock ticks since boot. It is the
# same identity the watcher singleton already uses through bin/fm-wake-lib.sh's
# fm_pid_identity, which sources THIS file so there is exactly one definition.
# The dependency runs one way only (wake lib -> session lock lib) because this
# file must stay side-effect free on source: bin/fm-statusline.sh sources it on
# every status-line render and must never create state/.
#
# Ticks are Linux-only (/proc). Every caller here treats them as OPTIONAL, on
# both the writing and the matching side, so a host without /proc resolves
# ownership exactly as before.

# Parse field 22 (starttime, clock ticks since boot) out of one /proc/<pid>/stat
# line. Field 2 (comm) is parenthesized and may itself contain spaces or
# parentheses, which shifts every positional field, so counting from the left is
# unsafe. Split on the LAST ')' instead: the remainder is field 3 onward, which
# makes field 22 that remainder's 20th whitespace-separated token.
fm_pid_parse_start_ticks() {
  local line=$1 rest fields
  [ -n "$line" ] || return 1
  rest=${line##*)}
  [ "$rest" != "$line" ] || return 1
  IFS=' ' read -r -a fields <<< "$rest"
  [ "${#fields[@]}" -ge 20 ] || return 1
  case "${fields[19]}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "${fields[19]}"
}

fm_pid_start_ticks() {
  local pid=$1 line=
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # stderr is redirected BEFORE the input redirect so that a dead pid's missing
  # stat file fails silently: redirections apply left to right, so the usual
  # trailing 2>/dev/null would arrive too late to swallow the open failure.
  # The trailing `|| true` keeps a missing stat file from tripping a caller's
  # errexit; the parser's own validation is what actually gates the result.
  IFS= read -r line 2>/dev/null < "/proc/$pid/stat" || true
  fm_pid_parse_start_ticks "$line"
}

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

# --- the session lock file ---------------------------------------------------
# state/.lock format:
#   line 1  holder pid          (required)
#   line 2  holder start ticks  (optional; absent on a non-Linux writer and on
#                                every lock written before this format existed)
# Line 1 stays a bare pid so bin/fm-session-start.sh's `sed -n '1p'` comparison
# and every fixture that writes one bare pid keep working unchanged.

FM_SESSION_LOCK_PID=
FM_SESSION_LOCK_TICKS=

# Read $1/.lock into FM_SESSION_LOCK_PID and FM_SESSION_LOCK_TICKS. Fails when
# the lock is absent, unreadable, empty, non-numeric, or names pid 0/1 (never a
# real harness); an unparseable second line simply leaves the ticks empty.
#
# Validation is on the PARSED VALUES, never on read's exit status: a lock whose
# final line carries no trailing newline still assigns the variable while read
# reports failure, and reading that as "no lock" would make bin/fm-watch-arm.sh
# arm over a live rival owner - the exact case the gate exists to stop.
fm_session_lock_read() {
  local state=$1 pid='' ticks=''
  FM_SESSION_LOCK_PID=
  FM_SESSION_LOCK_TICKS=
  # stderr is redirected BEFORE the input redirect: redirections apply left to
  # right, so a trailing 2>/dev/null would arrive too late to swallow the open
  # failure for an absent lock (the same trap bin/fm-wake-lib.sh documents).
  {
    IFS= read -r pid
    IFS= read -r ticks
  } 2>/dev/null < "$state/.lock" || true
  pid=${pid//[[:space:]]/}
  ticks=${ticks//[[:space:]]/}
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  case "$ticks" in
    *[!0-9]*) ticks= ;;
  esac
  FM_SESSION_LOCK_PID=$pid
  FM_SESSION_LOCK_TICKS=$ticks
  return 0
}

# The pid recorded in $1/.lock, or failure when there is no usable holder.
fm_session_lock_holder() {
  local state=$1
  fm_session_lock_read "$state" || return 1
  printf '%s\n' "$FM_SESSION_LOCK_PID"
}

# Record pid $2 as the holder of $1/.lock, with its start ticks when the kernel
# offers them. This is the only writer of the format the readers above parse.
fm_session_lock_write() {
  local state=$1 pid=$2 ticks
  if ticks=$(fm_pid_start_ticks "$pid"); then
    printf '%s\n%s\n' "$pid" "$ticks" > "$state/.lock"
  else
    printf '%s\n' "$pid" > "$state/.lock"
  fi
}

# True when live pid $1 is still the process whose start ticks were recorded as
# $2. A LEGACY pid-only lock (no recorded ticks) and a host with no /proc both
# match on the pid alone, exactly as before: ticks are optional on both sides and
# resolution never fails because they are unavailable. That legacy shape CANNOT
# detect pid reuse, which is why fm_session_lock_write records ticks now.
fm_session_lock_identity_matches() {
  local pid=$1 recorded=${2:-} current
  [ -n "$recorded" ] || return 0
  current=$(fm_pid_start_ticks "$pid") || return 0
  [ "$current" = "$recorded" ]
}

# Resolve this process's relationship to the session lock in state dir $1,
# starting the ancestry walk at $2 (default: this script's own pid). Always
# exits 0 and prints exactly one word:
#   owned   - the recorded holder is this process or one of its ancestors
#   other   - a different, still-live session holds the lock
#   missing - no lock, an unreadable or malformed lock, a dead holder, or a
#             holder pid the kernel says is a DIFFERENT process than the one
#             that took the lock
# Identity is checked first, then ancestry, then liveness. A recycled pid (after
# a reboot, state/ is not tmpfs and the lock survives) therefore reads as
# missing, so the arm arms with its announced notice and the blind-turn alarm
# still fires, instead of the two combining into a silently unsupervised home.
# Refusal for a genuinely live rival is unchanged.
fm_session_lock_ownership() {
  local state=$1 start=${2:-$$} holder ticks
  fm_session_lock_read "$state" || { printf 'missing\n'; return 0; }
  holder=$FM_SESSION_LOCK_PID
  ticks=$FM_SESSION_LOCK_TICKS
  if ! fm_session_lock_identity_matches "$holder" "$ticks"; then
    printf 'missing\n'
    return 0
  fi
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

# True when $1 is a live process that still looks like a harness AND still
# matches the start ticks recorded as $2 (optional). Acquisition applies the same
# start-tick identity fm_session_lock_ownership applies, so the two halves of
# this library cannot disagree about whether one lock file is stale.
fm_session_lock_holder_is_harness() {
  local pid=$1 recorded=${2:-} comm
  kill -0 "$pid" 2>/dev/null || return 1
  fm_session_lock_identity_matches "$pid" "$recorded" || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_SESSION_HARNESS_RE"
}
