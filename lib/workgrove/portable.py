"""Install and inspect a portable remote profile without provider-specific state."""

import argparse
import contextlib
import contextvars
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlsplit


class Refusal(Exception):
    """Return a fixed diagnostic without disclosing personal configuration."""

    def __init__(self, code, path=None):
        super().__init__(code)
        self.path = path


class VolumeTrustRequired(Refusal):
    def __init__(self, root, mount):
        super().__init__("personal-volume-trust-required")
        self.request = {"error": str(self), "root": str(root), "mount": str(mount)}


# Permission exceptions belong to one operation and one canonical mount.
_volume_policy = contextvars.ContextVar("volume_policy", default=None)


def check_mode(path, mode, code):
    if not mode & 0o022:
        return
    policy = _volume_policy.get()
    if policy and (path == policy["mount"] or policy["mount"] in path.parents):
        if policy["trusted"]:
            return
        raise VolumeTrustRequired(policy["root"], policy["mount"])
    raise Refusal(code)


@contextlib.contextmanager
def volume_permissions(root, policy, mount, trusted=False):
    require(not trusted or policy == "volume", "volume-trust-requires-volume-storage")
    point = canonical(mount) if policy == "volume" and mount else None
    if point:
        require(point != Path("/") and mounted(point), "persistent-mount-missing")
        require(root == point or point in root.parents, "root-outside-mount")
        require(not any(char in str(point) for char in ":\r\n\t"), "unsupported-root-path")
    token = _volume_policy.set(dict(root=root, mount=point, trusted=trusted) if point else None)
    try:
        yield
    finally:
        _volume_policy.reset(token)


def configured_permissions(function):
    def operation(args):
        root = canonical(args.root)
        snapshot = read(profile_path(root), missing=True)
        expected = getattr(args, "expected_profile_digest", None)
        require(expected is None or expected == hashlib.sha256(snapshot.encode()).hexdigest(), "profile-changed-retry-setup")
        previous = load_profile(root) if profile_path(root).exists() else None
        require(read(profile_path(root), missing=True) == snapshot, "profile-changed-retry-setup")
        args.permission_profile_snapshot = snapshot
        policy = args.storage or (previous["storage"] if previous else None)
        mount = args.mount or (previous["mount"] if previous else str(root) if policy == "volume" else None)
        mount = str(canonical(mount)) if mount and policy == "volume" else mount
        explicit = getattr(args, "trust_personal_volume", False)
        strict = getattr(args, "strict_permissions", False)
        require(not (explicit and strict), "conflicting-storage-permission-options")
        saved = bool(previous and previous["trust_personal_volume"])
        same_scope = bool(previous and policy == previous["storage"] and mount == previous["mount"])
        restoring = function.__name__ == "restore" or getattr(args, "restore_only", False)
        if restoring:
            require(previous and same_scope, "restore-storage-policy-conflict")
            require(not explicit or saved, "restore-cannot-change-volume-trust")
            require(not strict or not saved, "restore-cannot-change-volume-trust")
        require(not saved or same_scope or explicit or strict, "personal-volume-trust-scope-changed")
        args.storage, args.mount = policy, mount
        args.trust_personal_volume = explicit or (saved and same_scope and not strict)
        with volume_permissions(root, policy, mount, args.trust_personal_volume):
            return function(args)
    return operation


def confirm_volume_trust(request):
    require(isinstance(request, dict) and set(request) == {"error", "root", "mount"}
            and request["error"] == "personal-volume-trust-required", "invalid-volume-trust-request")
    for key in ("root", "mount"):
        value = request[key]
        require(isinstance(value, str) and value.startswith("/") and
                not any(ord(char) < 32 or ord(char) == 127 for char in value), "invalid-volume-trust-request")
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        return False
    print("Volume: " + request["mount"] + "\nInstallation root: " + request["root"], file=sys.stderr)
    print("This volume does not provide workgrove's required private permissions.", file=sys.stderr)
    print("Users or processes with volume access could read configuration or replace executable files.", file=sys.stderr)
    print("Do you exclusively control this volume and accept using it for personal configuration? [y/N] ",
          end="", file=sys.stderr, flush=True)
    return sys.stdin.readline().strip().lower() in {"y", "yes"}


def confirm_volume_request(args):
    request = json.loads(read(Path(args.request_file)).splitlines()[0])
    if not confirm_volume_trust(request):
        return 1
    print(request["root"] + "\n" + request["mount"])
    return 0


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("invalid-arguments: " + message)


def require(value, code, path=None):
    if not value:
        raise Refusal(code, path)


@contextlib.contextmanager
def refusal_path(path):
    """Name a fixed location without changing an existing refusal path or code."""
    try:
        yield
    except Refusal as error:
        if error.path is None:
            error.path = path
        raise


def canonical(path):
    path = Path(path).expanduser()
    require(path.is_absolute(), "absolute-path-required")
    try:
        return path.resolve()
    except (OSError, RuntimeError):
        raise Refusal("invalid-path") from None


def outside_git(path):
    for parent in (path, *path.parents):
        require(parent.name != ".git" and not (parent / ".git").exists(), "repository-destination")
        require(not ((parent / "HEAD").exists() and
                     ((parent / "objects").is_dir() or (parent / "commondir").is_file())),
                "repository-destination")


def private_path(path, detach=False, read_only_source=False):
    path = Path(path)
    require(detach or not path.is_symlink() or path.exists(), "dangling-configuration-link")
    target = canonical(path.parent) / path.name if detach else canonical(path)
    if not read_only_source:
        outside_git(target)
    if target.exists():
        info = target.lstat()
        require(info.st_uid == os.getuid(), "foreign-owner")
        require(not stat.S_ISREG(info.st_mode) or info.st_nlink == 1, "hardlinked-file")
        require(stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode) or
                (detach and stat.S_ISLNK(info.st_mode)), "nonregular-file")
        if not stat.S_ISLNK(info.st_mode):
            check_mode(target, info.st_mode, "shared-configuration-target")
    for ancestor in reversed(target.parents):
        if ancestor.is_dir():
            mode = ancestor.stat().st_mode
            if not mode & stat.S_ISVTX:
                check_mode(ancestor, mode, "shared-configuration-parent")
    parent = target.parent
    while not parent.exists():
        parent = parent.parent
    require(parent.stat().st_uid == os.getuid() or os.access(parent, os.W_OK), "unwritable-parent")
    return target


def mkdir(path):
    private_path(path)
    missing = []
    node = path
    while not node.exists():
        missing.append(node)
        node = node.parent
    for node in reversed(missing):
        node.mkdir(mode=0o700, exist_ok=True)


def read(path, missing=False):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "nonregular-file")
            data = stream.read(4 * 1024 * 1024 + 1)
    except FileNotFoundError:
        if missing and not path.is_symlink():
            return ""
        raise Refusal("missing-file") from None
    require(len(data) <= 4 * 1024 * 1024, "file-too-large")
    return data.decode("utf-8")


