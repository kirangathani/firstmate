#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs ShellCheck over firstmate's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# The lint command, the file set, the config, AND the pinned ShellCheck version
# live here and ONLY here, so the gates cannot drift apart: both invoke this
# script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/fm-lint.sh`.
#   - Pre-push: .no-mistakes.yaml `commands.lint` runs `bin/fm-lint.sh`, so the
#               no-mistakes gate runs the SAME shellcheck as CI. Without a
#               configured commands.lint, that gate step never ran this
#               deterministic shellcheck, so info-level findings were not
#               surfaced locally before CI rejected them.
#
# Version parity: CI's ShellCheck used to float with the runner image, and
# ShellCheck retired SC2015 in 0.11.0, so an older CI ShellCheck rejected an
# SC2015 that a newer local one no longer emits. This script pins one exact
# version (REQUIRED_SHELLCHECK) and asserts the resolved `shellcheck` matches it,
# so CI and local run the identical rule set. This is not a CI relaxation: it
# adopts one upstream release consistently; the only difference from the old
# floating CI is dropping the upstream-retired, false-positive-prone SC2015.
# No severity downgrade and no blanket suppression of checks - every
# still-supported finding at default severity is enforced.
# The local == CI parity contract is asserted by tests/fm-lint.test.sh.
#
# WHY THIS IS NOT ONE BIG SHELLCHECK CALL ANY MORE
# ------------------------------------------------
# The canonical whole-set command took 3m45s-5m23s on a clean tree, which made
# the pre-push gate slow enough to be worth routing around - the worst possible
# property for a gate.
#
# Measured cause on this repo at ShellCheck 0.11.0: it is NOT file length and
# NOT process startup. Without -x, ShellCheck follows a `# shellcheck
# source=<path>` directive only when the target is ALSO an input file on the
# same command line. The whole-set command supplies all 152 files at once, so
# all 184 source edges resolve and every importer is analysed with its sourced
# libraries inlined. ShellCheck's analysis is superlinear in the size of the
# script it ends up analysing, so that inlining, not the file count, dominates.
# Splitting bin/*.sh into four arbitrary chunks - which silently drops most
# source edges - cut 216s to 53s, a 4x swing in pure analysis work with the file
# set unchanged.
#
# That measurement also names the invariant that makes this safe to shard. A
# file's findings depend on exactly two inputs: its own contents, and the
# contents of the files it transitively sources that are present in the input
# list. Nothing else on the command line can affect them. Therefore, for any
# input list CLOSED under the transitive source relation, every file in that
# list yields precisely the findings the whole-set run gives it.
#
# So this script:
#   1. builds the source graph from the `source=` directives and literal
#      source statements (bin/fm-lint-plan.awk),
#   2. skips files whose own contents AND whose entire transitive source closure
#      are byte-identical to a previously recorded clean result under this exact
#      ShellCheck version and flags,
#   3. packs the rest into closed shards and runs those shards in parallel.
# None of those steps can change a finding: steps 1 and 3 preserve closure, and
# step 2 only ever skips work whose every byte of input is unchanged.
#
# This is a speed change ONLY. The file set, the severity, the config and the
# version are untouched, and `--verify-parity` re-derives that claim on demand
# by running the canonical whole-set command against the fast path and diffing
# the findings.
#
# Usage:
#   fm-lint.sh                    lint the canonical file set (what both gates run)
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   fm-lint.sh --whole-set        the canonical single-process command, unsharded
#                                  and uncached; the reference implementation
#   fm-lint.sh --verify-parity    run --whole-set and the fast path, diff findings
#   fm-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#
# Environment:
#   FM_LINT_JOBS       shard count (default: nproc, capped at 8)
#   FM_LINT_CACHE_DIR  where clean results are recorded (default: .git/fm-lint-cache)
#   FM_LINT_NO_CACHE=1 read and write no cache entries
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or the gate)
# fails exactly when ShellCheck reports a finding; a version mismatch or a
# missing ShellCheck fails before linting with a distinct message.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`; the test suite reads it the same way.
REQUIRED_SHELLCHECK=0.11.0

# The behavior-affecting ShellCheck flags. The cache key embeds this exact
# string, so the sharded invocations below must take their flags from here and
# nowhere else: a flag added to an invocation but not to the key would serve
# stale clean results recorded under a different effective lint. The canonical
# --whole-set command spells the same flags literally because the test suite
# pins that command string; --verify-parity keeps the two in agreement.
LINT_FLAGS='--norc'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Expose the pinned version without needing ShellCheck installed, so CI can read
# it to install the exact same build before any lint runs.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

