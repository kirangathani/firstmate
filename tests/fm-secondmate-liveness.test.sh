#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate LIVENESS
# guarantee: bin/fm-backend.sh's fm_backend_agent_alive probe (dispatching to
# fm_backend_tmux_agent_alive / fm_backend_herdr_agent_alive) and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep() that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; recovery only respawns endpoints reported dead, and the
# watcher deliberately exempts secondmates from stale-pane detection (an idle
# secondmate pane is healthy by design). A dead-shell secondmate was therefore
# invisible to every existing check and sat dead indefinitely.
#
# The guarantees under test:
#   - fm_backend_tmux_agent_alive classifies a verified-harness foreground
#     process as alive, a bare shell as dead, and anything ambiguous
#     (including a bare interpreter name) as unknown - never dead.
#   - fm_backend_herdr_agent_alive is a thin wrapper over the already-verified
#     fm_backend_herdr_pane_agent_state husk classifier: dead/no-agent -> dead,
#     live -> alive, unknown -> unknown.
#   - fm_backend_agent_alive routes to the right per-backend classifier and
#     reports unknown for a backend with no verified classifier (never errors).
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep respawns a confidently
#     DEAD secondmate (killing the stale endpoint first, since the tmux
#     adapter refuses to create a same-named window over a live one), keeps
#     handled DEAD and ALIVE results silent, and never acts on an inconclusive
#     (UNKNOWN) reading.
#   - A secondmate window that is structurally GONE is respawned too, and a
#     target that merely unique-prefix-resolves to a NEIGHBOURING window is
#     neither trusted for the verdict nor handed to the kill: only an endpoint
#     still resolving to this secondmate's own window is ever killed.
#   - A record with no tmux_window_pinned=1 guarantee is read leniently (no
#     exact-label check), so a window that predates the pin requirement can
#     never become a false dead reading that duplicates a live supervisor -
#     and, because that leniency leaves its endpoint identity UNVERIFIED, such
#     a record is never acted on destructively either: a dead verdict for it
#     is reported and skipped, with no kill and no respawn.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_alive --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  list-panes)
    # Endpoint-liveness primitive (bin/backends/tmux.sh
    # fm_backend_tmux_target_exists): the classifier resolves the target
    # through it before reading a command name, so this live window answers
    # with its own '#{window_name}'.
    _t=""; _p=""
    for _a in "\$@"; do [ "\$_p" = "-t" ] && _t="\$_a"; _p="\$_a"; done
    printf '%s\n' "\${_t##*:}"
    exit 0 ;;
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_alive_classifies() {
  local fb

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-claude" claude)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live claude foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-codex" codex)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live codex foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-opencode" opencode)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live opencode foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-grok" grok)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live grok foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-zsh" zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare zsh foreground process should classify as dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-bash" bash)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare bash foreground process should classify as dead"

  # Defensive: this adapter strips a leading login-shell dash even though real
  # tmux 3.6a was observed to already normalize #{pane_current_command} itself
  # (docs/tmux-backend.md "Agent liveness probe").
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-dashzsh" -zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a defensively-stripped login-shell name should still classify as dead"

  # A bare interpreter name is ambiguous (pi's own launcher execs into a
  # generic "node" process - docs/tmux-backend.md "Known gap") - must be
  # unknown, never dead, so the sweep can never respawn on a false-dead read.
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an ambiguous bare-interpreter (node) foreground process should classify as unknown, never dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-vim" vim)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an unrecognized foreground process should classify as unknown"

  pass "fm_backend_tmux_agent_alive: alive/dead/unknown classification"
}

