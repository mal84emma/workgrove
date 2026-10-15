# shellcheck shell=bash
file_hash() { # sha256 of a file, or "" when it cannot be read (the Mac has shasum, Linux sha256sum)
  local h=""
  if have shasum; then h=$(shasum -a 256 "$1" 2>/dev/null) || h=""
  elif have sha256sum; then h=$(sha256sum "$1" 2>/dev/null) || h=""
  else h=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null) || h=""
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
  list=$(printf '%s\n%s\n' "$(meta_get "$n" includes 2>/dev/null || true)" "$(worktree_includes "$p")")
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    f="${e%:*}"; h="${e##*:}"
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
  recorded=$(meta_get "$n" setup 2>/dev/null || true)
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
  # A remote-tracking ref is not proof. refs/remotes/origin/wt/x outlives the remote branch (an abandoned PR,
  # `git push origin :wt/x`, someone else's cleanup). The next fetch with fetch.prune then drops it, and
  # those commits become unreachable with no reflog. So ask the remote itself, and count an unreachable
  # remote as not pushed. Refusing while offline is the safe direction, and --force is one keystroke away.
  local b="$1" remote
  git -C "$REPO" rev-parse -q --verify "$b@{u}" >/dev/null 2>&1 || return 1
  [[ -z "$(git -C "$REPO" log "$b@{u}..$b" --oneline 2>/dev/null)" ]] || return 1
  remote=$(git -C "$REPO" config "branch.$b.remote" 2>/dev/null || true)
  [[ -n "$remote" ]] || return 1
  warn "asking $remote whether $b is still there (ctrl-c and use --force if it hangs)"
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
    git -C "$REPO" ls-remote --exit-code --heads "$remote" "refs/heads/$b" >/dev/null 2>&1
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

LANDED_WHY=""      # set by branch_landed when it says no: what it checked, for the refusal to repeat
branch_landed() { # branch_landed <branch> <base> — 0 when every change the branch made since it left the
                  # base is already in the base's tip, the shape a squash merge leaves behind.
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
  local b="$1" base="$2" m tree_b tree_t="" out rc=0 n idx
  LANDED_WHY=""
  m=$(git -C "$REPO" merge-base "$b" "$base" 2>/dev/null) || { LANDED_WHY="$b has no common history with $base"; return 1; }
  if git -C "$REPO" diff-tree --quiet "$m" "$b" 2>/dev/null; then
    LANDED_WHY="the net change of $b since $(git -C "$REPO" rev-parse --short "$m") is empty, which proves nothing"; return 1
  fi
  tree_b=$(git -C "$REPO" rev-parse "$base^{tree}" 2>/dev/null) || { LANDED_WHY="$base has no tree"; return 1; }
  if git_merges_trees; then
    out=$(git -C "$REPO" merge-tree --write-tree "$base" "$b" 2>/dev/null) || rc=$?
    case $rc in
      0) tree_t="${out%%$'\n'*}" ;;
      1) LANDED_WHY="merging $b into $base would conflict: $base changed the same lines again"; return 1 ;;
      *) LANDED_WHY="git merge-tree could not compare $b with $base"; return 1 ;;
    esac
  else
    # read-tree refuses an index file that is empty, so hand it a name that does not exist yet
    idx=$(mktemp "${TMPDIR:-/tmp}/wt-index.XXXXXX") || { LANDED_WHY="no temp file for a merge index"; return 1; }
    WT_TMPFILES+=("$idx"); rm -f "$idx"
    if GIT_INDEX_FILE="$idx" git -C "$REPO" read-tree -m -i --aggressive "$m" "$base" "$b" >/dev/null 2>&1; then
      tree_t=$(GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree 2>/dev/null) || tree_t=""
    fi
    rm -f "$idx"
    if [[ -z "$tree_t" ]]; then
      LANDED_WHY="merging $b into $base would touch a file $base changed since (git $(git version | awk '{print $3}') compares whole files; 2.38 compares hunks)"
      return 1
    fi
  fi
  [[ "$tree_t" == "$tree_b" ]] && return 0
  n=$(git -C "$REPO" diff-tree -r --name-only "$tree_b" "$tree_t" 2>/dev/null | wc -l | tr -d ' ')
  LANDED_WHY="merging $b into $base would still change $n path(s)"
  return 1
}

