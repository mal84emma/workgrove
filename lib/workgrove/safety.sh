# shellcheck shell=bash
# Reads globals: GIT_SSH_COMMAND, REPO, TMPDIR, WG_VERSION_ROOT, WT_BASE_FETCHES, WT_BASE_FETCH_NOTIFIED, WT_DIRNAME, WT_MERGE_TREE, WT_META, WT_TMPFILES.
preservation_git() { # Virtual history rewrites cannot establish preservation of the original objects.
  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null git -c advice.graftFileDeprecated=false "$@"
}
file_hash() { # sha256 of a file, or "" when it cannot be read (the Mac has shasum, Linux sha256sum)
  local h=""
  if have shasum; then h=$(shasum -a 256 2>/dev/null <"$1") || h=""
  elif have sha256sum; then h=$(sha256sum 2>/dev/null <"$1") || h=""
  else
    # shellcheck source=lib/workgrove/vm/python-runtime.sh
    source "$WG_VERSION_ROOT/lib/workgrove/vm/python-runtime.sh"
    h=$(wg_run_python -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null) || h=""
  fi
  h=${h%% *}
  [[ $h =~ ^[0-9a-f]{64}$ ]] || h=''
  printf '%s' "$h"
}

metadata_fingerprint() { # Absence and an unreadable sidecar must never compare equal.
  local path=$1 hash
  if [[ ! -e $path && ! -L $path ]]; then printf absent; return 0; fi
  [[ -f $path ]] || return 1
  hash=$(file_hash "$path")
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$hash"
}

work_file_hash() { # Link fingerprints preserve link identity without following their targets.
  if [[ ! -L $1 ]]; then file_hash "$1"; return; fi
  # shellcheck source=lib/workgrove/vm/python-runtime.sh
  source "$WG_VERSION_ROOT/lib/workgrove/vm/python-runtime.sh" || return 1
  wg_run_python -c 'import hashlib,os,sys; print("L" + hashlib.sha256(os.readlink(os.fsencode(sys.argv[1]))).hexdigest())' "$1"
}

