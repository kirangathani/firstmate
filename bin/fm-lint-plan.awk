# fm-lint-plan.awk - closure + shard planner for bin/fm-lint.sh.
#
# ShellCheck (without -x) follows a `# shellcheck source=<path>` directive ONLY
# when the target is also given as an input file on the same command line. That
# is the entire reason the canonical whole-set run is slow: every importer gets
# its sourced files inlined and re-analysed, and ShellCheck's analysis is
# superlinear in the size of the script it ends up analysing.
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

  # --- scan each file for source directives and count its lines -------------
  for (i = 1; i <= n; i++) {
    f = files[i]
    lc = 0
    while ((getline line < f) > 0) {
      lc++
      # Match `# shellcheck ... source=<path>`; the directive may carry other
      # keys (disable=..., shell=...) before or after the source= key.
      if (line ~ /^[ \t]*#[ \t]*shellcheck[ \t]/ && line ~ /source=/) {
        tail = line
        sub(/^.*source=/, "", tail)
        sub(/[ \t].*$/, "", tail)
        # Only targets that are themselves canonical inputs are followed by
        # ShellCheck; anything else stays unresolved in both modes alike.
        if (tail in inset && tail != f) {
          key = f SUBSEP tail
          if (!(key in edge)) { edge[key] = 1; deps[f] = deps[f] " " tail }
        }
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
