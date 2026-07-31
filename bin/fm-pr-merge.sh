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
# This gate is firstmate-side, so it protects every repo including ones with no
# PR CI.
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
#               missing, failing, unexecuted, or any. An ABSENT kind means any,
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
#     outside the four above. A "- " bullet holding pipe-delimited `key: value`
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
# Decision rule, which this header owns: every missing:/failing:/unexecuted:
# line is parsed, the exec-gate policy is applied to the unexecuted ones, and
# supersession excusal is applied to whatever is left counted. The merge is then
# refused iff any COUNTED finding is unexcused, plus two independent refusals: a
# findings exit whose output held no parseable finding line at all, and an exit
# other than 0 or 1 (the check could not run). The decision must never be taken
# from a single class's path or from the detector's exit code alone: doing so is
# how an unexecuted finding riding alongside an EXCUSED missing/failing one
# could be silently ignored, which is the exact inverse of what this gate is for.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

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

# supersession_approved <file>::<name> <finding-class>: 0 iff the project's
# supersession record holds a fully-formed captain-approved entry that covers
# that identifier for that finding class (grammar in this script's header).
# An absent file means no approvals; a malformed entry is warned about and never
# honored.
supersession_approved() {
  local ident=$1 finding_class=$2
  local line head field key val bad req kind_seen seen_keys
  local entry_id entry_ids entry_proj entry_date entry_reason entry_kind
  [ -n "$PROJ_NAME" ] || return 1
  [ -f "$SUPERSESSIONS_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- id: "*|"- ids: "*) ;;
      "- "*" | "*": "*)
        echo "warning: ignoring supersession entry that carries neither 'id:' nor 'ids:' as its first field: $line" >&2
        continue
        ;;
      *) continue ;;
    esac
    bad=
    for req in project date reason; do
      case "$line" in
        *" | $req: "*) ;;
        *) bad="a missing required field ($req)" ; break ;;
      esac
    done
    if [ -n "$bad" ]; then
      echo "warning: ignoring supersession entry missing a required field (id or ids, project, date, reason): $line" >&2
      continue
    fi
    # reason is taken as the whole remainder so it may itself contain " | ";
    # every other field is parsed out of the head, in any order.
    entry_reason=${line#* | reason: }
    head=${line%% | reason: *}
    head=${head#- }
    # Fail closed on a field written AFTER reason: it would be swallowed into the
    # reason text, and a swallowed `kind:` silently widens the entry to any.
    for req in id ids project date kind; do
      case "$entry_reason" in
        *" | $req:"*) bad="a field after reason (reason must be the last field)" ; break ;;
      esac
    done
    if [ -n "$bad" ]; then
      echo "warning: ignoring supersession entry with $bad: $line" >&2
      continue
    fi
    entry_id='' entry_ids='' entry_proj='' entry_date='' entry_kind='' kind_seen=0
    seen_keys=' '
    while :; do
      case "$head" in
        *" | "*) field=${head%% | *} ; head=${head#* | } ;;
        *) field=$head ; head= ;;
      esac
      case "$field" in
        *": "*) key=${field%%:*} ; val=${field#*: } ;;
        *) bad="an unparseable field '$field'" ; break ;;
      esac
      case "$seen_keys" in
        *" $key "*) bad="a duplicated field '$key' (a repeat would silently take the last value)" ; break ;;
      esac
      case "$key" in
        id) entry_id=$val ;;
        ids) entry_ids=$val ;;
        project) entry_proj=$val ;;
        date) entry_date=$val ;;
        kind) entry_kind=$val ; kind_seen=1 ;;
        *) bad="an unrecognized field '$key'" ; break ;;
      esac
      seen_keys="$seen_keys$key "
      [ -n "$head" ] || break
    done
    if [ -n "$bad" ]; then
      echo "warning: ignoring supersession entry with $bad: $line" >&2
      continue
    fi
    if [ -n "$entry_id" ] && [ -n "$entry_ids" ]; then
      echo "warning: ignoring supersession entry carrying both 'id:' and 'ids:' (use exactly one): $line" >&2
      continue
    fi
    if [ -z "$entry_id" ] && [ -z "$entry_ids" ]; then
      echo "warning: ignoring supersession entry with an empty field: $line" >&2
      continue
    fi
    if [ -z "$entry_proj" ] || [ -z "$entry_reason" ]; then
      echo "warning: ignoring supersession entry with an empty field: $line" >&2
      continue
    fi
    if [ "$kind_seen" -eq 1 ]; then
      case "$entry_kind" in
        missing|failing|unexecuted|any) ;;
        "")
          echo "warning: ignoring supersession entry with an empty field: $line" >&2
          continue
          ;;
        *)
          echo "warning: ignoring supersession entry whose kind is not missing, failing, unexecuted, or any: $line" >&2
          continue
          ;;
      esac
    else
      entry_kind=any
    fi
    case "$entry_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *)
        echo "warning: ignoring supersession entry whose date is not YYYY-MM-DD: $line" >&2
        continue
        ;;
    esac
    if [ "$entry_proj" != "$PROJ_NAME" ]; then
      echo "warning: ignoring supersession entry for project '$entry_proj' found in $PROJ_NAME's record: $line" >&2
      continue
    fi
    if [ "$entry_kind" != any ] && [ "$entry_kind" != "$finding_class" ]; then
      continue
    fi
    if [ -n "$entry_id" ]; then
      if [ "$entry_id" = "$ident" ]; then
        return 0
      fi
    else
      # shellcheck disable=SC2053  # unquoted glob match is the documented `ids:` batch mechanism
      if [[ "$ident" == $entry_ids ]]; then
        return 0
      fi
    fi
  done < "$SUPERSESSIONS_FILE"
  return 1
}

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

