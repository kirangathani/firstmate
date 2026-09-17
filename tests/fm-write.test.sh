#!/usr/bin/env bash
# tests/fm-write.test.sh - the short-lived document writer's guarantees.
#
# The writer itself is stubbed: a fake `claude` first on PATH stands in for the
# real one, so every case is deterministic, costs nothing, and runs in a second.
# What is under test is not the model's prose - it is everything around it: what
# gets piped in, what is refused, and what happens to the target file when the
# writer comes back wrong.
#
# The stub reads the same stdin bundle the real writer would, so the bundle
# assertions below are made against the exact bytes a writer receives.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-write.sh"

TMP=
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

TMP=$(mktemp -d)
HOME_DIR="$TMP/home"
DATA="$HOME_DIR/data"
STATE="$HOME_DIR/state"
BIN="$TMP/bin"
mkdir -p "$DATA" "$STATE" "$BIN"

printf 'CAPTAIN-MARKER: he prefers short answers.\n' > "$DATA/captain.md"
printf 'LEARNINGS-MARKER: the box died three times on 2026-08-09.\n' > "$DATA/learnings.md"
printf 'EXTRA-MARKER: something only this document needs.\n' > "$TMP/extra.md"

# The stub. It records the bundle it was given, then behaves as FM_STUB_MODE
# says, so each case drives a different writer outcome through the real script.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Records its own pid so the test can prove the writer really died rather than
# asserting against a process listing that would match nothing either way.
printf '%s\n' "$$" >> "$FM_STUB_PIDS"
cat > "$FM_STUB_BUNDLE"
case "${FM_STUB_MODE:-ok}" in
  ok) printf 'A document long enough to be a document.\n'
      head -c 2000 /dev/zero | tr '\0' 'x' ;;
  stub) printf 'I will gather the state first.\n' ;;
  crash) echo "the writer broke" >&2; exit 3 ;;
  hang) # A child of its own, whose pid is recorded too, so the death check
        # below covers a writer's DESCENDANTS and not only the writer.
        # `timeout` runs its command in a new process group and signals the
        # group, so they do die (verified 2026-09-17); this keeps that property
        # asserted rather than assumed, because a writer that leaves children
        # behind is exactly the memory cost this whole shape exists to avoid.
        sleep 30 & printf '%s\n' "$!" >> "$FM_STUB_PIDS"; sleep 30 ;;
esac
STUB
chmod +x "$BIN/claude"
export FM_STUB_BUNDLE="$TMP/bundle.txt"
export FM_STUB_PIDS="$TMP/writer-pids"
: > "$FM_STUB_PIDS"

run() {
  PATH="$BIN:$PATH" FM_HOME="$HOME_DIR" bash "$SCRIPT" "$@"
}

# --- the project-write boundary is enforced, not promised ---------------------
# AGENTS.md rule 1 forbids firstmate writing into a project at all. A path check
# is a cheaper guarantee than an instruction a caller can forget.
out=$(printf 'x\n' | run --out "$TMP/outside.md" 2>&1) && fail "a document outside the home's data directory is refused"
case "$out" in
  *"must be inside"*) : ;;
  *) printf 'refusal said: %s\n' "$out" >&2
     fail "a document outside the home's data directory is refused" ;;
esac
pass "a document outside the home's data directory is refused"

# --- an existing document is not silently replaced ----------------------------
printf 'the good version\n' > "$DATA/existing.md"
printf 'x\n' | run --out "$DATA/existing.md" >/dev/null 2>&1 \
  && fail "an existing document is not replaced without being asked"
[ "$(cat "$DATA/existing.md")" = "the good version" ] \
  || fail "an existing document is not replaced without being asked"
pass "an existing document is not replaced without being asked"

# --- the writer is never left to guess what to write --------------------------
run --out "$DATA/guessed.md" < /dev/null >/dev/null 2>&1 \
  && fail "an empty instruction is refused rather than guessed at"
[ -e "$DATA/guessed.md" ] && fail "an empty instruction is refused rather than guessed at"
pass "an empty instruction is refused rather than guessed at"

