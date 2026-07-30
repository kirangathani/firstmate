# shellcheck shell=bash
# fm-test-exec-lib.sh - the base-test execution library for the kept-tests gate.
# Usage: . bin/fm-test-exec-lib.sh   (sourced by bin/fm-assert-tests-kept.sh)
#
# This library is the ONE OWNER of the per-language runner mechanics that
# bin/fm-assert-tests-kept.sh's check 2 (assertion run) drives. fm-assert stays a
# readable orchestrator: it classifies test files, materializes the base/branch
# trees, and composes findings; detecting, running, and parsing a single base
# test file per language lives here.
#
# Runner interface (three functions, each dispatching on a runner spec):
#
#   runner_for_file <worktree> <file>
#       Print the runner SPEC that executes <file>, or nothing when no supported
#       runner applies. A spec is TAB-separated; its first field is the runner
#       name and later fields are runner-specific resolution results:
#         shell
#         pytest<TAB><python><TAB><config-dir>
#       <worktree> is the live worktree the file belongs to; py/js runners
#       resolve their already-provisioned interpreter from it. Always returns 0.
#
#   run_base_test_file <spec> <scratch-dir> <file> <results-out> <err-out> [<ident>...]
#       Run the single base test file <file> from <scratch-dir> using <spec>,
#       writing the machine-readable run output to <results-out> and captured
#       output to <err-out>. Returns the run's exit code. Trailing <ident>
#       arguments are the check-1 identifiers enumerated for <file>
#       (`<file>::<name>`); runners that can execute a subset use them to bound
#       the run to exactly those tests, and the shell runner ignores them.
#
#   passing_idents <spec> <results-out>
#       Print the sorted, unique set of passing test names the runner recorded in
#       <results-out>. fm-assert composes the full <file>::<name> identifier from
#       these names; for the shell runner the name is the `ok - <name>` tail.
#
# Scratch-tree lifecycle (same owner, called by fm-assert around the runs):
#
#   prepare_scratch_env <spec> <scratch-dir> <worktree>
#       Link the worktree's ALREADY-PROVISIONED dependency dirs into the scratch
#       tree. Idempotent, and never writes into <worktree>.
#
#   scratch_untrusted_reason <spec> <scratch-dir> <worktree>
#       Print why a run in <scratch-dir> could not be trusted to exercise the
#       scratch tree's own code, or nothing when it can. A non-empty reason means
#       the file's verdict is `unexecuted:`, never a pass (see "Trusting the
#       scratch tree" below).
#
#   cleanup_scratch_env <scratch-dir>
#       Unlink the linked dependency dirs. MUST run before any recursive delete
#       of <scratch-dir> (see "Cleanup safety" below).
#
# The `shell` runner preserves the exact TAP-style `ok - <name>` protocol the
# check has always used, so firstmate's own shell suite behaves byte-for-byte as
# before: same invocation, same baseline rule (a green exit code is the whole
# trust condition), same parse.
#
# --- pytest ------------------------------------------------------------------
#
# Detection needs BOTH a pytest config marker at or above the test file
# (pytest.ini, pyproject.toml [tool.pytest.ini_options], setup.cfg
# [tool:pytest], tox.ini [pytest]) AND a resolvable interpreter, searched in the
# worktree in this order: .venv/bin/python, venv/bin/python, then .venv/bin/pytest
# whose interpreter is read from its shebang. Every pytest run therefore goes
# through one `<python> -m pytest` path, and that same interpreter parses the
# results and probes import resolution. If none resolves, or `-m pytest
# --version` fails, the file is unsupported and fm-assert reports it unexecuted.
#
# Invocation is bounded to the identifiers check 1 enumerated for the file,
# passed as explicit nodeids:
#   <python> -m pytest -p no:cacheprovider -o addopts= --import-mode=importlib \
#            --junit-xml=<results> <file>::<name> ...
# `-o addopts=` neutralizes repo addopts (coverage gates, -x, --strict) that
# would distort a single-file run; `-p no:cacheprovider` keeps .pytest_cache from
# being written; `--import-mode=importlib` is the layout-robust import mode.
# A green exit code from pytest already means every requested nodeid passed, so
# the shell runner's baseline rule carries over unchanged.
#
# Results are read from the JUnit XML pytest writes natively (no plugin, unlike
# --report-log): a <testcase> with no failure/error/skipped child is a pass, and
# its `name` attribute is the reported name.
#
# Identifier-scheme reconciliation (checks 1 and 2 do NOT share a namespace):
# check 1's Python extractor is lexical and yields the bare `def test_*` name, so
# its identifier is `test_app.py::test_gamma`. pytest's own nodeid matches that
# for a module-level function, but a class method is `TestClass::test_method` and
# a parametrized case is `test_x[param]`, neither of which check 1 produces.
# Check-2 identifiers come from the runner VERBATIM, because a finding must name
# what the runner calls the test for it to be actionable and for a supersession
# entry to reference it. The two checks are independent signals; fm-assert's
# de-dup of a check-2 finding against a check-1 `missing:` line is exact-string
# and stays best-effort. The practical consequence: a class method or
# parametrized case that check 1 named bare cannot be run as a nodeid, so pytest
# exits non-zero on collection and the file is reported unexecuted, never passed.
#
# --- The provisioned environment and the scratch tree ------------------------
#
# Runs use the branch worktree's ALREADY-PROVISIONED environment - the .venv the
# pipeline's test step built, which survives until teardown - and NEVER create
# one. The live worktree is never mutated: fm-assert real-copies the git-tracked
# source into a scratch tree and prepare_scratch_env links the env in, so first
# party writes land in scratch. Python's own resolution comes from the absolute
# interpreter path, so the link is for tree fidelity (and the shape the JS runner
# needs); pytest's default norecursedirs already skips `.venv`/`venv`.
#
# Trusting the scratch tree: an editable install (pip install -e .) leaves a
# .pth/__editable__ entry in site-packages pointing at the ABSOLUTE live worktree
# path, so `import pkg` can load the live tree while we believe we are testing
# scratch - the gate would then lie in exactly the way it exists to prevent.
# Runs therefore set PYTHONPATH to the scratch source roots (which precede
# site-packages, and precede setuptools' editable finder because that finder is
# APPENDED to sys.meta_path), and scratch_untrusted_reason VERIFIES the outcome
# rather than assuming it: it collects every live-worktree path the import system
# can still reach (excluding the env dirs themselves, which are shared by
# design), derives the top-level module names those paths provide, and resolves
# each name with the real interpreter. Any name resolving outside scratch is a
# reason, and fm-assert reports the file unexecuted. A false green is the worst
# possible outcome here, so an unverifiable tree never passes.
#
# Cleanup safety: cleanup_scratch_env deletes each linked dependency dir only
# after asserting it IS a symlink, and with `rm -f`, never a recursive delete.
# It must run before the scratch tree's own `rm -rf`, so cleanup can never
# traverse a link into the live worktree's real .venv.
#
# FM_ASSERT_TESTS_TIMEOUT caps each run's runtime in seconds (default 300) when a
# `timeout` binary exists; the cap is applied by run_base_test_file.

