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
#   The byte count is ALSO what covers the open-decision set below, and that is
#   the whole reason no digest of the open keys is folded in: a key can only be
#   opened, or closed, by APPENDING a line to an append-only log, so every change
#   to the open set has already changed the byte count. An ack recorded while
#   key=a was the only open decision therefore cannot cover the later key=b, and
#   a smaller honest fingerprint does not exist. Were the log ever to stop being
#   append-only, this reasoning fails and the open keys would have to be hashed
#   into the fingerprint directly.
#
# THREE WAYS A TASK IS OWED, not one
#   1. The LAST status line carries an owed verb (done/failed/needs-decision/
#      blocked). This is the original rule and still applies unchanged.
#   2. The task has a STILL-OPEN keyed decision, whatever the last line says.
#      fm-classify-lib.sh's status_open_decisions is the one owner of that fold
#      (a needs-decision/blocked line opens a key; only an explicit resolution or
#      a verified captain-held transfer of that same key closes it), and this
#      library consults it rather than re-deriving any of it.
#   3. The task's current state is a DECLARED EXTERNAL WAIT (`paused`) that has
#      stood longer than FM_ACK_PAUSE_RECHECK without firstmate rechecking it.
#      What a pause owes is not an action but a periodic RE-VERIFICATION of the
#      worker's own claim, because that claim is a premise firstmate never
#      examined. Measured (2026-09-17, data/learnings.md): a worker paused on
#      "only the upstream maintainer can re-run this check", firstmate carried
#      that record through a handoff and a session start unexamined, and the
#      premise was simply wrong - the workflow re-fires on any PR edit, and the
#      real blocker was an unrelated conflict with upstream main. Six idle hours
#      and two captain interventions, with no alarm of any kind, because
#      `paused` is an expected-idle verb that alarmed on nothing.
#
#   Rule 2 exists because rule 1 alone is defeated by the very next append.
#   Measured, twice, on 2026-09-14: a worker appended
#   "needs-decision: [key=picker-props] ..." and immediately after it
#   "resolved: [key=sweep-dimensions] ..." closing an EARLIER, unrelated
#   decision. The last verb was then `resolved`, which owes nothing, so the cheap
#   filter never even reached the crew-state confirm that would have read
#   "parked ... ask-user: captain decision". Both requests sat 50 minutes until
#   the worker re-sent them by hand
#   (state/eln-location-no-project-l3.status, state/eln-live-comments-a1.status).
#
#   Rules 1 and 2 are not exclusive, and the open keys are reported on EVERY
#   owed row rather than only on rule 2's own. An ack covers the whole task, so a
#   row alarming under rule 1 that did not name a decision open behind it would
#   be acted on, recorded, and take that decision into permanent silence with
#   nothing left to re-arm it. A surface tells the rules apart with
#   fm_ack_verb_is_owed on the row's verb rather than a second copy of the list.
#
#   A RECHECK RECURS, which is what makes this rule different from the other
#   two. Rules 1 and 2 are silenced by an ack whose fingerprint still matches,
#   so one ack covers that situation for as long as it lasts. Rule 3 is
#   silenced by an ack's own EPOCH being inside the window, and a paused log
#   gains no line, so the same ack ages out and the alarm re-arms by itself.
#   No second record type was added for it: state/<id>.acted already carries
#   the epoch bin/fm-ack.sh wrote, which is exactly the fact the rule needs.
#
#   This changes only what firstmate OWES a paused task. `paused` remains an
#   expected-idle verb for the watcher's stale detection (fm-classify-lib.sh),
#   and its bounded re-surface cadence (FM_PAUSE_RESURFACE_SECS) is a separate
#   knob owned there for a separate consumer.
#
#   KNOWN CEILING: rules 1 and 2 still age their grace from the log's mtime, i.e.
#   from the LAST append, so a worker appending unrelated lines faster than the
#   grace window keeps resetting the clock on its own open decision. The
#   report-time prefix ("[t=<epoch>] ", whose grammar fm-classify-lib.sh owns)
#   now exists, and rule 3 ages the pause from it, falling back to the mtime only
#   for a line that carries none. Rules 1 and 2 were deliberately left on the
#   mtime: aging an individual decision from its own opening line would change
#   when every existing alarm fires, which is a separate change from adding this
#   one, and every status file written before that prefix existed carries no stamp.
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
#   Rule 3 IS elapsed time, and is not a contradiction of that: a pause is the
#   one state whose owed action is "look at it again after a while". The
#   threshold is FM_ACK_PAUSE_RECHECK, default three hours - long enough that a
#   real CI run, release window, or maintainer round trip is never nagged, short
#   enough that a wrong premise costs an hour or two rather than a morning. A
#   recheck ack silences it for exactly one window, so it recurs rather than
#   either nagging or falling permanently silent.
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