# --- an unverified harness is refused by name ---------------------------------
# AGENTS.md section 4: never dispatch on an unverified adapter, and a writer is
# a dispatch.
out=$(printf 'x\n' | FM_WRITE_HARNESS=codex run --out "$DATA/wrong-harness.md" 2>&1) \
  && fail "an unverified writer harness is refused rather than attempted"
case "$out" in
  *"not a verified writer harness"*) : ;;
  *) printf 'refusal said: %s\n' "$out" >&2
     fail "an unverified writer harness is refused rather than attempted" ;;
esac
pass "an unverified writer harness is refused rather than attempted"

# --- a successful write lands the document and reports one line ---------------
export FM_STUB_MODE=ok
out=$(printf 'Write the thing.\n' | run --out "$DATA/good.md" 2>&1) \
  || { printf 'writer said: %s\n' "$out" >&2; fail "a successful write lands the document and reports one line"; }
lines=$(printf '%s\n' "$out" | grep -c .)
[ "$lines" = 1 ] || { printf 'writer said: %s\n' "$out" >&2
                      fail "a successful write lands the document and reports one line"; }
case "$out" in
  wrote:*good.md*) : ;;
  *) printf 'writer said: %s\n' "$out" >&2
     fail "a successful write lands the document and reports one line" ;;
esac
[ -s "$DATA/good.md" ] || fail "a successful write lands the document and reports one line"
pass "a successful write lands the document and reports one line"

# --- the result line is handed to the next wake -------------------------------
# Under a Monitor the printed line is the notification, but a Monitor that
# expires before delivering it would take the only copy with it.
grep -q 'wrote:' "$STATE/.wake-results" 2>/dev/null \
  || fail "the result line is recorded for the next wake as well as printed"
pass "the result line is recorded for the next wake as well as printed"

# --- a stub answer never replaces a document ----------------------------------
# Measured 2026-09-17: given no tools and no warning it had none, a writer
# announced a plan, attempted one tool call, and returned 395 bytes. Writing
# that over a good document is worse than not writing at all.
printf 'the good version\n' > "$DATA/floor.md"
export FM_STUB_MODE=stub
out=$(printf 'Write the thing.\n' | run --force --out "$DATA/floor.md" 2>&1) \
  && fail "a writer answer under the floor is reported and nothing is written"
case "$out" in
  write-failed:*) : ;;
  *) printf 'writer said: %s\n' "$out" >&2
     fail "a writer answer under the floor is reported and nothing is written" ;;
esac
[ "$(cat "$DATA/floor.md")" = "the good version" ] \
  || fail "a writer answer under the floor is reported and nothing is written"
pass "a writer answer under the floor is reported and nothing is written"

# --- a writer that fails never replaces a document ----------------------------
printf 'the good version\n' > "$DATA/crash.md"
export FM_STUB_MODE=crash
out=$(printf 'Write the thing.\n' | run --force --out "$DATA/crash.md" 2>&1) \
  && fail "a writer that fails is reported and nothing is written"
case "$out" in
  write-failed:*) : ;;
  *) printf 'writer said: %s\n' "$out" >&2
     fail "a writer that fails is reported and nothing is written" ;;
esac
[ "$(cat "$DATA/crash.md")" = "the good version" ] \
  || fail "a writer that fails is reported and nothing is written"
pass "a writer that fails is reported and nothing is written"

# --- a writer that will not finish is stopped ---------------------------------
printf 'the good version\n' > "$DATA/hang.md"
export FM_STUB_MODE=hang
out=$(printf 'Write the thing.\n' | run --force --timeout 2 --out "$DATA/hang.md" 2>&1) \
  && fail "a writer that will not finish is stopped and nothing is written"
case "$out" in
  write-failed:*) : ;;
  *) printf 'writer said: %s\n' "$out" >&2
     fail "a writer that will not finish is stopped and nothing is written" ;;
esac
[ "$(cat "$DATA/hang.md")" = "the good version" ] \
  || fail "a writer that will not finish is stopped and nothing is written"
pass "a writer that will not finish is stopped and nothing is written"

