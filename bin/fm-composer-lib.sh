#!/usr/bin/env bash
# bin/fm-composer-lib.sh - the ONE fleet-wide owner of composer-content
# classification, shared by every session-provider adapter: the tmux path
# through bin/fm-tmux-lib.sh, and bin/backends/{herdr,orca,cmux}.sh directly.
#
# WHY THIS EXISTS (task fm-composer-shellglyph-safety): the four adapters each
# carried their own copy of the "is this composer row empty / pending / not an
# agent composer" decision, and the copies drifted. The dangerous drift: a BARE
# shell prompt glyph (`>`, `$`, `%`, `#`) - what a pane shows once its agent has
# exited to a plain login shell - was treated as an empty, ready-to-inject
# AGENT composer. The away-mode escalation injector (bin/fm-supervise-daemon.sh)
# reads composer-emptiness to decide whether a pane is a safe injection target,
# so a dead-shell pane misread as "empty" meant an escalation could be typed
# into (and, worst case, executed by) that shell. Consolidating the one decision
# here means the safety rule cannot silently drift across adapters again.
#
# THE SAFETY RULE this owner enforces: a bare shell prompt glyph is a genuine
# empty agent composer ONLY when it appears INSIDE a real agent-composer
# container - a bordered composer box, where the harness draws its own prompt
# glyph (e.g. claude's older `| > ... |`). On a bare, unstructured row it is a
# dead-shell prompt and is NEVER "empty"; it classifies as `unknown` (not a safe
# injection target). The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a
# genuine empty agent composer either way, bordered or bare.
#
# GHOST/PLACEHOLDER TEXT is the other half of this owner (task
# afk-herdr-false-pending): a harness fills an otherwise-empty composer with
# de-emphasized ghost text - claude's rotating prompt suggestion, codex's idle
# suggestion, grok's placeholder - which a plain capture cannot tell apart from
# text a human typed, so the away-mode injector reads the idle pane as "pending
# input" and defers every escalation (the overnight wedge that motivated this
# consolidation). fm_composer_strip_ghost is the ONE ANSI-aware extractor of
# "real typed content": it drops every de-emphasized run - dim/faint (SGR 2, how
# claude and codex render ghost text) AND a dark/muted TRUECOLOR foreground (how
# grok renders placeholder/hint text) - and keeps only normal-intensity,
# normally-coloured text. Consolidating it here means the two ANSI-capable
# adapters (tmux via bin/fm-tmux-lib.sh, herdr via bin/backends/herdr.sh) cannot
# drift into per-harness one-off strips again; the previous herdr-only faint
# byte-pattern check missed claude's own dim ghost (its prompt glyph is not
# bold-wrapped) and no adapter covered grok's truecolor placeholder at all.
#
# UNICODE BLANK PADDING is the third concern of this owner (task fm-send-falseneg).
# claude draws its composer prompt row as `❯` followed by a U+00A0 NO-BREAK
# SPACE, not an ASCII space (verified 2026-07-30 by hex-dumping a live pane: the
# cursor row is exactly `e2 9d af c2 a0`). The shell's `[[:space:]]` trims do not
# treat U+00A0 as whitespace, so the blank survived trimming, the trimmed content
# `❯<U+00A0>` missed the exact-glyph match below, and the leading-glyph strip left
# a lone U+00A0 that read as real typed content. Every empty claude composer
# therefore classified as `pending`. That is a FALSE POSITIVE for pending input in
# the dangerous direction for two consumers: bin/fm-send.sh reported "Enter
# swallowed" on every steer that had in fact been delivered (inviting a re-send
# that double-instructs an agent), and the away-mode injector read every idle
# claude pane as unsafe to inject, the same shape as incident afk-invx-i5. Every
# fixture in the suite had been hand-written with an ASCII space, so the whole
# suite stayed green while the real thing failed 100% of the time. Normalizing
# Unicode blanks to an ASCII space before the verdict fixes all four adapters at
# once, and keeps the other direction intact: real typed text after the blank
# still reads `pending`.
#
# Each adapter still owns its own CAPTURE and structural row-finding, because
# those use genuinely different primitives (tmux's cursor-row read, herdr's ANSI
# tail scan, orca/cmux's plain read-screen). Once an adapter has a candidate
# composer row it hands the RAW styled row to fm_composer_strip_ghost for the
# real-typed-content extraction, strips the box borders, trims, and hands the
# result plus a <bordered> flag to fm_composer_classify_content for the shared
# empty|pending|unknown verdict. orca/cmux read a plain (unstyled) screen so
# they have no ghost styling to strip and rely on the idle-placeholder match
# below. Re-sourcing is a cheap idempotent redefinition, so this file needs no
# include guard (matching bin/fm-tmux-lib.sh).

