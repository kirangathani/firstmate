#!/usr/bin/env bash
# fm-release-watch.sh - wake firstmate when a project's post-merge release
# workflow FAILS on its default branch.
#
# WHY. On 2026-10-01 ELN's production release workflow
# (.github/workflows/deploy-production.yml, which runs on every push to main)
# failed ten times in a row from 00:22 to 13:20 and nothing noticed, so
# production silently stayed on old code while PRs kept merging. Merges land
# both through bin/fm-pr-merge.sh and by the captain directly on GitHub, so this
# keys on the default branch's own workflow runs, never on firstmate's merge
# events: a merge made anywhere is covered.
#
# OPT-IN, per project: data/release-workflows/<project> in FM_HOME, one
# workflow file name per line (the name under .github/workflows/, e.g.
# `deploy-production.yml`); blank lines and `#` comments are ignored. A project
# with no such file is never queried. <project> is the clone's directory name
# under projects/, which is where the GitHub repo and default branch are read
# from (origin's address and origin/HEAD, falling back to GitHub for the branch).
#
# THE PREDICATE. For each listed workflow, the most recent COMPLETED run on the
# default branch, skipping `cancelled` and `skipped` runs (a superseded run says
# nothing about the code). If its conclusion is failure, timed_out, or
# startup_failure and its run id has not been reported before, one line is
# printed. An in-progress run is ignored until it completes, and a newer success
# simply stops older failures from being the latest, so ten failures in a row
# produce one wake per new failed run, never a backlog of the old ones.
#
# THE RECORD, state/.release-watch-seen: one reported run id per line, capped
# at the last 500. Each line is printed BEFORE its id is recorded, so a sweep cut
# short can at worst repeat a wake, never swallow one.
#
# Usage: fm-release-watch.sh --surface
#   Prints one line per newly failed release run, nothing otherwise, and exits 0
#   even when GitHub cannot be read (a sweep that cannot read stays silent and is
#   retried next cadence). bin/fm-watch.sh runs it every
#   FM_RELEASE_WATCH_INTERVAL seconds (default 300).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="$FM_HOME/data/release-workflows"
SEEN="$STATE/.release-watch-seen"
SEEN_CAP=500

[ "${1-}" = --surface ] || { echo "usage: fm-release-watch.sh --surface" >&2; exit 2; }
[ -d "$CONFIG_DIR" ] || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

surface_workflow() {  # <project> <slug> <branch> <workflow>
  local project=$1 slug=$2 branch=$3 wf=$4 run id sha title url detail
  run=$(fm_pr_bounded gh run list --repo "$slug" --workflow "$wf" --branch "$branch" --limit 20 \
    --json databaseId,status,conclusion,headSha,url,displayTitle 2>/dev/null \
    | jq -r 'map(select(.status == "completed" and .conclusion != "cancelled" and .conclusion != "skipped"))
             | first // empty
             | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure")
             | [.databaseId, .headSha[0:7], .displayTitle, .url, .conclusion] | @tsv' 2>/dev/null) || return 0
  [ -n "$run" ] || return 0
  IFS=$'\t' read -r id sha title url _ <<< "$run"
  [ -n "$id" ] || return 0
  grep -qx -- "$id" "$SEEN" 2>/dev/null && return 0
  detail=$(fm_pr_bounded gh run view "$id" --repo "$slug" --json jobs 2>/dev/null \
    | jq -r '[.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out")
              | "job \"" + .name + "\" failed"
                + ((first(.steps[]? | select(.conclusion == "failure" or .conclusion == "timed_out")) | " at step \"" + .name + "\"") // "")]
             | join(", ")' 2>/dev/null || true)
  [ -n "$detail" ] || detail="no failed job could be read"
  printf 'project %s: release workflow %s failed on %s at commit %s ("%s"): %s - %s\n' \
    "$project" "$wf" "$branch" "$sha" "$title" "$detail" "$url"
  { tail -n $((SEEN_CAP - 1)) "$SEEN" 2>/dev/null; printf '%s\n' "$id"; } > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
}

for cfg in "$CONFIG_DIR"/*; do
  [ -f "$cfg" ] || continue
  project=$(basename "$cfg")
  clone="$FM_HOME/projects/$project"
  fm_pr_remote_parse "$(git -C "$clone" remote get-url origin 2>/dev/null)" || continue
  slug="$FM_PR_REMOTE_OWNER/$FM_PR_REMOTE_REPO"
  branch=$(git -C "$clone" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  branch=${branch#origin/}
  [ -n "$branch" ] || branch=$(fm_pr_bounded gh api "repos/$slug" --jq .default_branch 2>/dev/null)
  [ -n "$branch" ] || continue
  while IFS= read -r wf || [ -n "$wf" ]; do
    wf=${wf%%#*}
    wf=$(printf '%s' "$wf" | tr -d '[:space:]')
    [ -n "$wf" ] || continue
    surface_workflow "$project" "$slug" "$branch" "$wf"
  done < "$cfg"
done
exit 0
