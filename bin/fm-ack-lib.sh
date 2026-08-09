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
# PER-TASK MONITORING EXEMPTION
#   A task may be exempted from the alarm by state/<id>.monitor-exempt, whose
#   format and captain-only minting are owned by bin/fm-monitor.sh. This library
#   only VERIFIES one, because the verdict has to be identical everywhere the
#   predicate runs. An exemption that cannot be verified is not an exemption:
#   deleting this home's key does not silence the fleet, it only stops new
#   exemptions from being minted.
#
# THE CLASSIFICATION IS THE PREDICATE
#   fm_ack_classify is the single owner of "has this task been actioned". Both
#   consumers are thin loops over it: fm_ack_unactioned emits only the alarming
#   class for bin/fm-guard.sh and bin/fm-turnend-guard.sh, and fm_ack_sweep emits
#   every task in every class for bin/fm-monitor.sh's render. A second copy of
#   this rule is exactly what would drift, so there is not one.
#
# This library states the contract; bin/fm-guard.sh and bin/fm-turnend-guard.sh
# are its alarm surfaces, bin/fm-monitor.sh is its render surface, and
# bin/fm-ack.sh is its captain-facing verb.

_FM_ACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_ACK_LIB_DIR="."

# fm-classify-lib.sh owns status-line parsing (last_status_line,
# status_line_verb) and the FM_CREW_STATE_BIN indirection tests stub. Reuse both
# rather than re-deriving either here.
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$_FM_ACK_LIB_DIR/fm-classify-lib.sh"
# fm-ci-waiver-lib.sh owns every HMAC payload domain in this repo, including the
# monitoring exemption's. Sourcing it defines variables and functions only.
# shellcheck source=bin/fm-ci-waiver-lib.sh
# shellcheck disable=SC1091
. "$_FM_ACK_LIB_DIR/fm-ci-waiver-lib.sh"
# fm-bounded-lib.sh bounds the current-state confirm below. It is probed rather
# than sourced unconditionally: several callers of this library run in trimmed
# scenario trees, and an unconditional `.` of a missing sibling prints to stderr,
# which would turn a silent healthy turn into a noisy one. A host with no bounder
# at all still works - fm_ack_confirm_state falls back to the unbounded read
# rather than skipping the confirm, because skipping it would clear nothing and
# alarm on every resumed worker.
if [ -r "$_FM_ACK_LIB_DIR/fm-bounded-lib.sh" ]; then
  # shellcheck source=bin/fm-bounded-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_ACK_LIB_DIR/fm-bounded-lib.sh"
