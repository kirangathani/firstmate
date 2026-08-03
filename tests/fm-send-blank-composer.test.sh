#!/usr/bin/env bash
# fm-send's submit verdict on a blank-padded composer (task fm-send-falseneg).
#
# claude renders its composer prompt row as `❯` followed by a U+00A0 NO-BREAK
# SPACE, not an ASCII space. The shell's `[[:space:]]` trims do not treat U+00A0 as
# whitespace, so an EMPTY claude composer classified as `pending` and fm-send
# reported "Enter swallowed; text left in composer" - exit 1 - on every steer it
# had in fact delivered. That is the dangerous failure direction: it invites a
# re-send that double-instructs a live agent, and firstmate's own rules treat a
# failed steer as a trigger for stuck-crewmate recovery, so a healthy agent gets
# dragged toward an unnecessary interrupt or relaunch.
#
# The fix normalizes Unicode blanks in the shared classifier
# (fm_composer_classify_content, bin/fm-composer-lib.sh), so it lands for every
# backend adapter at once rather than patching one call site. These tests pin BOTH
# directions through the real bin/fm-send.sh, because deleting the verification or
# making it always succeed would trade a noisy false negative for a silent false
# positive, which is worse - firstmate would believe an agent had been steered when
# it had not:
#   1. A submitted message (composer cleared to the real blank-padded row) exits 0
#      with no error.
#   2. A genuinely swallowed Enter (our text still sitting on that same
#      blank-padded row) still exits non-zero with the swallow diagnostic.
#   3. The retry budget is unchanged - a swallow costs FM_SEND_RETRIES Enters and
#      the text is typed exactly ONCE, never retyped (retyping a swallowed line
#      would duplicate it in the composer).
#   4. The tmux reader itself (fm_tmux_composer_state) reads the live-captured
#      rows the same way, so the fix is in the classifier and not in fm-send.
#
# Every fixture below is the EXACT byte sequence hex-dumped from a live claude
# pane on 2026-07-30 (`e2 9d af c2 a0`, optionally wrapped in the 38;5;246 grey
# claude styles the row with), not a hand-written ASCII-space approximation. The
# hand-written approximation is precisely why the pre-existing suite stayed green
# while every real send failed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-blank-composer)

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# The three live-captured composer rows, as printf format strings.
#   CLEARED  an empty composer: the grey-styled glyph plus its U+00A0 pad.
#   GHOST    an empty composer carrying claude's dim predicted-prompt ghost, whose
#            bare glyph is padded the same way (this shape defeated the earlier
#            ghost-text fix too, so it must read cleared).
#   PENDING  our own unsubmitted text on that same row: a genuine swallowed Enter.
ROW_CLEARED='\033[38;5;246m\xe2\x9d\xaf\xc2\xa0\033[39m\n'
ROW_GHOST='\xe2\x9d\xaf\xc2\xa0\033[2msay the word post-fix and nothing else\033[0m\n'
ROW_PENDING='\xe2\x9d\xaf\xc2\xa0a captain decision that must not be double-sent\n'

# A fake tmux serving one fixed composer row. Every send-keys is logged (one line
# each) so the "typed once, Enter retried" contract can be asserted. capture-pane
# honours -e exactly as the real one does: styled with it, SGR-stripped without.
# The row comes from FM_FAKE_ROW, the log path from FM_TMUX_LOG.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0; target=; arg=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) arg=$1; break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "$arg" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf '%%1\n'; exit 0 ;;
  capture-pane)
    has_e=0
    for a in "$@"; do [ "$a" = "-e" ] && has_e=1; done
    if [ "$has_e" = 1 ]; then
      printf "$FM_FAKE_ROW"
    else
      printf "$FM_FAKE_ROW" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*m/, ""); print}'
    fi
    exit 0 ;;
  list-panes)
    # Endpoint-liveness primitive (bin/backends/tmux.sh
    # fm_backend_tmux_target_exists): real tmux resolves the target and prints
    # its '#{window_name}', failing on a gone window. Every pane in this fake
    # is live, so it answers with the target's own window name.
    _t=""; _p=""
    for _a in "$@"; do [ "$_p" = "-t" ] && _t="$_a"; _p="$_a"; done
    printf '%s\n' "${_t##*:}"
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # No real waiting: the bug is a classification error, not a settle-time race, so
  # the tests must not depend on sleeping at all.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <dir> <row-format> -> sets RC and STDERR; echoes nothing.