def write(path, text):
    path = private_path(path)
    if path.is_file() and read(path) == text:
        return
    mkdir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".workgrove-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(args, cwd=None, env=None, allowed=(0,)):
    try:
        result = subprocess.run(args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=180, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise Refusal("command-unavailable") from None
    require(result.returncode in allowed, "command-failed")
    return result


def git(args, source=None, allowed=(0,)):
    transport = {"GIT_ALLOW_PROTOCOL", "GIT_PROTOCOL_FROM_USER", "GIT_SSL_CAINFO", "GIT_SSL_CAPATH"}
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_") or key in transport}
    # Public source acquisition must not inherit personal headers, URL rewrites, or credential commands.
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_NO_LAZY_FETCH"] = "1"
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    return run(["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
                "-c", "credential.interactive=false", "-c", "core.fsmonitor=false", *args], cwd=source or "/", env=env, allowed=allowed)


def git_quote(value, subsection=False):
    value = str(value).replace("\\", "\\\\").replace('"', '\\"')
    if not subsection:
        value = value.replace("\n", "\\n").replace("\t", "\\t").replace("\b", "\\b")
    return '"' + value + '"'


def profile_path(root):
    return root / ".config/workgrove/profile.json"


def load_profile(root=None):
    path = profile_path(root) if root else Path.home() / ".config/workgrove/profile.json"
    require(path.is_file(), "profile-missing")
    data = json.loads(read(path))
    require(isinstance(data, dict) and data.get("schema") in (1, 2), "invalid-profile")
    allowed = {"schema", "root", "source", "revision", "host", "storage", "mount", "persist_agents",
               "agent_roots", "agent_commands", "tmux", "agent_args"}
    allowed.update({"signatures"} if data["schema"] == 1 else {"runtime_manifest", "claude_config_dir"})
    data.setdefault("trust_personal_volume", False)
    allowed.add("trust_personal_volume")
    require(set(data) == allowed, "invalid-profile")
    require(data["root"] == str(canonical(data["root"])), "invalid-profile")
    if root:
        require(canonical(root) == Path(data["root"]), "profile-root-conflict")
    require(data["source"] == str(Path(data["root"]) / "workgrove"), "installation-identity-conflict")
    require(isinstance(data["revision"], str) and re.fullmatch(r"[0-9a-f]{40,64}", data["revision"]), "invalid-profile")
    require(isinstance(data["host"], str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", data["host"]), "invalid-profile")
    require(data["storage"] in {"volume", "os-disk"}, "invalid-profile")
    require(isinstance(data["trust_personal_volume"], bool), "invalid-profile")
    require(not data["trust_personal_volume"] or data["storage"] == "volume", "invalid-profile")
    if data["storage"] == "volume":
        require(isinstance(data["mount"], str), "invalid-profile")
        point = str(canonical(data["mount"]))
        require(not data["trust_personal_volume"] or data["mount"] == point, "invalid-profile")
        data["mount"] = point
    require(isinstance(data["tmux"], bool) and isinstance(data["persist_agents"], bool), "invalid-profile")
    require(isinstance(data["agent_roots"], dict) and set(data["agent_roots"]) == {"claude", "codex"}, "invalid-profile")
    for value in data["agent_roots"].values():
        require(isinstance(value, str) and Path(value).is_absolute(), "invalid-profile")
    require(isinstance(data["agent_commands"], dict) and set(data["agent_commands"]) == {"claude", "codex"}, "invalid-profile")
    for value in data["agent_commands"].values():
        require(value is None or (isinstance(value, str) and Path(value).is_absolute()), "invalid-profile")
    validate_agent_args(data["agent_args"])
    if data["schema"] == 1:
        require(isinstance(data["signatures"], dict) and set(data["signatures"]) == {
            "bin/wt", "install.sh", "lib/workgrove/portable.py"}, "invalid-profile")
        require(all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
                    for value in data["signatures"].values()), "invalid-profile")
    else:
        manifest = data["runtime_manifest"]
        require(isinstance(manifest, dict) and manifest, "invalid-profile")
        for name, value in manifest.items():
            require(name in {"install.sh", ".git/config"} or name.split("/")[0] in {"bin", "lib", "home"}, "invalid-profile")
            require(str(Path(name)) == name and ".." not in Path(name).parts, "invalid-profile")
            require(isinstance(value, str) and (value == "directory" or re.fullmatch(r"[0-9a-f]{64}", value)),
                    "invalid-profile")
        require(data["claude_config_dir"] is None or data["claude_config_dir"] == data["agent_roots"]["claude"],
                "invalid-profile")
    return data


def mount_list():
    """Read mount points and types, including bind mounts and escaped paths."""
    path = Path("/proc/self/mountinfo")
    if not path.is_file():
        return []
    points = []
    for line in read(path).splitlines():
        before, separator, after = line.partition(" - ")
        fields, filesystem = before.split(), after.split()
        if separator and len(fields) > 4 and filesystem:
            name = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), fields[4])
            points.append((Path(name), filesystem[0]))
    return points


def mounted(point):
    if Path("/proc/self/mountinfo").is_file():
        return any(name == point for name, _ in mount_list())
    return os.path.ismount(point)


def machine_path(root):
    return root / ".local/state/workgrove/machine"


def discover_root(host):
    """Find one alias-matching volume root without changing readiness or personal state."""
    result = dict(status="none", root=None, same_machine=None)
    deadline = time.monotonic() + 10
    folders = 0
    matches = {}
    seen_mounts = set()
    excluded = {"proc", "sysfs", "tmpfs", "devtmpfs", "devpts", "cgroup", "cgroup2",
                "mqueue", "overlay", "squashfs"}

    class SearchLimit(Exception):
        pass

    def checkpoint():
        if time.monotonic() >= deadline:
            raise SearchLimit()

    def inspect(function, *args):
        checkpoint()
        value = function(*args)
        checkpoint()
        return value

    def search(candidate, mount, depth):
        nonlocal folders
        checkpoint()
        if candidate.name.startswith("."):
            return
        try:
            if not stat.S_ISDIR(inspect(candidate.lstat).st_mode):
                return
            if not inspect(os.access, candidate, os.R_OK | os.X_OK):
                return
        except SearchLimit:
            raise
        except Exception:
            return
        if folders >= 4096:
            raise SearchLimit()
        folders += 1
        try:
            path = candidate
            for name, directory in ((".config", True), ("workgrove", True), ("profile.json", False)):
                path = path / name
                mode = inspect(path.lstat).st_mode
                require(stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode), "invalid-discovery-candidate")
            profile = inspect(load_profile, candidate)
            if profile["host"] == host and profile["storage"] == "volume" and profile["mount"] == str(mount):
                root = profile["root"]
                same_machine = None
                try:
                    record = machine_path(Path(root))
                    if stat.S_ISREG(inspect(record.lstat).st_mode):
                        same_machine = inspect(read, record) == socket.gethostname() + "\n"
                except SearchLimit:
                    raise
                except Exception:
                    pass
                matches[root] = same_machine
        except SearchLimit:
            raise
        except Exception:
            pass
        if depth == 2:
            return
        try:
            checkpoint()
            with os.scandir(candidate) as entries:
                checkpoint()
                while True:
                    checkpoint()
                    entry = next(entries, None)
                    checkpoint()
                    if entry is None:
                        break
                    if not entry.name.startswith("."):
                        search(candidate / entry.name, mount, depth + 1)
        except SearchLimit:
            raise
        except Exception:
            pass

    try:
        mounts = inspect(mount_list)
        excluded_points = {mount for mount, kind in mounts if kind in excluded}
        for mount, _ in mounts:
            checkpoint()
            if mount == Path("/") or mount in excluded_points or mount in seen_mounts:
                continue
            seen_mounts.add(mount)
            search(mount, mount, 0)
        checkpoint()
    except SearchLimit:
        result["status"] = "incomplete"
        return result
    except Exception:
        return result
    if len(matches) == 1:
        root, same_machine = next(iter(matches.items()))
        result.update(status="found", root=root, same_machine=same_machine)
    elif matches:
        result["status"] = "ambiguous"
    return result


def storage(root, policy, mount):
    outside_git(root)
    require(not any(char in str(root) for char in ":\r\n\t"), "unsupported-root-path")
    require(root != Path("/") and root != Path.home() and root not in Path.home().parents,
            "unsafe-root")
    if policy == "volume":
        require(mount is not None, "mount-required")
        point = canonical(mount)
        require(point != Path("/") and mounted(point), "persistent-mount-missing")
        require(root == point or point in root.parents, "root-outside-mount")
        require(root.exists(), "persistent-root-missing")
    else:
        require(policy == "os-disk", "storage-policy-required")
    if root.exists():
        require(root.is_dir() and root.stat().st_uid == os.getuid(), "persistent-root-owner")
        require(os.access(root, os.W_OK | os.X_OK), "persistent-root-unwritable")
    private_path(root)
    if root.exists():
        check_mode(root, root.stat().st_mode, "persistent-root-writable-by-others")


RUNTIME_INPUTS = ("install.sh", "bin", "lib", "home")


