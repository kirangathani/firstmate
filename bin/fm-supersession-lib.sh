#!/usr/bin/env bash
# fm-supersession-lib.sh - the ONE parser for the captain-approved supersession
# record's entry grammar, and the ONE matcher that decides whether an entry
# covers a finding.
#
# The grammar itself (entry format, required fields, every case that refuses
# rather than guesses, and the safety reasoning behind `kind`) is owned and
# documented by bin/fm-pr-merge.sh's header; this file is its single
# implementation, extracted so a second reader of the record cannot drift from
# the gate that enforces it. bin/fm-pr-merge.sh decides whether a merge
# proceeds; bin/fm-nm-flow.sh only classifies findings for display; the CI-side
# attestation (bin/fm-supersession-attest-lib.sh) carries the same approvals to
# a GitHub runner that cannot read the private record at all. All three must
# answer "is this identifier covered?" identically, which is why there is one
# matcher and not three.
#
# THREE FUNCTIONS, one parse and one match between them:
#
# fm_supersession_entries_extract <record-file> <project>
#   Print one CANONICAL ENTRY LINE per fully-formed captain-approved entry in
#   that record, in the order they appear. This is the file's only reader of the
#   entry grammar; everything else here is built on it.
#
# fm_supersession_entry_covers <sel> <kind> <value> <file>::<name> <finding-class>
#   Returns 0 iff one canonical entry covers that identifier for that class.
#
# fm_supersession_approved <record-file> <project> <file>::<name> <finding-class>
#   Returns 0 iff the record holds a fully-formed captain-approved entry that
#   covers that identifier for that finding class. An empty project or an
#   absent file means no approvals. A malformed entry is warned about on stderr
#   and never honored: this grammar governs what may BYPASS the merge gate, so
#   every unclear case fails closed.
#
# fm_supersession_covered <entries-file> <file>::<name> <finding-class>
#   The same question asked of a file of canonical entry lines rather than of
#   the record, for a reader that never sees the record - CI, which is handed
#   the verified entries and nothing else.
#
# THE CANONICAL ENTRY LINE, this file's own wire format between the record and
# any reader that cannot see it:
#
#     <sel><TAB><kind><TAB><value>
#
#   sel    `id` for an exact identifier, `ids` for the glob batch form.
#   kind   the finding class this entry excuses, or `any`. An entry that omits
#          kind is canonicalized to `any`, which is what the record's own
#          grammar means by an absent kind.
#   value  the identifier or the glob, LAST because a test identifier contains
#          spaces routinely. A value carrying a tab is refused rather than
#          canonicalized, because the field it would split into is not what the
#          captain approved.
#
# It deliberately carries NO date and NO reason. Those are the captain's private
# record of WHY an assertion was superseded; the matcher has never read them,
# and a reader that only has to answer "is this covered?" must not be handed
# them (bin/fm-supersession-attest.sh's header owns that boundary).

# The canonical line's field separator, resolved once into a named constant so
# every reader below splits on a tab that is visible in this source rather than
# on an invisible literal one.
FM_SUPERSESSION_FIELD_SEP=$'\t'

# fm_supersession_entry_line_valid <line>: 0 iff <line> is a well-formed
# canonical entry line. Every reader of a canonical line validates it with this
# before matching on it, including readers whose input was already signed: a
# signature proves who wrote a line, never that it says something this matcher
# can act on, and a line this file cannot read must never widen into one it
# guesses at.
fm_supersession_entry_line_valid() {
  local line=${1-} sel kind value rest sep=$FM_SUPERSESSION_FIELD_SEP
  case "$line" in
    *"$sep"*"$sep"*) ;;
    *) return 1 ;;
  esac
  sel=${line%%"$sep"*}
  rest=${line#*"$sep"}
  kind=${rest%%"$sep"*}
  value=${rest#*"$sep"}
  case "$sel" in id|ids) ;; *) return 1 ;; esac
  case "$kind" in missing|failing|unexecuted|unstable|any) ;; *) return 1 ;; esac
  [ -n "$value" ] || return 1
  case "$value" in *"$sep"*) return 1 ;; esac
  return 0
}

# fm_supersession_entry_covers <sel> <kind> <value> <ident> <finding-class>
fm_supersession_entry_covers() {
  local sel=$1 kind=$2 value=$3 ident=$4 finding_class=$5
  if [ "$kind" != any ] && [ "$kind" != "$finding_class" ]; then
    return 1
  fi
  case "$sel" in
    id) [ "$value" = "$ident" ]; return $? ;;
    ids) ;;
    *) return 1 ;;
  esac
  # The batch form's value is a GLOB matched against the identifier, so the
  # pattern side is deliberately unquoted; that is the documented `ids:`
  # mechanism rather than an oversight.
  # shellcheck disable=SC2053
  [[ "$ident" == $value ]]
}

