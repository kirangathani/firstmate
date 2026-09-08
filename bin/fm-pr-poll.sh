#!/usr/bin/env bash
# Static watcher program for a validated PR poll sidecar.
# It emits one merged line for MERGED, and stays silent otherwise - except under
# the captain's standing merge rule, below.
#
# THE STANDING MERGE RULE (config/merge-green; docs/configuration.md owns the
# file). When $FM_HOME/config/merge-green is present, an OPEN PR that has gone
# GREEN also wakes firstmate, so work the captain already asked for lands
# without a separate word. Absent - the default - nothing changes and only a
# merged PR wakes anything.
# THIS POLL NEVER MERGES. It emits a line; firstmate then runs
# bin/fm-merge-green.sh, which runs every gate. That separation is the point:
# the trigger is cheap and revocable, the decision stays in the one place that
# owns it.
# GREEN IS NOT DECIDED HERE EITHER. It is read from bin/fm-pr-green.sh, the same
# owner a ship worker reports its own green from, so this poll cannot wake
# firstmate on a definition of green the merge gate would then refuse. That
# sibling is resolved next to THIS file, so the rule is live only on the watcher
# path, where $0 is bin/fm-pr-poll.sh itself. Run as a state/<id>.check.sh copy
# there is no sibling to reach and the poll behaves exactly as it always has.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  id=$2
  url=$3
  owner=$4
  repo=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac
  id=$(basename "${0%.check.sh}")

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r owner <&3 || exit 0
  IFS= read -r repo <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$id" in
  ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
case "$owner" in
  *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
esac
[ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
case "$repo" in
  .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac
[ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0

state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
if [ "$state" = MERGED ]; then
  printf '%s\n' merged
  exit 0
fi
[ "$state" = OPEN ] || exit 0

# The standing merge rule, gated on the captain's own file (this file's header).
home=${FM_HOME:-}
[ -n "$home" ] && [ -d "$home" ] || exit 0
[ -e "$home/config/merge-green" ] || exit 0
green=$(dirname -- "$0")/fm-pr-green.sh
[ -f "$green" ] && [ ! -L "$green" ] && [ -x "$green" ] || exit 0
if FM_HOME="$home" "$green" "$id" "$url" >/dev/null 2>&1; then
  printf 'green: land it with the merge switch (%s)\n' "$id"
fi
exit 0
