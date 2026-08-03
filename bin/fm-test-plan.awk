# fm-test-plan.awk - reference-closure selection + cost-packed shard planner for
# bin/fm-test.sh's LOCAL mode. CI never runs this file; CI stays exhaustive.
#
# WHAT A TEST DEPENDS ON
# ----------------------
# A behaviour test's outcome depends on its own bytes plus the bytes of every
# repo file it reads or executes. Those files are almost never named by the
# test's own filename - tests/fm-teardown.test.sh runs bin/fm-teardown.sh, which
# sources bin/fm-crew-state.sh, which sources further libraries. So selection
# must follow that REFERENCE relation, not filename similarity: an untouched
# test file that exercises an edited script has to be selected, and a touched
# test file that exercises nothing edited still has to be selected because its
# own bytes changed.
#
# This planner therefore builds a directed reference graph over the tracked
# repo, closes it transitively from each test file, and selects the tests whose
# closure intersects the change set.
#
# WHAT IS AND IS NOT A DEPENDENCY TARGET
# --------------------------------------
# An edge from X to Y means "a change to Y can change what X does". Two whole
# classes of file fall out of that definition, and leaving either in makes the
# graph collapse into "everything depends on everything", which is a whole-set
# run wearing a planner's clothes:
#   - PROSE HAS NO OUTGOING EDGES. AGENTS.md names nearly every script in the
#     repo, but editing a script does not change AGENTS.md, so a *.md file is a
#     leaf: still a perfectly good edge TARGET for the tests that read it, never
#     a source. Without this, every test reaching any script that merely cites a
#     doc in its header inherits that doc's mention of the entire repo.
#   - A *.test.sh FILE IS NEVER ANOTHER FILE'S DEPENDENCY. Test files are
#     independent executables; none sources another. tests/lib.sh citing
#     "tests/" in a comment must not make every test depend on every other test.
#     A changed test file still runs, because selection takes the change set
#     itself, not just closures.
# Measured on this repo before those two rules: every test closed over 249 of
# the 253 tracked files. After them the mean closure is a small fraction of the
# repo and selection actually selects.
#
# HOW AN EDGE IS FOUND
# --------------------
# Every tracked, non-prose TEXT file is tokenised into maximal [A-Za-z0-9_.+/-] runs. A
# token resolves to an edge when its basename matches a tracked file's basename:
#   - if some candidate is a path-suffix of the token at a "/" boundary, the
#     edge goes to those candidates only ("$ROOT/bin/fm-spawn.sh" tokenises to
#     "ROOT/bin/fm-spawn.sh", whose suffix "bin/fm-spawn.sh" is tracked);
#   - otherwise the edge goes to EVERY tracked file with that basename, because
#     the token was spelled in a form this planner cannot pin down
#     ("$(dirname ...)/lib.sh" tokenises to "/lib.sh").
# A GLOB resolves to the directory it enumerates, because the source spells the
# whole match out: "bin/*.sh" in bin/fm-lint.sh draws edges to every tracked
# file under bin/, which is exactly right for a tool that lints all of them.
# Tracked symlinks draw an edge to their resolved target, so a test naming
# CLAUDE.md depends on AGENTS.md.
#
# WHAT THIS PLANNER DOES NOT MODEL
# --------------------------------
# Comments, and dynamic dispatch through a computed name. Both are deliberate,
# both are measured, and the reason is the same: modelling them collapses the
# graph to "everything depends on everything", which selects the whole suite
# and buys nothing. Comment text made all 88 scripts in bin/ mutual
# dependencies; widening "$ROOT/bin/$f" to all of bin/ put 79 of the 87 tests
# on every core file. The known unmodelled dispatch sites in this repo are
# bin/backends/cmux.sh, bin/fm-continuity-command-policy.mjs,
# .pi/extensions/fm-primary-turnend-guard.ts and tests/fm-backend.test.sh.
# An approximation here costs a slower fix loop, never a wrong merge: CI runs
# every file on every push and remains the authority.
#
# Over-inclusion is always safe here: it can only run MORE tests than needed. A
# missed edge is not safe, which is why every ambiguous spelling widens rather
# than narrows, and why the driver escalates to the whole set whenever the
# change set contains a file no closure claims (see MODE=select below).
#
# THE UNATTRIBUTABLE-CHANGE ESCALATION
# ------------------------------------
# The graph is a static approximation, so it cannot prove it saw every way a
# test reaches a file. What it CAN prove is that a changed file is reachable
# from no test at all, which is the case a static approximation gets wrong most
# often (a brand-new script, a renamed path, a file reached only through a
# computed name). MODE=select exits 10 on any such file and bin/fm-test.sh then
# runs the canonical whole set. Selection narrows only when every changed file
# is one this planner positively accounted for.
#
# Prose is the one exception, and it rests on the same asymmetry that makes
# prose a leaf: a doc affects a test only by being READ, and a test that reads a
# doc names it, so for a *.md or *.txt file "no test reaches it" is a positive
# finding rather than an absence of evidence. Such a file selects nothing and
# says so by name instead of escalating.
#
# Reading:
#   TRACKED  newline-delimited repo-relative paths of every tracked file: the
#            universe an edge may point at.
#   SCAN     newline-delimited subset of TRACKED to read for tokens (text files;
#            binaries have no outgoing edges).
#   LINKS    "<path><TAB><readlink target>" for each tracked symlink. Optional.
#   FILES    newline-delimited canonical test set (bin/fm-test.sh's tests/*.test.sh).
#   CHANGED  newline-delimited changed paths. Optional for MODE=closures.
#   COSTS    "<path><TAB><seconds>" measured durations for shard packing. Optional.
#   JOBS     shard count for MODE=shards.
#   MODE     "closures" - emit "<test> <closure...>" per test and exit.
#            "select"   - emit the selected test files, one per line.
#            "shards"   - select, then emit "<index><TAB><space-separated files>".
#
# Exit status: 0 on success, 10 when the caller must fall back to the whole set
# (the reason is on stderr), 3 on a malformed input the planner will not guess
# around.