# The optional timeout wrapper, resolved once at source time.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "${FM_ASSERT_TESTS_TIMEOUT:-300}")
fi

# The dependency dirs linked into a scratch tree, and the only names
# cleanup_scratch_env will ever unlink.
FM_ENV_LINK_NAMES=(.venv venv node_modules)

# --- python helper programs --------------------------------------------------
# Read by the resolved interpreter, so parsing and import probing use the same
# Python the tests run under.

# Print each passing testcase name from a pytest JUnit XML report.
FM_PY_JUNIT_SRC='
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
for case in root.iter("testcase"):
    if any(child.tag in ("failure", "error", "skipped") for child in case):
        continue
    name = case.get("name")
    if name:
        print(name)
'

# Print one line per top-level module that still resolves OUTSIDE the scratch
# tree because the live worktree is reachable from the import system. No output
# means the scratch tree is authoritative for first-party imports.
FM_PY_TRUST_SRC='
import glob, importlib.util, os, re, sys

live = os.path.realpath(sys.argv[1])
scratch = os.path.realpath(sys.argv[2])


def under(path, root):
    return path == root or path.startswith(root + os.sep)


# The provisioned env lives under the live worktree and is shared by design, so
# site-packages itself is never the hazard - only live FIRST-PARTY source is.
env_roots = [os.path.join(live, name) for name in (".venv", "venv")]


def is_env(path):
    return any(under(path, root) for root in env_roots)


