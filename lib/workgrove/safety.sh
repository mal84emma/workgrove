# shellcheck shell=bash
# Reads globals: GIT_SSH_COMMAND, REPO, TMPDIR, WG_VERSION_ROOT, WT_BASE_FETCHES, WT_DIRNAME, WT_MERGE_TREE, WT_META, WT_TMPFILES.
file_hash() { # sha256 of a file, or "" when it cannot be read (the Mac has shasum, Linux sha256sum)
  local h=""
  if have shasum; then h=$(shasum -a 256 "$1" 2>/dev/null) || h=""
  elif have sha256sum; then h=$(sha256sum "$1" 2>/dev/null) || h=""
  else
    # shellcheck source=lib/workgrove/vm/python-runtime.sh
    source "$WG_VERSION_ROOT/lib/workgrove/vm/python-runtime.sh"
    h=$(wg_run_python -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null) || h=""
  fi
  printf '%s' "${h%% *}"
}

include_match() { # include_match <path relative to a checkout> — 0 when .wt-include covers it
  local f="$1" inc="$REPO/.wt-include" pat
  [[ -f "$inc" ]] || return 1
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    pat="${pat%%#*}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -z "$pat" ]] && continue
    pat="${pat#/}"; pat="${pat%/}"
    # shellcheck disable=SC2053
    if [[ "$f" == $pat || "$f" == $pat/* || "$(basename "$f")" == $pat ]]; then return 0; fi
  done < "$inc"
  return 1
}

copy_includes() { # copy gitignored files listed in .wt-include into the new worktree; prints "<path>:<sha256>"
  local dest="$1" f                       # the hash is of what was copied, so rm can tell a copy edited inside
  [[ -f "$REPO/.wt-include" ]] || return 0   # the worktree from a file changed in the main checkout since
  git -C "$REPO" ls-files --others --ignored --exclude-standard -z | while IFS= read -r -d '' f; do
    if [[ "$f" != "$WT_DIRNAME/"* ]] && include_match "$f"; then
      # errexit does not reach in here (a pipeline inside $( )), so catch a failed copy by hand. If the loop
      # printed a failed copy anyway, "includes" would record a file that the worktree does not have.
      mkdir -p "$dest/$(dirname "$f")"
      if cp -p "$REPO/$f" "$dest/$f"; then printf '%s:%s\n' "$f" "$(file_hash "$dest/$f")"
      else warn "could not copy $f into the worktree"; fi
    fi
  done
}

worktree_includes() { # worktree_includes <path> — ignored files inside the worktree that .wt-include covers
  local p="$1" f                          # today, whether or not they existed when the worktree was created
  [[ -f "$REPO/.wt-include" ]] || return 0
  git -C "$p" ls-files --others --ignored --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' f; do
    if [[ "$f" != "$WT_DIRNAME/"* ]] && include_match "$f"; then printf '%s\n' "$f"; fi
  done
}

changed_includes() { # changed_includes <name> <path> -> ignored files that removing the worktree would destroy
  # This protection cannot be a creation-time snapshot. So it reads the two sources below.
  # - The files recorded at `wt new`, compared with the hash of what was copied then. So rotating a secret in
  #   the main checkout does not make every existing worktree unremovable.
  # - Every ignored file that the patterns cover *now*. An .env.local that an agent wrote in the worktree is
  #   in no snapshot, and `worktree remove --force` deletes it without a warning.
  local n="$1" p="$2" f h e seen="" list
  meta_require "$n"
  list=$(printf '%s\n%s\n' "${WT_META[includes]-}" "$(worktree_includes "$p")")
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    f="${e%:*}"; h="${e##*:}"
    # WT_COMPAT: Remove when every sidecar records hashes for included files.
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || { f="$e"; h=""; }   # metadata from an older wt: plain names, no hash
    case "$seen" in *"|$f|"*) continue ;; esac          # recorded and still matching: judge it once
    seen="$seen|$f|"
    [[ -e "$p/$f" ]] || continue
    if [[ -n "$h" ]]; then
      [[ "$(file_hash "$p/$f")" == "$h" ]] || printf '%s\n' "$f"
    elif [[ -e "$REPO/$f" ]]; then
      cmp -s "$p/$f" "$REPO/$f" || printf '%s\n' "$f"   # no hash: the main checkout is all there is to compare with
    else
      printf '%s\n' "$f"                                # nothing anywhere else holds it
    fi
  done <<<"$list"
}

porcelain_paths() { # porcelain_paths <checkout> — one path per line for every entry `git status` reports.
  # Use -z, because without it a path with a space in it comes back quoted, and this list is compared by
  # exact string. A rename or copy emits its source as a second record. The loop reads that record and drops
  # it: the destination is the dirty path, and the source no longer exists to hash.
  local p="$1" rec f
  git -C "$p" status --porcelain -z 2>/dev/null | while IFS= read -r -d '' rec; do
    f="${rec:3}"
    case "${rec:0:2}" in R*|C*) IFS= read -r -d '' _src || true ;; esac
    if [[ -n "$f" ]]; then printf '%s\n' "$f"; fi
  done
}

setup_dirt() { # setup_dirt <worktree path> — what .wt-setup left in git's way, as "<path>:<sha256>" lines.
  # wt calls this only immediately after the hook ran, so what it finds is the hook's own output and nobody
  # else's. This record exists for the same reason that copy_includes records a hash. With it, rm can tell
  # the work a human did inside the worktree from the state that the worktree was born with. A `.wt-setup`
  # that runs `uv sync` or `npm ci` rewrites a TRACKED lockfile. Without this record, `git status` is dirty
  # from birth, and every `wt rm` refuses for the worktree's whole life. The only way to clean up is then
  # --force, which also discards the unmerged-commit check. Ignored files never reach here: `status` does
  # not list them.
  local p="$1" f
  porcelain_paths "$p" | while IFS= read -r f; do
    printf '%s:%s\n' "$f" "$(file_hash "$p/$f")"      # a file the hook DELETED hashes to "", and matches as ""
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
  [[ -n "$recorded" ]] || { porcelain_paths "$p"; return 0; }
  porcelain_paths "$p" | while IFS= read -r f; do
    h=$(file_hash "$p/$f"); explained=0
    while IFS= read -r e; do
      if [[ -n "$e" && "${e%:*}" == "$f" && "${e##*:}" == "$h" ]]; then explained=1; break; fi
    done <<<"$recorded"
    if [[ $explained -eq 0 ]]; then printf '%s\n' "$f"; fi
  done
}

branch_pushed() { # branch_pushed <branch> — 0 only when the remote still has every commit of that branch.
  # Fetch the configured upstream into a private ref and verify actual commit containment.
  # A cached ref or a remote branch name alone cannot establish publication.
  local b="$1" remote upstream ref tip rc=1
  remote=$(git -C "$REPO" config "branch.$b.remote" 2>/dev/null) || return 1
  upstream=$(git -C "$REPO" config "branch.$b.merge" 2>/dev/null) || return 1
  [[ -n $remote && $upstream == refs/heads/* ]] || return 1
  ref="refs/wt/verify/$BASHPID-$RANDOM"
  warn "checking current remote commits for $b"
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
      git -C "$REPO" fetch -q --no-tags "$remote" "+$upstream:$ref" >/dev/null 2>&1; then
    tip=$(git -C "$REPO" rev-parse --verify "$ref^{commit}") || return 1
    git -C "$REPO" merge-base --is-ancestor "$b" "$tip" 2>/dev/null && rc=0
    git -C "$REPO" update-ref -d "$ref" "$tip" || return 1
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
  local __b="$1" __base="$2" __m __tree_b __tree_t="" __out __rc=0 __n __idx
  __landed_why=""
  __m=$(git -C "$REPO" merge-base --all "$__b" "$__base" 2>/dev/null) || { __landed_why="$__b has no common history with $__base"; return 1; }
  [[ $__m != *$'\n'* ]] || { __landed_why="multiple merge bases for $__b and $__base"; return 1; }
  git -C "$REPO" diff-tree --quiet "$__m" "$__b" 2>/dev/null || __rc=$?
  if [[ $__rc -eq 0 ]]; then
    __landed_why="the net change of $__b since $(git -C "$REPO" rev-parse --short "$__m") is empty, which proves nothing"; return 1
  fi
  [[ $__rc -eq 1 ]] || { __landed_why="git diff-tree could not compare $__b with $__base"; return 1; }
  __rc=0
  __tree_b=$(git -C "$REPO" rev-parse "$__base^{tree}" 2>/dev/null) || { __landed_why="$__base has no tree"; return 1; }
  # WT_COMPAT: Remove the read-tree branch when every machine has Git 2.38 or later.
  if git_merges_trees; then
    __out=$(git -C "$REPO" merge-tree --write-tree "$__base" "$__b" 2>/dev/null) || __rc=$?
    case $__rc in
      0) __tree_t="${__out%%$'\n'*}" ;;
      1) __landed_why="merging $__b into $__base would conflict: $__base changed the same lines again"; return 1 ;;
      *) __landed_why="git merge-tree could not compare $__b with $__base"; return 1 ;;
    esac
  else
    # read-tree refuses an index file that is empty, so hand it a name that does not exist yet
    __idx=$(mktemp "${TMPDIR:-/tmp}/wt-index.XXXXXX") || { __landed_why="no temp file for a merge index"; return 1; }
    wt_register_tmpfile "$__idx"; rm -f "$__idx"
    if GIT_INDEX_FILE="$__idx" git -C "$REPO" read-tree -m -i --aggressive "$__m" "$__base" "$__b" >/dev/null 2>&1; then
      __tree_t=$(GIT_INDEX_FILE="$__idx" git -C "$REPO" write-tree 2>/dev/null) || __tree_t=""
    fi
    rm -f "$__idx"
    if [[ -z "$__tree_t" ]]; then
      __landed_why="merging $__b into $__base would touch a file $__base changed since (git $(git version | awk '{print $3}') compares whole files; 2.38 compares hunks)"
      return 1
    fi
  fi
  [[ "$__tree_t" == "$__tree_b" ]] && return 0
  __n=$(git -C "$REPO" diff-tree -r --name-only "$__tree_b" "$__tree_t" 2>/dev/null | wc -l | tr -d ' ')
  __landed_why="merging $__b into $__base would still change $__n path(s)"
  return 1
}

declare -A WT_BASE_FETCHES=()
fetch_base() { # fetch_base <base> — refresh a remote-tracking base such as origin/main. Returns:
               # 0 when it refreshed the base; 1 when the fetch failed (now, or earlier this run);
               # 2 when the base is not a remote's branch and there was nothing to do;
               # 3 when the base was already refreshed this run.
  # Refresh remote content before accepting cached success. A failed fetch cannot authorize removal.
  # Local branches need no network operation. Cache each refresh until the deletion-boundary check.
  local base="${1#refs/remotes/}" remote
  [[ "$base" == */* ]] || return 2
  remote="${base%%/*}"
  git -C "$REPO" remote 2>/dev/null | grep -xF "$remote" >/dev/null || return 2
  case "${WT_BASE_FETCHES[$base]:-}" in
    ok) return 3 ;;
    failed) return 1 ;;
  esac
  warn "fetching $base from $remote to verify current landing content"
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
       git -C "$REPO" fetch -q --no-tags "$remote" "+refs/heads/${base#*/}:refs/remotes/$base" >/dev/null 2>&1; then
    WT_BASE_FETCHES[$base]=ok; return 0
  fi
  WT_BASE_FETCHES[$base]=failed; return 1
}

