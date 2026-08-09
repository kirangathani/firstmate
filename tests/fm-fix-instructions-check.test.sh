#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the no-mistakes fix-instructions PreToolUse seatbelt
# (docs/fix-instructions-gate.md).
#
# bin/fm-fix-instructions-policy.mjs is the single owner of the block/allow
# decision; it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-fix-instructions-check.sh is the stable transport that drives all five
# harness entry forms. Unlike the sibling seatbelts this one is not registered in
# a primary session at all: bin/fm-spawn.sh wires it into each crewmate's own
# task worktree, so this suite also drives the REAL fm-spawn for every harness
# and then exercises the hook it wrote.
#
# The claude, codex and grok hooks are shell commands, so those are proven end to
# end by executing the exact command string fm-spawn recorded. The opencode
# plugin and pi extension are JS/TS, so those are proven end to end by importing
# the generated file in node and invoking the generated blocking callback. No
# harness binary is spawned; live per-harness hook-loading evidence is recorded
# in docs/fix-instructions-gate.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-fix-instructions-check)

CHECK="$ROOT/bin/fm-fix-instructions-check.sh"
POLICY="$ROOT/bin/fm-fix-instructions-policy.mjs"
SPAWN="$ROOT/bin/fm-spawn.sh"

# A real, substantive fix instruction: the shape the gate is trying to force.
GOOD_INSTRUCTIONS="The reporting surface must never imply a verification it did not actually perform. Keep the explicit unverified marker on every unchecked row, and do not reintroduce the implied-check phrasing this finding is a variant of."
# Present but a single word: exactly what the captain rejected presence-only for.
THIN_INSTRUCTIONS="context"

DENY_COMMAND="no-mistakes axi respond --action fix --findings F1"
ALLOW_COMMAND="no-mistakes axi respond --action fix --findings F1 --instructions \"$GOOD_INSTRUCTIONS\""

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_CODES=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_CODES+=("$3")
  MATRIX_COMMANDS+=("$4")
}

# BLOCK: a fix round with no --instructions at all.
matrix_case B01 deny fix-instructions-missing 'no-mistakes axi respond --action fix'
matrix_case B02 deny fix-instructions-missing 'no-mistakes axi respond --action fix --findings F1,F2'
matrix_case B03 deny fix-instructions-missing 'no-mistakes axi respond --action=fix --findings F1'
matrix_case B04 deny fix-instructions-missing 'no-mistakes axi respond --step review --action fix'
matrix_case B05 deny fix-instructions-missing '/usr/local/bin/no-mistakes axi respond --action fix'
matrix_case B06 deny fix-instructions-missing 'cd /tmp && no-mistakes axi respond --action fix'
matrix_case B07 deny fix-instructions-missing 'no-mistakes axi respond --action fix | tee log'
matrix_case B08 deny fix-instructions-missing "bash -c 'no-mistakes axi respond --action fix'"
matrix_case B09 deny fix-instructions-missing '(no-mistakes axi respond --action fix)'
matrix_case B10 deny fix-instructions-missing 'no-mistakes axi respond --action fix --add-finding {}'

# BLOCK: a fix round whose --instructions are below the substance floor.
matrix_case B11 deny fix-instructions-thin "no-mistakes axi respond --action fix --instructions '$THIN_INSTRUCTIONS'"
matrix_case B12 deny fix-instructions-thin 'no-mistakes axi respond --action fix --instructions "fix it"'
matrix_case B13 deny fix-instructions-thin 'no-mistakes axi respond --action fix --instructions=short'
matrix_case B14 deny fix-instructions-thin 'no-mistakes axi respond --action fix --instructions "                                                                                                                             "'
matrix_case B15 deny fix-instructions-thin "no-mistakes axi respond --action fix --instructions 'do what the finding says and keep it clean'"

