#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Test-keep gate: after recording and before merging, bin/fm-assert-tests-kept.sh
# must confirm every test assertion present on the authoritative base is still
# present (check 1, by name) and still passing against the branch's code
# (check 2, by running the base's own test files). A missing or failing
# assertion is a hard refusal with no override flag, and a check that cannot
# run at all also refuses, because a merge that cannot be verified must not
# proceed silently. An assertion check 2 could not execute at all is a third
# finding class whose blocking is per-project (see "Unexecuted findings" below).
# An assertion the base test file NAMED DIFFERENTLY on check 2's two runs is a
# fourth class, `unstable:`, and it refuses unconditionally for every project:
# it means the base's own test builds its assertion name from a runtime value,
# so the gate cannot tell a vanished assertion from a moving name, and it has
# never been able to verify that assertion at all. The fix is in the base's test
# (a constant assertion name), and bin/fm-assert-tests-kept.sh's header owns why.
# This gate is firstmate-side, so it protects every repo including ones with no
# PR CI.
#
# Check 2's cost control, and why this script is what makes it honest: running
# every base test file twice is the dominant cost of landing a PR (~20-35
# minutes on firstmate itself). bin/fm-assert-tests-kept.sh can skip a base test
# file the branch's copy matches BYTE FOR BYTE, because the branch's own suite
# runs that identical file against that same branch code - but only when a
# caller passes --assume-branch-suite-green to assert that suite is verified
# green. That assertion is THIS script's to make, and it rests on the
# checks-green gate below refusing to merge a PR whose checks are failing,
# pending or unreadable: within one run of this command, a skip taken under the
# flag can never carry a merge whose suite was not verified green. The gate's
# order in the file does not weaken that - both must pass before the merge, and
# a conjunction does not care which is evaluated first.
# The flag is therefore WITHHELD in exactly the two cases where the checks-green
# gate cannot supply the premise, and check 2 then runs in full as it always has:
#   - the task carries ci_skip=on: the captain waived the PR's CI test jobs, so
#     the branch's suite never ran on the PR at all. This is precisely when the
#     kept-tests gate is the only test evidence the merge has, which is what the
#     waiver banner below already claims, so it must not be the run that
#     shortcuts it.
#   - $FM_HOME/data/no-pr-ci/<project> is present: the project intentionally
#     runs no PR CI, so a zero-check rollup passes the checks-green gate without
#     any suite having run.
# Every identifier the check does skip is reported by it as `assumed-covered:`
# and echoed here as a note, so a merge log never shows a green over assertions
# nothing re-ran. The class does not block: it is accounted for, not a finding.
#
# A refusal has two causes the coder cannot reliably tell apart. Rebase damage:
# the conflict resolution ate the base's behavior; redoing the resolution makes
# the base's assertion pass again and the gate clears itself. Deliberate
# supersession: the branch intentionally changes behavior the base asserted;
# that is a product decision, so it is escalated needs-decision to the captain
# and never decided by the coder or by firstmate.
#
# The supersession record is the ONE deliberate exception to "no suppression":
# without it a legitimate behavior change could never merge, because the base's
# old assertion would keep failing no matter what the coder does.
#   - Location: $FM_HOME/data/supersessions/<project>.md, where <project> is
#     the basename of the task meta's project= path. It lives in firstmate's
#     gitignored data/, never inside the project (firstmate must never write
#     under projects/), so it is private to this fleet by construction.
#   - Absent means empty means no approvals. It is created lazily by the
#     captain's approval, never auto-generated - not at project registration,
#     not at session start, not by this script.
#   - Entry format, one entry per line. This header is the ONE owner of the
#     entry grammar; every other mention of it elsewhere is a cross-reference.
#       - id: <file>::<name> | project: <project> | date: <YYYY-MM-DD> | reason: <captain's stated reason>
#       - ids: <glob> | project: <project> | kind: <class> | date: <YYYY-MM-DD> | reason: <captain's stated reason>
#     Fields:
#       id      an exact <file>::<name>, matched by string equality. Exactly one
#               of id or ids must be present, and it must be the entry's first
#               field so a line is recognizable as an entry at all. Its value may
#               not contain " | ", because that is this grammar's own field
#               separator, so an identifier holding it is inherently ambiguous;
#               such an entry is refused rather than guessed at.
#       ids     a glob matched against the identifier with bash pattern matching
#               ([[ "$ident" == $glob ]]), e.g. `src/legacy/*::*` or `*`. This is
#               the batch form: one entry covers many identifiers arising from a
#               single cause, such as a dependency bump. Its value carries the
#               same " | " restriction as id.
#       project must equal <project> (the record's own project).
#       kind    OPTIONAL, restricting which finding class the entry excuses:
#               missing, failing, unexecuted, unstable, or any. An ABSENT kind
#               means any,
#               which is what keeps every pre-existing entry behaving exactly as
#               it did before this field existed.
#       date    must be YYYY-MM-DD.
#       reason  the captain's stated reason. It must be the LAST field, because
#               it is the only field allowed to contain " | ". An entry with any
#               recognized field written after reason is refused rather than
#               parsed loosely: that field would be swallowed into the reason
#               text, and a swallowed kind would silently widen the entry to any.
#               The after-reason check matches the field marker without requiring
#               a space after its colon, so a one-character typo like
#               `reason: bumped runner | kind:unexecuted` is refused too.
#     Field order is otherwise free (id/ids first, reason last).
#     An entry is NOT honored - warned about and ignored - when it carries both
#     id and ids, is missing project, date, or reason, has an empty field, has a
#     malformed date, names a different project, carries an unparseable or
#     unrecognized field name, repeats a recognized field, or names a kind
#     outside the five above. A "- " bullet holding pipe-delimited `key: value`
#     fields but not starting with id: or ids: is warned about too, so a
#     forgotten identifier is visible rather than silently skipped. Any other
#     line (a heading, prose, a blank line) is ignored without comment.
#     Why those last cases refuse instead of taking a best guess: every other
#     malformed case in this grammar fails closed, and this file governs what is
#     permitted to BYPASS the merge gate, so silent scope-widening is the one
#     behavior it must never have. A repeated field taking its last value and a
#     typo'd field swallowed into reason both widen an entry past what the
#     captain wrote, which is exactly that failure.
#   - SAFETY: kind is a safety feature, not a convenience. A batch written
#     `ids: * | kind: unexecuted` excuses only unexecuted findings, so it can
#     never silently excuse a genuinely deleted (missing) or rewritten (failing)
#     assertion. A batch entry WITHOUT kind is a loaded gun: `ids: *` with no
#     kind excuses every class for every identifier in that project, which
#     disables this gate for that project entirely. That is the documented
#     back-compat behavior of an absent kind, not an oversight, so always write
#     the narrowest kind that covers the approved cause.
#   - Only the captain approves an entry. There is no mechanical guarantee of
#     this: nothing physically prevents another writer, and the required fields
#     exist so a fabricated entry is visible rather than silent.
#
# Unexecuted findings and per-project enablement: check 2 reports
# `unexecuted: <file>::<name>` for a base assertion it could not execute at all
# against the branch, so that assertion is name-checked only. A green result
# that means "nothing ran" is worse than no result because it reads as verified,
# which is why the detector exits non-zero for these too. Whether they BLOCK is
# a per-project decision, read here at MERGE time rather than from the task's
# meta, so enabling a project takes effect for already-in-flight tasks:
#   - Marker: $FM_HOME/data/exec-gate/<project> (any file or directory).
#     Present means unexecuted findings count toward refusal for that project,
#     subject to supersession like any other class. Absent means warn-only: each
#     one is printed as `note: unexecuted (not gated for <project>): <ident>` and
#     does not block, which is the behavior every project had before this class
#     existed.
#   - Default absent for every project, so the class ships inert and the flip is
#     made one project at a time. Same ownership model as the supersession
#     record above: firstmate's gitignored data/, lazily created, captain-
#     controlled, never auto-generated by any script.
#
# An unstable finding's identifier is the name the base RUN reported, which by
# definition differs run to run, so an `id:` entry can never match one twice; a
# supersession over the class needs the `ids:` glob form, and the honest answer is
# to fix the test rather than excuse it.
#
# Decision rule, which this header owns: every
# missing:/failing:/unexecuted:/unstable:
# line is parsed, the exec-gate policy is applied to the unexecuted ones, and
# supersession excusal is applied to whatever is left counted. The merge is then
# refused iff any COUNTED finding is unexcused, plus two independent refusals: a
# findings exit whose output held no parseable finding line at all, and an exit
# other than 0 or 1 (the check could not run). The decision must never be taken
# from a single class's path or from the detector's exit code alone: doing so is
# how an unexecuted finding riding alongside an EXCUSED missing/failing one
# could be silently ignored, which is the exact inverse of what this gate is for.
#
# Checks-green gate: after the test-keep gate and before the merge, the PR's
# own CI must be green, enforcing AGENTS.md's "never merge a red PR" in code
# rather than discipline. The PR's current check rollup is read with
# `gh pr view <url> --json statusCheckRollup`, addressed by PR URL so it never
# depends on the current branch. `gh pr checks` is unsuitable here: its exit
# code conflates pending with failing (exit 8 for merely-pending checks,
# reproduced 2026-08-02 on microsoft/vscode#328615), and without an argument it
# fails outright from a detached HEAD ("could not determine current branch",
# reproduced same day), which every gate worktree is.
#
# Each rollup entry is classified by this table, the ONE owner of the mapping:
#   - passing: a CheckRun COMPLETED with conclusion SUCCESS, NEUTRAL, or
#     SKIPPED, or a StatusContext in state SUCCESS.
#   - failing: a CheckRun COMPLETED with conclusion FAILURE, CANCELLED,
#     TIMED_OUT, ACTION_REQUIRED, STALE, or STARTUP_FAILURE, or a
#     StatusContext in state FAILURE or ERROR.
#   - pending: a CheckRun still queued or running (status QUEUED, IN_PROGRESS,
#     PENDING, WAITING, or REQUESTED), or a StatusContext in state PENDING or
#     EXPECTED.
# Any failing check refuses with the check named (a red PR). Otherwise any
# pending check refuses with a DISTINCT message, because the remedy differs:
# a red PR needs fixing, a pending one needs waiting. An entry the table
# cannot classify refuses as unverified rather than guessed at, and a rollup
# the query cannot read at all (gh error, no network, no auth) also refuses as
# unverified: a merge that cannot be verified must not proceed silently.
#
# ZERO checks is NOT green. An empty rollup is indistinguishable from CI that
# has not reported yet, which is the same false-green shape the unexecuted:
# class above exists to prevent. Whether an empty rollup may merge is a
# per-project captain decision:
#   - Marker: $FM_HOME/data/no-pr-ci/<project> (any file or directory).
#     Present means the captain has confirmed the project intentionally runs
#     no PR CI, so a zero-check PR proceeds with a note. Absent means a
#     zero-check PR refuses. Same ownership model as the two records above:
#     firstmate's gitignored data/, lazily created, captain-controlled, never
#     auto-generated by any script.
#   - A durable marker was chosen over a per-call flag because a flag would be
#     re-supplied mechanically on every refusal - the exact reflex this gate
#     exists to stop - while the marker records one considered decision per
#     project, made once, away from the pressure of a blocked merge.
#
# The attestation exemption: the ONE check whose failure this gate may excuse,
# and the only grant anywhere in this script. That check is
# `PR must be raised via no-mistakes`, the `check` job of that name in
# .github/workflows/no-mistakes-required.yml. It fails on every PR the pipeline
# did not raise, and firstmate itself authorizes exactly two ways for a PR to be
# raised without the pipeline, so without this the checks-green gate above
# refuses every such PR permanently - which is precisely the state this exemption
# was added to end.
#
# MATCHED BY EXACT NAME, never a prefix, a substring, or a pattern. Renaming that
# job therefore stops the exemption applying, in the safe direction: the renamed
# check is no longer recognized, so it is no longer excused, so a failing one
# refuses the merge. A rename can only ever cost a merge, never grant one.
# tests/fm-pr-merge.test.sh asserts the constant below still equals that
# workflow's job name, so the drift is caught by firstmate's own CI rather than
# discovered at a captain's next merge.
#
# TWO AUTHORITIES, either of which excuses that one check. Both are read on the
# captain's machine, from records the PR cannot influence:
#   - A captain-authorized testing skip on THIS task, carrying a signature this
#     home's config/ci-waiver-secret reproduces for this task id: local_skip=on
#     with a valid local_skip_auth=, or ci_skip=on with a valid ci_skip_auth=.
#     The bare flag line is NOT authority. A worker appends its status lines into
#     this same state directory, so it can append the flag line to its own record
#     just as easily; the token is an HMAC minted only by bin/fm-spawn.sh at
#     dispatch. bin/fm-ci-waiver-lib.sh owns both payload domains and states the
#     residual same-user limit no design in this space can remove. With no
#     secret, no token, a wrong token, or no node to verify with, nothing
#     verifies, so nothing is excused.
#   - The project's delivery mode, resolved through bin/fm-project-mode.sh, is
#     direct-PR. That mode is DEFINED as "push and open a PR without the
#     pipeline", so its PRs cannot carry the attestation by construction. The
#     registry it reads, $FM_HOME/data/projects.md, is firstmate's own private
#     navigation record: firstmate and bin/fm-home-seed.sh are the only writers,
#     and no brief, scaffold, or status protocol ever points a worker at it, so
#     unlike the flag line above it is not a file a worker is invited to touch.
#     An unregistered project, an unknown mode, or an absent registry all resolve
#     to no-mistakes, which grants nothing.
#
# WHAT IT DOES NOT GRANT, all enforced below:
#   - Any OTHER failing check still refuses, including a second failing check on
#     an otherwise-exempted PR.
#   - A pending check still refuses. Only a COMPLETED failure of that one name is
#     excusable, because "not finished yet" and "authorized to be red" are
#     different states with different remedies.
#   - A check the classification table cannot read still refuses as unverified.
#   - The kept-tests gate above still runs, and still refuses, unchanged.
#   - An exempted check is not evidence that anything ran, so it does not count
#     toward "this PR has checks": a rollup whose only entries were exempted is
#     treated exactly like the zero-check case above and refuses without the
#     captain's no-pr-ci marker. Counting it would rebuild the false-green shape
#     that whole rule exists to prevent.
#   - Nothing about the merge method, the recording step, or any other gate.
# Every merge that uses the exemption prints a loud banner naming the check and
# the authority, before the gates and again on the line before the merge, on the
# same model as the waiver banner below.
#
# Testing-waiver disclosure: when the task was dispatched with a testing skip
# (bin/fm-spawn.sh's --local-skip / --ci-skip / --all-testing-skip), this script
# prints a loud banner naming exactly what was skipped, both before the gates run
# and again on the line immediately before the merge, so a waived PR is never
# indistinguishable in the log from one that actually passed. Three properties
# of that disclosure are deliberate:
#   - It is read from the task's own state/<id>.meta, on the captain's machine,
#     and never from the PR, the branch, or the CI result. Nothing the PR carries
#     can add, remove, or alter this banner. A worker reaches that meta file to
#     the same extent it reaches its own status file, so it could ADD a spurious
#     banner to its own merge log; it cannot remove one, and per the next bullet
#     an unsigned flag grants nothing, so the most that buys is noise.
#   - It grants exactly one thing, and only when signed: a signed skip is one of
#     the two authorities that excuse the single named attestation check above.
#     Nothing else. Every other gate still applies unchanged, including the
#     zero-checks refusal, so a project whose CI is fully waived must still leave
#     at least one non-exempted check reporting or the merge refuses as
#     unverified exactly as it did before. Note which half needs the signature:
#     the GRANT does, the BANNER deliberately does not, so disclosure appears on
#     the bare flag and a merge log can never be made quieter by withholding a
#     token.
#   - The kept-tests gate above runs under EVERY flag combination and no skip
#     flag can disable it. It is firstmate-side rather than CI-side, and it is
#     what catches a rebase quietly eating a base assertion - which is precisely
#     the failure a PR with no test evidence cannot catch any other way. Under
#     ci_skip=on it runs at FULL cost, with no identical-file skip, for exactly
#     that reason: it is then the merge's only test evidence, so it has no green
#     branch suite to lean on and must not behave as though it had one.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-supersession-lib.sh
. "$SCRIPT_DIR/fm-supersession-lib.sh"
# shellcheck source=bin/fm-ci-waiver-lib.sh
. "$SCRIPT_DIR/fm-ci-waiver-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

