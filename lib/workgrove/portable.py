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
import stat
import subprocess
import sys
import tempfile
import uuid
from urllib.parse import urlsplit


class Refusal(Exception):
    """Return a fixed diagnostic without disclosing personal configuration."""


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
        raise Refusal("invalid-arguments")


def require(value, code):
    if not value:
        raise Refusal(code)


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


def private_path(path, detach=False):
    path = Path(path)
    require(detach or not path.is_symlink() or path.exists(), "dangling-configuration-link")
    target = canonical(path.parent) / path.name if detach else canonical(path)
    outside_git(target)
    if target.exists():
        info = target.lstat()
        require(info.st_uid == os.getuid(), "foreign-owner")
        require(not stat.S_ISREG(info.st_mode) or info.st_nlink == 1, "hardlinked-file")
        require(stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode) or
                (detach and stat.S_ISLNK(info.st_mode)), "nonregular-file")
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
    require(isinstance(data, dict) and data.get("schema") == 1, "invalid-profile")
    allowed = {"schema", "root", "source", "revision", "host", "storage", "mount", "persist_agents",
               "agent_roots", "agent_commands", "tmux", "agent_args", "signatures"}
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
    require(isinstance(data["signatures"], dict) and set(data["signatures"]) == {
        "bin/wt", "install.sh", "lib/workgrove/portable.py"}, "invalid-profile")
    for value in data["signatures"].values():
        require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "invalid-profile")
    return data


def mounted(point):
    # Mountinfo also identifies bind mounts that share a device number with their parent.
    path = Path("/proc/self/mountinfo")
    if path.is_file():
        for line in read(path).splitlines():
            fields = line.split()
            if len(fields) > 4:
                name = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), fields[4])
                if Path(name) == point:
                    return True
        return False
    return os.path.ismount(point)


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


def signatures(source):
    return {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
            for name in ("bin/wt", "install.sh", "lib/workgrove/portable.py")}


def validate_source(source, profile=None):
    require(source.is_dir() and (source / ".git").is_dir(), "standalone-installation-required")
    require(canonical(source / ".git") == source / ".git", "installation-identity-conflict")
    for name in ("bin/wt", "install.sh", "lib/workgrove/portable.py", "home/.claude/AGENTS.md"):
        require((source / name).is_file() and canonical(source) in canonical(source / name).parents,
                "installation-identity-conflict")
    if profile:
        require(signatures(source) == profile["signatures"], "installation-changed-run-full-setup")


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
        require(not home.is_symlink() or home.exists(), "agent-configuration-link-unavailable")
        old = previous["agent_roots"][agent] if previous else None
        configured = os.environ.get(variable) or old
        current = canonical(configured) if configured else canonical(home)
        if previous and previous["persist_agents"]:
            require(current.is_dir(), "persistent-agent-configuration-missing")
        if configured and current != canonical(home) and root not in current.parents:
            require(current.is_dir(), "external-agent-configuration-missing")
        private_path(current)
        if persist and (not configured or current == canonical(home)) and not home.is_symlink():
            target = root / ".config" / agent
        else:
            target = current
        private_path(target)
        if persist and current != target and current.exists() and target.exists():
            raise Refusal("agent-configuration-conflict")
        if persist and home.exists() and canonical(home) != target and configured and current != canonical(home):
            raise Refusal("agent-home-conflict")
        if persist and current != target and current.exists():
            require(current.is_dir(), "invalid-agent-root")
            migrations.append((current, target))
        chosen[agent] = str(target)
    return chosen, migrations


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


def git_config_graph(start, destination):
    """Preserve Git entry order and anchor relative paths at their logical source locations."""
    mapping = {}

    def visit(path):
        path = Path(os.path.abspath(Path(path).expanduser()))
        require(path.is_file(), "git-include-missing")
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
                value = str(visit(include)) if include.is_file() else str(include)
                if section == "includeif":
                    for prefix in ("gitdir:", "gitdir/i:", "worktree:", "worktree/i:"):
                        if subsection.startswith(prefix + "./"):
                            subsection = prefix + str(path.parent) + "/" + subsection[len(prefix) + 2:]
                            break
            header = section + (" " + git_quote(subsection, subsection=True) if subsection is not None else "")
            entries.append("[" + header + "]\n\t" + name + (" = " + git_quote(value) if separator else "") + "\n")
        write(target, "".join(entries))
        return target

    return visit(start)


