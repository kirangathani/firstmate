# fm-lint-plan.awk - closure + shard planner for bin/fm-lint.sh.
#
# ShellCheck (without -x) follows a sourced file ONLY when the target is also
# given as an input file on the same command line, and it resolves that target
# two ways: from a `# shellcheck source=<path>` directive, or from a plain
# `source <path>` / `. <path>` statement whose target is a variable-free
# literal path. That following is the entire reason the canonical whole-set run
# is slow: every importer gets its sourced files inlined and re-analysed, and
# ShellCheck's analysis is superlinear in the size of the script it ends up
# analysing.
#
# The parity invariant this planner rests on is that a file's findings depend
# only on its own bytes plus the transitively sourced files present as input.
# Any resolution mechanism the planner fails to model breaks that invariant
# SILENTLY, and a silently-wrong lint gate is far worse than a slow one. Hence
# the scan below models both mechanisms, and for any source statement it cannot
# confidently classify it exits non-zero so bin/fm-lint.sh falls back to the
# whole-set reference implementation instead of guessing.
#
# The findings ShellCheck reports for a file therefore depend on exactly two
# things: the file's own contents, and the contents of the files it transitively
# sources that are present in the input list. Nothing else on the command line
# can change them. So for any input list S that is CLOSED under the transitive
# source relation, every file in S yields precisely the findings it yields in
# the whole-set run.
#
# This planner emits such closed shards. Reading:
#   FILES  - newline-delimited canonical file list (repo-relative, cwd = repo root)
#   WORK   - newline-delimited subset that still needs linting (cache misses).
#            Empty or unset means "all of FILES".
#   JOBS   - how many shards to emit
#   MODE   - "closures" emits one record per file, "<file> <closure...>", and
#            skips sharding entirely. Anything else shards as described below.
#            Do not emulate this by passing a huge JOBS: the packer scans every
#            shard slot per file, so JOBS=999999 spent 13s doing nothing.
# Emitting one record per shard on stdout:
#   <shard-index><TAB><space-separated owned files><TAB><space-separated full shard>
# "owned" is the balanced partition of the work set; "full shard" is that
# partition plus its transitive source closure, which is what ShellCheck runs on.

function trim(s) {
  sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s
}

# Record a source edge from -> to. Only targets that are themselves canonical
# inputs are followed by ShellCheck; anything else stays unresolved in both
# modes alike, so it contributes no edge.
function addedge(from, to,   key) {
  if (to == "" || to == from || !(to in inset)) return
  key = from SUBSEP to
  if (!(key in edge)) { edge[key] = 1; deps[from] = deps[from] " " to }
}

function tripwire(f, ln, line) {
  printf "unclassifiable source statement at %s:%d: %s\n", f, ln, trim(line) > "/dev/stderr"
  exit 3
}

# Cost model for bin packing. ShellCheck's runtime grows faster than the line
# count (measured on this repo: 76 lines = 0.016s, 2287 lines = 2.56s), so
# packing by raw line count badly underweights the big files that actually
# dominate a shard's wall time. The exponent only has to rank shards sensibly.
function cost(lines) { return (lines / 100.0) ^ 1.6 }