def runtime_manifest(source):
    """Describe every installed input, without inspecting unrelated checkout environments."""
    paths = [source / "install.sh", source / ".git/config"]
    for component in RUNTIME_INPUTS[1:]:
        for directory, dirs, files in os.walk(source / component):
            paths.extend((Path(directory), *(Path(directory) / name for name in files)))
    return {str(path.relative_to(source)): "directory" if path.is_dir() else hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


def approved_runtime(source):
    """Bind runtime contents to the effective Git checkout before saving a manifest."""
    locations = git(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"], source).stdout.splitlines()
    require(len(locations) == 3 and [canonical(source / path) for path in locations] ==
            [source, source / ".git", source / ".git"], "installation-identity-conflict")
    indirect = git(["config", "--local", "--no-includes", "--get-regexp",
                    r"^(include|includeif\..*)\.path$|^extensions\.worktreeconfig$"], source, allowed=(0, 1))
    require(not indirect.stdout, "standalone-configuration-required")
    approved = {".git/config": hashlib.sha256((source / ".git/config").read_bytes()).hexdigest()}
    tree = git(["ls-tree", "-rz", "--full-tree", "HEAD", "--", *RUNTIME_INPUTS], source).stdout
    for record in tree.split("\0"):
        if not record:
            continue
        metadata, name = record.split("\t", 1)
        mode, kind, object_id = metadata.split()
        require(kind == "blob" and mode in {"100644", "100755"}, "installation-source-link-refused")
        path = source / name
        require(path.is_file(), "installation-has-local-edits")
        contents = path.read_bytes()
        digest = hashlib.new("sha1" if len(object_id) == 40 else "sha256")
        digest.update(f"blob {len(contents)}\0".encode())
        digest.update(contents)
        require(digest.hexdigest() == object_id, "installation-has-local-edits")
        approved[name] = hashlib.sha256(contents).hexdigest()
        for parent in Path(name).parents:
            if parent != Path("."):
                approved[str(parent)] = "directory"
    require(approved == runtime_manifest(source), "installation-untracked-runtime")
    return approved


def validate_source(source, profile=None):
    require(source.is_dir() and (source / ".git").is_dir(), "standalone-installation-required")
    require(canonical(source / ".git") == source / ".git", "installation-identity-conflict")
    objects = source / ".git/objects"
    require(objects.is_dir() and not objects.is_symlink() and not (source / ".git/commondir").exists(),
            "standalone-object-store-required")
    require(not read(objects / "info/alternates", missing=True).strip(), "standalone-object-store-required")
    require(not any((objects / "pack").glob("*.promisor")), "standalone-object-store-required")
    paths = [source, source / "install.sh"]
    for component in (".git", "bin", "lib", "home"):
        require(source in canonical(source / component).parents, "installation-identity-conflict")
        for directory, dirs, files in os.walk(source / component):
            paths.extend((Path(directory), *(Path(directory) / name for name in dirs + files)))
    for path in paths:
        require(not path.is_symlink(), "installation-source-link-refused")
        require(canonical(path) == path, "installation-identity-conflict")
        info = path.lstat()
        require(info.st_uid == os.getuid(), "installation-foreign-owner")
        require(stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode), "installation-nonregular-file")
        check_mode(path, info.st_mode, "installation-writable-by-others")
    for name in ("bin/wt", "install.sh", "lib/workgrove/portable.py", "home/.claude/AGENTS.md"):
        require((source / name).is_file() and canonical(source) in canonical(source / name).parents,
                "installation-identity-conflict")
    if profile:
        require(profile["schema"] == 2, "profile-upgrade-run-full-setup")
        require(runtime_manifest(source) == profile["runtime_manifest"], "installation-changed-run-full-setup")


def validate_objects(source):
    result = git(["fsck", "--connectivity-only", "--no-dangling"], source, allowed=range(256))
    require(result.returncode == 0, "installation-object-store-incomplete")


def validate_installation(source, requested_revision):
    """Validate the selected checkout before executing or installing its runtime."""
    validate_source(source)
    validate_objects(source)
    manifest = approved_runtime(source)
    revision = git(["rev-parse", "HEAD"], source).stdout.strip()
    require(not requested_revision or requested_revision == revision, "selected-revision-unavailable")
    require(not git(["status", "--porcelain", "--untracked-files=no"], source).stdout, "installation-has-local-edits")
    return revision, manifest


def validate_agent_args(value):
    require(isinstance(value, dict) and set(value) <= {"claude", "codex"}, "invalid-agent-arguments")
    for args in value.values():
        require(isinstance(args, list) and len(args) <= 32, "invalid-agent-arguments")
        for item in args:
            require(isinstance(item, str) and item and len(item) <= 1024 and
                    all(ord(c) >= 32 for c in item), "invalid-agent-arguments")
            require(not re.search(r"token|secret|password|api.?key|authorization", item, re.I),
                    "credential-argument-refused")


def select_agent_roots(root, persist, previous):
    chosen = {}
    migrations = []
    for agent, variable, default in (("claude", "CLAUDE_CONFIG_DIR", ".claude"),
                                     ("codex", "CODEX_HOME", ".codex")):
        home = Path.home() / default
        label = "~/" + default if persist else None
        require(not home.is_symlink() or home.exists(), "agent-configuration-link-unavailable", label)
        old = previous["agent_roots"][agent] if previous else None
        configured = old or os.environ.get(variable)
        current = canonical(configured) if configured else canonical(home)
        if previous and previous["persist_agents"]:
            require(current.is_dir(), "persistent-agent-configuration-missing")
        if configured and current != canonical(home) and root not in current.parents:
            require(current.is_dir(), "external-agent-configuration-missing")
        with refusal_path(label if current == canonical(home) else None):
            private_path(current)
        if persist and (not configured or current == canonical(home)) and not home.is_symlink():
            target = root / ".config" / agent
        else:
            target = current
        with refusal_path(label if target == canonical(home) else None):
            private_path(target)
        if persist and current != target and current.exists() and target.exists():
            raise Refusal("agent-configuration-conflict", label)
        if persist and home.exists() and canonical(home) != target and configured and current != canonical(home):
            raise Refusal("agent-home-conflict", label)
        if persist and current != target and current.exists():
            require(current.is_dir(), "invalid-agent-root", label)
            migrations.append((current, target))
        chosen[agent] = str(target)
    return chosen, migrations


def claude_directory(agents, persist, previous):
    if previous and previous["schema"] == 2:
        return agents["claude"] if persist or previous["claude_config_dir"] is not None else None
    if previous:
        redirected = Path(agents["claude"]) != Path.home() / ".claude"
        return agents["claude"] if persist or redirected else None
    return agents["claude"] if persist or os.environ.get("CLAUDE_CONFIG_DIR") else None


def claude_global(profile):
    return Path(profile["claude_config_dir"] or Path.home()) / ".claude.json"


def plan_claude_state(profile, previous, migrations):
    """Move global state with a changed lookup location, without combining identities."""
    target = claude_global(profile)
    if previous and previous["schema"] == 2:
        originals = [claude_global(previous)]
    elif previous:
        directory = Path(previous["agent_roots"]["claude"])
        originals = [directory / ".claude.json"]
        if directory in {Path.home() / ".claude", Path(previous["root"]) / ".config/claude"}:
            originals.append(Path.home() / ".claude.json")
    else:
        originals = [Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home()) / ".claude.json"]
        for old, new in migrations:
            if new == target.parent:
                originals.append(old / ".claude.json")
    paths = list(dict.fromkeys([*originals, target]))
    contents = {}
    for path in paths:
        private_path(path)
        if path.exists():
            contents[path] = read(path)
    require(len(set(contents.values())) <= 1, "claude-global-state-conflict")
    return target, next(iter(contents.values()), None), [path for path in contents if canonical(path) != canonical(target)]


def select_agent_commands(root, migrations, previous):
    commands = dict(previous["agent_commands"] if previous else {"claude": None, "codex": None})
    for agent in ("claude", "codex"):
        found = shutil.which(agent)
        if not found:
            continue
        command = Path(found).absolute()
        managed = root / ".local/bin" / agent
        if command == managed and command.is_symlink() and commands[agent] and command.readlink() == Path(commands[agent]):
            continue
        # Preserve command indirection after reaching the selected persistent root.
        for _ in range(32):
            parent = canonical(command.parent)
            if root == parent or root in parent.parents or not command.is_symlink():
                break
            target = command.readlink()
            command = target if target.is_absolute() else parent / target
        for original, target in migrations:
            if command == original or original in command.parents:
                command = target / command.relative_to(original)
        try:
            physical = canonical(command)
            outside_git(physical)
        except Refusal:
            continue
        if root in physical.parents:
            commands[agent] = str(command)
    return commands


def augmented_excludes(path, destination, missing_text=""):
    path = Path(path).expanduser()
    require(path.is_absolute(), "absolute-git-exclusions-required")
    private_path(path, read_only_source=True)
    text = read(path) if path.exists() else missing_text
    if text.rstrip("\n").split("\n")[-1] != ".worktrees/":
        text = text.rstrip("\n") + "\n.worktrees/\n"
    write(destination, text)
    return destination