live_paths = set()
for entry in sys.path:
    if not entry:
        continue
    real = os.path.realpath(entry)
    if under(real, scratch):
        continue
    if under(real, live) and not is_env(real):
        live_paths.add(real)
    if not os.path.isdir(real):
        continue
    for pattern in ("*.pth", "__editable__*", "*.egg-link"):
        for artifact in glob.glob(os.path.join(real, pattern)):
            try:
                with open(artifact, encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
            except OSError:
                continue
            for hit in re.findall(re.escape(live) + r"[^\s\x27\"]*", text):
                hit = os.path.realpath(hit.rstrip("/"))
                if not is_env(hit):
                    live_paths.add(hit)


def top_names(path):
    if os.path.isfile(path) and path.endswith(".py"):
        return [os.path.basename(path)[:-3]]
    if not os.path.isdir(path):
        return []
    if os.path.exists(os.path.join(path, "__init__.py")):
        return [os.path.basename(path)]
    names = []
    for child in sorted(os.listdir(path)):
        full = os.path.join(path, child)
        if os.path.isdir(full) and os.path.exists(os.path.join(full, "__init__.py")):
            names.append(child)
        elif child.endswith(".py") and child != "__init__.py":
            names.append(child[:-3])
    return names


candidates = set()
for path in live_paths:
    candidates.update(top_names(path))

for name in sorted(candidates):
    try:
        spec = importlib.util.find_spec(name)
    except Exception:
        continue
    if spec is None:
        continue
    origins = []
    if spec.origin and spec.origin not in ("built-in", "frozen"):
        origins.append(spec.origin)
    origins.extend(list(getattr(spec, "submodule_search_locations", None) or []))
    for origin in origins:
        real = os.path.realpath(origin)
        if not under(real, scratch):
            print("%s resolves to %s, outside the scratch tree" % (name, real))
            break
'

# --- pytest detection --------------------------------------------------------

# fm_py_config_dir <worktree> <file>: print the worktree-relative directory
# holding the nearest pytest config at or above <file> (empty string for the
# worktree root), or return 1 when no config marker exists.
fm_py_config_dir() {
  local wt=$1 dir=${2%/*} probe
  [ "$dir" != "$2" ] || dir=
  while :; do
    probe="$wt${dir:+/$dir}"
    if [ -f "$probe/pytest.ini" ] \
      || { [ -f "$probe/pyproject.toml" ] && grep -q '^\[tool\.pytest\.ini_options\]' "$probe/pyproject.toml"; } \
      || { [ -f "$probe/setup.cfg" ] && grep -q '^\[tool:pytest\]' "$probe/setup.cfg"; } \
      || { [ -f "$probe/tox.ini" ] && grep -q '^\[pytest\]' "$probe/tox.ini"; }; then
      printf '%s' "$dir"
      return 0
    fi
    [ -n "$dir" ] || return 1
    case "$dir" in
      */*) dir=${dir%/*} ;;
      *) dir= ;;
    esac
  done
}

# fm_py_interpreter <worktree>: print a python that can run `-m pytest` from the
# worktree's provisioned env, or return 1. The `.venv/bin/pytest` fallback is
# honored by reading that script's shebang interpreter, so every pytest run and
# every result parse goes through one interpreter.
fm_py_interpreter() {
  local wt=$1 candidate shebang
  for candidate in "$wt/.venv/bin/python" "$wt/venv/bin/python"; do
    if [ -x "$candidate" ] && "$candidate" -m pytest --version >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  candidate="$wt/.venv/bin/pytest"
  if [ -x "$candidate" ]; then
    IFS= read -r shebang < "$candidate" || shebang=
    shebang=${shebang#\#!}
    shebang=${shebang%% *}
    if [ -n "$shebang" ] && [ -x "$shebang" ] && "$shebang" -m pytest --version >/dev/null 2>&1; then
      printf '%s' "$shebang"
      return 0
    fi
  fi
  return 1
}

# --- runner interface --------------------------------------------------------

# runner_for_file <worktree> <file>: the runner spec that executes <file>, or
# nothing. Shell wins for tests/*.test.sh (at any depth) exactly as check 1's
# language classification does, so firstmate's own suite is never mis-detected.
runner_for_file() {
  local wt=$1 f=$2 base configdir python
  case "$f" in
    tests/*.test.sh|*/tests/*.test.sh) echo shell; return 0 ;;
  esac
  base=${f##*/}
  case "$base" in
    test_*.py|*_test.py)
      configdir=$(fm_py_config_dir "$wt" "$f") || return 0
      python=$(fm_py_interpreter "$wt") || return 0
      printf 'pytest\t%s\t%s\n' "$python" "$configdir"
      return 0
      ;;
  esac
  return 0
}

# fm_py_pythonpath <scratch> <config-dir>: the colon-joined scratch source roots
# a pytest run puts ahead of site-packages. The ambient PYTHONPATH is
# deliberately NOT inherited: it can point at the live worktree.
fm_py_pythonpath() {
  local scratch=$1 configdir=$2 candidate out=
  local roots=("$scratch" "$scratch/src")
  if [ -n "$configdir" ]; then
    roots+=("$scratch/$configdir" "$scratch/$configdir/src")
  fi
  for candidate in "${roots[@]}"; do
    [ -d "$candidate" ] || continue
    case ":$out:" in *":$candidate:"*) continue ;; esac
    out="${out:+$out:}$candidate"
  done
  printf '%s' "$out"
}