WT_FETCHED="${TMPDIR:-/tmp}/wt-fetched.$$"   # which bases fetch_base has tried this run; see there
fetch_base() { # fetch_base <base> — refresh a remote-tracking base such as origin/main. Returns:
               # 0 when it refreshed the base; 1 when the fetch failed (now, or earlier this run);
               # 2 when the base is not a remote's branch and there was nothing to do;
               # 3 when the base was already refreshed this run.
  # A squash merge lands on GitHub, and the next command typed is `wt rm`. Here, origin/main is whatever the
  # last fetch left, which is from before the merge, and branch_landed compares against that. So when the
  # offline checks say no and the base is a remote's branch, fetch that one branch and ask again. Offline,
  # the fetch fails quietly within the same 5-second ceiling that branch_pushed already accepts. The offline
  # verdict then stands, and the refusal says that the base could not be refreshed. A local base (`main`) is
  # never fetched.
  # Fetch once per run. `wt prune` asks rm_reasons about every worktree, and asks again through cmd_rm for
  # the ones it removes. Each time, it asks in a command substitution: a subshell, whose variables never
  # reach back. So the record of what was fetched is a file, named after this process and removed on exit.
  # cmd_rm and cmd_prune clear it before their first question, so a file that a killed run left behind
  # cannot answer.
  local base="$1" remote
  [[ "$base" == */* ]] || return 2
  remote="${base%%/*}"
  git -C "$REPO" remote 2>/dev/null | grep -qxF "$remote" || return 2
  if [[ -f "$WT_FETCHED" ]]; then
    grep -qxF "ok $base" "$WT_FETCHED" && return 3
    grep -qxF "failed $base" "$WT_FETCHED" && return 1
  fi
  warn "fetching $base from $remote to see whether the branch landed (ctrl-c and use --force if it hangs)"
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
       git -C "$REPO" fetch -q "$remote" "${base#*/}" >/dev/null 2>&1; then
    printf 'ok %s\n' "$base" >>"$WT_FETCHED"; return 0
  fi
  printf 'failed %s\n' "$base" >>"$WT_FETCHED"; return 1
}

reset_fetched() { # start the run's record of fetched bases afresh; the first of cmd_rm and cmd_prune to run does it
  if [[ $WT_FETCHED_RESET -eq 0 ]]; then rm -f "$WT_FETCHED"; WT_TMPFILES+=("$WT_FETCHED"); WT_FETCHED_RESET=1; fi
}
WT_FETCHED_RESET=0

RM_DISCARD_COMMITS=0   # `wt rm --discard-commits`: waive the unmerged-commit reason, and only that one
rm_reasons() { # rm_reasons <name> <path> <branch> <base> — why removing this worktree would destroy work,
               # one reason per line; nothing at all when there is nothing to lose. `wt rm` and `wt prune`
               # (dry run included) both read this, so the two can never disagree.
  # Every commit check is about the BRANCH, never the worktree's HEAD. Under `git bisect`, `git checkout <sha>`
  # or `--detach`, the HEAD is usually an ancestor of the base. A HEAD-based check then reads "clean, 0 ahead,
  # merged". But `branch -D` still destroys every commit that the branch holds, and its reflog too. $b
  # resolves whether or not it is checked out. The worktree shares its refs with the main checkout, so ask
  # $REPO about it.
  local n="$1" p="$2" b="$3" base="$4" dirty ahead=0 merged=0 base_ok=0 head_ref f why="" rc
  dirty=$(unexplained_dirt "$n" "$p" | wc -l | tr -d ' ')      # what .wt-setup itself wrote is not a reason
  [[ "$dirty" -gt 0 ]] && printf '%s uncommitted change(s)\n' "$dirty"
  # A base that no longer resolves fails both checks below, and each failure reads as "nothing to lose". The
  # literal HEAD (metadata from before wt canonicalized the base) resolves in every worktree to that
  # worktree's own tip, and reads the same way. So settle the base first, and make either case a refusal.
  if [[ "$base" != HEAD ]] && git -C "$REPO" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
    base_ok=1
    # merged means one of two things:
    # - the branch is an ancestor of the base (a merge commit, a fast-forward);
    # - all its work is in the base's tip without its commits (a squash merge; see branch_landed).
    # Check the second case offline first. Then, in case the merge is newer than the last fetch, refresh a
    # remote base and check once more. With --discard-commits, check neither: the reason is waived whatever
    # the answer, so there is nothing to go online for.
    if git -C "$REPO" merge-base --is-ancestor "$b" "$base" 2>/dev/null; then merged=1
    elif [[ $RM_DISCARD_COMMITS -eq 1 ]]; then merged=0
    elif branch_landed "$b" "$base"; then merged=1
    else
      why=" ($LANDED_WHY)"
      fetch_base "$base" && rc=0 || rc=$?
      if [[ $rc -eq 0 ]]; then
        if branch_landed "$b" "$base"; then merged=1; else why=" ($LANDED_WHY)"; fi
      elif [[ $rc -eq 1 ]]; then why=" ($LANDED_WHY; $base could not be refreshed from its remote)"
      fi
    fi
    ahead=$(git -C "$REPO" rev-list --count "$base..$b" 2>/dev/null || echo 0)
  fi
  [[ $base_ok -eq 1 ]] || printf "base '%s' cannot be compared with %s (gone, or the literal HEAD)\n" "$base" "$b"
  if [[ "$ahead" -gt 0 && $merged -eq 0 && $RM_DISCARD_COMMITS -eq 0 ]] && ! branch_pushed "$b"; then
    printf '%s commit(s) on %s not merged into %s and not on a remote%s\n' "$ahead" "$b" "$base" "$why"
  fi
  # The checks above are about $b, so a HEAD that is not $b is a reason of its own. The worktree then holds a
  # state (a bisect, a detached checkout) that no branch keeps, and removing the worktree throws it away.
  if [[ -d "$p" ]]; then
    head_ref=$(git -C "$p" symbolic-ref -q --short HEAD 2>/dev/null || true)
    if [[ -z "$head_ref" ]]; then printf 'HEAD is detached at %s (bisect, or a detached checkout), not on %s\n' \
        "$(git -C "$p" rev-parse --short HEAD 2>/dev/null || echo '?')" "$b"
    elif [[ "$head_ref" != "$b" ]]; then printf 'HEAD is on %s, not %s\n' "$head_ref" "$b"; fi
  fi
  while IFS= read -r f; do
    if [[ -n "$f" ]]; then printf '%s was edited or created inside the worktree (.wt-include, not in git)\n' "$f"; fi
  done <<<"$(changed_includes "$n" "$p")"
  return 0
}
