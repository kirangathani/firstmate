#!/usr/bin/env bash
# fm-supersession-lib.sh - the ONE parser for the captain-approved supersession
# record's entry grammar.
#
# The grammar itself (entry format, required fields, every case that refuses
# rather than guesses, and the safety reasoning behind `kind`) is owned and
# documented by bin/fm-pr-merge.sh's header; this file is its single
# implementation, extracted so a second reader of the record cannot drift from
# the gate that enforces it. bin/fm-pr-merge.sh decides whether a merge
# proceeds; bin/fm-nm-flow.sh only classifies findings for display. Both must
# answer "is this identifier covered?" identically, which is why there is one
# matcher and not two.
#
# fm_supersession_approved <record-file> <project> <file>::<name> <finding-class>
#   Returns 0 iff the record holds a fully-formed captain-approved entry that
#   covers that identifier for that finding class. An empty project or an
#   absent file means no approvals. A malformed entry is warned about on stderr
#   and never honored: this grammar governs what may BYPASS the merge gate, so
#   every unclear case fails closed.
fm_supersession_approved() {
  local file=$1 proj=$2 ident=$3 finding_class=$4
  local line head field key val bad req kind_seen seen_keys
  local entry_id entry_ids entry_proj entry_date entry_reason entry_kind
  [ -n "$proj" ] || return 1
  [ -f "$file" ] || return 1
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
    if [ "$entry_kind" != any ] && [ "$entry_kind" != "$finding_class" ]; then
      continue
    fi
    if [ -n "$entry_id" ]; then
      if [ "$entry_id" = "$ident" ]; then
        return 0
      fi
    else
      # shellcheck disable=SC2053  # unquoted glob match is the documented `ids:` batch mechanism
      if [[ "$ident" == $entry_ids ]]; then
        return 0
      fi
    fi
  done < "$file"
  return 1
}
