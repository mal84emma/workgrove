"""Coordinate finite teardown workers without inheritable lock descriptors."""
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
pending_signals = set()
def forward(signum, frame):
    pending_signals.add(signum)
for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, forward)
def probe(arguments, absent=False):
    for _ in range(3):
        result = subprocess.run(["ps", *arguments], text=True, stdout=subprocess.PIPE,
                                env=dict(os.environ, LC_ALL="C"))
        if result.returncode == -signal.SIGHUP:
            continue
        if result.returncode == 0 or (absent and result.returncode == 1 and not result.stdout.strip()):
            return result.stdout
        raise RuntimeError("cannot inspect teardown processes; cleanup remains pending")
    raise RuntimeError("teardown process probe interrupted; cleanup remains pending")
def worker_exited():
    # Retain the child PID until its group stops, so another group cannot reuse it.
    state = probe(["-p", str(child.pid), "-o", "stat="], absent=True).strip()
    return not state or state.startswith("Z")
def group_inactive(group):
    listing = probe(["-axo", "pgid=,stat="])
    if not listing.strip():
        raise RuntimeError("empty teardown process sample; cleanup remains pending")
    for line in listing.splitlines():
        pgid, state = line.split()
        if int(pgid) == group and not state.startswith("Z"):
            return False
    return True
def process_start(pid):
    return probe(["-p", str(pid), "-o", "lstart="], absent=True).strip()
try:
    boot = process_start(1)
except (OSError, RuntimeError) as error:
    sys.exit("wt: " + str(error))
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
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for _ in range(500):
        if group_inactive(child.pid):
            return child.wait()
        time.sleep(0.01)
    raise RuntimeError("teardown commands have not stopped; cleanup remains pending")
stopped = False
result = 1
try:
    try:
        acquire()
    except BlockingIOError:
        sys.exit("wt: teardown already runs for " + name)
    if pending_signals:
        sys.exit(128 + min(pending_signals))
    environment = dict(os.environ, WG_TEARDOWN_CONTROL_FD=str(worker.fileno()), WG_TEARDOWN_LOCK_PATH=path,
                       WG_TEARDOWN_ORIGIN_PID=str(os.getppid()))
    if machine:
        environment["WT_MACHINE"] = machine
    child = subprocess.Popen([interpreter, "-c", "export WG_TEARDOWN_WORKER_PID=$BASHPID; exec \"$@\"", "worker",
                              interpreter, script, "rm", *sys.argv[6:]], env=environment,
                             pass_fds=(worker.fileno(),), start_new_session=True)
    record(child.pid)
    worker.close()
    forwarded = set()
    buffer = b""
    while True:
        for signum in pending_signals - forwarded:
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass
            forwarded.add(signum)
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
    stopped = True
except (OSError, ValueError, RuntimeError) as error:
    print("wt: " + str(error), file=sys.stderr)
finally:
    if child is not None and not stopped:
        try:
            stop_worker()
            stopped = True
        except (OSError, ValueError, RuntimeError) as error:
            print("wt: " + str(error), file=sys.stderr)
            result = 1
    if held:
        if child is None or stopped:
            record()
        fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
    parent.close()
    worker.close()
if result == 0 and pending_signals:
    result = 128 + min(pending_signals)
sys.exit(result if result >= 0 else 128 - result)
