"""Register local SSH fragments while keeping supplier state read-only."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("invalid-arguments")


class Refusal(Exception):
    """Carry an allowlisted diagnostic without configuration contents."""


ALIAS = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}\Z")
MARKER = re.compile(r"# (>>>|<<<) wt-ssh-host (\S+)\r?\n?\Z")
SAFE_WORD = re.compile(r"[A-Za-z0-9_.:@+-]+\Z")
OPAQUE_PIN = re.compile(r"[A-Za-z0-9_.:@+/\[\]-]+\Z")
PATH_KEYS = {"identityfile", "userknownhostsfile"}
BOOL_KEYS = {"identitiesonly", "hashknownhosts"}
INT_KEYS = {"port", "serveraliveinterval", "serveralivecountmax", "connecttimeout", "connectionattempts"}
KEYS = PATH_KEYS | BOOL_KEYS | INT_KEYS | {
    "hostname", "user", "hostkeyalias", "hostkeyalgorithms", "stricthostkeychecking",
}
# Compare security policy as well as the endpoint. Extra identities can change authentication.
EFFECTIVE_KEYS = {
    "hostname", "port", "user", "hostkeyalias", "stricthostkeychecking", "identityfile",
    "userknownhostsfile", "globalknownhostsfile", "knownhostscommand", "verifyhostkeydns",
    "hostkeyalgorithms", "identitiesonly", "checkhostip", "updatehostkeys",
}


def require(condition, code):
    if not condition:
        raise Refusal(code)


def read_text(path, limit=1024 * 1024, missing=False):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "nonregular-file")
            data = stream.read(limit + 1)
    except FileNotFoundError:
        if missing and not path.is_symlink():
            return ""
        raise Refusal("missing-file") from None
    require(len(data) <= limit, "file-too-large")
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        raise Refusal("invalid-text") from None
    require(not any(ord(c) < 32 and c not in "\t\r\n" for c in text), "invalid-text")
    return text


def tokens(line):
    # OpenSSH supports double quotes. Shell quoting and shell expansion are not accepted.
    quoted = False
    for index, char in enumerate(line):
        if char == '"':
            quoted = not quoted
        elif char == "#" and not quoted:
            line = line[:index]
            break
    require("'" not in line and "\\" not in line, "unsupported-quoting")
    lexer = shlex.shlex(line, posix=True)
    lexer.whitespace_split = True
    lexer.commenters = "#"
    lexer.quotes = '"'
    try:
        return list(lexer)
    except ValueError:
        raise Refusal("invalid-quoting") from None


def decode_path(value):
    require("${" not in value and "`" not in value and "$" not in value, "unsupported-expansion")
    require("%" not in value.replace("%%", ""), "unsupported-expansion")
    value = value.replace("%%", "%")
    if value.startswith("~/"):
        value = str(Path.home()) + value[1:]
    require(value.startswith("/") and not any(c in value for c in "*?[]"), "nonliteral-path")
    return value


def fragment(path):
    fields = {}
    for line in read_text(path, 256 * 1024).splitlines():
        parts = tokens(line)
        if not parts:
            continue
        # Both Keyword value and Keyword=value are standard SSH spellings.
        first = parts.pop(0)
        if "=" in first:
            key, value = first.split("=", 1)
            parts.insert(0, value)
        else:
            key = first
            if parts and parts[0] == "=":
                parts.pop(0)
        key = key.lower()
        require(key in KEYS, "unsupported-directive")
        require(key not in fields, "duplicate-directive")
        require(len(parts) == 1 and parts[0] != "", "invalid-value")
        value = parts[0]
        if key in PATH_KEYS:
            decode_path(value)
        elif key in BOOL_KEYS:
            require(value in {"yes", "no"}, "invalid-boolean")
        elif key in INT_KEYS:
            require(bool(re.fullmatch(r"[0-9]{1,8}", value)), "invalid-number")
            number = int(value)
            require(1 <= number <= 65535 if key == "port" else number <= 86400, "invalid-number")
        elif key == "hostkeyalias":
            require(bool(OPAQUE_PIN.fullmatch(value)) and not value.startswith("-"), "invalid-value")
        elif key == "stricthostkeychecking":
            require(value == "yes", "strict-trust-required")
        elif key == "hostkeyalgorithms":
            require(bool(re.fullmatch(r"[+^\-]?[A-Za-z0-9@._,\-]+", value)), "invalid-algorithms")
        else:
            require(bool(SAFE_WORD.fullmatch(value)) and not value.startswith("-"), "invalid-value")
        fields[key] = value
    require("hostname" in fields, "missing-hostname")
    return fields


def literal_path(value):
    require(not any(c in value for c in '\r\n\x00"\\$`*?[]'), "unsupported-path")
    # Include expands tokens, so encode literal percent signs.
    return value.replace("%", "%%")


def block(alias, path, pin):
    result = f"# >>> wt-ssh-host {alias}\nHost {alias}\n    StrictHostKeyChecking yes\n"
    if pin is not None:
        result += f"    HostKeyAlias {pin}\n"
    result += f'    Include "{literal_path(str(path))}"\nHost *\n# <<< wt-ssh-host {alias}\n\n'
    return result


def registrations(text):
    """Accept only regions with the exact structure that this helper writes."""
    lines = text.splitlines(keepends=True)
    found = {}
    start = None
    offset = 0
    for index, line in enumerate(lines):
        if "# >>> wt-ssh-host" in line or "# <<< wt-ssh-host" in line:
            match = MARKER.fullmatch(line)
            require(match is not None, "malformed-managed-region")
            direction, alias = match.groups()
            require(bool(ALIAS.fullmatch(alias)), "malformed-managed-region")
            if direction == ">>>":
                require(start is None and alias not in found, "malformed-managed-region")
                start = (alias, index, offset)
            else:
                require(start is not None and start[0] == alias, "malformed-managed-region")
                body = lines[start[1] + 1:index]
                require(len(body) in {4, 5} and body[-1] == "Host *\n", "malformed-managed-region")
                require(body[0] == f"Host {alias}\n" and body[1] == "    StrictHostKeyChecking yes\n",
                        "malformed-managed-region")
                pin = None
                if len(body) == 5:
                    identity = tokens(body[2])
                    require(len(identity) == 2 and identity[0] == "HostKeyAlias", "malformed-managed-region")
                    pin = identity[1]
                    require(bool(OPAQUE_PIN.fullmatch(pin)), "malformed-managed-region")
                include = tokens(body[-2])
                require(len(include) == 2 and include[0] == "Include", "malformed-managed-region")
                path = decode_path(include[1])
                end = offset + len(line)
                if index + 1 < len(lines) and lines[index + 1] == "\n":
                    end += 1
                found[alias] = {"start": start[2], "end": end, "path": path, "pin": pin}
                start = None
        offset += len(line)
    require(start is None, "malformed-managed-region")
    return found


def without_region(text, regions, alias):
    if alias not in regions:
        return text
    region = regions[alias]
    return text[:region["start"]] + text[region["end"]:]


def refuse_explicit_alias(text, alias):
    # Leave wildcard defaults intact. OpenSSH resolves their effective policy later.
    for line in text.splitlines():
        lexer = shlex.shlex(line, posix=True)
        lexer.whitespace_split = True
        lexer.commenters = "#"
        try:
            parts = list(lexer)
        except ValueError:
            raise Refusal("invalid-existing-config") from None
        if not parts:
            continue
        first = parts.pop(0)
        if "=" in first:
            key, value = first.split("=", 1)
            parts.insert(0, value)
        else:
            key = first
        if key.lower() == "host":
            require(not any(p.lower() == alias.lower() for p in parts), "unmanaged-alias")
        if key.lower() == "match":
            # Refuse literal references in conditional sections without changing their control flow.
            words = " ".join(parts).replace(",", " ").split()
            require(alias.lower() not in [word.lower() for word in words], "unmanaged-alias")


def physical(path):
    try:
        resolved = path.expanduser().resolve()
    except (OSError, RuntimeError):
        raise Refusal("invalid-destination") from None
    require(not path.is_symlink() or resolved.exists(), "dangling-config-link")
    return resolved


def outside_git(path):
    for parent in (path, *path.parents):
        require(parent.name != ".git", "repository-destination")
        require(not (parent / ".git").exists(), "repository-destination")
        # Bare repositories and linked-worktree administrative directories also hold private state.
        require(not ((parent / "HEAD").exists() and
                     ((parent / "objects").is_dir() or (parent / "commondir").is_file())),
                "repository-destination")


def destination(path):
    path = physical(path)
    outside_git(path)
    require(not path.exists() or path.is_file(), "invalid-destination")
    if path.exists():
        require(path.stat().st_nlink == 1, "hardlinked-destination")
    return path


def private_write(path, text):
    fd, name = tempfile.mkstemp(prefix=".wt-ssh-host-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def edit_config(config):
    config = destination(config)
    backup = config.with_name(config.name + ".bak")
    lock = config.with_name(config.name + ".wt-ssh-host.lock")
    for path in (backup, lock):
        require(not path.is_symlink(), "linked-sidecar")
        destination(path)
    missing = []
    parent = config.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "nonregular-file")
        require(os.fstat(stream.fileno()).st_nlink == 1, "hardlinked-destination")
        os.fchmod(stream.fileno(), 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX)
        original = read_text(config, missing=True)
        yield config, backup, original


def replace_config(config, backup, original, updated):
    require(read_text(config, missing=True) == original, "config-changed")
    if updated == original:
        return
    if config.exists():
        private_write(backup, original)
    private_write(config, updated)


def ssh_run(args, timeout=15):
    try:
        return subprocess.run(["ssh", *args], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise Refusal("ssh-unavailable") from None


def effective(text, alias, parent):
    fd, name = tempfile.mkstemp(prefix=".wt-ssh-host-check-", dir=str(parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        result = ssh_run(["-G", "-F", name, alias])
        require(result.returncode == 0, "effective-config-unavailable")
        output = result.stdout.decode("utf-8", errors="replace")
        fields = {}
        for line in output.splitlines():
            key, separator, value = line.partition(" ")
            if separator and key in EFFECTIVE_KEYS:
                fields.setdefault(key, []).append(value)
        require(all(key in fields for key in ("hostname", "user", "port", "stricthostkeychecking")),
                "effective-config-unavailable")
        return fields
    finally:
        os.unlink(name)


def validate_effective(config, alias, managed, updated):
    expected = effective(managed, alias, config.parent)
    actual = effective(updated, alias, config.parent)
    require(actual == expected, "effective-config-conflict")


def check_registration(region):
    try:
        fields = fragment(Path(region["path"]))
    except Refusal as error:
        return "missing" if str(error) == "missing-file" else "invalid"
    except OSError:
        return "unreadable"
    if fields.get("hostkeyalias") != region["pin"]:
        return "identity-changed"
    return "configured"


def add(args):
    require(bool(ALIAS.fullmatch(args.alias)), "invalid-alias")
    path = Path(args.fragment).expanduser().absolute()
    literal_path(str(path))
    fields = fragment(path)
    managed = block(args.alias, path, fields.get("hostkeyalias"))
    with edit_config(Path(args.config)) as (config, backup, original):
        regions = registrations(original)
        old = regions.get(args.alias)
        if old:
            require(old["pin"] == fields.get("hostkeyalias"), "identity-change-requires-registration-removal")
        for alias, region in regions.items():
            if alias != args.alias:
                require(check_registration(region) == "configured", "invalid-existing-registration")
        rest = without_region(original, regions, args.alias)
        refuse_explicit_alias(rest, args.alias)
        updated = managed + rest
        if old and original[old["start"]:old["end"]] == managed:
            updated = original
        validate_effective(config, args.alias, managed, updated)
        replace_config(config, backup, original, updated)
    # Keep the written registration after verification fails. Never print captured SSH output.
    for region in registrations(read_text(config)).values():
        require(check_registration(region) == "configured", "registered-but-unavailable")
    try:
        result = ssh_run(["-F", str(config), "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                          "-o", "ConnectionAttempts=1", "-o", "StrictHostKeyChecking=yes",
                          "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", args.alias, "true"])
    except Refusal:
        raise Refusal("registered-but-unavailable") from None
    if result.returncode:
        raise Refusal("registered-but-unavailable")
    print("wt-ssh-host: registered and SSH verified")


def remove(args):
    require(bool(ALIAS.fullmatch(args.alias)), "invalid-alias")
    with edit_config(Path(args.config)) as (config, backup, original):
        regions = registrations(original)
        require(args.alias in regions, "unregistered-alias")
        updated = without_region(original, regions, args.alias)
        replace_config(config, backup, original, updated)
    print("wt-ssh-host: registration removed")


def listing(args):
    text = read_text(physical(Path(args.config)), missing=True)
    regions = registrations(text)
    rows = [{"alias": alias, "fragment": region["path"], "status": check_registration(region)}
            for alias, region in regions.items()]
    if args.json:
        print(json.dumps(rows))
    else:
        for row in rows:
            print(f'{row["alias"]}\t{row["status"]}')


def checking(args):
    require(bool(ALIAS.fullmatch(args.alias)), "invalid-alias")
    config = physical(Path(args.config))
    text = read_text(config, missing=True)
    regions = registrations(text)
    for region in regions.values():
        require(check_registration(region) == "configured", "invalid-managed-registration")
    if args.alias in regions:
        region = regions[args.alias]
        managed = block(args.alias, Path(region["path"]), region["pin"])
        parent = Path(tempfile.gettempdir()).resolve()
        outside_git(parent)
        expected = effective(managed, args.alias, parent)
        actual = effective(text, args.alias, parent)
        require(expected == actual, "effective-config-conflict")


def main():
    parser = PrivateArgumentParser(prog="wt-ssh-host", description=__doc__)
    parser.add_argument("-F", dest="config", default=str(Path.home() / ".ssh/config"), metavar="CONFIG")
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("add", help="register a fragment and verify SSH")
    create.add_argument("alias")
    create.add_argument("--fragment", required=True, metavar="PATH")
    create.set_defaults(run=add)
    delete = commands.add_parser("rm", help="remove only a managed registration")
    delete.add_argument("alias")
    delete.set_defaults(run=remove)
    check = commands.add_parser("check", help="validate managed configuration before a connection")
    check.add_argument("alias")
    check.set_defaults(run=checking)
    show = commands.add_parser("list", help="report local registrations without SSH")
    show.add_argument("--json", action="store_true")
    show.set_defaults(run=listing)
    if sys.argv[1:] == ["help"]:
        parser.print_help()
        return 0
    try:
        args = parser.parse_args()
        args.run(args)
    except Refusal as error:
        print(f"wt-ssh-host: {error}", file=sys.stderr)
        return 1
    except (OSError, RuntimeError, UnicodeError, ValueError):
        print("wt-ssh-host: local-file-operation-failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
