#!/usr/bin/env bash
# Behavior tests for bin/fm-open-url.sh, the single owner of "open this url in
# the captain's browser".
#
# The ladder is the whole subject, and it cannot be asserted by running it: a
# passing test must not put a browser window on somebody's desktop, and the
# machine running the suite has whatever openers it happens to have. Both are
# solved the same way - a fakebin holding exactly the openers a case declares,
# and the script's own FM_OPEN_URL_DRY_RUN seam, which prints the rung it would
# take and runs nothing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OPEN="$ROOT/bin/fm-open-url.sh"
TMP_ROOT=$(fm_test_tmproot fm-open-url)
mkdir -p "$TMP_ROOT"

URL="https://github.com/kirangathani/firstmate/pull/126"

# A fakebin holding ONLY the named openers, and a PATH that is only that dir
# plus the coreutils the script itself needs. Without the second half the real
# machine's own wslview or xdg-open shadows the case and every one of them
# reports the same rung.
only() {  # <opener>...
  local dir="$TMP_ROOT/bin.$$.$RANDOM"
  mkdir -p "$dir"
  local t
  for t in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$dir/$t"
    chmod 755 "$dir/$t"
  done
  # The script's own dependencies, linked in rather than inherited: PATH is the
  # only thing a case controls, so `bash` (its `env bash` shebang resolves
  # through PATH), `sh`, the `grep` its WSL reading uses and the `timeout` that
  # bounds a rung all have to be here or the case measures a missing
  # interpreter instead of the ladder.
  for t in bash sh grep timeout; do
    if command -v "$t" >/dev/null 2>&1; then ln -sf "$(command -v "$t")" "$dir/$t"; fi
  done
  printf '%s\n' "$dir"
}

rung() {  # <fakebin> [env=value]... -> the cmd= line
  local dir=$1; shift
  env -u BROWSER -i PATH="$dir" HOME="$TMP_ROOT" FM_OPEN_URL_DRY_RUN=1 "$@" \
    "$OPEN" "$URL" 2>/dev/null
}

# --- the ladder, one rung at a time -----------------------------------------

D=$(only wslview xdg-open)
assert_contains "$(rung "$D" FM_OPEN_URL_FORCE_WSL=1)" "cmd=wslview $URL" \
  "wslview was not preferred over xdg-open"
pass "wslview is taken before xdg-open, which is what reaches the Windows browser from WSL"

D=$(only xdg-open open)
assert_contains "$(rung "$D" FM_OPEN_URL_FORCE_WSL=0)" "cmd=xdg-open $URL" \
  "xdg-open was not taken on an ordinary Linux desktop"
pass "xdg-open is taken on a desktop with no wslview"

D=$(only open)
assert_contains "$(rung "$D" FM_OPEN_URL_FORCE_WSL=0)" "cmd=open $URL" \
  "open was not taken as the macOS rung"
pass "open is the macOS rung"

# $BROWSER is the captain's own stated choice and outranks every guess.
D=$(only wslview xdg-open mybrowser)
got=$(env -i PATH="$D" HOME="$TMP_ROOT" BROWSER=mybrowser FM_OPEN_URL_DRY_RUN=1 \
  FM_OPEN_URL_FORCE_WSL=1 "$OPEN" "$URL" 2>/dev/null)
assert_contains "$got" "cmd=mybrowser $URL" "BROWSER did not outrank wslview"
pass "an explicitly set BROWSER outranks every opener the ladder would guess"

# A BROWSER naming something that is not on PATH is not a dead end: it falls
# through rather than refusing, because a stale export in a shell profile must
# not cost the captain the working route.
D=$(only wslview)
got=$(env -i PATH="$D" HOME="$TMP_ROOT" BROWSER=not-installed FM_OPEN_URL_DRY_RUN=1 \
  FM_OPEN_URL_FORCE_WSL=1 "$OPEN" "$URL" 2>/dev/null)
assert_contains "$got" "cmd=wslview $URL" "an unresolvable BROWSER blocked the ladder"
pass "a BROWSER that is not installed falls through to the ladder instead of refusing"

