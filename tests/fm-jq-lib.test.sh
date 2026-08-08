#!/usr/bin/env bash
# tests/fm-jq-lib.test.sh - the shared jq payload carrier (bin/fm-jq-lib.sh).
#
# The load-bearing contract, task snapshot-argmax-a7:
#   1. A payload LARGER than the host's own execve limit still reaches jq.
#      `jq --argjson name "$BIG"` fails with E2BIG before jq starts once the
#      payload outgrows the argument vector, which is how fm-fleet-snapshot.sh
#      came to emit zero bytes and exit 126 at an ordinary fleet size.
#   2. Payloads bind to the names they were given, in any order.
#   3. A payload that is not exactly one JSON value - empty, or two values -
#      makes the envelope invalid JSON, so jq refuses rather than silently
#      binding the wrong value to the wrong name.
#   4. Small --arg/--argjson options still work alongside the envelope, and
#      jq's exit status is passed through.
#
# The oversized case derives its size from `getconf ARG_MAX` at runtime. A
# fixture at an ordinary payload size would pass on the broken code, because an
# ordinary payload size is exactly what broke. ARG_MAX is the whole-vector cap
# and a deliberate over-estimate of Linux's stricter per-argument
# MAX_ARG_STRLEN (a fixed 128 KiB), so a payload past ARG_MAX is past every
# execve limit on any host.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=bin/fm-jq-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-jq-lib.sh"

arg_max_bytes() {
  local n
  n=$(getconf ARG_MAX 2>/dev/null || printf '')
  case $n in
    ''|*[!0-9]*|0) n=2097152 ;;  # getconf unavailable: fall back to the limit measured on Linux
  esac
  printf '%s' "$n"
}

test_payload_past_arg_max_reaches_jq() {
  local arg_max pad big out
  arg_max=$(arg_max_bytes)
  # Built by string concatenation rather than `jq --arg`, because handing jq a
  # payload this size on argv is the very failure under test. The filler is all
  # 'x', so it needs no JSON escaping.
  pad=$(printf '%*s' $(( arg_max + 4096 )) '' | tr ' ' 'x')
  big="{\"blob\":\"$pad\"}"
  [ "${#big}" -gt "$arg_max" ] \
    || fail "fixture must exceed ARG_MAX ($arg_max) to prove anything, built only ${#big} bytes"
  # shellcheck disable=SC2016  # jq filter is literal: $doc is a jq binding, not shell
  out=$(fm_jq_object payload "$big" -- '. as $doc | $doc.payload.blob | length') \
    || fail "a payload past ARG_MAX must still reach jq"
  [ "$out" = "${#pad}" ] || fail "oversized payload must arrive intact, expected ${#pad} bytes got $out"
  pass "fm_jq_object: a payload past the host's ARG_MAX still reaches jq intact"
}

test_payloads_bind_to_their_names() {
  local out
  # shellcheck disable=SC2016  # jq filter is literal: $doc is a jq binding, not shell
  out=$(fm_jq_object second '{"v":2}' first '{"v":1}' -- -c \
    '. as $doc | {a:$doc.first.v, b:$doc.second.v}') \
    || fail "named payloads must bind"
  [ "$out" = '{"a":1,"b":2}' ] || fail "payloads must bind to their own names, got $out"
  pass "fm_jq_object: payloads bind to the names they were given, independent of order"
}

test_small_options_still_work_alongside_the_envelope() {
  local out
  # shellcheck disable=SC2016  # jq filter is literal: $doc is a jq binding, not shell
  out=$(fm_jq_object rows '[1,2,3]' -- -c --arg label counts --argjson cap 2 \
    '. as $doc | {label:$label, kept:($doc.rows[:$cap])}') \
    || fail "--arg/--argjson must still work alongside the envelope"
  [ "$out" = '{"label":"counts","kept":[1,2]}' ] || fail "small options mis-bound, got $out"
  pass "fm_jq_object: small --arg/--argjson options still travel on argv"
}

test_malformed_payload_refuses_rather_than_misbinding() {
  local rc out
  out=$(fm_jq_object a '' b '{"v":2}' -- -c '.b.v' 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an empty payload must refuse, not shift the remaining bindings (got '$out')"
  out=$(fm_jq_object a '{} {}' b '{"v":2}' -- -c '.b.v' 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a multi-value payload must refuse, not shift the remaining bindings (got '$out')"
  pass "fm_jq_object: a payload that is not exactly one JSON value refuses instead of misbinding"
}

test_usage_errors_refuse() {
  local rc
  fm_jq_object a '{}' -- >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a missing jq filter must refuse with 2, got $rc"
  fm_jq_object a '{}' '.a' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a missing -- separator must refuse with 2, got $rc"
  fm_jq_object a '{}' b >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "an odd number of payload arguments must refuse with 2, got $rc"
  fm_jq_object 'bad name' '{}' -- '.' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a payload name that is not an identifier must refuse with 2, got $rc"
  fm_jq_object dup '{"v":1}' dup '{"v":2}' -- '.dup.v' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a duplicate payload name must refuse with 2, not silently keep the last, got $rc"
  pass "fm_jq_object: usage errors refuse with 2 instead of building a broken envelope"
}

test_jq_exit_status_passes_through() {
  local rc
  fm_jq_object a '{}' -- -e '.a.missing' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "jq's own exit status must pass through, expected 1 got $rc"
  pass "fm_jq_object: jq's exit status passes through unchanged"
}

test_payload_past_arg_max_reaches_jq
test_payloads_bind_to_their_names
test_small_options_still_work_alongside_the_envelope
test_malformed_payload_refuses_rather_than_misbinding
test_usage_errors_refuse
test_jq_exit_status_passes_through