def prepare_git(root, identity, previous):
    destination = root / ".config/workgrove/git"
    if previous and (destination / "global").is_file() and not identity:
        return destination / "global"
    configured = os.environ.get("GIT_CONFIG_GLOBAL")
    candidates = [Path(configured)] if configured is not None else [
        Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "git/config", Path.home() / ".gitconfig"]
    originals = [path for path in candidates if path.is_file()]
    require(identity or originals, "personal-git-identity-required")
    if identity:
        require(Path(identity).is_file(), "personal-git-identity-required")
    # A generation keeps already installed configurations intact if preparation fails.
    generation = destination / uuid.uuid4().hex
    mkdir(generation)
    composite = generation / "global"
    if identity and not any(canonical(identity) == canonical(path) for path in originals):
        originals.append(Path(identity))
    bases = [git_config_graph(path, generation / str(index)) for index, path in enumerate(originals)]
    write(composite, "".join('[include]\n    path = ' + git_quote(base) + '\n' for base in bases))
    for key in ("user.name", "user.email"):
        result = git(["config", "--includes", "--file", str(composite), "--get", key], allowed=(0, 1))
        require(result.returncode == 0 and result.stdout.strip(), "personal-git-identity-required")
    prior = git(["config", "--includes", "--file", str(composite), "--path", "--get", "core.excludesfile"],
                allowed=(0, 1)).stdout.strip()
    excludes = ""
    if prior:
        old = Path(prior).expanduser()
        require(old.is_absolute(), "absolute-git-exclusions-required")
        if old.exists():
            excludes = read(old)
    ignore = generation / "ignore"
    write(ignore, excludes.rstrip("\n") + "\n.worktrees/\n")
    git(["config", "--file", str(composite), "core.excludesFile", str(ignore)])
    return composite


def backup(path, root):
    if not path.exists() and not path.is_symlink():
        return
    private_path(path, detach=True)
    folder = root / ".local/state/workgrove/backups" / uuid.uuid4().hex
    mkdir(folder)
    shutil.move(str(path), str(folder / path.name))


def link(target, path, root, replace=False):
    private_path(path, detach=True)
    if path.is_symlink() and canonical(path) == canonical(target):
        return
    if path.exists() or path.is_symlink():
        require(replace, "link-conflict")
        backup(path, root)
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
              "CLAUDE_CONFIG_DIR": profile["agent_roots"]["claude"],
              "CODEX_HOME": profile["agent_roots"]["codex"]}
    text = "# Workgrove exports only; sourcing this file performs no setup.\n"
    for name, value in values.items():
        text += f"export {name}={shlex.quote(value)}\n"
    for agent in ("claude", "codex"):
        value = json.dumps(profile["agent_args"].get(agent, []))
        text += f"export WT_{agent.upper()}_ARGS_JSON={shlex.quote(value)}\n"
    text += f'export PATH={shlex.quote(str(root / ".local/bin"))}:"$HOME/.local/bin:$PATH"\n'
    return text