# ALLOW: a fix round carrying substantive instructions.
matrix_case A01 allow '' "no-mistakes axi respond --action fix --instructions '$GOOD_INSTRUCTIONS'"
matrix_case A02 allow '' "no-mistakes axi respond --action fix --findings F1 --instructions \"$GOOD_INSTRUCTIONS\""
matrix_case A03 allow '' "no-mistakes axi respond --instructions '$GOOD_INSTRUCTIONS' --action fix"
matrix_case A04 allow '' "no-mistakes axi respond --action fix --instructions='$GOOD_INSTRUCTIONS'"
matrix_case A05 allow '' "bash -c \"no-mistakes axi respond --action fix --instructions '$GOOD_INSTRUCTIONS'\""

# ALLOW: not a fix round at all.
matrix_case A06 allow '' 'no-mistakes axi respond --action approve'
matrix_case A07 allow '' 'no-mistakes axi respond --action skip'
matrix_case A08 allow '' 'no-mistakes axi run --intent "ship the thing"'
matrix_case A09 allow '' 'no-mistakes doctor'
matrix_case A10 allow '' 'no-mistakes axi status'

# ALLOW: the bytes appear only as data, never in command position.
matrix_case A11 allow '' "echo 'no-mistakes axi respond --action fix'"
matrix_case A12 allow '' "printf '%s\\n' 'no-mistakes axi respond --action fix'"
matrix_case A13 allow '' '# no-mistakes axi respond --action fix'
matrix_case A14 allow '' 'grep -r "no-mistakes axi respond --action fix" docs/'

# ALLOW: unrelated commands, and the deliberate dynamic-value fail-open.
matrix_case A15 allow '' 'ls -la'
matrix_case A16 allow '' 'git commit -m "wire the fix gate"'
matrix_case A17 allow '' 'no-mistakes axi respond --action fix --instructions "$REASONING"'
matrix_case A18 allow '' 'no-mistakes axi respond --action fix --instructions "$(cat /tmp/reasoning.txt)"'
matrix_case A19 allow '' 'no-mistakes axi respond --action "$DECIDED" --instructions "x"'
matrix_case A20 allow '' '$NM axi respond --action fix'

MATRIX_TMP="$TMP_ROOT/matrix"
mkdir -p "$MATRIX_TMP"

run_matrix_entry() {
  local id=$1 expected=$2 code=$3 entry=$4 cmd=$5 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e --arg code "$code" '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("[" + $code + "]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the $code reason code on stderr: $(cat "$err_file")"
  # The refusal must name what is missing AND what the instructions must contain.
  jq -e '.systemMessage
           | contains("design reasoning")
             and contains("principle the fix must preserve")
             and contains("not break or reintroduce")' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must state what the instructions must contain: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "${MATRIX_CODES[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "fix-instructions acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, block/allow all correct"
}

# --- the substance floor is a named constant, not a magic number ------------

test_substance_floor_is_a_named_constant() {
  local floor at_floor below_floor rc
  assert_grep 'export const MIN_INSTRUCTIONS_CHARS' "$POLICY" "the substance floor must be a named exported constant"
  floor=$(node -e 'import("'"$POLICY"'").then((m) => process.stdout.write(String(m.MIN_INSTRUCTIONS_CHARS)))' 2>/dev/null) \
    || fail "could not read MIN_INSTRUCTIONS_CHARS from the policy module"
  [ -n "$floor" ] && [ "$floor" -gt 0 ] 2>/dev/null || fail "MIN_INSTRUCTIONS_CHARS is not a positive number: $floor"

  # The boundary must be exactly the constant: one character below denies, the
  # constant itself passes. This is what pins the behavior to the named value.
  at_floor=$(head -c "$floor" < /dev/zero | tr '\0' 'a')
  below_floor=$(head -c "$((floor - 1))" < /dev/zero | tr '\0' 'a')

  "$CHECK" --command "no-mistakes axi respond --action fix --instructions '$at_floor'" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "instructions of exactly MIN_INSTRUCTIONS_CHARS ($floor) must be allowed"
  "$CHECK" --command "no-mistakes axi respond --action fix --instructions '$below_floor'" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "instructions one character below MIN_INSTRUCTIONS_CHARS ($floor) must be denied"
  # The constant needs its value justified in a comment, not left bare.
  assert_grep 'Justification for' "$POLICY" "MIN_INSTRUCTIONS_CHARS must carry a justification comment"
  pass "substance floor: named constant MIN_INSTRUCTIONS_CHARS=$floor, boundary exact, justified in a comment"
}

