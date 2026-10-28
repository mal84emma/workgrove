# shellcheck shell=bash
# Reads globals: CMUX_ERROR, REPO, WG_LIB_DIR, WG_MACHINE_RESULT, WG_TEARDOWN_LOCK_FD,
#   WG_TEARDOWN_LOCK_PATH, WT_TEARDOWN_FILE, WT_TEARDOWN_JSON.
# Receipts survive the task directory and distinguish Git removal from session cleanup.
WT_TEARDOWN_FILE='' WT_TEARDOWN_JSON='' WG_TEARDOWN_CLOSE_PHASE=0
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

teardown_release() { # Release Git serialization before an external observer completes session cleanup.
  teardown_interpreter -c 'import fcntl,sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_UN)' "$WG_TEARDOWN_LOCK_FD" || die 'cannot release cleanup lock'
  WG_TEARDOWN_CLOSE_PHASE=1
}

teardown_save() { # teardown_save <stage>; flush the receipt before the next destructive operation.
  WT_TEARDOWN_JSON=$(jq -c --arg stage "$1" '.stage=$stage' <<<"$WT_TEARDOWN_JSON") || die 'cannot encode teardown receipt'
  teardown_interpreter -c '
import fcntl, json, os, sys, tempfile
path = sys.argv[1]
close_phase = sys.argv[2] == "1"
lock_fd = int(sys.argv[3])
if close_phase:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
data = json.load(sys.stdin)
if os.path.exists(path):
    with open(path) as previous:
        old = json.load(previous)
    if old.get("generation") != data.get("generation") and not (old.get("stage") == "complete" and data["stage"] == "prepared"):
        sys.exit("wt: cleanup generation changed; kept the newer receipt")
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
    if close_phase:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
' "$WT_TEARDOWN_FILE" "${WG_TEARDOWN_CLOSE_PHASE:-0}" "$WG_TEARDOWN_LOCK_FD" <<<"$WT_TEARDOWN_JSON" || die "cannot persist teardown receipt $WT_TEARDOWN_FILE"
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

teardown_observe() { # Observe absence only; this function never closes a row or deletes Git work.
  local name=$1 path=$2 branch=$3 keep=$4 row=$5 remote=$6 registrations current rc=0 rows
  [[ ! -e $path && ! -f $(wt_meta "$name") ]] || return 1
  registrations=$(git -C "$REPO" worktree list --porcelain) || return 1
  ! grep -qxF "worktree $path" <<<"$registrations" || return 1
  if [[ $keep == 0 ]]; then
    git -C "$REPO" show-ref -q --verify "refs/heads/$branch" && return 1
    rc=$?; [[ $rc == 1 ]] || return 1
  fi
  if [[ $remote == 1 ]]; then
    [[ ${row_closed:-0} == 1 || ( $(jq -r .workspace <<<"$WT_TEARDOWN_JSON") == 0 && $(jq -r .self <<<"$WT_TEARDOWN_JSON") == '' ) ]] || return 1
    current=$(task_tmux_identity "$(jq -r .session <<<"$WT_TEARDOWN_JSON")") && rc=0 || rc=$?
    [[ $rc == 1 ]] || return 1
  elif [[ -n $row ]]; then
    rows=$(rows_json checked) || return 1
    ! jq -e --arg row "$row" 'any(.workspaces[]; .id == $row)' <<<"$rows" >/dev/null || return 1
  fi
  teardown_save complete
}

teardown_finish() { # Complete only recorded cleanup. Never remove a new task with the same name.
  local name path branch head keep row self session native remote host title stage current rc=0
  name=$(jq -r .name <<<"$WT_TEARDOWN_JSON"); path=$(jq -r .path <<<"$WT_TEARDOWN_JSON")
  branch=$(jq -r .branch <<<"$WT_TEARDOWN_JSON"); head=$(jq -r .head <<<"$WT_TEARDOWN_JSON")
  keep=$(jq -r .keep <<<"$WT_TEARDOWN_JSON"); stage=$(jq -r .stage <<<"$WT_TEARDOWN_JSON")
  row=$(jq -r .row <<<"$WT_TEARDOWN_JSON"); remote=$(jq -r .remote <<<"$WT_TEARDOWN_JSON")
  if [[ ${observe_only:-0} == 1 ]]; then
    teardown_observe "$name" "$path" "$branch" "$keep" "$row" "$remote" || die 'cleanup absence cannot be verified'
    return 0
  fi
  if [[ ${row_closed:-0} == 1 && $remote != 1 ]]; then die 'row acknowledgment is only valid for VM cleanup'; fi
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
  teardown_release
  # Self-closure may kill this process before it can record a confirmed outcome.
  if [[ $remote == 1 ]]; then
    # shellcheck disable=SC2034  # tmux_agent writes the checked existence output.
    local identity='' identity_rc=0 saved_identity agent_rc=0 exists=false caller_session='' pane_pid=''
    identity=$(task_tmux_identity "$session") || identity_rc=$?
    [[ $identity_rc != 2 ]] || die 'cannot identify pending tmux cleanup; kept the session'
    saved_identity=$(jq -c '.tmux_identity // null' <<<"$WT_TEARDOWN_JSON")
    if [[ $identity_rc == 0 ]]; then
      [[ $(jq -cS . <<<"$identity") == $(jq -cS . <<<"$saved_identity") ]] || die 'tmux session identity changed; kept the replacement session'
    fi
    if [[ ${defer_close:-0} == 1 ]]; then
      tmux_agent "$session" exists >/dev/null || agent_rc=$?
      [[ $agent_rc == 1 ]] || die 'cannot defer cleanup of a running or unknown agent'
      printf 'Git cleanup complete; Mac controller must finish session cleanup\n'
      return 0
    fi
    if [[ ${row_closed:-0} == 1 ]]; then
      if [[ $identity_rc == 0 ]]; then
        tmux_recorded_owner "$session" "$name" "$(jq -c .tmux_owner <<<"$WT_TEARDOWN_JSON")" \
          || die 'another agent or command blocks recorded session cleanup'
        tmux kill-session -t "$(jq -r .id <<<"$identity")" || die 'could not stop the recorded tmux session'
        identity_rc=0; identity=$(task_tmux_identity "$session") || identity_rc=$?
        [[ $identity_rc == 1 ]] || die 'tmux session absence is unverified'
      fi
    elif [[ $identity_rc == 1 && $self == '' && $(jq -r .workspace <<<"$WT_TEARDOWN_JSON") == 0 ]]; then
      :
    else
      if [[ -n ${TMUX:-} && ${TMUX_PANE:-} =~ ^%[0-9]+$ ]]; then
        caller_session=$(tmux display-message -p -t "$TMUX_PANE" '#S') || return 1
        pane_pid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}') || return 1
      fi
      if [[ $identity_rc == 0 && $caller_session == "$session" ]] && process_descends "$BASHPID" "$pane_pid"; then
        tmux_self_ownership "$session" "$name" || die 'session ownership changed; cleanup remains pending'
        if [[ $native == 1 ]]; then
          tmux kill-session -t "$(jq -r .id <<<"$identity")" || rc=$?
        elif notify_mac wt-close host "$host" repo "$REPO" task "$name"; then
          local i wait_seconds=${WT_CLOSE_WAIT_SECONDS:-22}
          [[ $wait_seconds =~ ^[0-9]+$ ]] || wait_seconds=22
          for ((i=0; i<wait_seconds; i++)); do sleep 1; done
          rc=1
        else rc=1; fi
      else rc=1; fi
      if [[ $rc == 0 && $native == 1 ]]; then
        # A surviving caller cannot independently confirm that its Mac terminal closed.
        rc=1
      fi
      if [[ $rc != 0 ]]; then
        warn 'worktree removed, but its Mac row or tmux session is still open or unverified'
        warn "on the Mac: wt -H $host rm $name -r $(shell_join "$REPO")"
      fi
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