include_match() { # include_match <path relative to a checkout> — 0 when .wt-include covers it
  local f="$1" inc="$REPO/.wt-include" pat contents
  [[ -f "$inc" ]] || return 1
  contents=$(cat "$inc") || return 2
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    pat="${pat%%#*}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -z "$pat" ]] && continue
    pat="${pat#/}"; pat="${pat%/}"
    # shellcheck disable=SC2053
    if [[ "$f" == $pat || "$f" == $pat/* || "$(basename "$f")" == $pat ]]; then return 0; fi
  done <<<"$contents"
  return 1
}

copy_includes() { # Copy ignored files from .wt-include; print "<path>:<fingerprint>" for each successful snapshot.
  local dest="$1" f hash encoded match_rc  # the hash is of what was copied, so rm can tell a copy edited inside
  [[ -f "$REPO/.wt-include" ]] || return 0   # the worktree from a file changed in the main checkout since
  preservation_git -C "$REPO" ls-files --others --ignored --exclude-standard -z | while IFS= read -r -d '' f; do
    [[ $f != "$WT_DIRNAME/"* ]] || continue
    match_rc=0; include_match "$f" || match_rc=$?
    [[ $match_rc != 2 ]] || { warn 'cannot read private-file include patterns'; return 1; }
    if [[ $match_rc == 0 ]]; then
      [[ $f != *$'\n'* ]] || { warn 'cannot snapshot a copied filename containing a newline'; return 1; }
      encoded=$(jq -nr --arg path "$f" '$path') || return 1
      [[ $encoded == "$f" ]] || { warn 'cannot encode a copied filename in task metadata'; return 1; }
      # errexit does not reach in here (a pipeline inside $( )), so catch a failed copy by hand. If the loop
      # printed a failed copy anyway, "includes" would record a file that the worktree does not have.
      mkdir -p "$dest/$(dirname "$f")"
      if cp -p "$REPO/$f" "$dest/$f"; then
        hash=$(work_file_hash "$dest/$f") || return 1
        [[ $hash =~ ^L?[0-9a-f]{64}$ ]] || { warn 'cannot fingerprint a copied private file'; return 1; }
        printf '%s:%s\n' "$f" "$hash"
      else warn "could not copy $f into the worktree"; return 1; fi
    fi
  done
}

worktree_includes() { # worktree_includes <path> — ignored files inside the worktree that .wt-include covers
  local p="$1" f                          # today, whether or not they existed when the worktree was created
  [[ -f "$REPO/.wt-include" ]] || return 0
  local listing match_error=0
  listing=$(mktemp "${TMPDIR:-/tmp}/wt-includes.XXXXXX") || return 1
  wt_register_tmpfile "$listing"
  if ! preservation_git -C "$p" ls-files --others --ignored --exclude-standard -z >"$listing" 2>/dev/null; then
    rm -f "$listing"; return 1
  fi
  while IFS= read -r -d '' f; do
    if [[ $f == *$'\n'* ]]; then match_error=1; break; fi
    if [[ "$f" != "$WT_DIRNAME/"* ]]; then
      local match_rc=0
      include_match "$f" || match_rc=$?
      case $match_rc in 0) printf '%s\n' "$f" ;; 1) ;; *) match_error=1; break ;; esac
    fi
  done <"$listing"
  [[ -z $f ]] || match_error=1
  rm -f "$listing"
  [[ $match_error == 0 ]]
}

changed_includes() { # changed_includes <name> <path> -> ignored files that removing the worktree would destroy
  # This protection cannot be a creation-time snapshot. So it reads the two sources below.
  # - The files recorded at `wt new`, compared with the hash of what was copied then. So rotating a secret in
  #   the main checkout does not make every existing worktree unremovable.
  # - Every ignored file that the patterns cover *now*. An .env.local that an agent wrote in the worktree is
  #   in no snapshot, and `worktree remove --force` deletes it without a warning.
  local n="$1" p="$2" f h e list
  local -A seen=()
  meta_require "$n"
  [[ ${WT_META[includes_status]-complete} == complete ]] || return 1
  local current
  current=$(worktree_includes "$p") || return 1
  list=$(while IFS= read -r e; do [[ -z $e ]] || printf 'R:%s\n' "$e"; done <<<"${WT_META[includes]-}"
         while IFS= read -r e; do [[ -z $e ]] || printf 'F:%s\n' "$e"; done <<<"$current")
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    if [[ $e == F:* ]]; then f=${e#F:}; h=''
    else
    e=${e#R:}; f="${e%:*}"; h="${e##*:}"
    if [[ $h == \\* && ${h:1} =~ ^[0-9a-f]{64}$ ]]; then h=${h:1}; fi
    if [[ ${WT_META[metadata_version]:-0} == 3 && ! $h =~ ^L?[0-9a-f]{64}$ ]]; then return 1; fi
    if [[ ! $h =~ ^L?[0-9a-f]{64}$ && $f != "$e" && ( -e $p/$f || -L $p/$f ) ]]; then return 1; fi
    # WT_COMPAT: Remove when every sidecar records hashes for included files.
    [[ "$h" =~ ^L?[0-9a-f]{64}$ ]] || { f="$e"; h=""; }   # metadata from an older wt: plain names, no hash
    fi
    [[ -n $f ]] || return 1
    [[ -z ${seen["$f"]-} ]] || continue
    seen["$f"]=1
    [[ -e "$p/$f" || -L "$p/$f" ]] || continue
    if [[ -n "$h" ]]; then
      [[ "$(work_file_hash "$p/$f")" == "$h" ]] || printf '%s\n' "$f"
    elif [[ -L "$p/$f" || -L "$REPO/$f" ]]; then
      printf '%s\n' "$f"
    elif [[ -e "$REPO/$f" ]]; then
      cmp -s "$p/$f" "$REPO/$f" || printf '%s\n' "$f"   # no hash: the main checkout is all there is to compare with
    else
      printf '%s\n' "$f"                                # nothing anywhere else holds it
    fi
  done <<<"$list"
}

task_admin_preserved() { # Private submodule refs can survive deinitialization but disappear with the task registration.
  # shellcheck source=lib/workgrove/vm/python-runtime.sh
  source "$WG_VERSION_ROOT/lib/workgrove/vm/python-runtime.sh" || return 1
  wg_run_python "$WG_VERSION_ROOT/lib/workgrove/filtered_files.py" admin "$REPO" "$1"
}

filtered_files() ( # Git cleaning and stat caches cannot prove preservation of raw tracked bytes.
  local operation=$1 name=$2 path=$3 scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/wt-filtered.XXXXXX") || return 1
  trap 'rm -rf -- "$scratch"' EXIT
  preservation_git -C "$path" ls-files --stage -z >"$scratch/index" || return 1
  # shellcheck source=lib/workgrove/vm/python-runtime.sh
  source "$WG_VERSION_ROOT/lib/workgrove/vm/python-runtime.sh" || return 1
  wg_run_python "$WG_VERSION_ROOT/lib/workgrove/filtered_files.py" oids "$scratch" "$path" "$REPO" "$(wt_meta "$name")" >"$scratch/oids" || return 1
  preservation_git -C "$path" cat-file --batch <"$scratch/oids" >"$scratch/blobs" || return 1
  wg_run_python "$WG_VERSION_ROOT/lib/workgrove/filtered_files.py" "$operation" "$scratch" "$path" "$REPO" "$(wt_meta "$name")"
)

index_visibility() { # Hidden index entries cannot establish work preservation through status.
  local listing record='' result=0
  listing=$(mktemp "${TMPDIR:-/tmp}/wt-index-flags.XXXXXX") || return 1
  wt_register_tmpfile "$listing"
  if ! preservation_git -C "$1" ls-files -v -z >"$listing"; then rm -f "$listing"; return 1; fi
  while IFS= read -r -d '' record; do
    if [[ ${record:1:1} != ' ' || ${record:0:1} != [HMRCKU?] ]]; then result=1; break; fi
  done <"$listing"
  [[ -z $record ]] || result=1
  rm -f "$listing"
  if [[ $result != 0 ]]; then warn 'Git index flags can hide tracked changes; inspect assume-unchanged and skip-worktree entries'; fi
  return "$result"
}

porcelain_paths() { # porcelain_paths <checkout> — one path per line for every entry `git status` reports.
  # Use -z, because without it a path with a space in it comes back quoted, and this list is compared by
  # exact string. A rename or copy emits its source as a second record. The loop reads that record and drops
  # it: the destination is the dirty path, and the source no longer exists to hash.
  local p="$1" rec f path_error=0
  local listing
  index_visibility "$p" || return 1
  listing=$(mktemp "${TMPDIR:-/tmp}/wt-status.XXXXXX") || return 1
  wt_register_tmpfile "$listing"
  if ! preservation_git -C "$p" -c core.fsmonitor=false status --porcelain -z --untracked-files=all --ignore-submodules=none >"$listing" 2>/dev/null; then rm -f "$listing"; return 1; fi
  while IFS= read -r -d '' rec; do
    if [[ ${rec:2:1} != ' ' || ! ${rec:0:2} =~ ^[\ MADRCUT?!]{2}$ ]]; then path_error=1; break; fi
    f="${rec:3}"
    if [[ $f == *$'\n'* ]]; then path_error=1; break; fi
    case "${rec:0:2}" in R*|C*) IFS= read -r -d '' _src || { path_error=1; break; } ;; esac
    if [[ -n "$f" ]]; then printf '%s\n' "$f"; fi
  done <"$listing"
  [[ -z $rec ]] || path_error=1
  rm -f "$listing"
  [[ $path_error == 0 ]]
}

setup_dirt() { # setup_dirt <worktree path> — what .wt-setup left in git's way, as "<path>:<fingerprint>" lines.
  # wt calls this only immediately after the hook ran, so what it finds is the hook's own output and nobody
  # else's. This record exists for the same reason that copy_includes records a hash. With it, rm can tell
  # the work a human did inside the worktree from the state that the worktree was born with. A `.wt-setup`
  # that runs `uv sync` or `npm ci` rewrites a TRACKED lockfile. Without this record, `git status` is dirty
  # from birth, and every `wt rm` refuses for the worktree's whole life. The only way to clean up is then
  # --force, which also discards the unmerged-commit check. Ignored files never reach here: `status` does
  # not list them.
  local p="$1" f
  porcelain_paths "$p" | while IFS= read -r f; do
    printf '%s:%s\n' "$f" "$(work_file_hash "$p/$f")"      # a file the hook DELETED hashes to "", and matches as ""
  done
}

unexplained_dirt() { # unexplained_dirt <name> <path> — dirty paths that .wt-setup did not put there
  # A recorded path counts as explained only while it still holds exactly what the hook left. If someone
  # edits a recorded lockfile by hand, the hash stops matching, so the path is a reason again. Metadata
  # from before wt recorded this has no "setup" key. Then every path is unexplained, and the old refusal
  # stays unchanged.
  local n="$1" p="$2" recorded f h e explained
  meta_require "$n"
  # WT_COMPAT: Remove the missing setup key default when every sidecar records setup output.
  recorded=${WT_META[setup]-}
  local listing
  listing=$(porcelain_paths "$p") || return 1
  [[ -n "$recorded" ]] || { printf '%s' "$listing"; return 0; }
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    h=$(work_file_hash "$p/$f") || return 1
    explained=0
    if [[ -z $h && ( -e $p/$f || -L $p/$f ) ]]; then return 1; fi
    while IFS= read -r e; do
      if [[ -n "$e" && "${e%:*}" == "$f" && "${e##*:}" == "$h" ]]; then explained=1; break; fi
    done <<<"$recorded"
    if [[ $explained -eq 0 ]]; then printf '%s\n' "$f"; fi
  done <<<"$listing"
}

branch_pushed() { # branch_pushed <branch> — 0 only when the remote still has every commit of that branch.
  # Fetch the configured upstream into a private ref and verify actual commit containment.
  # A cached ref or a remote branch name alone cannot establish publication.
  local b="$1" remote upstream ref tip rc=1
  remote=$(preservation_git -C "$REPO" config "branch.$b.remote" 2>/dev/null) || return 1
  upstream=$(preservation_git -C "$REPO" config "branch.$b.merge" 2>/dev/null) || return 1
  [[ -n $remote && $upstream == refs/heads/* ]] || return 1
  ref="refs/wt/verify/$BASHPID-$RANDOM"
  warn "checking current remote commits for $b"
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
      preservation_git -C "$REPO" fetch -q --no-tags "$remote" "+$upstream:$ref" >/dev/null 2>&1; then
    tip=$(preservation_git -C "$REPO" rev-parse --verify "$ref^{commit}") || return 1
    preservation_git -C "$REPO" merge-base --is-ancestor "$b" "$tip" 2>/dev/null && rc=0
    preservation_git -C "$REPO" update-ref -d "$ref" "$tip" || return 1
  fi
  return "$rc"
}

git_merges_trees() { # 0 when this git has `merge-tree --write-tree` (2.38, September 2022). Ubuntu 22.04's
                     # apt git is 2.34, so a VM can be on either side; the answer is cached for the process.
  if [[ -z "${WT_MERGE_TREE:-}" ]]; then
    local v maj min; v=$(git version 2>/dev/null | awk '{print $3}'); maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
    WT_MERGE_TREE=0
    if [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] && { [[ $maj -gt 2 ]] || [[ $maj -eq 2 && $min -ge 38 ]]; }; then
      WT_MERGE_TREE=1
    fi
  fi
  [[ $WT_MERGE_TREE -eq 1 ]]
}

isolated_merge_tree() ( # Merge raw objects with built-in text semantics and no source configuration or attributes.
  local branch=$1 base=$2 ancestor=$3 mode=$4 comparison objects format keys key out tree base_tree count rc=0
  local proof_env=()
  objects=$(preservation_git -C "$REPO" rev-parse --path-format=absolute --git-path objects) || return 2
  [[ $objects == /* && $objects != *$'\n'* ]] || return 2
  format=$(preservation_git -C "$REPO" rev-parse --show-object-format) || return 2
  case $format in sha1|sha256) ;; *) return 2 ;; esac
  keys=$(git rev-parse --local-env-vars) || return 2
  while IFS= read -r key; do
    [[ $key =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 2
    proof_env+=(-u "$key")
  done <<<"$keys"
  proof_env+=(-u GIT_ATTR_SOURCE -u GIT_NAMESPACE GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null
    GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null)
  comparison=$(mktemp -d "${TMPDIR:-/tmp}/wt-merge-proof.XXXXXX") || return 2
  trap 'rm -rf -- "$comparison"' EXIT
  env "${proof_env[@]}" git init -q --bare --template= --initial-branch=proof --object-format="$format" "$comparison" || return 2
  mkdir -p "$comparison/info" "$comparison/objects/info" || return 2
  printf '%s\n' "$objects" >"$comparison/objects/info/alternates" || return 2
  printf '* merge\n' >"$comparison/info/attributes" || return 2
  isolated_git() {
    env "${proof_env[@]}" GIT_INDEX_FILE="$comparison/index" git --git-dir="$comparison" \
      -c core.attributesFile=/dev/null -c merge.renormalize=false "$@"
  }
  base_tree=$(isolated_git rev-parse "$base^{tree}") || return 2
  if [[ $mode == modern ]]; then
    out=$(isolated_git merge-tree --write-tree "$base" "$branch") || rc=$?
    case $rc in 0) tree=${out%%$'\n'*} ;; 1) return 1 ;; *) return 2 ;; esac
  else
    isolated_git read-tree -m -i --aggressive "$ancestor" "$base" "$branch" || return 3
    tree=$(isolated_git write-tree) || return 3
  fi
  [[ $tree =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && $base_tree =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 2
  count=$(isolated_git diff-tree -r --name-only -z "$base_tree" "$tree" | tr -cd '\000' | wc -c) || return 2
  count=${count//[[:space:]]/}
  [[ $count =~ ^[0-9]+$ ]] || return 2
  printf '%s\n%s\n%s\n' "$tree" "$base_tree" "$count"
)

branch_landed() { # branch_landed <branch> <base> <reason output>
  # Return 0 when every change since the branch left the base is in the base's tip.
  # This is the result of a squash merge. Set the reason output when the check fails.
  # A PR merged with GitHub's "squash and merge" (the default on most repos) lands as ONE new commit on
  # main. That commit's tree is the merge's tree, and the head branch is deleted. Nothing on wt/<name> is
  # then an ancestor of anything, and branch_pushed finds the remote branch gone. So the only way past
  # `wt rm` was --force, which also waives the dirty-tree and .wt-include checks. But that worktree had
  # nothing left to lose. This check tells that worktree apart from one that does have something to lose.
  #
  # The question it asks git is exact, not a heuristic: would a merge of the branch into the base's tip
  # change anything? A three-way merge looks at every region of every file. It takes the base's side where
  # only the base changed the region, and the branch's side where only the branch changed it. Where both made
  # the same change, it takes either side. So the merged tree equals the base's tree precisely when every
  # change that the branch made is already there. How it landed does not matter: by a squash, a rebase-merge,
  # a cherry-pick into another branch that then merged, or by hand.
  # branch_landed does NOT take these cases as landed:
  # - A change that the base later undid, for example a squash that was later reverted, in whole or in part.
  #   The merge would put it back, so the tree differs.
  # - A change that the base later edited again on the same lines. The merge conflicts.
  # - A commit whose change is not in the base at all: a commit pushed after the PR merged, or never merged.
  # Each of these cases is a refusal, and the refusal says which case it is.
  # A branch whose net change is empty (a commit undone by a later one on the same branch) passes the merge
  # trivially and proves nothing. So it is refused too, as it always was.
  #
  # `git merge-tree --write-tree` (2.38+) does the merge in memory, hunk by hunk. It does not touch any index
  # or working tree, and it exits 1 on conflicts. Older git gets `read-tree -m` into a throwaway index, which
  # merges file by file. There, a file that both sides changed is unmerged, whatever the hunks say. Then
  # `write-tree` refuses the unmerged index, which reads here as not landed. That path is stricter, and safe
  # in the same direction: either path calls a branch landed only when the merge would change nothing.
  local -n __landed_why=$3
  local __b="$1" __base="$2" __m __tree_b __tree_t="" __out __rc=0 __n __branch_oid __base_oid __mode=legacy __fields=()
  __landed_why=""
  __branch_oid=$(preservation_git -C "$REPO" rev-parse --verify "$__b^{commit}") || { __landed_why="cannot resolve $__b"; return 1; }
  __base_oid=$(preservation_git -C "$REPO" rev-parse --verify "$__base^{commit}") || { __landed_why="cannot resolve $__base"; return 1; }
  __m=$(preservation_git -C "$REPO" merge-base --all "$__branch_oid" "$__base_oid" 2>/dev/null) || { __landed_why="$__b has no common history with $__base"; return 1; }
  [[ $__m != *$'\n'* ]] || { __landed_why="multiple merge bases for $__b and $__base"; return 1; }
  preservation_git -C "$REPO" diff-tree --quiet "$__m" "$__branch_oid" 2>/dev/null || __rc=$?
  if [[ $__rc -eq 0 ]]; then
    __landed_why="the net change of $__b since $(preservation_git -C "$REPO" rev-parse --short "$__m") is empty, which proves nothing"; return 1
  fi
  [[ $__rc -eq 1 ]] || { __landed_why="git diff-tree could not compare $__b with $__base"; return 1; }
  __rc=0
  # WT_COMPAT: Remove the read-tree branch when every machine has Git 2.38 or later.
  if git_merges_trees; then __mode=modern; fi
  __out=$(isolated_merge_tree "$__branch_oid" "$__base_oid" "$__m" "$__mode" 2>/dev/null) || __rc=$?
  case $__rc in
    0) mapfile -t __fields <<<"$__out"
       [[ ${#__fields[@]} == 3 ]] || { __landed_why='invalid isolated merge result'; return 1; }
       __tree_t=${__fields[0]}; __tree_b=${__fields[1]}; __n=${__fields[2]} ;;
    1) __landed_why="merging $__b into $__base would conflict: $__base changed the same lines again"; return 1 ;;
    3)
      __landed_why="merging $__b into $__base would touch a file $__base changed since (git $(git version | awk '{print $3}') compares whole files; 2.38 compares hunks)"
       return 1 ;;
    *) __landed_why="git merge-tree could not compare $__b with $__base"; return 1 ;;
  esac
  [[ "$__tree_t" == "$__tree_b" ]] && return 0
  __landed_why="merging $__b into $__base would still change $__n path(s)"
  return 1
}

comparison_ref() { # Resolve a persistent ref or a pinned object. Revision expressions are not destinations.
  local -n __resolved=$3
  local __input=$1 __branch=$2 __symbol
  __resolved=''
  [[ $__input != HEAD ]] || return 1
  comparison_unambiguous "$__input" || return 1
  __symbol=$(preservation_git -C "$REPO" rev-parse --symbolic-full-name "$__input" 2>/dev/null) || __symbol=''
  if [[ $__symbol == refs/* && $__symbol != *$'\n'* ]]; then
    [[ $__symbol != "refs/heads/$__branch" ]] || return 1
    __resolved=$__symbol
  elif [[ $__input =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    __resolved=$(preservation_git -C "$REPO" rev-parse --verify "$__input^{commit}" 2>/dev/null) || return 1
  else
    local __candidate __remote_owner=''
    case $__input in refs/remotes/*) __candidate=$__input ;; refs/*) return 1 ;; */*) __candidate="refs/remotes/$__input" ;; *) return 1 ;; esac
    preservation_git -C "$REPO" check-ref-format "$__candidate" >/dev/null 2>&1 || return 1
    comparison_remote "$__candidate" __remote_owner || return 1
    __resolved=$__candidate
  fi
}