def git_owned_path(text, label, managed):
    start, end = f"# >>> workgrove git {label}\n", f"# <<< workgrove git {label}\n"
    require(text.count(start) == text.count(end) and text.count(start) <= 1, "managed-git-config-conflict")
    if start not in text:
        return None
    body = text.split(start, 1)[1].split(end, 1)[0]
    match = re.search(r'^\s*(?:path|excludesFile)\s*=\s*(.+)$', body, re.M | re.I)
    require(match is not None, "managed-git-config-conflict")
    value = match[1].strip()
    path = canonical(json.loads(value) if value.startswith('"') else value)
    return path if managed in path.parents else None


def git_config_graph(start, destination, managed=None, skip=(), missing_excludes="", overlay=None):
    """Preserve Git entry order and anchor relative paths at their logical source locations."""
    mapping = {}
    exclusions = []

    def visit(path):
        path = Path(path).expanduser().absolute()
        require(path.is_file(), "git-include-missing")
        private_path(path, read_only_source=True)
        if path in mapping:
            return mapping[path]
        require(len(mapping) < 64, "git-includes-too-deep")
        target = destination / f"config-{len(mapping)}"
        mapping[path] = target
        read(path)
        output = git(["config", "--file", str(path), "--no-includes", "--null", "--list"]).stdout
        entries = []
        for record in output.split("\0"):
            if not record:
                continue
            key, separator, value = record.partition("\n")
            section, _, name = key.partition(".")
            subsection = None
            if "." in name:
                subsection, name = name.rsplit(".", 1)
            if name == "path" and ((section == "include" and subsection is None) or
                                   (section == "includeif" and subsection is not None)):
                require(separator and "%(" not in value and "\n" not in value, "unsupported-git-include")
                include = Path(value).expanduser()
                if not include.is_absolute():
                    include = path.parent / include
                if path == Path(start).expanduser().absolute() and canonical(include) in skip:
                    continue
                if path == Path(start).expanduser().absolute() and overlay and canonical(include) == overlay[0]:
                    entries.append(replace_block("", "git identity", '[include]\n\tpath = ' + git_quote(overlay[1])))
                    continue
                value = str(visit(include)) if include.is_file() else str(include)
                if section == "includeif":
                    for prefix in ("gitdir:", "gitdir/i:", "worktree:", "worktree/i:"):
                        if subsection.startswith(prefix + "./"):
                            subsection = prefix + str(path.parent) + "/" + subsection[len(prefix) + 2:]
                            break
            if key == "core.excludesfile":
                require(separator and "%(" not in value and "\n" not in value, "unsupported-git-exclusions")
                original = Path(value).expanduser()
                require(original.is_absolute(), "absolute-git-exclusions-required")
                selected = canonical(original)
                legacy = (managed is not None and managed in selected.parents and selected.name == "ignore"
                          and re.fullmatch(r"[0-9a-f]{32}", selected.parent.name))
                if legacy or (path == Path(start).expanduser().absolute() and selected in skip):
                    continue
                copied = destination / f"excludes-{len(exclusions)}"
                exclusions.append(copied)
                value = str(augmented_excludes(original, copied, missing_excludes))
            header = section + (" " + git_quote(subsection, subsection=True) if subsection is not None else "")
            entries.append("[" + header + "]\n\t" + name + (" = " + git_quote(value) if separator else "") + "\n")
        write(target, "".join(entries))
        return target

    return visit(start)


def prepare_git(root, identity, previous):
    destination = root / ".config/workgrove/git"
    active = destination / "global"
    configured = os.environ.get("GIT_CONFIG_GLOBAL")
    candidates = [Path(configured)] if configured is not None else [
        Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "git/config", Path.home() / ".gitconfig"]
    adopting = bool(previous and active.is_file())
    if previous:
        require(adopting or identity, "personal-git-configuration-missing")
        originals = [active] if adopting else []
    else:
        originals = [path for path in candidates if path.is_file()]
    old_text = read(active) if adopting else ""
    old_identity = git_owned_path(old_text, "identity", destination)
    old_default = git_owned_path(old_text, "defaults", destination)
    if identity:
        require(Path(identity).is_file(), "personal-git-identity-required")
        selected = canonical(identity)
        if adopting and selected in {active, old_identity}:
            identity = None
        else:
            require(destination not in selected.parents, "managed-git-identity-source-refused")
    require(identity or originals, "personal-git-identity-required")
    generation = destination / uuid.uuid4().hex
    mkdir(generation)
    implicit = (destination / "missing-defaults" if previous else
                Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "git/ignore")
    legacy_text = ""
    if adopting and old_default is None:
        result = git(["config", "--includes", "--file", str(active), "--path", "--get", "core.excludesFile"], allowed=(0, 1))
        selected = Path(result.stdout.strip())
        if selected.is_absolute() and destination in selected.parents and selected.name == "ignore":
            legacy_text = read(selected, missing=True)
    fallback = augmented_excludes(old_default or implicit, generation / "defaults", legacy_text)
    overlay = old_identity
    if identity and not any(canonical(identity) == canonical(path) for path in originals):
        overlay = git_config_graph(Path(identity), generation / "identity", destination)
    skip = {old_default} if old_default is not None else set()
    replacement = (old_identity, overlay) if old_identity is not None else None
    bases = [git_config_graph(path, generation / str(index), destination, skip, legacy_text, replacement)
             for index, path in enumerate(originals)]
    contents = "".join(read(base) for base in bases)
    contents = replace_block(contents, "git defaults", '[core]\n\texcludesFile = ' + git_quote(fallback), first=True)
    if overlay and old_identity is None:
        contents = replace_block(contents, "git identity", '[include]\n\tpath = ' + git_quote(overlay))
    prospective = generation / "global"
    write(prospective, contents)
    for key in ("user.name", "user.email"):
        result = git(["config", "--includes", "--file", str(prospective), "--get", key], allowed=(0, 1))
        require(result.returncode == 0 and result.stdout.strip(), "personal-git-identity-required")
    write(active, contents)
    return active


def display_path(path, root, profile=None):
    if profile:
        for agent, value in profile["agent_roots"].items():
            base = Path(value)
            defaults = {root / ".config" / agent, Path.home() / ("." + agent)}
            if base not in defaults and (path == base or base in path.parents):
                return "<" + agent + "-root>/" + str(path.relative_to(base))
    for base, prefix in ((root, ""), (Path.home(), "~/")):
        if path == base or base in path.parents:
            return prefix + str(path.relative_to(base))
    return "<configuration>"


def backup(path, root, label=None):
    if not path.exists() and not path.is_symlink():
        return
    private_path(path, detach=True)
    base = root / ".local/state/workgrove/backups"
    records = []
    for record in base.glob("*/.workgrove-backup.json"):
        if record.is_file() and not record.is_symlink():
            records.append((json.loads(read(record)), record.parent))
    original = str(path.absolute())
    matching = [(data["order"], folder) for data, folder in records if data["path"] == original]
    label = label or display_path(path, root)
    if matching and stat.S_ISREG(path.lstat().st_mode):
        _, folder = max(matching)
        previous = folder / path.name
        identical = False
        if previous.exists() and stat.S_ISREG(previous.lstat().st_mode):
            try:
                identical = previous.read_bytes() == path.read_bytes()
            except OSError:
                # Keep setup's existing ability to move unreadable files.
                pass
        if identical:
            path.unlink()
            print(f"workgrove: removed {label}; identical backup in {folder.relative_to(root)}", file=sys.stderr)
            return
    folder = base / uuid.uuid4().hex
    mkdir(folder)
    shutil.move(str(path), str(folder / path.name))
    # The sequence records move order without depending on filesystem timestamps.
    order = max((data["order"] for data, _ in records), default=0) + 1
    write(folder / ".workgrove-backup.json", json.dumps(dict(path=original, order=order)) + "\n")
    print(f"workgrove: backed up {label} to {folder.relative_to(root)}", file=sys.stderr)


def link(target, path, root, replace=False, label=None):
    private_path(path, detach=True)
    if path.is_symlink() and canonical(path) == canonical(target):
        return
    if path.exists() or path.is_symlink():
        require(replace, "link-conflict", label)
        backup(path, root, label)
    mkdir(path.parent)
    temporary = path.with_name(".workgrove-link-" + uuid.uuid4().hex)
    try:
        temporary.symlink_to(target)
        os.replace(temporary, path)
    finally:
        if temporary.is_symlink():
            temporary.unlink()


