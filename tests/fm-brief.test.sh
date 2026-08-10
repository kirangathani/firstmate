#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

# A testing skip is authorized at DISPATCH and nowhere else, so scaffolding takes
# no skip flag at all. This is what removes the silent half-specified skip: there
# is no longer a second invocation that could be given the flag on its own and
# quietly produce a brief the dispatch never authorized.
test_scaffold_refuses_every_testing_skip_flag() {
  local home out status flag id i=0
  home="$TMP_ROOT/skip-refuse-home"
  write_registry "$home"
  for flag in --local-skip --ci-skip --all-testing-skip --skip-testing; do
    i=$((i + 1))
    id="brief-skipflag-d$i"
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj "$flag" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "scaffolding must refuse $flag"
    assert_contains "$out" "is a bin/fm-spawn.sh flag" \
      "$flag refusal did not name the one script that owns a testing skip"
    assert_contains "$out" "bin/fm-spawn.sh $id" \
      "$flag refusal did not print the dispatch to run instead"
    assert_absent "$home/data/$id/brief.md" "a refused scaffold still wrote a brief"
  done
  pass "fm-brief.sh: scaffolding refuses every testing-skip flag and names the dispatch that owns it"
}

# apply_skip <home> <id> <mode> [<flag>]: the call bin/fm-spawn.sh makes.
apply_skip() {
  local home=$1 id=$2 mode=$3
  shift 3
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" --apply-testing-skip "$id" --mode "$mode" "$@" 2>&1
}

# scaffold_ship <home> <id> <project>: a real scaffolded ship brief.
scaffold_ship() {
  FM_HOME="$1" "$ROOT/bin/fm-brief.sh" "$2" "$3" >/dev/null 2>&1
}

# Every ship brief is born in its ordinary shape, with the three regions a
# dispatch may rewrite delimited and labelled with the skip they were written
# for. The label is what lets an apply tell "already correct" from "needs
# rewriting", so a dispatch that changes nothing rewrites nothing.
test_ship_brief_carries_labelled_skip_regions() {
  local home brief
  home="$TMP_ROOT/skip-regions-home"
  write_registry "$home"
  scaffold_ship "$home" brief-regions-e1 no-registry-proj
  brief="$home/data/brief-regions-e1/brief.md"
  assert_grep '<!-- fm:setup-steps -->' "$brief" "ship brief lost the setup-steps region"
  assert_grep '<!-- /fm:setup-steps -->' "$brief" "ship brief lost the setup-steps region end"
  assert_grep '<!-- fm:rule-1 -->' "$brief" "ship brief lost the rule-1 region"
  assert_grep '<!-- /fm:rule-1 -->' "$brief" "ship brief lost the rule-1 region end"
  assert_grep '<!-- fm:definition-of-done skip=none -->' "$brief" \
    "a freshly scaffolded ship brief must record that it carries no testing skip"
  assert_grep '<!-- /fm:definition-of-done -->' "$brief" "ship brief lost the definition-of-done region end"
  pass "fm-brief.sh: a ship brief carries the three machine-owned regions, labelled with its skip"
}

