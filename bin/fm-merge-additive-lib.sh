#!/usr/bin/env bash
# fm-merge-additive-lib.sh - the single owner of the additive-merge-resolution
# verdict: given a merge's base, its two sides, and the resolution someone
# produced, decide whether that resolution KEPT the content both sides brought
# or DELETED one side's.
#
# The captain's rule this encodes:
#   - A resolution that keeps all the information from both sides is the coder's
#     own call and needs no escalation. Ordering, indentation, list numbering,
#     and fusing two lines into one are all inside that case.
#   - A resolution that deletes either side's content is the captain's call and
#     must escalate.
# docs/merge-resolution-gate.md is the authoritative human-readable contract,
# including the measured evidence behind every rule below and the list of what
# this cannot catch. Read it before changing any rule here.
#
# THE VERDICT, IN ONE PARAGRAPH
# A line is "content one side brought" when it is present in that side and NOT
# present in the merge base - that is what makes it new information rather than
# something the base already said. Every such line must still be present in the
# resolution. A base line that a side deliberately removed is NOT required to
# survive, because honoring a deletion is an ordinary merge outcome and demanding
# its return would flag every legitimate deletion in every merge.
#
# TWO RESCUES, BOTH MEASURED, BOTH DELIBERATE LOSSES OF STRICTNESS
# A correct additive resolution routinely rewrites what it keeps, so exact line
# survival alone refuses correct work - and a check that refuses correct work
# gets switched off, after which nothing is enforced at all. Two rescues make it
# survivable:
#   1. RELOCATION. A required line counts as present if it appears anywhere in
#      the merge's touched paths, not only in the path it came from. Moving a
#      paragraph from AGENTS.md into a skill is not content loss.
#   2. REFORMAT/BLEND. A required line still missing after (1) is rescued when
#      every word it INTRODUCED relative to the base still appears somewhere in
#      that path's resolved text. Re-indenting a line, renumbering a list, and
#      fusing two sentences into one all preserve those words; dropping the line
#      does not.
# Normalization before comparison collapses whitespace runs, strips leading and
# trailing whitespace, and strips a leading markdown list marker or list number,
# so re-indentation and renumbering never register as loss on their own.
#
# API
#   fm_additive_scan <repo> <base> <ours> <theirs> <result-spec>
#     <repo>        a path inside the git repository to read from
#     <base>        merge-base commit-ish, or "" when the sides share no base
#     <ours>        the HEAD side commit-ish
#     <theirs>      the MERGE_HEAD side commit-ish
#     <result-spec> "index" to read the resolution from the git index (what a
#                   commit would record), or a commit-ish to read it from a
#                   merge commit that already exists
#     Prints one `lost:<side>:<path>:<line>` finding per line of content the
#     resolution dropped; <side> is ours, theirs, or both.
#     Exit 0  the resolution is additive.
#     Exit 1  it drops content; findings are on stdout.
#     Exit 2  the scan could not run. The CALLER decides what an unverifiable
#             resolution means for it - an authorship-time checker must not wedge
#             a repository over its own malfunction, a landing gate must not pass
#             what it could not read.
#
#   fm_additive_explain <ours-label> <theirs-label>
#     Prints the shared escalation text naming BOTH candidate resolutions, so no
#     caller invents its own wording for the same decision.
#
# COST
# Two `git diff --name-only` calls, one batched id lookup, one batched read of
# the relocation corpus, and four blob reads per path both sides changed whose
# blob differs somewhere among ours, theirs, and the resolution; all of it feeds
# ONE awk pass, so the cost is linear in the text read.
# docs/merge-resolution-gate.md "Cost" owns the measurements.
set -u

# A path absent at that side reads as empty rather than as an error: add/add and
# delete/modify conflicts are ordinary inputs here.
fm_additive__read_to() {
  local repo=$1 rev=$2 path=$3 dest=$4
  : > "$dest"
  if [ "$rev" = index ]; then
    git -C "$repo" show ":$path" > "$dest" 2>/dev/null || : > "$dest"
  elif [ -n "$rev" ]; then
    git -C "$repo" show "$rev:$path" > "$dest" 2>/dev/null || : > "$dest"
  fi
}

# The object name that reads <path> at <rev> through `git cat-file`.
fm_additive__spec() {
  if [ "$1" = index ]; then printf ':%s\n' "$2"; else printf '%s:%s\n' "$1" "$2"; fi
}