PROJ_PATH=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
PROJ_NAME=
[ -z "$PROJ_PATH" ] || PROJ_NAME=$(basename "$PROJ_PATH")
SUPERSESSIONS_FILE="$FM_HOME/data/supersessions/$PROJ_NAME.md"
EXEC_GATE_FILE="$FM_HOME/data/exec-gate/$PROJ_NAME"
NO_PR_CI_FILE="$FM_HOME/data/no-pr-ci/$PROJ_NAME"

# --- testing-waiver disclosure (contract in this script's header) -------------
LOCAL_SKIP=off
CI_SKIP=off
if grep -qx 'local_skip=on' "$META"; then LOCAL_SKIP=on; fi
if grep -qx 'ci_skip=on' "$META"; then CI_SKIP=on; fi

waiver_banner() {  # <where>
  [ "$LOCAL_SKIP" = on ] || [ "$CI_SKIP" = on ] || return 0
  {
    echo "================================================================================"
    echo "TESTING WAIVER ($1): this PR does NOT carry full test evidence."
    echo "  task:            $ID"
    if [ "$LOCAL_SKIP" = on ]; then
      echo "  local pipeline:  SKIPPED - the captain dispatched this task with the local"
      echo "                   validation pipeline switched off, so no review, test, lint,"
      echo "                   or docs stage ever ran against this branch."
    fi
    if [ "$CI_SKIP" = on ]; then
      echo "  CI test jobs:    WAIVED - the captain authorized a CI waiver for this task,"
      echo "                   so the expensive lint and test jobs did not run on the PR."
    fi
    echo "  still enforced:  the base's own test assertions (fm-assert-tests-kept.sh) and"
    echo "                   every PR check gate below; no skip flag can disable either."
    if [ "$CI_SKIP" = on ]; then
      echo "                   With CI waived there is no green branch suite to lean on, so"
      echo "                   EVERY base test file is re-run here rather than assumed"
      echo "                   covered - slower, and the only test evidence this merge has."
    fi
    echo "================================================================================"
  } >&2
}
waiver_banner "before gates"