# The worker-facing half itself. The point of each assertion is that the worker
# is told the skip is deliberate and told exactly what to do instead, because an
# agent that reads a missing pipeline as a fault will try to repair it.
test_applied_testing_skip_briefs() {
  local home brief out
  home="$TMP_ROOT/skip-apply-home"
  write_registry "$home"

  scaffold_ship "$home" brief-localskip-c1 no-registry-proj
  brief="$home/data/brief-localskip-c1/brief.md"
  out=$(apply_skip "$home" brief-localskip-c1 no-mistakes --local-skip); status=$?
  expect_code 0 "$status" "applying --local-skip to a no-mistakes brief failed: $out"
  assert_grep "local testing skipped" "$brief" "--local-skip brief did not say testing is skipped"
  assert_grep "enforced, not requested" "$brief" "--local-skip brief did not say the skip is enforced"
  assert_grep "Do NOT run /no-mistakes" "$brief" "--local-skip brief still points at the pipeline"
  assert_no_grep "no-mistakes doctor" "$brief" "--local-skip brief kept the pipeline setup step"
  assert_no_grep "CI waiver handshake" "$brief" "--local-skip alone must not add the CI handshake"
  assert_no_grep "EOF" "$brief" "--local-skip brief leaked a heredoc marker"
  assert_grep '<!-- fm:definition-of-done skip=local -->' "$brief" \
    "the applied brief did not record which skip it now carries"

  scaffold_ship "$home" brief-ciskip-c2 direct-proj
  brief="$home/data/brief-ciskip-c2/brief.md"
  out=$(apply_skip "$home" brief-ciskip-c2 direct-PR --ci-skip); status=$?
  expect_code 0 "$status" "applying --ci-skip to a direct-PR brief failed: $out"
  assert_grep "CI waiver handshake" "$brief" "--ci-skip brief lost the waiver handshake"
  assert_grep "git rev-parse HEAD" "$brief" "handshake did not tell the worker how to read its head commit"
  assert_grep "blocked: ci-waiver needed for" "$brief" "handshake did not tell the worker how to ask for a signature"
  assert_grep "VERBATIM" "$brief" "handshake did not require the line to be copied verbatim"
  assert_grep "you cannot produce and must not try to produce" "$brief" \
    "handshake did not tell the worker the signature is not its to make"
  assert_no_grep "local testing skipped" "$brief" "--ci-skip must not claim the local pipeline was skipped"
  assert_no_grep "EOF" "$brief" "--ci-skip brief leaked a heredoc marker"

  scaffold_ship "$home" brief-allskip-c3 no-registry-proj
  brief="$home/data/brief-allskip-c3/brief.md"
  out=$(apply_skip "$home" brief-allskip-c3 no-mistakes --all-testing-skip); status=$?
  expect_code 0 "$status" "applying --all-testing-skip failed: $out"
  assert_grep "local testing skipped" "$brief" "--all-testing-skip brief lost the local skip"
  assert_grep "CI waiver handshake" "$brief" "--all-testing-skip brief lost the CI handshake"
  pass "fm-brief.sh: an applied testing skip renders the enforced skip and the waiver handshake"
}

# An applied skip must be exactly reversible, because bin/fm-spawn.sh applies on
# EVERY ship spawn: an unflagged dispatch of a brief that carries skip text has
# to put the ordinary instructions back, and it must put back the same bytes the
# scaffold wrote rather than an approximation of them.
test_applying_and_removing_a_skip_round_trips() {
  local home brief orig out
  home="$TMP_ROOT/skip-roundtrip-home"
  write_registry "$home"
  scaffold_ship "$home" brief-roundtrip-e2 no-registry-proj
  brief="$home/data/brief-roundtrip-e2/brief.md"
  orig="$home/roundtrip-original"
  cp "$brief" "$orig"

  out=$(apply_skip "$home" brief-roundtrip-e2 no-mistakes --all-testing-skip)
  assert_contains "$out" "testing skip none -> all" "the first apply did not report the transition it made"
  out=$(apply_skip "$home" brief-roundtrip-e2 no-mistakes --all-testing-skip)
  [ -z "$out" ] || fail "re-applying the same skip must rewrite nothing, got: $out"

  out=$(apply_skip "$home" brief-roundtrip-e2 no-mistakes)
  assert_contains "$out" "testing skip all -> none" "removing the skip did not report the transition"
  diff -u "$orig" "$brief" >/dev/null \
    || fail "removing an applied skip did not restore the scaffolded brief byte for byte"
  pass "fm-brief.sh: applying and removing a testing skip round-trips to the scaffolded bytes"
}

