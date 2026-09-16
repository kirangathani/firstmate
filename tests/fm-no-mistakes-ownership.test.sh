#!/usr/bin/env bash
# shellcheck disable=SC2016
# Static contract tests for crew-owned no-mistakes validation runs. The pinned
# strings carry markdown backticks, which are literal text here, not expansions.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

validate_contract() {
  awk '
    /^### Validate$/ { found = 1; next }
    found && /^### / { exit }
    found { print }
  ' "$ROOT/AGENTS.md"
}

test_worker_owns_synchronous_driver() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" 'The task worker that starts a no-mistakes run drives it to a terminal outcome' \
    "Validate contract does not assign the run to its initiating task worker"
  assert_contains "$contract" 're-attaching after every returned hold' \
    "Validate contract does not assign every attach to the task worker"
  assert_contains "$contract" 'keep driving each returned hold until completion or a genuinely new escalation' \
    "Validate contract does not require the task worker to keep driving each returned hold"
  # The two assertions above used to pin 'drives the pipeline and owns every
  # attach through the next gate or outcome'. Superseded 2026-09-16 with the
  # captain's approval (data/supersessions/firstmate.md, task
  # fm-brief-attach-ownership-a3): they pinned PHRASING, and the word "owns" was
  # itself the defect - three workers in one day read it as an authority claim
  # rather than a liveness obligation and idled on a parked run, one of them for
  # four hours. The obligation is unchanged and is asserted here more precisely.
  # This last one is what makes that concrete, so the contract cannot go back to
  # implying something else keeps a parked run alive.
  assert_contains "$contract" 'a run parked with no live attach is a stalled run' \
    "Validate contract does not state that a run left unattached stalls silently"
  pass "Validate contract assigns the complete driver loop to the initiating task worker"
}

test_every_attach_goes_through_the_one_owner() {
  local contract
  contract=$(validate_contract)

  # The raw `axi run`/`axi respond` is denied before it runs, so the contract has
  # to name the owner rather than the raw command - otherwise the instruction and
  # the enforcement disagree, and a worker reading only AGENTS.md is sent at a
  # command it cannot execute.
  assert_contains "$contract" 'always through `bin/fm-nm-attach.sh`' \
    "Validate contract does not route every attach through bin/fm-nm-attach.sh"
  # And it must stay a POINTER: the script's header is the one owner of why the
  # raw command is denied and of what its status line does.
  assert_contains "$contract" 'whose header owns' \
    "Validate contract restates the attach owner's mechanics instead of pointing at it"
  pass "Validate contract routes every attach through its one owner, as a pointer"
}

test_firstmate_never_responds_for_crew_run() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" 'Firstmate never responds to a gate for a crew-owned run.' \
    "Validate contract permits Firstmate to respond directly for a crew-owned run"
  pass "Validate contract forbids Firstmate from responding directly for a crew-owned run"
}

test_worker_owns_synchronous_driver
test_every_attach_goes_through_the_one_owner
test_firstmate_never_responds_for_crew_run