# --- the attestation exemption (contract in this script's header) -------------
# The ONE check name whose failure may be excused, and only ever by exact string
# equality against a rollup entry's name. It is duplicated from
# .github/workflows/no-mistakes-required.yml's `check` job by necessity - this
# script cannot read a workflow that lives in another repository - so
# tests/fm-pr-merge.test.sh asserts the two still agree.
ATTESTATION_CHECK_NAME='PR must be raised via no-mistakes'
CI_WAIVER_SECRET_FILE="$CONFIG/ci-waiver-secret"
# Newline-delimited rather than an array so an EMPTY value stays safe to expand
# under `set -u` on every Bash this repo supports, stock macOS 3.2 included.
# Empty means no authority, which is what makes it the exemption's own test.
ATTESTATION_AUTHORITY=
add_attestation_authority() {
  ATTESTATION_AUTHORITY="${ATTESTATION_AUTHORITY}${ATTESTATION_AUTHORITY:+
}$1"
}

# signed_skip_authority: 0 iff this task's meta pairs a testing-skip flag with a
# token this home's own secret reproduces for THIS task id. The pairing is the
# whole point: the flag line alone is reachable by the worker, the token is not.
# Every failure path here - no flag, no token, a malformed token, no secret, no
# node - returns non-zero, so an unverifiable claim is never an authorization.
signed_skip_authority() {  # <meta-field> <checker-fn> <label>
  local field=$1 checker=$2 label=$3 auth
  auth=$(grep -m1 "^$field=" "$META" | cut -d= -f2- || true)
  if [ -z "$auth" ] || ! fm_ci_waiver_valid_sig "$auth"; then
    echo "note: this task records a $label but no usable $field= signature, so the skip authorizes nothing here" >&2
    return 1
  fi
  if ! fm_ci_waiver_secret_readable "$CI_WAIVER_SECRET_FILE"; then
    echo "note: this task records a $label with a $field= signature, but this home has no signing key at $CI_WAIVER_SECRET_FILE to check it against, so the skip authorizes nothing here" >&2
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "note: node is unavailable, so this task's $field= signature cannot be checked and the skip authorizes nothing here" >&2
    return 1
  fi
  if ! "$checker" "$ID" "$auth" < "$CI_WAIVER_SECRET_FILE"; then
    echo "error: this task records a $label whose $field= signature this home's key does NOT reproduce for $ID; treating it as unauthorized" >&2
    echo "error: that pairing means the flag line was not written by this home's own dispatch - re-dispatch the task with the flag rather than editing its record" >&2
    return 1
  fi
  return 0
}