comparison_unambiguous() {
  local ref=$1 matches
  matches=$(git -C "$REPO" for-each-ref --format='%(refname)' -- "$ref" "refs/heads/$ref" "refs/remotes/$ref" "refs/tags/$ref") || return 1
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
  __configured=$(git -C "$REPO" config --get wt.landingRef 2>/dev/null || true)
  if [[ -n $__configured ]]; then __effective=$__configured
  elif [[ ${4:-} != landing ]] && git -C "$REPO" rev-parse -q --verify "$__saved^{commit}" >/dev/null 2>&1; then return 0
  else
    if [[ -n ${WT_META[landing_ref]-} && -z ${WT_META[landing_remote]-} ]]; then
      __effective=${WT_META[landing_ref]}
      [[ $__effective != "$__branch" && $__effective != HEAD ]] || return 1
      git -C "$REPO" rev-parse -q --verify "$__effective^{commit}" >/dev/null 2>&1
      return
    fi
    __remote=${WT_META[landing_remote]-}
    [[ -n $__remote ]] || __remote=$(git -C "$REPO" config "branch.$__branch.remote" 2>/dev/null || true)
    if [[ -z $__remote ]]; then
      __remotes=$(git -C "$REPO" remote)
      [[ -n $__remotes && $__remotes != *$'\n'* ]] || return 1
      __remote=$__remotes
    fi
    [[ $__remote != . ]] || return 1
    if [[ ${4:-} == cached ]]; then
      __effective=$(git -C "$REPO" symbolic-ref -q --short "refs/remotes/$__remote/HEAD" 2>/dev/null) || return 1
      return 0
    fi
    __advertised=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
      git -C "$REPO" ls-remote --symref "$__remote" HEAD 2>/dev/null) || return 1
    __head=$(printf '%s\n' "$__advertised" | sed -n 's/^ref: refs\/heads\/\([^[:space:]]*\)[[:space:]]HEAD$/\1/p')
    [[ -n $__head && $__head != *$'\n'* ]] || return 1
    __effective="$__remote/$__head"
  fi
  [[ $__effective != HEAD && $__effective != "$__branch" && $__effective != "refs/heads/$__branch" ]] || return 1
  return 0
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
  __dirty=$(unexplained_dirt "$__n" "$__p" | wc -l | tr -d ' ')
  [[ "$__dirty" -gt 0 ]] && __reasons+=("$__dirty uncommitted change(s)")
  # WT_COMPAT: Remove the literal HEAD refusal when every sidecar records a canonical creation base.
  WT_RM_BASE=$__base WT_RM_PROOF=''
  if [[ -d $__p ]] && ! git -C "$__p" status --porcelain -z >/dev/null 2>&1; then
    __reasons+=("cannot read worktree status")
  fi
  if ! git -C "$REPO" rev-parse -q --verify "$__b^{commit}" >/dev/null 2>&1; then
    __reasons+=("branch '$__b' cannot be resolved")
  fi
  if comparison_base "$__b" "$__base" WT_RM_BASE; then
    __base=$WT_RM_BASE
    if ! comparison_unambiguous "$__base"; then
      __reasons+=("comparison ref '$__base' is ambiguous")
      return 0
    fi
    fetch_base "$__base" && __rc=0 || __rc=$?
    if [[ $__rc -ne 1 ]] && git -C "$REPO" rev-parse -q --verify "$__base^{commit}" >/dev/null 2>&1; then
      __base_ok=1
      if ! __ahead=$(git -C "$REPO" rev-list --count "$__base..$__b" 2>/dev/null); then
        __reasons+=("git rev-list could not compare $__b with $__base")
      elif [[ ! $__ahead =~ ^[0-9]+$ ]]; then
        __reasons+=("git rev-list returned an invalid count")
      elif git -C "$REPO" merge-base --is-ancestor "$__b" "$__base" 2>/dev/null; then
        __merged=1; WT_RM_PROOF=ancestry
      elif [[ $__discard_commits -eq 0 ]] && branch_landed "$__b" "$__base" __landed_reason; then
        __merged=1; WT_RM_PROOF=content
      else __why=" (${__landed_reason:-content not validated})"
      fi
    else __why=" ($__base could not be refreshed from its remote)"
    fi
  fi
  # A retargeted child can retain a live or stale parent ref. Validate the complete stack at its root.
  if [[ $__merged -eq 0 && $__discard_commits -eq 0 && ( $__base_ok == 0 || $4 == wt/* || $4 == */wt/* ) ]]; then
    local __root_base=''
    if comparison_base "$__b" "$4" __root_base landing && [[ $__root_base != "$__base" ]] && comparison_unambiguous "$__root_base"; then
      fetch_base "$__root_base" && __rc=0 || __rc=$?
      if [[ $__rc != 1 ]] && git -C "$REPO" rev-parse -q --verify "$__root_base^{commit}" >/dev/null 2>&1; then
        if git -C "$REPO" merge-base --is-ancestor "$__b" "$__root_base" 2>/dev/null; then
          __merged=1; WT_RM_PROOF=ancestry
        elif branch_landed "$__b" "$__root_base" __landed_reason; then
          __merged=1; WT_RM_PROOF=content
        fi
        if [[ $__merged == 1 ]]; then __base=$__root_base; WT_RM_BASE=$__base; __base_ok=1; fi
      fi
    fi
  fi
  [[ $__base_ok -eq 1 ]] || __reasons+=("base '$__base' cannot be compared with $__b (gone, or the literal HEAD)$__why")
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
  while IFS= read -r __f; do
    if [[ -n "$__f" ]]; then __reasons+=("$__f was edited or created inside the worktree (.wt-include, not in git)"); fi
  done <<<"$(changed_includes "$__n" "$__p")"
  return 0
}