# --- transport fail-open behavior -------------------------------------------

test_fail_open_empty_stdin() {
  local rc
  printf '' | "$CHECK" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "empty stdin must fail open"
  pass "transport: empty stdin fails open"
}

test_fail_open_unparseable_json() {
  local rc
  printf 'not json at all' | "$CHECK" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "unparseable stdin must fail open"
  pass "transport: unparseable stdin fails open"
}

# Builds a PATH directory holding symlinks to exactly the named tools and
# nothing else, so a single tool can be made genuinely absent. `bash` is always
# included because the script's own `#!/usr/bin/env bash` shebang resolves it
# through PATH; without it the script would exit 127 before any fail-open path.
sandbox_path_dir() {
  local dir=$1 tool resolved
  shift
  mkdir -p "$dir"
  for tool in bash "$@"; do
    resolved=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$resolved" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

test_fail_open_missing_node() {
  local dir rc
  dir=$(sandbox_path_dir "$TMP_ROOT/no-node" cat sed tr jq)
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  [ ! -e "$dir/node" ] || fail "the missing-node sandbox must not contain node"
  PATH="$dir" "$CHECK" --command "$DENY_COMMAND" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a PATH without node must fail open"
  pass "transport: missing node fails open"
}

test_fail_open_missing_policy() {
  local dir rc
  dir="$TMP_ROOT/no-policy/bin"
  mkdir -p "$dir"
  cp "$CHECK" "$dir/fm-fix-instructions-check.sh"
  chmod +x "$dir/fm-fix-instructions-check.sh"
  "$dir/fm-fix-instructions-check.sh" --command "$DENY_COMMAND" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a missing policy owner must fail open"
  pass "transport: missing policy owner fails open"
}

test_fail_open_missing_jq_on_stdin() {
  local dir rc
  dir=$(sandbox_path_dir "$TMP_ROOT/no-jq" cat sed tr node)
  [ ! -e "$dir/jq" ] || fail "the missing-jq sandbox must not contain jq"
  printf '{"tool_input":{"command":"%s"}}' "$DENY_COMMAND" | PATH="$dir" "$CHECK" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "stdin transport without jq must fail open"
  pass "transport: missing jq on the stdin path fails open"
}

test_prefilter_skips_node_without_no_mistakes_substring() {
  local dir rc
  # node is unusable here, so anything that reaches the policy owner would fail
  # open anyway; the point is that the prefilter returns before spending it.
  dir="$TMP_ROOT/prefilter"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nprintf "POLICY WAS INVOKED\\n" >&2\nexit 1\n' > "$dir/node"
  chmod +x "$dir/node"
  PATH="$dir:$PATH" "$CHECK" --command 'git status --short' 2>"$TMP_ROOT/prefilter.err"; rc=$?
  expect_code 0 "$rc" "a command with no no-mistakes substring must allow"
  assert_not_contains "$(cat "$TMP_ROOT/prefilter.err")" "POLICY WAS INVOKED" "the prefilter must skip the policy owner entirely"
  pass "transport: prefilter fast-allows a command that cannot name no-mistakes"
}

test_prefilter_is_a_strict_superset() {
  local rc
  # Quote-split and ANSI-C-encoded program names must still reach the classifier.
  "$CHECK" --command 'no-"mistakes" axi respond --action fix' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a quote-split program name must still be classified"
  "$CHECK" --command "no-mistake\$'\\x73' axi respond --action fix" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an ANSI-C-encoded program name must still be classified"
  pass "transport: prefilter stays a strict superset for quote-split and ANSI-C names"
}

test_policy_cli_direct() {
  local out
  out=$(node "$POLICY" --command "$DENY_COMMAND")
  assert_contains "$out" 'deny	fix-instructions-missing' "direct policy CLI must emit the tab-separated deny record"
  out=$(node "$POLICY" --command "$ALLOW_COMMAND")
  [ "$out" = "allow" ] || fail "direct policy CLI must emit allow for a substantive fix round: $out"
  pass "policy owner: direct CLI emits stable allow/deny records"
}

# --- per-harness wiring, driven through the real bin/fm-spawn.sh ------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    # Record the literal (-l) payload so a test can assert on the launch command
    # fm-spawn actually typed into the pane.
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# Spawns a real crewmate for <harness> against fake tmux/treehouse and echoes
# "<case_dir>|<home>|<worktree>|<grok_home>|<id>". The launch command fm-spawn
# typed is captured at <case_dir>/launch.log. An optional <label> gives a second
# spawn of the same harness its own case directory.
spawn_crewmate() {
  local harness=$1 label=${2:-$1} case_dir home proj wt fakebin grok_home id out rc
  case_dir="$TMP_ROOT/spawn-$label"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  grok_home="$case_dir/grok"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="fixgate-$label-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$grok_home"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$harness" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "$harness spawn failed (exit $rc): $out"
  assert_contains "$out" "spawned $id harness=$harness" "$harness spawn did not report success"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$wt" "$grok_home" "$id"
}

# Runs a hook COMMAND STRING exactly as the harness would, feeding it the
# harness's own PreToolUse payload shape, and asserts deny (2) or allow (0).
assert_hook_command() {
  local label=$1 hook_command=$2 field=$3 command=$4 expected=$5 payload rc err
  payload=$(jq -cn --arg command "$command" --arg field "$field" '{tool_name:"Bash"} + {($field): {command: $command}}')
  err="$TMP_ROOT/$label.err"
  printf '%s' "$payload" | eval "$hook_command" >/dev/null 2>"$err"
  rc=$?
  if [ "$expected" = deny ]; then
    expect_code 2 "$rc" "$label must deny a bare fix round"
    assert_contains "$(cat "$err")" 'fix-instructions-missing' "$label deny must carry the reason code"
  else
    expect_code 0 "$rc" "$label must allow a substantive fix round"
    [ ! -s "$err" ] || fail "$label allow must stay silent: $(cat "$err")"
  fi
}

test_claude_spawn_wiring() {
  local rec case_dir home wt grok_home id settings hook_command
  rec=$(spawn_crewmate claude)
  IFS='|' read -r case_dir home wt grok_home id <<EOF
$rec
EOF
  : "$case_dir" "$home" "$grok_home" "$id"
  settings="$wt/.claude/settings.local.json"
  assert_present "$settings" "claude crewmate settings.local.json was not written"
  jq -e . "$settings" >/dev/null 2>&1 || fail "claude settings.local.json is not valid JSON: $(cat "$settings")"
  jq -e '.hooks.Stop[0].hooks[0].command | contains("touch")' "$settings" >/dev/null \
    || fail "claude wiring must keep the turn-end Stop hook"
  hook_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
  assert_contains "$hook_command" 'fm-fix-instructions-check.sh' "claude PreToolUse must invoke the fix-instructions check"
  assert_contains "$hook_command" '--claude' "claude PreToolUse must pass --claude so stdout stays empty on deny"
  jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$settings" >/dev/null \
    || fail "claude PreToolUse hook must match the Bash tool"
  assert_hook_command claude-deny "$hook_command" tool_input "$DENY_COMMAND" deny
  assert_hook_command claude-allow "$hook_command" tool_input "$ALLOW_COMMAND" allow
  # Claude ignores a PreToolUse deny whose stdout is non-empty.
  printf '%s' "$(jq -cn --arg c "$DENY_COMMAND" '{tool_input:{command:$c}}')" \
    | eval "$hook_command" > "$TMP_ROOT/claude-deny.out" 2>/dev/null
  [ ! -s "$TMP_ROOT/claude-deny.out" ] || fail "claude deny left stdout non-empty: $(cat "$TMP_ROOT/claude-deny.out")"
  pass "claude: fm-spawn wires the check into the crewmate worktree and it denies/allows end to end"
}

test_codex_spawn_wiring() {
  local rec case_dir home wt grok_home id hooks hook_command
  rec=$(spawn_crewmate codex)
  IFS='|' read -r case_dir home wt grok_home id <<EOF
$rec
EOF
  : "$case_dir" "$home" "$grok_home" "$id"
  hooks="$wt/.codex/hooks.json"
  assert_present "$hooks" "codex crewmate .codex/hooks.json was not written"
  jq -e . "$hooks" >/dev/null 2>&1 || fail "codex hooks.json is not valid JSON: $(cat "$hooks")"
  jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$hooks" >/dev/null \
    || fail "codex PreToolUse hook must match the Bash tool"
  hook_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$hooks")
  assert_contains "$hook_command" 'fm-fix-instructions-check.sh' "codex PreToolUse must invoke the fix-instructions check"
  assert_hook_command codex-deny "$hook_command" tool_input "$DENY_COMMAND" deny
  assert_hook_command codex-allow "$hook_command" tool_input "$ALLOW_COMMAND" allow
  # The worktree hook must stay invisible to git so it cannot ride into a commit.
  git -C "$wt" status --porcelain | grep -q '\.codex' \
    && fail "codex hooks.json is visible to git; it must be excluded like every other worktree hook"
  pass "codex: fm-spawn writes an excluded .codex/hooks.json that denies/allows end to end"
}

# Spawns a real codex SECONDMATE against fake tmux and echoes the launch command
# fm-spawn typed. The hook-trust ruling is scoped to crewmates, so this launch
# must not carry the bypass flag.
spawn_codex_secondmate_launch() {
  local case_dir home sm launchlog fakebin
  case_dir="$TMP_ROOT/spawn-codex-secondmate"
  home="$case_dir/home"
  sm="$case_dir/sm"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/state" "$home/data" "$home/config" "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  # fm-spawn refuses a secondmate home whose marker names a different id, so the
  # marker must carry the exact spawn id below.
  printf 'fixgate-sm\n' > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  : > "$launchlog"
  PATH="$fakebin:$PATH" TMUX='' CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$SPAWN" fixgate-sm "$sm" codex --secondmate >/dev/null 2>&1
  cat "$launchlog"
}

# The codex crewmate launch must carry --dangerously-bypass-hook-trust, and the
# codex secondmate launch must not. Codex gates project hooks on folder
# hook-trust, so without the flag the .codex/hooks.json written above is present
# but inert and every surface would read as though the seatbelt were enforced.
# The flag is a captain ruling with an accepted cost (a codex crewmate runs a
# repository's own hook code at launch with no trust check), scoped to the
# crewmate launch only; docs/fix-instructions-gate.md owns the contract. This
# pins both halves of that scope so it cannot be silently dropped or widened.
# It proves only what fm-spawn emits: codex is not installed here, so that the
# flag makes the hook fire is an inference, not a measurement.
test_codex_launch_hook_trust_scope() {
  local rec case_dir home wt grok_home id crew_launch sm_launch
  rec=$(spawn_crewmate codex codex-hooktrust)
  IFS='|' read -r case_dir home wt grok_home id <<EOF
$rec
EOF
  : "$home" "$wt" "$grok_home" "$id"
  crew_launch=$(cat "$case_dir/launch.log")
  assert_contains "$crew_launch" 'codex ' "the captured codex crewmate launch must be a codex launch"
  assert_contains "$crew_launch" '--dangerously-bypass-hook-trust' \
    "codex crewmate launch must bypass hook trust or the fix-instructions seatbelt is inert there"
  assert_contains "$crew_launch" '--dangerously-bypass-approvals-and-sandbox' \
    "codex crewmate launch must keep its existing autonomy flag"
  sm_launch=$(spawn_codex_secondmate_launch)
  assert_contains "$sm_launch" 'codex ' "the captured codex secondmate launch must be a codex launch"
  assert_not_contains "$sm_launch" '--dangerously-bypass-hook-trust' \
    "the hook-trust ruling covers crewmates only; a codex secondmate launch must not carry the flag"
  pass "codex: the hook-trust bypass is on the crewmate launch and absent from the secondmate launch"
}

test_grok_spawn_wiring() {
  local rec case_dir home wt grok_home id hook_json hook_command other_ws rc
  rec=$(spawn_crewmate grok)
  IFS='|' read -r case_dir home wt grok_home id <<EOF
$rec
EOF
  : "$home" "$id"
  hook_json="$grok_home/hooks/fm-pretool-check.json"
  assert_present "$hook_json" "grok global PreToolUse hook JSON was not installed"
  assert_present "$grok_home/hooks/fm-pretool-check.sh" "grok global PreToolUse hook script was not installed"
  jq -e . "$hook_json" >/dev/null 2>&1 || fail "grok hook JSON is not valid JSON: $(cat "$hook_json")"
  hook_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$hook_json")
  # Every $VAR in a grok hook command string must carry an inline :-default or
  # the hook fails to load at all, so the command must reference none directly.
  assert_not_contains "$hook_command" '$' "grok hook command must not carry a bare \$VAR reference"

  GROK_WORKSPACE_ROOT="$wt" assert_hook_command grok-deny "$hook_command" toolInput "$DENY_COMMAND" deny
  GROK_WORKSPACE_ROOT="$wt" assert_hook_command grok-allow "$hook_command" toolInput "$ALLOW_COMMAND" allow

  # The global hook must be a no-op for any workspace that is not a firstmate
  # crewmate worktree: no token pointer, no refusal.
  other_ws="$case_dir/not-firstmate"
  mkdir -p "$other_ws"
  printf '%s' "$(jq -cn --arg c "$DENY_COMMAND" '{toolInput:{command:$c}}')" \
    | GROK_WORKSPACE_ROOT="$other_ws" eval "$hook_command" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the grok global hook must be inert outside a firstmate crewmate worktree"
  # And inert for a workspace whose pointer names an unregistered token.
  printf 'token=fm.deadbeefdead\n' > "$other_ws/.fm-grok-turnend"
  printf '%s' "$(jq -cn --arg c "$DENY_COMMAND" '{toolInput:{command:$c}}')" \
    | GROK_WORKSPACE_ROOT="$other_ws" eval "$hook_command" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the grok global hook must be inert for an unregistered workspace token"
  pass "grok: fm-spawn installs a token-guarded global hook that denies/allows end to end and stays inert elsewhere"
}

# Drives the generated opencode plugin's own tool.execute.before callback, which
# blocks by throwing. Proves the generated adapter code, not just its text.
test_opencode_spawn_wiring() {
  local rec case_dir home wt grok_home id plugin out
  rec=$(spawn_crewmate opencode)
  IFS='|' read -r case_dir home wt grok_home id <<EOF
$rec
EOF
  : "$case_dir" "$home" "$grok_home" "$id"
  plugin="$wt/.opencode/plugins/fm-turn-end.js"
  assert_present "$plugin" "opencode crewmate plugin was not written"
  assert_grep 'session.idle' "$plugin" "opencode plugin must keep the turn-end signal"
  assert_grep 'tool.execute.before' "$plugin" "opencode plugin must register the PreToolUse callback"
  out=$(FM_PLUGIN="$plugin" FM_DENY="$DENY_COMMAND" FM_ALLOW="$ALLOW_COMMAND" node --input-type=module -e '
    const mod = await import(process.env.FM_PLUGIN);
    const plugin = await mod.FmTurnEnd({ $: () => {} });
    const before = plugin["tool.execute.before"];
    const run = async (command) => {
      try {
        await before({ tool: "bash" }, { args: { command } });
        return "allowed";
      } catch (error) {
        return `blocked:${error.message}`;
      }
    };
    process.stdout.write(`${await run(process.env.FM_DENY)}\n`);
    process.stdout.write(`${await run(process.env.FM_ALLOW)}\n`);
    process.stdout.write(`${await run("ls -la")}\n`);
  ' 2>&1) || fail "driving the opencode plugin failed: $out"
  assert_contains "$out" 'blocked:' "opencode plugin must throw on a bare fix round: $out"
  assert_contains "$out" 'fix-instructions-missing' "opencode plugin must surface the reason code: $out"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = allowed ] || fail "opencode plugin must allow a substantive fix round: $out"
  [ "$(printf '%s\n' "$out" | sed -n 3p)" = allowed ] || fail "opencode plugin must allow an unrelated command: $out"
  pass "opencode: fm-spawn writes a plugin whose tool.execute.before blocks/allows end to end"
}

# Drives the generated pi extension's own tool_call callback, which blocks by
# returning {block: true}. Node strips the TypeScript annotations natively.
test_pi_spawn_wiring() {
  local rec case_dir home wt grok_home id ext out
  rec=$(spawn_crewmate pi)
  IFS='|' read -r case_dir home wt grok_home id <<EOF
$rec
EOF
  : "$case_dir" "$wt" "$grok_home"
  ext="$home/state/$id.pi-ext.ts"
  assert_present "$ext" "pi crewmate extension was not written"
  assert_grep 'turn_end' "$ext" "pi extension must keep the turn-end signal"
  assert_grep 'tool_call' "$ext" "pi extension must register the PreToolUse callback"
  assert_grep 'block: true' "$ext" "pi extension must block on a checker exit 2"
  out=$(FM_EXT="$ext" FM_DENY="$DENY_COMMAND" FM_ALLOW="$ALLOW_COMMAND" node --input-type=module -e '
    const mod = await import(process.env.FM_EXT);
    const handlers = {};
    mod.default({ on: (name, handler) => { handlers[name] = handler; } });
    const run = async (command) => {
      const result = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command } });
      return result?.block ? `blocked:${result.reason}` : "allowed";
    };
    process.stdout.write(`${await run(process.env.FM_DENY)}\n`);
    process.stdout.write(`${await run(process.env.FM_ALLOW)}\n`);
    process.stdout.write(`${await run("ls -la")}\n`);
  ' 2>&1) || fail "driving the pi extension failed: $out"
  assert_contains "$out" 'blocked:' "pi extension must block a bare fix round: $out"
  assert_contains "$out" 'fix-instructions-missing' "pi extension must surface the reason code: $out"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = allowed ] || fail "pi extension must allow a substantive fix round: $out"
  [ "$(printf '%s\n' "$out" | sed -n 3p)" = allowed ] || fail "pi extension must allow an unrelated command: $out"
  pass "pi: fm-spawn writes an extension whose tool_call blocks/allows end to end"
}

