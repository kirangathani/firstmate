#!/usr/bin/env bash
# tests/fm-statusline-render.test.sh - drive the status line END TO END, the way
# Claude Code drives it, and assert on what a human would actually see.
#
# The regression this exists for: the tracked .claude/settings.json points the
# statusLine at bin/fm-statusline.sh, which is supposed to COMPOSE - print the
# operator's own status line first, then the fleet-control line under it. The
# base command was resolved only from FM_STATUSLINE_BASE or the local, gitignored
# config/statusline-base. A home with no config/ dir - a fresh home, a fresh
# clone, a task worktree - therefore resolved no base command and silently
# printed the fleet line alone, deleting the operator's status line everywhere
# inside this repo. Nothing warned and nothing logged; it was found by a human
# noticing his status line had gone.
#
# tests/fm-session-lock-gate.test.sh already covers the fleet-line half of
# bin/fm-statusline.sh (who is in control, and silence without fleet state). What
# was missing, and what let the regression ship green, is a test that RENDERS:
# feeds the real stdin payload to the real command named in the real settings
# file and looks at the bytes that come out. Every case here does that.
#
# The base command's output is a recorded fixture, not a hand-written shape, per
# CONTRIBUTING's fixture rule. tests/fixtures/statusline/botoverflow-render.out
# is the exact stdout of the operator's own status line on the machine where this
# regression was found, captured 2026-08-09 from
# ~/.claude/statusline-botoverflow.sh with:
#
#   env -u TMUX -u BO_TUI HOME=<sandbox> \
#     bash ~/.claude/statusline-botoverflow.sh < <payload.json>
#
# where <sandbox> was an empty HOME (so the rune state file was absent and the
# mark rendered its first frame), payload.json is the payload build_payload()
# writes below, and the cwd was a directory named proj holding a git repo on
# branch statusline-fixture with one commit - the workspace make_workspace()
# rebuilds. tests/fixtures/statusline/transcript.jsonl is the transcript that
# capture pointed at, kept alongside so the pair reproduces.
#
# test_real_operator_status_line_still_renders_every_segment re-runs the real
# script when it is present and asserts the same segments, so the fixture cannot
# quietly drift from the thing it stands for. CI has no such script; that case
# SKIPs there, loudly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-statusline-render)
FIXTURES="$ROOT/tests/fixtures/statusline"
BASE_FIXTURE="$FIXTURES/botoverflow-render.out"
TRANSCRIPT_FIXTURE="$FIXTURES/transcript.jsonl"

# The operator's real status-line script, resolved from the REAL home before any
# case sandboxes HOME. Absent on CI and on any other machine.
REAL_STATUSLINE="${HOME:-}/.claude/statusline-botoverflow.sh"

# Every segment bin/../statusline-botoverflow.sh composes, enumerated from that
# script rather than guessed, each asserted by name so a regression says which
# one vanished:
#   brand   = ${LIME}${BOLD}${rune}${label}  - the animated rune mark plus label
#   model   = ${BOLD}${model}                - model.display_name from the payload
#   dir     = basename of workspace.current_dir
#   branch  = ⎇ <git branch of that dir>
#   ctx     = ctx <used>/<max> <pct>%        - only when transcript_path exists
# The values are the ones the recorded capture was taken with.
SEGMENT_NAMES=(rune-mark model-name directory branch context)
SEGMENT_VALUES=('ᚬ BotOverflow' 'Opus 5' 'proj' '⎇ statusline-fixture' 'ctx 53k/200k 27%')

FLEET_LINE_MARKER='in control of fleet'

# --- fixtures ---------------------------------------------------------------

# A git repo standing in for the session's workspace, so the branch segment has
# something real to resolve. Named to match the recorded capture.
make_workspace() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q -b statusline-fixture
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m initial
}

# The exact JSON payload Claude Code writes to a statusLine command's stdin:
# model, workspace.current_dir, cwd, transcript_path, session_id.
build_payload() {  # <workspace dir> [transcript path]
  local cwd=$1 transcript=${2:-}
  printf '{"hook_event_name":"Status","session_id":"fixture-session","transcript_path":"%s","cwd":"%s","model":{"id":"claude-opus-5","display_name":"Opus 5"},"workspace":{"current_dir":"%s","project_dir":"%s"}}' \
    "$transcript" "$cwd" "$cwd" "$cwd"
}