# fm_supersession_entries_extract <record-file> <project>
fm_supersession_entries_extract() {
  local file=$1 proj=$2
  local line head field key val bad req kind_seen seen_keys
  local entry_id entry_ids entry_proj entry_date entry_reason entry_kind
  [ -n "$proj" ] || return 0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- id: "*|"- ids: "*) ;;
      "- "*" | "*": "*)
        echo "warning: ignoring supersession entry that carries neither 'id:' nor 'ids:' as its first field: $line" >&2
        continue
        ;;
      *) continue ;;
    esac
    bad=
    for req in project date reason; do
      case "$line" in
        *" | $req: "*) ;;
        *) bad="a missing required field ($req)" ; break ;;
      esac
    done
    if [ -n "$bad" ]; then
      echo "warning: ignoring supersession entry missing a required field (id or ids, project, date, reason): $line" >&2
      continue
    fi
    # reason is taken as the whole remainder so it may itself contain " | ";
    # every other field is parsed out of the head, in any order.
    entry_reason=${line#* | reason: }
    head=${line%% | reason: *}
    head=${head#- }
    # Fail closed on a field written AFTER reason: it would be swallowed into the
    # reason text, and a swallowed `kind:` silently widens the entry to any.
    for req in id ids project date kind; do
      case "$entry_reason" in
        *" | $req:"*) bad="a field after reason (reason must be the last field)" ; break ;;
      esac
    done
    if [ -n "$bad" ]; then
      echo "warning: ignoring supersession entry with $bad: $line" >&2
      continue
    fi
    entry_id='' entry_ids='' entry_proj='' entry_date='' entry_kind='' kind_seen=0
    seen_keys=' '
    while :; do
      case "$head" in
        *" | "*) field=${head%% | *} ; head=${head#* | } ;;
        *) field=$head ; head= ;;
      esac
      case "$field" in
        *": "*) key=${field%%:*} ; val=${field#*: } ;;
        *) bad="an unparseable field '$field'" ; break ;;
      esac
      case "$seen_keys" in
        *" $key "*) bad="a duplicated field '$key' (a repeat would silently take the last value)" ; break ;;
      esac
      case "$key" in
        id) entry_id=$val ;;
        ids) entry_ids=$val ;;
        project) entry_proj=$val ;;
        date) entry_date=$val ;;
        kind) entry_kind=$val ; kind_seen=1 ;;
        *) bad="an unrecognized field '$key'" ; break ;;
      esac
      seen_keys="$seen_keys$key "
      [ -n "$head" ] || break
    done
    if [ -n "$bad" ]; then
      echo "warning: ignoring supersession entry with $bad: $line" >&2
      continue
    fi
    if [ -n "$entry_id" ] && [ -n "$entry_ids" ]; then
      echo "warning: ignoring supersession entry carrying both 'id:' and 'ids:' (use exactly one): $line" >&2
      continue
    fi
    if [ -z "$entry_id" ] && [ -z "$entry_ids" ]; then
      echo "warning: ignoring supersession entry with an empty field: $line" >&2
      continue
    fi
    if [ -z "$entry_proj" ] || [ -z "$entry_reason" ]; then
      echo "warning: ignoring supersession entry with an empty field: $line" >&2
      continue
    fi
    if [ "$kind_seen" -eq 1 ]; then
      case "$entry_kind" in
        missing|failing|unexecuted|unstable|any) ;;
        "")
          echo "warning: ignoring supersession entry with an empty field: $line" >&2
          continue
          ;;
        *)
          echo "warning: ignoring supersession entry whose kind is not missing, failing, unexecuted, unstable, or any: $line" >&2
          continue
          ;;
      esac
    else
      entry_kind=any
    fi
    case "$entry_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *)
        echo "warning: ignoring supersession entry whose date is not YYYY-MM-DD: $line" >&2
        continue
        ;;
    esac
    if [ "$entry_proj" != "$proj" ]; then
      echo "warning: ignoring supersession entry for project '$entry_proj' found in $proj's record: $line" >&2
      continue
    fi
    # A tab inside the identifier would split the canonical line into fields the
    # captain never wrote, so it is refused here rather than carried into a
    # reader that would then match on a truncated value.
    case "$entry_id$entry_ids" in
      *"$FM_SUPERSESSION_FIELD_SEP"*)
        echo "warning: ignoring supersession entry whose identifier contains a tab: $line" >&2
        continue
        ;;
    esac
    if [ -n "$entry_id" ]; then
      printf 'id%s%s%s%s\n' \
        "$FM_SUPERSESSION_FIELD_SEP" "$entry_kind" "$FM_SUPERSESSION_FIELD_SEP" "$entry_id"
    else
      printf 'ids%s%s%s%s\n' \
        "$FM_SUPERSESSION_FIELD_SEP" "$entry_kind" "$FM_SUPERSESSION_FIELD_SEP" "$entry_ids"
    fi
  done < "$file"
}

# fm_supersession_approved <record-file> <project> <file>::<name> <finding-class>
fm_supersession_approved() {
  local file=$1 proj=$2 ident=$3 finding_class=$4 sel kind value
  [ -n "$proj" ] || return 1
  [ -f "$file" ] || return 1
  while IFS=$FM_SUPERSESSION_FIELD_SEP read -r sel kind value; do
    [ -n "$sel" ] || continue
    if fm_supersession_entry_covers "$sel" "$kind" "$value" "$ident" "$finding_class"; then
      return 0
    fi
  done < <(fm_supersession_entries_extract "$file" "$proj")
  return 1
}

# fm_supersession_covered <entries-file> <file>::<name> <finding-class>
# A line the validator above refuses is skipped rather than guessed at, and a
# caller that must not proceed on a partial reading validates the file itself
# first (bin/fm-reverify-base.sh does, and refuses).
fm_supersession_covered() {
  local file=$1 ident=$2 finding_class=$3 line sel kind value rest
  local sep=$FM_SUPERSESSION_FIELD_SEP
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    fm_supersession_entry_line_valid "$line" || continue
    sel=${line%%"$sep"*}
    rest=${line#*"$sep"}
    kind=${rest%%"$sep"*}
    value=${rest#*"$sep"}
    if fm_supersession_entry_covers "$sel" "$kind" "$value" "$ident" "$finding_class"; then
      return 0
    fi
  done < "$file"
  return 1
}