def compatibility(profile):
    root, source = Path(profile["root"]), Path(profile["source"])
    links = []
    for item in sorted((source / "bin").iterdir()):
        if item.is_file():
            links.extend(((item, root / ".local/bin" / item.name),
                          (item, Path.home() / ".local/bin" / item.name)))
    for agent, command in profile["agent_commands"].items():
        if command:
            target = Path(command)
            links.append((target, root / ".local/bin" / agent))
            home = Path.home() / ".local/bin" / agent
            if not home.exists() or (home.is_symlink() and canonical(home) == canonical(target)):
                links.append((target, home))
    for item in sorted((source / "home/.agents/skills").iterdir()):
        if item.is_dir():
            links.extend(((item, root / ".agents/skills" / item.name),
                          (item, Path.home() / ".agents/skills" / item.name),
                          (item, Path(profile["agent_roots"]["claude"]) / "skills" / item.name)))
    for agent, default in (("claude", ".claude"), ("codex", ".codex")):
        if profile["persist_agents"]:
            links.append((Path(profile["agent_roots"][agent]), Path.home() / default))
    links.append((profile_path(root), Path.home() / ".config/workgrove/profile.json"))
    links.append((root / ".config/workgrove/env.sh", Path.home() / ".config/workgrove/env.sh"))
    links.append((root / ".config/workgrove/git/global", Path.home() / ".gitconfig"))
    if profile["tmux"]:
        links.append((source / "home/.tmux.conf", Path.home() / ".tmux.conf"))
    return [(a, b) for a, b in links if a.absolute() != b.absolute()]


def preflight_files(profile, migrations, restoring):
    root = Path(profile["root"])
    moved = {start: target for start, target in migrations}
    for target, path in compatibility(profile):
        private_path(path, detach=True)
        if path.exists() or path.is_symlink():
            if path.is_symlink() and canonical(path) == canonical(target):
                continue
            # Full installation can back up ordinary files. Restoration preserves new conflicting data.
            require(not restoring, "restore-link-conflict")
            if path.is_dir() and not path.is_symlink():
                require(path in moved, "directory-conflict")
    for relative in (".bashrc", ".zshenv"):
        path = Path.home() / relative
        private_path(path, detach=True)
        require(not path.is_symlink() or path.exists(), "shell-configuration-link-unavailable")
        if path.exists():
            require(path.is_file(), "shell-configuration-conflict")
            replace_block(read(path), "environment", ". placeholder", first=relative == ".bashrc")
    for agent, files in (("claude", ("settings.json", "AGENTS.md", "CLAUDE.md")),
                         ("codex", ("hooks.json", "config.toml", "AGENTS.md"))):
        base = Path(profile["agent_roots"][agent])
        for filename in files:
            private_path(base / filename, detach=filename.endswith(".md"))
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
        for filename in (("AGENTS.md", "CLAUDE.md") if agent == "claude" else ("AGENTS.md",)):
            path = original / filename
            if path.is_symlink():
                require(canonical(path) == canonical(Path(profile["source"]) / "home/.claude" / filename),
                        "instruction-link-conflict")
            elif path.exists():
                replace_block(read(path), "instructions", "placeholder")
    private_path(root / ".config/workgrove/env.sh")
    private_path(profile_path(root))


def require_agent_roots(profile):
    for agent, value in profile["agent_roots"].items():
        target = Path(value)
        if profile["persist_agents"]:
            require(target.is_dir(), "persistent-agent-configuration-missing")
        elif target != canonical(Path.home() / ("." + agent)) and Path(profile["root"]) not in target.parents:
            require(target.is_dir(), "external-agent-configuration-missing")


