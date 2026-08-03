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
#         vitest<TAB><node>
#         jest<TAB><node>
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
#   passing_idents <spec> <results-out> [<file>]
#       Print the sorted, unique set of passing test names the runner recorded in
#       <results-out>. fm-assert composes the full <file>::<name> identifier from
#       these names; for the shell runner the name is the `ok - <name>` tail.
#       <file> is the repo-relative test file the run was for; the JS runners use
#       it to keep names from a suffix-colliding file a substring filter also
#       matched out of this file's result set (see the vitest section below), and
#       the other runners ignore it.
#
#   skipped_idents <spec> <results-out> [<file>]
#       Print the sorted, unique set of test names the runner recorded as an
#       EXPLICIT skip in <results-out>. fm-assert subtracts these AND
#       passing_idents from the identifiers the run was bounded to; whatever is
#       left produced no result at all and is reported `unaccounted:`. The shell
#       runner's TAP protocol has no skip marker, so it never reports one and an
#       unrun shell name is therefore unaccounted rather than skipped.
#
#   fm_reported_name_accounts <spec> <requested> <reported>
#       Succeed when one runner-reported name accounts for one check-1 requested
#       name. The per-runner reconciliation rule between the two namespaces
#       (equality everywhere; pytest's `<name>[...]` parametrized cases; the JS
#       runners' composed `a > b` titles matched by whole segment) lives here
#       with the identifier-scheme notes that justify it, so fm-assert's
#       accounting loop stays runner-agnostic.
#
# Scratch-tree lifecycle (same owner, called by fm-assert around the runs):
#
#   prepare_scratch_env <spec> <scratch-dir> <worktree>
#       Link the worktree's ALREADY-PROVISIONED dependency dirs into the scratch
#       tree. Idempotent, and never writes into <worktree>.
#
#   scratch_untrusted_reason <spec> <scratch-dir> <worktree> <file>
#       Print why a run in <scratch-dir> could not be trusted to exercise the
#       scratch tree's own code, or nothing when it can. <file> is the test file
#       the run will execute, so the probe resolves imports through exactly the
#       PYTHONPATH run_base_test_file will use. A non-empty reason means the
#       file's verdict is `unexecuted:`, never a pass (see "Trusting the scratch
#       tree" below).
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
# being written; `--import-mode=importlib` is kept because it is the only mode
# that tolerates the same test basename in two directories without an
# __init__.py. The trade it makes is that, unlike the default prepend mode, it
# does NOT insert the test file's own directory into sys.path, so a tests/ dir of
# sibling helper modules (`from helpers import x`) would stop resolving. That
# directory is therefore supplied explicitly among the PYTHONPATH roots, resolved
# inside the SCRATCH tree and never the live worktree, so prepend-mode-dependent
# suites still execute without weakening the authoritativeness guard.
# A green exit code from pytest already means every requested nodeid passed, so
# the shell runner's baseline rule carries over unchanged.
#
# Results are read from the JUnit XML pytest writes natively (no plugin, unlike
# --report-log): a <testcase> with no failure/error/skipped child is a pass, and
# its `name` attribute is the reported name. A <testcase> carrying a <skipped>
# child is an EXPLICIT skip - pytest records @pytest.mark.skip, a true skipif and
# an xfail that way - and skipped_idents reports it, so a green run that verified
# nothing is visible as a per-identifier skip instead of a bare pass. A report
# that is missing, empty or unparseable yields neither set, so every requested
# name comes back unaccounted at the orchestrator; the same is true, per nodeid,
# of a name the run produced no <testcase> for at all.
#
# The report cannot distinguish a deliberate skip from a skipif that is true ONLY
# because of the scratch environment (a missing optional dependency, a platform
# guard): both are a <skipped> child, so both land in skipped:. That limit is
# carried forward deliberately, not closed here.
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
# and stays best-effort.
#
# The two schemes diverge differently for the two cases, verified against a real
# pytest, and conflating them was a live bug:
#   - CLASS METHOD: the bare nodeid `test_mod.py::test_method` does NOT resolve,
#     pytest exits 4 having collected nothing, and the base_rc path reports the
#     file unexecuted. Correct, and unchanged.
#   - PARAMETRIZED: the bare nodeid `test_mod.py::test_x` IS accepted. pytest
#     exits 0, runs every case, and emits the JUnit names `test_x[1]`,
#     `test_x[2]` - so the run really did verify the requested name under names
#     check 1 never produces.
# fm-assert therefore accounts a requested bare name against runner names by
# equality OR by the name followed IMMEDIATELY by a literal `[`, never by a bare
# string prefix (`test_xy[a]` must not account for a requested `test_x`). Passing
# takes precedence over skipped, so one passing case of a parametrized name means
# that name was verified.
#
# --- vitest / jest -----------------------------------------------------------
#
# Detection reads the NEAREST package.json at or above the test file. v1
# executes only a single-package layout whose nearest package.json is the repo
# root: a nested nearest package.json (a workspace or monorepo member) means the
# config, dependency hoisting, and env-link layout cannot be confidently
# resolved, so the file is unsupported and fm-assert reports it unexecuted -
# fail safe, widen coverage from what real projects surface. The runner is
# vitest or jest per devDependencies/dependencies and the presence of
# vitest.config.* / jest.config.* (or a "jest" key in package.json); when both
# runners are signalled, a config file breaks the tie, and vitest is preferred
# when the tie stands. A `node` on PATH is required (it reads package.json and
# parses results; the .bin shims also resolve their interpreter through `env
# node`), and the binary must exist at <worktree>/node_modules/.bin/<runner>.
# If node_modules or the binary is absent, the file is unsupported and becomes
# unexecuted, never a silent pass.
#
# Invocation runs from the scratch tree root so config discovery, path aliases,
# and node_modules resolution match the project's own `npm test`:
#   vitest run --root <scratch> --cache=false --reporter=json \
#              --outputFile=<results> <file>
#   jest --rootDir <scratch> --reporters=default --json --outputFile=<results> \
#        --runTestsByPath <file>
# `--cache=false` is REQUIRED for vitest: without it a run writes its results
# cache into node_modules/.vite/, which the env symlink would deliver into the
# live worktree's real node_modules (verified 2026-08-03, vitest 3.2.7; the
# flag verifiably stops every node_modules write). jest's cache goes to the OS
# tmpdir and needs no counterpart. The ambient NODE_PATH and NODE_OPTIONS are
# stripped for the same reason PYTHONPATH is not inherited: both are resolution
# and preload backdoors that can reach outside the scratch tree.
#
# Results are read from the jest-shaped JSON both runners emit natively
# (testResults[].assertionResults[] with status/title/ancestorTitles), one
# parser for both. vitest's JUnit reporter is equally built in, but parsing XML
# robustly needs a parser bash does not have, while `node` - already required
# here - parses JSON exactly; same no-new-plugin-dependency intent, sturdier
# read. A pass is status == "passed"; an EXPLICIT skip is status "skipped",
# "pending", "todo", or "disabled" (verified 2026-08-03: it.skip reports
# "skipped" on vitest 3.2.7 and "pending" on jest 30.4.1, test.todo reports
# "todo" on both). A missing, empty, or unparseable report yields neither set,
# so every requested name comes back unaccounted at the orchestrator.
#
# The reported name is ancestorTitles + title joined with " > ", exactly how
# vitest composes its own full titles. This is a rendering of the runner's
# structured fields, not a normalization toward check 1's shape: the runners'
# own single-string `fullName` joins with plain spaces ("greet x behaves"),
# which cannot be split back into segments, while the " > " join keeps the
# describe path recoverable. Check 1's JS extractor emits each it/test/describe
# first string argument SEPARATELY, so a requested bare name is accounted for
# when it equals a whole " > "-separated segment of a reported name - describe
# titles included - and never by bare substring. Two limits are deliberate: a
# title containing a literal " > " is indistinguishable from a segment
# boundary, and an it.each/test.each template ("adds %i") never matches its
# substituted run-time titles, so it lands in unaccounted - both are
# informational classes that do not affect the exit code.
#
# One imprecision is carried consciously: vitest selects files by SUBSTRING
# filter, so a path that is a suffix of another (mod.test.js beside
# src/mod.test.js) can pull the colliding file into the run. The result parse
# filters testcases to the requested file, so passing/skipped sets stay
# correct; the residual effect is that a colliding file red on the base can
# fail that baseline run and report this file unexecuted - fail safe, never a
# false pass. jest's --runTestsByPath selects exactly the named file.
#
# The JS analogue of the editable-install hazard is a linked first-party
# package: npm/pnpm/yarn workspaces and file:/npm-link dependencies leave a
# node_modules/<name> symlink pointing at live-worktree source, so a bare
# specifier import loads the LIVE tree while we believe we are testing scratch.
# scratch_untrusted_reason therefore scans the worktree's top-level
# node_modules entries (scoped @*/ included): a symlink resolving inside the
# live worktree but outside node_modules itself is first-party live code and
# the file is reported unexecuted. Links resolving elsewhere (a shared store, a
# global npm-link target) are third-party env by the same rule that shares
# site-packages. Node resolves the scratch test file's relative imports inside
# scratch and its bare specifiers through the scratch node_modules link, so
# with no such first-party link the scratch tree is authoritative.
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
# The probe's VERDICT is keyed on its stdout alone. It deliberately runs with
# site processing enabled (that is how it sees editable `.pth` entries), and an
# `import` line in a .pth executes at startup, so a DeprecationWarning or an
# ambient PYTHONWARNINGS lands on stderr; reading that as shadow evidence would
# refuse a merge on a tree that is in fact authoritative. Stderr is captured only
# as human-facing evidence, and a non-zero exit from the probe is still the
# "could not verify" reason, so failing safe is preserved.
#
# Cleanup safety: cleanup_scratch_env deletes each linked dependency dir only
# after asserting it IS a symlink, and with `rm -f`, never a recursive delete.
# It must run before the scratch tree's own `rm -rf`, so cleanup can never
# traverse a link into the live worktree's real .venv.
#
# FM_ASSERT_TESTS_TIMEOUT caps each run's runtime in seconds (default 300) when a
# `timeout` binary exists; the cap is applied by run_base_test_file.
#
# FM_TEST_EXEC_CACHE_DIR points at a writable directory in which interpreter
# resolution and trust verdicts are memoized (see "memoization" below). It is
# optional: with it unset every probe simply recomputes.

