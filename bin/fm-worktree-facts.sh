#!/usr/bin/env bash
# fm-worktree-facts.sh - the per-task git facts a resume, pause, or handoff
# document is expected to state, measured rather than remembered.
#
# WHY THIS EXISTS. A resume record whose per-task table omits the branch, the
# head, the unpushed count or the dirty count is worse than no record at all,
# because the next session trusts it. Those four facts are not in any fleet
# snapshot: bin/fm-fleet-snapshot.sh records a task's worktree PATH, and stops
# there. So firstmate used to open each worktree and run git by hand, four
# reads per task, in the foreground, every time it wrote one of those
# documents. This prints the same table in one call.
#
# It is the collector half of bin/fm-write.sh, which pipes this output into a
# short-lived writer, and it is equally usable on its own when the captain just
# wants to know where the fleet's uncommitted work is.
#
# LOCAL-ONLY and READ-ONLY. Every command it runs is a git read against a
# worktree that already exists. It makes no network call, fetches nothing,
# writes nothing into any project, and never touches an index or a ref.
# `unpushed` is therefore measured against the LOCAL tracking ref, which can
# overstate the count when the remote has moved and nothing has fetched since;
# the output labels it so a reader does not mistake it for a live comparison.
#
# A task whose worktree is gone is reported with `worktree=absent` rather than
# skipped: a missing worktree is itself a fact the reader needs, and a silently
# short table reads as "nothing to report here".
#
# Usage:
#   fm-worktree-facts.sh [--tsv] [<task-id>...]
#     no ids       every task with a state/<id>.meta in this home
#     <task-id>    only those tasks, in the order given
#     --tsv        tab-separated rows with a header, for a machine
#     (default)    an aligned markdown table, for a document
#
# Exit status is 0 whenever the table was produced, even when every row is
# absent: "no task has a worktree" is a successful measurement, not an error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

TSV=0
IDS=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --tsv) TSV=1 ;;
    -*) echo "error: unknown argument '$a'" >&2; exit 2 ;;
    *) IDS+=("$a") ;;
  esac
done

if [ "${#IDS[@]}" -eq 0 ]; then
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    b=$(basename "$m" .meta)
    IDS+=("$b")
  done
fi

meta_value() {
  # First match wins, so a hand-appended duplicate cannot shadow what fm-spawn
  # wrote. Read with grep rather than sourcing the file: a meta line is data a
  # worker's own id can reach, and sourcing it would execute it.
  grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true
}

# One row of facts for one worktree. Every value is either measured or the
# literal string that says it could not be, never an empty cell a reader has to
# guess at.
row_for() {
  local id=$1 meta wt branch head unpushed dirty upstream
  meta="$STATE/$id.meta"
  wt=$(meta_value "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf '%s\t%s\tabsent\t-\t-\t-\t-\n' "$id" "${wt:--}"
    return 0
  fi
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\t%s\tnot-a-repo\t-\t-\t-\t-\n' "$id" "$wt"
    return 0
  fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch='?'
  [ "$branch" = HEAD ] && branch='(detached)'
  head=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null) || head='?'
  # A configured tracking ref first, then `origin/<branch>` as a fallback,
  # because `git push origin HEAD` pushes a branch without ever setting one:
  # reporting such a branch as having no comparison at all would read as
  # "never pushed", which is the opposite of the truth.
  upstream=$(git -C "$wt" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || upstream=
  if [ -z "$upstream" ] && [ "$branch" != '(detached)' ] \
    && git -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    upstream="origin/$branch"
  fi
  if [ -n "$upstream" ]; then
    unpushed=$(git -C "$wt" rev-list --count "$upstream..HEAD" 2>/dev/null) || unpushed='?'
  else
    unpushed=never-pushed
  fi
  # Counted with wc, NEVER with `grep -c .`: grep exits 1 on no match, so a
  # clean tree would take the failure branch and be reported as unmeasurable.
  # A clean tree is the commonest case and the one a reader most needs stated.
  if dirty=$(git -C "$wt" status --porcelain 2>/dev/null); then
    dirty=$(printf '%s' "$dirty" | grep -c . || true)
  else
    dirty='?'
  fi
  printf '%s\t%s\tpresent\t%s\t%s\t%s\t%s\n' "$id" "$wt" "$branch" "$head" "$unpushed" "$dirty"
}

ROWS=$(for id in "${IDS[@]}"; do row_for "$id"; done)

if [ "$TSV" -eq 1 ]; then
  printf 'task\tworktree\tworktree_state\tbranch\thead\tunpushed\tdirty_paths\n'
  printf '%s\n' "$ROWS"
  exit 0
fi

echo "Per-task worktree facts, measured $(date '+%Y-%m-%d %H:%M:%S %Z') by fm-worktree-facts.sh."
echo "\`unpushed\` counts commits ahead of the LOCAL tracking ref; nothing was fetched, so it can overstate."
echo
echo '| task | worktree | branch | head | unpushed | dirty paths |'
echo '|---|---|---|---|---|---|'
printf '%s\n' "$ROWS" | while IFS=$'\t' read -r id wt wtstate branch head unpushed dirty; do
  [ -n "$id" ] || continue
  if [ "$wtstate" != present ]; then
    # shellcheck disable=SC2016  # markdown code fences, not shell expansions
    printf '| %s | `%s` (%s) | - | - | - | - |\n' "$id" "$wt" "$wtstate"
  else
    # shellcheck disable=SC2016  # markdown code fences, not shell expansions
    printf '| %s | `%s` | `%s` | `%s` | %s | %s |\n' "$id" "$wt" "$branch" "$head" "$unpushed" "$dirty"
  fi
done
