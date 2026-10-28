# shellcheck shell=bash
# Reads globals: CMUX_ERROR, REPO, WG_LIB_DIR, WG_MACHINE_RESULT, WG_TEARDOWN_LOCK_FD,
#   WG_TEARDOWN_LOCK_PATH, WT_TEARDOWN_FILE, WT_TEARDOWN_JSON.
# Receipts survive the task directory and distinguish Git removal from session cleanup.
WT_TEARDOWN_FILE='' WT_TEARDOWN_JSON=''
teardown_interpreter() {
  # shellcheck source=lib/workgrove/vm/python-runtime.sh
  source "${BASH_SOURCE[0]%/*}/vm/python-runtime.sh" || return
  wg_run_python "$@"
}

teardown_lock() { # Hold an OS lock through a finite child command. Process death releases it automatically.
  local name=$1 lock_path="$REPO/.git/wt/teardown/$1.lock"
  shift
  if [[ ${WG_TEARDOWN_LOCK_PATH:-} == "$lock_path" && ${WG_TEARDOWN_LOCK_FD:-} =~ ^[0-9]+$ ]]; then
    teardown_interpreter -c '
import fcntl, os, sys
fd = int(sys.argv[1])
if not os.path.samestat(os.fstat(fd), os.stat(sys.argv[2])):
    sys.exit("wt: teardown lock identity changed")
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
' "$WG_TEARDOWN_LOCK_FD" "$lock_path" || die 'cannot validate inherited teardown lock'
    return 0
  fi
  local rc=0
  teardown_interpreter -c '
import fcntl, os, subprocess, sys
path, name, interpreter, script, machine = sys.argv[1:6]
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
try:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit("wt: teardown already runs for " + name)
    environment = dict(os.environ, WG_TEARDOWN_LOCK_FD=str(fd), WG_TEARDOWN_LOCK_PATH=path)
    if machine:
        environment["WT_MACHINE"] = machine
    result = subprocess.call([interpreter, script, "rm", *sys.argv[6:]], env=environment, pass_fds=(fd,))
    sys.exit(result if result >= 0 else 128 - result)
finally:
    os.close(fd)
' "$lock_path" "$name" "$BASH" "$WG_LIB_DIR/../../bin/wt" "${WG_MACHINE_RESULT:-}" "$@" || rc=$?
  exit "$rc"
}

teardown_save() { # teardown_save <stage>; flush the receipt before the next destructive operation.
  WT_TEARDOWN_JSON=$(jq -c --arg stage "$1" '.stage=$stage' <<<"$WT_TEARDOWN_JSON") || die 'cannot encode teardown receipt'
  teardown_interpreter -c '
import json, os, sys, tempfile
path = sys.argv[1]
data = json.load(sys.stdin)
parent = os.path.dirname(path)
os.makedirs(parent, mode=0o700, exist_ok=True)
fd, temporary = tempfile.mkstemp(dir=parent)
try:
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
' "$WT_TEARDOWN_FILE" <<<"$WT_TEARDOWN_JSON" || die "cannot persist teardown receipt $WT_TEARDOWN_FILE"
}

teardown_preflight() { # teardown_preflight <worktree path>
  local executable location root target hops commands=(git jq "$BASH")
  wg_select_python || die 'teardown requires Python 3.9 or later'
  commands+=("${wg_python}")
  if is_remote; then commands+=(tmux); else
    location=$(cmux_bin || true)
    [[ -z $location ]] || commands+=("$location")
  fi
  root=$(physical_dir "$1")
  for executable in "${commands[@]}"; do
    location=$(type -P "$executable") || die "teardown requires $executable"
    hops=0
    while [[ -L $location && $hops -lt 32 ]]; do
      target=$(readlink "$location") || die "cannot resolve $executable"
      case $target in /*) location=$target ;; *) location="${location%/*}/$target" ;; esac
      hops=$((hops + 1))
    done
    [[ ! -L $location ]] || die "cannot resolve $executable"
    location=$(cd "$(dirname "$location")" && printf '%s/%s' "$(pwd -P)" "${location##*/}")
    path_within "$location" "$root" && die "$executable is inside the worktree; use an installation outside it"
  done
  location=$(physical_dir "$WG_LIB_DIR")
  path_within "$location" "$root" && die 'wt libraries are inside the target worktree; use an installation outside it'
  return 0
}

