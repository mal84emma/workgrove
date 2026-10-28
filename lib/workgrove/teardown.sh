# shellcheck shell=bash
# Reads globals: CMUX_ERROR, REPO, WG_LIB_DIR, WG_MACHINE_RESULT, WG_TEARDOWN_CONTROL_FD, WG_TEARDOWN_WORKER_PID,
#   WG_TEARDOWN_LOCK_PATH, WT_TEARDOWN_FILE, WT_TEARDOWN_JSON.
# Receipts survive the task directory and distinguish Git removal from session cleanup.
WT_TEARDOWN_FILE='' WT_TEARDOWN_JSON='' WG_TEARDOWN_CLOSE_PHASE=0
teardown_interpreter() {
  # shellcheck source=lib/workgrove/vm/python-runtime.sh
  source "${BASH_SOURCE[0]%/*}/vm/python-runtime.sh" || return
  wg_run_python "$@"
}

teardown_control() {
  teardown_interpreter -c '
import json, socket, sys
channel = socket.socket(fileno=int(sys.argv[1]))
channel.sendall((json.dumps({"op":sys.argv[2],"path":sys.argv[3]}) + "\n").encode())
reply = b""
while not reply.endswith(b"\n") and len(reply) < 16384:
    part = channel.recv(4096)
    if not part:
        sys.exit("wt: teardown coordinator exited")
    reply += part
if reply != b"ok\n":
    sys.exit("wt: " + reply.decode().strip())
' "$WG_TEARDOWN_CONTROL_FD" "$1" "$WG_TEARDOWN_LOCK_PATH"
}

teardown_lock() { # Only the finite coordinator holds the lock descriptor; commands inherit a control channel.
  local name=$1 lock_path="$REPO/.git/wt/teardown/$1.lock"
  shift
  if [[ ${WG_TEARDOWN_LOCK_PATH:-} == "$lock_path" && ${WG_TEARDOWN_WORKER_PID:-} == "$BASHPID" ]]; then
    teardown_control acquire || die 'cannot validate teardown coordinator'
    return 0
  fi
  local rc=0
  # shellcheck disable=SC2016  # The worker shell expands its own PID and arguments.
  teardown_interpreter -c '
import fcntl, json, os, select, signal, socket, subprocess, sys, time
path, name, interpreter, script, machine = sys.argv[1:6]
prior = os.environ.get("WG_TEARDOWN_CONTROL_FD", "")
if prior.isdigit():
    try:
        os.close(int(prior))
    except OSError:
        pass
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
parent, worker = socket.socketpair()
child = None
held = False
def worker_exited():
    state = subprocess.check_output(["ps", "-p", str(child.pid), "-o", "stat="], text=True).strip()
    return state.startswith("Z")
def group_inactive(group):
    listing = subprocess.check_output(["ps", "-axo", "pgid=,stat="], text=True)
    for line in listing.splitlines():
        pgid, state = line.split()
        if int(pgid) == group and not state.startswith("Z"):
            return False
    return True
def process_start(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], text=True, stdout=subprocess.PIPE, env=dict(os.environ, LC_ALL="C"))
    if result.returncode not in (0, 1):
        raise RuntimeError("cannot inspect recorded teardown process")
    return result.stdout.strip()
boot = process_start(1)
if not boot:
    sys.exit("wt: cannot identify the current boot")
def acquire():
    global held
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    previous = os.pread(fd, 4096, 0)
    if previous:
        owner = json.loads(previous)
        if not isinstance(owner, dict) or type(owner.get("group")) is not int or owner["group"] <= 1:
            raise ValueError("invalid teardown lock owner")
        for key in ("start", "boot"):
            if key in owner and (not isinstance(owner[key], str) or not owner[key].strip() or "\n" in owner[key]):
                raise ValueError("invalid teardown lock owner")
        group = owner["group"]
        start = process_start(group)
        same_boot = owner.get("boot", boot) == boot
        same_owner = not start or "start" not in owner or owner["start"] == start
        if same_boot and same_owner and not group_inactive(group):
            fcntl.flock(fd, fcntl.LOCK_UN)
            raise ValueError("previous teardown commands are still running")
    held = True
