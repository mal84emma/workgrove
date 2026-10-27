"""Exercise portable setup and home replacement with synthetic personal data."""

import importlib.util
import io
import json
import os
import pty
import re
import select
import shlex
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from argparse import Namespace

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("portable", REPO / "lib/workgrove/portable.py")
portable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portable)
CANARY = "SYNTHETIC-CONFIDENTIAL-CANARY"


class RootDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=os.environ.get("TEST_ROOT"))
        self.addCleanup(self.scratch.cleanup)
        self.mount = Path(self.scratch.name).resolve()
        self.original_mount_list = getattr(portable, "mount_list", None)
        self.mounts = patch.object(portable, "mount_list", return_value=[(self.mount, "ext4")], create=True)
        self.mounts.start()
        self.addCleanup(self.mounts.stop)

    def candidate(self, relative="owner/root", host="test-host"):
        root = self.mount / relative
        path = root / ".config/workgrove/profile.json"
        path.parent.mkdir(parents=True)
        profile = dict(schema=1, root=str(root), source=str(root / "workgrove"), revision="a" * 40,
                       host=host, storage="volume", mount=str(self.mount), persist_agents=True,
                       agent_roots={name: str(root / name) for name in ("claude", "codex")},
                       agent_commands=dict(claude=None, codex=None), tmux=False, agent_args={},
                       signatures={name: "b" * 64 for name in ("bin/wt", "install.sh", "lib/workgrove/portable.py")})
        path.write_text(json.dumps(profile))
        return root

    def discover(self):
        return portable.discover_root("test-host")

    def test_found_and_machine_record_states(self):
        root = self.candidate()
        record = root / ".local/state/workgrove/machine"
        for value, expected in ((None, None), (portable.socket.gethostname(), True), ("other-machine", False)):
            with self.subTest(expected=expected):
                if value is not None:
                    record.parent.mkdir(parents=True, exist_ok=True)
                    record.write_text(value + "\n")
                before = record.read_bytes() if record.exists() else None
                self.assertEqual(self.discover(), dict(status="found", root=str(root), same_machine=expected))
                self.assertEqual(record.read_bytes() if record.exists() else None, before)

    def test_none_other_alias_and_ambiguous_disclose_no_candidates(self):
        self.assertEqual(self.discover(), dict(status="none", root=None, same_machine=None))
        secret = self.candidate("private/other", "private-alias")
        self.assertEqual(self.discover()["status"], "none")
        self.candidate()
        report = self.discover()
        self.assertEqual(report["status"], "found")
        self.assertNotIn(str(secret), json.dumps(report))
        self.assertNotIn("private-alias", json.dumps(report))
        self.candidate("second/root")
        self.assertEqual(self.discover(), dict(status="ambiguous", root=None, same_machine=None))

    def test_duplicate_mounts_and_canonical_roots_count_once(self):
        root = self.candidate()
        with patch.object(portable, "mount_list", return_value=[(self.mount, "ext4"), (self.mount, "ext4"),
                                                               (self.mount / ".", "ext4")]):
            self.assertEqual(self.discover()["root"], str(root))

    def test_hidden_and_shadowed_mount_folders_are_skipped(self):
        self.candidate("")
        with self.subTest(kind="shadowed"), patch.object(portable, "mount_list", return_value=[
                (self.mount, "ext4"), (self.mount, "tmpfs")]):
            self.assertEqual(self.discover()["status"], "none")
        root = self.candidate(".hidden-mount")
        path = portable.profile_path(root)
        data = json.loads(path.read_text())
        data["mount"] = str(root)
        path.write_text(json.dumps(data))
        with self.subTest(kind="hidden"), patch.object(portable, "mount_list", return_value=[(root, "ext4")]):
            self.assertEqual(self.discover()["status"], "none")

    def test_excluded_nested_mount_preserves_candidates_and_folder_budget(self):
        self.candidate("temporary/root")
        mounts = [(self.mount, "ext4"), (self.mount / "temporary", "tmpfs")]
        with patch.object(portable, "mount_list", return_value=mounts):
            with self.subTest(stage="candidate"):
                self.assertEqual(self.discover()["status"], "none")
            root = self.candidate()
            for index in range(4096):
                (self.mount / "temporary" / ("folder-%04d" % index)).mkdir()
            with self.subTest(stage="budget"):
                self.assertEqual(self.discover()["root"], str(root))

    def test_nested_volume_uses_only_its_own_mount_scope(self):
        root = self.candidate("volume/root")
        mount = self.mount / "volume"
        with patch.object(portable, "mount_list", return_value=[(self.mount, "ext4"), (mount, "ext4")]):
            self.assertEqual(self.discover()["status"], "none")
            path = portable.profile_path(root)
            data = json.loads(path.read_text())
            data["mount"] = str(mount)
            path.write_text(json.dumps(data))
            self.assertEqual(self.discover()["root"], str(root))

    def test_nested_mounts_on_profile_components_are_skipped(self):
        root = self.candidate()
        for relative in (".config", ".config/workgrove", ".config/workgrove/profile.json"):
            with self.subTest(relative=relative), patch.object(portable, "mount_list", return_value=[
                    (self.mount, "ext4"), (root / relative, "tmpfs")]):
                self.assertEqual(self.discover()["status"], "none")

    def test_mountinfo_decodes_spaces_and_optional_fields(self):
        root = self.candidate("space root")
        profile = portable.profile_path(root)
        data = json.loads(profile.read_text())
        data["mount"] = str(root)
        profile.write_text(json.dumps(data))
        escaped = str(root).replace(" ", r"\040")
        content = "10 1 0:1 / " + escaped + " rw shared:2 master:1 - fuse.test source rw\n"
        original = portable.read
        with patch.object(portable, "mount_list", wraps=self.original_mount_list), \
                patch.object(portable, "read", side_effect=lambda path, **kw: content if str(path) == "/proc/self/mountinfo" else original(path, **kw)), \
                patch.object(Path, "is_file", autospec=True, side_effect=lambda path: True if str(path) == "/proc/self/mountinfo" else path.exists()):
            self.assertEqual(portable.mount_list(), [(root, "fuse.test")])
            self.assertTrue(portable.mounted(root))
            self.assertEqual(self.discover()["root"], str(root))

    def test_missing_mountinfo_and_excluded_mount_types(self):
        root = self.candidate()
        with patch.object(portable, "mount_list", wraps=self.original_mount_list), \
                patch.object(Path, "is_file", return_value=False):
            self.assertEqual(self.discover()["status"], "none")
        for kind in ("proc", "sysfs", "tmpfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "mqueue", "overlay", "squashfs"):
            with self.subTest(kind=kind), patch.object(portable, "mount_list", return_value=[(self.mount, kind)]):
                self.assertEqual(self.discover()["status"], "none")
        with patch.object(portable, "mount_list", return_value=[(Path("/"), "ext4"), (portable.profile_path(root), "ext4")]):
            self.assertEqual(self.discover()["status"], "none")

    def test_links_hidden_folders_and_excess_depth_are_not_followed(self):
        root = self.candidate()
        for relative in (".config/workgrove/profile.json", ".config/workgrove", ".config"):
            with self.subTest(relative=relative):
                path = root / relative
                saved = self.mount / "saved"
                path.rename(saved)
                path.symlink_to(saved)
                self.assertEqual(self.discover()["status"], "none")
                path.unlink()
                saved.rename(path)
        self.candidate(".hidden/root")
        self.candidate("too/deep/root")
        linked = self.mount / "linked"
        root.rename(self.mount / ".saved")
        linked.symlink_to(self.mount / ".saved")
        self.assertEqual(self.discover()["status"], "none")

    def test_candidate_exceptions_do_not_change_readiness(self):
        root = self.candidate()
        bad = self.candidate("broken/root")
        other = self.candidate("other/root", "private-alias")
        path = portable.profile_path(bad)
        data = json.loads(path.read_text())
        data["root"] = 42
        path.write_text(json.dumps(data))
        baseline = dict(ready=False, issues=["profile-missing", "remote-wt-missing"])
        args = Namespace(root=None, host="test-host", preflight=False, probe=False, json=True)
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(portable, "readiness", return_value=baseline.copy()), \
                patch("sys.stdout", output), patch("sys.stderr", errors):
            self.assertEqual(portable.doctor(args), 1)
        result = json.loads(output.getvalue())
        self.assertEqual(result["issues"], baseline["issues"])
        self.assertFalse(result["ready"])
        self.assertEqual(result["root_discovery"]["root"], str(root))
        for private in (str(bad), str(other), "private-alias"):
            self.assertNotIn(private, output.getvalue() + errors.getvalue())
        self.assertFalse((root / ".local/state/workgrove/machine").exists())
        original = portable.load_profile
        def load(candidate):
            if candidate == bad:
                raise Exception("private")
            return original(candidate)
        with patch.object(portable, "load_profile", side_effect=load):
            self.assertEqual(self.discover()["root"], str(root))

    def test_unreadable_folders_and_profile_scope_mismatches_are_skipped(self):
        root = self.candidate()
        with patch.object(portable.os, "access", return_value=False):
            self.assertEqual(self.discover()["status"], "none")
        path = portable.profile_path(root)
        original = json.loads(path.read_text())
        for updates in ({"storage": "os-disk"}, {"mount": str(root)}, {"root": str(self.mount)}):
            with self.subTest(updates=updates):
                path.write_text(json.dumps(dict(original, **updates)))
                self.assertEqual(self.discover()["status"], "none")

    def test_folder_and_monotonic_time_limits_discard_partial_matches(self):
        self.candidate("")
        for index in range(4096):
            (self.mount / ("folder-%04d" % index)).mkdir()
        self.assertEqual(self.discover(), dict(status="incomplete", root=None, same_machine=None))
        original = portable.os.scandir
        with patch.object(portable.time, "monotonic", return_value=0) as clock:
            def expire(path):
                clock.return_value = 11
                return original(path)
            with patch.object(portable.os, "scandir", side_effect=expire):
                self.assertEqual(self.discover(), dict(status="incomplete", root=None, same_machine=None))
        with patch.object(portable.time, "monotonic", side_effect=[0, 0, 11]):
            self.assertEqual(self.discover(), dict(status="incomplete", root=None, same_machine=None))

    def test_doctor_discovery_gates_and_probe_record(self):
        baseline = dict(ready=False, issues=["profile-missing", "remote-wt-missing"])
        for overrides in ({"probe": True}, {"preflight": True}, {"root": str(self.mount)}, {"host": None},
                          {"issues": ["profile-missing"]}):
            args = Namespace(root=None, host="test-host", preflight=False, probe=False, json=True)
            report = baseline.copy()
            for key, value in overrides.items():
                if key == "issues":
                    report[key] = value
                else:
                    setattr(args, key, value)
            output = io.StringIO()
            with self.subTest(overrides=overrides), patch.object(portable, "readiness", return_value=report), \
                    patch.object(portable, "discover_root") as discovery, patch("sys.stdout", output), patch("sys.stderr", io.StringIO()):
                portable.doctor(args)
                discovery.assert_not_called()
                if args.probe:
                    self.assertEqual(json.loads(output.getvalue().split("\t", 1)[1]), baseline)
                elif not args.preflight:
                    self.assertEqual(json.loads(output.getvalue())["root_discovery"],
                                     dict(status="not-run", root=None, same_machine=None))

    def test_doctor_hint_uses_only_a_found_root_and_keeps_readiness(self):
        root = str(self.mount / "space root's data")
        baseline = dict(status="incomplete", ready=False, issues=["profile-missing", "remote-wt-missing"],
                        warnings=[], storage_permission_policy=None, tools={})
        for status in ("found", "none", "ambiguous", "incomplete", "not-run"):
            for as_json in (False, True):
                with self.subTest(status=status, json=as_json):
                    discovery = dict(status=status, root=root if status == "found" else None, same_machine=None)
                    args = Namespace(root=None, host="test-host", preflight=False, probe=False, json=as_json)
                    output, errors = io.StringIO(), io.StringIO()
                    with patch.object(portable, "readiness", return_value=baseline.copy()), \
                            patch.object(portable, "discover_root", return_value=discovery), \
                            patch("sys.stdout", output), patch("sys.stderr", errors):
                        self.assertEqual(portable.doctor(args), 1)
                    hint = errors.getvalue() if as_json else output.getvalue()
                    if as_json:
                        result = json.loads(output.getvalue())
                        self.assertEqual({key: result[key] for key in baseline}, baseline)
                        self.assertEqual(result["root_discovery"], discovery)
                    else:
                        self.assertEqual(errors.getvalue(), "")
                    if status == "found":
                        for command in ("doctor --root " + shlex.quote(root) + " --json",
                                        "setup --root " + shlex.quote(root) + " --restore-only"):
                            self.assertIn("wt -H test-host " + command, hint)
                        self.assertNotIn("The user must give the root.", hint)
                    else:
                        self.assertIn("The user must give the root.", hint)
                        self.assertIn("wt -H test-host doctor --root <root> --json", hint)
                        self.assertNotIn(root, hint)


class PortableTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="portable-", dir=os.environ.get("TEST_ROOT"))
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir(mode=0o700)
        self.root = self.base / "durable"
        self.root.mkdir(mode=0o700)
        self.source = self.root / "workgrove"
        self.source.mkdir()
        for name in ("bin", "lib", "home"):
            shutil.copytree(REPO / name, self.source / name, symlinks=True)
        shutil.copy2(REPO / "install.sh", self.source / "install.sh")
        self.tools = self.base / "tools"
        self.tools.mkdir()
        for command in ("python3", "bash", "git", "jq", "sh", "uname", "id", "ps"):
            target = sys.executable if command == "python3" else shutil.which(command)
            (self.tools / command).symlink_to(target)
        for command in ("tmux", "rsync", "timeout", "infocmp", "claude", "codex"):
            tool = self.tools / command
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o700)
        self.env = dict(HOME=str(self.home), PATH=str(self.tools) + ":/usr/bin:/bin", GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=str(self.home / ".gitconfig"), GIT_ALLOW_PROTOCOL="file",
                        GIT_AUTHOR_NAME="Test User", GIT_AUTHOR_EMAIL="test@example.invalid",
                        GIT_COMMITTER_NAME="Test User", GIT_COMMITTER_EMAIL="test@example.invalid")
        (self.home / ".gitconfig").write_text('[include]\n path = ~/.gitconfig.local\n[core]\n excludesFile = ' +
                                               str(self.home / "ignore") + '\n[credential]\n helper = !echo ' + CANARY + '\n')
        (self.home / ".gitconfig.local").write_text('[user]\n name = Test User\n email = test@example.invalid\n')
        (self.home / "ignore").write_text("private-example\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "Create synthetic public installation")
        self.revision = self.git("rev-parse", "HEAD").stdout.strip()
        self.script = self.source / "lib/workgrove/portable.py"

    def git(self, *args):
        return subprocess.run([str(self.tools / "git"), *args], cwd=self.source, env=self.env,
                              text=True, capture_output=True, check=True)

    def command(self, *args, ok=True, env=None):
        result = subprocess.run([sys.executable, "-B", str(self.script), *args], env=env or self.env,
                                text=True, capture_output=True, timeout=30)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def install(self, *args, ok=True):
        return self.command("install", "--root", str(self.root), "--host", "test-host",
                            "--storage", "os-disk", *args, ok=ok)

    def profile(self):
        return json.loads((self.root / ".config/workgrove/profile.json").read_text())

    def test_reference_links_follow_agent_roots_and_restore_missing_links(self):
        claude = self.root / "personal-agents/claude"
        codex = self.root / "personal-agents/codex"
        self.env.update(CLAUDE_CONFIG_DIR=str(claude), CODEX_HOME=str(codex))
        self.install("--persist-agents")
        reference = self.source / "home/.claude/TASKS.md"
        for directory in (claude, codex):
            self.assertEqual((directory / "TASKS.md").resolve(), reference)
            self.assertIn("(TASKS.md#", (directory / "AGENTS.md").read_text())
            (directory / "TASKS.md").unlink()
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("compatibility-links-missing", report["issues"])
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        for directory in (claude, codex):
            self.assertEqual((directory / "TASKS.md").resolve(), reference)
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_restore_requires_explicit_matching_host_before_home_changes(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        record = self.root / ".local/state/workgrove/machine"
        before = record.read_bytes() if record.exists() else None
        for mode in ("restore", "bootstrap", "install", "reinstall"):
            for host in (None, "different-host"):
                with self.subTest(mode=mode, host=host):
                    args = [mode, "--root", str(self.root)]
                    if mode == "reinstall":
                        args.extend(("--source", str(self.source)))
                    if mode != "restore":
                        args.append("--restore-only")
                    if host:
                        args.extend(("--host", host))
                    result = self.command(*args, ok=False, env=dict(self.env, WT_HOST="test-host"))
                    self.assertIn("restore-host-mismatch" if host else "host-alias-required", result.stderr)
                    if host:
                        self.assertIn("full setup with the new alias changes the saved alias", result.stderr)
                    self.assertEqual(list(self.home.iterdir()), [])
                    self.assertEqual(record.read_bytes() if record.exists() else None, before)
        for extra in ([], ["--host", "different-host"]):
            result = subprocess.run([str(self.tools / "bash"), str(self.source / "install.sh"),
                                     "--restore-only", *extra], env=dict(self.env, PYTHONDONTWRITEBYTECODE="1"),
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("restore-host-mismatch" if extra else "host-alias-required", result.stderr)
            self.assertEqual(list(self.home.iterdir()), [])

    def test_machine_record_waits_for_success_under_the_installation_lock(self):
        import fcntl
        self.install()
        record = self.root / ".local/state/workgrove/machine"
        record.write_text("previous-machine\n")
        def fail_install(*args, **kwargs):
            self.assertEqual(record.read_text(), "previous-machine\n")
            with (self.root / ".config/workgrove/setup.lock").open() as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raise portable.Refusal("synthetic-install-failure")
        for mode in ("install", "restore"):
            with self.subTest(mode=mode), patch.dict(os.environ, self.env, clear=True), \
                    patch.object(portable, "install_files", side_effect=fail_install) as files, \
                    patch.object(sys, "argv", ["portable.py", mode, "--root", str(self.root), "--host", "test-host"]), \
                    patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
                old_mask = os.umask(0o077)
                try:
                    self.assertEqual(portable.main(), 1)
                finally:
                    os.umask(old_mask)
                files.assert_called_once()
                self.assertEqual(record.read_text(), "previous-machine\n")

    def test_full_setup_can_change_alias_and_records_machine_only_after_success(self):
        import socket
        self.install()
        record = self.root / ".local/state/workgrove/machine"
        self.assertEqual(record.read_text(), socket.gethostname() + "\n")
        record.write_text("previous-machine\n")
        self.command("doctor", "--json")
        self.assertEqual(record.read_text(), "previous-machine\n")
        self.install("--host", "different-host")
        self.assertEqual(self.profile()["host"], "different-host")
        self.assertEqual(record.read_text(), socket.gethostname() + "\n")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        record.write_text("before-restore\n")
        result = self.command("bootstrap", "--root", str(self.root), "--host", "different-host", "--restore-only",
                              env=dict(self.env, PATH=""))
        self.assertIn("alias different-host", result.stderr)
        self.assertEqual(record.read_text(), socket.gethostname() + "\n")

    def test_restore_summary_reports_persistence_and_sign_in_presence_without_contents(self):
        self.install()
        for persist in (False, True):
            if persist:
                self.install("--persist-agents")
            profile = self.profile()
            for claude_present, codex_present in ((False, False), (True, False), (False, True), (True, True)):
                with self.subTest(persist=persist, claude=claude_present, codex=codex_present):
                    for agent, present in (("claude", claude_present), ("codex", codex_present)):
                        name = ".credentials.json" if agent == "claude" else "auth.json"
                        path = Path(profile["agent_roots"][agent]) / name
                        if present:
                            path.write_text(CANARY)
                        elif path.exists():
                            path.unlink()
                    result = self.command("restore", "--host", "test-host", "--root", str(self.root))
                    self.assertEqual(result.stdout, "workgrove: portable links and environment restored; run doctor before recovery\n")
                    self.assertIn("restored root " + str(self.root) + "; alias test-host", result.stderr)
                    self.assertIn("persist_agents: " + ("yes" if persist else "no"), result.stderr)
                    self.assertIn(".credentials.json: " + ("present" if claude_present else "absent"), result.stderr)
                    self.assertIn("auth.json: " + ("present" if codex_present else "absent"), result.stderr)
                    self.assertIn("~/.gitconfig links to the saved Git config", result.stderr)
                    self.assertIn("inside root: " + ("yes" if persist else "no"), result.stderr)
                    if not persist:
                        self.assertIn("<claude-root>", result.stderr)
                        self.assertIn("<codex-root>", result.stderr)
                        for value in profile["agent_roots"].values():
                            self.assertNotIn(value, result.stderr)

    def test_restore_summary_hides_selected_external_agent_roots(self):
        for agent, variable in (("claude", "CLAUDE_CONFIG_DIR"), ("codex", "CODEX_HOME")):
            path = self.base / ("private-" + agent)
            path.mkdir(mode=0o700)
            self.env[variable] = str(path)
        self.install("--persist-agents")
        result = self.command("restore", "--host", "test-host", "--root", str(self.root))
        for agent in ("claude", "codex"):
            self.assertIn("<" + agent + "-root>; inside root: no", result.stderr)
            self.assertNotIn(str(self.base / ("private-" + agent)), result.stderr)

    def claude_lookup(self):
        fixture = ('import json,os; from pathlib import Path; '
                   'print(json.dumps([os.environ.get("CLAUDE_CONFIG_DIR"), '
                   '(Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home())/".claude.json").read_text()]))')
        result = subprocess.run([str(self.tools / "bash"), "-c", '. "$HOME/.config/workgrove/env.sh"; exec "$@"',
                                 "fixture", sys.executable, "-c", fixture], env=self.env,
                                capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_claude_default_lookup_and_explicit_persistence_transition(self):
        state = json.dumps({"synthetic_session": CANARY, "trusted_project": "example"})
        (self.home / ".claude.json").write_text(state)
        self.install()
        self.assertEqual(self.claude_lookup(), [None, state])
        self.install()
        self.assertEqual(self.claude_lookup(), [None, state])
        self.install("--persist-agents")
        selected = self.profile()["agent_roots"]["claude"]
        self.assertEqual(self.claude_lookup(), [selected, state])
        self.assertFalse((self.home / ".claude.json").exists())
        self.install()
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        self.command("restore", "--host", "test-host", "--root", str(self.root), env=dict(self.env, PATH=str(self.base / "no-tools")))
        self.assertEqual(self.claude_lookup(), [selected, state])

    def test_existing_explicit_claude_root_keeps_its_own_identity(self):
        external = self.base / "selected-claude"
        external.mkdir(mode=0o700)
        (external / ".claude.json").write_text("selected identity")
        (self.home / ".claude.json").write_text("unrelated default identity")
        self.env["CLAUDE_CONFIG_DIR"] = str(external)
        self.install("--persist-agents")
        self.assertEqual(self.claude_lookup(), [str(external), "selected identity"])
        self.assertEqual((self.home / ".claude.json").read_text(), "unrelated default identity")
        self.install()
        self.assertEqual(self.claude_lookup(), [str(external), "selected identity"])
        old = self.profile()
        old["schema"] = 1
        old["signatures"] = {name: old["runtime_manifest"][name]
                             for name in ("bin/wt", "install.sh", "lib/workgrove/portable.py")}
        del old["runtime_manifest"], old["claude_config_dir"]
        (self.root / ".config/workgrove/profile.json").write_text(json.dumps(old))
        self.install()
        self.assertEqual(self.claude_lookup(), [str(external), "selected identity"])
        self.assertEqual((self.home / ".claude.json").read_text(), "unrelated default identity")

    def test_claude_global_conflict_refuses_before_mutation(self):
        (self.home / ".claude.json").write_text("default identity")
        selected = self.root / ".config/claude"
        selected.mkdir(parents=True, mode=0o700)
        (selected / ".claude.json").write_text("other identity")
        result = self.install("--persist-agents", ok=False)
        self.assertIn("claude-global-state-conflict", result.stderr)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        self.assertEqual((self.home / ".claude.json").read_text(), "default identity")
        self.assertEqual((selected / ".claude.json").read_text(), "other identity")

    def test_explicit_claude_directory_alias_preserves_selected_global_state(self):
        selected = self.root / "selected-claude"
        selected.mkdir(mode=0o700)
        state = selected / ".claude.json"
        state.write_text("selected global state")
        alias = self.base / "claude-alias"
        alias.symlink_to(selected)
        self.env["CLAUDE_CONFIG_DIR"] = str(alias)
        self.install("--persist-agents")
        self.assertEqual(self.claude_lookup(), [str(selected), "selected global state"])
        self.install()
        self.assertEqual(state.read_text(), "selected global state")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        self.assertEqual(self.claude_lookup(), [str(selected), "selected global state"])

    def test_replacement_home_and_environment_cannot_replace_durable_git(self):
        with (self.home / ".gitconfig").open("a") as stream:
            stream.write('[credential]\n helper =\n helper = durable-helper\n[custom]\n preserved = yes\n')
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        replacement = self.home / ".gitconfig"
        replacement.write_text('[user]\n name = Image User\n email = image@example.invalid\n[credential]\n helper = image-helper\n')
        self.install()
        self.assertEqual(self.git("config", "--global", "--includes", "--get", "user.name").stdout.strip(), "Test User")
        self.assertEqual(self.git("config", "--global", "--includes", "--get", "custom.preserved").stdout.strip(), "yes")
        alternate = self.base / "alternate-global"
        alternate.write_text('[user]\n name = Other User\n email = other@example.invalid\n')
        self.env["GIT_CONFIG_GLOBAL"] = str(alternate)
        self.install()
        active = self.root / ".config/workgrove/git/global"
        self.assertEqual(self.git("config", "--file", str(active), "--includes", "--get", "user.name").stdout.strip(), "Test User")
        self.install("--git-identity", str(alternate))
        self.assertEqual(self.git("config", "--file", str(active), "--includes", "--get", "user.name").stdout.strip(), "Other User")
        self.assertEqual(self.git("config", "--file", str(active), "--includes", "--get", "custom.preserved").stdout.strip(), "yes")
        helpers = self.git("config", "--file", str(active), "--includes", "--get-all", "credential.helper").stdout.splitlines()
        self.assertEqual(helpers[-2:], ["", "durable-helper"])
        active.unlink()
        self.assertIn("personal-git-configuration-missing", self.install(ok=False).stderr)
        self.install("--git-identity", str(alternate))
        self.assertEqual(self.git("config", "--file", str(active), "--includes", "--get", "user.name").stdout.strip(), "Other User")

    def test_actual_update_repairs_missing_profile_link_without_legacy_fallback(self):
        upstream = self.base / "upstream.git"
        self.git("clone", "--bare", str(self.source), str(upstream))
        branch = self.git("branch", "--show-current").stdout.strip()
        self.git("remote", "add", "origin", str(upstream))
        self.git("fetch", "origin")
        self.git("branch", "--set-upstream-to", "origin/" + branch)
        self.install("--persist-agents")
        (self.home / ".config/workgrove/profile.json").unlink()
        result = subprocess.run([str(self.tools / "bash"), str(self.home / ".local/bin/wt"), "update"],
                                env=dict(self.env, FORCE_OS="Linux"), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".config/workgrove/profile.json").is_symlink())
        self.assertFalse((self.home / ".zshenv").is_symlink())
        self.assertIn("workgrove environment", (self.home / ".zshenv").read_text())
        publisher = self.base / "publisher"
        self.git("clone", str(upstream), str(publisher))
        updated = publisher / "lib/workgrove/remote.sh"
        updated.write_text(updated.read_text() + "\n# Updated synthetic runtime.\n")
        for args in (("add", str(updated)), ("commit", "-qm", "Update synthetic runtime"), ("push", "origin", branch)):
            subprocess.run([str(self.tools / "git"), "-C", str(publisher), *args], env=self.env,
                           capture_output=True, text=True, check=True)
        master, slave = pty.openpty()
        try:
            os.write(master, b"y\n")
            result = subprocess.run([str(self.tools / "bash"), str(self.home / ".local/bin/wt"), "update"],
                                    stdin=slave, env=dict(self.env, FORCE_OS="Linux"),
                                    capture_output=True, text=True, timeout=30)
        finally:
            os.close(slave)
            os.close(master)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.profile()["revision"], self.revision)
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])
        saved = self.root / ".config/workgrove/profile.json"
        saved.unlink()
        before = (self.home / ".zshenv").read_bytes()
        result = subprocess.run([str(self.tools / "bash"), str(self.source / "install.sh")],
                                env=dict(self.env, FORCE_OS="Linux"), capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("portable-profile-missing-run-explicit-setup", result.stderr)
        self.assertEqual((self.home / ".zshenv").read_bytes(), before)
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        result = subprocess.run([str(self.tools / "bash"), str(self.source / "install.sh")],
                                env=dict(self.env, FORCE_OS="Linux"), capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("portable-profile-missing-run-explicit-setup", result.stderr)
        self.assertFalse((self.home / ".zshenv").exists())

    def test_actual_legacy_install_migrates_links_without_modifying_old_checkout(self):
        legacy = self.base / "legacy"
        shutil.copytree(self.source, legacy, symlinks=True)
        (self.home / ".gitconfig").unlink()
        result = subprocess.run([str(self.tools / "bash"), str(legacy / "install.sh")],
                                env=dict(self.env, FORCE_OS="Linux", WT_HOST="test-host"),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".claude/AGENTS.md").is_symlink())
        personal = self.base / "personal-instructions"
        personal.write_text("Keep this personal instruction.\n")
        (self.home / ".codex/AGENTS.md").unlink()
        (self.home / ".codex/AGENTS.md").symlink_to(personal)
        (self.home / ".claude.json").write_text("legacy global state")
        (self.home / ".codex/auth.json").write_text(CANARY)
        before = {str(path.relative_to(legacy)): path.read_bytes() for path in legacy.rglob("*") if path.is_file()}
        self.install("--persist-agents")
        self.install()
        self.assertIn("Keep this personal instruction.", (self.home / ".codex/AGENTS.md").read_text())
        self.assertEqual((self.home / ".codex/auth.json").read_text(), CANARY)
        self.assertEqual(self.claude_lookup()[1], "legacy global state")
        self.assertEqual(personal.read_text(), "Keep this personal instruction.\n")
        after = {str(path.relative_to(legacy)): path.read_bytes() for path in legacy.rglob("*") if path.is_file()}
        self.assertEqual(after, before)
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_missing_profile_evidence_blocks_clean_environment_preflight(self):
        self.install("--persist-agents")
        (self.root / ".config/workgrove/profile.json").unlink()
        self.assertNotIn("WT_REMOTE_ROOT", self.env)
        before = (self.home / ".config/workgrove/env.sh").read_bytes()
        for remove_home_links in (False, True):
            if remove_home_links:
                (self.home / ".config/workgrove/profile.json").unlink()
                (self.home / ".config/workgrove/env.sh").unlink()
            report = json.loads(self.command("doctor", "--json", ok=False).stdout)
            self.assertFalse(report["ready"])
            self.assertIn("portable-profile-missing", report["issues"])
            self.command("doctor", "--preflight", ok=False)
            self.assertEqual((self.root / ".config/workgrove/env.sh").read_bytes(), before)
            self.assertFalse((self.root / ".config/workgrove/profile.json").exists())

    def test_manifest_covers_all_runtime_inputs_and_requires_full_setup_after_update(self):
        self.install("--persist-agents")
        for name in ("lib/workgrove/remote.sh", "bin/cmux-hook", "home/.claude/AGENTS.md"):
            with self.subTest(name=name):
                path = self.source / name
                before = path.read_bytes()
                path.write_bytes(before + b"\n# Modified runtime input.\n")
                report = json.loads(self.command("doctor", "--json", ok=False).stdout)
                self.assertIn("installation-changed-run-full-setup", report["issues"])
                self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False,
                             env=dict(self.env, PATH=str(self.base / "no-tools")))
                self.assertIn("installation-has-local-edits", self.install(ok=False).stderr)
                path.write_bytes(before)
        path = self.source / "lib/workgrove/remote.sh"
        path.write_text(path.read_text() + "\n# Updated public runtime.\n")
        self.git("add", str(path))
        self.git("commit", "-qm", "Update synthetic runtime")
        self.install()
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_task_branch_config_invalidates_manifest_and_allows_cleanup(self):
        self.install()
        task = self.source / ".worktrees/accidental"
        self.git("worktree", "add", "-qb", "wt/accidental", str(task), "HEAD")
        self.git("config", "branch.wt/accidental.remote", "origin")
        self.git("config", "branch.wt/accidental.merge", "refs/heads/main")
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("installation-changed-run-full-setup", report["issues"])
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertIn("installation-changed-run-full-setup", result.stderr)
        tmux = self.tools / "tmux"
        tmux.write_text("#!/bin/sh\necho 'no server running on /tmp/synthetic-tmux' >&2\nexit 1\n")
        for command in ("show", "path", "rm"):
            options = ["--keep-branch"] if command == "rm" else []
            result = subprocess.run([str(self.tools / "bash"), str(self.source / "bin/wt"),
                                     command, "accidental", "-r", str(self.source), *options],
                                    cwd=self.root, env=dict(self.env, CMUX_SSH_ATTEMPT_ID="test"),
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(task.exists())
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("installation-changed-run-full-setup", report["issues"])
        self.install()
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        tmux.write_text("#!/bin/sh\nexit 0\n")
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_manifest_rejects_untracked_inputs_but_ignores_unrelated_environment(self):
        extra = self.source / "bin/extra-command"
        extra.write_text("#!/bin/sh\nexit 0\n")
        extra.chmod(0o700)
        self.assertIn("installation-untracked-runtime", self.install(ok=False).stderr)
        extra.unlink()
        unused = self.source / ".venv/bin"
        unused.mkdir(parents=True)
        (unused / "python").symlink_to(sys.executable)
        self.install()
        (self.source / "home/.agents/skills/untracked-skill").mkdir()
        self.command("doctor", "--json", ok=False)
        self.assertIn("installation-untracked-runtime", self.install(ok=False).stderr)

    def test_effective_git_worktree_must_match_the_installation(self):
        external = self.base / "other-tree"
        shutil.copytree(self.source, external, ignore=shutil.ignore_patterns(".git"))
        self.git("config", "core.worktree", str(external))
        self.assertIn("installation-identity-conflict", self.install(ok=False).stderr)
        self.git("config", "--unset", "core.worktree")
        self.install()
        self.git("config", "core.worktree", str(external))
        self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.command("doctor", "--json", ok=False)

    def test_git_status_cannot_hide_modified_runtime_contents(self):
        path = self.source / "lib/workgrove/remote.sh"
        self.git("update-index", "--assume-unchanged", str(path))
        path.write_text(path.read_text() + "\n# Modified hidden runtime.\n")
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertIn("installation-has-local-edits", self.install(ok=False).stderr)

    def test_replacement_objects_cannot_change_the_selected_revision_runtime(self):
        path = self.source / "lib/workgrove/remote.sh"
        path.write_text(path.read_text() + "\n# Replacement runtime.\n")
        self.git("add", str(path))
        self.git("commit", "-qm", "Create replacement runtime")
        replacement = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("reset", "--soft", self.revision)
        self.git("replace", self.revision, replacement)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        result = self.install("--revision", self.revision, ok=False)
        self.assertIn("installation-has-local-edits", result.stderr)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        self.git("replace", "-d", self.revision)
        self.git("reset", "--hard", replacement)
        self.install("--revision", replacement)
        self.assertEqual(self.profile()["revision"], replacement)

    def test_standalone_runtime_rejects_external_repository_configuration(self):
        include = self.base / "repository-options"
        include.write_text("[core]\n bare = false\n")
        self.git("config", "include.path", str(include))
        self.assertIn("standalone-configuration-required", self.install(ok=False).stderr)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())

    def test_old_partial_manifest_requires_explicit_full_setup_upgrade(self):
        self.install("--persist-agents")
        path = self.root / ".config/workgrove/profile.json"
        old = self.profile()
        old["schema"] = 1
        old["signatures"] = {name: old["runtime_manifest"][name]
                             for name in ("bin/wt", "install.sh", "lib/workgrove/portable.py")}
        del old["runtime_manifest"], old["claude_config_dir"]
        path.write_text(json.dumps(old))
        self.assertIn("profile-upgrade-run-full-setup", self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False).stderr)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("profile-upgrade-run-full-setup", report["issues"])
        (self.home / ".claude.json").write_text("stranded global state")
        self.install()
        self.assertEqual(self.profile()["schema"], 2)
        self.assertEqual(self.claude_lookup()[1], "stranded global state")
        self.command("restore", "--host", "test-host", "--root", str(self.root))

    def test_every_managed_personal_file_has_the_same_safety_checks(self):
        self.install("--persist-agents")
        claude = Path(self.profile()["agent_roots"]["claude"])
        (claude / ".claude.json").write_text("synthetic global state")
        paths = [Path(self.profile()["agent_roots"]["codex"]) / "config.toml",
                 claude / ".claude.json", self.root / ".config/workgrove/git/global"]
        for path in paths:
            with self.subTest(file=path.name):
                path.chmod(0o666)
                report = json.loads(self.command("doctor", "--json", ok=False).stdout)
                self.assertIn("shared-configuration-target", report["issues"])
                self.command("doctor", "--preflight", ok=False)
                self.assertIn("shared-configuration-target", self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False).stderr)
                self.assertIn("shared-configuration-target", self.install(ok=False).stderr)
                path.chmod(0o600)
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_mutable_configuration_links_and_hardlinks_fail_every_entry_point(self):
        self.install("--persist-agents")
        codex = Path(self.profile()["agent_roots"]["codex"])
        path = codex / "config.toml"
        path.unlink()
        path.symlink_to(self.source / "home/.codex/config.base.toml")
        for command in (("doctor", "--json"), ("restore", "--host", "test-host", "--root", str(self.root)),
                        ("install", "--root", str(self.root))):
            result = self.command(*command, ok=False)
            self.assertIn("repository-destination", result.stdout + result.stderr)
        path.unlink()
        path.write_text("custom = true\n")
        original = self.base / "authentication"
        original.write_text(CANARY)
        os.link(original, codex / "auth.json")
        for command in (("doctor", "--json"), ("restore", "--host", "test-host", "--root", str(self.root)),
                        ("install", "--root", str(self.root))):
            result = self.command(*command, ok=False)
            self.assertIn("hardlinked-file", result.stdout + result.stderr)

    def test_trusted_volume_does_not_require_exact_runtime_mode_bits(self):
        self.volume_install("--persist-agents", "--trust-personal-volume")
        for path in (self.source / "lib/workgrove/remote.sh",
                     Path(self.profile()["agent_roots"]["codex"]) / "config.toml"):
            path.chmod(0o666)
        self.assertTrue(json.loads(self.volume_command("doctor", "--json").stdout)["ready"])
        self.volume_command("restore", "--host", "test-host", "--root", str(self.root))
        self.volume_install()
        self.volume_install("--strict-permissions", ok=False)
        self.assertTrue(self.profile()["trust_personal_volume"])

    def test_partial_agent_move_can_be_retried_without_losing_claude_state(self):
        self.install()
        state = self.home / ".claude.json"
        state.write_text("existing global state")
        target = self.root / ".config/claude"
        (self.home / ".claude").rename(target)
        self.install("--persist-agents")
        self.assertEqual(self.claude_lookup(), [str(target), "existing global state"])
        self.assertTrue((self.home / ".claude").is_symlink())

    def test_migration_refuses_changed_link_referents_before_moving_any_state(self):
        claude = self.home / ".claude"
        claude.mkdir()
        (self.home / "selected-settings.json").write_text('{"custom":true}')
        (self.home / "foreign-skills").mkdir()
        (self.home / "foreign-skills/SKILL.md").write_text("Synthetic foreign skill.\n")
        links = (("settings.json", "../selected-settings.json"),
                 ("nested/session", "../../selected-settings.json"),
                 ("skills/foreign", "../../foreign-skills"))
        for name, reference in links:
            with self.subTest(name=name):
                path = claude / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(reference)
                result = self.install("--persist-agents", ok=False)
                self.assertIn("agent-link-migration-conflict", result.stderr)
                self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
                self.assertFalse((self.root / ".config/claude").exists())
                self.assertTrue(path.exists())
                self.assertFalse(claude.is_symlink())
                path.unlink()

    def test_migration_keeps_internal_links_and_absolute_external_links(self):
        claude = self.home / ".claude"
        (claude / "nested").mkdir(parents=True)
        (claude / "data").write_text("synthetic session")
        (claude / "nested/internal").symlink_to("../data")
        (claude / "absolute-internal").symlink_to(claude / "data")
        external = self.base / "external-state"
        external.write_text("external session")
        (claude / "nested/external").symlink_to(external)
        (claude / "AGENTS.md").symlink_to("../selected-instructions")
        (self.home / "selected-instructions").write_text("Keep these personal instructions.\n")
        self.install("--persist-agents")
        self.assertEqual((claude / "nested/internal").read_text(), "synthetic session")
        self.assertEqual((claude / "absolute-internal").read_text(), "synthetic session")
        self.assertEqual((claude / "nested/external").read_text(), "external session")
        self.assertIn("Keep these personal instructions.", (claude / "AGENTS.md").read_text())
        self.install()
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        self.assertEqual((claude / "nested/internal").read_text(), "synthetic session")
        self.assertEqual((claude / "absolute-internal").read_text(), "synthetic session")

    def test_migration_checks_parent_traversal_after_a_directory_link(self):
        claude = self.home / ".claude"
        claude.mkdir()
        (self.home / "outside").write_text("external session")
        (claude / "alias").symlink_to(claude)
        (claude / "session").symlink_to("alias/../outside")
        result = self.install("--persist-agents", ok=False)
        self.assertIn("agent-link-migration-conflict", result.stderr)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        self.assertEqual((claude / "session").read_text(), "external session")

    def test_migration_refuses_link_cycles_before_moving_state(self):
        claude = self.home / ".claude"
        (claude / "skills").mkdir(parents=True)
        (claude / "skills/cycle-a").symlink_to("cycle-b")
        (claude / "skills/cycle-b").symlink_to("cycle-a")
        result = self.install("--persist-agents", ok=False)
        self.assertIn("agent-link-migration-conflict", result.stderr)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        self.assertFalse(claude.is_symlink())

    def test_migration_checks_links_between_both_agent_roots(self):
        claude, codex = self.home / ".claude", self.home / ".codex"
        claude.mkdir()
        codex.mkdir()
        (codex / "session").write_text("synthetic shared state")
        link = claude / "other-agent"
        link.symlink_to("../.codex/session")
        result = self.install("--persist-agents", ok=False)
        self.assertIn("agent-link-migration-conflict", result.stderr)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        link.unlink()
        link.symlink_to(codex / "session")
        self.install("--persist-agents")
        self.assertEqual(link.read_text(), "synthetic shared state")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        self.assertEqual(link.read_text(), "synthetic shared state")

    def test_migration_refuses_selected_roots_nested_inside_a_moved_directory(self):
        for parent, nested, variable in (("codex", "claude", "CLAUDE_CONFIG_DIR"),
                                         ("claude", "codex", "CODEX_HOME")):
            with self.subTest(parent=parent):
                original = self.home / ("." + parent)
                selected = original / nested
                selected.mkdir(parents=True)
                state = selected / (".claude.json" if nested == "claude" else "config.toml")
                state.write_text(CANARY)
                self.env[variable] = str(selected)
                result = self.install("--persist-agents", ok=False)
                self.assertIn("agent-configuration-conflict", result.stderr)
                self.assertEqual(state.read_text(), CANARY)
                self.assertFalse(original.is_symlink())
                self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
                self.assertFalse((self.root / ".config" / parent).exists())
                del self.env[variable]
                shutil.rmtree(original)

    def volume_command(self, *args, ok=True, mounts=None):
        harness = '''import json,runpy,sys
from pathlib import Path
script,points=sys.argv[1:3]
module=runpy.run_path(script,run_name="volume_fixture")
module["main"].__globals__["mounted"]=lambda point: str(point) in json.loads(points)
sys.argv=[script,*sys.argv[3:]]
sys.exit(module["main"]())
'''
        result = subprocess.run([sys.executable, "-B", "-c", harness, str(self.script),
                                 json.dumps(mounts if mounts is not None else [str(self.root)]), *args],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def volume_install(self, *args, **kwargs):
        return self.volume_command("install", "--root", str(self.root), "--host", "test-host",
                                   "--storage", "volume", *args, **kwargs)

    def test_personal_volume_requires_explicit_acceptance_before_private_writes(self):
        self.root.chmod(0o777)
        result = self.volume_install(ok=False)
        tag, payload = result.stderr.splitlines()[0].split("\t", 1)
        self.assertEqual(tag, "trust-request")
        request = json.loads(payload)
        self.assertEqual(request, {"error": "personal-volume-trust-required", "root": str(self.root), "mount": str(self.root)})
        self.assertIn("--trust-personal-volume", result.stderr)
        self.assertFalse((self.root / ".config").exists())
        self.assertFalse((self.home / ".local").exists())
        self.assertNotIn("[y/N]", result.stderr)

    def test_personal_volume_acceptance_survives_restore_and_reinstall(self):
        self.root.chmod(0o777)
        self.volume_install("--trust-personal-volume", "--persist-agents")
        self.assertTrue(self.profile()["trust_personal_volume"])
        report = json.loads(self.volume_command("doctor", "--root", str(self.root), "--json").stdout)
        self.assertTrue(report["ready"], report)
        self.assertEqual(report["storage_permission_policy"], "trusted-personal-volume")
        self.assertEqual(report["storage_permission_warnings"], ["unix-mode-checks-relaxed"])
        self.volume_install()
        self.volume_command("reinstall", "--source", str(self.source))
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        self.volume_command("restore", "--host", "test-host", "--root", str(self.root))
        self.assertTrue((self.home / ".local/bin/wt").is_symlink())
        self.assertTrue(self.profile()["trust_personal_volume"])
        self.assertTrue(json.loads(self.volume_command("doctor", "--json").stdout)["ready"])
        result = self.volume_command("restore", "--host", "test-host", "--root", str(self.root), mounts=[], ok=False)
        self.assertIn("persistent-mount-missing", result.stderr)

    def test_personal_volume_scope_changes_require_new_acceptance(self):
        self.volume_install("--trust-personal-volume")
        result = self.volume_install("--mount", str(self.base), mounts=[str(self.base)], ok=False)
        self.assertIn("personal-volume-trust-scope-changed", result.stderr)
        self.assertEqual(self.profile()["mount"], str(self.root))
        self.volume_install("--mount", str(self.base), "--trust-personal-volume", mounts=[str(self.base)])
        self.assertEqual(self.profile()["mount"], str(self.base))
        self.assertTrue(self.profile()["trust_personal_volume"])

    def test_doctor_keeps_permission_checks_for_external_agent_configuration(self):
        external = self.base / "external-agent"
        external.mkdir(mode=0o700)
        self.env["CODEX_HOME"] = str(external)
        self.volume_install("--trust-personal-volume")
        external.chmod(0o777)
        report = json.loads(self.volume_command("doctor", "--json", ok=False).stdout)
        self.assertFalse(report["ready"])
        self.assertIn("shared-configuration-target", report["issues"])
        self.assertEqual(report["storage_permission_policy"], "trusted-personal-volume")

    def test_strict_permissions_check_existing_target_files_and_directories(self):
        external = self.base / "external-agent"
        external.mkdir(mode=0o755)
        self.env["CODEX_HOME"] = str(external)
        self.install()
        hooks = external / "hooks.json"
        original = hooks.read_bytes()
        hooks.chmod(0o666)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("shared-configuration-target", report["issues"])
        self.install(ok=False)
        self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual(hooks.read_bytes(), original)
        self.assertEqual(hooks.stat().st_mode & 0o777, 0o666)
        hooks.chmod(0o600)
        self.install()
        external.chmod(0o777)
        with self.assertRaisesRegex(portable.Refusal, "shared-configuration-target"):
            portable.private_path(external)

    def test_personal_volume_target_exception_stays_inside_the_selected_mount(self):
        external = self.base / "external-agent"
        external.mkdir(mode=0o755)
        self.env["CODEX_HOME"] = str(external)
        self.volume_install("--trust-personal-volume", "--persist-agents")
        internal = Path(self.profile()["agent_roots"]["claude"]) / "settings.json"
        internal.chmod(0o666)
        self.assertTrue(json.loads(self.volume_command("doctor", "--json").stdout)["ready"])
        self.volume_install()
        self.assertEqual(internal.stat().st_mode & 0o777, 0o666)
        (external / "hooks.json").chmod(0o666)
        report = json.loads(self.volume_command("doctor", "--json", ok=False).stdout)
        self.assertIn("shared-configuration-target", report["issues"])
        self.volume_install(ok=False)

    def test_bootstrap_forwards_saved_volume_acceptance_to_selected_installer(self):
        import argparse
        self.volume_install("--trust-personal-volume")
        args = argparse.Namespace(root=str(self.root), host="test-host", storage=None, mount=None,
                                  source=None, revision=None, git_identity=None, persist_agents=False,
                                  with_tmux_conf=False, claude_args_json=None, codex_args_json=None,
                                  restore_only=False, trust_personal_volume=False, strict_permissions=False)
        with patch.dict(os.environ, self.env, clear=True), patch.object(portable, "mounted", return_value=True), \
                patch.object(portable, "packages"), patch.object(portable.os, "execv") as execute:
            portable.bootstrap(args)
        self.assertIn("--trust-personal-volume", execute.call_args.args[1])
        self.assertIsNone(portable._volume_policy.get())

    def test_volume_trust_never_applies_to_os_disk_or_missing_mount(self):
        result = self.install("--trust-personal-volume", ok=False)
        self.assertIn("volume-trust-requires-volume-storage", result.stderr)
        result = self.volume_install("--trust-personal-volume", mounts=[], ok=False)
        self.assertIn("persistent-mount-missing", result.stderr)
        self.assertFalse((self.root / ".config").exists())

    def test_restore_cannot_grant_new_volume_trust(self):
        self.volume_install()
        before = (self.root / ".config/workgrove/profile.json").read_bytes()
        result = self.volume_command("restore", "--host", "test-host", "--root", str(self.root), "--trust-personal-volume", ok=False)
        self.assertIn("restore-cannot-change-volume-trust", result.stderr)
        self.assertEqual((self.root / ".config/workgrove/profile.json").read_bytes(), before)

    def test_explicit_strict_policy_revokes_acceptance_only_after_validation(self):
        self.root.chmod(0o777)
        self.volume_install("--trust-personal-volume")
        self.volume_install("--strict-permissions", ok=False)
        self.assertTrue(self.profile()["trust_personal_volume"])
        result = self.volume_install("--strict-permissions", "--trust-personal-volume", ok=False)
        self.assertIn("conflicting-storage-permission-options", result.stderr)
        self.root.chmod(0o700)
        self.volume_install("--strict-permissions")
        self.assertFalse(self.profile()["trust_personal_volume"])
        report = json.loads(self.volume_command("doctor", "--json").stdout)
        self.assertEqual(report["storage_permission_policy"], "strict")
        self.assertEqual(report["storage_permission_warnings"], [])

    def test_old_profiles_keep_strict_mode_and_reject_invalid_trust_values(self):
        self.install()
        path = self.root / ".config/workgrove/profile.json"
        data = self.profile()
        del data["trust_personal_volume"]
        path.write_text(json.dumps(data))
        report = json.loads(self.command("doctor", "--json").stdout)
        self.assertEqual(report["storage_permission_policy"], "strict")
        self.assertEqual(report["storage_permission_warnings"], [])
        for value in (True, "yes", 1):
            path.write_text(json.dumps(dict(data, trust_personal_volume=value)))
            result = self.command("doctor", "--json", ok=False)
            self.assertIn("invalid-profile", json.loads(result.stdout)["issues"])

    def test_old_strict_volume_profiles_accept_equivalent_mount_spelling(self):
        self.volume_install()
        data = self.profile()
        del data["trust_personal_volume"]
        data["mount"] += "/"
        (self.root / ".config/workgrove/profile.json").write_text(json.dumps(data))
        report = json.loads(self.volume_command("doctor", "--json").stdout)
        self.assertEqual(report["storage_permission_policy"], "strict")
        self.volume_install()
        self.assertEqual(self.profile()["mount"], str(self.root))
        self.assertFalse(self.profile()["trust_personal_volume"])

    def test_selected_installer_refuses_a_changed_permission_profile(self):
        import hashlib
        self.volume_install("--trust-personal-volume")
        snapshot = (self.root / ".config/workgrove/profile.json").read_bytes()
        expected = hashlib.sha256(snapshot).hexdigest()
        self.volume_install("--strict-permissions")
        result = self.volume_install("--trust-personal-volume", "--expected-profile-digest", expected, ok=False)
        self.assertIn("profile-changed-retry-setup", result.stderr)
        self.assertFalse(self.profile()["trust_personal_volume"])

    def test_volume_trust_preserves_repository_link_owner_and_parent_guards(self):
        self.root.chmod(0o777)
        external = self.base / "untrusted"
        external.mkdir(mode=0o777)
        external.chmod(0o777)
        escape = self.root / "escape"
        escape.symlink_to(external, target_is_directory=True)
        secret = self.root / "personal"
        secret.write_text(CANARY)
        os.link(secret, self.root / "second-link")
        dangling = self.root / "dangling"
        dangling.symlink_to(self.base / "missing")
        with patch.object(portable, "mounted", return_value=True):
            with portable.volume_permissions(self.root, "volume", str(self.root), True):
                portable.storage(self.root, "volume", str(self.root))
                for path, code in ((escape / "settings", "shared-configuration-parent"),
                                   (secret, "hardlinked-file"), (dangling, "dangling-configuration-link"),
                                   (self.source / "private", "repository-destination")):
                    with self.assertRaisesRegex(portable.Refusal, code):
                        portable.private_path(path)
                with patch.object(portable.os, "getuid", return_value=-1):
                    with self.assertRaisesRegex(portable.Refusal, "foreign-owner"):
                        portable.private_path(self.root)
                with self.assertRaisesRegex(portable.Refusal, "repository-destination"):
                    portable.storage(self.source, "volume", str(self.root))
        with self.assertRaisesRegex(portable.Refusal, "shared-configuration-parent"):
            portable.private_path(self.root / "new-settings")

    def test_personal_volume_prompt_defaults_to_no_and_requires_a_terminal(self):
        request = {"error": "personal-volume-trust-required", "root": "/example/root", "mount": "/example"}
        for response, expected in (("\n", False), ("no\n", False), ("yes\n", True), ("y\n", True)):
            incoming, outgoing = io.StringIO(response), io.StringIO()
            incoming.isatty = outgoing.isatty = lambda: True
            with patch.object(portable.sys, "stdin", incoming), patch.object(portable.sys, "stderr", outgoing):
                self.assertEqual(portable.confirm_volume_trust(request), expected)
            self.assertIn("/example/root", outgoing.getvalue())
            self.assertIn("[y/N]", outgoing.getvalue())
        with patch.object(portable.sys, "stdin", io.StringIO("yes\n")), patch.object(portable.sys, "stderr", io.StringIO()):
            self.assertFalse(portable.confirm_volume_trust(request))

    def test_confirmation_reads_tagged_requests_and_legacy_json(self):
        request = {"error": "personal-volume-trust-required", "root": "/example/root", "mount": "/example"}
        path = self.base / "request"
        for prefix in ("", "diagnostic before the record\ntrust-request\t"):
            with self.subTest(prefix=prefix):
                path.write_text(prefix + json.dumps(request, separators=(",", ":")) + "\nother diagnostic\n")
                output = io.StringIO()
                with patch.object(portable, "confirm_volume_trust", return_value=True) as confirm, \
                        patch.object(sys, "stdout", output):
                    self.assertEqual(portable.confirm_volume_request(Namespace(request_file=str(path))), 0)
                confirm.assert_called_once_with(request)
                self.assertEqual(output.getvalue(), "/example/root\n/example\n")

    def test_persistent_identity_exclusions_tools_and_sticky_preferences(self):
        self.install("--persist-agents", "--with-tmux-conf", "--codex-args-json", '["--no-alt-screen"]')
        self.assertEqual((self.home / ".local/bin/wt").readlink(), self.source / "bin/wt")
        profile = self.profile()
        self.assertTrue(profile["tmux"])
        self.assertTrue(profile["persist_agents"])
        self.assertNotIn(CANARY, json.dumps(profile))
        self.assertEqual(profile["revision"], self.revision)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        result = self.command("doctor", "--json")
        doctor = json.loads(result.stdout)
        self.assertTrue(doctor["ready"], doctor)
        self.assertTrue(doctor["git_identity"])
        self.assertTrue(doctor["worktree_exclusion"])
        self.assertEqual(doctor["native_relay"], "requires-row-check")
        env_file = self.root / ".config/workgrove/env.sh"
        before = env_file.read_bytes()
        self.command("install", "--root", str(self.root))
        self.assertEqual(env_file.read_bytes(), before)
        self.assertTrue(self.profile()["tmux"])
        self.assertEqual(self.profile()["agent_args"]["codex"], ["--no-alt-screen"])

    def test_fullscreen_default_preserves_personal_ui_settings(self):
        self.install()
        path = Path(self.profile()["agent_roots"]["claude"]) / "settings.json"
        settings = json.loads(path.read_text())
        self.assertEqual(settings["tui"], "fullscreen")
        self.assertNotIn("theme", settings)
        self.assertNotIn("voice", settings)
        self.assertNotIn("CLAUDE_CODE_DISABLE_MOUSE_CLICKS", settings.get("env", {}))
        settings["tui"] = "personal-choice"
        settings["personal"] = True
        path.write_text(json.dumps(settings))
        self.install()
        self.assertEqual(json.loads(path.read_text())["tui"], "personal-choice")
        settings.pop("tui")
        path.write_text(json.dumps(settings))
        self.install()
        restored = json.loads(path.read_text())
        self.assertEqual(restored["tui"], "fullscreen")
        self.assertTrue(restored["personal"])

    def test_agent_configuration_and_foreign_hooks_survive_migration(self):
        claude = self.home / ".claude"
        codex = self.home / ".codex"
        claude.mkdir()
        codex.mkdir()
        existing = {"setting": CANARY, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo " + CANARY}]}]}}
        (claude / "settings.json").write_text(json.dumps(existing))
        (codex / "config.toml").write_text('custom_setting = "' + CANARY + '"\n')
        (codex / "auth.json").write_text(CANARY)
        (claude / "AGENTS.md").write_text("Preserve this personal instruction.\n")
        (claude / "CLAUDE.md").write_text("Preserve this Claude instruction.\n")
        self.install("--persist-agents")
        self.assertTrue(claude.is_symlink())
        self.assertEqual((codex / "auth.json").read_text(), CANARY)
        self.assertIn(CANARY, (codex / "config.toml").read_text())
        merged = json.loads((claude / "settings.json").read_text())
        self.assertEqual(merged["setting"], CANARY)
        self.assertIn("echo " + CANARY, json.dumps(merged["hooks"]))
        self.assertIn("Preserve this personal instruction.", (claude / "AGENTS.md").read_text())
        self.assertIn("@AGENTS.md", (claude / "CLAUDE.md").read_text())
        self.assertTrue(list((self.root / ".local/state/workgrove/backups").iterdir()))

    def test_restore_after_home_replacement_needs_only_python(self):
        self.install("--persist-agents", "--with-tmux-conf")
        task = self.root / "project/.worktrees/kept-task/uncommitted.txt"
        task.parent.mkdir(parents=True)
        task.write_text(CANARY)
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        minimal = self.base / "minimal"
        minimal.mkdir()
        env = dict(self.env, PATH=str(minimal))
        self.command("restore", "--host", "test-host", "--root", str(self.root), env=env)
        self.assertEqual((self.home / ".local/bin/wt").readlink(), self.source / "bin/wt")
        self.assertTrue((self.home / ".tmux.conf").is_symlink())
        for agent in ("claude", "codex"):
            self.assertEqual((self.home / ("." + agent) / "TASKS.md").resolve(),
                             self.source / "home/.claude/TASKS.md")
        self.assertEqual(task.read_text(), CANARY)
        result = self.command("doctor", "--root", str(self.root), "--json", env=env, ok=False)
        self.assertIn("missing-prerequisites", json.loads(result.stdout)["issues"])
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_restore_backs_up_supplier_home_files_and_reuses_identical_backups(self):
        self.install("--persist-agents", "--with-tmux-conf")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        planted = {".gitconfig": b"[credential]\n helper = supplier\n", ".tmux.conf": b"# supplier\n\xff"}
        backups = self.root / ".local/state/workgrove/backups"
        before = {name: set(backups.glob("*/" + name)) for name in planted}
        for attempt in range(2):
            for name, contents in planted.items():
                path = self.home / name
                if path.is_symlink():
                    path.unlink()
                path.write_bytes(contents)
            result = self.command("restore", "--host", "test-host", "--root", str(self.root), env=dict(self.env, PATH=""))
            for name, contents in planted.items():
                self.assertTrue((self.home / name).is_symlink())
                copies = list(set(backups.glob("*/" + name)) - before[name])
                self.assertEqual(len(copies), 1)
                self.assertEqual(copies[0].read_bytes(), contents)
                action = "backed up" if attempt == 0 else "removed"
                lines = [line for line in result.stderr.splitlines() if "~/" + name in line and
                         line.startswith(("workgrove: backed up ", "workgrove: removed "))]
                self.assertEqual(len(lines), 1)
                self.assertIn(action, lines[0])
                self.assertIn(str(copies[0].parent.relative_to(self.root)), lines[0])
            backup_lines = [line for line in result.stderr.splitlines()
                            if line.startswith(("workgrove: backed up ", "workgrove: removed "))]
            self.assertNotIn(str(self.home), "\n".join(backup_lines))
            self.assertNotIn(str(self.root), "\n".join(backup_lines))
            summary = result.stderr.splitlines().index("workgrove: restored root " + str(self.root) + "; alias test-host")
            self.assertTrue(all(result.stderr.splitlines().index(line) < summary for line in backup_lines))
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_backup_uses_newest_original_path_without_file_timestamps(self):
        self.install("--persist-agents", "--with-tmux-conf")
        path = self.home / ".tmux.conf"
        backups = self.root / ".local/state/workgrove/backups"
        for contents, count in ((b"first", 1), (b"second", 2), (b"first", 3), (b"first", 3)):
            path.unlink()
            path.write_bytes(contents)
            self.command("restore", "--host", "test-host", "--root", str(self.root), env=dict(self.env, PATH=""))
            copies = list(backups.glob("*/.tmux.conf"))
            self.assertEqual(len(copies), count)
            for copy in copies:
                os.utime(copy, (1, 1))
                os.utime(copy.parent, (1, 1))

    @unittest.skipIf(os.geteuid() == 0, "Root can read files without read permission.")
    def test_full_setup_still_backs_up_unreadable_regular_files(self):
        self.install("--persist-agents", "--with-tmux-conf")
        path = self.home / ".tmux.conf"
        backups = self.root / ".local/state/workgrove/backups"
        for attempt in range(2):
            path.unlink()
            path.write_bytes(b"supplier settings")
            path.chmod(0o000)
            result = self.install()
            self.assertIn("backed up ~/.tmux.conf to .local/state/workgrove/backups/", result.stderr)
            copies = list(backups.glob("*/.tmux.conf"))
            self.assertEqual(len(copies), attempt + 1)
            self.assertTrue(all(copy.stat().st_mode & 0o777 == 0 for copy in copies))
        for copy in copies:
            copy.chmod(0o600)
            self.assertEqual(copy.read_bytes(), b"supplier settings")

    def test_full_setup_keeps_same_basename_backups_separate(self):
        for base in (self.root, self.home):
            path = base / ".local/bin/wt"
            path.parent.mkdir(parents=True)
            path.write_bytes(b"supplier command\xff")
        result = self.install("--persist-agents")
        copies = list((self.root / ".local/state/workgrove/backups").glob("*/wt"))
        self.assertEqual(len(copies), 2)
        self.assertTrue(all(path.read_bytes() == b"supplier command\xff" for path in copies))
        self.assertIn("backed up ~/.local/bin/wt to .local/state/workgrove/backups/", result.stderr)
        self.assertIn("backed up .local/bin/wt to .local/state/workgrove/backups/", result.stderr)

    def test_restore_names_directory_and_foreign_link_conflicts_before_any_move(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        (self.home / ".gitconfig").write_bytes(b"supplier")
        before = sorted((self.root / ".local/state/workgrove/backups").iterdir())
        path = self.home / ".claude"
        path.mkdir()
        (path / ".credentials.json").write_text(CANARY)
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual(result.stderr, "workgrove: restore-link-conflict: ~/.claude\n")
        self.assertEqual((path / ".credentials.json").read_text(), CANARY)
        shutil.rmtree(path)
        path.symlink_to(self.base / CANARY)
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual(result.stderr, "workgrove: restore-link-conflict: ~/.claude\n")
        self.assertTrue(path.is_symlink())
        self.assertFalse((self.home / ".local/bin/wt").exists())
        self.assertEqual((self.home / ".gitconfig").read_bytes(), b"supplier")
        self.assertEqual(sorted((self.root / ".local/state/workgrove/backups").iterdir()), before)

    def test_restore_checks_backup_permissions_before_any_home_changes(self):
        self.install("--persist-agents")
        backups = self.root / ".local/state/workgrove/backups"
        before = sorted(backups.iterdir())
        backups.chmod(0o777)
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        (self.home / ".gitconfig").write_text("supplier configuration")
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False, env=dict(self.env, PATH=""))
        self.assertEqual(result.stderr, "workgrove: shared-configuration-parent\n")
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse((self.home / ".config").exists())
        self.assertEqual((self.home / ".gitconfig").read_text(), "supplier configuration")
        self.assertEqual(sorted(backups.iterdir()), before)

    def test_restore_checks_backup_records_before_any_home_changes(self):
        self.install("--persist-agents")
        backups = self.root / ".local/state/workgrove/backups"
        record = next(backups.glob("*/.workgrove-backup.json"))
        before = sorted(backups.iterdir())
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        (self.home / ".gitconfig").write_text("supplier configuration")
        for contents in ("{invalid", "[]", '{}', '{"path": "example", "order": "invalid"}'):
            record.write_text(contents)
            result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False, env=dict(self.env, PATH=""))
            self.assertEqual(result.stderr, "workgrove: portable-operation-failed\n")
            self.assertFalse((self.home / ".local").exists())
            self.assertFalse((self.home / ".config").exists())
            self.assertEqual((self.home / ".gitconfig").read_text(), "supplier configuration")
            self.assertEqual(sorted(backups.iterdir()), before)

    def test_restore_checks_backup_storage_ancestors_before_home_changes(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        (self.home / ".gitconfig").write_text("supplier configuration")
        for relative in (".local/state", ".local/state/workgrove", ".local/state/workgrove/backups"):
            path = self.root / relative
            saved = path.with_name(path.name + "-saved")
            path.rename(saved)
            path.write_text("occupied storage location")
            result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False, env=dict(self.env, PATH=""))
            self.assertEqual(result.stderr, "workgrove: portable-operation-failed\n")
            self.assertFalse((self.home / ".local").exists())
            self.assertFalse((self.home / ".config").exists())
            self.assertEqual((self.home / ".gitconfig").read_text(), "supplier configuration")
            path.unlink()
            saved.rename(path)

    @unittest.skipIf(os.geteuid() == 0, "Root can write directories without write permission.")
    def test_restore_checks_backup_write_access_before_home_changes(self):
        self.install("--persist-agents")
        backups = self.root / ".local/state/workgrove/backups"
        before = sorted(backups.iterdir())
        backups.chmod(0o500)
        self.addCleanup(backups.chmod, 0o700)
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        (self.home / ".gitconfig").write_text("supplier configuration")
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False, env=dict(self.env, PATH=""))
        self.assertEqual(result.stderr, "workgrove: portable-operation-failed\n")
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse((self.home / ".config").exists())
        self.assertEqual((self.home / ".gitconfig").read_text(), "supplier configuration")
        self.assertEqual(sorted(backups.iterdir()), before)

    def test_full_setup_reuses_identical_backup_in_read_only_storage(self):
        self.install("--persist-agents", "--with-tmux-conf")
        path = self.home / ".tmux.conf"
        path.unlink()
        path.write_text("supplier configuration")
        self.install()
        backups = self.root / ".local/state/workgrove/backups"
        before = sorted(backups.iterdir())
        backups.chmod(0o500)
        self.addCleanup(backups.chmod, 0o700)
        path.unlink()
        path.write_text("supplier configuration")
        result = self.install()
        self.assertIn("removed ~/.tmux.conf; identical backup in .local/state/workgrove/backups/", result.stderr)
        self.assertTrue(path.is_symlink())
        self.assertEqual(sorted(backups.iterdir()), before)

    def test_nested_custom_agent_roots_keep_the_inner_root_private(self):
        outer = self.root / "selected-claude"
        inner = outer / CANARY
        inner.mkdir(parents=True, mode=0o700)
        self.env.update(CLAUDE_CONFIG_DIR=str(outer), CODEX_HOME=str(inner))
        self.install()
        instructions = self.base / "personal-instructions"
        instructions.write_text("Keep personal instructions.\n")
        path = inner / "AGENTS.md"
        path.unlink()
        path.symlink_to(instructions)
        result = self.install()
        self.assertIn("backed up <codex-root>/AGENTS.md to .local/state/workgrove/backups/", result.stderr)
        self.assertEqual(instructions.read_text(), "Keep personal instructions.\n")

    def test_agent_root_containing_home_and_root_keeps_both_paths_private(self):
        old = self.root
        self.root = self.base / CANARY
        old.rename(self.root)
        self.source = self.root / "workgrove"
        self.script = self.source / "lib/workgrove/portable.py"
        self.env["CLAUDE_CONFIG_DIR"] = str(self.base)
        path = self.root / ".local/bin/wt"
        path.parent.mkdir(parents=True, mode=0o700)
        path.write_text("supplier command")
        result = self.install()
        self.assertIn("backed up .local/bin/wt to .local/state/workgrove/backups/", result.stderr)
        self.assertIn("backed up ~/.gitconfig to .local/state/workgrove/backups/", result.stderr)


    def test_restore_refuses_root_files_even_inside_home(self):
        old = self.root
        self.root = self.home / "durable"
        old.rename(self.root)
        self.source = self.root / "workgrove"
        self.script = self.source / "lib/workgrove/portable.py"
        self.install("--persist-agents")
        path = self.root / ".local/bin/wt"
        path.unlink()
        path.write_text("supplier command")
        home = self.home / ".local/bin/azml-ssh-host"
        home.unlink()
        home.write_text("home command")
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual(result.stderr, "workgrove: restore-link-conflict: .local/bin/wt\n")
        self.assertEqual(path.read_text(), "supplier command")
        self.assertEqual(home.read_text(), "home command")

    def test_restore_refuses_claude_skill_files_without_persistence(self):
        self.install()
        path = next((self.home / ".claude/skills").iterdir())
        path.unlink()
        path.write_text("personal skill")
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual(result.stderr, "workgrove: restore-link-conflict: ~/.claude/skills/" + path.name + "\n")
        self.assertEqual(path.read_text(), "personal skill")

    def check_custom_agent_root_diagnostics(self, base):
        selected = base / CANARY
        selected.mkdir(mode=0o700)
        self.env["CLAUDE_CONFIG_DIR"] = str(selected)
        self.install()
        path = next((selected / "skills").iterdir())
        path.unlink()
        path.write_text("personal skill")
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual(result.stderr, "workgrove: restore-link-conflict: <claude-root>/skills/" + path.name + "\n")
        result = self.install()
        self.assertIn("backed up <claude-root>/skills/" + path.name + " to .local/state/workgrove/backups/", result.stderr)

    def test_custom_agent_root_inside_home_stays_private_in_diagnostics(self):
        self.check_custom_agent_root_diagnostics(self.home)

    def test_custom_agent_root_inside_persistent_root_stays_private_in_diagnostics(self):
        self.check_custom_agent_root_diagnostics(self.root)

    def test_fixed_conflicts_name_paths_and_keep_refusal_codes(self):
        directory = self.home / ".local/bin/wt"
        directory.mkdir(parents=True)
        result = self.install(ok=False)
        self.assertEqual(result.stderr, "workgrove: directory-conflict: ~/.local/bin/wt\n")
        directory.rmdir()
        for name in (".bashrc", ".zshenv"):
            path = self.home / name
            path.mkdir()
            result = self.install(ok=False)
            self.assertEqual(result.stderr, "workgrove: shell-configuration-conflict: ~/" + name + "\n")
            path.rmdir()
            path.symlink_to(self.base / CANARY)
            result = self.install(ok=False)
            self.assertEqual(result.stderr, "workgrove: shell-configuration-link-unavailable: ~/" + name + "\n")
            path.unlink()
        with patch.dict(os.environ, self.env, clear=True):
            directory.write_text("command")
            with self.assertRaises(portable.Refusal) as caught:
                portable.link(self.source / "bin/wt", directory, self.root, label="~/.local/bin/wt")
        self.assertEqual(str(caught.exception), "link-conflict")
        self.assertEqual(caught.exception.path, "~/.local/bin/wt")

    def test_shell_marker_refusals_name_paths_before_any_move(self):
        self.install("--persist-agents")
        command = self.home / ".local/bin/azml-ssh-host"
        command.unlink()
        command.write_text("supplier command")
        backups = self.root / ".local/state/workgrove/backups"
        before = sorted(backups.iterdir())
        for name in (".bashrc", ".zshenv"):
            path = self.home / name
            original = path.read_bytes()
            path.write_text("# >>> workgrove environment\n# Missing end marker.\n")
            for mode in ("restore", "install"):
                result = self.command(mode, "--host", "test-host", "--root", str(self.root), ok=False)
                self.assertEqual(result.stderr, "workgrove: managed-text-conflict: ~/" + name + "\n")
                self.assertEqual(command.read_text(), "supplier command")
                self.assertEqual(sorted(backups.iterdir()), before)
            path.write_bytes(original)

    def test_fixed_location_safety_refusals_name_paths_before_any_move(self):
        self.install("--persist-agents")
        command = self.home / ".local/bin/azml-ssh-host"
        command.unlink()
        command.write_text("supplier command")
        backups = self.root / ".local/state/workgrove/backups"
        before = sorted(backups.iterdir())
        for relative in (".local/bin/wt", ".bashrc", ".zshenv"):
            path = self.home / relative
            target = path.readlink() if path.is_symlink() else None
            original = path.read_bytes()
            if target is not None:
                path.unlink()
            path.write_text("shared configuration")
            path.chmod(0o666)
            for mode in ("restore", "install"):
                result = self.command(mode, "--host", "test-host", "--root", str(self.root), ok=False)
                self.assertEqual(result.stderr, "workgrove: shared-configuration-target: ~/" + relative + "\n")
                self.assertEqual(command.read_text(), "supplier command")
                self.assertEqual(sorted(backups.iterdir()), before)
            path.unlink()
            if target is not None:
                path.symlink_to(target)
            else:
                path.write_bytes(original)

    def test_setup_names_conflicting_and_dangling_agent_home_paths(self):
        self.install("--persist-agents")
        before = sorted((self.root / ".local/state/workgrove/backups").iterdir())
        for agent in ("claude", "codex"):
            path = self.home / ("." + agent)
            target = path.readlink()
            path.unlink()
            path.mkdir()
            credentials = path / (".credentials.json" if agent == "claude" else "auth.json")
            credentials.write_text(CANARY)
            result = self.install(ok=False)
            self.assertEqual(result.stderr, "workgrove: agent-home-conflict: ~/." + agent + "\n")
            self.assertEqual(credentials.read_text(), CANARY)
            shutil.rmtree(path)
            path.symlink_to(self.base / CANARY)
            result = self.install(ok=False)
            self.assertEqual(result.stderr, "workgrove: agent-configuration-link-unavailable: ~/." + agent + "\n")
            self.assertEqual(sorted((self.root / ".local/state/workgrove/backups").iterdir()), before)
            path.unlink()
            path.symlink_to(target)

    def test_full_setup_reports_instruction_and_shell_link_moves_privately(self):
        external = self.base / CANARY
        external.mkdir(mode=0o700)
        self.env["CLAUDE_CONFIG_DIR"] = str(external)
        for name in ("AGENTS.md", "CLAUDE.md"):
            (external / name).symlink_to(self.source / "home/.claude/AGENTS.md")
        # Only the foreign instruction link requires a copy.
        (external / "AGENTS.md").unlink()
        instructions = self.base / "private-instructions"
        instructions.write_text("Personal instructions.\n")
        (external / "AGENTS.md").symlink_to(instructions)
        for name in (".bashrc", ".zshenv"):
            target = self.base / ("private" + name)
            target.write_text("# supplier shell\n")
            (self.home / name).symlink_to(target)
        result = self.install()
        self.assertIn("backed up <claude-root>/AGENTS.md to .local/state/workgrove/backups/", result.stderr)
        for name in (".bashrc", ".zshenv"):
            self.assertIn("backed up ~/" + name + " to .local/state/workgrove/backups/", result.stderr)
        self.assertNotIn(str(self.base), result.stderr)
        path = next((external / "skills").iterdir())
        path.unlink()
        path.write_text("personal skill")
        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual(result.stderr, "workgrove: restore-link-conflict: <claude-root>/skills/" + path.name + "\n")

    def test_restore_reports_shell_link_moves_without_deduplicating_links(self):
        self.install("--persist-agents")
        target = self.base / CANARY
        target.write_text("# supplier shell\n")
        backups = self.root / ".local/state/workgrove/backups"
        for attempt in range(2):
            for name in (".bashrc", ".zshenv"):
                path = self.home / name
                path.unlink()
                path.symlink_to(target)
            result = self.command("restore", "--host", "test-host", "--root", str(self.root), env=dict(self.env, PATH=""))
            for name in (".bashrc", ".zshenv"):
                self.assertIn("backed up ~/" + name + " to .local/state/workgrove/backups/", result.stderr)
                copies = list(backups.glob("*/" + name))
                self.assertEqual(len(copies), attempt + 1)
                self.assertTrue(all(copy.is_symlink() and copy.readlink() == target for copy in copies))
            self.assertIn("# supplier shell", (self.home / ".bashrc").read_text())
            self.assertEqual(target.read_text(), "# supplier shell\n")

    def test_conflicting_agent_data_stops_before_migration(self):
        current = self.home / ".codex"
        target = self.root / ".config/codex"
        current.mkdir()
        target.mkdir(parents=True)
        (current / "auth.json").write_text(CANARY)
        (target / "auth.json").write_text("different-data")
        self.assertIn("agent-configuration-conflict", self.install("--persist-agents", ok=False).stderr)
        self.assertFalse(current.is_symlink())
        self.assertEqual((current / "auth.json").read_text(), CANARY)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())

    def test_missing_identity_does_not_move_agent_data(self):
        (self.home / ".gitconfig.local").write_text("# No identity.\n")
        agent = self.home / ".codex"
        agent.mkdir()
        (agent / "auth.json").write_text(CANARY)
        self.install("--persist-agents", ok=False)
        self.assertFalse(agent.is_symlink())
        self.assertEqual((agent / "auth.json").read_text(), CANARY)

    def test_restore_refuses_new_home_data_without_merging(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir()
        (self.home / ".codex").mkdir()
        (self.home / ".codex/auth.json").write_text(CANARY)
        self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertEqual((self.home / ".codex/auth.json").read_text(), CANARY)
        self.assertFalse((self.home / ".local/bin/wt").exists())

    def test_mutable_agent_links_into_repositories_are_rejected(self):
        agent = self.home / ".codex"
        agent.mkdir()
        tracked = self.source / "home/.codex/config.base.toml"
        before = tracked.read_bytes()
        (agent / "config.toml").symlink_to(tracked)
        self.assertIn("repository-destination", self.install("--persist-agents", ok=False).stderr)
        self.assertEqual(tracked.read_bytes(), before)
        self.assertFalse(agent.is_symlink())

    def test_existing_redirected_roots_are_preserved(self):
        external = self.root / "personal-agents/codex"
        external.mkdir(parents=True)
        (external / "auth.json").write_text(CANARY)
        env = dict(self.env, CODEX_HOME=str(external))
        self.command("install", "--root", str(self.root), "--host", "test-host", "--storage", "os-disk",
                     "--persist-agents", env=env)
        self.assertEqual(self.profile()["agent_roots"]["codex"], str(external))
        self.assertEqual((external / "auth.json").read_text(), CANARY)
        self.assertEqual((self.home / ".codex").resolve(), external)

    def test_missing_mount_is_never_created_as_a_replacement(self):
        missing = self.base / "unmounted"
        self.command("install", "--root", str(missing), "--host", "test-host", "--storage", "volume", ok=False)
        self.assertFalse(missing.exists())
        self.command("install", "--root", str(self.root), "--host", "test-host", "--storage", "volume", ok=False)
        self.assertFalse((self.root / ".config/workgrove").exists())

    def test_storage_validation_recognizes_explicit_mount_evidence(self):
        with patch.object(portable, "mounted", return_value=True):
            portable.storage(self.root, "volume", str(self.root))
        with patch.object(portable, "mounted", return_value=False):
            with self.assertRaisesRegex(portable.Refusal, "persistent-mount-missing"):
                portable.storage(self.root, "volume", str(self.root))

    def test_repository_and_symlink_boundaries(self):
        linked = self.base / "linked"
        linked.symlink_to(self.source)
        self.command("install", "--root", str(linked / "personal"), "--storage", "os-disk", ok=False)
        self.assertFalse((self.source / "personal").exists())
        (self.home / ".config").symlink_to(self.source)
        self.install(ok=False)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_doctor_reports_missing_wt_without_remote_installation(self):
        result = self.command("doctor", "--json", ok=False)
        self.assertIn("remote-wt-missing", json.loads(result.stdout)["issues"])
        self.assertFalse((self.root / ".config/workgrove").exists())

    def test_doctor_has_no_agent_warning_without_a_profile(self):
        result = self.command("doctor", "--json", ok=False)
        self.assertEqual(json.loads(result.stdout)["warnings"], [])

    def test_doctor_has_no_agent_warning_for_null_commands(self):
        self.install()
        self.assertEqual(self.profile()["agent_commands"], dict(claude=None, codex=None))
        self.assertEqual(json.loads(self.command("doctor", "--json").stdout)["warnings"], [])

    def test_readiness_fallback_has_warnings(self):
        with patch.object(portable, "_readiness", side_effect=OSError):
            report = portable.readiness()
        self.assertEqual(report["issues"], ["readiness-probe-failed"])
        self.assertEqual(report["warnings"], [])

    def test_doctor_checks_saved_agent_commands_without_running_them(self):
        directory = self.root / "agent-tools"
        directory.mkdir()
        marker = self.base / "agent-ran"
        targets = []
        for agent in ("claude", "codex"):
            target = directory / (agent + "-target")
            target.write_text("#!/bin/sh\ntouch " + shlex.quote(str(marker)) + "\n")
            target.chmod(0o700)
            (directory / agent).symlink_to(target.name)
            targets.append(target)
        self.env["PATH"] = str(directory) + ":" + self.env["PATH"]
        self.install()
        before = json.loads(self.command("doctor", "--json").stdout)
        self.assertTrue(before["ready"])
        self.assertEqual(before["issues"], [])
        self.assertFalse(marker.exists())
        for agent, target in zip(("claude", "codex"), targets):
            self.assertEqual(self.profile()["agent_commands"][agent], str(directory / agent))
            content = target.read_text()
            for kind in ("removed", "non-executable", "dangling-link", "directory"):
                with self.subTest(agent=agent, kind=kind):
                    target.unlink()
                    if kind == "non-executable":
                        target.write_text(content)
                        target.chmod(0o600)
                    elif kind == "dangling-link":
                        target.symlink_to(directory / "missing")
                    elif kind == "directory":
                        target.mkdir()
                    try:
                        result = self.command("doctor", "--json")
                        report = json.loads(result.stdout)
                        self.assertEqual(report["warnings"], ["agent-command-unavailable"])
                        for key in ("ready", "status", "issues", "storage_permission_warnings"):
                            self.assertEqual(report[key], before[key])
                        self.assertNotIn(str(directory), result.stdout + result.stderr)
                        self.assertFalse(marker.exists())
                    finally:
                        if kind == "directory":
                            target.rmdir()
                        elif kind != "removed":
                            target.unlink()
                        target.write_text(content)
                        target.chmod(0o700)
        self.assertEqual(before["warnings"], [])

    def test_doctor_prints_agent_warning_and_preserves_exit_status(self):
        directory = self.root / "agent-tools"
        directory.mkdir()
        command = directory / "codex"
        command.write_text("#!/bin/sh\nexit 0\n")
        command.chmod(0o700)
        self.env["PATH"] = str(directory) + ":" + self.env["PATH"]
        self.install()
        for ready in (True, False):
            if not ready:
                (self.home / ".local/bin/wt").unlink()
            before = self.command("doctor", ok=ready)
            command.unlink()
            result = self.command("doctor", ok=ready)
            self.assertEqual(result.returncode, before.returncode)
            self.assertEqual(result.stdout, before.stdout.replace(
                "native relay", "  agent-command-unavailable\nnative relay"))
            self.assertNotIn(str(command), result.stdout + result.stderr)
            probe = self.command("doctor", "--probe")
            self.assertTrue(probe.stdout.startswith("readiness\t"))
            self.assertEqual(json.loads(probe.stdout.split("\t", 1)[1])["warnings"],
                             ["agent-command-unavailable"])
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o700)

    def test_replaced_home_doctor_explains_explicit_root_recovery(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        result = self.command("doctor", "--json", ok=False)
        self.assertEqual(json.loads(result.stdout)["issues"], ["profile-missing", "remote-wt-missing"])
        hint = ("A host whose home folder was replaced looks new. "
                "The user must give the root. "
                "Run: wt -H <host> doctor --root <root> --json; "
                "then wt -H <host> setup --root <root> --restore-only. "
                "If doctor reports missing prerequisites, run full setup: wt -H <host> setup --root <root>.")
        self.assertEqual(result.stderr, hint + "\n")
        text = self.command("doctor", ok=False)
        self.assertIn("workgrove: incomplete\n", text.stdout)
        self.assertIn("  profile-missing\n  remote-wt-missing\n", text.stdout)
        self.assertIn(hint, text.stdout)
        self.assertEqual(text.stderr, "")
        explicit = self.command("doctor", "--root", str(self.root), "--json", ok=False)
        self.assertEqual(json.loads(explicit.stdout)["issues"],
                         ["compatibility-links-missing", "remote-wt-missing"])
        self.assertEqual(explicit.stderr, "")
        supplied = self.command("doctor", "--json", ok=False,
                                env=dict(self.env, WT_REMOTE_ROOT=str(self.root)))
        self.assertEqual(json.loads(supplied.stdout), json.loads(explicit.stdout))

    def test_doctor_separates_restore_conflicts_from_missing_links(self):
        self.install("--persist-agents")
        locations = ((self.home / ".gitconfig", "directory"),
                     (self.home / ".gitconfig", "foreign-link"),
                     (self.root / ".local/bin/wt", "file"),
                     (next((self.root / ".agents/skills").iterdir()), "file"),
                     (next((self.root / ".config/claude/skills").iterdir()), "file"))
        for path, kind in locations:
            with self.subTest(path=path, kind=kind):
                target = path.readlink()
                path.unlink()
                if kind == "directory":
                    path.mkdir()
                elif kind == "foreign-link":
                    path.symlink_to(self.base / "foreign-target")
                else:
                    path.write_text("supplier file")
                try:
                    report = json.loads(self.command("doctor", "--root", str(self.root), "--json", ok=False).stdout)
                    self.assertEqual(report["issues"], ["compatibility-links-conflict"])
                    refused = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
                    self.assertIn("restore-link-conflict", refused.stderr)
                finally:
                    if kind == "directory":
                        path.rmdir()
                    else:
                        path.unlink()
                    path.symlink_to(target)
        path = self.home / ".gitconfig"
        path.unlink()
        path.write_text("supplier file")
        report = json.loads(self.command("doctor", "--root", str(self.root), "--json", ok=False).stdout)
        self.assertEqual(report["issues"], ["compatibility-links-missing"])
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_doctor_finds_conflicts_after_missing_links(self):
        self.install("--persist-agents")
        (self.root / ".local/bin/agent-notify").unlink()
        path = self.home / ".gitconfig"
        path.unlink()
        path.mkdir()
        report = json.loads(self.command("doctor", "--root", str(self.root), "--json", ok=False).stdout)
        self.assertEqual(report["issues"], ["compatibility-links-conflict", "compatibility-links-missing"])
        self.assertTrue(path.is_dir())
        self.assertFalse((self.root / ".local/bin/agent-notify").exists())

    def test_doctor_uses_link_roles_when_root_is_inside_home(self):
        previous = self.root
        self.root = self.home / "durable"
        previous.rename(self.root)
        self.source = self.root / "workgrove"
        self.script = self.source / "lib/workgrove/portable.py"
        self.install()
        for path in (self.root / ".local/bin/wt", next((self.home / ".claude/skills").iterdir())):
            with self.subTest(path=path):
                target = path.readlink()
                path.unlink()
                path.write_text("persistent file")
                report = json.loads(self.command("doctor", "--root", str(self.root), "--json", ok=False).stdout)
                self.assertEqual(report["issues"], ["compatibility-links-conflict"])
                path.unlink()
                path.symlink_to(target)

    def test_hosts_preserves_restore_conflict_readiness(self):
        self.install("--persist-agents")
        path = self.root / ".local/bin/wt"
        path.unlink()
        path.write_text("persistent file")
        environment = self.transport()
        config = Path(environment["HOME"]) / ".ssh/config"
        config.parent.mkdir()
        config.write_text("Host test-host\n")
        result = subprocess.run([str(self.tools / "bash"), str(REPO / "bin/wt"), "hosts", "--json"],
                                env=environment, capture_output=True, text=True, timeout=30, check=True)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        report, = json.loads(result.stdout)
        self.assertEqual(report["host"], "test-host")
        self.assertEqual(report["readiness_issues"], ["compatibility-links-conflict"])
        self.assertFalse(report["workgrove_ready"])

    def test_restore_detects_replaced_installation(self):
        self.install()
        (self.source / "bin/wt").write_text("#!/bin/sh\nexit 0\n")
        self.assertIn("installation-changed", self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False).stderr)

    def test_strict_setup_checks_source_directories_and_runtime_files(self):
        self.install()
        self.root.chmod(0o755)
        for relative, mode in (("lib/workgrove", 0o777), ("lib/workgrove/task.sh", 0o666)):
            path = self.source / relative
            original = path.stat().st_mode & 0o777
            path.chmod(mode)
            result = self.install(ok=False)
            self.assertIn("installation-writable-by-others", result.stderr)
            report = json.loads(self.command("doctor", "--json", ok=False).stdout)
            self.assertIn("installation-writable-by-others", report["issues"])
            path.chmod(original)
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_source_modes_use_the_explicit_volume_exception(self):
        (self.source / "lib/workgrove").chmod(0o777)
        (self.source / "lib/workgrove/task.sh").chmod(0o666)
        self.volume_install(ok=False)
        self.volume_install("--trust-personal-volume")
        self.assertTrue(json.loads(self.volume_command("doctor", "--json").stdout)["ready"])
        with patch.object(portable.os, "getuid", return_value=-1):
            with self.assertRaisesRegex(portable.Refusal, "installation-foreign-owner"):
                portable.validate_source(self.source)

    def test_source_checks_do_not_follow_unrelated_untracked_environments(self):
        environment = self.source / ".venv/bin"
        environment.mkdir(parents=True)
        (environment / "python3").symlink_to(sys.executable)
        self.install()
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_runtime_directory_links_cannot_hide_writable_source_files(self):
        self.install()
        directory = self.source / "lib/workgrove"
        target = self.source / ".runtime/workgrove"
        target.parent.mkdir()
        directory.rename(target)
        directory.symlink_to("../.runtime/workgrove", target_is_directory=True)
        (target / "task.sh").chmod(0o666)
        self.git("add", "-A")
        self.git("commit", "-qm", "Create the synthetic runtime directory link")
        self.assertIn("installation-source-link-refused", self.install(ok=False).stderr)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("installation-source-link-refused", report["issues"])

    def test_runtime_file_links_are_refused_for_unsafe_and_safe_targets(self):
        self.install()
        original = self.source / "lib/workgrove/task.sh"
        target = self.source / ".runtime/task.sh"
        target.parent.mkdir()
        original.rename(target)
        original.symlink_to("../../.runtime/task.sh")
        self.git("add", "-A")
        self.git("commit", "-qm", "Create the synthetic runtime file link")
        target.parent.chmod(0o777)
        self.assertIn("installation-source-link-refused", self.install(ok=False).stderr)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("installation-source-link-refused", report["issues"])
        target.parent.chmod(0o755)
        self.assertIn("installation-source-link-refused", self.install(ok=False).stderr)

    def test_runtime_file_links_cannot_traverse_unchecked_directory_links(self):
        self.install()
        original = self.source / "lib/workgrove/task.sh"
        target = self.source / ".safe/task.sh"
        target.parent.mkdir()
        original.rename(target)
        intermediate = self.source / ".runtime"
        intermediate.mkdir()
        (intermediate / "door").symlink_to("../.safe", target_is_directory=True)
        original.symlink_to("../../.runtime/door/task.sh")
        self.git("add", "-A")
        self.git("commit", "-qm", "Create the synthetic indirect runtime link")
        intermediate.chmod(0o777)
        self.assertIn("installation-source-link-refused", self.install(ok=False).stderr)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("installation-source-link-refused", report["issues"])

    def test_seeded_shared_clones_and_linked_objects_are_refused(self):
        external = self.base / "external-source"
        self.source.rename(external)
        subprocess.run([str(self.tools / "git"), "clone", "--shared", str(external), str(self.source)],
                       env=self.env, check=True, capture_output=True, text=True)
        result = self.install(ok=False)
        self.assertIn("standalone-object-store-required", result.stderr)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        (self.source / ".git/objects/info/alternates").unlink()
        objects = self.source / ".git/objects"
        promisor = objects / "pack/synthetic.promisor"
        promisor.parent.mkdir(exist_ok=True)
        promisor.write_text("")
        self.assertIn("standalone-object-store-required", self.install(ok=False).stderr)
        promisor.unlink()
        objects.rename(self.base / "external-objects")
        objects.symlink_to(self.base / "external-objects", target_is_directory=True)
        self.assertIn("standalone-object-store-required", self.install(ok=False).stderr)

    def test_doctor_refuses_missing_installation_objects(self):
        self.install()
        objects = self.source / ".git/objects"
        shutil.rmtree(objects)
        objects.mkdir()
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("installation-object-store-incomplete", report["issues"])

    def test_plain_installer_rerun_keeps_portable_profile(self):
        self.install("--persist-agents", "--with-tmux-conf")
        result = subprocess.run([str(self.tools / "bash"), str(self.source / "install.sh")], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.profile()["tmux"])
        self.assertEqual(self.profile()["root"], str(self.root))

    def test_portable_update_refuses_unsupported_flags_before_fetch(self):
        upstream = self.base / "upstream"
        self.git("clone", "--quiet", str(self.source), str(upstream))
        self.git("remote", "add", "origin", str(upstream))
        self.git("fetch", "--quiet", "origin")
        branch = self.git("branch", "--show-current").stdout.strip()
        self.git("branch", "--set-upstream-to", "origin/" + branch)
        with (upstream / "bin/wt").open("a") as stream:
            stream.write("\n# Synthetic incoming runtime change.\n")
        self.git("-C", str(upstream), "add", "bin/wt")
        self.git("-C", str(upstream), "commit", "-qm", "Change the synthetic runtime")
        self.install()
        before = self.command("doctor", "--json").stdout
        self.assertIsNot(json.loads(before)["ready"], False)
        fetch_head = (self.source / ".git/FETCH_HEAD").read_bytes()
        tracking = self.git("rev-parse", "@{u}").stdout
        profile = self.profile()
        for flag in ("--with-zshrc", "--opinionated-config", "--with-future-config"):
            with self.subTest(flag=flag):
                result = subprocess.run([str(self.tools / "bash"), str(self.source / "bin/wt"), "update", flag],
                                        env=self.env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"update: portable host refuses {flag}; accepted flags:", result.stderr)
                accepted = result.stderr.partition("accepted flags:")[2].strip().split()
                self.assertEqual(set(accepted), {"--with-tmux-conf", "--refresh-config"})
                self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.revision)
                self.assertEqual((self.source / ".git/FETCH_HEAD").read_bytes(), fetch_head)
                self.assertEqual(self.git("rev-parse", "@{u}").stdout, tracking)
                self.assertEqual(self.command("doctor", "--json").stdout, before)
                self.assertEqual(self.profile(), profile)

    def test_portable_installer_names_unsupported_argument(self):
        self.install()
        result = subprocess.run([str(self.tools / "bash"), str(self.source / "install.sh"), "--with-zshrc"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn("workgrove: invalid-arguments: unrecognized arguments: --with-zshrc", result.stderr)

    def test_portable_update_accepts_reinstall_flags(self):
        parser = self.script.read_text()
        self.script.write_text(parser.replace('        command.add_argument("--refresh-config", action="store_true")',
                                             '        command.add_argument("--refresh-config", action="store_true")\n'
                                             '        command.add_argument("--with-future-config", action="store_true")'))
        self.git("add", str(self.script))
        self.git("commit", "-qm", "Add a synthetic reinstall flag")
        upstream = self.base / "upstream.git"
        self.git("clone", "--bare", str(self.source), str(upstream))
        self.git("remote", "add", "origin", str(upstream))
        self.git("fetch", "--quiet", "origin")
        branch = self.git("branch", "--show-current").stdout.strip()
        self.git("branch", "--set-upstream-to", "origin/" + branch)
        self.install()
        accepted = self.command("reinstall-flags").stdout.split()
        for flag in ("--refresh-config", "--with-tmux-conf", "--with-future-config"):
            self.assertIn(flag, accepted)
        for flag in ("--refresh-config", "--with-tmux-conf", "--with-tmux", "--with-tm", "--with-future-config"):
            with self.subTest(flag=flag):
                result = subprocess.run([str(self.tools / "bash"), str(self.source / "bin/wt"), "update", flag],
                                        env=self.env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.command("doctor", "--json")
        self.assertTrue(self.profile()["tmux"])

    def test_portable_installer_and_update_share_supported_python_selection(self):
        runtime = self.source / "lib/workgrove/vm/python-runtime.sh"
        original = runtime.read_text()
        supported = self.base / "supported-python"
        supported.symlink_to(sys.executable)
        runtime.write_text(original.replace("/usr/bin/python3", str(supported)))
        self.git("add", str(runtime))
        self.git("commit", "-qm", "Configure the synthetic Python fallback")
        self.install("--persist-agents")
        upstream = self.base / "local-upstream.git"
        self.git("clone", "--bare", str(self.source), str(upstream))
        self.git("remote", "add", "origin", str(upstream))
        self.git("fetch", "--quiet", "origin")
        branch = self.git("branch", "--show-current").stdout.strip()
        self.git("branch", "--set-upstream-to", "origin/" + branch)
        old = self.tools / "python3"
        old.unlink()
        old.write_text("#!/bin/sh\nexit 1\n")
        old.chmod(0o700)
        commands = ([str(self.source / "install.sh")],
                    [str(self.source / "install.sh"), "--remote-root", str(self.root)],
                    [str(self.source / "bin/wt"), "update"])
        for command in commands:
            with self.subTest(command=Path(command[0]).name, args=command[1:]):
                result = subprocess.run([str(self.tools / "bash"), *command], env=self.env,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
        before = self.profile()
        runtime.write_text(original.replace("/usr/bin/python3", str(self.base / "missing-system-python")))
        for command in commands:
            result = subprocess.run([str(self.tools / "bash"), *command], env=self.env,
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("python-3.9-required", result.stderr)
            self.assertEqual(self.profile(), before)

    def test_bootstrap_uses_selected_installation_without_changing_git(self):
        result = self.command("bootstrap", "--root", str(self.root), "--host", "test-host", "--storage", "os-disk",
                              "--revision", self.revision)
        self.assertIn("installed", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.revision)
        self.command("bootstrap", "--root", str(self.root), "--revision", "0" * 40, ok=False)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.revision)

    def test_trusted_bootstrap_rejects_modified_installer_before_execution(self):
        marker = self.base / "unexpected-installer-execution"
        self.script.write_text(f'from pathlib import Path; Path({str(marker)!r}).touch()\n' + self.script.read_text())
        result = subprocess.run([sys.executable, "-B", str(REPO / "lib/workgrove/portable.py"), "bootstrap",
                                 "--root", str(self.root), "--host", "test-host", "--storage", "os-disk",
                                 "--revision", self.revision], env=self.env, text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installation-has-local-edits", result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.revision)

    def test_trusted_bootstrap_rejects_revision_mismatch_before_execution(self):
        marker = self.base / "unexpected-installer-execution"
        self.script.write_text(f'from pathlib import Path; Path({str(marker)!r}).touch()\n' + self.script.read_text())
        self.git("add", "lib/workgrove/portable.py")
        self.git("commit", "-qm", "Create different synthetic installer revision")
        selected = self.git("rev-parse", "HEAD").stdout.strip()
        result = subprocess.run([sys.executable, "-B", str(REPO / "lib/workgrove/portable.py"), "bootstrap",
                                 "--root", str(self.root), "--host", "test-host", "--storage", "os-disk",
                                 "--revision", self.revision], env=self.env, text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("selected-revision-unavailable", result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), selected)

    def test_durable_agent_commands_keep_the_owning_installers_indirection(self):
        directory = self.root / "agent-tools/bin"
        directory.mkdir(parents=True)
        first = self.root / "agent-tools/first"
        second = self.root / "agent-tools/second"
        for path in (first, second):
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o700)
        command = directory / "codex"
        command.symlink_to(first)
        self.env["PATH"] = str(directory) + ":" + self.env["PATH"]
        self.install("--persist-agents")
        self.assertEqual(self.profile()["agent_commands"]["codex"], str(command))
        self.assertEqual((self.root / ".local/bin/codex").readlink(), command)
        command.unlink()
        command.symlink_to(second)
        self.assertEqual((self.root / ".local/bin/codex").resolve(), second)
        shutil.rmtree(self.home)
        self.home.mkdir()
        self.command("restore", "--host", "test-host", "--root", str(self.root))
        self.assertEqual((self.home / ".local/bin/codex").resolve(), second)

    def test_unicode_and_spaces_in_the_persistent_root(self):
        old = self.root
        self.root = self.base / "durable space-\u00e9"
        old.rename(self.root)
        self.source = self.root / "workgrove"
        self.script = self.source / "lib/workgrove/portable.py"
        self.install("--persist-agents")
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_shell_environment_never_restores_a_missing_link(self):
        self.install("--persist-agents")
        command = self.home / ".local/bin/wt"
        command.unlink()
        result = subprocess.run([str(self.tools / "bash"), "--noprofile", "--norc", "-c", '. "$HOME/.bashrc"'],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(command.exists())
        self.assertFalse(command.is_symlink())

    def test_shell_path_survives_host_reset_and_reinstall(self):
        old = self.root
        self.root = self.base / "durable 'space-$\u00e9"
        old.rename(self.root)
        self.source = self.root / "workgrove"
        self.script = self.source / "lib/workgrove/portable.py"
        bashrc = self.home / ".bashrc"
        bashrc.write_text('[ -z "$PS1" ] && return\nexport PATH=/usr/bin:/bin\n'
                          'export CODEX_HOME="$HOME/supplier-codex"\n'
                          'export CLAUDE_CONFIG_DIR="$HOME/supplier-claude"\n')
        expected = f'{self.root}/.local/bin:{self.home}/.local/bin:'
        for attempt in range(2):
            self.install()
            interactive = subprocess.run(
                [str(self.tools / "bash"), "-ic", 'printf "%s\\n" "$PATH" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"'],
                env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(interactive.returncode, 0, interactive.stderr)
            self.assertEqual(interactive.stdout.splitlines(),
                             [expected + "/usr/bin:/bin", str(self.home / "supplier-codex"),
                              str(self.home / "supplier-claude")])
            noninteractive = subprocess.run(
                [str(self.tools / "bash"), "-c", '. "$HOME/.bashrc"; printf %s "$PATH"'],
                env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(noninteractive.returncode, 0, noninteractive.stderr)
            self.assertEqual(noninteractive.stdout, expected + self.env["PATH"])
            for label in ("environment", "interactive path"):
                for marker in (">>>", "<<<"):
                    self.assertEqual(bashrc.read_text().count(f"# {marker} workgrove {label}\n"), 1)
            self.assertTrue(bashrc.read_text().endswith("# <<< workgrove interactive path\n"))
            self.assertNotIn("workgrove interactive path", (self.home / ".zshenv").read_text())
            if attempt == 0:
                with bashrc.open("a") as stream:
                    stream.write("export PATH=/usr/bin:/bin\n")

    def test_shell_path_only_adds_missing_folders(self):
        self.install()
        text = (self.home / ".bashrc").read_text()
        self.assertIn("# >>> workgrove interactive path\n", text)
        text = text.split("# >>> workgrove interactive path\n")[1]
        root_bin, home_bin = str(self.root / ".local/bin"), str(self.home / ".local/bin")
        for initial, expected in (("/usr/bin:/bin", f"{root_bin}:{home_bin}:/usr/bin:/bin"),
                                  (f"/bin:{root_bin}", f"{home_bin}:/bin:{root_bin}"),
                                  (f"{home_bin}:/bin", f"{root_bin}:{home_bin}:/bin"),
                                  (f"/bin:{home_bin}:{root_bin}", f"/bin:{home_bin}:{root_bin}"),
                                  (f"{root_bin}-other:{home_bin}-other",
                                   f"{root_bin}:{home_bin}:{root_bin}-other:{home_bin}-other")):
            with self.subTest(initial=initial):
                result = subprocess.run([str(self.tools / "bash"), "-c", text + text + 'printf %s "$PATH"'],
                                        env=dict(self.env, PATH=initial), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_restore_writes_both_shell_blocks_after_home_replacement(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        (self.home / ".bashrc").write_text('[ -z "$PS1" ] && return\nexport PATH=/usr/bin:/bin\n')
        self.command("restore", "--host", "test-host", "--root", str(self.root), env=dict(self.env, PATH=""))
        text = (self.home / ".bashrc").read_text()
        self.assertTrue(text.startswith("# >>> workgrove environment\n"))
        self.assertTrue(text.endswith("# <<< workgrove interactive path\n"))
        self.assertNotIn("workgrove interactive path", (self.home / ".zshenv").read_text())
        result = subprocess.run([str(self.tools / "bash"), "-ic", 'printf %s "$PATH"'],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{self.root}/.local/bin:{self.home}/.local/bin:/usr/bin:/bin")

    def test_shell_path_conflicts_refuse_before_install_or_restore_changes(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        bashrc = self.home / ".bashrc"
        start, end = "# >>> workgrove interactive path\n", "# <<< workgrove interactive path\n"
        for text in (start, end, (start + ":\n" + end) * 2, end + start):
            for operation in ("install", "restore"):
                with self.subTest(text=text, operation=operation):
                    bashrc.write_text(text)
                    if operation == "install":
                        result = self.install(ok=False)
                    else:
                        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
                    self.assertEqual(result.stderr, "workgrove: managed-text-conflict: ~/.bashrc\n")
                    self.assertEqual(bashrc.read_text(), text)
                    self.assertFalse((self.home / ".local").exists())
                    self.assertFalse((self.home / ".zshenv").exists())

    def test_linked_bashrc_gets_both_blocks_with_one_backup_and_write(self):
        self.install()
        bashrc = self.home / ".bashrc"
        bashrc.unlink()
        supplier = self.base / "supplier-bashrc"
        supplier.write_text("export PATH=/usr/bin:/bin\n")
        bashrc.symlink_to(supplier)
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(portable, "backup", wraps=portable.backup) as backup, \
                patch.object(portable, "write", wraps=portable.write) as write:
            portable.install_files(self.profile())
        self.assertEqual([call.args for call in backup.call_args_list if call.args[0] == bashrc],
                         [(bashrc, self.root)])
        writes = [call.args[1] for call in write.call_args_list if call.args[0] == bashrc]
        self.assertEqual(len(writes), 1)
        self.assertIn("# >>> workgrove environment\n", writes[0])
        self.assertTrue(writes[0].endswith("# <<< workgrove interactive path\n"))
        self.assertFalse(bashrc.is_symlink())
        self.assertEqual(supplier.read_text(), "export PATH=/usr/bin:/bin\n")

    def test_interleaved_shell_blocks_refuse_before_home_backups(self):
        self.install("--persist-agents")
        environment = ("# >>> workgrove environment\n", "# <<< workgrove environment\n")
        interactive = ("# >>> workgrove interactive path\n", "# <<< workgrove interactive path\n")
        for outer, inner in ((environment, interactive), (interactive, environment)):
            for operation in ("install", "restore"):
                with self.subTest(outer=outer, operation=operation):
                    shutil.rmtree(self.home)
                    self.home.mkdir(mode=0o700)
                    text = outer[0] + inner[0] + outer[1] + inner[1]
                    (self.home / ".bashrc").write_text(text)
                    gitconfig = self.home / ".gitconfig"
                    gitconfig.write_bytes(b"supplier Git configuration")
                    backups = self.root / ".local/state/workgrove/backups"
                    before = set(backups.iterdir())
                    if operation == "install":
                        result = self.install(ok=False)
                    else:
                        result = self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False,
                                              env=dict(self.env, PATH=""))
                    self.assertEqual(result.stderr, "workgrove: managed-text-conflict: ~/.bashrc\n")
                    self.assertEqual((self.home / ".bashrc").read_text(), text)
                    self.assertFalse(gitconfig.is_symlink())
                    self.assertEqual(gitconfig.read_bytes(), b"supplier Git configuration")
                    self.assertEqual(set(backups.iterdir()), before)
                    self.assertFalse((self.home / ".local").exists())
                    self.assertFalse((self.home / ".zshenv").exists())

    def test_doctor_does_not_replace_personal_files_or_create_backups(self):
        self.install("--persist-agents")
        folder = self.root / ".config/workgrove"
        before = {str(path.relative_to(folder)): path.stat().st_mtime_ns
                  for path in folder.rglob("*") if path.is_file()}
        self.command("doctor", "--json")
        after = {str(path.relative_to(folder)): path.stat().st_mtime_ns
                 for path in folder.rglob("*") if path.is_file()}
        self.assertEqual(before, after)

    def test_missing_persistent_agent_data_blocks_full_repair(self):
        self.install("--persist-agents")
        target = Path(self.profile()["agent_roots"]["codex"])
        shutil.rmtree(target)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("persistent-agent-configuration-missing", report["issues"])
        self.command("doctor", "--preflight", ok=False)
        self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.command("install", "--root", str(self.root), ok=False)
        self.assertFalse(target.exists())

    def test_git_copy_preserves_order_duplicates_and_implicit_values(self):
        child = self.home / "included"
        child.write_text('[user]\n email = included@example.invalid\n')
        original = self.home / ".gitconfig"
        original.write_text('[include]\n path = ./included\n[user]\n name = Test User\n'
                            ' email = outer@example.invalid\n[include]\n path = ./included\n'
                            '[user]\n email = final@example.invalid\n[custom "Mixed.Case"]\n'
                            ' flag\n value = "line\\nwith\\ttabs\\b\\\\\\\""\n')
        with original.open("a") as stream:
            stream.write('[custom "Tab\tSection"]\n value = preserved\n')
        before = self.git("config", "--global", "--includes", "--null", "--list").stdout
        self.install()
        after = self.git("config", "--global", "--includes", "--null", "--list").stdout
        def values(output):
            return [item for item in output.split("\0") if item and not item.startswith(("include.path\n", "core.excludesfile\n"))]
        self.assertEqual(values(after), values(before))
        self.assertEqual(self.git("config", "--global", "--includes", "--get", "user.email").stdout.strip(),
                         "final@example.invalid")

    def test_git_copy_anchors_nested_relative_conditions_at_logical_source(self):
        store = self.base / "store"
        store.mkdir()
        original = self.home / ".gitconfig"
        original.unlink()
        original.symlink_to(store / "global")
        (store / "global").write_text('[include]\n path = ./nested/config\n')
        nested = self.home / "nested"
        nested.mkdir()
        (nested / "config").write_text('[user]\n name = Test User\n email = default@example.invalid\n'
                                       '[includeIf "gitdir:./projects/"]\n path = ./project\n'
                                       '[includeIf "gitdir/i:./PROJECTS/"]\n path = ./case-project\n')
        (nested / "project").write_text('[user]\n email = project@example.invalid\n')
        (nested / "case-project").write_text('[user]\n email = insensitive@example.invalid\n')
        project = nested / "projects/example"
        project.mkdir(parents=True)
        self.git("init", "-q", str(project))
        before = self.git("-C", str(project), "config", "--global", "--includes", "--get", "user.email").stdout
        self.assertEqual(before.strip(), "insensitive@example.invalid")
        self.install()
        after = self.git("-C", str(project), "config", "--global", "--includes", "--get", "user.email").stdout
        self.assertEqual(after, before)

    def test_git_copy_preserves_both_global_sources_and_their_precedence(self):
        self.env.pop("GIT_CONFIG_GLOBAL")
        self.env["XDG_CONFIG_HOME"] = str(self.home / "xdg")
        xdg = self.home / "xdg/git/config"
        xdg.parent.mkdir(parents=True)
        xdg.write_text('[user]\n name = XDG User\n email = xdg@example.invalid\n[custom]\n order = xdg\n')
        (self.home / ".gitconfig").write_text('[custom]\n order = home\n')
        self.install()
        self.assertEqual(self.git("config", "--global", "--includes", "--get", "user.email").stdout.strip(), "xdg@example.invalid")
        self.assertEqual(self.git("config", "--global", "--includes", "--get-all", "custom.order").stdout.splitlines(), ["xdg", "home"])
        self.install()
        self.assertEqual(self.git("config", "--global", "--includes", "--get-all", "custom.order").stdout.splitlines(), ["xdg", "home"])

    def test_full_setup_reuses_durable_git_configuration_after_home_loss(self):
        self.install("--persist-agents")
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        self.install()
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])
        self.assertEqual(self.git("config", "--global", "--includes", "--get", "user.email").stdout.strip(), "test@example.invalid")

    def test_identity_refresh_preserves_later_user_overrides_and_helper_resets(self):
        identity = self.home / "identity"
        identity.write_text('[user]\n email = selected@example.invalid\n[credential]\n helper = cache\n')
        self.install("--git-identity", str(identity))
        active = self.root / ".config/workgrove/git/global"
        with active.open("a") as stream:
            stream.write('[user]\n email = edited@example.invalid\n[credential]\n helper =\n')
        for args in ((), ("--git-identity", str(identity))):
            before = self.git("config", "--global", "--includes", "--get-all", "credential.helper").stdout
            self.install(*args)
            self.assertEqual(self.git("config", "--global", "--includes", "--get", "user.email").stdout.strip(), "edited@example.invalid")
            self.assertEqual(self.git("config", "--global", "--includes", "--get-all", "credential.helper").stdout, before)

    def git_generations(self):
        folder = self.root / ".config/workgrove/git"
        return {path for path in folder.iterdir() if re.fullmatch(r"[0-9a-f]{32}", path.name)
                and not path.is_symlink() and path.is_dir()}

    def test_git_generations_keep_identity_after_three_plain_installs(self):
        identity = self.home / "identity"
        identity.write_text('[user]\n name = Selected User\n email = selected@example.invalid\n')
        self.install("--git-identity", str(identity))
        active = self.root / ".config/workgrove/git/global"
        self.env["GIT_CONFIG_GLOBAL"] = str(active)
        for _ in range(3):
            previous = self.git_generations()
            self.install()
            current = self.git_generations()
            self.assertLessEqual(len(current), 2)
            for key, value in (("user.name", "Selected User"), ("user.email", "selected@example.invalid")):
                self.assertEqual(self.git("config", "--global", "--includes", "--get", key).stdout.strip(), value)
            overlay = portable.git_owned_path(active.read_text(), "identity", active.parent)
            self.assertNotIn(overlay.parents[1], previous)
        self.install("--git-identity", str(overlay))
        self.assertFalse(overlay.exists())
        self.assertEqual(self.git("config", "--global", "--includes", "--get", "user.email").stdout.strip(),
                         "selected@example.invalid")

    def test_failed_git_setup_before_activation_keeps_generations_and_active_configuration(self):
        self.install()
        active = self.root / ".config/workgrove/git/global"
        before = self.git_generations(), active.read_bytes()
        invalid = self.home / "invalid-identity"
        invalid.write_text('[broken\n')
        self.install("--git-identity", str(invalid), ok=False)
        self.assertEqual((self.git_generations(), active.read_bytes()), before)

    def test_failed_git_setup_after_activation_keeps_generations_and_active_configuration(self):
        self.install()
        active = self.root / ".config/workgrove/git/global"
        stale = active.parent / ("a" * 32)
        stale.mkdir()
        before = self.git_generations(), active.read_bytes()
        for step in ("install_files", "write"):
            original = portable.write
            def fail(*args, **kwargs):
                if step == "install_files" or args[0] == portable.machine_path(self.root):
                    raise portable.Refusal("synthetic-install-failure")
                return original(*args, **kwargs)
            with self.subTest(step=step), patch.dict(os.environ, self.env, clear=True), \
                    patch.object(portable, step, side_effect=fail), \
                    patch.object(sys, "argv", ["portable.py", "install", "--root", str(self.root), "--host", "test-host"]), \
                    patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
                self.assertEqual(portable.main(), 1)
            self.assertEqual((self.git_generations(), active.read_bytes()), before)

    def test_failed_first_git_setup_removes_new_generation_and_active_configuration(self):
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(portable, "install_files", side_effect=portable.Refusal("synthetic-install-failure")), \
                patch.object(sys, "argv", ["portable.py", "install", "--root", str(self.root), "--host", "test-host",
                                           "--storage", "os-disk"]), \
                patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
            self.assertEqual(portable.main(), 1)
        self.assertEqual(self.git_generations(), set())
        self.assertFalse((self.root / ".config/workgrove/git/global").exists())

    def test_git_pruning_keeps_links_and_other_entries(self):
        self.install()
        folder = self.root / ".config/workgrove/git"
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep\n")
        link = folder / ("a" * 32)
        link.symlink_to(outside, target_is_directory=True)
        other = folder / "personal"
        other.mkdir()
        (other / "keep").write_text("keep\n")
        stale = folder / ("b" * 32)
        stale.mkdir()
        (stale / "link").symlink_to(outside, target_is_directory=True)
        (folder / "missing-defaults").write_text("keep\n")
        with patch.dict(os.environ, self.env, clear=True), portable.installation_lock(self.root):
            portable.prune_git_generations(folder, next(iter(self.git_generations() - {link, stale})))
        self.assertFalse(stale.exists())
        self.assertTrue(link.is_symlink())
        self.assertEqual((outside / "keep").read_text(), "keep\n")
        self.assertEqual((other / "keep").read_text(), "keep\n")
        self.assertEqual((folder / "missing-defaults").read_text(), "keep\n")

    def test_doctor_and_restore_leave_git_generations_unchanged(self):
        self.install()
        stale = self.root / ".config/workgrove/git" / ("c" * 32)
        stale.mkdir()
        before = self.git_generations()
        self.command("doctor", "--root", str(self.root), "--json")
        self.command("restore", "--root", str(self.root), "--host", "test-host")
        self.assertEqual(self.git_generations(), before)

    def test_git_pruning_keeps_reachable_legacy_nested_conditional_and_exclusion_files(self):
        self.install()
        folder = self.root / ".config/workgrove/git"
        legacy, nested, conditional, exclusions, creating = [folder / (char * 32) for char in "abcde"]
        for path in (legacy, nested, conditional, exclusions, creating):
            path.mkdir()
        (folder / "global").write_text('[include]\n path = ' + str(legacy / "global") + '\n')
        (legacy / "global").write_text('[include]\n path = ../' + nested.name + '/config\n'
                                       '[core]\n excludesFile = ' + str(legacy / "ignore") + '\n')
        (legacy / "ignore").write_text("legacy\n")
        (nested / "config").write_text('[includeIf "gitdir:/never-matches/"]\n path = ../' + conditional.name + '/config\n')
        (conditional / "config").write_text('[core]\n excludesFile = ' + str(exclusions / "defaults") + '\n')
        (exclusions / "defaults").write_text("excluded\n")
        with patch.dict(os.environ, self.env, clear=True), portable.installation_lock(self.root):
            portable.prune_git_generations(folder, creating)
        self.assertEqual(self.git_generations(), {legacy, nested, conditional, exclusions, creating})

    def test_git_pruning_failure_does_not_fail_installation(self):
        self.install()
        stale = self.root / ".config/workgrove/git" / ("f" * 32)
        stale.mkdir()
        original = portable.shutil.rmtree
        def fail(path, *args, **kwargs):
            if path == stale:
                raise PermissionError("synthetic-prune-failure")
            return original(path, *args, **kwargs)
        with patch.dict(os.environ, self.env, clear=True), patch.object(portable.shutil, "rmtree", side_effect=fail) as removal, \
                patch.object(sys, "argv", ["portable.py", "install", "--root", str(self.root), "--host", "test-host"]), \
                patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
            self.assertEqual(portable.main(), 0)
        removal.assert_any_call(stale)
        self.assertTrue(stale.is_dir())

    def test_git_pruning_checks_combined_graphs_and_cycles(self):
        self.install()
        folder = self.root / ".config/workgrove/git"
        stale = self.git_generations()
        creating = folder / ("e" * 32)
        creating.mkdir()
        includes = []
        for number in range(70):
            config = creating / str(number)
            config.write_text('[include]\n path = ' + str(creating / "0") + '\n')
            includes.append('[include]\n path = ' + str(config) + '\n')
        (folder / "global").write_text("".join(includes))
        with patch.dict(os.environ, self.env, clear=True), portable.installation_lock(self.root):
            portable.prune_git_generations(folder, creating)
        self.assertTrue(all(not path.exists() for path in stale))
        self.assertEqual(self.git_generations(), {creating})

    def test_git_maintenance_keeps_user_entries_added_inside_managed_sections(self):
        self.install()
        self.git("config", "--global", "core.editor", "test-editor")
        ignore = self.home / "second-ignore"
        ignore.write_text("second-secret\n")
        self.git("config", "--global", "--add", "core.excludesFile", str(ignore))
        self.install()
        self.assertEqual(self.git("config", "--global", "--get", "core.editor").stdout.strip(), "test-editor")
        self.git("check-ignore", "--no-index", "second-secret", ".worktrees/task")

    def test_git_exclusions_keep_per_repository_conditions(self):
        projects = []
        for number in range(2):
            project = self.root / f"project-{number}"
            self.git("init", "-q", str(project))
            ignore = self.home / f"ignore-{number}"
            ignore.write_text(f"secret-{number}\n")
            branch = self.home / f"config-{number}"
            branch.write_text('[core]\n excludesFile = ' + str(ignore) + '\n')
            with (self.home / ".gitconfig").open("a") as stream:
                stream.write(f'[includeIf "gitdir:{project}/"]\n path = {branch}\n')
            projects.append(project)
        self.install()
        for number, project in enumerate(projects):
            self.git("-C", str(project), "check-ignore", "--no-index", f"secret-{number}", ".worktrees/task")
            result = subprocess.run([str(self.tools / "git"), "-C", str(project), "check-ignore", "--no-index",
                                     f"secret-{1-number}"], env=self.env, capture_output=True)
            self.assertEqual(result.returncode, 1)

    def test_git_exclusions_preserve_implicit_defaults_and_explicit_missing_files(self):
        (self.home / ".gitconfig").write_text('[user]\n name = Test User\n email = test@example.invalid\n')
        implicit = self.home / ".config/git/ignore"
        implicit.parent.mkdir(parents=True)
        implicit.write_text("implicit-secret\n")
        project = self.root / "project"
        self.git("init", "-q", str(project))
        self.install()
        self.git("-C", str(project), "check-ignore", "--no-index", "implicit-secret", ".worktrees/task")
        self.git("config", "--global", "core.excludesFile", str(self.home / "missing-ignore"))
        self.install()
        result = subprocess.run([str(self.tools / "git"), "-C", str(project), "check-ignore", "--no-index",
                                 "implicit-secret"], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.git("-C", str(project), "check-ignore", "--no-index", ".worktrees/task")

    def test_explicit_identity_refresh_is_repeatable_and_preserves_active_settings(self):
        identity = self.home / "identity"
        identity.write_text('[user]\n name = Selected User\n email = selected@example.invalid\n[credential]\n helper = cache\n')
        self.install("--git-identity", str(identity))
        helpers = self.git("config", "--global", "--includes", "--get-all", "credential.helper").stdout
        self.git("config", "--global", "custom.keep", "retained")
        for _ in range(12):
            self.install("--git-identity", str(identity))
        self.install("--git-identity", str(self.home / ".gitconfig"))
        active = self.root / ".config/workgrove/git/global"
        overlay = portable.git_owned_path(active.read_text(), "identity", active.parent)
        self.install("--git-identity", str(overlay))
        self.assertEqual(self.git("config", "--global", "--includes", "--get-all", "credential.helper").stdout, helpers)
        self.assertEqual(self.git("config", "--global", "--get", "custom.keep").stdout.strip(), "retained")
        overlay = portable.git_owned_path(active.read_text(), "identity", active.parent)
        before = active.read_bytes(), overlay.read_bytes()
        invalid = self.home / "invalid-identity"
        invalid.write_text("[broken\n")
        self.install("--git-identity", str(invalid), ok=False)
        self.assertEqual((active.read_bytes(), overlay.read_bytes()), before)

    def test_legacy_git_graph_is_adopted_without_another_include_layer(self):
        self.install()
        folder = self.root / ".config/workgrove/git"
        personal = self.home / "personal-base"
        personal.write_text('[include]\n path = ' + str(self.home / ".gitconfig.local") + '\n'
                            '[core]\n excludesFile = ' + str(self.home / "ignore") + '\n')
        target = personal
        for number in range(8):
            generation = folder / f"{number:032x}"
            generation.mkdir()
            (generation / "ignore").write_text("private-example\n.worktrees/\n")
            current = generation / "global"
            current.write_text('[include]\n path = ' + str(target) + '\n[core]\n excludesFile = ' + str(generation / "ignore") + '\n')
            target = current
        (folder / "global").write_text('[include]\n path = ' + str(target) + '\n')
        self.git("config", "--global", "--includes", "--get", "user.email")
        for _ in range(3):
            self.install("--git-identity", str(self.home / ".gitconfig.local"))
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_git_copy_traverses_symlink_directories_before_parent_components(self):
        target = self.base / "elsewhere/deep"
        (target / "directory").mkdir(parents=True)
        (self.home / "link").symlink_to(target / "directory")
        (self.home / ".gitconfig").write_text('[include]\n path = ./link/../child\n')
        (self.home / "child").write_text('[user]\n name = Test User\n email = lexical@example.invalid\n')
        (target / "child").write_text('[user]\n name = Test User\n email = parent@example.invalid\n'
                                      '[include]\n path = ./nested\n')
        (target / "nested").write_text('[user]\n email = intended@example.invalid\n')
        before = self.git("config", "--global", "--includes", "--get", "user.email").stdout
        self.assertEqual(before.strip(), "intended@example.invalid")
        self.install()
        self.assertEqual(self.git("config", "--global", "--includes", "--get", "user.email").stdout, before)

    def test_source_git_does_not_inherit_repository_or_object_storage(self):
        external = self.base / "external-objects"
        external.mkdir()
        clone = self.base / "standalone"
        variables = dict(GIT_OBJECT_DIRECTORY=str(external), GIT_ALTERNATE_OBJECT_DIRECTORIES=str(external),
                         GIT_SHALLOW_FILE=str(self.base / "missing-shallow"), GIT_REPLACE_REF_BASE="refs/synthetic/",
                         GIT_DIR=str(self.source / ".git"), GIT_WORK_TREE=str(self.source),
                         GIT_INDEX_FILE=str(self.base / "foreign-index"))
        with patch.dict(os.environ, dict(self.env, **variables), clear=True):
            portable.git(["clone", "--no-local", str(self.source), str(clone)])
        shutil.rmtree(external)
        self.git("-C", str(clone), "fsck", "--full")
        self.assertEqual(self.git("-C", str(clone), "rev-parse", "HEAD").stdout.strip(), self.revision)

    def test_dangling_configuration_links_never_create_external_files(self):
        directory = self.home / ".codex"
        directory.mkdir()
        missing = self.base / "unavailable/config.toml"
        (directory / "config.toml").symlink_to(missing)
        result = self.install("--persist-agents", ok=False)
        self.assertIn("dangling-configuration-link", result.stderr)
        self.assertFalse(missing.parent.exists())
        self.assertFalse(directory.is_symlink())

    def test_missing_external_agent_root_requires_explicit_resolution(self):
        missing = self.base / "unavailable-agent"
        self.command("install", "--root", str(self.root), "--host", "test-host", "--storage", "os-disk",
                     "--persist-agents", env=dict(self.env, CODEX_HOME=str(missing)), ok=False)
        self.assertFalse(missing.exists())

    def test_deleted_external_agent_configuration_blocks_doctor_and_restore(self):
        external = self.base / "external-agent"
        external.mkdir(mode=0o700)
        self.env["CODEX_HOME"] = str(external)
        self.install()
        shutil.rmtree(external)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("external-agent-configuration-missing", report["issues"])
        self.command("restore", "--host", "test-host", "--root", str(self.root), ok=False)
        self.assertFalse(external.exists())

    def test_launch_arguments_reject_credentials_without_logging_them(self):
        self.install("--codex-args-json", json.dumps(["--api-key", CANARY]), ok=False)
        self.assertFalse((self.root / ".config/workgrove/profile.json").exists())

    def transport(self):
        local = self.base / "mac"
        local.mkdir()
        tools = self.base / "mac-tools"
        tools.mkdir()
        ssh = tools / "ssh"
        ssh.write_text(f'''#!{sys.executable}
import os, subprocess, sys
with open(os.environ["TRANSPORT_LOG"], "a") as stream:
    stream.write(sys.argv[-1] + "\\n")
environment = os.environ.copy()
environment["HOME"] = os.environ["TRANSPORT_HOME"]
environment["CMUX_SSH_ATTEMPT_ID"] = "synthetic-connection"
sys.exit(subprocess.run(["/bin/sh", "-c", sys.argv[-1]], env=environment, check=False).returncode)
''')
        ssh.chmod(0o700)
        uname = tools / "uname"
        uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n")
        uname.chmod(0o700)
        cmux = tools / "cmux"
        cmux.symlink_to(REPO / "test/fakes/cmux")
        state = self.base / "cmux-state"
        subprocess.run([str(self.tools / "bash"), "-c",
                        'source "$1/test/fakes/rows.sh"; fake_cmux_init "$2"',
                        "fake-cmux", str(REPO), str(state)], env=self.env, check=True)
        (state / "mutate").touch()
        tmux = self.tools / "tmux"
        tmux.write_text("#!/bin/sh\ncase \"$1\" in has-session) echo 'no server running on /tmp/synthetic-tmux' >&2; exit 1;; esac\nexit 0\n")
        environment = dict(self.env, HOME=str(local), PATH=str(tools) + ":" + self.env["PATH"],
                           TRANSPORT_HOME=str(self.home), TRANSPORT_LOG=str(self.base / "transport.log"),
                           FAKE_CMUX_STATE=str(state), CMUX_BUNDLED_CLI_PATH=str(cmux))
        return environment

    def remote(self, environment, *args, ok=True, brief=None):
        result = subprocess.run([str(self.tools / "bash"), str(REPO / "bin/wt"), "-H", "test-host", *args],
                                env=environment, input=brief, capture_output=True, text=True, timeout=30)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_remote_setup_and_doctor_work_before_remote_wt_exists(self):
        environment = self.transport()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        mac_before = {str(path.relative_to(environment["HOME"])) for path in Path(environment["HOME"]).rglob("*")}
        missing = self.remote(environment, "repos", ok=False)
        self.assertEqual(missing.returncode, 127)
        self.assertIn("doctor --root <root> --json", missing.stderr)
        self.assertIn("setup --root <root> --restore-only", missing.stderr)
        result = self.remote(environment, "doctor", "--json", ok=False)
        self.assertIn("remote-wt-missing", json.loads(result.stdout)["issues"])
        self.assertIn("wt -H test-host doctor --json; then", missing.stderr)
        self.assertNotIn(str(self.root), missing.stderr)
        self.assertIn("The user must give the root.", result.stderr)
        self.assertIn("A host whose home folder was replaced looks new.", result.stderr)
        self.assertIn("doctor --root <root> --json", result.stderr)
        self.assertIn("setup --root <root> --restore-only", result.stderr)
        mac_after = {str(path.relative_to(environment["HOME"])) for path in Path(environment["HOME"]).rglob("*")}
        self.assertEqual(mac_after, mac_before)
        self.remote(environment, "setup", "--root", str(self.root), "--storage", "os-disk",
                    "--revision", self.revision, "--persist-agents")
        self.assertTrue(json.loads(self.remote(environment, "doctor", "--json").stdout)["ready"])
        shutil.rmtree(self.home)
        self.home.mkdir()
        self.remote(environment, "setup", "--root", str(self.root), "--restore-only")
        self.assertTrue(json.loads(self.remote(environment, "doctor", "--json").stdout)["ready"])
        log = (self.base / "transport.log").read_text()
        self.assertNotIn("just ", log)
        self.assertNotIn("az ", log)
        self.assertNotIn("runpod ", log)

    def test_remote_volume_prompt_and_explicit_flag_use_the_same_acceptance(self):
        self.remote_volume_prompt(tagged=True)

    def test_remote_volume_prompt_accepts_legacy_json_without_spacing_dependency(self):
        self.remote_volume_prompt(tagged=False)

    def test_legacy_volume_prompt_does_not_run_jq(self):
        self.remote_volume_prompt(tagged=False, unavailable_jq=True)

    def remote_volume_prompt(self, tagged, unavailable_jq=False):
        environment = self.transport()
        jq_marker = self.base / "unexpected-jq"
        if unavailable_jq:
            jq = Path(environment["PATH"].split(":")[0]) / "jq"
            jq.write_text("#!/bin/sh\nprintf called >" + shlex.quote(str(jq_marker)) + "\nexit 127\n")
            jq.chmod(0o700)
        marker = self.base / "accepted"
        ssh = Path(environment["PATH"].split(":")[0]) / "ssh"
        request = ("trust-request\t" if tagged else "") + json.dumps(
            {"error": "personal-volume-trust-required", "root": str(self.root), "mount": str(self.root)},
            separators=None if unavailable_jq else (",", ":"))
        ssh.write_text(f'''#!{sys.executable}
import pathlib,sys
sys.stdin.read()
if "--trust-personal-volume" in sys.argv[-1]:
    pathlib.Path({str(marker)!r}).write_text(sys.argv[-1])
    print("synthetic setup accepted")
    sys.exit(0)
print({request!r},file=sys.stderr)
sys.exit(1)
''')
        arguments = ["setup", "--root", str(self.root), "--storage", "volume", "--"]
        refusal = self.remote(environment, *arguments, ok=False)
        self.assertNotIn("[y/N]", refusal.stderr)
        self.assertFalse(marker.exists())
        for answer, accepted in (("\n", False), ("y\n", True)):
            master, slave = pty.openpty()
            process = subprocess.Popen([str(self.tools / "bash"), str(REPO / "bin/wt"), "-H", "test-host", *arguments],
                                       env=environment, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            output = b""
            sent = False
            deadline = time.monotonic() + 15
            try:
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output += chunk
                        if b"[y/N]" in output and not sent:
                            os.write(master, answer.encode())
                            sent = True
                    if process.poll() is not None:
                        break
                self.assertTrue(sent, output.decode(errors="replace"))
                self.assertEqual(process.wait(timeout=2) == 0, accepted, output.decode(errors="replace"))
                self.assertEqual(marker.exists(), accepted)
                if accepted:
                    self.assertIn("--mount", marker.read_text())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
            marker.unlink(missing_ok=True)
        self.remote(environment, *arguments[:-1], "--trust-personal-volume", "--")
        self.assertTrue(marker.exists())
        self.assertFalse(jq_marker.exists())

    def test_hosts_and_environment_doctor_ignore_login_json_module(self):
        self.install("--persist-agents")
        environment = self.transport()
        config = Path(environment["HOME"]) / ".ssh/config"
        config.parent.mkdir()
        config.write_text("Host test-host\n")
        ssh = Path(environment["PATH"].split(":")[0]) / "ssh"
        ssh.write_text(ssh.read_text().replace(
            'env=environment, check=False', 'env=environment, cwd=environment["HOME"], check=False'))
        marker = self.base / "login-module-imported"
        (self.home / "json.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
            "raise RuntimeError('login json imported')\n")
        for arguments in (("hosts", "--json"), ("-H", "test-host", "doctor", "--environment")):
            with self.subTest(arguments=arguments):
                marker.unlink(missing_ok=True)
                result = subprocess.run([str(self.tools / "bash"), str(REPO / "bin/wt"), *arguments],
                                        env=environment, capture_output=True, text=True, timeout=30)
                self.assertFalse(marker.exists(), result.stdout + result.stderr)
                self.assertEqual(result.returncode, 0, result.stderr)
                if arguments[0] == "hosts":
                    self.assertTrue(json.loads(result.stdout)[0]["workgrove_ready"])
                else:
                    self.assertIn("native relay", result.stdout)

    def test_vm_and_container_restart_share_task_recovery_and_row_identity(self):
        self.install("--persist-agents")
        environment = self.transport()
        project = self.root / "project"
        project.mkdir()
        subprocess.run([str(self.tools / "git"), "init", "-q", str(project)], env=self.env, capture_output=True, check=True)
        subprocess.run([str(self.tools / "git"), "-C", str(project), "commit", "--allow-empty", "-qm", "Create synthetic task repository"],
                       env=self.env, capture_output=True, check=True)
        for lifecycle in ("vm-reboot", "container-restart"):
            names = [lifecycle + "-" + agent for agent in ("claude", "codex")]
            brief = "Exact brief with $HOME, 'quotes', and a final newline.\n"
            for name, agent in zip(names, ("claude", "codex")):
                self.remote(environment, "new", name, "-r", str(project), "-a", agent, "-m", "test-model",
                            "--no-workspace", "--prompt-stdin", brief=brief)
                self.assertEqual((project / ".git/wt" / (name + ".prompt")).read_text(), brief)
                (project / ".git/wt" / (name + ".started")).write_text("")
            changed = project / ".worktrees" / names[0] / "kept.txt"
            changed.write_text("Uncommitted task work.\n")
            if lifecycle == "container-restart":
                shutil.rmtree(self.home)
                self.home.mkdir()
                self.remote(environment, "setup", "--root", str(self.root), "--restore-only")
            self.assertTrue(json.loads(self.remote(environment, "doctor", "--json").stdout)["ready"])
            records = json.loads(self.remote(environment, "list", "--json", "-r", str(project)).stdout)
            self.assertTrue(set(names) <= {record["name"] for record in records})
            before = (self.base / "cmux-state/rows.json").read_text() if (self.base / "cmux-state/rows.json").exists() else "[]"
            refusal = self.remote(environment, "attach", names[0], "-r", str(project), ok=False)
            self.assertIn("--restart-agent", refusal.stderr)
            self.assertEqual((self.base / "cmux-state/rows.json").read_text(), before)
            self.remote(environment, "attach", names[0], "-r", str(project), "--restart-agent")
            rows = json.loads((self.base / "cmux-state/rows.json").read_text())["workspaces"]
            self.assertTrue(any(row["title"] == names[0] and row["description"] == "@test-host · project" for row in rows))
            self.assertFalse(any(row["title"] == names[1] for row in rows))
            metadata = json.loads((project / ".git/wt" / (names[0] + ".json")).read_text())
            self.assertEqual(metadata["agent"], "claude")
            self.assertEqual(metadata["model"], "test-model")
            self.assertEqual(changed.read_text(), "Uncommitted task work.\n")
        commands = [line.split() for line in (self.base / "cmux-state/calls.log").read_text().splitlines()]
        ssh_rows = [command for command in commands if command[0] == "ssh"]
        self.assertEqual(len(ssh_rows), 2)
        self.assertTrue(all("--no-focus" in command for command in ssh_rows))


    def test_selected_revision_clone_tracks_upstream_without_running_hooks(self):
        import argparse
        destination = self.base / "new-root"
        destination.mkdir(mode=0o700)
        args = argparse.Namespace(root=str(destination), host="test-host", storage="os-disk", mount=None,
                                  source="https://example.invalid/public/workgrove", revision=self.revision,
                                  git_identity=None, persist_agents=False, with_tmux_conf=False,
                                  claude_args_json=None, codex_args_json=None, restore_only=False)
        hook_dir = self.home / "custom-hooks"
        hook_dir.mkdir()
        marker = self.base / "unexpected-hook"
        hook = hook_dir / "post-checkout"
        hook.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
        hook.chmod(0o700)
        with (self.home / ".gitconfig").open("a") as stream:
            stream.write("[core]\n hooksPath = " + str(hook_dir) + "\n")
        original = portable.git
        calls = []
        def local_git(arguments, source=None, allowed=(0,)):
            calls.append(arguments)
            if arguments[0] == "clone":
                arguments = [*arguments[:-2], str(self.source), arguments[-1]]
            return original(arguments, source, allowed)
        with patch.dict(os.environ, self.env, clear=True), patch.object(portable, "packages"), \
                patch.object(portable, "git", side_effect=local_git), patch.object(portable.os, "execv") as execute:
            portable.bootstrap(args)
        source = destination / "workgrove"
        self.assertTrue((source / ".git").is_dir())
        self.assertFalse(marker.exists())
        result = subprocess.run([str(self.tools / "git"), "-C", str(source), "rev-parse", "--abbrev-ref", "@{u}"],
                                env=self.env, text=True, capture_output=True, check=True)
        self.assertTrue(result.stdout.strip().startswith("origin/"))
        self.assertEqual(execute.call_args.args[1][:3], [sys.executable, "-I", "-B"])
        self.assertIn(str(source / "lib/workgrove/portable.py"), execute.call_args.args[1])
        self.assertTrue(any(command[0] == "checkout" and self.revision in command for command in calls))

    def test_package_adapter_refuses_unsupported_systems_and_missing_privilege(self):
        with patch.object(portable.shutil, "which", return_value=None), \
                patch.object(portable, "supported_os", return_value=False), patch.object(portable, "run") as command:
            with self.assertRaisesRegex(portable.Refusal, "unsupported-package-adapter"):
                portable.packages()
            command.assert_not_called()
        with patch.object(portable.shutil, "which", return_value=None), \
                patch.object(portable, "supported_os", return_value=True), \
                patch.object(portable.os, "geteuid", return_value=1000), patch.object(portable, "run") as command:
            with self.assertRaisesRegex(portable.Refusal, "privilege-required"):
                portable.packages()
            command.assert_not_called()

    def test_profile_arguments_preserve_elements_and_task_models_for_both_agents(self):
        self.install("--persist-agents", "--claude-args-json", '["--model","profile-model","--test-option","a value"]',
                     "--codex-args-json", '["--model","profile-model","--test-option","a value"]')
        project = self.root / "agent-project"
        project.mkdir()
        subprocess.run([str(self.tools / "git"), "init", "-q", str(project)], env=self.env, capture_output=True, check=True)
        subprocess.run([str(self.tools / "git"), "-C", str(project), "commit", "--allow-empty", "-qm", "Create agent fixture"],
                       env=self.env, capture_output=True, check=True)
        environment = self.transport()
        for agent in ("claude", "codex"):
            self.remote(environment, "new", "agent-" + agent, "-r", str(project), "-a", agent, "-m", "task-model",
                        "--no-workspace", "-p", "Saved brief.")
            tool = self.tools / agent
            capture = self.base / (agent + "-arguments.json")
            tool.write_text(f'#!{sys.executable}\nimport json, pathlib, sys\npathlib.Path({str(capture)!r}).write_text(json.dumps(sys.argv[1:]))\n')
            tool.chmod(0o700)
            result = subprocess.run([str(self.tools / "bash"), str(self.home / ".local/bin/wt"), "run", "agent-" + agent,
                                     "-r", str(project)], env=dict(self.env, CMUX_SSH_ATTEMPT_ID="fixture"),
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            arguments = json.loads(capture.read_text())
            self.assertIn("task-model", arguments)
            self.assertNotIn("profile-model", arguments)
            self.assertEqual(arguments[arguments.index("--test-option") + 1], "a value")
            self.assertEqual(arguments[-1], "Saved brief.")

    def test_missing_remote_python_reports_explicit_repair_without_installing(self):
        self.install("--persist-agents")
        environment = self.transport()
        empty = self.base / "no-python"
        empty.mkdir()
        # SSH's interpreter is absolute. Only the simulated remote command gets this restricted PATH.
        remote_ssh = Path(environment["PATH"].split(":")[0]) / "ssh"
        text = remote_ssh.read_text().replace('environment["CMUX_SSH_ATTEMPT_ID"] = "synthetic-connection"',
                                             'environment["PATH"] = ' + repr(str(empty)))
        remote_ssh.write_text(text)
        result = self.remote(environment, "doctor", "--json", ok=False)
        self.assertIn("missing-prerequisites", json.loads(result.stdout)["issues"])
        self.assertNotIn("missing-python", json.loads(result.stdout)["issues"])
        # The system Python fallback can remain usable even when PATH no longer names Python.
        result = self.remote(environment, "setup", "--root", str(self.root), "--restore-only")
        self.assertIn("restored", result.stdout)
        client = self.base / "client"
        shutil.copytree(REPO / "bin", client / "bin")
        shutil.copytree(REPO / "lib", client / "lib")
        runtime = client / "lib/workgrove/vm/python-runtime.sh"
        runtime.write_text(runtime.read_text().replace("/usr/bin/python3", str(self.base / "missing-system-python")))
        result = subprocess.run([str(self.tools / "bash"), str(client / "bin/wt"), "-H", "test-host", "setup",
                                 "--root", str(self.root), "--restore-only"], env=environment,
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Python 3 is missing", result.stderr)
        self.assertTrue((self.root / ".config/workgrove/profile.json").exists())

    def missing_python_setup(self):
        environment = self.transport()
        tools = self.base / "bootstrap-tools"
        tools.mkdir()
        packages = self.base / "package-calls"
        mounts = self.base / "mount-calls"
        (tools / "env").symlink_to(shutil.which("env"))
        for name, script in {
            "id": "printf '0\\n'",
            "apt-get": f'printf "%s\\n" "$*" >>{str(packages)!r}\nexit 1',
            "mountpoint": f'printf "%s\\n" "$3" >>{str(mounts)!r}\n[ "$3" = "$TEST_MOUNT" ]',
        }.items():
            command = tools / name
            command.write_text("#!/bin/sh\n" + script + "\n")
            command.chmod(0o700)
        remote_ssh = Path(environment["PATH"].split(":")[0]) / "ssh"
        remote_ssh.write_text(remote_ssh.read_text().replace(
            'environment["CMUX_SSH_ATTEMPT_ID"] = "synthetic-connection"',
            'environment["PATH"] = ' + repr(str(tools))))
        client = self.base / "bootstrap-client"
        shutil.copytree(REPO / "bin", client / "bin")
        shutil.copytree(REPO / "lib", client / "lib")
        runtime = client / "lib/workgrove/vm/python-runtime.sh"
        runtime.write_text(runtime.read_text().replace("/usr/bin/python3", str(self.base / "missing-system-python")))
        release = self.base / "os-release"
        release.write_text("ID=ubuntu\nVERSION_ID=24.04\n")
        setup = client / "lib/workgrove/setup.sh"
        setup.write_text(setup.read_text().replace(". /etc/os-release", '. "$TEST_OS_RELEASE"'))
        environment.update(TEST_OS_RELEASE=str(release), TEST_MOUNT=str(self.base))

        def run(*args):
            result = subprocess.run([str(self.tools / "bash"), str(client / "bin/wt"), "-H", "test-host", "setup",
                                     "--root", str(self.root), *args], env=environment,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual(result.stdout, "")
            return result.stderr
        return run, environment, packages, mounts

    def test_missing_python_saved_volume_requires_storage_and_parent_mount(self):
        self.install()
        profile = self.root / ".config/workgrove/profile.json"
        saved = self.profile()
        saved.update(storage="volume", mount=str(self.base))
        profile.write_text(json.dumps(saved))
        before = profile.read_bytes()
        run, environment, packages, mounts = self.missing_python_setup()
        self.assertEqual(run(), "workgrove: Python 3 is missing; pass --storage volume --mount <mount>, "
                         "or --storage os-disk, to use the saved root\n")
        self.assertFalse(mounts.exists())
        self.assertFalse(packages.exists())
        self.assertEqual(run("--storage", "volume"), "workgrove: Python 3 is missing; pass --mount <mount> "
                         "with --storage volume when the root is below the mount\n")
        self.assertFalse(packages.exists())
        self.assertEqual(run("--storage", "volume", "--mount", str(self.base)), "workgrove: Python-install-failed\n")
        self.assertEqual(packages.read_text(), "update\n")
        packages.unlink()
        environment["TEST_MOUNT"] = str(self.root)
        self.assertEqual(run("--storage", "volume"), "workgrove: Python-install-failed\n")
        self.assertEqual(packages.read_text(), "update\n")
        self.assertEqual(profile.read_bytes(), before)

    def test_missing_python_saved_os_disk_requires_storage(self):
        self.install()
        profile = self.root / ".config/workgrove/profile.json"
        before = profile.read_bytes()
        run, _, packages, mounts = self.missing_python_setup()
        self.assertIn("pass --storage volume --mount <mount>, or --storage os-disk", run())
        self.assertFalse(packages.exists())
        self.assertFalse(mounts.exists())
        self.assertEqual(run("--storage", "os-disk"), "workgrove: Python-install-failed\n")
        self.assertEqual(packages.read_text(), "update\n")
        self.assertFalse(mounts.exists())
        self.assertEqual(profile.read_bytes(), before)

    def test_missing_python_without_profile_keeps_storage_checks(self):
        run, environment, packages, mounts = self.missing_python_setup()
        self.assertEqual(run(), "workgrove: persistent-mount-missing\n")
        self.assertEqual(mounts.read_text(), str(self.root) + "\n")
        self.assertFalse(packages.exists())
        environment["TEST_MOUNT"] = str(self.root)
        self.assertEqual(run(), "workgrove: Python-install-failed\n")
        self.assertEqual(packages.read_text(), "update\n")
        packages.unlink()
        self.assertEqual(run("--storage", "os-disk"), "workgrove: Python-install-failed\n")
        self.assertEqual(packages.read_text(), "update\n")

    def test_remote_runtime_fallback_and_unavailable_portable_preflight(self):
        self.install("--persist-agents")
        environment = self.transport()
        old = self.tools / "python3"
        old.unlink()
        old.write_text("#!/bin/sh\nexit 1\n")
        old.chmod(0o700)
        client = self.base / "client"
        shutil.copytree(REPO / "bin", client / "bin")
        shutil.copytree(REPO / "lib", client / "lib")
        runtime = client / "lib/workgrove/vm/python-runtime.sh"
        original = runtime.read_text()
        runtime.write_text(original.replace("/usr/bin/python3", sys.executable))
        def client_command(*args):
            return subprocess.run([str(self.tools / "bash"), str(client / "bin/wt"), "-H", "test-host", *args],
                                  env=environment, capture_output=True, text=True, timeout=30)
        def inventory():
            source = subprocess.run([str(self.tools / "bash"), "-c",
                                     'WG_LIB_DIR="$1/lib/workgrove"; source "$WG_LIB_DIR/hosts.sh"; host_probe_source',
                                     "fixture", str(client)], env=self.env, capture_output=True, text=True, check=True).stdout
            result = subprocess.run(["/bin/sh", "-s"], input=source, env=self.env,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            return {key: json.loads(value) for key, value in (line.split("\t", 1) for line in result.stdout.splitlines() if "\t" in line)
                    if key in {"capabilities", "readiness"}}
        result = client_command("doctor", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["ready"])
        direct = subprocess.run([str(self.tools / "bash"), str(client / "bin/wt"), "doctor", "--json"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(direct.returncode, 0, direct.stderr)
        self.assertTrue(json.loads(direct.stdout)["ready"])
        self.assertTrue(inventory()["readiness"]["ready"])
        result = client_command("setup", "--root", str(self.root), "--restore-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        runtime.write_text(original.replace("/usr/bin/python3", str(self.base / "missing-system-python")))
        result = client_command("doctor", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["issues"], ["python-3.9-required"])
        direct = subprocess.run([str(self.tools / "bash"), str(client / "bin/wt"), "doctor", "--json"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(direct.returncode, 0)
        self.assertEqual(json.loads(direct.stdout)["issues"], ["python-3.9-required"])
        report = inventory()
        self.assertEqual(report["readiness"]["issues"], ["python-3.9-required"])
        self.assertEqual(report["capabilities"]["capacity_issues"], ["python-3.9-required"])
        result = client_command("new", "not-created", "-r", str(self.source), "--no-workspace", "-a", "none")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python-3.9-required", result.stderr)
        self.assertFalse((self.source / ".worktrees/not-created").exists())

    def test_runtime_preserves_legacy_preflight_without_python(self):
        runtime = (REPO / "lib/workgrove/vm/python-runtime.sh").read_text()
        runtime = runtime.replace("/usr/bin/python3", str(self.base / "missing-system-python"))
        empty = self.base / "empty"
        empty.mkdir()
        environment = dict(self.env, PATH=str(empty))
        script = runtime + '\nwg_select_python && exit 2\nwg_has_portable_profile && exit 3\nexit 0\n'
        result = subprocess.run(["/bin/sh", "-c", script], env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.install("--persist-agents")
        script = runtime + '\nwg_select_python && exit 2\nwg_has_portable_profile || exit 3\nexit 0\n'
        result = subprocess.run(["/bin/sh", "-c", script], env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("profile.json", "env.sh"):
            (self.home / ".config/workgrove" / name).unlink()
        result = subprocess.run(["/bin/sh", "-c", script], env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_incomplete_portable_profile_blocks_new_tasks_without_repair(self):
        self.install("--persist-agents")
        environment = self.transport()
        (self.home / ".config/workgrove/env.sh").unlink()
        result = self.remote(environment, "new", "not-created", "-r", "missing-project", "--no-workspace", ok=False)
        self.assertIn("setup --root", result.stderr)
        self.assertFalse((self.root / "missing-project").exists())
        self.assertFalse((self.home / ".config/workgrove/env.sh").exists())



if __name__ == "__main__":
    unittest.main()