# With no merge base every path in the side counts as changed, which is the
# correct reading for unrelated histories: nothing was already shared.
fm_additive__changed() {
  local repo=$1 base=$2 side=$3
  if [ -n "$base" ]; then
    git -C "$repo" diff --name-only "$base" "$side" 2>/dev/null
  else
    git -C "$repo" ls-tree -r --name-only "$side" 2>/dev/null
  fi | LC_ALL=C sort -u
}

# A resolution's own bytes decide whether it is text; a binary path has no lines
# to keep, so it is skipped rather than guessed at.
fm_additive__is_text() {
  local raw stripped
  raw=$(wc -c < "$1" 2>/dev/null) || return 1
  stripped=$(LC_ALL=C tr -d '\000' < "$1" 2>/dev/null | wc -c) || return 1
  [ "$raw" -eq "$stripped" ]
}

fm_additive_explain() {
  local ours_label=${1:-your branch} theirs_label=${2:-the base you merged in}
  cat <<EOF
This resolution drops content that one side of the merge introduced, so it is
not additive and the choice is not the coder's to make alone.

The two candidate resolutions are:
  (a) KEEP BOTH - restore the lines listed above alongside what this resolution
      already keeps. Ordering, indentation, list numbering, and fusing two
      sentences into one are all free choices inside this option and need no
      approval from anyone.
  (b) DROP THEM - land the resolution as it stands, accepting that this content
      leaves "$ours_label" or "$theirs_label" permanently.

If (a) is correct, redo the resolution and commit again; nothing is escalated.
If the content genuinely should not survive, (b) is a product decision that is
not the coder's to make: report it with

  needs-decision: merge resolution drops <what>; (a) keep both sides, (b) drop <what> from <where>

naming BOTH candidates so it can be relayed as a real choice, and stop.
EOF
}

fm_additive_scan() {
  local repo=$1 base=$2 ours=$3 theirs=$4 result=$5
  local tmp path found=0

  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 2
  tmp=$(mktemp -d 2>/dev/null) || return 2

  fm_additive__changed "$repo" "$base" "$ours"   > "$tmp/ours.paths"  || { rm -rf "$tmp"; return 2; }
  fm_additive__changed "$repo" "$base" "$theirs" > "$tmp/theirs.paths" || { rm -rf "$tmp"; return 2; }
  LC_ALL=C comm -12 "$tmp/ours.paths" "$tmp/theirs.paths" > "$tmp/both.paths"
  if [ ! -s "$tmp/both.paths" ]; then
    rm -rf "$tmp"
    return 0
  fi
  LC_ALL=C sort -u "$tmp/ours.paths" "$tmp/theirs.paths" > "$tmp/touched.paths"

  # A path whose blob is the same on both sides and in the resolution cannot
  # have lost anything either side brought, so it is not read at all. That is
  # most of an ancestry merge: 328 of the 347 paths both sides changed in the
  # 2026-09-30 no-mistakes fork merge.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_additive__spec "$ours" "$path"
    fm_additive__spec "$theirs" "$path"
    fm_additive__spec "$result" "$path"
  done < "$tmp/both.paths" \
    | git -C "$repo" cat-file --batch-check > "$tmp/both.ids" 2>/dev/null \
    || { rm -rf "$tmp"; return 2; }
  : > "$tmp/judge.paths"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    IFS=' ' read -r o_id _ <&3; IFS=' ' read -r t_id _ <&3; IFS=' ' read -r r_id _ <&3
    # A missing object's line starts with the name it was asked for, and the
    # three names always differ, so a missing side never reads as identical.
    [ "$o_id" = "$t_id" ] && [ "$t_id" = "$r_id" ] && continue
    printf '%s\n' "$path" >> "$tmp/judge.paths"
  done < "$tmp/both.paths" 3< "$tmp/both.ids"
  if [ ! -s "$tmp/judge.paths" ]; then
    rm -rf "$tmp"
    return 0
  fi

  # One tagged stream, one awk pass. The relocation corpus - the resolution's
  # text across every path the merge touched, so a line that moved to another
  # file is not read as deleted - goes in ONCE at the head, read by one batched
  # git call, and each path to judge follows as an F header plus its four texts.
  # Feeding the corpus again per path made the cost paths-times-corpus: 4m24s on
  # a 347-path upstream merge (docs/merge-resolution-gate.md "Cost"). The batch's
  # own "<oid> blob <size>" header lines land in the corpus too; no content line
  # plausibly equals one, and --batch ends every blob with a newline.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_additive__spec "$result" "$path"
  done < "$tmp/touched.paths" \
    | git -C "$repo" cat-file --batch 2>/dev/null \
    | awk '{ print "R\t" $0 }' > "$tmp/stream" \
    || { rm -rf "$tmp"; return 2; }

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_additive__read_to "$repo" "$result" "$path" "$tmp/res"
    [ -s "$tmp/res" ] || continue
    fm_additive__is_text "$tmp/res" || continue
    fm_additive__read_to "$repo" "$base"   "$path" "$tmp/base"
    fm_additive__read_to "$repo" "$ours"   "$path" "$tmp/ours"
    fm_additive__read_to "$repo" "$theirs" "$path" "$tmp/theirs"
    {
      printf 'F\t%s\n' "$path"
      fm_additive__tag B "$tmp/base"
      fm_additive__tag O "$tmp/ours"
      fm_additive__tag T "$tmp/theirs"
      fm_additive__tag P "$tmp/res"
    } >> "$tmp/stream"
  done < "$tmp/judge.paths"

  fm_additive__awk < "$tmp/stream" > "$tmp/out" || { rm -rf "$tmp"; return 2; }
  [ -s "$tmp/out" ] && found=1
  cat "$tmp/out"

  rm -rf "$tmp"
  [ "$found" -eq 0 ]
}