# Resolves ATTESTATION_AUTHORITY, and is called ONLY when that named check is
# actually failing on this PR, so an ordinary green merge pays none of its cost
# and prints none of its notes.
resolve_attestation_exemption() {
  local mode yolo
  if [ "$LOCAL_SKIP" = on ] \
    && signed_skip_authority local_skip_auth fm_ci_waiver_dispatch_local_check "captain-authorized local-pipeline skip"; then
    add_attestation_authority "a captain-authorized local-pipeline skip on this task, signed at dispatch by this home's own key"
  fi
  if [ "$CI_SKIP" = on ] \
    && signed_skip_authority ci_skip_auth fm_ci_waiver_dispatch_check "captain-authorized CI skip"; then
    add_attestation_authority "a captain-authorized CI skip on this task, signed at dispatch by this home's own key"
  fi
  if [ -n "$PROJ_NAME" ]; then
    read -r mode yolo <<EOF_MODE
$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" "$PROJ_NAME")
EOF_MODE
    : "$yolo"
    if [ "$mode" = direct-PR ]; then
      add_attestation_authority "$PROJ_NAME is registered as a direct-PR project, whose PRs are raised without the pipeline by design"
    fi
  fi
}

attestation_banner() {  # <where>
  [ -n "$ATTESTATION_AUTHORITY" ] || return 0
  local line
  {
    echo "================================================================================"
    # Deliberately states what was EXCUSED rather than what the merge will do:
    # this prints before the remaining refusals too, so a run that still refuses
    # on a pending or unrelated red check must not read as an announced merge.
    echo "ATTESTATION CHECK EXEMPTED ($1): one FAILING PR check was excused."
    echo "  task:            $ID"
    echo "  check:           $ATTESTATION_CHECK_NAME"
    echo "  why it is red:   this PR was not raised through the no-mistakes pipeline, so"
    echo "                   its body carries no pipeline attestation for that check to find."
    echo "  authority:"
    while IFS= read -r line; do
      echo "                   - $line"
    done <<EOF_AUTH
$ATTESTATION_AUTHORITY
EOF_AUTH
    echo "  still enforced:  every OTHER check must be green, no check may be pending, an"
    echo "                   unreadable check still refuses, and the base's own test"
    echo "                   assertions still gate this merge. Only the check named"
    echo "                   above was excused, matched by its exact name."
    echo "================================================================================"
  } >&2
}