# A base status-line command that replays the recorded bytes verbatim, including
# the missing trailing newline the real one emits (it ends with printf '%s').
# It drains stdin exactly as a real status-line command does.
install_replay_base() {  # <path>
  local path=$1
  cat > "$path" <<SH
#!/usr/bin/env bash
cat >/dev/null
cat "$BASE_FIXTURE"
SH
  chmod +x "$path"
}

# A user-level settings file, the fallback source the fix reads. Written into a
# directory handed to the render as CLAUDE_CONFIG_DIR, so no case ever reads or
# writes the real one.
install_user_settings() {  # <config dir> <status line command>
  local dir=$1 command=$2
  mkdir -p "$dir"
  cat > "$dir/settings.json" <<JSON
{
  "statusLine": {
    "type": "command",
    "command": "$command",
    "padding": 0,
    "refreshInterval": 1
  }
}
JSON
}

# --- the render -------------------------------------------------------------

# Run the status line the way Claude Code runs it: take the command string out
# of the tracked .claude/settings.json, hand it to a shell with
# CLAUDE_PROJECT_DIR set, and write the payload to its stdin. Nothing here names
# bin/fm-statusline.sh, so a settings file that stops pointing at the composer
# fails these cases instead of passing them.
tracked_statusline_command() {
  node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).statusLine;
    if (!s || s.type !== "command" || typeof s.command !== "string") {
      process.stderr.write("tracked settings have no statusLine command\n");
      process.exit(1);
    }
    process.stdout.write(s.command);
  ' "$ROOT/.claude/settings.json"
}

STATUSLINE_COMMAND=$(tracked_statusline_command) ||
  fail ".claude/settings.json does not configure a statusLine command"

# render <payload> <env arg>...: echo the rendered status line. stdout only -
# the tracked command already drops stderr, exactly as in production. The env
# args are forwarded verbatim, so a case may pass `-u NAME` options; they must
# come first, as env requires, and CLAUDE_PROJECT_DIR is appended after them.
render() {
  local payload=$1
  shift
  printf '%s' "$payload" | env "$@" CLAUDE_PROJECT_DIR="$ROOT" sh -c "$STATUSLINE_COMMAND"
}

# Assert every enumerated segment survives composition, naming the one that did
# not. A single "the base line is there" check would pass on a truncated line.
assert_every_segment() {  # <rendered> <label>
  local rendered=$1 label=$2 i
  for i in "${!SEGMENT_NAMES[@]}"; do
    assert_contains "$rendered" "${SEGMENT_VALUES[$i]}" \
      "$label: the ${SEGMENT_NAMES[$i]} segment is missing from the rendered status line"
  done
}