# A secondmate is a firstmate in its own home, not a crewmate driving a
# no-mistakes gate, so it must keep the existing no-worktree-hook shape. The
# seatbelt rides the per-harness hook block bin/fm-spawn.sh already gates on
# `KIND != secondmate`, so this asserts the wiring never escaped that guard.
# Source structure, not behavior: the secondmate spawn path itself is covered by
# the secondmate suites.
test_hooks_stay_inside_the_non_secondmate_guard() {
  local guard_line fix_lines line
  guard_line=$(grep -n '^if \[ "\$KIND" != secondmate \]; then$' "$SPAWN" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ] || fail "could not find the non-secondmate hook guard in bin/fm-spawn.sh"
  fix_lines=$(grep -n 'FIXCHECK\|fm-pretool-check' "$SPAWN" | cut -d: -f1)
  [ -n "$fix_lines" ] || fail "no fix-instructions wiring found in bin/fm-spawn.sh"
  for line in $fix_lines; do
    # The FIXCHECK definition sits just above the guard; every USE must be below it.
    if [ "$line" -lt "$guard_line" ]; then
      grep -q '^FIXCHECK=' <(sed -n "${line}p" "$SPAWN") \
        || fail "bin/fm-spawn.sh line $line wires the fix-instructions check outside the non-secondmate guard"
    fi
  done
  pass "secondmate: every fix-instructions hook write stays inside the non-secondmate guard"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$ROOT/bin/fm-fix-instructions-check.sh" >/dev/null 2>&1 \
    || fail "bin/fm-fix-instructions-check.sh is not shellcheck-clean"
  pass "bin/fm-fix-instructions-check.sh is shellcheck-clean"
}

test_full_acceptance_matrix
test_substance_floor_is_a_named_constant
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_policy
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_no_mistakes_substring
test_prefilter_is_a_strict_superset
test_policy_cli_direct
test_claude_spawn_wiring
test_codex_spawn_wiring
test_codex_launch_hook_trust_scope
test_grok_spawn_wiring
test_opencode_spawn_wiring
test_pi_spawn_wiring
test_hooks_stay_inside_the_non_secondmate_guard
test_scripts_are_shellcheck_clean