# fm_composer_strip_ansi: drop every CSI escape sequence, leaving plain text.
# Used for STRUCTURAL row/shape detection, where ghost text must be KEPT so the
# composer box border or bare prompt glyph is still visible; content extraction
# uses fm_composer_strip_ghost instead. Reads the styled text on stdin and prints
# plain text (stdin-only, matching fm_composer_strip_ghost). The character class
# includes ':' so an ITU colon-form SGR (38:2::r:g:b) is stripped whole, not left
# with a dangling tail.
fm_composer_strip_ansi() {
  local esc; esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;:?]*[[:alpha:]]//g"
}

# fm_composer_strip_ghost: the ONE fleet-wide ANSI-aware extractor of "real typed
# content" from a captured, styled composer row. Reads the styled line on stdin
# (from `tmux capture-pane -e` or `herdr pane read --format ansi`) and prints the
# plain, non-ghost text on stdout, dropping:
#   - dim/faint runs (SGR 2): how claude and codex render ghost/suggestion text.
#     A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run.
#   - dark/muted TRUECOLOR foreground runs (SGR 38;2;r;g;b or the colon form
#     38:2::r:g:b) whose perceived luminance (0.299R + 0.587G + 0.114B) is below
#     FM_COMPOSER_GHOST_LUMA_MAX (default 128): how grok renders its placeholder
#     and hint text. A reset (SGR 0), a default-foreground (SGR 39), any base
#     foreground colour (30-37 / 90-97), or a lighter 38;2 foreground ends the
#     dark-foreground run. This assumes a DARK terminal theme, the firstmate
#     fleet reality, where real typed input is bright and only de-emphasised UI
#     is dark; the SGR-2 signal above stays theme-independent. A 256-colour
#     foreground (38;5;n) is NOT luminance-tested - it is palette-dependent and
#     no fleet harness uses it for ghost text, so it is kept (real text wins:
#     under-stripping merely defers, which the max-defer alarm surfaces, while
#     over-stripping would inject over real input).
# The dim/faint and dark-foreground states are tracked together as "de-emphasis";
# codes are processed left to right within a sequence, so "ESC[0;2m" reads as dim.
# LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and de-emphasised
# runs alike pass through or drop intact without locale-dependent classes.
fm_composer_strip_ghost() {
  LC_ALL=C awk -v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}" '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    # fg38_is_dark: 1 when the SGR 38 foreground starting at param p is a
    # TRUECOLOR (38;2 / 38:2) whose luminance is below lumamax; 0 otherwise
    # (a 38;5 palette colour, a bright truecolor, or a malformed run).
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec = a[p]
      if (index(spec, ":") > 0) {           # colon form: whole colour in a[p]
        nf = split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r = f[nf - 2] + 0; g = f[nf - 1] + 0; b = f[nf] + 0
        return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
      }
      if (p + 1 > k || a[p + 1] != "2" || p + 4 > k) return 0
      r = a[p + 2] + 0; g = a[p + 3] + 0; b = a[p + 4] + 0
      return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
    }
    {
      line = $0; out = ""; dim = 0; darkfg = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update de-emphasis
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0") { dim = 0; darkfg = 0 }
                else if (code == "22") dim = 0
                else if (code == "39") darkfg = 0
                else if (code + 0 >= 30 && code + 0 <= 37) darkfg = 0
                else if (code + 0 >= 90 && code + 0 <= 97) darkfg = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0 && darkfg == 0) out = out c   # keep only non-de-emphasised bytes
        i++
      }
      print out
    }
  '
}