# --- no writer process outlives the command ------------------------------------
# The captain's stated reason for this whole shape is memory: the writers have
# to die, including the one that had to be stopped. Each stub recorded its own
# pid, so this is a real liveness check and not a process listing that would
# match nothing whatever happened.
while read -r writer_pid; do
  [ -n "$writer_pid" ] || continue
  if kill -0 "$writer_pid" 2>/dev/null; then
    printf 'still alive: %s\n' "$writer_pid" >&2
    fail "no writer process outlives the command that started it"
  fi
done < "$FM_STUB_PIDS"
[ -s "$FM_STUB_PIDS" ] || fail "no writer process outlives the command that started it"
pass "no writer process outlives the command that started it"

# --- the bundle carries the context and the learnings -------------------------
# The captain's premise is that context and learnings are the whole difference
# between firstmate and a writer it sets up, so a bundle missing them is the
# mechanism not doing its job.
export FM_STUB_MODE=ok
printf 'Write the thing.\n' | run --no-fleet --context "$TMP/extra.md" --out "$DATA/bundled.md" >/dev/null 2>&1 \
  || fail "the bundle carries the captain preferences, the learnings, the named context, and the instruction"
for marker in CAPTAIN-MARKER LEARNINGS-MARKER EXTRA-MARKER 'Write the thing.'; do
  grep -q "$marker" "$FM_STUB_BUNDLE" || {
    printf 'missing from bundle: %s\n' "$marker" >&2
    fail "the bundle carries the captain preferences, the learnings, the named context, and the instruction"
  }
done
pass "the bundle carries the captain preferences, the learnings, the named context, and the instruction"

# --- the bundle tells the writer it has no tools -------------------------------
# This sentence is what turned the measured 395-byte stub answer into a real
# document, so it is a guarantee and not decoration.
grep -qi 'NO TOOLS' "$FM_STUB_BUNDLE" \
  || fail "the bundle tells the writer it has no tools"
pass "the bundle tells the writer it has no tools"

# --- the bundle carries the discipline the document is judged by ---------------
grep -q '\[F\]' "$FM_STUB_BUNDLE" || fail "the bundle carries the evidence-tagging discipline"
grep -q '\[O\]' "$FM_STUB_BUNDLE" || fail "the bundle carries the evidence-tagging discipline"
pass "the bundle carries the evidence-tagging discipline"

# --- an omitted section is omitted ---------------------------------------------
printf 'Write the thing.\n' | run --no-fleet --no-learnings --no-captain --out "$DATA/lean.md" >/dev/null 2>&1 \
  || fail "an omitted section is left out of the bundle"
grep -q CAPTAIN-MARKER "$FM_STUB_BUNDLE" && fail "an omitted section is left out of the bundle"
grep -q LEARNINGS-MARKER "$FM_STUB_BUNDLE" && fail "an omitted section is left out of the bundle"
pass "an omitted section is left out of the bundle"

# --- inspecting the bundle spends no writer and writes nothing -----------------
printf 'x\n' > "$FM_STUB_BUNDLE"
out=$(printf 'Write the thing.\n' | run --context-only --no-fleet --out "$DATA/never.md" 2>&1) \
  || fail "inspecting the bundle spends no writer and writes nothing"
[ -e "$DATA/never.md" ] && fail "inspecting the bundle spends no writer and writes nothing"
[ "$(cat "$FM_STUB_BUNDLE")" = "x" ] || fail "inspecting the bundle spends no writer and writes nothing"
case "$out" in
  *CAPTAIN-MARKER*) : ;;
  *) fail "inspecting the bundle spends no writer and writes nothing" ;;
esac
pass "inspecting the bundle spends no writer and writes nothing"

# --- the refill flag is only honoured where it is safe -------------------------
# It replaces the process with a waiting arm, so a caller that passes it
# anywhere but first must be told rather than have it quietly ignored.
out=$(printf 'x\n' | run --out "$DATA/late-refill.md" --refill 2>&1) \
  && fail "the refill flag is refused anywhere but first"
case "$out" in
  *"only accepted as the FIRST argument"*) : ;;
  *) printf 'refusal said: %s\n' "$out" >&2
     fail "the refill flag is refused anywhere but first" ;;
esac
pass "the refill flag is refused anywhere but first"

cleanup
