#!/usr/bin/env bash
# fm-attribution-lib.sh - the single owner of firstmate's AI-attribution pattern
# set and of the scan that applies it to a block of text.
#
# The captain's standing rule: no AI attribution in any shipped artefact. The
# observed damage was a coauthor trailer, a session-link trailer, and a
# "generated with" footer riding a project's commits and PR bodies onto its
# default branch (docs/attribution-gate.md records the incident).
#
# Everything that enforces that rule reads its patterns from HERE, so the rule
# is stated once: bin/fm-commit-msg-check.sh (the git commit-msg hook target),
# bin/fm-pr-merge.sh (the PR merge gate), and bin/fm-merge-local.sh (the
# local-only landing gate). docs/attribution-gate.md is the human-readable
# contract for what each of those covers and what it does not.
#
# No side effects on source. set -u / set -e safe. Nothing here exits.
#
# API
#   fm_attribution_scan_file <path>
#       Scan the file's lines. Prints one finding per offending line as
#       "<rule>:<lineno>: <line>" on stdout. Returns 0 when clean, 1 when any
#       finding was printed, 2 when the file cannot be read.
#   fm_attribution_scan_text <label> <<< "$text"
#       Same scan over stdin. <label> is prefixed to each finding so a caller
#       scanning several blocks (a PR body, then each commit message) can say
#       which one carried it. Returns 0 clean, 1 findings.
#   fm_attribution_explain
#       Print the standing rule and the fix, for a refusal message. Callers add
#       their own "what to do next" line; this owns the shared half.
#
# WHY THE PATTERNS ARE LINE-ANCHORED
# A git trailer is only a trailer at the start of a line, and the "generated
# with" footer is emitted at the start of its own line. Anchoring there is what
# lets prose ABOUT the rule pass: "we stripped the Co-Authored-By trailer" in
# the middle of a sentence, or a markdown bullet naming it, is discussion, not
# attribution, and must not be refused. The cost of that choice is stated in
# docs/attribution-gate.md rather than hidden here.

# The AI identities that make a trailer an AI trailer. Matched as substrings of
# the lowercased trailer VALUE (the part after the colon), so both the display
# name and the email address are covered ("Claude", "noreply@anthropic.com").
# Separator is "|" because some tokens contain a space.
FM_ATTRIBUTION_AI_TOKENS='claude|anthropic|codex|openai|chatgpt|gpt-|copilot|cursor|gemini|grok|opencode|devin|aider'

# The tool names that make a "generated with/by" line an attribution footer.
# A commit that says "generated with protoc" carries no AI token and passes.
FM_ATTRIBUTION_TOOL_TOKENS='claude code|claude-code|claude opus|claude sonnet|claude|anthropic|codex|copilot|cursor|opencode|gemini|grok|aider|devin'

# The trailer keys that carry authorship credit. "claude-session" is handled
# separately below because that key means exactly one thing whatever its value.
FM_ATTRIBUTION_TRAILER_KEYS='co-authored-by|co-author|coauthored-by|assisted-by|generated-by'

# The scan itself. One pass, no regex assembled from the token lists (they are
# compared with index() so a token containing "." or "-" cannot behave as a
# metacharacter).
fm_attribution_awk_program() {
  cat <<'AWK'
function has_token(s, list,   n, i, arr) {
  n = split(list, arr, "|")
  for (i = 1; i <= n; i++) {
    if (arr[i] != "" && index(s, arr[i]) > 0) return 1
  }
  return 0
}
function emit(rule) {
  found = 1
  if (LABEL == "") {
    printf "%s:%d: %s\n", rule, NR, raw
  } else {
    printf "%s:%s:%d: %s\n", rule, LABEL, NR, raw
  }
}
{
  raw = $0
  sub(/\r$/, "", raw)
  line = tolower(raw)
  sub(/^[ \t]+/, "", line)

  if (line ~ /^claude-session:[ \t]*[^ \t]/) { emit("session-trailer"); next }

  if (match(line, TRAILER_KEYS_RE)) {
    value = substr(line, RLENGTH + 1)
    if (has_token(value, AI_TOKENS)) { emit("ai-coauthor"); next }
  }

  probe = line
  sub(/^[^a-z]*/, "", probe)
  if (probe ~ /^generated (with|by)[ \t]/) {
    if (has_token(probe, TOOL_TOKENS)) { emit("generated-footer"); next }
  }
}
END { exit(found ? 1 : 0) }
AWK
}

# fm_attribution_scan_stdin [label]: scan stdin, print findings, return 0/1.
fm_attribution_scan_stdin() {
  local label=${1:-}
  awk \
    -v LABEL="$label" \
    -v AI_TOKENS="$FM_ATTRIBUTION_AI_TOKENS" \
    -v TOOL_TOKENS="$FM_ATTRIBUTION_TOOL_TOKENS" \
    -v TRAILER_KEYS_RE="^($FM_ATTRIBUTION_TRAILER_KEYS):" \
    "$(fm_attribution_awk_program)"
}

# fm_attribution_scan_file <path> [label]: 0 clean, 1 findings, 2 unreadable.
fm_attribution_scan_file() {
  local path=${1:?usage: fm_attribution_scan_file <path> [label]} label=${2:-} rc=0
  [ -r "$path" ] || return 2
  fm_attribution_scan_stdin "$label" < "$path" || rc=$?
  return "$rc"
}

# Strip the parts of a commit-message file that are NOT the message: git's own
# comment lines, and everything from a scissors line onward. Under
# commit.verbose the file can carry the staged DIFF, and a diff that adds a
# documentation line showing one of these patterns would otherwise be read as
# the commit committing attribution. Defensive either way: when git has already
# applied its cleanup the filter is a no-op.
fm_attribution_strip_commit_comments() {
  awk '/^#.*>8/ { exit } /^#/ { next } { print }'
}

fm_attribution_explain() {
  cat <<'TXT'
The captain's standing rule: no AI attribution in any shipped artefact - no AI
coauthor trailer, no session-link trailer, and no "generated with <tool>" footer
in a commit message, a PR body, or anything else that leaves this machine.
Rewrite the message or body without those lines. Nothing else about the change
needs to alter; only the attribution has to go.
TXT
}