def replace_block(text, label, contents, first=False):
    start = f"# >>> workgrove {label}\n"
    end = f"# <<< workgrove {label}\n"
    require(text.count(start) == text.count(end) and text.count(start) <= 1, "managed-text-conflict")
    if start in text:
        left, rest = text.split(start)
        _, right = rest.split(end, 1)
        text = left + right
    managed = start + contents.rstrip("\n") + "\n" + end
    if first:
        return managed + text
    return text + ("\n" if text and not text.endswith("\n") else "") + managed


def merge_hooks(existing, base):
    require(isinstance(existing, dict), "invalid-agent-json")
    hooks = existing.setdefault("hooks", {})
    require(isinstance(hooks, dict), "invalid-agent-json")
    for event, groups in base.get("hooks", {}).items():
        current = hooks.setdefault(event, [])
        require(isinstance(current, list), "invalid-agent-json")
        for group in current:
            require(isinstance(group, dict) and isinstance(group.get("hooks", []), list), "invalid-agent-json")
            require(all(isinstance(hook, dict) and isinstance(hook.get("command", ""), str)
                        for hook in group.get("hooks", [])), "invalid-agent-json")
        commands = {hook.get("command") for group in current for hook in group.get("hooks", [])}
        for group in groups:
            missing = [hook for hook in group["hooks"] if hook["command"] not in commands]
            if missing:
                current.append(dict(group, hooks=missing))
    return existing


def shell_environment(profile):
    root = Path(profile["root"])
    values = {"WT_REMOTE_ROOT": str(root), "WT_HOST": profile["host"], "WT_REPOS_DIR": str(root),
              "GIT_CONFIG_GLOBAL": str(root / ".config/workgrove/git/global"),
              "CODEX_HOME": profile["agent_roots"]["codex"]}
    if profile["claude_config_dir"] is not None:
        values["CLAUDE_CONFIG_DIR"] = profile["claude_config_dir"]
    text = "# Workgrove exports only; sourcing this file performs no setup.\n"
    for name, value in values.items():
        text += f"export {name}={shlex.quote(value)}\n"
    if profile["claude_config_dir"] is None:
        text += "unset CLAUDE_CONFIG_DIR\n"
    for agent in ("claude", "codex"):
        value = json.dumps(profile["agent_args"].get(agent, []))
        text += f"export WT_{agent.upper()}_ARGS_JSON={shlex.quote(value)}\n"
    text += f'export PATH={shlex.quote(str(root / ".local/bin"))}:"$HOME/.local/bin:$PATH"\n'
    return text


def bash_path(profile):
    text = ""
    for folder in ('"$HOME/.local/bin"', shlex.quote(str(Path(profile["root"]) / ".local/bin"))):
        text += ('case ":$PATH:" in\n'
                 f'    *:{folder}:*) ;;\n'
                 f'    *) export PATH={folder}:"$PATH" ;;\n'
                 'esac\n')
    return text


def compatibility(profile):
    """Return (target, path, home) entries with each location's restoration role."""
    root, source = Path(profile["root"]), Path(profile["source"])
    links = []
    for item in sorted((source / "bin").iterdir()):
        if item.is_file():
            links.extend(((item, root / ".local/bin" / item.name, False),
                          (item, Path.home() / ".local/bin" / item.name, True)))
    for agent, command in profile["agent_commands"].items():
        if command:
            target = Path(command)
            links.append((target, root / ".local/bin" / agent, False))
            home = Path.home() / ".local/bin" / agent
            if not home.exists() or (home.is_symlink() and canonical(home) == canonical(target)):
                links.append((target, home, True))
    for item in sorted((source / "home/.agents/skills").iterdir()):
        if item.is_dir():
            links.extend(((item, root / ".agents/skills" / item.name, False),
                          (item, Path.home() / ".agents/skills" / item.name, True),
                          (item, Path(profile["agent_roots"]["claude"]) / "skills" / item.name, False)))
    for agent, default in (("claude", ".claude"), ("codex", ".codex")):
        if profile["persist_agents"]:
            links.append((Path(profile["agent_roots"][agent]), Path.home() / default, True))
    links.append((profile_path(root), Path.home() / ".config/workgrove/profile.json", True))
    links.append((root / ".config/workgrove/env.sh", Path.home() / ".config/workgrove/env.sh", True))
    links.append((root / ".config/workgrove/git/global", Path.home() / ".gitconfig", True))
    if profile["tmux"]:
        links.append((source / "home/.tmux.conf", Path.home() / ".tmux.conf", True))
    return [(a, b, home) for a, b, home in links if a.absolute() != b.absolute()]


AGENT_FILES = {
    "claude": {"settings.json": "hooks", ".credentials.json": "state",
               "AGENTS.md": "instructions", "CLAUDE.md": "instructions"},
    "codex": {"hooks.json": "hooks", "config.toml": "settings", "auth.json": "state",
              "AGENTS.md": "instructions"},
}


def validate_migration_links(migrations, materialized, selected_roots):
    """Refuse directory moves that change a copied link's referent."""
    selected = [canonical(path) for path in selected_roots]
    for original, _ in migrations:
        require(not any(path == original or original in path.parents for path in selected),
                "agent-configuration-conflict")

    def relocated(path):
        for original, target in migrations:
            if path == original or original in path.parents:
                return target / path.relative_to(original)
        return path

    def future_referent(path):
        current, pending, followed = Path("/"), list(path.parts[1:]), 0
        while pending:
            part = pending.pop(0)
            if part == "..":
                current = current.parent
                continue
            candidate = current / part
            # HOME compatibility links will point to the migrated directories.
            replacement = next((target for original, target in migrations if candidate == original), None)
            physical = candidate
            # Copied links retain their text but resolve from their future parent directories.
            for original, target in migrations:
                if candidate == target or target in candidate.parents:
                    physical = original / candidate.relative_to(target)
                    break
            if replacement is None and physical.is_symlink():
                replacement = physical.readlink()
            if replacement is not None:
                followed += 1
                require(followed <= 40, "agent-link-migration-conflict")
                if replacement.is_absolute():
                    current = Path("/")
                    pending = list(replacement.parts[1:]) + pending
                else:
                    pending = list(replacement.parts) + pending
            else:
                current = candidate
        return current

    for original, target in migrations:
        for directory, dirs, files in os.walk(original):
            for name in dirs + files:
                path = Path(directory) / name
                destination = target / path.relative_to(original)
                if path.is_symlink() and destination not in materialized:
                    try:
                        referent = canonical(path)
                    except Refusal:
                        raise Refusal("agent-link-migration-conflict") from None
                    require(future_referent(destination) == relocated(referent), "agent-link-migration-conflict")


def validate_personal_files(profile, migrations=(), installing=False):
    """Apply the same file safety contract during setup, restoration, and readiness checks."""
    source, root = Path(profile["source"]), Path(profile["root"])
    instruction_copies = {}
    for agent, files in AGENT_FILES.items():
        base = Path(profile["agent_roots"][agent])
        original = next((old for old, target in migrations if target == base), base)
        for directory in dict.fromkeys((original, base)):
            private_path(directory)
            for filename, role in files.items():
                path = directory / filename
                private_path(path, detach=role == "instructions")
                require(not path.exists() or path.is_file(), "nonregular-file")
                if role == "instructions" and path.is_symlink():
                    expected = source / "home/.claude" / filename
                    if canonical(path) != expected:
                        require(installing, "instruction-link-conflict")
                        private_path(path, read_only_source=True)
                        require(path.is_file(), "instruction-link-conflict")
                        instruction_copies[base / filename] = read(path)
                elif role == "instructions" and path.exists():
                    replace_block(read(path), "instructions", "placeholder")
    for path in (claude_global(profile), root / ".config/workgrove/env.sh", profile_path(root)):
        private_path(path)
    configuration = root / ".config/workgrove/git"
    private_path(configuration)
    if configuration.exists():
        for directory, dirs, files in os.walk(configuration):
            for path in (Path(directory), *(Path(directory) / name for name in dirs + files)):
                require(not path.is_symlink(), "git-configuration-link-refused")
                private_path(path)
    return instruction_copies


def restore_can_backup(path, home):
    """Use the link's restoration role to permit regular home files only."""
    return home and stat.S_ISREG(path.lstat().st_mode)