def record(group=None):
    os.ftruncate(fd, 0)
    if group is not None:
        start = process_start(group)
        if not start:
            raise RuntimeError("cannot identify teardown command group")
        os.pwrite(fd, json.dumps({"group":group,"start":start,"boot":boot}).encode(), 0)
    os.fsync(fd)
def stop_worker():
    if not group_inactive(child.pid):
        os.killpg(child.pid, signal.SIGKILL)
    for _ in range(500):
        if group_inactive(child.pid):
            return child.wait()
        time.sleep(0.01)
    raise RuntimeError("teardown commands have not stopped; cleanup remains pending")
try:
    try:
        acquire()
    except BlockingIOError:
        sys.exit("wt: teardown already runs for " + name)
    environment = dict(os.environ, WG_TEARDOWN_CONTROL_FD=str(worker.fileno()), WG_TEARDOWN_LOCK_PATH=path,
                       WG_TEARDOWN_ORIGIN_PID=str(os.getppid()))
    if machine:
        environment["WT_MACHINE"] = machine
    child = subprocess.Popen([interpreter, "-c", "export WG_TEARDOWN_WORKER_PID=$BASHPID; exec \"$@\"", "worker",
                              interpreter, script, "rm", *sys.argv[6:]], env=environment,
                             pass_fds=(worker.fileno(),), start_new_session=True)
    record(child.pid)
    worker.close()
    def forward(signum, frame):
        if not group_inactive(child.pid):
            os.killpg(child.pid, signum)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, forward)
    buffer = b""
    while True:
        ready, _, _ = select.select([parent], [], [], 0.05)
        if not ready:
            if worker_exited():
                break
            continue
        part = parent.recv(4096)
        if not part:
            break
        buffer += part
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            answer = "ok"
            try:
                request = json.loads(line)
                if request.get("path") != path:
                    raise ValueError("teardown lock identity changed")
                operation = request.get("op")
                if operation == "acquire":
                    if not held:
                        acquire()
                        record(child.pid)
                elif operation == "release":
                    record()
                    fcntl.flock(fd, fcntl.LOCK_UN)
                    held = False
                elif operation != "check" or not held:
                    raise ValueError("teardown lock is not held")
            except (ValueError, OSError) as error:
                answer = str(error)
            parent.sendall((answer + "\n").encode())
        if len(buffer) > 16384:
            raise ValueError("invalid teardown control message")
    result = stop_worker()
    sys.exit(result if result >= 0 else 128 - result)
finally:
    if child is not None and child.returncode is None:
        stop_worker()
    if held:
        record()
        fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
    parent.close()
    worker.close()
' "$lock_path" "$name" "$BASH" "$WG_LIB_DIR/../../bin/wt" "${WG_MACHINE_RESULT:-}" "$@" || rc=$?
  exit "$rc"
}

teardown_release() { # Permit an independent observer after all Git cleanup has finished.
  teardown_control release || die 'cannot release cleanup lock'
  WG_TEARDOWN_CLOSE_PHASE=1
}

teardown_save() { # teardown_save <stage>; flush the receipt before the next destructive operation.
  WT_TEARDOWN_JSON=$(jq -c --arg stage "$1" '.stage=$stage' <<<"$WT_TEARDOWN_JSON") || die 'cannot encode teardown receipt'
  if [[ ${WG_TEARDOWN_CLOSE_PHASE:-0} == 1 ]]; then teardown_control acquire; else teardown_control check; fi \
    || die 'teardown lock is unavailable'
  teardown_interpreter -c '
import json, os, sys, tempfile
path = sys.argv[1]
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
' "$WT_TEARDOWN_FILE" <<<"$WT_TEARDOWN_JSON" || die "cannot persist teardown receipt $WT_TEARDOWN_FILE"
  if [[ ${WG_TEARDOWN_CLOSE_PHASE:-0} == 1 ]]; then teardown_control release || die 'cannot release receipt lock'; fi
}