# The status-log verbs that owe firstmate an ACTION. `paused` is deliberately
# absent: it is a declared external wait (fm-classify-lib.sh), and what it owes
# is a periodic recheck rather than an action, which rule 3 handles on its own
# terms below. `working` and `resolved` owe nothing.
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
# The fm-crew-state.sh SOURCES that may not clear a candidate even when the
# state they carry is one of the above. Both are evidence that something of this
# task's is still executing, which is what the watcher needs to know before it
# absorbs a quiet pane - but neither is evidence that the AGENT has moved past
# the state it reported. A worker that appends `done:` and leaves a background
# process behind reads `working - source: subprocess`, and clearing on that
# would silence exactly the unanswered report this guard exists to catch. The
# watcher's own absorb path deliberately does trust them; that path re-surfaces
# on its wedge timer, and this one has no such backstop.
FM_ACK_NONCLEARING_SOURCES_DEFAULT='subprocess attach'

# How long an owed, unacked state may sit before it alarms. Ten minutes is
# deliberately conservative: firstmate routinely takes a turn or two to trigger
# validation or compose a relay, and the incident this guards against ran twenty
# minutes, well clear of the window.
FM_ACK_GRACE_DEFAULT=600
# Rule 3's window: how long a declared external wait (`paused`) may stand before
# firstmate owes it a recheck, and equally how long one recorded recheck silences
# it before the next is owed. Three hours is chosen from both ends: a real CI run,
# release window, or maintainer round trip is well inside it and is never nagged,
# while a pause resting on a wrong premise is caught after an hour or two rather
# than after a morning (the 2026-09-17 incident in the header ran six hours). It
# is deliberately unrelated to FM_PAUSE_RESURFACE_SECS in fm-classify-lib.sh,
# which paces how often the WATCHER re-surfaces a pause as a wake; this paces
# what firstmate owes one.
FM_ACK_PAUSE_RECHECK_DEFAULT=10800
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

# 0 when <source> is one this guard refuses to clear on, whatever state it
# carries. See FM_ACK_NONCLEARING_SOURCES_DEFAULT for why these two are listed.
fm_ack_source_is_nonclearing() {  # <fm-crew-state source token>
  local s=$1 w
  [ -n "$s" ] || return 1
  for w in ${FM_ACK_NONCLEARING_SOURCES:-$FM_ACK_NONCLEARING_SOURCES_DEFAULT}; do
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

fm_ack_resolve_pause_recheck() {  # [window]
  local w=${1:-${FM_ACK_PAUSE_RECHECK:-$FM_ACK_PAUSE_RECHECK_DEFAULT}}
  case "$w" in ''|*[!0-9]*) w=$FM_ACK_PAUSE_RECHECK_DEFAULT ;; esac
  printf '%s' "$w"
}

# How long the declared wait has stood, in seconds, or -1 when it cannot be
# dated. The line's own report-time prefix is preferred over the log's mtime
# because they answer different questions: the mtime says when the file was last
# touched, which any later append moves, while the stamp says when the WORKER
# declared this wait, which is the age rule 3 is about. fm-classify-lib.sh owns
# that prefix's grammar (status_line_epoch); an unstamped line - every status
# file predating the prefix, and any crew that copied the template imperfectly -
# falls back to the mtime, which for a paused task that has appended nothing
# since is the same instant anyway.
fm_ack_pause_age() {  # <status-line> <status-log> <now>
  local t
  t=$(status_line_epoch "$1")
  case "$t" in ''|*[!0-9]*) t=$(fm_ack_stat_mtime "$2") ;; esac
  case "$t" in ''|*[!0-9]*) printf -- '-1'; return 0 ;; esac
  printf '%s' "$(($3 - t))"
}

# 0 when firstmate recorded a recheck within the last <window> seconds. This
# reads the SAME state/<id>.acted record rules 1 and 2 read, by its epoch rather
# than its fingerprint, which is the whole reason rule 3 needs no record of its
# own: a paused log gains no line, so a fingerprint match would silence the task
# forever, while an epoch ages out on its own and re-arms the alarm.
fm_ack_recheck_is_current() {  # <state-dir> <id> <now> <window>
  local f rec ts
  f=$(fm_ack_file "$1" "$2")
  [ -f "$f" ] || return 1
  IFS= read -r rec < "$f" 2>/dev/null || return 1
  ts=${rec%%$'\t'*}
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  [ $(($3 - ts)) -lt "$4" ]
}