# The optional timeout wrapper, resolved once at source time.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "${FM_ASSERT_TESTS_TIMEOUT:-300}")
fi

# The dependency dirs linked into a scratch tree, and the only names
# cleanup_scratch_env will ever unlink.
FM_ENV_LINK_NAMES=(.venv venv node_modules)

# --- memoization -------------------------------------------------------------
# Interpreter resolution and the trust probe each spawn a Python (a pytest import
# included) and return the same answer for every test file that shares their
# inputs, so a repo of N Python test files would otherwise pay N times over.
# Both are reached through command substitution from fm-assert-tests-kept.sh,
# which is a SUBSHELL, so a shell variable could never persist; results are
# memoized as files under FM_TEST_EXEC_CACHE_DIR instead. Each slot stores its
# key verbatim next to its value and is only read back on an EXACT key match, so
# a checksum collision costs a recomputation and can never yield another key's
# verdict.

# fm_cache_slot <namespace> <key>: the slot path prefix for <key>, or return 1
# when no cache directory is configured.
fm_cache_slot() {
  local ns=$1 key=$2 sum
  [ -n "${FM_TEST_EXEC_CACHE_DIR:-}" ] && [ -d "${FM_TEST_EXEC_CACHE_DIR:-}" ] || return 1
  sum=$(printf '%s' "$key" | cksum | tr -cd '0-9')
  printf '%s/%s.%s' "$FM_TEST_EXEC_CACHE_DIR" "$ns" "$sum"
}