# Enforce the pin so local and CI resolve the identical rule set.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi
unset SHELLCHECK_OPTS
resolved=$(shellcheck --version | awk '/^version:/ {print $2; exit}')
# Log the resolved version to stderr so both CI and local runs record it.
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

# Developer convenience: explicit paths bypass planning entirely and run the
# same ShellCheck with the same config.
if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then
  exec shellcheck --norc "$@"
fi

MODE=default
case "${1:-}" in
  '') ;;
  --whole-set) MODE=whole-set ;;
  --verify-parity) MODE=verify-parity ;;
  *)
    printf 'fm-lint.sh: unknown option %s\n' "$1" >&2
    exit 2
    ;;
esac

if [ "$MODE" = whole-set ]; then
  # The canonical file set: the ONE authoritative definition of what gets
  # linted, in a single process, uncached and unsharded. This is the reference
  # implementation every other path must agree with, and --verify-parity keeps
  # it honest. Callers reference this script; they never re-spell these globs.
  exec shellcheck --norc bin/*.sh bin/backends/*.sh tests/*.sh
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

# The fast path plans over exactly the canonical set above, so the two modes
# cannot cover different files.
ls -1 bin/*.sh bin/backends/*.sh tests/*.sh >"$TMP/files"

if [ "$MODE" = verify-parity ]; then
  printf 'fm-lint.sh: running the canonical whole-set command (this is the slow one)...\n' >&2
  # shellcheck disable=SC2046,SC2086
  shellcheck $LINT_FLAGS --format=gcc $(cat "$TMP/files") 2>/dev/null | sort -u >"$TMP/ref" || true
  printf 'fm-lint.sh: running the sharded fast path...\n' >&2
  FM_LINT_NO_CACHE=1 FM_LINT_EMIT_FINDINGS="$TMP/fast" "$ROOT/bin/fm-lint.sh" >/dev/null 2>&1 || true
  [ -f "$TMP/fast" ] || : >"$TMP/fast"
  if diff -u "$TMP/ref" "$TMP/fast" >"$TMP/diff"; then
    printf 'fm-lint.sh: PARITY OK - %s finding(s), identical in both modes.\n' \
      "$(wc -l <"$TMP/ref" | tr -d ' ')" >&2
    exit 0
  fi
  printf 'fm-lint.sh: PARITY BROKEN - the fast path disagrees with the canonical command:\n' >&2
  cat "$TMP/diff" >&2
  exit 1
fi

# --- content hashing --------------------------------------------------------
# Used only to decide whether a file's inputs are byte-identical to a recorded
# clean result. With no hasher available the cache is skipped, never guessed at.
HASHER=
if command -v sha256sum >/dev/null 2>&1; then
  HASHER=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASHER='shasum -a 256'
fi

CACHE_DIR="${FM_LINT_CACHE_DIR:-}"
if [ -z "$CACHE_DIR" ]; then
  # .git is never tracked and never shipped, so a stale or hostile cache cannot
  # ride into the repo or into CI, which always starts cold.
  git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
  CACHE_DIR="${git_dir:-$ROOT/.fm-lint}/fm-lint-cache"
fi
USE_CACHE=1
[ -n "$HASHER" ] || USE_CACHE=0
[ "${FM_LINT_NO_CACHE:-0}" = 1 ] && USE_CACHE=0

JOBS="${FM_LINT_JOBS:-}"
if [ -z "$JOBS" ]; then
  JOBS=$(nproc 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null || echo 4)
  # Past this, added shards contend for memory bandwidth instead of adding
  # throughput (measured on this repo: 8 concurrent ShellCheck processes
  # returned about 3x, 16 returned about 5x), while every extra shard
  # re-analyses the shared libraries its owned files pull in.
  [ "$JOBS" -gt 8 ] && JOBS=8
fi
[ "$JOBS" -ge 1 ] || JOBS=1

# --- closures ---------------------------------------------------------------
# One shard per file gives each file's own transitive closure, which is both the
# exact input set ShellCheck reads for it and therefore the exact thing its
# cache key has to cover.
if ! awk -v FILES="$TMP/files" -v WORK="" -v JOBS=1 -v MODE=closures \
  -f "$ROOT/bin/fm-lint-plan.awk" >"$TMP/closures" 2>"$TMP/plan.err"; then
  # Never silently lint less than the canonical set: if planning fails for any
  # reason, fall back to the reference implementation rather than guessing.
  printf 'fm-lint.sh: could not plan the lint (%s); falling back to the canonical command.\n' \
    "$(tr -d '\n' <"$TMP/plan.err")" >&2
  rm -rf "$TMP"
  exec "$ROOT/bin/fm-lint.sh" --whole-set
fi

# --- cache lookup -----------------------------------------------------------
# Each file's cache line is the pinned version, the flags, and the digest of
# every file ShellCheck will actually read for it (itself plus its closure), in
# a stable order. Any byte change anywhere in that set changes the line, so a
# stale result can never be served. The whole thing is two awk passes and one
# hash pass: doing it per file in the shell cost 12s of process spawns on a
# run that had no linting to do at all.
: >"$TMP/work"
: >"$TMP/material"
MANIFEST="$CACHE_DIR/manifest"

if [ "$USE_CACHE" = 1 ]; then
  mkdir -p "$CACHE_DIR"
  # shellcheck disable=SC2046
  $HASHER $(cat "$TMP/files") >"$TMP/hashes" 2>/dev/null || : >"$TMP/hashes"
  # Both passes below load their lookup table in BEGIN rather than with the
  # usual NR==FNR two-file idiom. That idiom silently inverts when the first
  # file is empty - every record of the SECOND file is then read as a lookup
  # entry and nothing is emitted. On a cold cache the manifest is empty, which
  # made the work set come out empty, which reported all 152 files clean
  # without running ShellCheck at all. A lint gate that passes everything is
  # far worse than a slow one, so neither pass may depend on that idiom.
  awk -v VER="$REQUIRED_SHELLCHECK" -v FLAGS="$LINT_FLAGS" -v HASHES="$TMP/hashes" '
    BEGIN {
      while ((getline hl < HASHES) > 0) {
        split(hl, hf, " ")
        digest[hf[2]] = hf[1]
      }
      close(HASHES)
    }
    {
      n = split($0, m, " ")
      if (n == 0) next
      # Sort the digests so shard ordering can never change the line.
      for (i = 1; i <= n; i++) {
        d = digest[m[i]]
        if (d == "") { bad = 1 }
        h[i] = d
      }
      for (i = 2; i <= n; i++) { v = h[i]; j = i - 1
        while (j >= 1 && h[j] > v) { h[j+1] = h[j]; j-- }
        h[j+1] = v }
      line = VER " " FLAGS
      for (i = 1; i <= n; i++) line = line " " h[i]
      # A file whose digest is missing is never treated as cacheable.
      if (bad) { bad = 0; next }
      printf "%s\t%s\n", m[1], line
    }
  ' "$TMP/closures" >"$TMP/material"
fi

if [ "$USE_CACHE" != 1 ]; then
  cut -d' ' -f1 "$TMP/closures" >"$TMP/work"
else
  [ -f "$MANIFEST" ] || : >"$MANIFEST"
  # A file is a hit only when its entire line is byte-identical to the line
  # recorded by a previous clean run.
  awk -F'\t' -v MAN="$MANIFEST" '
    BEGIN { while ((getline ml < MAN) > 0) seen[ml] = 1; close(MAN) }
    !($0 in seen) { print $1 }
  ' "$TMP/material" >"$TMP/work"
  # Anything the material pass could not key (a missing digest) must still be
  # linted rather than silently dropped from the run.
  cut -d' ' -f1 "$TMP/closures" | sort -u >"$TMP/all-owners"
  cut -f1 "$TMP/material" | sort -u >"$TMP/keyed"
  comm -23 "$TMP/all-owners" "$TMP/keyed" >>"$TMP/work"
  sort -u "$TMP/work" -o "$TMP/work"
fi

total=$(wc -l <"$TMP/files" | tr -d ' ')
todo=$(wc -l <"$TMP/work" | tr -d ' ')
cached=$((total - todo))

if [ "$todo" -eq 0 ]; then
  [ -n "${FM_LINT_EMIT_FINDINGS:-}" ] && : >"$FM_LINT_EMIT_FINDINGS"
  printf 'fm-lint.sh: clean - all %s files unchanged since their last clean lint.\n' \
    "$total" >&2
  exit 0
fi

[ "$JOBS" -le "$todo" ] || JOBS="$todo"
printf 'fm-lint.sh: linting %s of %s files in %s shards (%s cached clean).\n' \
  "$todo" "$total" "$JOBS" "$cached" >&2

if ! awk -v FILES="$TMP/files" -v WORK="$TMP/work" -v JOBS="$JOBS" \
  -f "$ROOT/bin/fm-lint-plan.awk" >"$TMP/plan" 2>"$TMP/plan.err"; then
  printf 'fm-lint.sh: could not plan the lint (%s); falling back to the canonical command.\n' \
    "$(tr -d '\n' <"$TMP/plan.err")" >&2
  rm -rf "$TMP"
  exec "$ROOT/bin/fm-lint.sh" --whole-set
fi

# --- run the shards in parallel ---------------------------------------------
# --format=gcc emits one finding per line, which is what makes shard outputs
# mergeable and comparable. It selects a rendering; it cannot suppress or
# reclassify a finding.
TAB=$(printf '\t')
pids=
idx=0
while IFS="$TAB" read -r sid owned members; do
  [ -n "$members" ] || continue
  idx=$((idx + 1))
  : "$sid" "$owned"
  (
    rc=0
    # shellcheck disable=SC2086
    shellcheck $LINT_FLAGS --format=gcc $members >"$TMP/out.$idx" 2>"$TMP/err.$idx" || rc=$?
    printf '%s\n' "$rc" >"$TMP/rc.$idx"
  ) &
  pids="$pids $!"
done <"$TMP/plan"

for p in $pids; do
  wait "$p" || true
done

# --- collect ----------------------------------------------------------------
fatal=0
i=0
while [ "$i" -lt "$idx" ]; do
  i=$((i + 1))
  [ -f "$TMP/rc.$i" ] || { fatal=1; printf 'fm-lint.sh: shard %s produced no exit status.\n' "$i" >&2; continue; }
  rc=$(cat "$TMP/rc.$i")
  # ShellCheck exits 1 for findings; anything above that is a fatal or usage
  # error and must never be reported as a clean lint.
  if [ "$rc" -gt 1 ]; then
    fatal=1
    printf 'fm-lint.sh: ShellCheck exited %s on shard %s:\n' "$rc" "$i" >&2
    cat "$TMP/err.$i" >&2 2>/dev/null || true
  fi
done

cat "$TMP"/out.* 2>/dev/null | sed '/^$/d' | sort -u >"$TMP/findings"
[ -n "${FM_LINT_EMIT_FINDINGS:-}" ] && cp "$TMP/findings" "$FM_LINT_EMIT_FINDINGS"

if [ "$fatal" = 1 ]; then
  printf 'fm-lint.sh: aborting without a verdict; re-run with --whole-set to reproduce.\n' >&2
  exit 2
fi

if [ -s "$TMP/findings" ]; then
  # Re-render the affected files through ShellCheck's normal output so a failure
  # reads the way a developer expects, giving each file the same closure that
  # produced its findings.
  cut -d: -f1 "$TMP/findings" | sort -u >"$TMP/failed"
  while read -r shard; do
    owner=${shard%% *}
    grep -Fxq "$owner" "$TMP/failed" || continue
    for m in $shard; do printf '%s\n' "$m"; done
  done <"$TMP/closures" | sort -u >"$TMP/replay"
  # shellcheck disable=SC2046,SC2086
  shellcheck $LINT_FLAGS $(cat "$TMP/replay") || true
  printf 'fm-lint.sh: %s finding(s) across %s file(s).\n' \
    "$(wc -l <"$TMP/findings" | tr -d ' ')" "$(wc -l <"$TMP/failed" | tr -d ' ')" >&2
  exit 1
fi

# --- record the clean result ------------------------------------------------
# Every canonical file was either a cache hit or a member of some closed shard,
# and every shard member is analysed against its full closure. So reaching here
# with no findings means every file is clean, and the whole material file is a
# valid manifest. Written atomically so an interrupted run cannot leave a
# half-manifest that would be read as a set of hits.
if [ "$USE_CACHE" = 1 ]; then
  cp "$TMP/material" "$MANIFEST.new" && mv "$MANIFEST.new" "$MANIFEST"
fi

printf 'fm-lint.sh: clean (%s file(s) checked, %s cached).\n' "$todo" "$cached" >&2
exit 0
