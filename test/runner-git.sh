# shellcheck shell=bash
# Resolve Apple's Git launcher once for test workers. Keep the caller's Git selection on every failure.

# runner_git_dir <os> <selected-git-path> <scratch-dir> prints an optional directory for PATH.
# The caller owns the scratch directory and removes it after all workers finish.
runner_git_dir() {
  local candidate selected_version candidate_version directory
  [[ $1 == Darwin && $2 == /usr/bin/git ]] || return 0
  candidate=$(xcrun --find git 2>/dev/null) || return 0
  [[ $candidate == /* && $candidate != /usr/bin/git && -f $candidate && -x $candidate ]] || return 0
  selected_version=$("$2" --version 2>/dev/null) || return 0
  candidate_version=$("$candidate" --version 2>/dev/null) || return 0
  [[ -n $selected_version && $selected_version == "$candidate_version" ]] || return 0
  # PATH cannot represent a directory whose name contains a colon.
  [[ $3 != *:* ]] || return 0
  directory=$3/git-bin
  mkdir "$directory" 2>/dev/null || return 0
  if ! ln -s "$candidate" "$directory/git" 2>/dev/null; then
    rmdir "$directory" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$directory"
}