# FM_COMPOSER_BLANKS: the Unicode SPACE-SEPARATOR characters a harness may draw
# in otherwise-empty composer chrome, which the shell's `[[:space:]]` trims and
# the exact-glyph matches below would otherwise read as real typed content. Each
# is built from its UTF-8 bytes with `printf %b` so this file stays ASCII-only
# (no \u escapes, no multibyte literals, no locale-dependent character classes)
# and bash 3.2 safe. U+00A0 is the empirically observed one (claude's composer);
# the rest are the same Unicode category and cost nothing to cover.
#
# Zero-width and format characters (U+200B, U+200C, U+200D, U+2060, U+2063,
# U+FEFF) are DELIBERATELY excluded: U+2063 INVISIBLE SEPARATOR is firstmate's own
# from-firstmate marker (bin/fm-marker-lib.sh), and unknown invisible content
# should count as content, which keeps the safe bias (over-reporting pending
# merely defers, while under-reporting it would inject over real input).
# The covered code points, in the order listed below:
#   U+00A0 NO-BREAK SPACE            (claude's composer prompt row: the observed one)
#   U+1680 OGHAM SPACE MARK
#   U+2000..U+200A                   EN QUAD through HAIR SPACE
#   U+202F NARROW NO-BREAK SPACE
#   U+205F MEDIUM MATHEMATICAL SPACE
#   U+3000 IDEOGRAPHIC SPACE
fm_composer_blanks_init() {
  local esc ch
  FM_COMPOSER_BLANKS=()
  for esc in '\302\240' '\341\232\200' \
             '\342\200\200' '\342\200\201' '\342\200\202' '\342\200\203' \
             '\342\200\204' '\342\200\205' '\342\200\206' '\342\200\207' \
             '\342\200\210' '\342\200\211' '\342\200\212' \
             '\342\200\257' '\342\201\237' '\343\200\200'; do
    printf -v ch '%b' "$esc"
    FM_COMPOSER_BLANKS+=("$ch")
  done
}
fm_composer_blanks_init

# fm_composer_normalize_blanks: replace every FM_COMPOSER_BLANKS character in
# <text> with an ASCII space and assign the result to <out-var>, so the caller's
# ordinary `[[:space:]]` trim can then reduce a blank-only row to the empty
# string. Assigns rather than echoing (the bin/fm-marker-lib.sh idiom) so the
# classifier stays subshell-free on the per-poll path.
fm_composer_normalize_blanks() {  # <text> <out-var>
  local _fmcnb_text=$1 _fmcnb_out=$2 _fmcnb_ch
  for _fmcnb_ch in "${FM_COMPOSER_BLANKS[@]}"; do
    _fmcnb_text=${_fmcnb_text//"$_fmcnb_ch"/ }
  done
  printf -v "$_fmcnb_out" '%s' "$_fmcnb_text"
}

# fm_composer_classify_content: the single shared composer-content verdict.
#   <bordered> 1 when <content> came from a genuine agent-composer container (a
#              bordered composer box, or a structurally-identified bare AGENT
#              prompt row); 0 for a bare, unstructured row (e.g. tmux's raw
#              cursor line that carried no box border).
#   <content>  the candidate composer content, already border-stripped and
#              whitespace-trimmed by the caller.
#   [idle_re]  optional per-harness idle-placeholder regex (e.g. grok's
#              "Type a message...") that reads as empty; matched both before and
#              after a leading prompt glyph is stripped, so a pattern written
#              with or without the glyph both land.
fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | grep -qE "$idle_re" ;;
  esac
}

fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content]
  local bordered=$1 content=$2 idle_re=${3:-} idle_case=${4:-sensitive} plain_content
  plain_content=${5:-$content}
  # Unicode blanks -> ASCII space, then re-trim, BEFORE any emptiness test or
  # exact-glyph match. Callers trim with `[[:space:]]`, which leaves U+00A0 and
  # friends behind, so without this a blank-padded empty composer reads as
  # pending input (see UNICODE BLANK PADDING in this file's header). Both the
  # ghost-stripped content and the structural plain row are normalized, so the
  # bare-glyph fallback below also lands on a blank-padded row.
  fm_composer_normalize_blanks "$content" content
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  fm_composer_normalize_blanks "$plain_content" plain_content
  plain_content="${plain_content#"${plain_content%%[![:space:]]*}"}"
  plain_content="${plain_content%"${plain_content##*[![:space:]]}"}"
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    case "$plain_content" in
      '❯'|'›') printf 'empty'; return 0 ;;
      *) printf 'unknown'; return 0 ;;
    esac
  fi
  # A bare prompt glyph on its own row.
  case "$content" in
    '❯'|'›')
      # Agent prompt glyph: a genuine empty agent composer, bordered or bare.
      printf 'empty'; return 0 ;;
    '>'|'$'|'%'|'#')
      # Shell prompt glyph: empty ONLY inside a composer box (the harness's own
      # prompt). Bare, it is a dead-shell prompt - never a safe injection target.
      if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
      return 0 ;;
  esac
  # Nothing on the row = empty composer.
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched before a leading glyph is stripped).
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph, then re-judge the remainder.
  case "$content" in
    '❯ '*|'› '*|'> '*|'$ '*|'% '*|'# '*) content=${content#??} ;;
    '❯'*|'›'*|'>'*|'$'*|'%'*|'#'*) content=${content#?} ;;
  esac
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched again after the leading glyph was stripped,
  # e.g. "❯ Type a message...").
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Real, unsubmitted content remains.
  printf 'pending'; return 0
}