BEGIN {
  if (JOBS < 1) JOBS = 1

  # --- read the canonical file list -----------------------------------------
  n = 0
  while ((getline line < FILES) > 0) {
    line = trim(line)
    if (line == "") continue
    files[++n] = line
    inset[line] = 1
  }
  close(FILES)
  if (n == 0) exit 0

  # --- read the work set (cache misses) --------------------------------------
  # An unset WORK means "own everything". An explicitly supplied but empty WORK
  # means every file was a cache hit, so the planner must emit no shards at all;
  # those two cases must not collapse into each other.
  if (WORK == "") {
    for (i = 1; i <= n; i++) work[files[i]] = 1
  } else {
    while ((getline line < WORK) > 0) {
      line = trim(line)
      if (line == "" || !(line in inset)) continue
      work[line] = 1
    }
    close(WORK)
  }

  # --- scan each file for source edges and count its lines ------------------
  # Every source/`.` statement must land in one of three buckets: (1) covered
  # by a `# shellcheck source=` directive, which then owns resolution; (2) a
  # target containing a shell expansion ($var, ${...}, $(...), backticks),
  # which ShellCheck cannot resolve either, so both modes agree there is no
  # edge; (3) a variable-free literal path, an edge exactly when it names a
  # canonical input (tried both repo-root-relative and script-dir-relative;
  # over-inclusion is safe under the parity invariant, a missed edge is not).
  # Anything else hits the tripwire above. Detection is statement-initial
  # only: a mid-line `source` reaching ShellCheck as a real statement is not
  # a shape this repo uses, and scanning inside strings/heredocs would drown
  # the tripwire in false alarms.
  for (i = 1; i <= n; i++) {
    f = files[i]
    fdir = ""
    if (f ~ /\//) { fdir = f; sub(/\/[^\/]*$/, "/", fdir) }
    lc = 0
    covered = 0
    while ((getline line < f) > 0) {
      lc++
      # Match `# shellcheck ... source=<path>`; the directive may carry other
      # keys (disable=..., shell=...) before or after the source= key. It
      # governs the next command, whose own target must then not be re-read.
      if (line ~ /^[ \t]*#[ \t]*shellcheck[ \t]/ && line ~ /source=/) {
        tail = line
        sub(/^.*source=/, "", tail)
        sub(/[ \t].*$/, "", tail)
        addedge(f, tail)
        covered = 1
        continue
      }
      if (line ~ /^[ \t]*(#|$)/) continue
      stmt = line
      sub(/^[ \t]+/, "", stmt)
      if (stmt ~ /^(source|\.)[ \t]/) {
        if (covered) { covered = 0; continue }
        covered = 0
        sub(/^(source|\.)[ \t]+/, "", stmt)
        tgt = stmt
        sub(/[ \t].*$/, "", tgt)
        if (tgt == "" || tgt ~ /[$`]/) continue
        if (tgt ~ /\\/) tripwire(f, lc, line)
        if (tgt ~ /^"[^"]*"$/ || tgt ~ /^'[^']*'$/)
          tgt = substr(tgt, 2, length(tgt) - 2)
        else if (tgt ~ /["']/) tripwire(f, lc, line)
        if (tgt ~ /[];&|<>(){}*?~[]/) tripwire(f, lc, line)
        sub(/^(\.\/)+/, "", tgt)
        addedge(f, tgt)
        addedge(f, fdir tgt)
        continue
      }
      covered = 0
    }
    close(f)
    lines[f] = lc
  }

  # --- transitive closure per file ------------------------------------------
  for (i = 1; i <= n; i++) {
    f = files[i]
    delete seen
    stackn = 0
    cnt = split(deps[f], d, " ")
    for (j = 1; j <= cnt; j++) if (d[j] != "") stack[++stackn] = d[j]
    while (stackn > 0) {
      cur = stack[stackn--]
      if (cur in seen || cur == f) continue
      seen[cur] = 1
      cnt2 = split(deps[cur], d2, " ")
      for (j = 1; j <= cnt2; j++) if (d2[j] != "") stack[++stackn] = d2[j]
    }
    cl = ""; tot = lines[f]
    for (k in seen) { cl = cl " " k; tot += lines[k] }
    closure[f] = cl
    weight[f] = cost(tot)
  }

  if (MODE == "closures") {
    for (i = 1; i <= n; i++) printf "%s%s\n", files[i], closure[files[i]]
    exit 0
  }

  # --- balance the work set across JOBS shards (longest-processing-time) -----
  # Sort work files by descending weight, then repeatedly assign the next
  # heaviest to the currently lightest shard. Cheap and close to optimal for
  # this shape of workload.
  m = 0
  for (i = 1; i <= n; i++) { f = files[i]; if (f in work) ord[++m] = f }
  for (i = 1; i < m; i++)
    for (j = 1; j <= m - i; j++)
      if (weight[ord[j]] < weight[ord[j + 1]]) { t = ord[j]; ord[j] = ord[j + 1]; ord[j + 1] = t }

  for (s = 1; s <= JOBS; s++) load[s] = 0
  for (i = 1; i <= m; i++) {
    best = 1
    for (s = 2; s <= JOBS; s++) if (load[s] < load[best]) best = s
    load[best] += weight[ord[i]]
    owned[best] = owned[best] " " ord[i]
    members[best] = members[best] " " ord[i] closure[ord[i]]
  }

  # --- emit ------------------------------------------------------------------
  for (s = 1; s <= JOBS; s++) {
    if (trim(owned[s]) == "") continue
    # De-duplicate shard members: a shared library pulled in by several owned
    # files must be listed once.
    delete uniq
    full = ""
    cnt = split(members[s], mm, " ")
    for (j = 1; j <= cnt; j++) {
      if (mm[j] == "" || mm[j] in uniq) continue
      uniq[mm[j]] = 1
      full = full " " mm[j]
    }
    printf "%d\t%s\t%s\n", s, trim(owned[s]), trim(full)
  }
}
