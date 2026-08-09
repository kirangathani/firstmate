# shellcheck shell=bash
# Shared owner of the "firstmate has acted on this direct report" record and the
# unactioned-state predicate built on it.
# Usage: . bin/fm-ack-lib.sh
#
# Why this exists. Supervision is event-driven: exactly one actionable wake
# carries each terminal or firstmate-owed state, and a mishandled wake leaves no
# trace, because draining the wake queue is what destroys the evidence. The two
# existing guards both miss it. bin/fm-guard.sh alarms on queued-but-undrained
# wakes and a stale watcher beacon; a wake that was drained and then dropped is
# invisible to it. bin/fm-turnend-guard.sh asserts only that a watcher is ALIVE,
# so a turn can end perfectly healthy with a crew sitting at done:. Measured
# consequence (2026-07-30): a finished ship task sat unactioned for twenty
# minutes with no alarm of any kind.
#
# The missing fact was never "what state is the crew in" - fm-crew-state.sh
# already answers that - but "did firstmate DO the thing that state owes". That
# is what this library records.
#
# THE ACK RECORD
#   state/<id>.acted, one line: "<epoch>\t<fingerprint>\t<note>".
#   The fingerprint is "<last-status-verb>|<status-log-bytes>". The status log is
#   append-only, so any new event changes the byte count and the ack no longer
#   covers the current situation. That is the whole re-arm mechanism: acking a
#   done: does NOT mask the later "done: PR ... checks green" that owes a
#   different action, and acking a needs-decision: does not mask the next gate.
#
# WHY THE GRACE CANNOT BE RAW ELAPSED TIME
#   A needs-decision legitimately sits for as long as the captain takes to
#   answer. Alarming on elapsed time alone would fire on every captain decision
#   in the fleet, and data/learnings.md records what that costs: a guard banner
#   that becomes noise gets learned past, and the next genuine one is missed. So
#   the predicate is "owed AND firstmate has not yet done its part", never "owed
#   AND old". Once firstmate relays a decision to the captain and acks it, the
#   task is silent for as long as the captain needs.
#
# TWO INDEPENDENT SILENCERS, both needed:
#   1. A current ack - firstmate did its part; the ball is elsewhere.
#   2. A crew-state confirm - the crew has provably moved past the state, so
#      nothing is owed. fm-crew-state.sh documents the status log going stale
#      exactly this way: a needs-decision/blocked line stays behind after the
#      gate resolved and the run resumed. Confirming against the authoritative
#      run-step is what keeps a resolved-and-resumed crew from alarming.
#
# COST. The cheap filter (last status line, verb, mtime, byte size, ack file) is
# pure file reads and runs on every call. The crew-state confirm forks a
# subprocess, so it runs ONLY for a task that already passed the cheap filter -
# owed verb, past grace, unacked - which in a healthy fleet is never. Confirms
# are further bounded per invocation (FM_ACK_CONFIRM_MAX) and cached with a
# short TTL (FM_ACK_RECHECK) in state/.unactioned-<id>, so a genuinely
# unactioned task does not re-pay the read on every fleet command.
#
# This library states the contract; bin/fm-guard.sh is its only alarm surface
# and bin/fm-ack.sh is its only captain-facing verb.

_FM_ACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_ACK_LIB_DIR="."

# fm-classify-lib.sh owns status-line parsing (last_status_line,
# status_line_verb) and the FM_CREW_STATE_BIN indirection tests stub. Reuse both
# rather than re-deriving either here.
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$_FM_ACK_LIB_DIR/fm-classify-lib.sh"

# The status-log verbs that owe firstmate an action. `paused` is deliberately
# absent: it is a declared external wait that firstmate is meant to leave alone
# (fm-classify-lib.sh), and `working` and `resolved` owe nothing.
FM_ACK_OWED_VERBS_DEFAULT='done failed needs-decision blocked'
# The fm-crew-state.sh states that mean the same thing. `parked` is that
# reader's name for a crew sitting at a gate (its needs-decision mapping).
FM_ACK_OWED_STATES_DEFAULT='done failed parked blocked'
# The fm-crew-state.sh states that PROVE the crew moved past the owed state, and
# so are the only ones that clear a candidate. Everything else - including
# `unknown` - is inconclusive, not exoneration: a crew whose pane died after
# reporting done: reads unknown, and that is the case this guard exists for.
# Clearing on unknown would silence exactly the incident it was built to catch.
FM_ACK_CLEAR_STATES_DEFAULT='working paused'

