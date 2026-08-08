#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for GitHub PR merge polling.
# Callers must validate task IDs and raw PR URLs before constructing task paths
# or performing any side effect.
#
# This file is the ONE owner of the GitHub address grammar, split by INPUT TYPE
# and not by strictness. There is one parser per input type and one identity
# rule underneath both, so no caller has to write a third reading of "is this
# GitHub, and which repository is it":
#   - fm_pr_url_parse         a PR LINK, the canonical recorded artifact.
#   - fm_pr_remote_parse      a GIT REMOTE ADDRESS, what `git remote get-url`
#                             prints. It carries no PR number and returns none.
#   - fm_pr_github_identity_valid  the shared host and owner/repo rule both of
#                             the above judge their extracted parts by.
#   - fm_pr_github_slug_fold  the folded form two identities are COMPARED on,
#                             since GitHub treats owner and repo
#                             case-insensitively.
#
# It is also the ONE reader of which BRANCH a PR targets
# (fm_pr_base_branch_read), for the same reason: a merge gate and the preview of
# that gate must resolve one base, not two.

FM_PR_URL=
FM_PR_OWNER=
FM_PR_REPO=
FM_PR_NUMBER=
FM_PR_REMOTE_URL=
FM_PR_REMOTE_OWNER=
FM_PR_REMOTE_REPO=
FM_PR_DATA_URL=
FM_PR_DATA_OWNER=
FM_PR_DATA_REPO=
FM_PR_DATA_NUMBER=
FM_PR_META_URL=
FM_PR_META_OWNER=
FM_PR_META_REPO=
FM_PR_META_NUMBER=
FM_PR_REG_ID=
FM_PR_REG_URL=
FM_PR_REG_OWNER=
FM_PR_REG_REPO=
FM_PR_REG_NUMBER=
FM_PR_REG_DATA_HASH=
FM_PR_REG_TEMPLATE_HASH=
FM_PR_REG_DATA_IDENTITY=
FM_PR_REG_CHECK_IDENTITY=
FM_PR_POLL_DATA_TMP=
FM_PR_POLL_CHECK_TMP=
FM_PR_POLL_REG_TMP=
FM_PR_POLL_DATA_DEST=
FM_PR_POLL_CHECK_DEST=
FM_PR_POLL_REG_DEST=
FM_PR_POLL_EXPECT_ID=
FM_PR_POLL_EXPECT_URL=
FM_PR_POLL_EXPECT_OWNER=
FM_PR_POLL_EXPECT_REPO=
FM_PR_POLL_EXPECT_NUMBER=
FM_PR_POLL_EXPECT_DATA_HASH=
FM_PR_POLL_EXPECT_TEMPLATE_HASH=
FM_PR_POLL_EXPECT_DATA_IDENTITY=
FM_PR_POLL_EXPECT_CHECK_IDENTITY=
FM_PR_POLL_TEMPLATE=
FM_PR_POLL_STATE_DEVICE=

fm_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_pr_task_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id"
}

fm_task_id_creation_valid() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