# The refusals. A brief that cannot be brought into agreement with its dispatch
# must stop the dispatch, never launch a worker whose instructions and whose
# durable record disagree.
test_apply_refuses_what_it_cannot_write() {
  local home brief out status
  home="$TMP_ROOT/skip-apply-refuse-home"
  write_registry "$home"

  # A brief with no machine-owned regions at all: silent when nothing is asked
  # of it, a refusal when a skip is.
  mkdir -p "$home/data/brief-legacy-e3"
  printf 'a brief written before this contract existed\n' > "$home/data/brief-legacy-e3/brief.md"
  out=$(apply_skip "$home" brief-legacy-e3 no-mistakes); status=$?
  expect_code 0 "$status" "an unflagged apply must leave a pre-contract brief alone: $out"
  assert_contains "$out" "predates the machine-written testing-skip regions" \
    "the no-op on a pre-contract brief was silent about what it did"
  out=$(apply_skip "$home" brief-legacy-e3 no-mistakes --all-testing-skip); status=$?
  [ "$status" -eq 0 ] && fail "a flagged apply must refuse a brief with no regions to write into"
  assert_contains "$out" "has no machine-written testing-skip regions" \
    "the refusal did not say why the brief could not be brought into agreement"

  # Half a set of markers is a structure the scaffold never produces, so it is
  # refused rather than partially rewritten.
  scaffold_ship "$home" brief-halfmarked-e4 no-registry-proj
  brief="$home/data/brief-halfmarked-e4/brief.md"
  grep -v -- '<!-- /fm:rule-1 -->' "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
  out=$(apply_skip "$home" brief-halfmarked-e4 no-mistakes --all-testing-skip); status=$?
  [ "$status" -eq 0 ] && fail "a brief missing a region marker must refuse"
  assert_contains "$out" "does not carry exactly one of each machine-written region marker" \
    "the malformed-marker refusal did not name the problem"

  # The same delivery-mode matrix bin/fm-spawn.sh checks, re-checked here so a
  # disagreement between the two stops rather than writing half an answer. Every
  # row of that matrix is exercised through THIS entry point, not just the one
  # that happened to be convenient: a defence-in-depth check tested on one row is
  # a check nobody has established holds on the others.
  scaffold_ship "$home" brief-modemismatch-e5 direct-proj
  out=$(apply_skip "$home" brief-modemismatch-e5 direct-PR --local-skip); status=$?
  [ "$status" -eq 0 ] && fail "applying --local-skip on a direct-PR brief must refuse"
  assert_contains "$out" "already runs no local pipeline" "direct-PR local-skip refusal wording"

  out=$(apply_skip "$home" brief-modemismatch-e5 direct-PR --all-testing-skip); status=$?
  [ "$status" -eq 0 ] && fail "applying --all-testing-skip on a direct-PR brief must refuse"
  assert_contains "$out" "already runs no local pipeline" "direct-PR all-testing-skip refusal wording"

  scaffold_ship "$home" brief-modemismatch-e8 no-registry-proj
  out=$(apply_skip "$home" brief-modemismatch-e8 no-mistakes --ci-skip); status=$?
  [ "$status" -eq 0 ] && fail "applying --ci-skip alone on a no-mistakes brief must refuse"
  assert_contains "$out" "cannot be honoured for a no-mistakes project" \
    "no-mistakes ci-skip-alone refusal wording"

  scaffold_ship "$home" brief-modemismatch-e9 local-proj
  out=$(apply_skip "$home" brief-modemismatch-e9 local-only --ci-skip); status=$?
  [ "$status" -eq 0 ] && fail "applying any skip on a local-only brief must refuse"
  assert_contains "$out" "does not apply to a local-only project" "local-only refusal wording"

  out=$(apply_skip "$home" brief-modemismatch-e9 local-only --skip-testing); status=$?
  [ "$status" -eq 0 ] && fail "--skip-testing on a local-only brief must refuse"
  assert_contains "$out" "nothing to skip on a local-only project" \
    "local-only --skip-testing refusal wording"

  out=$(apply_skip "$home" brief-modemismatch-e5 direct-PR --local-skip --ci-skip); status=$?
  [ "$status" -eq 0 ] && fail "two skip flags at once must refuse"
  assert_contains "$out" "pass exactly one testing-skip flag" "two-flag refusal wording"

  out=$(apply_skip "$home" brief-absent-e6 no-mistakes --all-testing-skip); status=$?
  [ "$status" -eq 0 ] && fail "applying to a brief that does not exist must refuse"
  assert_contains "$out" "needs a regular brief file" "the missing-brief refusal did not say what it needed"
  pass "fm-brief.sh: an apply refuses every brief it cannot bring into agreement with the dispatch"
}