# How long an owed, unacked state may sit before it alarms. Ten minutes is
# deliberately conservative: firstmate routinely takes a turn or two to trigger
# validation or compose a relay, and the incident this guards against ran twenty
# minutes, well clear of the window.
FM_ACK_GRACE_DEFAULT=600
# TTL of a cached crew-state confirm, and the per-invocation confirm budget.
FM_ACK_RECHECK_DEFAULT=120
FM_ACK_CONFIRM_MAX_DEFAULT=3

# Test seam: freeze "now" so age assertions are deterministic.
fm_ack_now() {
  if [ -n "${FM_ACK_NOW:-}" ]; then printf '%s' "$FM_ACK_NOW"; else date +%s; fi
}

# Resolved ONCE at source time, not per call: the OS cannot change during the
# process's life, and a per-call `uname` fork costs more than the stat it selects.
# The two helpers below run once per task per watcher poll, so the fork was the
# dominant cost of the unactioned-alarm predicate. The failure branch is explicit
# rather than left to the assignment's exit status: callers source this under
# `set -e`, so an absent `uname` must leave the value empty and take the Linux
# branch, not abort the sourcing script.
FM_ACK_UNAME_S=$(uname 2>/dev/null) || FM_ACK_UNAME_S=

# Portable mtime/size; Linux stat lacks -f, macOS stat lacks -c.
fm_ack_stat_mtime() {  # <file>
  if [ "$FM_ACK_UNAME_S" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}
fm_ack_stat_size() {  # <file>
  if [ "$FM_ACK_UNAME_S" = Darwin ]; then stat -f %z "$1" 2>/dev/null; else stat -c %s "$1" 2>/dev/null; fi
}

fm_ack_verb_is_owed() {  # <status-verb>
  local v=$1 w
  [ -n "$v" ] || return 1
  for w in ${FM_ACK_OWED_VERBS:-$FM_ACK_OWED_VERBS_DEFAULT}; do
    if [ "$v" = "$w" ]; then return 0; fi
  done
  return 1
}

fm_ack_state_is_owed() {  # <fm-crew-state state token>
  local s=$1 w
  [ -n "$s" ] || return 1
  for w in ${FM_ACK_OWED_STATES:-$FM_ACK_OWED_STATES_DEFAULT}; do
    if [ "$s" = "$w" ]; then return 0; fi
  done
  return 1
}

fm_ack_state_is_clear() {  # <fm-crew-state state token>
  local s=$1 w
  [ -n "$s" ] || return 1
  for w in ${FM_ACK_CLEAR_STATES:-$FM_ACK_CLEAR_STATES_DEFAULT}; do
    if [ "$s" = "$w" ]; then return 0; fi
  done
  return 1
}

fm_ack_file() {  # <state-dir> <id>
  printf '%s' "$1/$2.acted"
}

fm_ack_cache_file() {  # <state-dir> <id>
  printf '%s' "$1/.unactioned-$2"
}

# The situation an ack covers: the crew's last status verb plus the append-only
# log's byte count. Any later append changes it, which re-arms the alarm.
fm_ack_fingerprint() {  # <state-dir> <id>
  local log="$1/$2.status" verb='' bytes='' last
  if [ -f "$log" ]; then
    last=$(last_status_line "$log")
    verb=$(status_line_verb "$last")
    bytes=$(fm_ack_stat_size "$log")
  fi
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  printf '%s|%s' "$verb" "$bytes"
}

# Record that firstmate acted on <id>'s current situation. Returns non-zero only
# when the record could not be written.
fm_ack_record() {  # <state-dir> <id> [note]
  local state=$1 id=$2 note=${3:-} fp
  [ -d "$state" ] || return 1
  fp=$(fm_ack_fingerprint "$state" "$id")
  printf '%s\t%s\t%s\n' "$(fm_ack_now)" "$fp" "$note" > "$(fm_ack_file "$state" "$id")" 2>/dev/null || return 1
  rm -f "$(fm_ack_cache_file "$state" "$id")" 2>/dev/null || true
  return 0
}

# 0 when a recorded ack still covers the crew's current situation.
fm_ack_is_current() {  # <state-dir> <id>
  local f rec fp
  f=$(fm_ack_file "$1" "$2")
  [ -f "$f" ] || return 1
  IFS= read -r rec < "$f" 2>/dev/null || return 1
  rec=${rec#*$'\t'}
  fp=${rec%%$'\t'*}
  [ "$fp" = "$(fm_ack_fingerprint "$1" "$2")" ]
}

# Ask the authoritative current-state reader whether anything is still owed.
# Prints owed | clear | unconfirmed. An unreadable verdict is `unconfirmed`, not
# `clear`: the cheap filter already established the task looks owed, and a
# failed read is no evidence that it is not.
fm_ack_confirm_state() {  # <id>
  local line state
  line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || true
  case "$line" in
    state:*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  state=${line#state: }
  state=${state%% *}
  if fm_ack_state_is_clear "$state"; then
    printf 'clear'
  elif fm_ack_state_is_owed "$state"; then
    printf 'owed'
  else
    printf 'unconfirmed'
  fi
}

# Cached confirm verdict for this exact fingerprint, or nothing when absent,
# stale, or for a different situation.
fm_ack_cached_verdict() {  # <state-dir> <id> <fingerprint> <now>
  local f rec ts fp verdict ttl
  ttl=${FM_ACK_RECHECK:-$FM_ACK_RECHECK_DEFAULT}
  f=$(fm_ack_cache_file "$1" "$2")
  [ -f "$f" ] || return 0
  IFS= read -r rec < "$f" 2>/dev/null || return 0
  ts=${rec%%$'\t'*}
  rec=${rec#*$'\t'}
  fp=${rec%%$'\t'*}
  verdict=${rec##*$'\t'}
  case "$ts" in ''|*[!0-9]*) return 0 ;; esac
  [ "$fp" = "$3" ] || return 0
  [ $(($4 - ts)) -lt "$ttl" ] || return 0
  printf '%s' "$verdict"
}

fm_ack_cache_write() {  # <state-dir> <id> <fingerprint> <verdict> <now>
  if [ "${FM_ACK_NO_CACHE:-0}" = 1 ]; then return 0; fi
  printf '%s\t%s\t%s\n' "$5" "$3" "$4" > "$(fm_ack_cache_file "$1" "$2")" 2>/dev/null || true
  return 0
}

# The predicate. Prints one TAB-separated row per direct report sitting in a
# terminal or firstmate-owed state that firstmate has not acted on:
#   <id>\t<verb>\t<age-seconds>\t<confirm-verdict>\t<last-status-line>
# Prints nothing when the fleet is clean. Always returns 0.
fm_ack_unactioned() {  # <state-dir> [grace-seconds]
  local state=$1 grace=${2:-${FM_ACK_GRACE:-$FM_ACK_GRACE_DEFAULT}}
  local meta id log last verb now age m fp verdict cap confirms=0
  cap=${FM_ACK_CONFIRM_MAX:-$FM_ACK_CONFIRM_MAX_DEFAULT}
  case "$grace" in ''|*[!0-9]*) grace=$FM_ACK_GRACE_DEFAULT ;; esac
  case "$cap" in ''|*[!0-9]*) cap=$FM_ACK_CONFIRM_MAX_DEFAULT ;; esac
  [ -d "$state" ] || return 0
  now=$(fm_ack_now)

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    log="$state/$id.status"
    [ -f "$log" ] || continue
    last=$(last_status_line "$log")
    [ -n "$last" ] || continue
    verb=$(status_line_verb "$last")
    if ! fm_ack_verb_is_owed "$verb"; then continue; fi
    m=$(fm_ack_stat_mtime "$log")
    case "$m" in ''|*[!0-9]*) continue ;; esac
    age=$((now - m))
    if [ "$age" -lt "$grace" ]; then continue; fi
    if fm_ack_is_current "$state" "$id"; then continue; fi

    fp=$(fm_ack_fingerprint "$state" "$id")
    verdict=$(fm_ack_cached_verdict "$state" "$id" "$fp" "$now")
    if [ -z "$verdict" ]; then
      if [ "$confirms" -lt "$cap" ]; then
        verdict=$(fm_ack_confirm_state "$id")
        confirms=$((confirms + 1))
        fm_ack_cache_write "$state" "$id" "$fp" "$verdict" "$now"
      else
        verdict=unconfirmed
      fi
    fi
    if [ "$verdict" = clear ]; then continue; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$verb" "$age" "$verdict" "$last"
  done
  return 0
}