# supersession_approved <file>::<name> <finding-class>: 0 iff this project's
# supersession record holds a fully-formed captain-approved entry that covers
# that identifier for that finding class (grammar in this script's header,
# which stays this file's to own). The matcher itself lives in
# bin/fm-supersession-lib.sh so the read-only viewer that shows a captain what
# this gate will excuse (bin/fm-nm-flow.sh) reads the record through the exact
# same parser rather than a second one that could drift from it.
supersession_approved() {
  fm_supersession_approved "$SUPERSESSIONS_FILE" "$PROJ_NAME" "$1" "$2"
}

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

KEPT_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-kept.XXXXXX")
CHECKS_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-checks.XXXXXX")
trap 'rm -f "$KEPT_OUT" "$CHECKS_ERR"' EXIT

# --- the premise behind check 2's identical-file skip (contract in this
# --- script's header) ---------------------------------------------------------
# Decided from facts this script already holds, BEFORE the check runs, so no
# reordering of the gates is needed to establish it honestly.
KEPT_ARGS=()
FULL_RERUN_REASON=
if [ "$CI_SKIP" = on ]; then
  FULL_RERUN_REASON="this task's CI test jobs were waived, so the branch's own suite never ran on the PR"
elif [ -n "$PROJ_NAME" ] && [ -e "$NO_PR_CI_FILE" ]; then
  FULL_RERUN_REASON="$PROJ_NAME is marked as running no PR CI, so no branch suite runs on the PR"
