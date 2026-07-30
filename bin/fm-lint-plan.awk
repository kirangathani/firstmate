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
# the scan below models both mechanisms, and for any source statement or
# shellcheck directive key it cannot confidently classify it exits non-zero so
# bin/fm-lint.sh falls back to the whole-set reference implementation instead
# of guessing.
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

function tripwire(f, ln, line, what) {
  if (what == "") what = "unclassifiable source statement"
  printf "%s at %s:%d: %s\n", what, f, ln, trim(line) > "/dev/stderr"
  exit 3
}

# Classify one detected source/`.` statement (stmt starts at the keyword) and
# record its edge, or tripwire if it fits no bucket. An unquoted target word
# ends at the first shell metacharacter, exactly as the shell would end it.
function srcedge(f, ln, line, stmt, fdir,   tgt) {
  sub(/^(source|\.)[ \t]+/, "", stmt)
  tgt = stmt
  sub(/[ \t].*$/, "", tgt)
  if (tgt == "" || tgt ~ /[$`]/) return
  if (tgt ~ /\\/) tripwire(f, ln, line)
  if (tgt ~ /^"[^"]*"$/ || tgt ~ /^'[^']*'$/)
    tgt = substr(tgt, 2, length(tgt) - 2)
  else if (tgt ~ /["']/) tripwire(f, ln, line)
  else sub(/[;&|<>()].*$/, "", tgt)
  if (tgt == "") return
  if (tgt ~ /[]{}*?~[]/) tripwire(f, ln, line)
  sub(/^(\.\/)+/, "", tgt)
  addedge(f, tgt)
  addedge(f, fdir tgt)
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
  # Anything else hits the tripwire above. ShellCheck follows a literal source
  # wherever it sits in command position, so the scan tracks command position
  # across the whole line: a statement is detected at the start of a line,
  # after `;`, `&`, `&&`, `|`, `||`, `(` or `)`, after the reserved words
  # if/elif/then/else/while/until/do/in and the `{`/`!` words, and past
  # assignment prefixes (`VAR=x . lib`). A separator inside quotes is not a
  # statement boundary, and scanning inside strings/heredocs stays out of
  # scope because it would drown the tripwire in false alarms.
  # Directive lines get the same policy: a `# shellcheck` line carrying a key
  # this planner does not model (e.g. source-path=, which changes how a later
  # source statement resolves) is itself a tripwire, so no unmodelled
  # resolution mechanism can be silently guessed around. Keys that cannot
  # affect resolution (disable=, shell=, enable=, external-sources=) pass.
  for (i = 1; i <= n; i++) {
    f = files[i]
    fdir = ""
    if (f ~ /\//) { fdir = f; sub(/\/[^\/]*$/, "/", fdir) }
    lc = 0
    covered = 0
    while ((getline line < f) > 0) {
      lc++
      # A `# shellcheck` directive line; keys may come in any order and a
      # trailing `# comment` is ignored. A source= key governs the next
      # command, whose own target must then not be re-read.
      if (line ~ /^[ \t]*#[ \t]*shellcheck[ \t]/) {
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
            covered = 1
          } else if (dkey != "disable" && dkey != "shell" && dkey != "enable" &&
                     dkey != "external-sources")
            tripwire(f, lc, line, "unmodelled shellcheck directive")
        }
        continue
      }
      if (line ~ /^[ \t]*(#|$)/) continue
      wascov = covered
      covered = 0
      if (index(line, "source") == 0 && line !~ /\.[ \t]/) continue
      nseg = 0
      len = length(line); insq = 0; indq = 0; esc = 0
      expect = 1
      word = ""; wstart = 0
      for (p = 1; p <= len + 1; p++) {
        c = p <= len ? substr(line, p, 1) : " "
        if (esc) { esc = 0; word = word c; continue }
        if (insq) { if (c == "'") insq = 0; word = word c; continue }
        if (indq) {
          if (c == "\\") esc = 1
          else if (c == "\"") indq = 0
          word = word c
          continue
        }
        if (c == "\\" || c == "'" || c == "\"") {
          if (c == "\\") esc = 1
          else if (c == "'") insq = 1
          else indq = 1
          if (word == "") wstart = p
          word = word c
          continue
        }
        if (c == "#" && word == "" && (p == 1 || substr(line, p - 1, 1) ~ /[ \t;&|(]/)) break
        if (c ~ /[ \t;&|()]/) {
          if (word != "") {
            if (expect && (word == "source" || word == ".")) {
              segs[++nseg] = substr(line, wstart)
              expect = 0
            } else if (word != "if" && word != "elif" && word != "then" &&
                       word != "else" && word != "while" && word != "until" &&
                       word != "do" && word != "in" && word != "{" && word != "!" &&
                       word !~ /^[A-Za-z_][A-Za-z0-9_]*=/)
              expect = 0
            word = ""
          }
          if (c != " " && c != "\t") expect = 1
          continue
        }
        if (word == "") wstart = p
        word = word c
      }
      if (nseg > 0 && !wascov)
        for (q = 1; q <= nseg; q++) srcedge(f, lc, line, segs[q], fdir)
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