# The base line must be ABOVE the fleet line, not instead of it and not under it.
assert_base_above_fleet() {  # <rendered> <label>
  local rendered=$1 label=$2 first rest
  first=${rendered%%$'\n'*}
  rest=${rendered#*$'\n'}
  assert_contains "$first" "${SEGMENT_VALUES[0]}" \
    "$label: the first rendered line is not the operator's own status line"
  assert_not_contains "$first" "$FLEET_LINE_MARKER" \
    "$label: the fleet line displaced the operator's own line at the top"
  assert_contains "$rest" "$FLEET_LINE_MARKER" \
    "$label: the fleet-control line is missing below the operator's own line"
}

# --- cases ------------------------------------------------------------------

# THE REGRESSION. No FM_STATUSLINE_BASE, no config/statusline-base, no config dir
# at all - the state every fresh home and every fresh clone starts in. Before the
# fix this rendered the fleet line alone.
test_render_with_no_local_base_configured_at_all() {
  local case_dir home workspace config rendered
  case_dir="$TMP_ROOT/no-local-base"
  home="$case_dir/home"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  mkdir -p "$home/state"
  make_workspace "$workspace"
  install_replay_base "$case_dir/base.sh"
  install_user_settings "$config" "$case_dir/base.sh"
  printf '%s\n' "$$" > "$home/state/.lock"

  [ ! -e "$home/config" ] || fail "the regression case must have no config dir"

  rendered=$(render "$(build_payload "$workspace" "$TRANSCRIPT_FIXTURE")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")

  assert_every_segment "$rendered" "no local base configured"
  assert_base_above_fleet "$rendered" "no local base configured"
  assert_contains "$rendered" "$(cat "$BASE_FIXTURE")" \
    "no local base configured: the operator's line was not reproduced byte for byte"
  pass "render: a home with no config/statusline-base still shows the operator's own status line"
}

# The same case in a task worktree: a plain git worktree of this repo carries the
# tracked settings but has neither config/ nor state/. The composed render must
# still be the operator's line - the crewmate window complaint.
test_render_in_a_task_worktree_with_no_state_dir() {
  local case_dir home workspace config rendered
  case_dir="$TMP_ROOT/task-worktree"
  home="$case_dir/worktree"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  mkdir -p "$home"
  make_workspace "$workspace"
  install_replay_base "$case_dir/base.sh"
  install_user_settings "$config" "$case_dir/base.sh"

  [ ! -d "$home/state" ] || fail "a task worktree fixture must have no state dir"

  rendered=$(render "$(build_payload "$workspace" "$TRANSCRIPT_FIXTURE")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")

  assert_every_segment "$rendered" "task worktree"
  assert_not_contains "$rendered" "$FLEET_LINE_MARKER" \
    "task worktree: a worktree with no fleet state must say nothing about the fleet"
  [ ! -d "$home/state" ] || fail "the render created a state dir; it must never write to state"
  pass "render: a task worktree with no state dir still shows the operator's own status line"
}

# Every crewmate runs inside tmux. The composed line must carry the base
# command's FULL output there, not a reduced one.
test_render_inside_tmux_carries_the_whole_base_line() {
  local case_dir home workspace config rendered
  case_dir="$TMP_ROOT/inside-tmux"
  home="$case_dir/home"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  mkdir -p "$home/state"
  make_workspace "$workspace"
  install_replay_base "$case_dir/base.sh"
  install_user_settings "$config" "$case_dir/base.sh"
  printf '%s\n' "$$" > "$home/state/.lock"

  rendered=$(render "$(build_payload "$workspace" "$TRANSCRIPT_FIXTURE")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config" \
    TMUX="/tmp/tmux-1000/default,1234,0" TMUX_PANE="%7")

  assert_every_segment "$rendered" "inside tmux"
  assert_base_above_fleet "$rendered" "inside tmux"
  assert_contains "$rendered" "$(cat "$BASE_FIXTURE")" \
    "inside tmux: the operator's line was not reproduced byte for byte"
  pass "render: inside tmux the composed line still carries the base command's whole output"
}

# The configured sources still win over the fallback, in their documented order,
# and an explicit "none" still buys the fleet line by itself.
test_configured_sources_outrank_the_fallback() {
  local case_dir home workspace config rendered
  case_dir="$TMP_ROOT/precedence"
  home="$case_dir/home"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  mkdir -p "$home/state" "$home/config"
  make_workspace "$workspace"
  install_replay_base "$case_dir/fallback.sh"
  install_user_settings "$config" "$case_dir/fallback.sh"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "CONFIG-FILE-LINE"\n' > "$case_dir/config-file.sh"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "ENV-OVERRIDE-LINE"\n' > "$case_dir/env.sh"
  chmod +x "$case_dir/config-file.sh" "$case_dir/env.sh"
  printf '%s\n' "$$" > "$home/state/.lock"

  printf '%s\n' "$case_dir/config-file.sh" > "$home/config/statusline-base"
  rendered=$(render "$(build_payload "$workspace")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")
  assert_contains "$rendered" "CONFIG-FILE-LINE" "config/statusline-base must outrank the user-level fallback"
  assert_not_contains "$rendered" "${SEGMENT_VALUES[0]}" "the fallback ran even though config/statusline-base was set"

  rendered=$(render "$(build_payload "$workspace")" \
    FM_STATUSLINE_BASE="$case_dir/env.sh" FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")
  assert_contains "$rendered" "ENV-OVERRIDE-LINE" "FM_STATUSLINE_BASE must outrank config/statusline-base"
  assert_not_contains "$rendered" "CONFIG-FILE-LINE" "config/statusline-base ran even though the env override was set"

  rendered=$(render "$(build_payload "$workspace")" \
    FM_STATUSLINE_BASE=none FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")
  assert_contains "$rendered" "$FLEET_LINE_MARKER" "an opted-out home must still get its fleet line"
  assert_not_contains "$rendered" "${SEGMENT_VALUES[0]}" "\"none\" must stop the fallback, not fall through to it"
  pass "render: FM_STATUSLINE_BASE, then config/statusline-base, then the user-level fallback"
}

# Nothing configured anywhere, which is a real state and not an error: no local
# base, and a harness with no status line of its own. The fleet line must render
# by itself rather than the whole status line failing.
test_render_with_genuinely_no_base_command_anywhere() {
  local case_dir home workspace config rendered status
  case_dir="$TMP_ROOT/no-base-anywhere"
  home="$case_dir/home"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  mkdir -p "$home/state" "$config"
  make_workspace "$workspace"
  printf '%s\n' '{"model":"claude-opus-5"}' > "$config/settings.json"
  printf '%s\n' "$$" > "$home/state/.lock"

  rendered=$(render "$(build_payload "$workspace" "$TRANSCRIPT_FIXTURE")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")
  status=$?
  expect_code 0 "$status" "the status line must exit 0 with no base command anywhere"
  assert_contains "$rendered" "$FLEET_LINE_MARKER" "the fleet line must render on its own"
  [ "$(printf '%s\n' "$rendered" | wc -l)" = 1 ] ||
    fail "expected the fleet line alone, got:"$'\n'"$rendered"

  # An unreadable user settings file is the same quiet case, not a crash.
  printf '%s\n' 'not json at all {' > "$config/settings.json"
  rendered=$(render "$(build_payload "$workspace")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")
  status=$?
  expect_code 0 "$status" "the status line must exit 0 with an unparseable user settings file"
  assert_contains "$rendered" "$FLEET_LINE_MARKER" "an unparseable settings file must degrade to the fleet line"
  pass "render: no base command anywhere degrades to the fleet line alone, quietly"
}

# A user-level status line that names this very script must terminate and must
# not print the fleet line twice.
test_a_self_referential_user_setting_does_not_recurse() {
  local case_dir home workspace config rendered
  case_dir="$TMP_ROOT/self-reference"
  home="$case_dir/home"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  mkdir -p "$home/state"
  make_workspace "$workspace"
  install_user_settings "$config" "$ROOT/bin/fm-statusline.sh"
  printf '%s\n' "$$" > "$home/state/.lock"

  rendered=$(render "$(build_payload "$workspace")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")
  assert_contains "$rendered" "$FLEET_LINE_MARKER" "a self-referential setting must still render the fleet line"
  [ "$(printf '%s\n' "$rendered" | grep -c "$FLEET_LINE_MARKER")" = 1 ] ||
    fail "a self-referential user setting duplicated the fleet line:"$'\n'"$rendered"
  pass "render: a user-level setting naming this script neither recurses nor duplicates"
}

# The base command reads the same payload the harness sent, or its own line loses
# the model, directory, branch and context segments - which is the whole content
# of the operator's status line. A replayed fixture cannot show that, so this
# case checks the bytes the base command actually received.
test_the_payload_reaches_the_base_command_unchanged() {
  local case_dir home workspace config payload rendered
  case_dir="$TMP_ROOT/payload-forwarding"
  home="$case_dir/home"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  mkdir -p "$home/state"
  make_workspace "$workspace"
  cat > "$case_dir/base.sh" <<SH
#!/usr/bin/env bash
cat > "$case_dir/received-payload.json"
printf 'PAYLOAD-RECORDED'
SH
  chmod +x "$case_dir/base.sh"
  install_user_settings "$config" "$case_dir/base.sh"
  printf '%s\n' "$$" > "$home/state/.lock"

  payload=$(build_payload "$workspace" "$TRANSCRIPT_FIXTURE")
  rendered=$(render "$payload" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")

  assert_contains "$rendered" "PAYLOAD-RECORDED" "the fallback base command did not run"
  assert_present "$case_dir/received-payload.json" "the base command received no stdin at all"
  [ "$(cat "$case_dir/received-payload.json")" = "$payload" ] ||
    fail "the base command received different bytes than the harness sent:"$'\n'"$(cat "$case_dir/received-payload.json")"
  pass "render: the harness payload reaches the base command byte for byte"
}

# Guarded: proves the recorded fixture still matches the thing it stands for.
# Skips loudly where the operator's script is absent, which is every CI run.
test_real_operator_status_line_still_renders_every_segment() {
  local case_dir home workspace config rendered
  if [ ! -x "$REAL_STATUSLINE" ]; then
    printf '# SKIP: %s is not present on this machine\n' "$REAL_STATUSLINE"
    pass "render: SKIP the live capture-fidelity check, the operator status line is absent"
    return 0
  fi
  case_dir="$TMP_ROOT/live"
  home="$case_dir/home"
  workspace="$case_dir/proj"
  config="$case_dir/claude-config"
  # A sandboxed HOME, so the live script's own rune/state files land here and
  # never touch the operator's. Empty means it renders its first rune frame,
  # which is the frame the fixture was captured on.
  mkdir -p "$home/state" "$home/.claude"
  make_workspace "$workspace"
  install_user_settings "$config" "$REAL_STATUSLINE"
  printf '%s\n' "$$" > "$home/state/.lock"

  rendered=$(render "$(build_payload "$workspace" "$TRANSCRIPT_FIXTURE")" \
    -u FM_STATUSLINE_BASE -u BO_TUI FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$config")

  assert_every_segment "$rendered" "live operator status line"
  assert_base_above_fleet "$rendered" "live operator status line"
  assert_contains "$rendered" "$(cat "$BASE_FIXTURE")" \
    "the recorded fixture no longer matches what $REAL_STATUSLINE prints; recapture it"
  pass "render: the live operator status line composes, and the recorded fixture still matches it"
}

# --- watcher pool strip ------------------------------------------------------
# bin/fm-statusline.sh appends a right-aligned strip of boxes to the fleet line:
# one distinctly-marked cell for the live watcher, a filled blue box per
# waiting dormant arm, and a hollow box for each empty slot up to
# bin/fm-arm-pool-lib.sh's pool target. These cases render that strip end to
# end, the same way the cases above render the base line, at a fixed 120-column
# width (the width the PR screenshot uses) so the expected string is exact.
#
# A synthetic pool record matches bin/fm-arm-pool-lib.sh's own on-disk format
# exactly (identity, session, timestamp, role, slot, tab-separated), with the
# identity and session fields left empty: an empty identity is accepted on any
# host regardless of /proc support, and an empty session matches what
# fm_arm_pool_session reads when no state/.lock is present, which none of these
# cases create. Every case uses a real, live pid for its record - a synthetic
# pid that names no real process is exactly what that library's own pruning
# discards as dead.
FM_STATUSLINE_TEST_BLUE=$'\033[34m'
FM_STATUSLINE_TEST_BLUE_BOLD=$'\033[1;34m'
FM_STATUSLINE_TEST_RESET=$'\033[0m'
NO_SESSION_FLEET_TEXT='home - not in control of fleet (no session holds it; run bin/fm-session-start.sh)'

POOL_SPAWNED_PIDS=()
pool_test_cleanup() {
  local p
  for p in "${POOL_SPAWNED_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap pool_test_cleanup EXIT

# spawn_pool_member <state dir> <slot>: writes a live-pid record in <slot> and
# leaves the pid in SPAWN_PID. NEVER called through `$(...)`: the background
# `sleep` inherits that command substitution's write end of its capture pipe,
# so the substitution blocks for the full 300s waiting for a close that a
# backgrounded job never gives it. Redirecting the job's own stdio away from
# the caller's descriptors is the fix, not just working around the symptom -
# but a global out-parameter sidesteps the whole class of the bug here, and
# also lets POOL_SPAWNED_PIDS accumulate in THIS shell rather than in a
# subshell whose array the caller could never see.
SPAWN_PID=
spawn_pool_member() {
  local state=$1 slot=$2
  sleep 300 >/dev/null 2>&1 &
  SPAWN_PID=$!
  POOL_SPAWNED_PIDS+=("$SPAWN_PID")
  mkdir -p "$state/.arm-pool"
  printf '\t\t%s\tdormant\t%s\n' "$(date +%s)" "$slot" > "$state/.arm-pool/$SPAWN_PID"
}

# mark_watch_live <state dir> <pid>: names <pid> as the live watcher.
mark_watch_live() {
  mkdir -p "$1/.watch.lock"
  printf '%s\n' "$2" > "$1/.watch.lock/pid"
}

# The right margin bin/fm-statusline.sh holds back from COLUMNS, because Claude
# Code draws the status line inside a padded footer box and truncates anything
# wider. Measured on Claude Code 2.1.282, recorded in docs/configuration.md's
# "Status-line composition" section.
FM_STATUSLINE_TEST_MARGIN=4

# expected_fleet_row <text> <strip> <strip width> <term width>: the same
# right-align arithmetic bin/fm-statusline.sh's fm_statusline_compose_row uses,
# so a case asserts the documented contract rather than a copy-pasted number.
expected_fleet_row() {
  local text=$1 strip=$2 strip_w=$3 width=$4 pad
  pad=$((width - FM_STATUSLINE_TEST_MARGIN - ${#text} - strip_w))
  printf '%s%*s%s' "$text" "$pad" '' "$strip"
}

strip_ansi() {
  printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g'
}

# render_pool <home> [COLUMNS=n]: the fleet line alone, base composition
# skipped by pointing CLAUDE_CONFIG_DIR at a path with no settings.json, so
# fm_statusline_user_base resolves nothing and BASE stays empty.
render_pool() {
  local home=$1
  shift
  render "$(build_payload "$home")" \
    -u FM_STATUSLINE_BASE FM_HOME="$home" HOME="$home" \
    CLAUDE_CONFIG_DIR="$home-no-config" "$@"
}

test_watcher_strip_empty_pool() {
  local home rendered expected
  home="$TMP_ROOT/pool-empty/home"
  mkdir -p "$home/state/.arm-pool"

  rendered=$(render_pool "$home" COLUMNS=120)
  expected=$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" '[.][.][.][.][.][.]' 18 120)
  [ "$rendered" = "$expected" ] ||
    fail "empty pool: expected"$'\n'"$expected"$'\n'"got"$'\n'"$rendered"
  [ "$(strip_ansi "$rendered")" = "$expected" ] ||
    fail "empty pool: the strip carried unexpected ANSI codes"
  pass "render: an empty pool draws six hollow boxes, right-aligned to the terminal width"
}

test_watcher_strip_one_live() {
  local home pid rendered expected raw
  home="$TMP_ROOT/pool-one-live/home"
  mkdir -p "$home/state"
  spawn_pool_member "$home/state" 1; pid=$SPAWN_PID
  mark_watch_live "$home/state" "$pid"

  rendered=$(render_pool "$home" COLUMNS=120)
  raw="${FM_STATUSLINE_TEST_BLUE_BOLD}[@]${FM_STATUSLINE_TEST_RESET}[.][.][.][.][.]"
  expected=$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" "$raw" 18 120)
  [ "$rendered" = "$expected" ] ||
    fail "one live: expected"$'\n'"$expected"$'\n'"got"$'\n'"$rendered"
  [ "$(strip_ansi "$rendered")" = "$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" '[@][.][.][.][.][.]' 18 120)" ] ||
    fail "one live: the ANSI-stripped strip did not read [@][.][.][.][.][.]"
  pass "render: the sole live watcher draws distinctly marked, with five hollow slots behind it"
}

test_watcher_strip_live_plus_three_dormant() {
  local home pid1 rendered expected raw
  home="$TMP_ROOT/pool-live-plus-three/home"
  mkdir -p "$home/state"
  spawn_pool_member "$home/state" 1; pid1=$SPAWN_PID
  spawn_pool_member "$home/state" 2
  spawn_pool_member "$home/state" 3
  spawn_pool_member "$home/state" 4
  mark_watch_live "$home/state" "$pid1"

  rendered=$(render_pool "$home" COLUMNS=120)
  raw="${FM_STATUSLINE_TEST_BLUE_BOLD}[@]${FM_STATUSLINE_TEST_RESET}"
  raw="$raw${FM_STATUSLINE_TEST_BLUE}[#]${FM_STATUSLINE_TEST_RESET}"
  raw="$raw${FM_STATUSLINE_TEST_BLUE}[#]${FM_STATUSLINE_TEST_RESET}"
  raw="$raw${FM_STATUSLINE_TEST_BLUE}[#]${FM_STATUSLINE_TEST_RESET}[.][.]"
  expected=$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" "$raw" 18 120)
  [ "$rendered" = "$expected" ] ||
    fail "live plus three dormant: expected"$'\n'"$expected"$'\n'"got"$'\n'"$rendered"
  [ "$(strip_ansi "$rendered")" = "$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" '[@][#][#][#][.][.]' 18 120)" ] ||
    fail "live plus three dormant: the ANSI-stripped strip did not read [@][#][#][#][.][.]"
  pass "render: a live watcher plus three waiting dormant arms draws four filled boxes and two hollow"
}

test_watcher_strip_full() {
  local home slot pid live_pid rendered expected raw n
  home="$TMP_ROOT/pool-full/home"
  mkdir -p "$home/state"
  raw=
  for n in 1 2 3 4 5 6; do
    spawn_pool_member "$home/state" "$n"; pid=$SPAWN_PID
    if [ "$n" = 1 ]; then
      live_pid=$pid
      raw="${FM_STATUSLINE_TEST_BLUE_BOLD}[@]${FM_STATUSLINE_TEST_RESET}"
    else
      raw="$raw${FM_STATUSLINE_TEST_BLUE}[#]${FM_STATUSLINE_TEST_RESET}"
    fi
  done
  mark_watch_live "$home/state" "$live_pid"

  rendered=$(render_pool "$home" COLUMNS=120)
  expected=$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" "$raw" 18 120)
  [ "$rendered" = "$expected" ] ||
    fail "full pool: expected"$'\n'"$expected"$'\n'"got"$'\n'"$rendered"
  [ "$(strip_ansi "$rendered")" = "$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" '[@][#][#][#][#][#]' 18 120)" ] ||
    fail "full pool: the ANSI-stripped strip did not read [@][#][#][#][#][#]"
  pass "render: a full pool draws the live watcher plus five filled boxes, none hollow"
}

test_watcher_strip_absent_pool() {
  local home rendered expected
  home="$TMP_ROOT/pool-absent/home"
  mkdir -p "$home/state"

  [ ! -d "$home/state/.arm-pool" ] || fail "absent pool: the fixture must have no .arm-pool directory"
  rendered=$(render_pool "$home" COLUMNS=120)
  expected=$(expected_fleet_row "$NO_SESSION_FLEET_TEXT" '[.]' 3 120)
  [ "$rendered" = "$expected" ] ||
    fail "absent pool: expected"$'\n'"$expected"$'\n'"got"$'\n'"$rendered"
  pass "render: a home that has never joined the pool draws one hollow cell, the old-style single watcher"
}

# The truncation bug: the strip was right-aligned to COLUMNS itself, so the
# rendered row was exactly COLUMNS wide and Claude Code's footer padding pushed
# its last cells past the edge, where Ink replaced them with an ellipsis. These
# two cases pin the visible width - the one thing the arithmetic above cannot
# catch, since it mirrors whatever the script does.
visible_width() {  # <rendered row>
  local plain
  plain=$(strip_ansi "$1")
  printf '%s' "${#plain}"
}

test_watcher_strip_row_stops_short_of_the_terminal_width() {
  local home pid rendered width
  home="$TMP_ROOT/pool-margin/home"
  mkdir -p "$home/state"
  spawn_pool_member "$home/state" 1; pid=$SPAWN_PID
  mark_watch_live "$home/state" "$pid"

  # Scrubbed rather than inherited: this case measures the script's own default,
  # and bin/fm-spawn.sh forwards status-line environment into worker panes.
  rendered=$(unset FM_STATUSLINE_RIGHT_MARGIN; render_pool "$home" COLUMNS=120)
  width=$(visible_width "$rendered")
  printf 'measured visible width %s at COLUMNS=120, margin %s\n' "$width" "$FM_STATUSLINE_TEST_MARGIN"
  [ "$width" -eq $((120 - FM_STATUSLINE_TEST_MARGIN)) ] ||
    fail "the fleet row must stop short of COLUMNS by the measured right margin, or Claude Code truncates the strip"
  pass "render: the fleet row's visible width stops short of the terminal width by the measured right margin"
}

test_watcher_strip_right_margin_override() {
  local home pid rendered width
  home="$TMP_ROOT/pool-margin-override/home"
  mkdir -p "$home/state"
  spawn_pool_member "$home/state" 1; pid=$SPAWN_PID
  mark_watch_live "$home/state" "$pid"

  rendered=$(render_pool "$home" COLUMNS=120 FM_STATUSLINE_RIGHT_MARGIN=11)
  width=$(visible_width "$rendered")
  printf 'measured visible width %s at COLUMNS=120 with an overridden margin of 11\n' "$width"
  [ "$width" -eq 109 ] ||
    fail "FM_STATUSLINE_RIGHT_MARGIN must set the width the row is right-aligned to"

  rendered=$(render_pool "$home" COLUMNS=120 FM_STATUSLINE_RIGHT_MARGIN=notanumber)
  width=$(visible_width "$rendered")
  printf 'measured visible width %s at COLUMNS=120 with a non-numeric margin\n' "$width"
  [ "$width" -eq $((120 - FM_STATUSLINE_TEST_MARGIN)) ] ||
    fail "a non-numeric FM_STATUSLINE_RIGHT_MARGIN must fall back to the measured default, not break the row"
  pass "render: FM_STATUSLINE_RIGHT_MARGIN overrides the margin, and a non-numeric value falls back to the default"
}

test_watcher_strip_narrow_width_drops_it() {
  local home slot pid live_pid rendered
  home="$TMP_ROOT/pool-narrow/home"
  mkdir -p "$home/state"
  for slot in 1 2 3 4 5 6; do
    spawn_pool_member "$home/state" "$slot"; pid=$SPAWN_PID
    [ "$slot" = 1 ] && live_pid=$pid
  done
  mark_watch_live "$home/state" "$live_pid"

  rendered=$(render_pool "$home" COLUMNS=40)
  [ "$rendered" = "$NO_SESSION_FLEET_TEXT" ] ||
    fail "narrow width: the strip must be dropped rather than wrap the row, got:"$'\n'"$rendered"
  pass "render: a terminal too narrow for the strip drops it and keeps the text intact"
}

test_render_with_no_local_base_configured_at_all
test_render_in_a_task_worktree_with_no_state_dir
test_render_inside_tmux_carries_the_whole_base_line
test_configured_sources_outrank_the_fallback
test_render_with_genuinely_no_base_command_anywhere
test_a_self_referential_user_setting_does_not_recurse
test_the_payload_reaches_the_base_command_unchanged
test_real_operator_status_line_still_renders_every_segment
test_watcher_strip_empty_pool
test_watcher_strip_one_live
test_watcher_strip_live_plus_three_dormant
test_watcher_strip_full
test_watcher_strip_absent_pool
test_watcher_strip_row_stops_short_of_the_terminal_width
test_watcher_strip_right_margin_override
test_watcher_strip_narrow_width_drops_it