# The expected-label argument, on the classifier itself: tmux target matching
# is a unique-prefix match, so a gone window's target can resolve to a live
# NEIGHBOUR. A caller that names the owning window must not be given that
# neighbour's verdict, and a caller with no label keeps tmux's own resolution.
test_tmux_agent_alive_honors_expected_label() {
  local fb out
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-label" claude)

  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:fm-sm1 fm-sm1' "$ROOT")
  [ "$out" = alive ] || fail "a live window matching its own label should classify as alive, got '$out'"

  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:fm-sm1 fm-sm1-2' "$ROOT")
  [ "$out" = dead ] || fail "a window resolving to a name other than the expected label must not inherit its verdict, got '$out'"

  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_agent_alive tmux sess:fm-sm1 fm-sm1-2' "$ROOT")
  [ "$out" = dead ] || fail "the dispatcher must pass the expected label through to the tmux classifier, got '$out'"

  pass "fm_backend_tmux_agent_alive: an expected label is required to match the resolved window name"
}

# --- unit level: fm_backend_herdr_agent_alive -------------------------------
# Reuses the already-verified fm_backend_herdr_pane_agent_state husk
# classifier (docs/herdr-backend.md "Respawn idempotency" /
# "Agent liveness probe reuses the husk classifier"); this wrapper's own
# mapping logic is tested in isolation by overriding that classifier, exactly
# as tests/fm-backend-herdr.test.sh already overrides `sleep` in a bash -c
# string for the same kind of isolated-unit assertion.

test_herdr_agent_alive_maps_pane_agent_state() {
  local out

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "dead"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr pane_agent_state=dead should map to dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr pane_agent_state=no-agent (restored bare shell) should map to dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = alive ] || fail "herdr pane_agent_state=live should map to alive, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "unknown"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = unknown ] || fail "herdr pane_agent_state=unknown should stay unknown, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_alive "no-colon-target"' "$ROOT")
  [ "$out" = unknown ] || fail "an unparseable target should classify as unknown, got '$out'"

  pass "fm_backend_herdr_agent_alive: dead/no-agent->dead, live->alive, unknown->unknown"
}

# --- unit level: the generic fm_backend_agent_alive dispatcher --------------

test_agent_alive_dispatcher_routes_and_falls_back() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route tmux to fm_backend_tmux_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_alive herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route herdr to fm_backend_herdr_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "dispatcher should report unknown for a backend with no verified classifier, got '$out'"

  pass "fm_backend_agent_alive: routes tmux/herdr correctly, unknown for an unverified backend"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.1.1' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a tmux stub whose #{pane_current_command} answer is
