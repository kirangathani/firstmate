#!/usr/bin/env bash
# fm-open-url.sh - open ONE url in the captain's own browser, and say what it did.
#
# The single owner of that question for this repository. It exists because the
# answer is not one command: firstmate runs in WSL2 while the browser lives on
# the Windows host, so the Linux openers are frequently absent or useless there
# and the working route is a Windows one. Spreading that ladder across callers
# would leave each of them with a different half of it.
#
# Usage:
#   fm-open-url.sh <https-url>
#
# The ladder, in order, first one that is present wins:
#   $BROWSER         the captain's own stated choice, and it outranks every
#                    guess below it
#   wslview          wslu's opener: hands the url to the Windows default
#                    browser. The right answer on this machine when installed
#   xdg-open         an ordinary Linux desktop
#   open             macOS
#   powershell.exe   WSL only. Start-Process is the documented Windows verb for
#                    "open this with whatever handles it"
#   explorer.exe     WSL only, last. It works, but its exit code is not a
#                    verdict (it returns 1 on a url it opened perfectly well),
#                    so this reports what it handed over rather than claiming a
#                    success it cannot check
#
# THE URL IS VALIDATED, and that is not ceremony. The value reaches here from a
# PR link recorded in fleet state, and two rungs of the ladder interpolate it
# into another interpreter's command line. Only http(s) and a conservative
# character set are accepted; anything else is refused with the reason and
# nothing is run.
#
# Environment knobs:
#   FM_OPEN_URL_DRY_RUN   print `cmd=<argv>` for the rung it WOULD take, run
#                         nothing, exit 0. This is the seam the tests use, so a
#                         test can assert the ladder without a browser opening
#                         on somebody's desktop.
#   FM_OPEN_URL_FORCE_WSL set to 1 or 0 to override the WSL reading, so the
#                         Windows rungs can be tested from an ordinary Linux
#                         box and the Linux ones from WSL.
#
# The outcome line goes to STDERR, like bin/fm-flow.sh --open's, because the
# viewer flashes exactly what this command says it did and never infers one
# from an exit code.
#
# Exit codes: 0 opened (or handed over), 1 nothing could open it or the url was
# refused, 2 usage error.
set -u

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -eq 1 ] || { echo "error: fm-open-url.sh takes exactly one url" >&2; exit 2; }

URL=$1
case "$URL" in
  http://*|https://*) ;;
  *) echo "error: refusing to open $URL: not an http(s) url" >&2; exit 1 ;;
esac
# Deliberately narrower than RFC 3986. A quote, a backtick, a dollar, a space or
# a backslash in a value that is about to be spliced into a PowerShell command
# line is a shell-injection seam, and no GitHub pull request link contains one.
case "$URL" in
  *[!A-Za-z0-9._~:/?#@%+=\&-]*)
    echo "error: refusing to open $URL: it carries a character this opener will not pass on" >&2
    exit 1
    ;;
esac

is_wsl() {
  case "${FM_OPEN_URL_FORCE_WSL:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qi microsoft /proc/version 2>/dev/null
}

# One rung: report it under dry run, otherwise run it bounded and say so.
# `timeout` is absent on stock macOS, so its absence degrades to an unbounded
# call rather than to a refusal - the same trade bin/fm-flow-snapshot.sh makes.
attempt() {  # <command...>
  if [ -n "${FM_OPEN_URL_DRY_RUN:-}" ]; then
    printf 'cmd=%s\n' "$*"
    exit 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 "$@" >/dev/null 2>&1
  else
    "$@" >/dev/null 2>&1
  fi
}

if [ -n "${BROWSER:-}" ] && command -v "$BROWSER" >/dev/null 2>&1; then
  if attempt "$BROWSER" "$URL"; then
    echo "opened in $BROWSER" >&2
    exit 0
  fi
fi

for opener in wslview xdg-open open; do
  command -v "$opener" >/dev/null 2>&1 || continue
  if attempt "$opener" "$URL"; then
    echo "opened in your browser via $opener" >&2
    exit 0
  fi
done

if is_wsl; then
  if command -v powershell.exe >/dev/null 2>&1; then
    if attempt powershell.exe -NoProfile -Command "Start-Process '$URL'"; then
      echo "opened in your Windows browser" >&2
      exit 0
    fi
  fi
  # Last, and reported as a handover rather than a success: explorer.exe opens
  # the url and then exits 1 anyway, so its exit code says nothing either way
  # and claiming an open on it would be exactly the lie --open was fixed for.
  if command -v explorer.exe >/dev/null 2>&1; then
    attempt explorer.exe "$URL" || true
    echo "handed to explorer.exe, which does not report whether it opened" >&2
    exit 0
  fi
fi

echo "error: nothing on this machine could open a url (tried \$BROWSER, wslview, xdg-open, open$(is_wsl && printf ', powershell.exe, explorer.exe'))" >&2
exit 1