# A brief is PROSE. It is not, and must never become, evidence that a skip was
# authorized: the only authority is the keyed token bin/fm-spawn.sh writes into
# state/<id>.meta. This is the property that keeps a worker - which can reach
# both its own brief and its own status file - from writing itself a skip.
test_applying_a_skip_grants_no_authority() {
  local home
  home="$TMP_ROOT/skip-noauth-home"
  write_registry "$home"
  mkdir -p "$home/state" "$home/config"
  scaffold_ship "$home" brief-noauth-e7 no-registry-proj
  apply_skip "$home" brief-noauth-e7 no-mistakes --all-testing-skip >/dev/null
  assert_absent "$home/state/brief-noauth-e7.meta" \
    "applying a skip to a brief wrote a durable task record"
  assert_grep "CI waiver handshake" "$home/data/brief-noauth-e7/brief.md" \
    "the applied brief lost the handshake this case depends on"
  # Nothing anywhere under the home now carries an authorization, so
  # bin/fm-ci-waiver.sh has nothing to find: the brief said "skip" and granted
  # nothing at all.
  if grep -rqE 'ci_skip=on|ci_skip_auth=|local_skip_auth=' "$home/state" "$home/config" 2>/dev/null; then
    fail "applying a skip to a brief produced something that looks like an authorization"
  fi
  pass "fm-brief.sh: applying a skip writes prose and grants no authority"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# The commit-early cadence rule is structural scaffold text, not per-task
# advice (see the header's rationale: hand-added cadence notes measurably
# failed, 2026-08-02). Every ship mode must carry it; scouts, whose worktree
# is scratch by contract, carry the incremental-report rule instead.
test_commit_cadence_is_scaffold_text() {
  local home id proj brief
  home="$TMP_ROOT/cadence-home"
  write_registry "$home"
  for id_proj in "brief-cadence-n1:no-registry-proj" "brief-cadence-d2:direct-proj" "brief-cadence-l3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1 \
      || fail "fm-brief.sh $id $proj exited non-zero"
    brief="$home/data/$id/brief.md"
    assert_grep "Commit early and often" "$brief" "$id: ship brief lost the commit-early cadence rule"
    assert_grep "discarded when this worktree is recycled" "$brief" "$id: ship brief lost the worktree-recycling justification"
  done
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-cadence-s4 no-registry-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout cadence scaffold exited non-zero"
  brief="$home/data/brief-cadence-s4/brief.md"
  assert_grep "Write findings into the report file as you go" "$brief" "scout brief lost the incremental-report rule"
  assert_no_grep "Commit early and often" "$brief" "scout brief wrongly carries the ship commit-cadence rule (its worktree is scratch)"
  pass "fm-brief: commit-early cadence is scaffold text in every ship mode; scouts carry the incremental-report rule"
}

# The lockstep property finding 3 is about: bin/fm-brief.sh and bin/fm-spawn.sh
# must refuse the same combinations with the same words, so a brief can never be
# scaffolded for a combination spawn will then refuse. They drifted while each
# held its own copy, so this asserts the matrix is stated in exactly ONE place
# and both scripts consume it - the structural fact, not just today's strings.
test_skip_matrix_has_exactly_one_owner() {
  local lib="$ROOT/bin/fm-testing-skip-lib.sh" f n
  assert_present "$lib" "the shared testing-skip owner is missing"
  for f in bin/fm-brief.sh bin/fm-spawn.sh; do
    assert_grep 'fm-testing-skip-lib.sh' "$ROOT/$f" "$f must consume the shared testing-skip owner"
    assert_grep 'fm_testing_skip_check_mode' "$ROOT/$f" "$f must use the shared delivery-mode matrix"
    assert_grep 'fm_testing_skip_check_args' "$ROOT/$f" "$f must use the shared argument-only rules"
    # The refusal text must exist only in the owner, never re-spelled downstream.
    n=$(grep -c 'cannot be honoured for a no-mistakes project' "$ROOT/$f" || true)
    [ "$n" -eq 0 ] || fail "$f re-spells the no-mistakes refusal; it belongs only in bin/fm-testing-skip-lib.sh"
  done
  n=$(grep -c 'cannot be honoured for a no-mistakes project' "$lib" || true)
  [ "$n" -eq 1 ] || fail "the no-mistakes refusal must be stated exactly once in the owner, found $n"
  pass "testing-skip matrix: stated once, consumed by both brief and spawn"
}


test_skip_matrix_has_exactly_one_owner
test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_scaffold_refuses_every_testing_skip_flag
test_ship_brief_carries_labelled_skip_regions
test_applied_testing_skip_briefs
test_applying_and_removing_a_skip_round_trips
test_apply_refuses_what_it_cannot_write
test_applying_a_skip_grants_no_authority
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_commit_cadence_is_scaffold_text