teardown_preflight() { # teardown_preflight <worktree path>
  local executable location root target parent hops commands=(git jq "$BASH" rm ps uname env cat grep basename dirname sed tr readlink mktemp pgrep sleep awk od)
  if have shasum; then commands+=(shasum); elif have sha256sum; then commands+=(sha256sum); fi
  if have cmux-tui; then commands+=(cmux-tui); fi
  wg_select_python || die 'teardown requires Python 3.9 or later'
  commands+=("${wg_python}")
  if is_remote; then commands+=(tmux); else
    location=$(cmux_bin || true)
    [[ -z $location ]] || commands+=("$location")
  fi
  root=$(physical_dir "$1")
  for executable in "${commands[@]}"; do
    location=$(type -P "$executable") || die "teardown requires $executable"
    path_within "$location" "$root" && die "$executable is inside the worktree; use an installation outside it"
    parent=${location%/*}; [[ $parent != "$location" ]] || parent=.
    target=$(cd "$parent" && printf '%s/%s' "$(pwd -P)" "${location##*/}")
    path_within "$target" "$root" && die "$executable is inside the worktree; use an installation outside it"
    location=$target
    hops=0
    while [[ -L $location && $hops -lt 32 ]]; do
      target=$(readlink "$location") || die "cannot resolve $executable"
      case $target in /*) location=$target ;; *) location="${location%/*}/$target" ;; esac
      hops=$((hops + 1))
    done
    [[ ! -L $location ]] || die "cannot resolve $executable"
    parent=${location%/*}; [[ $parent != "$location" ]] || parent=.
    location=$(cd "$parent" && printf '%s/%s' "$(pwd -P)" "${location##*/}")
    path_within "$location" "$root" && die "$executable is inside the worktree; use an installation outside it"
  done
  location=$(physical_dir "$WG_LIB_DIR")
  path_within "$location" "$root" && die 'wt libraries are inside the target worktree; use an installation outside it'
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" probe || die 'kernel task command identities are unavailable; kept the task'
  return 0
}

teardown_commands_observe() {
  local manifest generation self
  manifest=$(jq -c 'if has("commands") then .commands else null end' <<<"$WT_TEARDOWN_JSON") || return 1
  if [[ $manifest == null ]]; then
    self=$(jq -r .self <<<"$WT_TEARDOWN_JSON")
    [[ $self == '' ]]
    return
  fi
  generation=$(jq -r .generation <<<"$WT_TEARDOWN_JSON")
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" observe "$generation" <<<"$manifest"
}

teardown_commands_stop() {
  local manifest generation
  manifest=$(jq -c 'if has("commands") then .commands else null end' <<<"$WT_TEARDOWN_JSON") || return 1
  [[ $manifest != null ]] || { teardown_commands_observe; return; }
  generation=$(jq -r .generation <<<"$WT_TEARDOWN_JSON")
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" stop "$generation" "$1" <<<"$manifest"
}