# fm_pr_github_identity_valid <host> <owner> <repo>: the ONE rule for which
# host counts as GitHub and which owner/repo names are real, applied to parts a
# parser has already extracted. Both parsers call it, so "is this GitHub" cannot
# be read two different ways.
# The host is matched case-insensitively because hostnames are; owner and repo
# are judged, not folded, so each parser can return the spelling its input used
# and a caller that COMPARES two identities folds both through
# fm_pr_github_slug_fold instead of trusting either spelling.
fm_pr_github_identity_valid() {
  local host=${1-} owner=${2-} repo=${3-} pattern
  local LC_ALL=C
  case "$host" in
    [Gg][Ii][Tt][Hh][Uu][Bb]"."[Cc][Oo][Mm]) ;;
    *) return 1 ;;
  esac
  pattern='^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])$'
  [[ "$owner" =~ $pattern ]] || return 1
  [[ "$owner" != *--* ]] || return 1
  [[ "$repo" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || return 1
  [ "$repo" != . ] && [ "$repo" != .. ] || return 1
}

# fm_pr_github_slug_fold <owner> <repo>: print the form two identities are
# compared on. GitHub treats owner and repo case-insensitively, so a comparison
# that does not fold case answers "a different repository" for the same one.
fm_pr_github_slug_fold() {
  printf '%s/%s' "${1-}" "${2-}" | tr '[:upper:]' '[:lower:]'
}

# fm_pr_url_parse <raw>: the sole PR-LINK parser. It takes a PR link and returns
# owner, repo and number, rejecting anything that is not PR-shaped.
# The shape is matched here and the identity is judged by
# fm_pr_github_identity_valid; the literal lowercase `https://github.com/`
# prefix is this parser's OWN additional requirement, on top of the shared rule
# rather than instead of it. A recorded link is a canonical artifact that is
# later compared byte for byte, so a differently-spelled host is a different
# string and is rejected rather than silently canonicalized.
fm_pr_url_parse() {
  local raw=${1-} pattern owner repo number
  local LC_ALL=C
  FM_PR_URL=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  pattern='^https://github\.com/([^/]+)/([^/]+)/pull/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  # Captured before the shared rule runs: its own [[ =~ ]] would clobber
  # BASH_REMATCH.
  owner=${BASH_REMATCH[1]}
  repo=${BASH_REMATCH[2]}
  number=${BASH_REMATCH[3]}
  fm_pr_github_identity_valid github.com "$owner" "$repo" || return 1
  FM_PR_URL=$raw
  FM_PR_OWNER=$owner
  FM_PR_REPO=$repo
  FM_PR_NUMBER=$number
}

# fm_pr_remote_parse <raw>: the sole GIT REMOTE ADDRESS parser, for what
# `git remote get-url` prints. It accepts the scp-style git@host:owner/repo, the
# ssh:// and https:// forms, an optional embedded credential, an optional port,
# and an optional trailing .git.
# A remote address carries no PR number, so this parser returns none and never
# touches FM_PR_NUMBER: a caller holding a parsed PR link and a parsed remote at
# once keeps both.
# An address that is not GitHub at all is a plain non-zero return with the
# FM_PR_REMOTE_* set left empty, so a caller can never read a partial answer as
# an identity.
# shellcheck disable=SC2034  # FM_PR_REMOTE_* are this parser's return values, read by its callers.
fm_pr_remote_parse() {
  local raw=${1-} rest host owner repo
  local LC_ALL=C
  FM_PR_REMOTE_URL=
  FM_PR_REMOTE_OWNER=
  FM_PR_REMOTE_REPO=
  case "$raw" in
    *://*)
      rest=${raw#*://}
      # A userinfo@ segment belongs to the authority, so it is stripped only
      # when it appears before the first path separator.
      case "${rest%%/*}" in
        *@*) rest=${rest#*@} ;;
      esac
      host=${rest%%/*}
      host=${host%%:*}
      case "$rest" in */*) rest=${rest#*/} ;; *) return 1 ;; esac
      ;;
    *:*)
      host=${raw%%:*}
      host=${host##*@}
      rest=${raw#*:}
      ;;
    *) return 1 ;;
  esac
  rest=${rest#/}
  rest=${rest%/}
  rest=${rest%.git}
  case "$rest" in */*) ;; *) return 1 ;; esac
  owner=${rest%%/*}
  repo=${rest#*/}
  fm_pr_github_identity_valid "$host" "$owner" "$repo" || return 1
  FM_PR_REMOTE_URL=$raw
  FM_PR_REMOTE_OWNER=$owner
  FM_PR_REMOTE_REPO=$repo
}

# fm_pr_bounded <command...>: run <command> under a wall-clock bound when a
# timeout tool exists, and unbounded when none does. FM_PR_GH_TIMEOUT (default
# 15) is the bound. A missing timeout tool must not stop the command running at
# all, because the callers' alternative is no GitHub answer whatsoever.
fm_pr_bounded() {
  local secs=${FM_PR_GH_TIMEOUT:-15}
  case "$secs" in ''|*[!0-9]*|0) secs=15 ;; esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

# fm_pr_repo_matches_origin <worktree> <pr-url>: succeed when the PR link and
# the worktree's origin name the same GitHub repository, and when the question
# is not decidable at all.
# NOT DECIDABLE IS NOT A MISMATCH, deliberately: an origin that is not a GitHub
# address (a local path, a bare mirror, a self-hosted remote) cannot be compared
# with a GitHub PR link, and refusing there would break every legitimate
# non-GitHub setup. This closes the wrong-GitHub-repository hole; it is not a
# general remote-identity check.
# On a decidable MISMATCH it returns non-zero with FM_PR_OWNER/FM_PR_REPO and
# FM_PR_REMOTE_OWNER/FM_PR_REMOTE_REPO left set to the two sides, so a caller can
# name both without re-parsing either. Origin's RAW address is never among them,
# because it can carry an embedded credential.
fm_pr_repo_matches_origin() {
  local wt=${1-} pr_url=${2-} origin_url
  fm_pr_url_parse "$pr_url" || return 1
  origin_url=$(git -C "$wt" remote get-url origin 2>/dev/null || true)
  [ -n "$origin_url" ] || return 0
  fm_pr_remote_parse "$origin_url" || return 0
  [ "$(fm_pr_github_slug_fold "$FM_PR_OWNER" "$FM_PR_REPO")" \
    != "$(fm_pr_github_slug_fold "$FM_PR_REMOTE_OWNER" "$FM_PR_REMOTE_REPO")" ] || return 0
  # The two parsers clear disjoint variable sets, so both sides are still set.
  return 1
}

# fm_pr_base_branch_read <worktree> <pr-url> <diagnostic-file>: the sole reader
# of which BRANCH a pull request targets, printed on stdout.
# Two callers ask that question and must never answer it differently: the merge
# gate (bin/fm-assert-tests-kept.sh) measures its verdict against this branch,
# and the merge-gate preview (bin/fm-nm-flow.sh) shows the captain what that
# verdict will be. A second reading of "which base" would put the preview and
# the gate it previews on different trees, which is the same wrong-base class
# both were written to eliminate.
# gh-axi is this repo's GitHub interface for ACTIONS, but its `pr view` exposes
# no baseRefName field, so this is a raw-gh JSON read exactly as
# bin/fm-pr-check.sh's headRefOid lookup is. The URL fully qualifies the repo;
# the cd into the worktree only supplies gh's repo context if it ever needs one.
# This function DECIDES NOTHING on failure, because its callers legitimately
# differ: the gate refuses because it blocks a merge, the viewer degrades
# because it does not. So every distinguishable cause, together with gh's own
# verbatim stderr, is written to <diagnostic-file> and the caller chooses what
# to do with it. gh's stderr is captured into the sibling <diagnostic-file>.gh,
# so a caller must own a private directory for both rather than a bare temp
# name a second user could pre-create as a symlink.
# The link itself is judged by the parser that owns its input type BEFORE any
# network call, so a value that is not a PR link at all costs no query.
fm_pr_base_branch_read() {
  local wt=${1-} pr_url=${2-} diag=${3-} err name rc=0
  err="$diag.gh"
  : > "$diag" || return 1
  : > "$err" || return 1
  if ! fm_pr_url_parse "$pr_url"; then
    printf '%s is not a GitHub pull request link\n' "$pr_url" > "$diag"
    return 1
  fi
  # The answer is a branch name in the PR's OWN repository, and every caller
  # resolves it against the worktree's origin, so a PR living somewhere else
  # would name a same-branch in the wrong repository. Checking it HERE is what
  # keeps the gate and its preview from disagreeing: a caller that had to
  # remember the check separately is a caller that can forget it.
  if ! fm_pr_repo_matches_origin "$wt" "$pr_url"; then
    printf 'the PR lives in %s/%s but this local copy points at %s/%s\n' \
      "$FM_PR_OWNER" "$FM_PR_REPO" \
      "$FM_PR_REMOTE_OWNER" "$FM_PR_REMOTE_REPO" > "$diag"
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'gh is not installed\n' > "$diag"
    return 1
  fi
  # A network read with no bound hangs whoever called it, and one caller is the
  # merge gate, where a silent indefinite hang is worst. Bound it here so both
  # callers inherit it; the viewer's own outer bound is a separate layer that
  # also covers this function's non-network work.
  name=$(cd "$wt" && fm_pr_bounded gh pr view "$pr_url" --json baseRefName -q .baseRefName 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    { printf 'the gh query failed (exit %s)\n' "$rc"; cat "$err"; } > "$diag"
    return 1
  fi
  if [ -z "$name" ]; then
    { printf 'the gh query succeeded but reported no base branch name\n'; cat "$err"; } > "$diag"
    return 1
  fi
  # The name goes into a refspec, so it must be a name git itself accepts as a
  # branch; anything else is rejected rather than interpolated.
  if ! git check-ref-format "refs/heads/$name" 2>"$err"; then
    { printf 'gh reported %s, which git does not accept as a branch name\n' "$name"; cat "$err"; } > "$diag"
    return 1
  fi
  printf '%s' "$name"
}

fm_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

fm_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

fm_pr_file_identity() {
  local device inode
  device=$(fm_pr_file_device "$1") || return 1
  inode=$(fm_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

# sha256sum is preferred because it is a C binary while shasum is a perl script,
# measured here at roughly 13x the cost per call on the PR-poll validation path.
# The shasum branch must stay: stock macOS ships shasum and does not ship sha256sum.
# Both emit "<hex>  <name>" and "<hex>  -", so field 1 is identical either way.
fm_pr_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(fm_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ]
}

fm_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(fm_pr_file_link_count "$path")" = 1 ]
  fi
}

fm_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  fm_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(fm_pr_file_device "$path")" = "$device" ]
}

fm_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  FM_PR_META_URL=
  FM_PR_META_OWNER=
  FM_PR_META_REPO=
  FM_PR_META_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if fm_pr_url_parse "$value"; then
          FM_PR_META_URL=$FM_PR_URL
          FM_PR_META_OWNER=$FM_PR_OWNER
          FM_PR_META_REPO=$FM_PR_REPO
          FM_PR_META_NUMBER=$FM_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          fm_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$FM_PR_META_URL" ]
}

fm_pr_poll_data_parse() {
  local file=$1 url owner repo number
  FM_PR_DATA_URL=
  FM_PR_DATA_OWNER=
  FM_PR_DATA_REPO=
  FM_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r owner <&8 || { exec 8<&-; return 1; }
  IFS= read -r repo <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  fm_pr_url_parse "$url" || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  FM_PR_DATA_URL=$FM_PR_URL
  FM_PR_DATA_OWNER=$FM_PR_OWNER
  FM_PR_DATA_REPO=$FM_PR_REPO
  FM_PR_DATA_NUMBER=$FM_PR_NUMBER
}

fm_pr_poll_registration_parse() {
  local file=$1 version id url owner repo number data_hash template_hash data_identity check_identity
  FM_PR_REG_ID=
  FM_PR_REG_URL=
  FM_PR_REG_OWNER=
  FM_PR_REG_REPO=
  FM_PR_REG_NUMBER=
  FM_PR_REG_DATA_HASH=
  FM_PR_REG_TEMPLATE_HASH=
  FM_PR_REG_DATA_IDENTITY=
  FM_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r owner <&7 || { exec 7<&-; return 1; }
  IFS= read -r repo <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = fm-pr-poll-registration-v1 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  FM_PR_REG_ID=$id
  FM_PR_REG_URL=$FM_PR_URL
  FM_PR_REG_OWNER=$FM_PR_OWNER
  FM_PR_REG_REPO=$FM_PR_REPO
  FM_PR_REG_NUMBER=$FM_PR_NUMBER
  FM_PR_REG_DATA_HASH=$data_hash
  FM_PR_REG_TEMPLATE_HASH=$template_hash
  FM_PR_REG_DATA_IDENTITY=$data_identity
  FM_PR_REG_CHECK_IDENTITY=$check_identity
}

fm_pr_poll_cleanup() {
  [ -z "$FM_PR_POLL_DATA_TMP" ] || rm -f -- "$FM_PR_POLL_DATA_TMP"
  [ -z "$FM_PR_POLL_CHECK_TMP" ] || rm -f -- "$FM_PR_POLL_CHECK_TMP"
  [ -z "$FM_PR_POLL_REG_TMP" ] || rm -f -- "$FM_PR_POLL_REG_TMP"
  FM_PR_POLL_DATA_TMP=
  FM_PR_POLL_CHECK_TMP=
  FM_PR_POLL_REG_TMP=
}

fm_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$FM_PR_POLL_CHECK_DEST" ] || [ -L "$FM_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$FM_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_REG_DEST" ] || [ -L "$FM_PR_POLL_REG_DEST" ]; then
    rm -f -- "$FM_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_DATA_DEST" ] || [ -L "$FM_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$FM_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$FM_PR_POLL_CHECK_DEST" ] && [ ! -L "$FM_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_REG_DEST" ] && [ ! -L "$FM_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_DATA_DEST" ] && [ ! -L "$FM_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

fm_pr_poll_prepare() {
  local state=$1 id=$2 url=$3 owner=$4 repo=$5 number=$6 template=$7
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  FM_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  FM_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  FM_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  FM_PR_POLL_EXPECT_ID=$id
  FM_PR_POLL_EXPECT_URL=$url
  FM_PR_POLL_EXPECT_OWNER=$owner
  FM_PR_POLL_EXPECT_REPO=$repo
  FM_PR_POLL_EXPECT_NUMBER=$number
  FM_PR_POLL_TEMPLATE=$template
  FM_PR_POLL_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  [ -n "$FM_PR_POLL_STATE_DEVICE" ] || return 1
  FM_PR_POLL_DATA_TMP=$(mktemp "$state/.fm-pr-poll-data.XXXXXX") || return 1
  FM_PR_POLL_CHECK_TMP=$(mktemp "$state/.fm-pr-poll-check.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }
  FM_PR_POLL_REG_TMP=$(mktemp "$state/.fm-pr-poll-registration.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n' "$url" "$owner" "$repo" "$number" > "$FM_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_DATA_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_TMP" \
    || [ "$FM_PR_DATA_URL" != "$url" ] \
    || [ "$FM_PR_DATA_OWNER" != "$owner" ] \
    || [ "$FM_PR_DATA_REPO" != "$repo" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$FM_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_CHECK_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_CHECK_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$FM_PR_POLL_CHECK_TMP"; then
    fm_pr_poll_cleanup
    return 1
  fi
  FM_PR_POLL_EXPECT_DATA_HASH=$(fm_pr_sha256 "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_TEMPLATE_HASH=$(fm_pr_sha256 "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_DATA_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_CHECK_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-registration-v1 "$id" "$url" "$owner" "$repo" "$number" \
      "$FM_PR_POLL_EXPECT_DATA_HASH" "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$FM_PR_POLL_EXPECT_DATA_IDENTITY" "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$FM_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_REG_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_REG_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_TMP" \
    || [ "$FM_PR_REG_ID" != "$id" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    fm_pr_poll_cleanup
    return 1
  fi
}

fm_pr_poll_publish_prepared() {
  [ -n "$FM_PR_POLL_DATA_TMP" ] && [ -n "$FM_PR_POLL_CHECK_TMP" ] \
    && [ -n "$FM_PR_POLL_REG_TMP" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_DATA_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_REG_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$FM_PR_POLL_DATA_TMP" "$FM_PR_POLL_DATA_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_DATA_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || [ "$(fm_pr_file_identity "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(fm_pr_sha256 "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_DEST" \
    || [ "$FM_PR_DATA_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_DATA_OWNER" != "$FM_PR_POLL_EXPECT_OWNER" ] \
    || [ "$FM_PR_DATA_REPO" != "$FM_PR_POLL_EXPECT_REPO" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$FM_PR_POLL_REG_TMP" "$FM_PR_POLL_REG_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_REG_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_REG_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_DEST" \
    || [ "$FM_PR_REG_ID" != "$FM_PR_POLL_EXPECT_ID" ] \
    || [ "$FM_PR_REG_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_REG_OWNER" != "$FM_PR_POLL_EXPECT_OWNER" ] \
    || [ "$FM_PR_REG_REPO" != "$FM_PR_POLL_EXPECT_REPO" ] \
    || [ "$FM_PR_REG_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$FM_PR_REG_DATA_IDENTITY" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$FM_PR_REG_CHECK_IDENTITY" != "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$FM_PR_POLL_CHECK_TMP" "$FM_PR_POLL_CHECK_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_CHECK_TMP=
  if ! fm_pr_poll_artifacts_valid "${FM_PR_POLL_CHECK_DEST%/*}" "$FM_PR_POLL_EXPECT_ID" "$FM_PR_POLL_TEMPLATE"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
}

fm_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash data_identity check_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  template_hash=$(fm_pr_sha256 "$check") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_REG_OWNER" = "$FM_PR_DATA_OWNER" ] || return 1
  [ "$FM_PR_REG_REPO" = "$FM_PR_DATA_REPO" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$check_identity" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_META_OWNER" = "$FM_PR_DATA_OWNER" ] || return 1
  [ "$FM_PR_META_REPO" = "$FM_PR_DATA_REPO" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_DATA_NUMBER" ]
}