KEPT_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-kept.XXXXXX")
trap 'rm -f "$KEPT_OUT"' EXIT
set +e
"$SCRIPT_DIR/fm-assert-tests-kept.sh" "$ID" > "$KEPT_OUT"
kept_rc=$?
set -e
cat "$KEPT_OUT"
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
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    'missing: '*) finding_class=missing ; ident=${line#missing: } ;;
    'failing: '*) finding_class=failing ; ident=${line#failing: } ;;
    'unexecuted: '*) finding_class=unexecuted ; ident=${line#unexecuted: } ;;
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
    echo "error: no captain-approved supersession entry covers: $ident ($finding_class)" >&2
  fi
done < "$KEPT_OUT"

if [ "$unexcused" -gt 0 ]; then
  echo "error: base test assertion(s) are missing, failing, or unexecuted on the PR branch (named above); refusing to merge" >&2
  echo "error: if this is rebase damage, have the coder redo the conflict resolution so the base's assertions pass again, then re-run fm-pr-merge.sh" >&2
  if [ "$unexcused_unexecuted" -gt 0 ]; then
    echo "error: an unexecuted finding means the base's assertion could not be run at all against the branch, so it is unverified rather than proven broken; fix whatever stops it executing, or escalate for a captain-approved 'kind: unexecuted' entry" >&2
  fi
  echo "error: if the branch deliberately supersedes the base's behavior, that is the captain's decision - escalate needs-decision naming each assertion; only a captain-approved entry in $SUPERSESSIONS_FILE (entry format in this script's header) lets the merge proceed" >&2
  exit 1
fi
if [ "$kept_rc" -eq 1 ] && [ "$parsed" -eq 0 ]; then
  echo "error: fm-assert-tests-kept.sh reported findings (exit 1) but none of its output parsed as a missing:/failing:/unexecuted: line (see above); refusing to merge unverified" >&2
  exit 1
fi
if [ "$excused" -gt 0 ]; then
  echo "note: all $excused counted base assertion finding(s) are covered by captain-approved supersession entries in $SUPERSESSIONS_FILE; proceeding" >&2
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