# fm_cache_get <namespace> <key>: print the memoized value and return 0 on a
# hit, return 1 on a miss. An empty value is a legitimate hit.
fm_cache_get() {
  local slot
  slot=$(fm_cache_slot "$1" "$2") || return 1
  [ -f "$slot.key" ] && [ -f "$slot.val" ] || return 1
  [ "$(cat "$slot.key")" = "$2" ] || return 1
  cat "$slot.val"
}

# fm_cache_put <namespace> <key> <value>: memoize <value>. Never fails the
# caller; an unwritable cache just means the next call recomputes.
fm_cache_put() {
  local slot
  slot=$(fm_cache_slot "$1" "$2") || return 0
  # The key is written LAST, so a half-written slot reads as a miss rather than
  # as some other key's value.
  rm -f "$slot.key"
  printf '%s' "$3" > "$slot.val" 2>/dev/null || return 0
  printf '%s' "$2" > "$slot.key" 2>/dev/null || rm -f "$slot.val"
  return 0
}

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

# Print each EXPLICITLY skipped testcase name from a pytest JUnit XML report.
FM_PY_JUNIT_SKIPPED_SRC='
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
for case in root.iter("testcase"):
    if not any(child.tag == "skipped" for child in case):
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
# Resolved, because every path compared against these is resolved too: a .venv
# that is itself a symlink would otherwise never match its own contents.
env_roots = [os.path.realpath(os.path.join(live, name)) for name in (".venv", "venv")]


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
            # The literal match is a PREFIX match, so a sibling worktree whose
            # path merely starts with <live> would slip through; containment is
            # re-checked on the RESOLVED path, which also drops an entry spelled
            # through <live> that resolves out of the live tree entirely.
            for hit in re.findall(re.escape(live) + r"[^\s\x27\"]*", text):
                hit = os.path.realpath(hit.rstrip("/"))
                if under(hit, live) and not is_env(hit):
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