teardown_finish() { # Complete only recorded cleanup. Never remove a new task with the same name.
  local name path branch head keep row self session native remote host title stage current rc=0
  name=$(jq -r .name <<<"$WT_TEARDOWN_JSON"); path=$(jq -r .path <<<"$WT_TEARDOWN_JSON")
  branch=$(jq -r .branch <<<"$WT_TEARDOWN_JSON"); head=$(jq -r .head <<<"$WT_TEARDOWN_JSON")
  keep=$(jq -r .keep <<<"$WT_TEARDOWN_JSON"); stage=$(jq -r .stage <<<"$WT_TEARDOWN_JSON")
  if [[ $stage == complete ]]; then printf 'teardown complete %s\n' "$name"; return 0; fi
  if [[ $stage == prepared ]]; then
    # An interrupted removal may have deleted the directory before updating its receipt.
    [[ ! -e $path ]] || die "teardown is prepared but the worktree remains; rerun normal removal"
    git -C "$REPO" worktree prune || die 'could not prune removed worktree'
  fi
  if [[ $stage == prepared || $stage == worktree_removed ]]; then
    local ref_rc=0
    git -C "$REPO" show-ref -q --verify "refs/heads/$branch" || ref_rc=$?
    case $ref_rc in
      0) current=$(git -C "$REPO" rev-parse --verify "refs/heads/$branch") || die 'cannot resolve remaining task branch' ;;
      1) current='' ;;
      *) die 'cannot inspect remaining task branch; cleanup remains pending' ;;
    esac
    if [[ $keep == 0 && -n $current ]]; then
      [[ $current == "$head" ]] || die "worktree removed, but $branch changed; kept branch and receipt $WT_TEARDOWN_FILE (retry with --keep-branch to preserve it)"
      local registrations
      registrations=$(git -C "$REPO" worktree list --porcelain) || die 'cannot check branch registrations'
      if grep -qxF "branch refs/heads/$branch" <<<"$registrations"; then die "branch $branch is checked out elsewhere; kept it"; fi
      git -C "$REPO" update-ref --no-deref -d "refs/heads/$branch" "$head" || die "worktree removed, but branch deletion failed; retry wt rm $name -r $(shell_join "$REPO")"
    fi
    if [[ -e $(wt_meta "$name") && $(file_hash "$(wt_meta "$name")") != $(jq -r .metadata_hash <<<"$WT_TEARDOWN_JSON") ]]; then
      die 'worktree removed, but task metadata changed; kept metadata and cleanup receipt'
    fi
    rm -f "$(wt_meta "$name")" "$(wt_prompt "$name")" "$(wt_started "$name")" || die 'worktree removed, but sidecar cleanup failed'
    teardown_save git_removed
    printf 'removed %s%s\n' "$name" "$(if [[ $keep == 1 ]]; then printf ' (branch %s kept)' "$branch"; fi)"
  fi
  row=$(jq -r .row <<<"$WT_TEARDOWN_JSON"); self=$(jq -r .self <<<"$WT_TEARDOWN_JSON")
  session=$(jq -r .session <<<"$WT_TEARDOWN_JSON"); native=$(jq -r .native <<<"$WT_TEARDOWN_JSON")
  remote=$(jq -r .remote <<<"$WT_TEARDOWN_JSON"); host=$(jq -r .host <<<"$WT_TEARDOWN_JSON")
  title=$(jq -r .title <<<"$WT_TEARDOWN_JSON")
  teardown_save close_requested
  # Self-closure may kill this process before it can record a confirmed outcome.
  if [[ $remote == 1 ]]; then
    if [[ $native == 1 ]]; then
      local caller_session='' pane_pid=''
      if [[ -n ${TMUX:-} && ${TMUX_PANE:-} =~ ^%[0-9]+$ ]]; then
        caller_session=$(tmux display-message -p -t "$TMUX_PANE" '#S') || return 1
        pane_pid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}') || return 1
      fi
      if [[ $caller_session != "$session" ]] || ! process_descends "$BASHPID" "$pane_pid"; then
        local agent_rc=0
        tmux_agent "$session" || agent_rc=$?
        [[ $agent_rc == 1 ]] || die 'cannot verify ownership of the pending native session; kept it'
      fi
      if [[ $caller_session == "$session" ]]; then
        tmux_self_ownership "$session" || die 'native session ownership changed; cleanup remains pending'
      fi
      tmux kill-session -t "=$session" || rc=$?
    elif [[ $self == remote ]]; then
      if notify_mac wt-close host "$host" repo "$REPO" task "$name"; then
        local i wait_seconds=${WT_CLOSE_WAIT_SECONDS:-22}
        [[ $wait_seconds =~ ^[0-9]+$ ]] || wait_seconds=22
        for ((i=0; i<wait_seconds; i++)); do sleep 1; done
      fi
      warn 'worktree removed, but its Mac row or tmux session is still open'
      rc=1
    else
      local agent_rc=0
      tmux_agent "$session" || agent_rc=$?
      case $agent_rc in
        0) die "another agent is running in tmux session $session; cleanup remains pending" ;;
        1) tmux kill-session -t "=$session" 2>/dev/null || true ;;
        *) die "cannot check tmux session $session; cleanup remains pending" ;;
      esac
    fi
  elif [[ -n $row ]]; then
    local checked_row='' checked_self=''
    check_row_removal "$title" "$REPO" checked_row checked_self '' "$path" || die "$CMUX_ERROR; cleanup remains pending in $WT_TEARDOWN_FILE"
    # A reused title must never redirect a saved cleanup operation.
    [[ -z $checked_row || $checked_row == "$row" ]] || die 'task row identity changed; cleanup remains pending'
    local existing_rows
    existing_rows=$(rows_json checked) || die 'cannot verify saved row absence; cleanup remains pending'
    if [[ -z $checked_row ]] && jq -e --arg id "$row" 'any(.workspaces[]; .id == $id)' <<<"$existing_rows" >/dev/null; then
      die 'saved row still exists with changed identity; cleanup remains pending'
    fi
    if [[ -n $checked_row ]]; then
      close_row "$row" "$checked_self" || { warn "$CMUX_ERROR"; rc=1; }
      if [[ $rc == 0 ]]; then
        local rows
        rows=$(rows_json checked) || rc=1
        if [[ $rc == 0 ]] && jq -e --arg id "$row" 'any(.workspaces[]; .id == $id)' <<<"$rows" >/dev/null; then rc=1; fi
      fi
    fi
  fi
  if [[ $rc != 0 ]]; then
    warn "Git cleanup completed; session cleanup is pending. Retry: wt rm $name -r $(shell_join "$REPO")"
    warn "receipt: $WT_TEARDOWN_FILE"
    return 1
  fi
  teardown_save complete
  printf 'teardown complete %s\n' "$name"
}