# --- the WSL rungs, which are the reason this script exists -----------------
#
# With no Linux opener at all - which is the stock WSL2 distro - the route to
# the browser is a Windows one, and PowerShell's Start-Process is it.
D=$(only powershell.exe explorer.exe)
got=$(rung "$D" FM_OPEN_URL_FORCE_WSL=1)
assert_contains "$got" "powershell.exe" "the PowerShell rung was not reached under WSL"
assert_contains "$got" "Start-Process '$URL'" "Start-Process did not carry the url"
pass "with no Linux opener, WSL reaches the Windows browser through PowerShell"

D=$(only explorer.exe)
assert_contains "$(rung "$D" FM_OPEN_URL_FORCE_WSL=1)" "cmd=explorer.exe $URL" \
  "explorer.exe was not the last WSL rung"
pass "explorer.exe is the last rung, after PowerShell"

# The Windows rungs are WSL-only. On an ordinary Linux box a stray
# powershell.exe on PATH is not a browser route and must not be taken.
D=$(only powershell.exe explorer.exe)
env -u BROWSER -i PATH="$D" HOME="$TMP_ROOT" FM_OPEN_URL_FORCE_WSL=0 "$OPEN" "$URL" >/dev/null 2>&1
expect_code 1 $? "a non-WSL machine took a Windows opener"
pass "the Windows rungs are reached only under WSL"

# --- nothing works, and it says so ------------------------------------------
D=$(only)
err=$(env -u BROWSER -i PATH="$D" HOME="$TMP_ROOT" FM_OPEN_URL_FORCE_WSL=0 "$OPEN" "$URL" 2>&1 >/dev/null)
expect_code 1 $? "a machine with no opener at all reported success"
assert_contains "$err" "nothing on this machine could open a url" "the failure did not say what it was"
assert_contains "$err" "xdg-open" "the failure did not name what it tried"
pass "a machine with no opener refuses and names every rung it tried"

# --- the url is a trust boundary --------------------------------------------
#
# The value arrives from a PR link recorded in fleet state and two rungs splice
# it into another interpreter's command line, so it is validated before either
# can see it. These are refusals, not escapes: nothing is run at all.
D=$(only wslview powershell.exe)
for bad in \
  "https://github.com/x/y/pull/1'; Start-Process calc; '" \
  'https://github.com/x/$(id)' \
  'file:///etc/passwd' \
  'javascript:alert(1)' \
  'ssh://github.com/x'
do
  out=$(env -u BROWSER -i PATH="$D" HOME="$TMP_ROOT" FM_OPEN_URL_DRY_RUN=1 \
    FM_OPEN_URL_FORCE_WSL=1 "$OPEN" "$bad" 2>&1)
  st=$?
  [ "$st" -eq 1 ] || fail "a url this opener must refuse was accepted"
  case $out in
    *"refusing to open"*) ;;
    *) fail "a refused url did not say why" ;;
  esac
  case $out in
    cmd=*) fail "a refused url still produced a command to run" ;;
  esac
done
pass "a url that is not plain http(s), or carries a character the Windows rung would interpret, is refused with its reason and nothing is run"

# An ordinary PR link with every character GitHub really puts in one survives
# that gate, which is the other half of the boundary being useful.
D=$(only wslview)
assert_contains "$(rung "$D" FM_OPEN_URL_FORCE_WSL=1)" "cmd=wslview $URL" \
  "an ordinary PR link was refused"
pass "an ordinary GitHub pull request link passes the validation unchanged"

# --- usage ------------------------------------------------------------------
"$OPEN" >/dev/null 2>&1
expect_code 2 $? "a call with no url was not a usage error"
"$OPEN" one two >/dev/null 2>&1
expect_code 2 $? "a call with two urls was not a usage error"
"$OPEN" --help >/dev/null 2>&1
expect_code 0 $? "--help did not exit 0"
pass "it takes exactly one url and says so when it does not get one"