else
  KEPT_ARGS+=(--assume-branch-suite-green)
fi

set +e
"$SCRIPT_DIR/fm-assert-tests-kept.sh" ${KEPT_ARGS[@]+"${KEPT_ARGS[@]}"} "$ID" > "$KEPT_OUT"
kept_rc=$?
set -e
cat "$KEPT_OUT"
if [ -n "$FULL_RERUN_REASON" ]; then
  echo "note: the base's test assertions were re-run in full: $FULL_RERUN_REASON" >&2
else
  assumed_covered=$(grep -c '^assumed-covered: ' "$KEPT_OUT" || true)
  if [ "${assumed_covered:-0}" -gt 0 ]; then
    echo "note: $assumed_covered base assertion(s) were not re-run here because the branch's copy of their test file is byte-identical, so the branch's own suite already ran them against this code; the checks-green gate below is what holds that premise up" >&2
  fi
fi
if [ "$kept_rc" -ne 0 ] && [ "$kept_rc" -ne 1 ]; then
  echo "error: could not verify the base's tests are kept (fm-assert-tests-kept.sh exit $kept_rc, see above); refusing to merge unverified" >&2
  echo "error: repair the task's worktree/project so the check can run, then re-run fm-pr-merge.sh" >&2
  exit 1
fi

# Whether unexecuted findings block is read here, at merge time, so enabling a
# project takes effect for tasks that are already in flight (header contract).
exec_gate_enabled=0
if [ -n "$PROJ_NAME" ] && [ -e "$EXEC_GATE_FILE" ]; then
  exec_gate_enabled=1
fi