# run_base_test_file <spec> <scratch-dir> <file> <results-out> <err-out> [<ident>...]:
# run one base test file from the scratch tree root, returning its exit code.
run_base_test_file() {
  local spec=$1 scratch=$2 f=$3 results=$4 errout=$5
  shift 5
  local runner python configdir pythonpath
  IFS=$'\t' read -r runner python configdir <<< "$spec"
  case "$runner" in
    shell)
      # firstmate's own env overrides are stripped so a firstmate-repo test file
      # runs against the scratch tree, never this home's live state.
      (
        cd "$scratch" || exit 125
        FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_HOME='' \
          ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} bash "$f"
      ) > "$results" 2>"$errout"
      ;;
    pytest)
      # Nothing to select means nothing to verify; the caller reports the file
      # unexecuted rather than reading an empty run as a pass.
      [ $# -gt 0 ] || return 125
      : > "$results"
      pythonpath=$(fm_py_pythonpath "$scratch" "$configdir")
      (
        cd "$scratch" || exit 125
        PYTHONPATH="$pythonpath" PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS='' \
        FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_HOME='' \
          ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$python" -m pytest \
            -p no:cacheprovider -o addopts= --import-mode=importlib \
            --junit-xml="$results" "$@"
      ) > "$errout" 2>&1
      ;;
    *)
      return 125
      ;;
  esac
}

# passing_idents <spec> <results-out>: the sorted unique passing test names of
# one run, read from that runner's machine-readable output.
passing_idents() {
  local spec=$1 results=$2 runner python
  IFS=$'\t' read -r runner python _ <<< "$spec"
  case "$runner" in
    shell)
      sed -n 's/^ok - //p' "$results" | sort -u
      ;;
    pytest)
      [ -s "$results" ] || return 0
      "$python" -c "$FM_PY_JUNIT_SRC" "$results" 2>/dev/null | sort -u
      ;;
  esac
}

# --- scratch-tree lifecycle --------------------------------------------------

# prepare_scratch_env <spec> <scratch-dir> <worktree>: link the worktree's
# already-provisioned dependency dirs into the scratch tree. Idempotent, and it
# never writes into <worktree>.
prepare_scratch_env() {
  local spec=$1 scratch=$2 wt=$3 runner name
  IFS=$'\t' read -r runner _ <<< "$spec"
  case "$runner" in
    pytest) ;;
    *) return 0 ;;
  esac
  for name in "${FM_ENV_LINK_NAMES[@]}"; do
    [ -d "$wt/$name" ] || continue
    if [ -e "$scratch/$name" ] || [ -L "$scratch/$name" ]; then
      continue
    fi
    ln -s "$wt/$name" "$scratch/$name"
  done
  return 0
}

# scratch_untrusted_reason <spec> <scratch-dir> <worktree>: why a run in the
# scratch tree could not be trusted to exercise the scratch tree's own code, or
# nothing when it can. See "Trusting the scratch tree" in this file's header.
scratch_untrusted_reason() {
  local spec=$1 scratch=$2 wt=$3 runner python configdir out
  IFS=$'\t' read -r runner python configdir <<< "$spec"
  case "$runner" in
    pytest) ;;
    *) return 0 ;;
  esac
  out=$(
    cd "$scratch" || exit 1
    PYTHONPATH="$(fm_py_pythonpath "$scratch" "$configdir")" PYTHONDONTWRITEBYTECODE=1 \
      "$python" -c "$FM_PY_TRUST_SRC" "$wt" "$scratch" 2>&1
  ) || {
    printf 'import resolution could not be verified'
    return 0
  }
  [ -n "$out" ] || return 0
  printf 'the branch worktree shadows the scratch tree: %s' "$(printf '%s' "$out" | tr '\n' ';')"
}

# cleanup_scratch_env <scratch-dir>: unlink the linked dependency dirs. MUST run
# before any recursive delete of the scratch tree, and only ever unlinks a path
# that IS a symlink, so cleanup can never traverse into the live worktree's real
# dependency dirs.
cleanup_scratch_env() {
  local scratch=$1 name
  [ -n "$scratch" ] || return 0
  for name in "${FM_ENV_LINK_NAMES[@]}"; do
    if [ -L "$scratch/$name" ]; then
      rm -f "$scratch/$name"
    fi
  done
  return 0
}