function trim(s) {
  sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s
}

function bail(msg) {
  printf "fm-test-plan.awk: %s\n", msg > "/dev/stderr"
  exit 3
}

# Collapse "a/./b", "a/b/../c" and repeated slashes so a symlink target joined
# to its own directory lands on the path git actually tracks.
function normpath(p,   parts, n, i, out, m, j) {
  gsub(/\/+/, "/", p)
  n = split(p, parts, "/")
  m = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == ".." && m > 0 && out[m] != "..") { m--; continue }
    out[++m] = parts[i]
  }
  p = ""
  for (j = 1; j <= m; j++) p = (p == "" ? out[j] : p "/" out[j])
  return p
}

function addedge(from, to,   key) {
  if (to == "" || to == from || !(to in tracked)) return
  # A test file is an independent executable, never another file's dependency.
  if (to in testfile) return
  key = from SUBSEP to
  if (key in edge) return
  edge[key] = 1
  deps[from] = deps[from] " " to
}

# Draw edges to every tracked file under directory d. Returns 1 when d was a
# tracked directory, so the caller can stop widening the token.
function adddir(from, d,   c, i, parts) {
  if (d == "" || !(d in isdir)) return 0
  c = split(dirfiles[d], parts, " ")
  for (i = 1; i <= c; i++) addedge(from, parts[i])
  return 1
}