# A duration in the compact form the alarm surfaces print ("5h12m", "40m", "9s").
# Here rather than in a surface so the guard banner and the monitor render cannot
# word the same number two ways.
fm_ack_duration() {  # <seconds>
  local s=$1
  case "$s" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  if [ "$s" -ge 3600 ]; then
    printf '%sh%sm' "$((s / 3600))" "$(((s % 3600) / 60))"
  elif [ "$s" -ge 60 ]; then
    printf '%sm' "$((s / 60))"
  else
    printf '%ss' "$s"
  fi
}

# 0 when a bare token is the declared-wait verb. fm-classify-lib.sh owns the
# vocabulary (FM_CLASSIFY_PAUSED_VERB); its own status_is_paused takes a whole
# status LINE, and the two places rule 3 needs this have a bare word in hand -
# fm-crew-state.sh's state token, and a row's verb column.
fm_ack_is_paused_token() {  # <token>
  [ "$1" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 when an fm_ack_unactioned row is owed a PAUSE RECHECK rather than an action.
# That row format carries no class column, so this is the one place the two are
# told apart, and both alarm surfaces ask here instead of each re-deriving it
# from the verb.
fm_ack_row_is_recheck() {  # <verb> <open-keys>
  [ -z "$2" ] || return 1
  fm_ack_is_paused_token "$1"
}

# The still-open keyed decisions for <id>, space separated, or nothing.
# fm-classify-lib.sh's status_open_decisions stays the one owner of what "open"
# means; this only asks it and flattens the answer to the keys. That fold skips
# every line it cannot act on without forking, so a quiet task with a long status
# log costs a read loop and one awk here, not two subprocesses per line.
fm_ack_open_keys() {  # <state-dir> <id>
  status_open_decisions "$1/$2.status" | LC_ALL=C awk -F '\t' '
    $1 != "" { printf "%s%s", (n++ ? " " : ""), $1 }
  '
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
#
# The read is split in two because rule 3 needs a fact the three-way verdict
# discards. That fold deliberately puts `working` and `paused` both in `clear` -
# for rules 1 and 2 either equally proves the crew moved past the owed state -
# but rule 3 is ABOUT a crew still sitting in a declared wait, so it reads the
# reader's own token instead. Widening the verdict vocabulary would change what
# every existing caller sees; splitting the read changes nothing and costs no
# extra subprocess, since each path forks once.
FM_ACK_CONFIRM_TIMEOUT_DEFAULT=15
# The raw read carries the reader's SOURCE as well as its state, tab-separated,
# because two of this file's rules need different halves of the same line and
# neither may cost a second fork: rule 3 asks which state token the reader
# produced, and the clear/owed fold asks what evidence produced it. Callers that
# want only the state token take the field before the tab; fm_ack_confirm_verdict
# below splits the pair itself, so its one-argument contract is unchanged.
fm_ack_confirm_state_raw() {  # <id> -> "<state>[<TAB><source>]", or empty
  local line src rc=0 bound
  bound=${FM_ACK_CONFIRM_TIMEOUT:-$FM_ACK_CONFIRM_TIMEOUT_DEFAULT}
  case "$bound" in ''|*[!0-9]*) bound=$FM_ACK_CONFIRM_TIMEOUT_DEFAULT ;; esac
  if command -v fm_bounded_available >/dev/null 2>&1 && fm_bounded_available; then
    line=$(fm_bounded_run "$bound" "$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 124 ]; then return 0; fi
  else
    line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || true
  fi
  case "$line" in
    state:*) ;;
    *) return 0 ;;
  esac
  src=${line#*source: }
  src=${src%% *}
  line=${line#state: }
  printf '%s\t%s' "${line%% *}" "$src"
}

# The three-way verdict for a raw read. An empty read - unreadable, or the bound
# expired - is `unconfirmed`, never `clear`. A `clear`-looking state whose source
# is one this guard refuses to clear on is `unconfirmed` for the same reason: it
# is not evidence the crew moved past what it reported.
fm_ack_confirm_verdict() {  # <raw read, "<state>[<TAB><source>]">
  local token=${1%%$'\t'*} src=
  case "$1" in *$'\t'*) src=${1#*$'\t'} ;; esac
  if [ -z "$token" ]; then
    printf 'unconfirmed'
  elif fm_ack_state_is_clear "$token" && ! fm_ack_source_is_nonclearing "$src"; then
    printf 'clear'
  elif fm_ack_state_is_owed "$token"; then
    printf 'owed'
  else
    printf 'unconfirmed'
  fi
}

fm_ack_confirm_state() {  # <id>
  fm_ack_confirm_verdict "$(fm_ack_confirm_state_raw "$1")"
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
#   FM_ACK_CLASS    unactioned | recheck | pending | acked | moved-on | exempt | quiet
#   FM_ACK_VERB     the last status verb ('' when the task has no status log)
#   FM_ACK_AGE      seconds since that log was last appended (-1 when unknown)
#   FM_ACK_VERDICT  the crew-state confirm's answer, or '' when none was made
#   FM_ACK_LAST     the crew's own last status line, as evidence
#   FM_ACK_REASON   the signed exemption reason, for class `exempt`
#   FM_ACK_OPEN_KEYS the still-open decision keys, space separated ('' when none)
#   FM_ACK_PAUSE_AGE seconds the declared wait has stood (-1 when not paused or
#                   when the wait cannot be dated)
# Class `recheck` is rule 3's: the task is sitting in a declared external wait
# that has stood past FM_ACK_PAUSE_RECHECK with no recheck recorded inside that
# window. It alarms like `unactioned`, but what it owes is a re-verification of
# the worker's stated premise, not the action a reported state owes.
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
FM_ACK_OPEN_KEYS=
FM_ACK_PAUSE_AGE=-1
FM_ACK_CONFIRMS=0
fm_ack_classify() {  # <state-dir> <id> <grace> <now> [alarm|render]
  local state=$1 id=$2 grace=$3 now=$4 mode=${5:-alarm}
  local log last verb m age fp verdict raw cap owed=0 paused_owed=0 window
  cap=${FM_ACK_CONFIRM_MAX:-$FM_ACK_CONFIRM_MAX_DEFAULT}
  case "$cap" in ''|*[!0-9]*) cap=$FM_ACK_CONFIRM_MAX_DEFAULT ;; esac

  FM_ACK_CLASS=quiet
  FM_ACK_VERB=
  FM_ACK_AGE=-1
  FM_ACK_VERDICT=
  FM_ACK_LAST=
  FM_ACK_REASON=
  FM_ACK_OPEN_KEYS=
  FM_ACK_PAUSE_AGE=-1

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
    # Rule 2 (see THE TWO WAYS A TASK IS OWED above). Read for EVERY task, not
    # only one the last verb left un-owed. A task owed under rule 1 whose open
    # keys went unreported would be acked for what its last line said, and that
    # ack covers the whole task, so an unrelated decision opened earlier would be
    # silenced permanently with nothing left to re-arm it - the very failure this
    # rule exists to close. Reporting the keys on every owed row is what makes
    # the ack an informed assertion rather than an accident.
    FM_ACK_OPEN_KEYS=$(fm_ack_open_keys "$state" "$id")
    [ -n "$FM_ACK_OPEN_KEYS" ] && owed=1

    # Rule 3 (see THREE WAYS A TASK IS OWED above). Only when nothing else is
    # owed: a pause with an open decision behind it is already alarming for a
    # stronger reason, and relabelling that row as a recheck would tell firstmate
    # to go and look rather than to answer the decision. Both tests are pure file
    # reads, so a fleet of healthy pauses still forks nothing here.
    if [ "$owed" -eq 0 ] && status_is_paused "$FM_ACK_LAST"; then
      window=$(fm_ack_resolve_pause_recheck)
      FM_ACK_PAUSE_AGE=$(fm_ack_pause_age "$FM_ACK_LAST" "$log" "$now")
      if [ "$FM_ACK_PAUSE_AGE" -ge "$window" ] &&
         ! fm_ack_recheck_is_current "$state" "$id" "$now" "$window"; then
        paused_owed=1
      fi
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

  if [ "$owed" -eq 0 ] && [ "$paused_owed" -eq 1 ]; then
    # A declared wait that has stood too long unexamined. Its own silencers are
    # the recheck window (tested above) and the captain-signed exemption; the
    # fingerprint ack that silences rules 1 and 2 deliberately does NOT silence
    # this one, because a paused log gains no line and that ack would therefore
    # never expire. Then confirm, for the same reason rules 1 and 2 confirm: the
    # status log is a wake-event history, and a worker whose run has resumed is
    # not waiting on anything regardless of what its last line still says.
    if [ "$mode" != render ] && fm_ack_is_exempt "$state" "$id"; then
      FM_ACK_CLASS=exempt
      FM_ACK_REASON=$FM_ACK_EXEMPT_REASON
      return 0
    fi
    raw=
    if [ "$FM_ACK_CONFIRMS" -lt "$cap" ]; then
      raw=$(fm_ack_confirm_state_raw "$id")
      FM_ACK_CONFIRMS=$((FM_ACK_CONFIRMS + 1))
    fi
    FM_ACK_VERDICT=$(fm_ack_confirm_verdict "$raw")
    if [ -n "${raw%%$'\t'*}" ] && ! fm_ack_is_paused_token "${raw%%$'\t'*}"; then
      # The reader can see past the log: a resumed run, a finished one, a gate.
      # Whatever it is, the declared wait is over and owes no recheck.
      FM_ACK_CLASS=moved-on
    else
      FM_ACK_CLASS=recheck
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
# sitting in a terminal or firstmate-owed state that firstmate has not acted on,
# or in a declared wait it has not rechecked:
#   <id>\t<verb>\t<age-seconds>\t<confirm-verdict>\t<open-keys>\t<last-status-line>
# <open-keys> is every still-open decision key, "-" when there are none, and
# <verb> remains the LAST line's verb, which under rule 2 is routinely something
# that owes nothing. A surface tells the THREE rules apart without a class column:
# fm_ack_row_is_recheck is rule 3's row (verb `paused`, no open keys, and
# <age-seconds> is then how long the WAIT has stood rather than how long ago the
# log was touched - the two differ whenever the pause line carries a report-time
# stamp); otherwise fm_ack_verb_is_owed on <verb> tells rule 1 from rule 2, owed
# meaning rule 1 fired and any open keys are ADDITIONAL, not owed meaning the
# open keys are the whole reason the row is here.
#
# EVERY OPTIONAL FIELD IS "-" WHEN EMPTY, never an empty string, and a reader
# turns "-" back into empty. This is not cosmetic. Bash's `read` collapses runs
# of IFS WHITESPACE into one delimiter, and TAB is IFS whitespace, so an empty
# interior field in a tab-separated row is not read as empty - it is not read at
# all, and every later field silently shifts left by one. A reader would then
# hand the crew's status line to a caller expecting the confirm verdict with no
# error anywhere. The verdict field has always been able to be empty (a task
# over the per-invocation confirm budget), so this was already latent; the
# open-keys field is empty on most rows, which would have made it routine.
# Prints nothing when the fleet is clean, which is what lets bin/fm-guard.sh and
# bin/fm-turnend-guard.sh stay byte-silent. Always returns 0.
fm_ack_unactioned() {  # <state-dir> [grace-seconds]
  local state=$1 grace meta id now age
  grace=$(fm_ack_resolve_grace "${2:-}")
  [ -d "$state" ] || return 0
  now=$(fm_ack_now)
  FM_ACK_CONFIRMS=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_ack_classify "$state" "$id" "$grace" "$now" alarm
    case "$FM_ACK_CLASS" in
      unactioned) age=$FM_ACK_AGE ;;
      recheck) age=$FM_ACK_PAUSE_AGE ;;
      *) continue ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "${FM_ACK_VERB:--}" "$age" "${FM_ACK_VERDICT:--}" \
      "${FM_ACK_OPEN_KEYS:--}" "$FM_ACK_LAST"
  done
  return 0
}

# The RENDER surface's view: every direct report, in every class, including the
# ones that owe nothing. Prints one TAB-separated row per task:
#   <id>\t<class>\t<verb>\t<age-seconds>\t<confirm-verdict>\t<open-keys>\t<detail>
# <age-seconds> is how long the declared wait has stood for class `recheck` and
# how long ago the log was last appended otherwise. <detail> is the signed reason
# for class `exempt` and the crew's own last status line otherwise; <open-keys> is the still-open decision keys, space separated.
# Optional fields are "-" when empty, for the reason fm_ack_unactioned states. Always returns 0; bin/fm-monitor.sh owns the render itself.
fm_ack_sweep() {  # <state-dir> [grace-seconds]
  local state=$1 grace meta id now detail age
  grace=$(fm_ack_resolve_grace "${2:-}")
  [ -d "$state" ] || return 0
  now=$(fm_ack_now)
  FM_ACK_CONFIRMS=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_ack_classify "$state" "$id" "$grace" "$now" render
    if [ "$FM_ACK_CLASS" = exempt ]; then detail=$FM_ACK_REASON; else detail=$FM_ACK_LAST; fi
    if [ "$FM_ACK_CLASS" = recheck ]; then age=$FM_ACK_PAUSE_AGE; else age=$FM_ACK_AGE; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$FM_ACK_CLASS" "${FM_ACK_VERB:--}" "$age" "${FM_ACK_VERDICT:--}" \
      "${FM_ACK_OPEN_KEYS:--}" "$detail"
  done
  return 0
}