teardown_commands_capture() { # Stop proven task commands before the last work-preservation check.
  local root=$1 start=$2 observers=${3:-[]} generation manifest refreshed stage
  generation=$(jq -r .generation <<<"$WT_TEARDOWN_JSON")
  manifest=$(jq -c 'if has("commands") then .commands else null end' <<<"$WT_TEARDOWN_JSON") || return 1
  stage=$(jq -r .stage <<<"$WT_TEARDOWN_JSON")
  refreshed=$(teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" capture "$generation" "$root" "$start" \
    "$WG_TEARDOWN_ORIGIN_PID" "$observers" <<<"$manifest") || return 1
  WT_TEARDOWN_JSON=$(jq -c --argjson commands "$refreshed" '.commands=$commands' <<<"$WT_TEARDOWN_JSON") || return 1
  teardown_save "$stage"
  teardown_commands_stop commands
}

teardown_preservation() { # Recheck the frozen proof before deleting the remaining branch.
  local name=$1 branch=$2 head=$3 proof base expected current canonical='' rc=0 retained
  proof=$(jq -r .proof <<<"$WT_TEARDOWN_JSON")
  base=$(jq -r .base <<<"$WT_TEARDOWN_JSON")
  [[ $proof != discard ]] || return 0
  case $proof in ancestry|content|published) ;; *) return 1 ;; esac
  if [[ $proof == published || $base =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    retained="refs/wt/preserved/$(jq -r .generation <<<"$WT_TEARDOWN_JSON")"
    git -C "$REPO" check-ref-format "$retained" >/dev/null 2>&1 || return 1
    git -C "$REPO" symbolic-ref -q "$retained" >/dev/null 2>&1 && return 1
    [[ $? == 1 ]] || return 1
    current=$(preservation_git -C "$REPO" rev-parse -q --verify "$retained^{commit}") || return 1
    [[ $current == "$head" ]]
    return
  fi
  meta_require "$name"
  comparison_ref "$base" "$branch" canonical || return 1
  forget_base "$base" || return 1
  fetch_base "$base" || rc=$?
  [[ $rc != 1 ]] || return 1
  expected=$(jq -r .base_object <<<"$WT_TEARDOWN_JSON")
  current=$(preservation_git -C "$REPO" rev-parse -q --verify "$canonical^{commit}") || return 1
  [[ $current == "$expected" ]]
}

teardown_sidecars_snapshot() {
  local metadata prompt started
  metadata=$(metadata_fingerprint "$(wt_meta "$1")") || return 1
  prompt=$(metadata_fingerprint "$(wt_prompt "$1")") || return 1
  started=$(metadata_fingerprint "$(wt_started "$1")") || return 1
  jq -cn --arg metadata "$metadata" --arg prompt "$prompt" --arg started "$started" '$ARGS.named'
}

teardown_remove_registration() { # One task's recovery must never prune another task's registration.
  local path=$1 listing registered
  task_admin_preserved "$path" || return 1
  listing=$(git -C "$REPO" -c core.quotePath=true worktree list --porcelain) || return 1
  registered=$(teardown_interpreter -c '
import ast, os, sys
target = os.fsencode(sys.argv[1])
if b"\n" in target:
    sys.exit("wt: cannot safely inspect a multiline worktree path")
found = False
for line in sys.stdin.buffer.read().split(b"\n"):
    if not line.startswith(b"worktree "):
        continue
    path = line[len(b"worktree "):]
    if path.startswith(b"\""):
        path = ast.literal_eval("b" + path.decode("ascii"))
    if not isinstance(path, bytes):
        sys.exit("wt: invalid worktree path record")
    found |= path == target
print("present" if found else "absent")
' "$path" <<<"$listing") || return 1
  if [[ $registered == present ]]; then git -C "$REPO" worktree remove --force "$path"
  else [[ ! -e $path && ! -L $path ]]; fi
}

teardown_sidecars_check() { # Absence is valid only after durable sidecar-removal intent.
  local name=$1 snapshot=$2 allow_absent=${3:-0} key path expected current
  for key in metadata prompt started; do
    case $key in metadata) path=$(wt_meta "$name") ;; prompt) path=$(wt_prompt "$name") ;; started) path=$(wt_started "$name") ;; esac
    expected=$(jq -er --arg key "$key" '.[$key] | select(type == "string")' <<<"$snapshot") || return 1
    [[ $expected == absent || $expected =~ ^[0-9a-f]{64}$ ]] || return 1
    current=$(metadata_fingerprint "$path") || return 1
    [[ $allow_absent != 1 || $current != absent ]] || continue
    [[ $current == "$expected" ]] || return 1
  done
}