fi

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
#
# The read is WALL-CLOCK BOUNDED, because this predicate is now on the turn-end
# path (bin/fm-turnend-guard.sh), and that hook is the one place a hang wedges a
# whole session - the same reason its stale-base sweep is bounded. Bounding the
# CONFIRM is not the same as swallowing the FINDING: on expiry the verdict is
# `unconfirmed`, which still alarms, so the bound can only ever cost accuracy
# about a worker's current state, never silence a report that was left
# unanswered. fm-crew-state.sh reads panes and can shell out to no-mistakes, so
# it is not a call that can be assumed to return.
FM_ACK_CONFIRM_TIMEOUT_DEFAULT=15
fm_ack_confirm_state() {  # <id>
  local line state rc=0 bound
  bound=${FM_ACK_CONFIRM_TIMEOUT:-$FM_ACK_CONFIRM_TIMEOUT_DEFAULT}
  case "$bound" in ''|*[!0-9]*) bound=$FM_ACK_CONFIRM_TIMEOUT_DEFAULT ;; esac
  if command -v fm_bounded_available >/dev/null 2>&1 && fm_bounded_available; then
    line=$(fm_bounded_run "$bound" "$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 124 ]; then printf 'unconfirmed'; return 0; fi
  else
    line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || true
  fi
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

# --- the per-task monitoring exemption --------------------------------------
#
# The record lives at state/<id>.monitor-exempt, one line:
#   <epoch>\t<hmac-hex>\t<reason>
# bin/fm-monitor.sh owns minting it; this file owns believing it.

fm_ack_exempt_file() {  # <state-dir> <id>
  printf '%s' "$1/$2.monitor-exempt"
}

# The master key this home signs exemptions with. FM_ACK_SECRET_FILE is the test
# and caller override; otherwise it is the config sibling of the state dir, which
# is how every firstmate home is laid out.
fm_ack_secret_file() {  # <state-dir>
  if [ -n "${FM_ACK_SECRET_FILE:-}" ]; then
    printf '%s' "$FM_ACK_SECRET_FILE"
  elif [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s/ci-waiver-secret' "$FM_CONFIG_OVERRIDE"
  else
    printf '%s/config/ci-waiver-secret' "${1%/*}"
  fi
}

# 0 iff <id> carries a monitoring exemption whose signature this home's key
# reproduces. Every failure path returns non-zero: an absent key, an unreadable
# record, a malformed line, or a signature that does not verify all mean NOT
# exempt. A guard that fell back to "exempt" whenever it could not check would be
# silenced by deleting a file, which is the opposite of the point.
# On success, FM_ACK_EXEMPT_REASON holds the signed reason.
FM_ACK_EXEMPT_REASON=
fm_ack_is_exempt() {  # <state-dir> <id>
  local f rec ts sig reason secret
  FM_ACK_EXEMPT_REASON=
  f=$(fm_ack_exempt_file "$1" "$2")
  [ -f "$f" ] || return 1
  IFS= read -r rec < "$f" 2>/dev/null || return 1
  ts=${rec%%$'\t'*}
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  rec=${rec#*$'\t'}
  sig=${rec%%$'\t'*}
  fm_ci_waiver_valid_sig "$sig" || return 1
  case "$rec" in *$'\t'*) reason=${rec#*$'\t'} ;; *) return 1 ;; esac
  secret=$(fm_ack_secret_file "$1")
  fm_ci_waiver_secret_readable "$secret" || return 1
  fm_ci_waiver_monitor_exempt_check "$2" "$reason" "$sig" < "$secret" || return 1
  FM_ACK_EXEMPT_REASON=$reason
  return 0
}

# --- the predicate ----------------------------------------------------------
#
# fm_ack_classify is the ONE owner of "has this task been actioned". It sets:
#   FM_ACK_CLASS    unactioned | pending | acked | moved-on | exempt | quiet
#   FM_ACK_VERB     the last status verb ('' when the task has no status log)
#   FM_ACK_AGE      seconds since that log was last appended (-1 when unknown)
#   FM_ACK_VERDICT  the crew-state confirm's answer, or '' when none was made
#   FM_ACK_LAST     the crew's own last status line, as evidence
#   FM_ACK_REASON   the signed exemption reason, for class `exempt`
# It also increments FM_ACK_CONFIRMS, the caller's per-invocation confirm budget.
#
# Two modes, because the two consumers pay different costs for the same verdict:
#   alarm  (default) the cheap filter gates every subprocess, so a healthy fleet
#                    forks nothing. This runs on bin/fm-send.sh's path.
#   render           classify every task fully, including confirming a task the
#                    cheap filter would have skipped. This is the captain's
#                    on-demand sweep, where "we did not look" is not an answer.
FM_ACK_CLASS=
FM_ACK_VERB=
FM_ACK_AGE=-1
FM_ACK_VERDICT=
FM_ACK_LAST=
FM_ACK_REASON=
FM_ACK_CONFIRMS=0
fm_ack_classify() {  # <state-dir> <id> <grace> <now> [alarm|render]
  local state=$1 id=$2 grace=$3 now=$4 mode=${5:-alarm}
  local log last verb m age fp verdict cap owed=0
  cap=${FM_ACK_CONFIRM_MAX:-$FM_ACK_CONFIRM_MAX_DEFAULT}
  case "$cap" in ''|*[!0-9]*) cap=$FM_ACK_CONFIRM_MAX_DEFAULT ;; esac

  FM_ACK_CLASS=quiet
  FM_ACK_VERB=
  FM_ACK_AGE=-1
  FM_ACK_VERDICT=
  FM_ACK_LAST=
  FM_ACK_REASON=

  log="$state/$id.status"
  if [ -f "$log" ]; then
    last=$(last_status_line "$log")
    if [ -n "$last" ]; then
      FM_ACK_LAST=$last
      verb=$(status_line_verb "$last")
      FM_ACK_VERB=$verb
      fm_ack_verb_is_owed "$verb" && owed=1
      m=$(fm_ack_stat_mtime "$log")
      case "$m" in ''|*[!0-9]*) ;; *) age=$((now - m)); FM_ACK_AGE=$age ;; esac
    fi
  fi

  # An exemption outranks every other class, so the render always names it and
  # the alarm path can never fire on an exempt task. In alarm mode the node fork
  # it costs is paid only by a task that would otherwise alarm; in render mode it
  # is paid for every task, because the captain is owed the full accounting.
  if [ "$mode" = render ] && fm_ack_is_exempt "$state" "$id"; then
    FM_ACK_CLASS=exempt
    FM_ACK_REASON=$FM_ACK_EXEMPT_REASON
    if [ "$FM_ACK_CONFIRMS" -lt "$cap" ]; then
      FM_ACK_VERDICT=$(fm_ack_confirm_state "$id")
      FM_ACK_CONFIRMS=$((FM_ACK_CONFIRMS + 1))
    fi
    return 0
  fi

  if [ "$owed" -eq 0 ]; then
    # Nothing is owed. The render still reports what the task is actually doing,
    # because "gone over every task" cannot mean "read a file and stopped".
    if [ "$mode" = render ] && [ "$FM_ACK_CONFIRMS" -lt "$cap" ]; then
      FM_ACK_VERDICT=$(fm_ack_confirm_state "$id")
      FM_ACK_CONFIRMS=$((FM_ACK_CONFIRMS + 1))
    fi
    return 0
  fi

  if [ "$FM_ACK_AGE" -lt 0 ]; then
    # An unreadable mtime leaves no way to age the state. It is not silently
    # dropped: the render says so, and the alarm path keeps its long-standing
    # behaviour of not firing on a state it cannot date.
    FM_ACK_CLASS=pending
    return 0
  fi

  if fm_ack_is_current "$state" "$id"; then
    FM_ACK_CLASS=acked
    return 0
  fi

  if [ "$FM_ACK_AGE" -lt "$grace" ]; then
    FM_ACK_CLASS=pending
    return 0
  fi

  if [ "$mode" != render ] && fm_ack_is_exempt "$state" "$id"; then
    FM_ACK_CLASS=exempt
    FM_ACK_REASON=$FM_ACK_EXEMPT_REASON
    return 0
  fi

  fp=$(fm_ack_fingerprint "$state" "$id")
  verdict=$(fm_ack_cached_verdict "$state" "$id" "$fp" "$now")
  if [ -z "$verdict" ]; then
    if [ "$FM_ACK_CONFIRMS" -lt "$cap" ]; then
      verdict=$(fm_ack_confirm_state "$id")
      FM_ACK_CONFIRMS=$((FM_ACK_CONFIRMS + 1))
      fm_ack_cache_write "$state" "$id" "$fp" "$verdict" "$now"
    else
      verdict=unconfirmed
    fi
  fi
  FM_ACK_VERDICT=$verdict
  if [ "$verdict" = clear ]; then
    FM_ACK_CLASS=moved-on
  else
    FM_ACK_CLASS=unactioned
  fi
  return 0
}