# The refuse/proceed decision is driven off the parsed-and-policy-applied counts
# rather than the detector's exit code, because an unexecuted finding can appear
# alongside a still-refusing exit while not itself counting for this project.
parsed=0
excused=0
unexcused=0
unexcused_unexecuted=0
unexcused_unstable=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    'missing: '*) finding_class=missing ; ident=${line#missing: } ;;
    'failing: '*) finding_class=failing ; ident=${line#failing: } ;;
    'unexecuted: '*) finding_class=unexecuted ; ident=${line#unexecuted: } ;;
    'unstable: '*) finding_class=unstable ; ident=${line#unstable: } ;;
    *) continue ;;
  esac
  parsed=$((parsed + 1))
  if [ "$finding_class" = unexecuted ] && [ "$exec_gate_enabled" -eq 0 ]; then
    echo "note: unexecuted (not gated for ${PROJ_NAME:-unknown project}): $ident" >&2
    continue
  fi
  if supersession_approved "$ident" "$finding_class"; then
    excused=$((excused + 1))
    echo "note: captain-approved supersession covers: $ident ($finding_class)" >&2
  else
    unexcused=$((unexcused + 1))
    if [ "$finding_class" = unexecuted ]; then
      unexcused_unexecuted=$((unexcused_unexecuted + 1))
    fi
    if [ "$finding_class" = unstable ]; then
      unexcused_unstable=$((unexcused_unstable + 1))
    fi
    echo "error: no captain-approved supersession entry covers: $ident ($finding_class)" >&2
  fi
done < "$KEPT_OUT"

if [ "$unexcused" -gt 0 ]; then
  echo "error: base test assertion(s) are missing, failing, unexecuted, or unstably named on the PR branch (named above); refusing to merge" >&2
  echo "error: if this is rebase damage, have the coder redo the conflict resolution so the base's assertions pass again, then re-run fm-pr-merge.sh" >&2
  if [ "$unexcused_unexecuted" -gt 0 ]; then
    echo "error: an unexecuted finding means the base's assertion could not be run at all against the branch, so it is unverified rather than proven broken; fix whatever stops it executing, or escalate for a captain-approved 'kind: unexecuted' entry" >&2
  fi
  if [ "$unexcused_unstable" -gt 0 ]; then
    echo "error: an unstable finding is a defect in the BASE's test, not in this branch: that test names its own assertion with a runtime value, so two runs of the identical file report two different names and nothing can be compared. Fix the test to use a constant assertion name (put the runtime value in its fail message), land that, then re-run fm-pr-merge.sh" >&2
  fi
  echo "error: if the branch deliberately supersedes the base's behavior, that is the captain's decision - escalate needs-decision naming each assertion; only a captain-approved entry in $SUPERSESSIONS_FILE (entry format in this script's header) lets the merge proceed" >&2
  exit 1
fi
if [ "$kept_rc" -eq 1 ] && [ "$parsed" -eq 0 ]; then
  echo "error: fm-assert-tests-kept.sh reported findings (exit 1) but none of its output parsed as a missing:/failing:/unexecuted:/unstable: line (see above); refusing to merge unverified" >&2
  exit 1
fi
if [ "$excused" -gt 0 ]; then
  echo "note: all $excused counted base assertion finding(s) are covered by captain-approved supersession entries in $SUPERSESSIONS_FILE; proceeding" >&2
fi

# --- checks-green gate (classification table and zero-checks contract in this
# --- script's header) ---------------------------------------------------------
# Empty fields are mapped to "-" in jq because tab is IFS whitespace to `read`,
# so consecutive tabs would collapse and shift every later field over.
set +e
checks_raw=$(gh pr view "$URL" --json statusCheckRollup \
  -q '.statusCheckRollup // [] | .[] | [.__typename, .status, .conclusion, .state, (.name // .context // "unnamed")] | map(if . == null or . == "" then "-" else . end) | @tsv' \
  2> "$CHECKS_ERR")
checks_rc=$?
set -e
if [ "$checks_rc" -ne 0 ]; then
  cat "$CHECKS_ERR" >&2
  echo "error: could not read the PR's check status (gh exit $checks_rc, see above); refusing to merge unverified" >&2
  echo "error: restore GitHub access so the checks can be read, then re-run fm-pr-merge.sh" >&2
  exit 1
fi