def preflight_files(profile, migrations, restoring, restore_files=None):
    root = Path(profile["root"])
    moved = {start: target for start, target in migrations}
    for target, path, home in compatibility(profile):
        with refusal_path(display_path(path, root, profile)):
            private_path(path, detach=True)
            if path.exists() or path.is_symlink():
                if path.is_symlink() and canonical(path) == canonical(target):
                    continue
                require(not restoring or restore_can_backup(path, home), "restore-link-conflict")
                if restoring and restore_files is not None:
                    restore_files.add(path)
                if path.is_dir() and not path.is_symlink():
                    require(path in moved, "directory-conflict")
    for relative in (".bashrc", ".zshenv"):
        path = Path.home() / relative
        with refusal_path("~/" + relative):
            private_path(path, detach=True)
            require(not path.is_symlink() or path.exists(), "shell-configuration-link-unavailable")
            if path.exists():
                require(path.is_file(), "shell-configuration-conflict")
                text = replace_block(read(path), "environment", ". placeholder", first=relative == ".bashrc")
                if relative == ".bashrc":
                    try:
                        replace_block(text, "interactive path", "placeholder")
                    except ValueError:
                        raise Refusal("managed-text-conflict") from None
    instructions = validate_personal_files(profile, migrations, installing=not restoring)
    for agent in ("claude", "codex"):
        base = Path(profile["agent_roots"][agent])
        original = next((old for old, target in migrations if target == base), base)
        names = ("settings.json",) if agent == "claude" else ("hooks.json", "config.toml")
        for filename in names:
            path = original / filename
            private_path(path)
            if filename.endswith(".json") and path.exists():
                template = "home/.claude/settings.base.json" if agent == "claude" else "home/.codex/hooks.base.json"
                merge_hooks(json.loads(read(path)), json.loads(read(Path(profile["source"]) / template)))
    validate_migration_links(migrations, instructions, profile["agent_roots"].values())
    return instructions


def require_agent_roots(profile):
    for agent, value in profile["agent_roots"].items():
        target = Path(value)
        if profile["persist_agents"]:
            require(target.is_dir(), "persistent-agent-configuration-missing")
        elif target != canonical(Path.home() / ("." + agent)) and Path(profile["root"]) not in target.parents:
            require(target.is_dir(), "external-agent-configuration-missing")


def install_files(profile, restoring=False, instruction_copies=None, restore_files=()):
    root, source = Path(profile["root"]), Path(profile["source"])
    for path in profile["agent_roots"].values():
        mkdir(Path(path))
    for path, contents in (instruction_copies or {}).items():
        backup(path, root, display_path(path, root, profile))
        write(path, contents)
    for target, path, home in compatibility(profile):
        link(target, path, root, replace=not restoring or path in restore_files,
             label=display_path(path, root, profile))
    env = root / ".config/workgrove/env.sh"
    write(env, shell_environment(profile))
    for filename in (".bashrc", ".zshenv"):
        path = Path.home() / filename
        original = read(path, missing=True)
        contents = f". {shlex.quote(str(env))}"
        text = replace_block(original, "environment", contents, first=filename == ".bashrc")
        if filename == ".bashrc":
            text = replace_block(text, "interactive path", bash_path(profile))
        if path.is_symlink():
            backup(path, root)
        write(path, text)
    instructions = read(source / "home/.claude/AGENTS.md")
    for agent in ("claude", "codex"):
        path = Path(profile["agent_roots"][agent]) / "AGENTS.md"
        if path.is_symlink() and canonical(path) == canonical(source / "home/.claude/AGENTS.md"):
            continue
        if not path.exists():
            link(source / "home/.claude/AGENTS.md", path, root)
        else:
            require(not path.is_symlink(), "instruction-link-conflict")
            write(path, replace_block(read(path), "instructions", instructions))
    claude = Path(profile["agent_roots"]["claude"])
    claude_instructions = claude / "CLAUDE.md"
    if not claude_instructions.exists():
        write(claude_instructions, "@AGENTS.md\n")
    elif not claude_instructions.is_symlink() and "@AGENTS.md" not in read(claude_instructions):
        write(claude_instructions, replace_block(read(claude_instructions), "instructions", "@AGENTS.md"))
    if restoring:
        return
    # Merge owned hook commands without replacing sign-ins, settings, or foreign hooks.
    for agent, filename, template in (("claude", "settings.json", "home/.claude/settings.base.json"),
                                      ("codex", "hooks.json", "home/.codex/hooks.base.json")):
        path = Path(profile["agent_roots"][agent]) / filename
        base = json.loads(read(source / template))
        if path.exists():
            current = json.loads(read(path))
        elif agent == "claude":
            current = dict(base)
            for key in ("voice", "voiceEnabled", "theme", "statusLine"):
                current.pop(key, None)
            current.get("env", {}).pop("CLAUDE_CODE_DISABLE_MOUSE_CLICKS", None)
            if not current.get("env"):
                current.pop("env", None)
        else:
            current = {}
        if agent == "claude":
            current.setdefault("tui", base["tui"])
        merged = merge_hooks(current, base)
        write(path, json.dumps(merged, indent=2) + "\n")
    path = Path(profile["agent_roots"]["codex"]) / "config.toml"
    if not path.exists():
        text = read(source / "home/.codex/config.base.toml")
        text = "\n".join(line for line in text.splitlines() if not line.startswith("cli_auth_credentials_store"))
        write(path, text + "\n[tui]\nanimations = false\n")


@contextlib.contextmanager
def installation_lock(root):
    folder = root / ".config/workgrove"
    mkdir(folder)
    path = private_path(folder / "setup.lock")
    require(not path.is_symlink(), "lock-link-conflict")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode) and os.fstat(stream.fileno()).st_nlink == 1,
                "invalid-lock")
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


@configured_permissions
def install(args):
    if args.restore_only:
        return restore(args)
    root = canonical(args.root)
    expected_profile = read(profile_path(root), missing=True)
    require(expected_profile == args.permission_profile_snapshot, "profile-changed-retry-setup")
    previous = load_profile(root) if profile_path(root).exists() else None
    policy = args.storage or (previous["storage"] if previous else None)
    mount = args.mount or (previous["mount"] if previous else str(root) if policy == "volume" else None)
    storage(root, policy, mount)
    source = root / "workgrove"
    revision, manifest = validate_installation(source, args.revision)
    host = args.host or (previous["host"] if previous else os.environ.get("WT_HOST"))
    require(host and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", host), "host-alias-required")
    persist = args.persist_agents or bool(previous and previous["persist_agents"])
    agents, migrations = select_agent_roots(root, persist, previous)
    launch = dict(previous["agent_args"] if previous else {})
    for agent in ("claude", "codex"):
        value = getattr(args, agent + "_args_json")
        if value is not None:
            launch[agent] = json.loads(value)
    validate_agent_args(launch)
    profile = dict(schema=2, root=str(root), source=str(source), revision=revision, host=host,
                   storage=policy, mount=mount, trust_personal_volume=args.trust_personal_volume,
                   persist_agents=persist, agent_roots=agents,
                   agent_commands=select_agent_commands(root, migrations, previous),
                   tmux=args.with_tmux_conf or bool(previous and previous["tmux"]), agent_args=launch,
                   claude_config_dir=claude_directory(agents, persist, previous), runtime_manifest=manifest)
    instruction_copies = preflight_files(profile, migrations, False)
    global_target, global_contents, global_originals = plan_claude_state(profile, previous, migrations)
    with installation_lock(root):
        require(read(profile_path(root), missing=True) == expected_profile, "profile-changed-retry-setup")
        personal = prepare_git(root, args.git_identity, previous)
        for old, target in migrations:
            require(not target.exists(), "agent-configuration-conflict")
            mkdir(target.parent)
            temporary = target.with_name(".workgrove-agent-" + uuid.uuid4().hex)
            try:
                shutil.copytree(old, temporary, symlinks=True)
                os.chmod(temporary, 0o700)
                os.replace(temporary, target)
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
            backup(old, root, display_path(old, root, profile))
        if global_contents is not None:
            write(global_target, global_contents)
            for old in global_originals:
                backup(old, root, display_path(old, root, profile))
        global_path = root / ".config/workgrove/git/global"
        if canonical(personal) != canonical(global_path):
            write(global_path, '[include]\n    path = ' + git_quote(personal) + '\n')
        write(profile_path(root), json.dumps(profile, indent=2) + "\n")
        install_files(profile, instruction_copies=instruction_copies)
        write(machine_path(root), socket.gethostname() + "\n")
    print("workgrove: portable profile installed; run doctor before creating tasks")


@configured_permissions
def restore(args):
    root = canonical(args.root)
    expected_profile = read(profile_path(root))
    require(expected_profile == args.permission_profile_snapshot, "profile-changed-retry-setup")
    profile = load_profile(root)
    require(args.host, "host-alias-required")
    require(profile["host"] == args.host, "restore-host-mismatch")
    storage(root, profile["storage"], profile["mount"])
    validate_source(Path(profile["source"]), profile)
    restore_files = set()
    preflight_files(profile, [], True, restore_files)
    require((root / ".config/workgrove/git/global").is_file(), "personal-git-configuration-missing")
    require_agent_roots(profile)
    with installation_lock(root):
        require(read(profile_path(root)) == expected_profile, "profile-changed-retry-setup")
        install_files(profile, restoring=True, restore_files=restore_files)
        write(machine_path(root), socket.gethostname() + "\n")
        restore_summary(profile)
    print("workgrove: portable links and environment restored; run doctor before recovery")


def restore_summary(profile):
    root = Path(profile["root"])
    print("workgrove: restored root " + str(root) + "; alias " + profile["host"], file=sys.stderr)
    print("  persist_agents: " + ("yes" if profile["persist_agents"] else "no"), file=sys.stderr)
    for agent, files in AGENT_FILES.items():
        base = canonical(profile["agent_roots"][agent])
        inside = base == root or root in base.parents
        label = str(base) if inside else "<" + agent + "-root>"
        sign_in = next(name for name, role in files.items() if role == "state")
        present = (base / sign_in).is_file()
        print("  " + agent + ": " + label + "; inside root: " + ("yes" if inside else "no") +
              "; " + sign_in + ": " + ("present" if present else "absent"), file=sys.stderr)
    print("  ~/.gitconfig links to the saved Git config", file=sys.stderr)


def supported_os():
    data = {}
    for line in read(Path("/etc/os-release")).splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key] = value.strip('"')
    return data.get("ID") == "ubuntu" and data.get("VERSION_ID") in {"22.04", "24.04"}