comparison_remote() { # Return 2 for local refs and 1 for an unknown or ambiguous remote mapping.
  local -n __owner=$2
  local __full=$1 __candidate __explicit __matches=()
  __owner=''
  [[ $__full == refs/remotes/* ]] || return 2
  while IFS= read -r __candidate; do
    [[ $__full != "refs/remotes/$__candidate/"* ]] || __matches+=("$__candidate")
  done <<<"$(preservation_git -C "$REPO" remote)"
  __explicit=$(preservation_git -C "$REPO" config --get wt.landingRemote 2>/dev/null || true)
  if [[ -z $__explicit && ${WT_META[metadata_version]:-0} == 3 ]]; then __explicit=${WT_META[landing_remote]-}; fi
  if [[ -n $__explicit ]]; then
    for __candidate in "${__matches[@]}"; do
      if [[ $__candidate == "$__explicit" ]]; then __owner=$__candidate; return 0; fi
    done
  fi
  ((${#__matches[@]} == 1)) || return 1
  __owner=${__matches[0]}
}

declare -A WT_BASE_FETCHES=()
# The coordinator preserves notice state when prune starts isolated removal workers.
WT_BASE_FETCH_NOTIFIED=${WT_BASE_FETCH_NOTIFIED:-0}
fetch_base() { # Refresh the canonical remote ref. Return 2 for local evidence and 3 for an already refreshed ref.
  local base=$1 full='' remote='' rc=0 branch
  comparison_ref "$base" '' full || return 1
  comparison_remote "$full" remote || rc=$?
  [[ $rc != 2 ]] || return 2
  [[ $rc == 0 ]] || return 1
  case "${WT_BASE_FETCHES[$full]:-}" in ok) return 3 ;; failed) return 1 ;; esac
  branch=${full#refs/remotes/"$remote"/}
  # Freshness checks can clear fetch results; keep the notice separate for this command.
  if [[ $WT_BASE_FETCH_NOTIFIED == 0 ]]; then
    warn "fetching $base from $remote to verify current landing content"
    WT_BASE_FETCH_NOTIFIED=1
  fi
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
      preservation_git -C "$REPO" fetch -q --no-tags "$remote" "+refs/heads/$branch:$full" >/dev/null 2>&1; then
    WT_BASE_FETCHES[$full]=ok; return 0
  fi
  WT_BASE_FETCHES[$full]=failed; return 1
}

forget_base() {
  local full=''
  comparison_ref "$1" '' full || return 1
  WT_BASE_FETCHES[$full]=''
}

comparison_unambiguous() {
  local ref=$1 matches
  matches=$(preservation_git -C "$REPO" for-each-ref --format='%(refname)' -- "$ref" "refs/heads/$ref" "refs/remotes/$ref" "refs/tags/$ref") || return 1
  [[ $matches != *$'\n'* ]]
}

# Select a landing destination without changing the creation base or dependent sidecars.
# WT_RM_BASE and WT_RM_PROOF describe the verified removal decision.
# shellcheck disable=SC2034  # The removal caller consumes the preservation proof.
WT_RM_BASE='' WT_RM_PROOF=''
comparison_base() { # comparison_base <branch> <creation base> <output>
  local -n __effective=$3
  local __branch=$1 __saved=$2 __configured __remote __advertised __head __remotes
  __effective=$__saved
  [[ $__saved != HEAD && $__saved != "$__branch" && $__saved != "refs/heads/$__branch" ]] || return 1
  __configured=$(preservation_git -C "$REPO" config --get wt.landingRef 2>/dev/null || true)
  if [[ -n $__configured ]]; then __effective=$__configured
  elif [[ ${4:-} != landing ]] && preservation_git -C "$REPO" rev-parse -q --verify "$__saved^{commit}" >/dev/null 2>&1; then comparison_ref "$__effective" "$__branch" __canonical; return
  else
    if [[ -n ${WT_META[landing_ref]-} && -z ${WT_META[landing_remote]-} ]]; then
      __effective=${WT_META[landing_ref]}
      [[ $__effective != "$__branch" && $__effective != HEAD ]] || return 1
      comparison_ref "$__effective" "$__branch" __canonical
      return
    fi
    __remote=''
    [[ ${WT_META[metadata_version]:-0} != 3 ]] || __remote=${WT_META[landing_remote]-}
    [[ -n $__remote ]] || __remote=$(preservation_git -C "$REPO" config "branch.$__branch.remote" 2>/dev/null || true)
    if [[ -z $__remote ]]; then
      __remotes=$(preservation_git -C "$REPO" remote)
      [[ -n $__remotes && $__remotes != *$'\n'* ]] || return 1
      __remote=$__remotes
    fi
    [[ $__remote != . ]] || return 1
    if [[ ${4:-} == cached ]]; then
      __effective=$(preservation_git -C "$REPO" symbolic-ref -q --short "refs/remotes/$__remote/HEAD" 2>/dev/null) || return 1
      comparison_ref "$__effective" "$__branch" __canonical
      return
    fi
    __advertised=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
      preservation_git -C "$REPO" ls-remote --symref "$__remote" HEAD 2>/dev/null) || return 1
    __head=$(printf '%s\n' "$__advertised" | sed -n 's/^ref: refs\/heads\/\([^[:space:]]*\)[[:space:]]HEAD$/\1/p')
    [[ -n $__head && $__head != *$'\n'* ]] || return 1
    __effective="$__remote/$__head"
  fi
  comparison_ref "$__effective" "$__branch" __canonical
}

rm_reasons() { # rm_reasons <name> <path> <branch> <base> <reasons output array> [discard commits]
  # Every commit check is about the BRANCH, never the worktree's HEAD. Under `git bisect`, `git checkout <sha>`
  # or `--detach`, the HEAD is usually an ancestor of the base. A HEAD-based check then reads "clean, 0 ahead,
  # merged". But `branch -D` still destroys every commit that the branch holds, and its reflog too. $__b
  # resolves whether or not it is checked out. The worktree shares its refs with the main checkout, so ask
  # $REPO about it.
  local __discard_commits=${6:-0}
  local -n __reasons=$5
  local __n="$1" __p="$2" __b="$3" __base="$4" __dirty __ahead=0 __merged=0 __base_ok=0 __head_ref __f __why="" __rc __landed_reason
  meta_require "$__n"
  __reasons=()
  if ! task_admin_preserved "$__p"; then
    __reasons+=("cannot preserve private submodule Git data; kept the task registration")
  fi
  local __dirty_paths=''
  if [[ -d $__p ]]; then
    if ! filtered_files check "$__n" "$__p"; then
      __reasons+=("cannot preserve raw tracked files; inspect tracked bytes and submodule data before removal")
    fi
    if __dirty_paths=$(unexplained_dirt "$__n" "$__p"); then
      if [[ -n $__dirty_paths ]]; then
        __dirty=$(printf '%s\n' "$__dirty_paths" | wc -l | tr -d ' ')
        __reasons+=("$__dirty uncommitted change(s)")
      fi
    else __reasons+=("cannot enumerate working files"); fi
  fi
  # WT_COMPAT: Remove the literal HEAD refusal when every sidecar records a canonical creation base.
  WT_RM_BASE=$__base WT_RM_PROOF=''
  if [[ -d $__p ]] && ! git -C "$__p" status --porcelain -z >/dev/null 2>&1; then
    __reasons+=("cannot read worktree status")
  fi
  if ! preservation_git -C "$REPO" rev-parse -q --verify "$__b^{commit}" >/dev/null 2>&1; then
    __reasons+=("branch '$__b' cannot be resolved")
  fi
  if comparison_base "$__b" "$__base" WT_RM_BASE; then
    __base=$WT_RM_BASE
    if ! comparison_unambiguous "$__base"; then
      __reasons+=("comparison ref '$__base' is ambiguous")
      return 0
    fi
    fetch_base "$__base" && __rc=0 || __rc=$?
    if [[ $__rc -ne 1 ]] && preservation_git -C "$REPO" rev-parse -q --verify "$__base^{commit}" >/dev/null 2>&1; then
      __base_ok=1
      if ! __ahead=$(preservation_git -C "$REPO" rev-list --count "$__base..$__b" 2>/dev/null); then
        __reasons+=("git rev-list could not compare $__b with $__base")
        __ahead=0
      elif [[ ! $__ahead =~ ^[0-9]+$ ]]; then
        __reasons+=("git rev-list returned an invalid count")
        __ahead=0
      else
        __rc=0; preservation_git -C "$REPO" merge-base --is-ancestor "$__b" "$__base" 2>/dev/null || __rc=$?
        if [[ $__rc == 0 ]]; then __merged=1; WT_RM_PROOF=ancestry
        elif [[ $__rc != 1 ]]; then __reasons+=("git merge-base could not compare $__b with $__base")
        elif [[ $__discard_commits -eq 0 ]] && branch_landed "$__b" "$__base" __landed_reason; then
          __merged=1; WT_RM_PROOF=content
        else __why=" (${__landed_reason:-content not validated})"; fi
      fi
    else __why=" ($__base could not be refreshed from its remote)"
    fi
  fi
  # A retargeted child can retain a live or stale parent ref. Validate the complete stack at its root.
  if [[ $__merged -eq 0 && $__discard_commits -eq 0 && ( $__base_ok == 0 || $4 == wt/* || $4 == */wt/* ) ]]; then
    local __root_base=''
    if comparison_base "$__b" "$4" __root_base landing && [[ $__root_base != "$__base" ]] && comparison_unambiguous "$__root_base"; then
      fetch_base "$__root_base" && __rc=0 || __rc=$?
      if [[ $__rc != 1 ]] && preservation_git -C "$REPO" rev-parse -q --verify "$__root_base^{commit}" >/dev/null 2>&1; then
        __rc=0; preservation_git -C "$REPO" merge-base --is-ancestor "$__b" "$__root_base" 2>/dev/null || __rc=$?
        if [[ $__rc == 0 ]]; then __merged=1; WT_RM_PROOF=ancestry
        elif [[ $__rc != 1 ]]; then __reasons+=("git merge-base could not compare $__b with $__root_base")
        elif branch_landed "$__b" "$__root_base" __landed_reason; then __merged=1; WT_RM_PROOF=content; fi
        if [[ $__merged == 1 ]]; then __base=$__root_base; WT_RM_BASE=$__base; __base_ok=1; fi
      fi
    fi
  fi
  [[ $__base_ok -eq 1 ]] || __reasons+=("base '$__base' cannot be compared with $__b (gone, or the literal HEAD)$__why")
  if [[ $__base_ok == 1 && $__merged == 0 && $__ahead == 0 && $__discard_commits == 0 ]]; then
    __reasons+=("cannot establish a preservation proof for $__b")
  fi
  if [[ $__base_ok -eq 1 && $__ahead -gt 0 && $__merged -eq 0 && $__discard_commits -eq 0 ]]; then
    # shellcheck disable=SC2034  # The removal caller consumes this proof.
    if branch_pushed "$__b"; then WT_RM_PROOF=published
    else __reasons+=("$__ahead commit(s) on $__b not merged into $__base and not on a remote$__why"); fi
  fi
  # The checks above use $__b. A different HEAD adds a reason of its own.
  # Removing the worktree loses a state that no branch keeps, such as a bisect or detached checkout.
  if [[ -d "$__p" ]]; then
    __head_ref=$(git -C "$__p" symbolic-ref -q --short HEAD 2>/dev/null || true)
    if [[ -z "$__head_ref" ]]; then
      __reasons+=("HEAD is detached at $(git -C "$__p" rev-parse --short HEAD 2>/dev/null || echo '?') (bisect, or a detached checkout), not on $__b")
    elif [[ "$__head_ref" != "$__b" ]]; then __reasons+=("HEAD is on $__head_ref, not $__b"); fi
  fi
  local __includes=''
  if [[ -d $__p ]]; then
    if ! __includes=$(changed_includes "$__n" "$__p"); then
      __reasons+=("cannot enumerate included private files")
    else
      while IFS= read -r __f; do
        if [[ -n $__f ]]; then __reasons+=("$__f was edited or created inside the worktree (.wt-include, not in git)"); fi
      done <<<"$__includes"
    fi
  fi
  return 0
}