checks_total=0
checks_failing=0
checks_pending=0
checks_unknown=0
checks_exempted=0
# Deferred rather than decided inside the loop: the exemption's authority is
# resolved once, after the pass, and only if that named check turned out to be
# failing at all. Its count is kept because a re-run can leave the same name in
# the rollup more than once.
attestation_failing=0
while IFS=$'\t' read -r ck_type ck_status ck_conclusion ck_state ck_name; do
  [ -n "$ck_type$ck_status$ck_conclusion$ck_state$ck_name" ] || continue
  checks_total=$((checks_total + 1))
  verdict=unknown
  case "$ck_type" in
    CheckRun)
      case "$ck_status" in
        COMPLETED)
          case "$ck_conclusion" in
            SUCCESS|NEUTRAL|SKIPPED) verdict=passing ;;
            FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STALE|STARTUP_FAILURE) verdict=failing ;;
          esac
          ;;
        QUEUED|IN_PROGRESS|PENDING|WAITING|REQUESTED) verdict=pending ;;
      esac
      ;;
    StatusContext)
      case "$ck_state" in
        SUCCESS) verdict=passing ;;
        FAILURE|ERROR) verdict=failing ;;
        PENDING|EXPECTED) verdict=pending ;;
      esac
      ;;
  esac
  case "$verdict" in
    failing)
      # Exact equality, so a renamed job falls straight through to the ordinary
      # refusal below (header: a rename costs a merge, it never grants one).
      if [ "$ck_name" = "$ATTESTATION_CHECK_NAME" ]; then
        attestation_failing=$((attestation_failing + 1))
        continue
      fi
      checks_failing=$((checks_failing + 1))
      echo "error: PR check is failing: $ck_name" >&2
      ;;
    pending)
      checks_pending=$((checks_pending + 1))
      echo "note: PR check has not finished: $ck_name" >&2
      ;;
    unknown)
      checks_unknown=$((checks_unknown + 1))
      echo "error: PR check state could not be classified: $ck_name (type=$ck_type status=$ck_status conclusion=$ck_conclusion state=$ck_state)" >&2
      ;;
  esac
done <<EOF_CHECKS
$checks_raw
EOF_CHECKS

if [ "$attestation_failing" -gt 0 ]; then
  resolve_attestation_exemption
  if [ -n "$ATTESTATION_AUTHORITY" ]; then
    checks_exempted=$attestation_failing
    attestation_banner "before the remaining gates"
  else
    checks_failing=$((checks_failing + attestation_failing))
    echo "error: PR check is failing: $ATTESTATION_CHECK_NAME" >&2
    echo "error: that check can only be excused by a captain-authorized testing skip carrying this home's own signature, or by the project being registered as direct-PR; neither applies here (contract in this script's header)" >&2
  fi
fi

if [ "$checks_failing" -gt 0 ]; then
  echo "error: $checks_failing failing PR check(s) (named above); refusing to merge a red PR" >&2
  echo "error: fix the failure(s) on the PR branch until every check is green, then re-run fm-pr-merge.sh" >&2
  exit 1
fi
if [ "$checks_unknown" -gt 0 ]; then
  echo "error: $checks_unknown PR check(s) could not be classified (named above); refusing to merge unverified" >&2
  exit 1
fi
if [ "$checks_pending" -gt 0 ]; then
  echo "error: $checks_pending PR check(s) have not finished (named above); this PR is not red, it is unfinished - wait for the checks to complete, then re-run fm-pr-merge.sh" >&2
  exit 1
fi
# An exempted check is an authorized RED, not evidence that anything ran, so it
# is subtracted before asking whether this PR reported any checks at all. A PR
# whose only entry was excused is the same false-green shape as an empty rollup
# and takes the same refusal (header contract).
checks_evidence=$((checks_total - checks_exempted))
if [ "$checks_evidence" -eq 0 ]; then
  if [ "$checks_total" -eq 0 ]; then
    zero_reason="the PR reports no checks at all"
  else
    zero_reason="the PR's only check(s) were the exempted attestation check, so nothing on this PR actually verified the branch"
  fi
  if [ -n "$PROJ_NAME" ] && [ -e "$NO_PR_CI_FILE" ]; then
    echo "note: $zero_reason; captain-approved marker $NO_PR_CI_FILE confirms $PROJ_NAME intentionally runs no PR CI; proceeding" >&2
  else
    echo "error: $zero_reason; refusing to treat absent CI as green" >&2
    echo "error: either CI has not reported yet (wait, then re-run fm-pr-merge.sh) or this project runs no PR CI - only a captain-created marker at $NO_PR_CI_FILE (contract in this script's header) lets a zero-check PR merge" >&2
    exit 1
  fi
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

# Repeated on the line immediately before the merge so the disclosure cannot be
# lost above a long gate log.
waiver_banner "MERGING NOW"
attestation_banner "MERGING NOW"

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