# --- js helper programs ------------------------------------------------------
# Read by the `node` resolved at detection time, so detection and result
# parsing use the same interpreter the .bin shims resolve through `env node`.

# Print the runner name (vitest or jest) the package root signals, or nothing.
# argv[1] is the package root directory.
FM_JS_DETECT_SRC='
const fs = require("fs"), path = require("path");
const root = process.argv[1];
let pkg;
try {
  pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")) || {};
} catch (e) {
  process.exit(0);
}
const deps = Object.assign({}, pkg.dependencies, pkg.devDependencies);
let names = [];
try { names = fs.readdirSync(root); } catch (e) {}
const hasConfig = (base) => names.some((n) => n.startsWith(base + ".config."));
const vitestConfig = hasConfig("vitest");
const jestConfig = hasConfig("jest") || "jest" in pkg;
const vitest = "vitest" in deps || vitestConfig;
const jest = "jest" in deps || jestConfig;
if (vitest && jest) {
  // A config file breaks the tie; vitest is preferred when the tie stands.
  console.log(jestConfig && !vitestConfig ? "jest" : "vitest");
} else if (vitest) {
  console.log("vitest");
} else if (jest) {
  console.log("jest");
}
'

# Print each passing (mode "passing") or explicitly skipped (mode "skipped")
# test name from the jest-shaped JSON report both runners emit. argv[1] is the
# report path, argv[2] the mode, argv[3] the repo-relative test file the run was
# for (testcases from any other file a substring filter matched are dropped).
# Names are ancestorTitles + title joined with " > "; see the vitest/jest
# header section for why that rendering and these statuses.
FM_JS_RESULTS_SRC='
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
} catch (e) {
  process.exit(0);
}
const mode = process.argv[2];
const target = process.argv[3] || "";
const skipStatuses = new Set(["skipped", "pending", "todo", "disabled"]);
for (const file of (data && data.testResults) || []) {
  if (target) {
    const name = String(file.name || "");
    if (name !== target && !name.endsWith("/" + target)) continue;
  }
  for (const a of file.assertionResults || []) {
    const wanted = mode === "passing" ? a.status === "passed" : skipStatuses.has(a.status);
    if (!wanted) continue;
    const parts = (a.ancestorTitles || []).concat([a.title]).filter(
      (p) => typeof p === "string" && p.length > 0
    );
    if (parts.length) console.log(parts.join(" > "));
  }
}
'

# --- vitest / jest detection -------------------------------------------------