def packages():
    names = {"git": "git", "bash": "bash", "tmux": "tmux", "jq": "jq", "python3": "python3",
             "rsync": "rsync", "ps": "procps", "timeout": "coreutils", "infocmp": "ncurses-bin"}
    missing = {package for command, package in names.items() if not shutil.which(command)}
    if shutil.which("infocmp"):
        for terminal in ("xterm-256color", "tmux-256color"):
            if run(["infocmp", terminal], allowed=(0, 1)).returncode:
                missing.add("ncurses-term")
    if not missing:
        return
    require(supported_os(), "unsupported-package-adapter")
    prefix = [] if os.geteuid() == 0 else ["sudo", "-n"]
    if prefix:
        require(shutil.which("sudo") and run([*prefix, "true"], allowed=(0, 1)).returncode == 0,
                "package-install-privilege-required")
    run([*prefix, "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update"])
    run([*prefix, "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", *sorted(missing)])


@configured_permissions
def bootstrap(args):
    root = canonical(args.root)
    old = load_profile(root) if profile_path(root).exists() else None
    policy = args.storage or (old["storage"] if old else None)
    mount = args.mount or (old["mount"] if old else str(root) if policy == "volume" else None)
    storage(root, policy, mount)
    source = root / "workgrove"
    if args.restore_only:
        return restore(args)
    if not source.exists():
        require(args.source and args.revision, "source-and-revision-required")
        url = urlsplit(args.source)
        require(url.scheme == "https" and url.hostname and not url.username and not url.password
                and not url.query and not url.fragment, "public-https-source-required")
        require(re.fullmatch(r"[0-9a-f]{40,64}", args.revision), "full-revision-required")
    else:
        validate_source(source)
    packages()
    if not source.exists():
        mkdir(root)
        with installation_lock(root):
            require(not source.exists(), "installation-created-concurrently")
            temporary = root / (".workgrove-checkout-" + uuid.uuid4().hex)
            try:
                git(["clone", "--no-checkout", "--", args.source, str(temporary)])
                if git(["cat-file", "-e", args.revision + "^{commit}"], temporary, allowed=(0, 1, 128)).returncode:
                    git(["fetch", "origin", args.revision], temporary)
                track = git(["symbolic-ref", "refs/remotes/origin/HEAD"], temporary).stdout.strip()
                require(git(["merge-base", "--is-ancestor", args.revision, track], temporary,
                            allowed=(0, 1)).returncode == 0, "revision-not-on-upstream")
                git(["checkout", "-b", "workgrove-install", args.revision], temporary)
                git(["branch", "--set-upstream-to", track.removeprefix("refs/remotes/"), "workgrove-install"], temporary)
                validate_source(temporary)
                os.replace(temporary, source)
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
    validate_installation(source, args.revision)
    args.root = str(root)
    # Execute the selected revision's installer rather than a different Mac revision's implementation.
    command = [sys.executable, "-B", str(source / "lib/workgrove/portable.py"), "install", "--root", str(root)]
    if args.trust_personal_volume or getattr(args, "strict_permissions", False):
        # The selected installer must not overwrite a concurrent trust change with stale acceptance.
        command.extend(("--expected-profile-digest", hashlib.sha256(args.permission_profile_snapshot.encode()).hexdigest()))
    for name in ("host", "storage", "mount", "revision", "git_identity", "claude_args_json", "codex_args_json"):
        value = getattr(args, name)
        if value is not None:
            command.extend(("--" + name.replace("_", "-"), value))
    if args.persist_agents:
        command.append("--persist-agents")
    if args.with_tmux_conf:
        command.append("--with-tmux-conf")
    if args.trust_personal_volume:
        command.append("--trust-personal-volume")
    if getattr(args, "strict_permissions", False):
        command.append("--strict-permissions")
    os.execv(sys.executable, command)