fm_ack_resolve_grace() {  # [grace]
  local grace=${1:-${FM_ACK_GRACE:-$FM_ACK_GRACE_DEFAULT}}
  case "$grace" in ''|*[!0-9]*) grace=$FM_ACK_GRACE_DEFAULT ;; esac
  printf '%s' "$grace"
}

# The ALARM surface's view. Prints one TAB-separated row per direct report
# sitting in a terminal or firstmate-owed state that firstmate has not acted on:
#   <id>\t<verb>\t<age-seconds>\t<confirm-verdict>\t<last-status-line>
# Prints nothing when the fleet is clean, which is what lets bin/fm-guard.sh and
# bin/fm-turnend-guard.sh stay byte-silent. Always returns 0.
fm_ack_unactioned() {  # <state-dir> [grace-seconds]
  local state=$1 grace meta id now
  grace=$(fm_ack_resolve_grace "${2:-}")
  [ -d "$state" ] || return 0
  now=$(fm_ack_now)
  FM_ACK_CONFIRMS=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_ack_classify "$state" "$id" "$grace" "$now" alarm
    [ "$FM_ACK_CLASS" = unactioned ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$FM_ACK_VERB" "$FM_ACK_AGE" "$FM_ACK_VERDICT" "$FM_ACK_LAST"
  done
  return 0
}

# The RENDER surface's view: every direct report, in every class, including the
# ones that owe nothing. Prints one TAB-separated row per task:
#   <id>\t<class>\t<verb>\t<age-seconds>\t<confirm-verdict>\t<detail>
# <detail> is the signed reason for class `exempt` and the crew's own last status
# line otherwise. Always returns 0; bin/fm-monitor.sh owns the render itself.
fm_ack_sweep() {  # <state-dir> [grace-seconds]
  local state=$1 grace meta id now detail
  grace=$(fm_ack_resolve_grace "${2:-}")
  [ -d "$state" ] || return 0
  now=$(fm_ack_now)
  FM_ACK_CONFIRMS=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_ack_classify "$state" "$id" "$grace" "$now" render
    if [ "$FM_ACK_CLASS" = exempt ]; then detail=$FM_ACK_REASON; else detail=$FM_ACK_LAST; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$FM_ACK_CLASS" "$FM_ACK_VERB" "$FM_ACK_AGE" "$FM_ACK_VERDICT" "$detail"
  done
  return 0
}