# Tag every line of a file as "<tag>\t<content>". awk, not sed: sed passes a
# missing final newline through, so a file ending without one fused its last line
# with the next section's first tag - a no-EOL JSON file identical on both sides
# was reported as losing "}T {". awk ends every record it prints.
fm_additive__tag() {
  awk -v t="$1" '{ print t "\t" $0 }' "$2"
}

# Tagged-stream awk core. Every line arrives as "<tag>\t<content>", so an empty
# side contributes nothing and can never shift which input the reader thinks it
# is on - the failure mode a positional FNR==1 counter has on an empty file, and
# the reason this is not written as five awk file arguments.
#   R relocation corpus (the resolution across every touched path), first, once
#   F the next path to judge; its B, O, T, P lines follow
#   B base text   O ours text   T theirs text   P this path's resolution
# Prints one `lost:<side>:<path>:<line>` per finding, grouped by path in stream
# order and sorted within a path.
fm_additive__awk() {
  awk -F'\t' '
    function norm(s) {
      gsub(/[ \t]+/, " ", s)
      sub(/^ /, "", s); sub(/ $/, "", s)
      sub(/^[-*+] /, "", s)
      sub(/^[0-9]+[.)] /, "", s)
      return s
    }
    # Tokens are case-folded. Fusing two sentences into one lowercases the
    # second one is leading word, and the captain named sentence-merging as
    # inside the additive case, so a rescue that failed on that single letter
    # would refuse exactly the reformat it exists to allow. Only the rescue folds
    # case; exact line survival above it does not.
    function addtoks(s, dest,   n, i, a) {
      n = split(tolower(s), a, /[^a-z0-9_]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") dest[a[i]] = 1
    }
    function judge(   k, req, nt, a, i, novel, survived) {
      for (k in O) if (!(k in B)) req[k] = "ours"
      for (k in T) if (!(k in B)) req[k] = (k in req) ? "both" : "theirs"
      for (k in req) {
        if (k in R) continue                       # rescue 1: relocation
        nt = split(tolower(k), a, /[^a-z0-9_]+/)   # rescue 2: reformat/blend
        novel = 0; survived = 0
        for (i = 1; i <= nt; i++) {
          if (a[i] == "" || a[i] in BT) continue
          novel++
          if (a[i] in PT) survived++
        }
        if (novel == 0) continue
        if (novel == survived) continue
        # The path number keeps paths in stream order through the sort below.
        printf "%09d\tlost:%s:%s:%s\n", np, req[k], path, k
      }
      split("", B); split("", O); split("", T); split("", BT); split("", PT)
    }
    {
      tag = $1
      line = substr($0, index($0, "\t") + 1)
      if (tag == "F") { if (np) judge(); np++; path = line; next }
      n = norm(line)
      if (tag == "B")      { if (n != "") B[n] = 1; addtoks(line, BT) }
      else if (tag == "O") { if (n != "") O[n] = 1 }
      else if (tag == "T") { if (n != "") T[n] = 1 }
      else if (tag == "R") { if (n != "") R[n] = 1 }
      else if (tag == "P") { addtoks(line, PT) }
    }
    END { if (np) judge() }
  ' | LC_ALL=C sort | cut -f2-
}