teardown_observe() { # Observe absence only; this function never closes a row or deletes Git work.
  local name=$1 path=$2 branch=$3 keep=$4 row=$5 remote=$6 registrations current rc=0 rows
  [[ ! -e $path && ! -L $path ]] || return 1
  [[ ! -e $REPO/.git/wt/teardown/$name.branch-locks && ! -L $REPO/.git/wt/teardown/$name.branch-locks ]] || return 1
  [[ $(teardown_sidecars_snapshot "$name") == '{"metadata":"absent","prompt":"absent","started":"absent"}' ]] || return 1
  task_admin_preserved "$path" || return 1
  teardown_commands_observe || return 1
  registrations=$(git -C "$REPO" worktree list --porcelain) || return 1
  ! grep -qxF "worktree $path" <<<"$registrations" || return 1
  if [[ $keep == 0 ]]; then
    git -C "$REPO" show-ref -q --verify "refs/heads/$branch" && return 1
    rc=$?; [[ $rc == 1 ]] || return 1
    [[ $(teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/branch_config.py" snapshot "$REPO" "$branch") == '""' ]] || return 1
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
  if [[ $stage == complete ]]; then
    teardown_commands_observe || die 'task commands remain active or unverified; cleanup is pending'
    printf 'teardown complete %s\n' "$name"; return 0
  fi
  task_admin_preserved "$path" || die 'private submodule Git data prevents cleanup; kept the task registration'
  if [[ $stage == prepared ]]; then
    # An interrupted removal may have deleted the directory before updating its receipt.
    [[ ! -e $path ]] || die "teardown is prepared but the worktree remains; rerun normal removal"
    teardown_remove_registration "$path" || die 'could not remove the recorded task registration'
  fi
  if [[ $stage == prepared || $stage == worktree_removed ]]; then
    local ref_rc=0
    git -C "$REPO" show-ref -q --verify "refs/heads/$branch" || ref_rc=$?
    case $ref_rc in
      0) current=$(preservation_git -C "$REPO" rev-parse --verify "refs/heads/$branch") || die 'cannot resolve remaining task branch' ;;
      1) current='' ;;
      *) die 'cannot inspect remaining task branch; cleanup remains pending' ;;
    esac
    [[ $(metadata_fingerprint "$(wt_meta "$name")") == $(jq -r .metadata_hash <<<"$WT_TEARDOWN_JSON") ]] \
      || die 'task metadata changed before branch removal; kept the branch and metadata'
    if [[ $keep == 0 && -n $current ]]; then
      [[ $current == "$head" ]] || die "worktree removed, but $branch changed; kept branch and receipt $WT_TEARDOWN_FILE (retry with --keep-branch to preserve it)"
      local registrations
      registrations=$(git -C "$REPO" worktree list --porcelain) || die 'cannot check branch registrations'
      if grep -qxF "branch refs/heads/$branch" <<<"$registrations"; then die "branch $branch is checked out elsewhere; kept it"; fi
      teardown_preservation "$name" "$branch" "$head" || die 'preservation evidence changed; kept branch and metadata (retry with --keep-branch to preserve it)'
      [[ $(metadata_fingerprint "$(wt_meta "$name")") == $(jq -r .metadata_hash <<<"$WT_TEARDOWN_JSON") ]] \
        || die 'task metadata changed before branch removal; kept the branch and metadata'
      teardown_control check || die 'teardown coordinator exited before branch removal'
      git -C "$REPO" update-ref --no-deref -d "refs/heads/$branch" "$head" || die "worktree removed, but branch deletion failed; retry wt rm $name -r $(shell_join "$REPO")"
    fi
    teardown_save branch_config_removing
    stage=branch_config_removing
  fi
  if [[ $stage == branch_config_removing ]]; then
    teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/branch_config.py" recover "$REPO" "$branch" null "$(jq -r .generation <<<"$WT_TEARDOWN_JSON")" \
      || die 'cannot recover recorded branch cleanup locks; kept sidecars and receipt'
    if [[ $keep == 0 ]]; then
      teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/branch_config.py" remove "$REPO" "$branch" "$(jq -c '.branch_config // null' <<<"$WT_TEARDOWN_JSON")" "$(jq -r .generation <<<"$WT_TEARDOWN_JSON")" \
        || die 'Git branch cleanup remains pending; kept sidecars and receipt'
    fi
    local snapshot
    snapshot=$(jq -c '.sidecars // null' <<<"$WT_TEARDOWN_JSON")
    if [[ $snapshot == null ]]; then
      snapshot=$(teardown_sidecars_snapshot "$name") || die 'cannot fingerprint remaining sidecars'
      WT_TEARDOWN_JSON=$(jq -c --argjson sidecars "$snapshot" '.sidecars=$sidecars' <<<"$WT_TEARDOWN_JSON")
    fi
    [[ $(jq -r .metadata <<<"$snapshot") == $(jq -r .metadata_hash <<<"$WT_TEARDOWN_JSON") ]] || die 'metadata snapshot changed; kept sidecars and receipt'
    teardown_sidecars_check "$name" "$snapshot" || die 'sidecars changed before cleanup; kept sidecars and receipt'
    teardown_save sidecars_removing
    stage=sidecars_removing
  fi
  if [[ $stage == sidecars_removing ]]; then
    [[ ! -e $path && ! -L $path ]] || die 'worktree reappeared; kept sidecars and receipt'
    if [[ $keep == 0 ]]; then
      local branch_rc=0
      git -C "$REPO" show-ref -q --verify "refs/heads/$branch" || branch_rc=$?
      [[ $branch_rc == 1 ]] || die 'task branch reappeared or is unreadable; kept sidecars and receipt'
    fi
    local sidecars key sidecar
    sidecars=$(jq -c .sidecars <<<"$WT_TEARDOWN_JSON")
    teardown_sidecars_check "$name" "$sidecars" 1 || die 'sidecars changed during cleanup; kept sidecars and receipt'
    for key in metadata prompt started; do
      teardown_sidecars_check "$name" "$sidecars" 1 || die 'sidecars changed during cleanup; kept sidecars and receipt'
      case $key in metadata) sidecar=$(wt_meta "$name") ;; prompt) sidecar=$(wt_prompt "$name") ;; started) sidecar=$(wt_started "$name") ;; esac
      teardown_control check || die 'teardown coordinator exited before sidecar removal'
      rm -f "$sidecar" || die 'worktree removed, but sidecar cleanup failed'
    done
    [[ $(teardown_sidecars_snapshot "$name") == '{"metadata":"absent","prompt":"absent","started":"absent"}' ]] || die 'sidecars reappeared during cleanup'
    teardown_save git_removed
    printf 'removed %s%s\n' "$name" "$(if [[ $keep == 1 ]]; then printf ' (branch %s kept)' "$branch"; fi)"
  fi
  [[ ! -e $path && ! -L $path ]] || die 'worktree reappeared; session cleanup remains pending'
  [[ $(teardown_sidecars_snapshot "$name") == '{"metadata":"absent","prompt":"absent","started":"absent"}' ]] || die 'sidecars reappeared; session cleanup remains pending'
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
      if [[ $identity_rc == 0 ]]; then
        tmux_recorded_owner "$session" "$name" "$(jq -c .tmux_owner <<<"$WT_TEARDOWN_JSON")" \
          || die 'recorded owner validation blocks deferred cleanup'
      fi
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
        if [[ $(jq -r '.mode // "agent"' <<<"$WT_TMUX_OWNER") == shell ]]; then
          local saved_owner saved_shell saved_start
          saved_owner=$(jq -c .tmux_owner <<<"$WT_TEARDOWN_JSON")
          saved_shell=$(jq -r .pid <<<"$WT_TMUX_OWNER"); saved_start=$(jq -r .start <<<"$WT_TMUX_OWNER")
          jq -e --arg pid "$saved_shell" --arg start "$saved_start" \
            '(.pid == $pid and .start == $start) or any(.ancestors[]; .pid == $pid and .start == $start)' \
            <<<"$saved_owner" >/dev/null || die 'recorded task shell changed; cleanup remains pending'
          WT_TEARDOWN_JSON=$(jq -c --argjson owner "$WT_TMUX_OWNER" '.tmux_owner=$owner' <<<"$WT_TEARDOWN_JSON")
          teardown_save close_requested
        else
          [[ $(jq -c '[.pid,.start]' <<<"$WT_TMUX_OWNER") == "$(jq -c '.tmux_owner | [.pid,.start]' <<<"$WT_TEARDOWN_JSON")" ]] \
            || die 'recorded task provider changed; cleanup remains pending'
        fi
        teardown_commands_capture "$(jq -r .pid <<<"$WT_TMUX_OWNER")" "$(jq -r .start <<<"$WT_TMUX_OWNER")" \
          || die 'task command cancellation is incomplete; session cleanup remains pending'
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
      if [[ $checked_self == self ]]; then
        teardown_commands_capture "$ROW_AGENT_PID" "$ROW_AGENT_START" "$ROW_AGENT_OBSERVERS" \
          || die 'task command cancellation is incomplete; row cleanup remains pending'
      fi
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
  teardown_commands_stop all || die 'Git and row cleanup completed, but task command cleanup remains pending'
  teardown_commands_observe || die 'task runtime or command absence is unverified; cleanup remains pending'
  teardown_save complete
  printf 'teardown complete %s\n' "$name"
}