# FM_ROOT_OVERRIDE/FM_HOME point at an empty temp home so fm-guard stays quiet and
# no in-flight task is seen.
run_send() {
  local dir=$1 row=$2 fb home
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  LOG="$dir/tmux.log"; : > "$LOG"
  set +e
  STDERR=$(env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_TMUX_LOG="$LOG" FM_FAKE_ROW="$row" FM_SEND_SETTLE=0 \
    "$SEND" "sess:win" "a captain decision that must not be double-sent" 2>&1 >/dev/null)
  RC=$?
  set -e
}

test_submitted_message_exits_zero() {
  local dir
  dir="$TMP_ROOT/cleared"; mkdir -p "$dir"
  run_send "$dir" "$ROW_CLEARED"
  expect_code 0 "$RC" "a delivered send must exit 0 (blank-padded cleared composer)"
  [ -z "$STDERR" ] || fail "a delivered send must print no error, got: $STDERR"
  pass "fm-send: a submitted message on a U+00A0-padded cleared composer exits 0 with no error"
}

test_submitted_message_with_ghost_exits_zero() {
  local dir
  dir="$TMP_ROOT/ghost"; mkdir -p "$dir"
  run_send "$dir" "$ROW_GHOST"
  expect_code 0 "$RC" "a delivered send must exit 0 (blank-padded ghost composer)"
  pass "fm-send: a cleared composer carrying claude's dim ghost still exits 0"
}

test_swallowed_enter_still_exits_nonzero() {
  local dir
  dir="$TMP_ROOT/swallowed"; mkdir -p "$dir"
  run_send "$dir" "$ROW_PENDING"
  [ "$RC" -ne 0 ] || fail "a genuinely swallowed Enter must exit non-zero, got 0"
  case "$STDERR" in
    *"not submitted"*|*"Enter swallowed"*) : ;;
    *) fail "a swallowed Enter must report the swallow, got: $STDERR" ;;
  esac
  pass "fm-send: a genuinely unsubmitted message still exits non-zero (no silent false positive)"
}

test_swallow_types_once_and_retries_enter_only() {
  local dir typed enters
  dir="$TMP_ROOT/retry"; mkdir -p "$dir"
  run_send "$dir" "$ROW_PENDING"
  [ "$RC" -ne 0 ] || fail "expected the swallow path for this assertion"
  typed=$(grep -c 'literal=1' "$LOG" || true)
  enters=$(grep -c 'literal=0 arg=Enter' "$LOG" || true)
  [ "$typed" = 1 ] \
    || fail "the text must be typed exactly once, never retyped; got $typed literal sends"$'\n'"$(cat "$LOG")"
  [ "$enters" = 3 ] \
    || fail "expected the default 3 bounded Enter retries, got $enters"$'\n'"$(cat "$LOG")"
  pass "fm-send: a swallow retries Enter within its bounded budget and never retypes the text"
}

test_tmux_reader_matches_on_the_live_rows() {
  local dir fb out
  dir="$TMP_ROOT/reader"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  : > "$dir/tmux.log"
  out=$(PATH="$fb:$PATH" FM_TMUX_LOG="$dir/tmux.log" FM_FAKE_ROW="$ROW_CLEARED" \
        fm_tmux_composer_state "sess:win")
  [ "$out" = empty ] || fail "the live cleared row must read empty, got '$out'"
  out=$(PATH="$fb:$PATH" FM_TMUX_LOG="$dir/tmux.log" FM_FAKE_ROW="$ROW_GHOST" \
        fm_tmux_composer_state "sess:win")
  [ "$out" = empty ] || fail "the live ghost row must read empty, got '$out'"
  out=$(PATH="$fb:$PATH" FM_TMUX_LOG="$dir/tmux.log" FM_FAKE_ROW="$ROW_PENDING" \
        fm_tmux_composer_state "sess:win")
  [ "$out" = pending ] || fail "the live pending row must read pending, got '$out'"
  pass "fm_tmux_composer_state: the live-captured rows classify empty/empty/pending"
}

test_submitted_message_exits_zero
test_submitted_message_with_ghost_exits_zero
test_swallowed_enter_still_exits_nonzero
test_swallow_types_once_and_retries_enter_only
test_tmux_reader_matches_on_the_live_rows