def install_files(profile, restoring=False):
    root, source = Path(profile["root"]), Path(profile["source"])
    for path in profile["agent_roots"].values():
        mkdir(Path(path))
    for target, path in compatibility(profile):
        link(target, path, root, replace=not restoring)
    env = root / ".config/workgrove/env.sh"
    write(env, shell_environment(profile))
    for filename in (".bashrc", ".zshenv"):
        path = Path.home() / filename
        original = read(path, missing=True)
        contents = f". {shlex.quote(str(env))}"
        text = replace_block(original, "environment", contents, first=filename == ".bashrc")
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
            for key in ("voice", "voiceEnabled", "theme", "tui", "statusLine"):
                current.pop(key, None)
            current.get("env", {}).pop("CLAUDE_CODE_DISABLE_MOUSE_CLICKS", None)
            if not current.get("env"):
                current.pop("env", None)
        else:
            current = {}
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
    root = canonical(args.root)
    expected_profile = read(profile_path(root), missing=True)
    require(expected_profile == args.permission_profile_snapshot, "profile-changed-retry-setup")
    previous = load_profile(root) if profile_path(root).exists() else None
    policy = args.storage or (previous["storage"] if previous else None)
    mount = args.mount or (previous["mount"] if previous else str(root) if policy == "volume" else None)
    storage(root, policy, mount)
    source = root / "workgrove"
    validate_source(source)
    revision = git(["rev-parse", "HEAD"], source).stdout.strip()
    require(not args.revision or args.revision == revision, "selected-revision-unavailable")
    require(not git(["status", "--porcelain", "--untracked-files=no"], source).stdout, "installation-has-local-edits")
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
    profile = dict(schema=1, root=str(root), source=str(source), revision=revision, host=host,
                   storage=policy, mount=mount, trust_personal_volume=args.trust_personal_volume,
                   persist_agents=persist, agent_roots=agents,
                   agent_commands=select_agent_commands(root, migrations, previous),
                   tmux=args.with_tmux_conf or bool(previous and previous["tmux"]), agent_args=launch,
                   signatures=signatures(source))
    preflight_files(profile, migrations, False)
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
            backup(old, root)
        global_path = root / ".config/workgrove/git/global"
        if canonical(personal) != canonical(global_path):
            write(global_path, '[include]\n    path = ' + git_quote(personal) + '\n')
        write(profile_path(root), json.dumps(profile, indent=2) + "\n")
        install_files(profile)
    print("workgrove: portable profile installed; run doctor before creating tasks")


@configured_permissions
def restore(args):
    root = canonical(args.root)
    expected_profile = read(profile_path(root))
    require(expected_profile == args.permission_profile_snapshot, "profile-changed-retry-setup")
    profile = load_profile(root)
    storage(root, profile["storage"], profile["mount"])
    validate_source(Path(profile["source"]), profile)
    preflight_files(profile, [], True)
    require((root / ".config/workgrove/git/global").is_file(), "personal-git-configuration-missing")
    require_agent_roots(profile)
    with installation_lock(root):
        require(read(profile_path(root)) == expected_profile, "profile-changed-retry-setup")
        install_files(profile, restoring=True)
    print("workgrove: portable links and environment restored; run doctor before recovery")


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
                if profile_path(candidate).is_file():
                    root = str(candidate)
    issues = []
    profile = None
    try:
        profile = load_profile(canonical(root) if root else None)
        with volume_permissions(Path(profile["root"]), profile["storage"], profile["mount"],
                                profile["trust_personal_volume"]):
            storage(Path(profile["root"]), profile["storage"], profile["mount"])
            validate_source(Path(profile["source"]), profile)
            require_agent_roots(profile)
            for target, path in compatibility(profile):
                private_path(path, detach=True)
                if not path.is_symlink() or canonical(path) != canonical(target):
                    issues.append("compatibility-links-missing")
                    break
            env = Path(profile["root"]) / ".config/workgrove/env.sh"
            private_path(env)
            for agent, path in profile["agent_roots"].items():
                private_path(Path(path) / ("settings.json" if agent == "claude" else "hooks.json"))
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
    profile = load_profile()
    require(canonical(args.source) == Path(profile["source"]), "installation-identity-conflict")
    args.root = profile["root"]
    return install(args)


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
    if args.json:
        print(json.dumps(result))
    else:
        print("workgrove: " + result["status"])
        if result["storage_permission_policy"] == "trusted-personal-volume":
            print("storage permissions: trusted personal volume; Unix mode checks are relaxed within its mount")
        for issue in result["issues"]:
            print("  " + issue)
        print("native relay and hook trust require a separate native-row check")
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
    command = commands.add_parser("doctor")
    command.add_argument("--root")
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
        print("workgrove: " + str(error), file=sys.stderr)
    except (OSError, ValueError, RuntimeError, UnicodeError, TypeError, AttributeError):
        print("workgrove: portable-operation-failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