# Find the directory a computed token was being built in. Trailing segments are
# dropped one at a time (so "bin/%.sh" reaches "bin"), and each truncation is
# also tried with its leading segments stripped (so "%ROOT/bin/%f" reaches
# "bin"), because the token usually carries a prefix that is not a repo path.
function trydirs(from, t,   u) {
  sub(/\/+$/, "", t)
  while (t != "") {
    u = t
    while (u != "") {
      if (adddir(from, u)) return 1
      if (!sub(/^[^\/]*\//, "", u)) break
    }
    if (!sub(/\/[^\/]*$/, "", t)) break
  }
  return 0
}

function resolve(from, tok,   b, c, i, arr, hit, L, T, last) {
  sub(/^(\.\/)+/, "", tok)
  if (tok == "") return
  # Directory widening fires only on a GLOB in the FINAL segment. "%" marks a
  # * or ?, which is a complete enumeration the source spells out in full, so
  # "bin/%.sh" (from "bin/*.sh") really does depend on every file it matches.
  # "~" marks a $ { }, a name the planner cannot resolve; widening THOSE to the
  # whole directory is a guess, and measured on this repo it is a ruinous one -
  # three variable dispatch sites (a backend adapter, a hook command policy, a
  # primary-harness extension) sit on paths nearly every test reaches, and
  # widening them put every one of the 88 files in bin/ into 79 of the 87
  # closures, which is a whole-set run with extra steps. Unresolvable dynamic
  # dispatch is therefore NOT modelled, and CI stays exhaustive precisely
  # because the local planner makes approximations like this one.
  last = tok
  sub(/^.*\//, "", last)
  # Trailing markers are the closing brace of "${...}", not part of the name:
  # "${X:-$ROOT/bin/fm-afk-start.sh}" ends up as "...fm-afk-start.sh~", and
  # leaving that on would defeat the basename match.
  sub(/[%~]+$/, "", tok)
  if (tok == "") return
  if (tok ~ /\/$/) return
  b = tok
  sub(/^.*\//, "", b)
  if (b == "" || !(b in bybase)) { if (index(last, "%") > 0) trydirs(from, tok); return }
  c = split(bybase[b], arr, " ")
  hit = 0
  T = length(tok)
  for (i = 1; i <= c; i++) {
    if (arr[i] == "") continue
    L = length(arr[i])
    if (tok == arr[i] || (T > L && substr(tok, T - L + 1) == arr[i] && substr(tok, T - L, 1) == "/")) {
      addedge(from, arr[i])
      hit = 1
    }
  }
  # The token named the basename in a spelling this planner cannot pin to one
  # path, so every file with that basename becomes a dependency.
  if (!hit) for (i = 1; i <= c; i++) addedge(from, arr[i])
}

BEGIN {
  if (TRACKED == "" || FILES == "") bail("TRACKED and FILES are required")

  # --- the universe an edge may point at, plus basename and directory indexes -
  while ((getline line < TRACKED) > 0) {
    line = trim(line)
    if (line == "") continue
    tracked[line] = 1
    ntracked++
    b = line
    sub(/^.*\//, "", b)
    bybase[b] = bybase[b] " " line
    d = line
    while (sub(/\/[^\/]*$/, "", d)) {
      isdir[d] = 1
      dirfiles[d] = dirfiles[d] " " line
    }
  }
  close(TRACKED)
  if (ntracked == 0) bail("TRACKED listed no files")

  # --- the canonical test set -------------------------------------------------
  nt = 0
  while ((getline line < FILES) > 0) {
    line = trim(line)
    if (line == "") continue
    testfile[line] = 1
    tests[++nt] = line
    # A test file may be brand new and therefore untracked; it is still a valid
    # edge target for its own closure.
    tracked[line] = 1
  }
  close(FILES)
  if (nt == 0) bail("FILES listed no test files")

  # --- symlink edges ----------------------------------------------------------
  if (LINKS != "") {
    while ((getline line < LINKS) > 0) {
      ti = index(line, "\t")
      if (ti == 0) continue
      lp = substr(line, 1, ti - 1)
      lt = trim(substr(line, ti + 1))
      if (lp == "" || lt == "") continue
      ldir = ""
      if (lp ~ /\//) { ldir = lp; sub(/\/[^\/]*$/, "/", ldir) }
      full = normpath(ldir lt)
      if (!adddir(lp, full)) addedge(lp, full)
    }
    close(LINKS)
  }

  # --- tokenise every scannable file into reference edges ---------------------
  if (SCAN != "") {
    while ((getline sf < SCAN) > 0) {
      sf = trim(sf)
      if (sf == "" || !(sf in tracked)) continue
      # Prose is a leaf: it can be depended ON, but a change elsewhere in the
      # repo never changes what it says, so it contributes no outgoing edges.
      if (sf ~ /\.(md|txt)$/) continue
      delete seentok
      while ((getline line < sf) > 0) {
        # A comment cannot create a runtime dependency, and these scripts cite
        # each other heavily in their headers. Scanning comment text made every
        # bin script a dependency of every other one, which put all 87 tests on
        # every core file; stripping them first is what makes selection select.
        if (sf ~ /\.(ts|js|mjs)$/) sub(/\/\/.*$/, "", line)
        else { sub(/^[ \t]*#.*$/, "", line); sub(/[ \t]#[ \t].*$/, "", line) }
        # "%" marks a glob, "~" a shell expansion; any literal one is cleared
        # out of the way first so the markers stay unambiguous.
        gsub(/[%~]/, " ", line)
        gsub(/[*?]/, "%", line)
        gsub(/[$\{\}]/, "~", line)
        gsub(/[^A-Za-z0-9_.+%~\/-]/, " ", line)
        n = split(line, toks, " ")
        for (i = 1; i <= n; i++) {
          tk = toks[i]
          if (tk == "" || tk in seentok) continue
          seentok[tk] = 1
          if (index(tk, ".") == 0 && index(tk, "/") == 0) continue
          resolve(sf, tk)
        }
      }
      close(sf)
    }
    close(SCAN)
  }

  # --- transitive closure per test file ---------------------------------------
  for (i = 1; i <= nt; i++) {
    f = tests[i]
    delete seen
    stackn = 0
    cnt = split(deps[f], d1, " ")
    for (j = 1; j <= cnt; j++) if (d1[j] != "") stack[++stackn] = d1[j]
    while (stackn > 0) {
      cur = stack[stackn--]
      if (cur in seen || cur == f) continue
      seen[cur] = 1
      cnt2 = split(deps[cur], d2, " ")
      for (j = 1; j <= cnt2; j++) if (d2[j] != "") stack[++stackn] = d2[j]
    }
    cl = ""
    for (k in seen) {
      cl = cl " " k
      claimed[k] = 1
    }
    closure[f] = cl
    claimed[f] = 1
  }

  if (MODE == "closures") {
    for (i = 1; i <= nt; i++) printf "%s%s\n", tests[i], closure[tests[i]]
    exit 0
  }

  # --- selection --------------------------------------------------------------
  if (CHANGED == "") bail("CHANGED is required for MODE=" MODE)
  while ((getline line < CHANGED) > 0) {
    line = trim(line)
    if (line == "") continue
    if (line in changed) continue
    changed[line] = 1
    if (!(line in claimed)) {
      # "No test reaches this file" means different things for prose and for
      # code, and the difference is the same asymmetry that makes prose a leaf.
      # A doc can only affect a test by being READ, and a test that reads a doc
      # names it - this planner scans every test file, so an unreferenced doc is
      # a positive finding that no test can be affected by it. A script can also
      # be reached by EXECUTION through a computed name, which is explicitly not
      # modelled here, so an unreferenced script is merely an absence of
      # evidence and must escalate.
      # Without the distinction the gate was unusable in practice: 21 of this
      # repo's 23 unreached files are documentation, and docs are shared tracked
      # material that most changes touch, so an ordinary code-plus-docs commit
      # escalated to a 17-minute whole-set run.
      if (line ~ /\.(md|txt)$/) { proseonly[line] = 1; continue }
      printf "fm-test-plan.awk: no test reaches %s; the whole set is the only sound answer.\n", \
        line > "/dev/stderr"
      exit 10
    }
  }
  close(CHANGED)

  for (pf in proseonly)
    printf "fm-test-plan.awk: no test reads %s, so no test can be affected by it.\n", \
      pf > "/dev/stderr"

  nsel = 0
  for (i = 1; i <= nt; i++) {
    f = tests[i]
    hitsel = 0
    if (f in changed) hitsel = 1
    if (!hitsel) {
      cnt = split(closure[f], cm, " ")
      for (j = 1; j <= cnt; j++) if (cm[j] != "" && (cm[j] in changed)) { hitsel = 1; break }
    }
    if (hitsel) sel[++nsel] = f
  }

  if (MODE == "select") {
    for (i = 1; i <= nsel; i++) print sel[i]
    exit 0
  }
  if (MODE != "shards") bail("unknown MODE " MODE)

  # --- cost-packed shards -----------------------------------------------------
  # Round-robin over sorted names, which is all CI's fixed partition can do
  # without measurements, leaves the heaviest shard several times the lightest.
  # Locally there ARE measurements, so pack longest-processing-time first: sort
  # by measured seconds descending and hand each file to the lightest shard.
  # An unmeasured file gets the mean of the measured ones so a first run cannot
  # treat it as free.
  known = 0
  ksum = 0
  if (COSTS != "") {
    while ((getline line < COSTS) > 0) {
      ti = index(line, "\t")
      if (ti == 0) continue
      cp = substr(line, 1, ti - 1)
      cv = trim(substr(line, ti + 1)) + 0
      if (cp == "" || cv < 0) continue
      cost[cp] = cv
      known++
      ksum += cv
    }
    close(COSTS)
  }
  fallback = (known > 0 ? ksum / known : 1)
  for (i = 1; i <= nsel; i++) if (!(sel[i] in cost)) cost[sel[i]] = fallback

  if (JOBS + 0 < 1) JOBS = 1
  if (JOBS > nsel) JOBS = nsel
  for (i = 1; i < nsel; i++)
    for (j = 1; j <= nsel - i; j++)
      if (cost[sel[j]] < cost[sel[j + 1]]) { t = sel[j]; sel[j] = sel[j + 1]; sel[j + 1] = t }

  for (s = 1; s <= JOBS; s++) load[s] = 0
  for (i = 1; i <= nsel; i++) {
    best = 1
    for (s = 2; s <= JOBS; s++) if (load[s] < load[best]) best = s
    load[best] += cost[sel[i]]
    packed[best] = packed[best] " " sel[i]
  }

  for (s = 1; s <= JOBS; s++) {
    if (trim(packed[s]) == "") continue
    printf "%d\t%s\n", s, trim(packed[s])
  }
  exit 0
}