# fm_js_pkg_dir <worktree> <file>: print the worktree-relative directory holding
# the nearest package.json at or above <file> (empty string for the worktree
# root), or return 1 when none exists.
fm_js_pkg_dir() {
  local wt=$1 dir=${2%/*}
  [ "$dir" != "$2" ] || dir=
  while :; do
    if [ -f "$wt${dir:+/$dir}/package.json" ]; then
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

# fm_js_runner_name <worktree> <node>: print the runner (vitest or jest) the
# worktree root's package.json signals, or nothing. The answer depends only on
# <worktree>, so it is memoized; an empty memoized value records "no signal".
fm_js_runner_name() {
  local wt=$1 node=$2 out
  if out=$(fm_cache_get jsrunner "$wt"); then
    printf '%s' "$out"
    return 0
  fi
  out=$("$node" -e "$FM_JS_DETECT_SRC" "$wt" 2>/dev/null) || out=
  fm_cache_put jsrunner "$wt" "$out"
  printf '%s' "$out"
}

# fm_js_runner_spec <worktree> <file>: print the vitest/jest runner spec for
# <file>, or nothing when the file is unsupported (nested package root, no
# node, no runner signal, or no provisioned binary). Always returns 0.
fm_js_runner_spec() {
  local wt=$1 f=$2 pkgdir node runner
  pkgdir=$(fm_js_pkg_dir "$wt" "$f") || return 0
  # v1 executes only a single-package layout rooted at the repo root; a nested
  # nearest package.json (workspace/monorepo member) is unsupported, so the
  # file is reported unexecuted rather than run under the wrong root.
  [ -z "$pkgdir" ] || return 0
  node=$(command -v node 2>/dev/null) || return 0
  runner=$(fm_js_runner_name "$wt" "$node")
  [ -n "$runner" ] || return 0
  [ -x "$wt/node_modules/.bin/$runner" ] || return 0
  printf '%s\t%s\n' "$runner" "$node"
}

# fm_js_untrusted_reason <worktree>: why a JS run in a scratch tree could not be
# trusted, or nothing. A top-level (or scoped) node_modules entry that is a
# symlink resolving INSIDE the live worktree but outside node_modules itself is
# linked first-party live source - a workspace or file:/npm-link package - and
# a bare specifier import would load the live tree instead of scratch. The
# answer depends only on <worktree>, so it is memoized.
fm_js_untrusted_reason() {
  local wt=$1 nmreal wtreal entry real name reason
  if reason=$(fm_cache_get jstrust "$wt"); then
    printf '%s' "$reason"
    return 0
  fi
  reason=
  nmreal=$(readlink -f "$wt/node_modules" 2>/dev/null) || nmreal=
  wtreal=$(readlink -f "$wt" 2>/dev/null) || wtreal=$wt
  if [ -n "$nmreal" ]; then
    for entry in "$wt/node_modules"/* "$wt/node_modules"/@*/*; do
      [ -L "$entry" ] || continue
      real=$(readlink -f "$entry" 2>/dev/null) || continue
      case "$real" in
        "$nmreal" | "$nmreal"/*) continue ;;
      esac
      case "$real" in
        "$wtreal"/*)
          name=${entry#"$wt/node_modules/"}
          reason="linked package $name resolves to $real, first-party code in the live worktree"
          break
          ;;
      esac
    done
  fi
  fm_cache_put jstrust "$wt" "$reason"
  printf '%s' "$reason"
}

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
# every result parse goes through one interpreter. The answer depends only on
# <worktree>, so it is memoized: an empty memoized value records "none resolves".
# The probe imports pytest with the LIVE worktree's interpreter, so like every
# other Python this library starts it runs with PYTHONDONTWRITEBYTECODE=1: a cold
# __pycache__ would otherwise have the probe write .pyc files into the live
# worktree's provisioned env, which this gate promises never to mutate.
fm_py_interpreter() {
  local wt=$1 candidate shebang resolved=
  if resolved=$(fm_cache_get interpreter "$wt"); then
    [ -n "$resolved" ] || return 1
    printf '%s' "$resolved"
    return 0
  fi
  resolved=
  for candidate in "$wt/.venv/bin/python" "$wt/venv/bin/python"; do
    if [ -x "$candidate" ] \
      && PYTHONDONTWRITEBYTECODE=1 "$candidate" -m pytest --version >/dev/null 2>&1; then
      resolved=$candidate
      break
    fi
  done
  if [ -z "$resolved" ]; then
    candidate="$wt/.venv/bin/pytest"
    if [ -x "$candidate" ]; then
      IFS= read -r shebang < "$candidate" || shebang=
      shebang=${shebang#\#!}
      shebang=${shebang%% *}
      if [ -n "$shebang" ] && [ -x "$shebang" ] \
        && PYTHONDONTWRITEBYTECODE=1 "$shebang" -m pytest --version >/dev/null 2>&1; then
        resolved=$shebang
      fi
    fi
  fi
  fm_cache_put interpreter "$wt" "$resolved"
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
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
    *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.test.mjs|*.test.cjs|\
    *.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|*.spec.mjs|*.spec.cjs)
      fm_js_runner_spec "$wt" "$f"
      return 0
      ;;
  esac
  return 0
}

# fm_py_pythonpath <scratch> <config-dir> <file>: the colon-joined scratch source
# roots a pytest run puts ahead of site-packages. The ambient PYTHONPATH is
# deliberately NOT inherited: it can point at the live worktree. <file> is the
# repo-relative test file, whose own directory is appended (resolved INSIDE
# <scratch>) so the sibling-helper imports prepend mode would have resolved still
# work under --import-mode=importlib; it goes last so the source roots keep
# precedence for first-party packages.
fm_py_pythonpath() {
  local scratch=$1 configdir=$2 f=${3:-} candidate filedir out=
  local roots=("$scratch" "$scratch/src")
  if [ -n "$configdir" ]; then
    roots+=("$scratch/$configdir" "$scratch/$configdir/src")
  fi
  if [ -n "$f" ]; then
    filedir=${f%/*}
    [ "$filedir" != "$f" ] || filedir=
    roots+=("$scratch${filedir:+/$filedir}")
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
      pythonpath=$(fm_py_pythonpath "$scratch" "$configdir" "$f")
      (
        cd "$scratch" || exit 125
        PYTHONPATH="$pythonpath" PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS='' \
        FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_HOME='' \
          ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$python" -m pytest \
            -p no:cacheprovider -o addopts= --import-mode=importlib \
            --junit-xml="$results" "$@"
      ) > "$errout" 2>&1
      ;;
    vitest)
      # Like the shell runner, the whole file runs and the trailing identifiers
      # are ignored; accounting reconciles the result. --cache=false is the
      # write-back guard for the linked node_modules (see the header section).
      : > "$results"
      (
        cd "$scratch" || exit 125
        NODE_PATH='' NODE_OPTIONS='' \
        FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_HOME='' \
          ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} \
          "$scratch/node_modules/.bin/vitest" run --root "$scratch" \
            --cache=false --reporter=json --outputFile="$results" "$f"
      ) > "$errout" 2>&1
      ;;
    jest)
      : > "$results"
      (
        cd "$scratch" || exit 125
        NODE_PATH='' NODE_OPTIONS='' \
        FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_HOME='' \
          ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} \
          "$scratch/node_modules/.bin/jest" --rootDir "$scratch" \
            --reporters=default --json --outputFile="$results" \
            --runTestsByPath "$f"
      ) > "$errout" 2>&1
      ;;
    *)
      return 125
      ;;
  esac
}

# passing_idents <spec> <results-out> [<file>]: the sorted unique passing test
# names of one run, read from that runner's machine-readable output.
passing_idents() {
  local spec=$1 results=$2 f=${3:-} runner python
  IFS=$'\t' read -r runner python _ <<< "$spec"
  case "$runner" in
    shell)
      sed -n 's/^ok - //p' "$results" | sort -u
      ;;
    pytest)
      [ -s "$results" ] || return 0
      PYTHONDONTWRITEBYTECODE=1 "$python" -c "$FM_PY_JUNIT_SRC" "$results" 2>/dev/null | sort -u
      ;;
    vitest|jest)
      [ -s "$results" ] || return 0
      "$python" -e "$FM_JS_RESULTS_SRC" "$results" passing "$f" 2>/dev/null | sort -u
      ;;
  esac
}

# skipped_idents <spec> <results-out> [<file>]: the sorted unique test names one
# run recorded as an EXPLICIT skip. Everything the run was bounded to that
# appears in neither this set nor passing_idents produced no result at all.
skipped_idents() {
  local spec=$1 results=$2 f=${3:-} runner python
  IFS=$'\t' read -r runner python _ <<< "$spec"
  case "$runner" in
    shell)
      # The TAP-style protocol has no skip marker, and inventing one would change
      # it; a shell name that never emitted `ok - ` is unaccounted, not skipped.
      return 0
      ;;
    pytest)
      [ -s "$results" ] || return 0
      PYTHONDONTWRITEBYTECODE=1 "$python" -c "$FM_PY_JUNIT_SKIPPED_SRC" "$results" 2>/dev/null | sort -u
      ;;
    vitest|jest)
      [ -s "$results" ] || return 0
      "$python" -e "$FM_JS_RESULTS_SRC" "$results" skipped "$f" 2>/dev/null | sort -u
      ;;
  esac
}

# fm_reported_name_accounts <spec> <requested> <reported>: succeed when the
# runner-reported name <reported> accounts for check 1's requested bare name.
# Equality accounts everywhere. pytest additionally accounts a requested name
# followed IMMEDIATELY by a literal `[` (its parametrized cases; the bracket
# must be the very next character so `test_xy[a]` never accounts for a
# requested `test_x`), and the shell runner keeps that same rule its accounting
# has always used. The JS runners report composed `a > b > c` titles while
# check 1 requests each segment separately, so a requested name is accounted by
# any whole " > "-separated segment - never by bare substring, so a near-name
# pair cannot cross-match.
fm_reported_name_accounts() {
  local spec=$1 name=$2 reported=$3 runner seg rest
  IFS=$'\t' read -r runner _ <<< "$spec"
  [ "$reported" != "$name" ] || return 0
  case "$runner" in
    shell|pytest)
      case "$reported" in "${name}["*) return 0 ;; esac
      ;;
    vitest|jest)
      rest=$reported
      while :; do
        seg=${rest%% > *}
        [ "$seg" != "$name" ] || return 0
        [ "$seg" != "$rest" ] || break
        rest=${rest#* > }
      done
      ;;
  esac
  return 1
}

# --- scratch-tree lifecycle --------------------------------------------------

# prepare_scratch_env <spec> <scratch-dir> <worktree>: link the worktree's
# already-provisioned dependency dirs into the scratch tree. Idempotent, and it
# never writes into <worktree>.
prepare_scratch_env() {
  local spec=$1 scratch=$2 wt=$3 runner name
  IFS=$'\t' read -r runner _ <<< "$spec"
  case "$runner" in
    pytest|vitest|jest) ;;
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

# scratch_untrusted_reason <spec> <scratch-dir> <worktree> <file>: why a run in
# the scratch tree could not be trusted to exercise the scratch tree's own code,
# or nothing when it can. The probe uses the IDENTICAL PYTHONPATH
# run_base_test_file will use for <file>, so it resolves imports the way the run
# does; its verdict comes from stdout ALONE, never from startup noise on stderr.
# See "Trusting the scratch tree" in this file's header. The answer depends only
# on (spec, scratch tree, worktree, the file's directory), so it is memoized.
scratch_untrusted_reason() {
  local spec=$1 scratch=$2 wt=$3 f=${4:-} runner python configdir
  local pythonpath out err reason key rc=0
  IFS=$'\t' read -r runner python configdir <<< "$spec"
  case "$runner" in
    pytest) ;;
    vitest|jest)
      fm_js_untrusted_reason "$wt"
      return 0
      ;;
    *) return 0 ;;
  esac
  pythonpath=$(fm_py_pythonpath "$scratch" "$configdir" "$f")
  key="$spec"$'\n'"$scratch"$'\n'"$wt"$'\n'"$pythonpath"
  if reason=$(fm_cache_get trust "$key"); then
    printf '%s' "$reason"
    return 0
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/fm-trust-probe.XXXXXX")
  out=$(
    cd "$scratch" || exit 1
    PYTHONPATH="$pythonpath" PYTHONDONTWRITEBYTECODE=1 \
      "$python" -c "$FM_PY_TRUST_SRC" "$wt" "$scratch" 2>"$err"
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    # The probe itself broke: fail safe, and carry its stderr as the evidence a
    # human needs, which is the ONLY thing that stream is ever read for.
    reason="import resolution could not be verified (exit $rc)"
    if [ -s "$err" ]; then
      reason="$reason: $(tr '\n' ';' < "$err" | cut -c 1-500)"
    fi
  elif [ -n "$out" ]; then
    reason="the branch worktree shadows the scratch tree: $(printf '%s' "$out" | tr '\n' ';')"
  else
    reason=
  fi
  rm -f "$err"
  fm_cache_put trust "$key" "$reason"
  printf '%s' "$reason"
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