# read fresh from $FM_TEST_PANE_CMD on every query (so a test can flip it
# between bootstrap runs), and which logs every new-window/kill-window call
# (the only two operations a respawn performs) to $FM_TMUX_CALL_LOG.
#
# Its list-panes arm models the three shapes the endpoint-liveness primitive
# has to tell apart, all switchable per run:
#   FM_TEST_PANE_GONE=1        - the RECORDED window has closed. A window this
#                                fake has since been asked to create is live
#                                again, so a respawn's own sends still work.
#   FM_TEST_PANE_RESOLVES_TO=X - the target resolves, but to a differently
#                                named window: real tmux target matching is a
#                                unique-prefix match, so "firstmate:fm-sm1"
#                                lands on a neighbouring "fm-sm1-2" once the
#                                secondmate's own window is gone.
#   FM_TEST_TMUX_DOWN=1        - the server does not answer the two reads the
#                                sweep makes (list-panes, list-sessions), the
#                                case that must stay inconclusive.
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-sessions)
    # fm_backend_tmux_agent_alive's server-down discriminator: a target that
    # does not resolve is only `dead` if the server itself still answers.
    [ "${FM_TEST_TMUX_DOWN:-0}" = 1 ] && exit 1
    printf 'firstmate: 1 windows\n'
    exit 0 ;;
  list-panes)
    # Endpoint-liveness primitive (bin/backends/tmux.sh
    # fm_backend_tmux_target_exists): the classifier resolves the target
    # through it before reading a command name, and real tmux prints the
    # resolved '#{window_name}'.
    [ "${FM_TEST_TMUX_DOWN:-0}" = 1 ] && exit 1
    _t=""; _p=""
    for _a in "$@"; do [ "$_p" = "-t" ] && _t="$_a"; _p="$_a"; done
    _w=${_t##*:}
    if [ "${FM_TEST_PANE_GONE:-0}" = 1 ] \
       && ! grep -q -- "-n $_w " "${FM_TMUX_CALL_LOG:-/dev/null}" 2>/dev/null; then
      exit 1
    fi
    printf '%s\n' "${FM_TEST_PANE_RESOLVES_TO:-$_w}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *pane_current_command*) printf '%s\n' "${FM_TEST_PANE_CMD:-zsh}"; exit 0 ;; esac; done
    exit 0 ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    exit 0 ;;
  list-windows|has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window> [harness] [pinned]: a plain (non-git) secondmate
# home - the probe/respawn machinery under test never requires the home to be a
# real worktree; a non-git home just makes the unrelated fast-forward sweep log
# a harmless "not a git repo" skip.
#
# <pinned> defaults to 1: bin/fm-spawn.sh writes tmux_window_pinned=1 for every
# tmux spawn now that fm_backend_tmux_create_task refuses to create a window it
# could not pin, so a pinned record is what the sweep normally reads. Pass 0 for
# a record written before that requirement, which must be read leniently
# (fm_backend_expected_label_of_meta, bin/fm-backend.sh).
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude} pinned=${5:-1}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
    if [ "$pinned" = 1 ]; then printf 'tmux_window_pinned=1\n'; fi
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a successfully respawned secondmate should be handled silently"
  assert_contains "$(cat "$log")" "kill-window -t firstmate:fm-sm1" \
    "the stale endpoint must be killed before respawn (tmux refuses a same-named window over a live one)"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  pass "sweep: a confirmed-dead secondmate endpoint is killed and respawned"
}

test_sweep_respawns_structurally_gone_window() {
  local w fb tmuxfb log out
  w=$(new_world sweep-gone)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # The whole window is gone, not just its agent: the classifier must reach
  # `dead` from the target failing to RESOLVE, without ever reading a command
  # name (a read that would answer from the session's current window). The
  # pane command is left at "claude" precisely so an inherited read would say
  # alive and leave the dead secondmate unrespawned.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_TEST_PANE_GONE=1)

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped" \
    "a structurally gone window is a confident dead reading, not an inconclusive one"
  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed" \
    "the respawn of a gone secondmate window should succeed"
  assert_contains "$(cat "$log")" "new-window" \
    "a secondmate whose window has closed must actually be relaunched"
  # Nothing was killed because nothing of ours was there to kill: the kill is
  # guarded on the endpoint still resolving to this secondmate's own window,
  # so an unresolvable target can never be handed to tmux's prefix matching.
  assert_not_contains "$(cat "$log")" "kill-window" \
    "a target that no longer resolves must not be handed to kill-window"
  pass "sweep: a structurally gone window is respawned, with no kill against an unresolvable target"
}

test_sweep_never_touches_a_prefix_resolved_neighbour() {
  local w fb tmuxfb log out
  w=$(new_world sweep-prefix)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # The secondmate's own window is gone, and "firstmate:fm-sm1" now
  # unique-prefix-resolves to a LIVE ordinary task's window "fm-sm1-2" whose
  # agent is running. Without the owning-label check the sweep would read that
  # neighbour's "claude" and leave the dead secondmate alone forever; with it,
  # the secondmate is respawned and the neighbour is never killed.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_TEST_PANE_RESOLVES_TO=fm-sm1-2)

  assert_contains "$(cat "$log")" "new-window" \
    "a secondmate whose window merely prefix-resolved to a neighbour must still be respawned"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "the neighbouring window a stale target resolved to must never be killed"
  pass "sweep: a target that prefix-resolves to a differently-named window is neither trusted nor killed"
}