def _readiness(root=None):
    if root is None and os.environ.get("WT_REMOTE_ROOT"):
        root = os.environ["WT_REMOTE_ROOT"]
    if root is None and not (Path.home() / ".config/workgrove/profile.json").exists():
        command = Path.home() / ".local/bin/wt"
        if command.exists():
            executable = canonical(command)
            if len(executable.parents) > 2 and executable.parent.name == "bin":
                candidate = executable.parents[2]
                if any((candidate / name).exists() or (candidate / name).is_symlink() for name in (
                        ".config/workgrove/profile.json", ".config/workgrove/env.sh", ".config/workgrove/git/global")):
                    root = str(candidate)
    issues = []
    profile = None
    source_valid = False
    try:
        profile = load_profile(canonical(root) if root else None)
        with volume_permissions(Path(profile["root"]), profile["storage"], profile["mount"],
                                profile["trust_personal_volume"]):
            storage(Path(profile["root"]), profile["storage"], profile["mount"])
            validate_source(Path(profile["source"]), profile)
            source_valid = True
            require_agent_roots(profile)
            for target, path, home in compatibility(profile):
                private_path(path, detach=True)
                if not path.is_symlink() or canonical(path) != canonical(target):
                    if (path.exists() or path.is_symlink()) and not restore_can_backup(path, home):
                        issues.append("compatibility-links-conflict")
                    else:
                        issues.append("compatibility-links-missing")
            env = Path(profile["root"]) / ".config/workgrove/env.sh"
            validate_personal_files(profile)
            if not env.is_file() or read(env) != shell_environment(profile):
                issues.append("environment-incomplete")
    except (Refusal, OSError, ValueError, RuntimeError, UnicodeError) as error:
        code = str(error) if isinstance(error, Refusal) else "profile-unreadable"
        issues.append("portable-profile-missing" if root and code == "profile-missing" else code)
    environment = os.environ.copy()
    if profile:
        environment["PATH"] = str(Path(profile["root"]) / ".local/bin") + ":" + environment.get("PATH", "")
        environment["GIT_CONFIG_GLOBAL"] = str(Path(profile["root"]) / ".config/workgrove/git/global")
    tools = {name: shutil.which(name, path=environment.get("PATH")) is not None
             for name in ("bash", "git", "tmux", "jq", "python3", "rsync", "ps", "timeout", "infocmp")}
    if tools["bash"]:
        tools["bash"] = run([shutil.which("bash", path=environment["PATH"]), "-c", "((BASH_VERSINFO[0] >= 5))"],
                            env=environment, allowed=(0, 1)).returncode == 0
    if not all(tools.values()):
        issues.append("missing-prerequisites")
    if source_valid and tools["git"]:
        try:
            validate_objects(Path(profile["source"]))
        except Refusal as error:
            issues.append(str(error))
    if profile and sys.version_info < (3, 9):
        issues.append("python-3.9-required")
    if not os.access(Path.home() / ".local/bin/wt", os.X_OK):
        issues.append("remote-wt-missing")
    git_identity = False
    exclusions = False
    if tools["git"]:
        git_identity = all(run(["git", "config", "--global", "--includes", "--get", key], env=environment,
                               allowed=(0, 1)).stdout.strip() for key in ("user.name", "user.email"))
        if profile:
            exclusions = run(["git", "check-ignore", "--no-index", "--", ".worktrees/workgrove-check"],
                             cwd=profile["source"], env=environment, allowed=(0, 1, 128)).returncode == 0
    if profile and not git_identity:
        issues.append("personal-git-identity-missing")
    if profile and not exclusions:
        issues.append("worktree-exclusion-missing")
    terminals = {}
    if tools["infocmp"]:
        for term in ("xterm-256color", "tmux-256color"):
            terminals[term] = run(["infocmp", term], env=environment, allowed=(0, 1)).returncode == 0
        if not all(terminals.values()):
            issues.append("terminfo-missing")
    agents = {name: shutil.which(name, path=environment.get("PATH")) is not None for name in ("claude", "codex")}
    hooks = {}
    for agent in ("claude", "codex"):
        configured = Path(profile["agent_roots"][agent]) if profile else Path.home() / ("." + agent)
        path = configured / ("settings.json" if agent == "claude" else "hooks.json")
        try:
            config = json.loads(read(path))
            hooks[agent] = any("CMUX_TUI_HOOK" in hook.get("command", "")
                               for groups in config.get("hooks", {}).values()
                               for group in groups for hook in group.get("hooks", []))
        except (Refusal, OSError, ValueError, TypeError, AttributeError):
            hooks[agent] = False
    evidence = any(path.exists() or path.is_symlink() for path in (
        Path.home() / ".config/workgrove/profile.json", Path.home() / ".config/workgrove/env.sh"))
    if evidence and "profile-missing" in issues:
        issues.remove("profile-missing")
        issues.append("portable-profile-missing")
    legacy = profile is None and issues == ["profile-missing"]
    return {"schema": 1, "status": "legacy" if legacy else "incomplete" if issues else "ready",
            "ready": None if legacy else not issues, "issues": sorted(set(issues)), "tools": tools,
            "agents": agents, "git_identity": bool(git_identity), "worktree_exclusion": exclusions,
            "storage_permission_policy": ("trusted-personal-volume" if profile["trust_personal_volume"]
                                          else "strict") if profile else None,
            "storage_permission_warnings": ["unix-mode-checks-relaxed"] if profile and profile["trust_personal_volume"] else [],
            "terminfo": terminals, "native_hooks": hooks, "native_relay": "requires-row-check"}


def readiness(root=None):
    try:
        return _readiness(root)
    except (Refusal, OSError, ValueError, RuntimeError, UnicodeError, TypeError, AttributeError):
        return {"schema": 1, "status": "incomplete", "ready": False,
                "issues": ["readiness-probe-failed"], "tools": {}, "agents": {},
                "storage_permission_policy": None, "storage_permission_warnings": [],
                "native_hooks": {}, "native_relay": "requires-row-check"}


def reinstall(args):
    # Bare reruns use the owning checkout even when HOME has lost its profile link.
    root = canonical(args.source).parent
    require(profile_path(root).is_file(), "portable-profile-missing-run-explicit-setup")
    profile = load_profile(root)
    require(canonical(args.source) == Path(profile["source"]), "installation-identity-conflict")
    args.root = profile["root"]
    return install(args)


def reinstall_flags(args):
    accepted = " ".join(flag for action in args.reinstall_parser._actions for flag in action.option_strings
                        if flag.startswith("--") and flag != "--help")
    for flag in args.flags:
        args.reinstall_parser.parse_args([flag])
    print(accepted)


def root_recovery_hint(host, discovery):
    command = "wt -H " + (shlex.quote(host) if host else "<host>")
    found = discovery["status"] == "found"
    root = shlex.quote(discovery["root"]) if found else "<root>"
    text = "A host whose home folder was replaced looks new. "
    if not found:
        text += "The user must give the root. "
    return (text + "Run: " + command + " doctor --root " + root + " --json; "
            "then " + command + " setup --root " + root + " --restore-only. "
            "If doctor reports missing prerequisites, run full setup: " + command + " setup --root " + root + ".")


def doctor(args):
    result = readiness(args.root)
    if args.preflight:
        if result["ready"] is False and "profile-missing" not in result["issues"]:
            print("workgrove: portable environment needs explicit setup repair", file=sys.stderr)
            return 1
        return 0
    if args.probe:
        print("readiness\t" + json.dumps(result, separators=(",", ":")))
        return 0
    result["root_discovery"] = dict(status="not-run", root=None, same_machine=None)
    if args.host and not args.root and {"profile-missing", "remote-wt-missing"}.issubset(result["issues"]):
        result["root_discovery"] = discover_root(args.host)
    if args.json:
        print(json.dumps(result))
    else:
        print("workgrove: " + result["status"])
        if result["storage_permission_policy"] == "trusted-personal-volume":
            print("storage permissions: trusted personal volume; Unix mode checks are relaxed within its mount")
        for issue in result["issues"]:
            print("  " + issue)
        print("native relay and hook trust require a separate native-row check")
    if {"profile-missing", "remote-wt-missing"}.issubset(result["issues"]):
        print(root_recovery_hint(args.host, result["root_discovery"]),
              file=sys.stderr if args.json else sys.stdout)
    return 0 if result["ready"] is not False else 1


def main():
    parser = Parser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, function in (("bootstrap", bootstrap), ("install", install), ("restore", restore), ("reinstall", reinstall)):
        command = commands.add_parser(name)
        command.add_argument("--root", required=name != "reinstall")
        command.add_argument("--host")
        command.add_argument("--storage", choices=("volume", "os-disk"))
        command.add_argument("--mount")
        command.add_argument("--trust-personal-volume", action="store_true")
        command.add_argument("--strict-permissions", action="store_true")
        command.add_argument("--expected-profile-digest", help=argparse.SUPPRESS)
        command.add_argument("--revision")
        command.add_argument("--source")
        command.add_argument("--git-identity")
        command.add_argument("--persist-agents", action="store_true")
        command.add_argument("--with-tmux-conf", action="store_true")
        command.add_argument("--claude-args-json")
        command.add_argument("--codex-args-json")
        command.add_argument("--restore-only", action="store_true")
        command.add_argument("--refresh-config", action="store_true")
        command.set_defaults(run=function)
        if name == "reinstall":
            reinstall_parser = command
    command = commands.add_parser("reinstall-flags")
    command.add_argument("flags", nargs="*")
    command.set_defaults(run=reinstall_flags, reinstall_parser=reinstall_parser)
    command = commands.add_parser("doctor")
    command.add_argument("--root")
    command.add_argument("--host")
    command.add_argument("--json", action="store_true")
    command.add_argument("--probe", action="store_true")
    command.add_argument("--preflight", action="store_true")
    command.set_defaults(run=doctor)
    command = commands.add_parser("confirm-volume-trust")
    command.add_argument("--request-file", required=True)
    command.set_defaults(run=confirm_volume_request)
    try:
        args = parser.parse_args()
        require(sys.version_info >= ((3, 8) if args.command == "doctor" else (3, 9)), "python-3.9-required")
        if args.command in {"bootstrap", "install", "restore", "reinstall"}:
            os.umask(0o077)
        while True:
            try:
                return args.run(args) or 0
            except VolumeTrustRequired as error:
                if args.command in {"bootstrap", "install", "reinstall"} and not args.restore_only and \
                        not args.trust_personal_volume and not args.strict_permissions and confirm_volume_trust(error.request):
                    args.trust_personal_volume = True
                    continue
                print(json.dumps(error.request), file=sys.stderr)
                print("workgrove: use --trust-personal-volume only for a volume you exclusively control", file=sys.stderr)
                return 1
    except Refusal as error:
        print("workgrove: " + str(error) + (": " + error.path if error.path else ""), file=sys.stderr)
        if str(error) == "restore-host-mismatch":
            print("workgrove: full setup with the new alias changes the saved alias", file=sys.stderr)
    except (OSError, ValueError, RuntimeError, UnicodeError, TypeError, AttributeError):
        print("workgrove: portable-operation-failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
