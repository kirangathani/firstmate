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
# SILENTLY, and a silently-wrong lint gate is far worse than a slow one. This
# planner therefore does NOT parse source statements out of shell code itself:
# successive review rounds proved that chasing shell grammar in awk keeps
# leaking (line starts, separators, `then`/subshell positions, `function`
# bodies, redirection prefixes). Instead, bin/fm-lint.sh runs a discovery pass
# that asks ShellCheck itself: each file is checked ALONE, and every SC1091
# "was not specified as input" note names exactly one followable literal
# source target, in every syntactic position, with no parsing on our side.
# Those discovered edges arrive here via EDGES. This file still reads each
# script, but only its `# shellcheck` directive lines: a `source=<path>` key
# is an edge (it can name the target of a variable-path statement, which
# discovery also surfaces but the directive states outright), and any
# directive key or disable= item that could change resolution in a way the
# discovery pass cannot see makes this planner exit non-zero so bin/fm-lint.sh
# falls back to the whole-set reference implementation instead of guessing.
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
#   EDGES  - pre-discovered source edges, one per line: "<from><TAB><target>",
#            the target exactly as ShellCheck named it in the SC1091 note.
#            Unset or empty means "no discovered edges".
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

function tripwire(f, ln, line, what) {
  printf "%s at %s:%d: %s\n", what, f, ln, trim(line) > "/dev/stderr"
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

  # --- read the discovered source edges --------------------------------------
  # bin/fm-lint.sh ran every canonical file through ShellCheck alone and
  # harvested the target named by each SC1091 "was not specified as input"
  # note. A target counts as an edge when it names a canonical input, tried
  # both as ShellCheck spelled it and script-dir-relative; over-inclusion is
  # safe under the parity invariant, a missed edge is not.
  if (EDGES != "") {
    while ((getline line < EDGES) > 0) {
      ti = index(line, "\t")
      if (ti == 0) continue
      from = substr(line, 1, ti - 1)
      tgt = trim(substr(line, ti + 1))
      if (!(from in inset) || tgt == "") continue
      sub(/^(\.\/)+/, "", tgt)
      fdir = ""
      if (from ~ /\//) { fdir = from; sub(/\/[^\/]*$/, "/", fdir) }
      addedge(from, tgt)
      addedge(from, fdir tgt)
    }
    close(EDGES)
  }

  # --- scan each file for directive edges and count its lines ----------------
  # Only `# shellcheck` directive lines are inspected; statement edges come
  # pre-discovered via EDGES. A `source=` key is an edge. Directive keys this
  # planner does not model (e.g. source-path=, which changes how a later
  # source statement resolves) are tripwires, so no unmodelled resolution
  # mechanism can be silently guessed around; keys that cannot affect
  # resolution (disable=, shell=, enable=, external-sources=) pass. One
  # nuance makes disable= safe to pass: an in-file disable of SC1091 would
  # blind the discovery pass, so bin/fm-lint.sh neutralizes SC1091 inside
  # directive lines before each discovery run and the note still surfaces.
  # That neutralization only recognises plain SCnnnn items, so a disable=
  # item in any other spelling ("all", SCnnnn-SCnnnn ranges, or anything
  # unrecognised) could still suppress SC1091 unseen - those tripwire here.
  for (i = 1; i <= n; i++) {
    f = files[i]
    lc = 0
    while ((getline line < f) > 0) {
      lc++
      if (line !~ /^[ \t]*#[ \t]*shellcheck[ \t]/) continue
      rest = line
      sub(/^[ \t]*#[ \t]*shellcheck[ \t]+/, "", rest)
      nt = split(rest, toks, /[ \t]+/)
      for (t = 1; t <= nt; t++) {
        if (toks[t] ~ /^#/) break
        if (toks[t] !~ /=/) continue
        dkey = toks[t]
        sub(/=.*$/, "", dkey)
        if (dkey == "source") {
          tail = toks[t]
          sub(/^source=/, "", tail)
          addedge(f, tail)
        } else if (dkey == "disable") {
          tail = toks[t]
          sub(/^disable=/, "", tail)
          nv = split(tail, items, ",")
          for (v = 1; v <= nv; v++)
            if (items[v] !~ /^SC[0-9]+$/)
              tripwire(f, lc, line, "unclassifiable disable= item")
        } else if (dkey != "shell" && dkey != "enable" && dkey != "external-sources")
          tripwire(f, lc, line, "unmodelled shellcheck directive")
      }
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