test_sweep_stays_inconclusive_when_the_server_is_down() {
  local w fb tmuxfb log out
  w=$(new_world sweep-server-down)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # An unresolvable target is only `dead` when the tmux server itself still
  # answers. With the server down nothing was confidently read, so a momentary
  # glitch can never license a respawn (which would duplicate a live agent).
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_TEST_TMUX_DOWN=1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an unanswering tmux server should be reported as an inconclusive probe"
  [ ! -s "$log" ] || fail "an unanswering tmux server must NEVER trigger a kill or respawn: $(cat "$log")"
  pass "sweep: an unanswering tmux server stays inconclusive and is never acted on"
}

test_sweep_reads_an_unpinned_record_leniently() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unpinned)
  # A meta written before fm_backend_tmux_create_task made the window-name pin
  # a hard requirement: its window may legitimately have been renamed, so the
  # exact-label check is NOT applied and the endpoint is read through tmux's
  # own resolution. The window here resolves to a differently-named live
  # window running an agent, which must therefore read alive rather than
  # become a false dead reading that kills and respawns a live supervisor.
  add_sm_home "$w" sm1 firstmate:fm-sm1 claude 0
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_TEST_PANE_RESOLVES_TO=fm-sm1-renamed)

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "an unpinned record reading alive through tmux's own resolution should be silent"
  [ ! -s "$log" ] || fail "a record with no pin guarantee must never become a false dead reading: $(cat "$log")"
  pass "sweep: a record with no window-name pin guarantee is read leniently, never as a false dead"
}

test_sweep_refuses_to_act_on_an_unpinned_record() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unpinned-dead)
  # Same unverified record, now reading DEAD: its window resolves to a pane
  # sitting at a bare shell. Leniency answered the verdict, but it cannot
  # answer WHOSE window that was - tmux target matching is a unique-prefix
  # match, so the resolved pane may belong to a neighbouring crewmate. Acting
  # would either destroy that stranger's window or duplicate a live agent, so
  # the sweep must refuse both halves and report the record instead.
  add_sm_home "$w" sm1 firstmate:fm-sm1 claude 0
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: endpoint identity unverifiable" \
    "a dead reading on a record with no pin guarantee should be reported as unverifiable"
  [ ! -s "$log" ] || fail "an unverifiable record must NEVER be killed or respawned: $(cat "$log")"
  pass "sweep: a dead verdict on an unpinned record is refused - no kill, no respawn"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "an already-live secondmate should be handled silently"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"
  pass "sweep: an already-live secondmate is left untouched (no kill, no respawn)"
}

test_sweep_never_acts_on_inconclusive_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unknown)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # "node" is the ambiguous bare-interpreter case (docs/tmux-backend.md
  # "Known gap") - ANY reading less than confident-dead must never respawn.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an inconclusive (unknown) probe reading should be reported as skipped"
  [ ! -s "$log" ] || fail "an inconclusive reading must NEVER trigger a kill or respawn (would risk a duplicate agent): $(cat "$log")"
  pass "sweep: a transient/unknown probe reading is reported but never acted on"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an unverified harness should not let a dead-looking endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must NEVER trigger a kill or respawn: $(cat "$log")"
  pass "sweep: an unverified harness makes a dead-looking probe inconclusive"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead -> respawned silently (kill + new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: respawned" "round 1 should handle the successful respawn silently"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn window operations"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should handle the already-live secondmate silently"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

test_tmux_agent_alive_classifies
test_tmux_agent_alive_honors_expected_label
test_herdr_agent_alive_maps_pane_agent_state
test_agent_alive_dispatcher_routes_and_falls_back
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_respawns_structurally_gone_window
test_sweep_never_touches_a_prefix_resolved_neighbour
test_sweep_stays_inconclusive_when_the_server_is_down
test_sweep_reads_an_unpinned_record_leniently
test_sweep_refuses_to_act_on_an_unpinned_record
test_sweep_leaves_alive_secondmate_untouched
test_sweep_never_acts_on_inconclusive_reading
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta

echo "# all fm-secondmate-liveness tests passed"
