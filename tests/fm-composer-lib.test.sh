#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
#
# Task fm-send-falseneg adds the UNICODE BLANK PADDING contract:
#   5. A Unicode blank (U+00A0 and the rest of FM_COMPOSER_BLANKS) is normalized
#      to an ASCII space before the verdict, so a blank-padded empty composer
#      reads `empty`, not `pending`. claude pads its prompt glyph with a U+00A0
#      NO-BREAK SPACE, which the shell's `[[:space:]]` trims leave behind. Every
#      fixture here had been hand-written with an ASCII space, so the suite was
#      green while every real claude composer classified as pending input.
#   6. The other direction is unchanged: real text after the blank still reads
#      `pending`, a blank-padded bare shell glyph is still `unknown`, and a
#      zero-width/format character still counts as content.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Unicode blank padding (task fm-send-falseneg) --------------------------

# The exact bytes hex-dumped from a live claude pane's cursor row on 2026-07-30:
# e2 9d af (❯) c2 a0 (U+00A0 NO-BREAK SPACE). Built with printf so this file stays
# readable ASCII - a literal U+00A0 in source is invisible and unmaintainable.
NBSP=$(printf '\302\240')
GLYPH=$(printf '\342\235\257')

test_blank_padded_empty_composer_is_empty() {
  local out
  out=$(classify 0 "$GLYPH$NBSP")
  [ "$out" = empty ] \
    || fail "a live claude row (glyph + U+00A0) must read empty, got '$out'"
  out=$(classify 1 "$NBSP")
  [ "$out" = empty ] || fail "a blank-only bordered composer row should read empty, got '$out'"
  # The bare-glyph fallback (ghost stripping emptied the content) must land too.
  out=$(classify 0 '' '' sensitive "$GLYPH$NBSP")
  [ "$out" = empty ] || fail "a blank-padded plain_content fallback should read empty, got '$out'"
  pass "fm_composer_classify_content: a U+00A0-padded empty composer reads empty, not pending"
}

test_every_normalized_blank_reads_empty() {
  local ch out
  for ch in "${FM_COMPOSER_BLANKS[@]}"; do
    out=$(classify 0 "$GLYPH$ch")
    [ "$out" = empty ] \
      || fail "glyph padded with a normalized blank should read empty, got '$out'"
  done
  pass "fm_composer_classify_content: every FM_COMPOSER_BLANKS character reads as blank padding"
}

test_blank_padding_preserves_pending_and_unknown() {
  local out zwj
  # The dangerous direction: real unsubmitted text after the blank is still pending.
  out=$(classify 0 "$GLYPH$NBSP fix findings 1 and 3")
  [ "$out" = pending ] || fail "real text after a U+00A0 must stay pending, got '$out'"
  out=$(classify 0 "$GLYPH$NBSP$NBSP a captain decision")
  [ "$out" = pending ] || fail "real text after repeated blanks must stay pending, got '$out'"
  # The dead-shell safety rule survives blank padding.
  out=$(classify 0 "\$$NBSP")
  [ "$out" = unknown ] || fail "a blank-padded bare shell glyph must stay unknown, got '$out'"
  # Zero-width and format characters are NOT normalized: U+2063 INVISIBLE
  # SEPARATOR is firstmate's own from-firstmate marker, so it counts as content.
  zwj=$(printf '\342\201\243')
  out=$(classify 0 "$GLYPH$NBSP$zwj")
  [ "$out" = pending ] || fail "a zero-width marker character must count as content, got '$out'"
  pass "fm_composer_classify_content: blank normalization preserves the pending and unknown verdicts"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_blank_padded_empty_composer_is_empty
test_every_normalized_blank_reads_empty
test_blank_padding_preserves_pending_and_unknown
