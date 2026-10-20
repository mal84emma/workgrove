"""Exercise portable setup and home replacement with synthetic personal data."""

import importlib.util
import io
import json
import os
import pty
import select
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("portable", REPO / "lib/workgrove/portable.py")
portable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portable)
CANARY = "SYNTHETIC-CONFIDENTIAL-CANARY"


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
        request = json.loads(result.stderr.splitlines()[0])
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
        self.volume_command("restore", "--root", str(self.root))
        self.assertTrue((self.home / ".local/bin/wt").is_symlink())
        self.assertTrue(self.profile()["trust_personal_volume"])
        self.assertTrue(json.loads(self.volume_command("doctor", "--json").stdout)["ready"])
        result = self.volume_command("restore", "--root", str(self.root), mounts=[], ok=False)
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
        self.assertIn("shared-configuration-parent", report["issues"])
        self.assertEqual(report["storage_permission_policy"], "trusted-personal-volume")

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
        result = self.volume_command("restore", "--root", str(self.root), "--trust-personal-volume", ok=False)
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
        self.command("restore", "--root", str(self.root), env=env)
        self.assertEqual((self.home / ".local/bin/wt").readlink(), self.source / "bin/wt")
        self.assertTrue((self.home / ".tmux.conf").is_symlink())
        self.assertEqual(task.read_text(), CANARY)
        result = self.command("doctor", "--root", str(self.root), "--json", env=env, ok=False)
        self.assertIn("missing-prerequisites", json.loads(result.stdout)["issues"])
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

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
        self.command("restore", "--root", str(self.root), ok=False)
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

    def test_restore_detects_replaced_installation(self):
        self.install()
        (self.source / "bin/wt").write_text("#!/bin/sh\nexit 0\n")
        self.assertIn("installation-changed", self.command("restore", "--root", str(self.root), ok=False).stderr)

    def test_plain_installer_rerun_keeps_portable_profile(self):
        self.install("--persist-agents", "--with-tmux-conf")
        result = subprocess.run([str(self.tools / "bash"), str(self.source / "install.sh")], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.profile()["tmux"])
        self.assertEqual(self.profile()["root"], str(self.root))

    def test_bootstrap_uses_selected_installation_without_changing_git(self):
        result = self.command("bootstrap", "--root", str(self.root), "--host", "test-host", "--storage", "os-disk",
                              "--revision", self.revision)
        self.assertIn("installed", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.revision)
        self.command("bootstrap", "--root", str(self.root), "--revision", "0" * 40, ok=False)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.revision)

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
        self.command("restore", "--root", str(self.root))
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
        self.command("install", "--root", str(self.root), ok=False)
        self.assertFalse(target.exists())

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
        cmux.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
args = sys.argv[1:]
path = pathlib.Path(os.environ["TRANSPORT_ROWS"])
rows = json.loads(path.read_text()) if path.exists() else []
with open(os.environ["TRANSPORT_CMUX_LOG"], "a") as stream:
    stream.write(json.dumps(args) + "\\n")
if args[0] == "--json":
    print('[{{"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}}]')
elif args[:2] == ["workspace", "list"]:
    print(json.dumps({{"workspaces":rows}}))
elif args[:2] == ["workspace", "close"]:
    rows = [row for row in rows if row["id"] != args[2]]
elif args[0] == "ssh":
    identity = "workspace:" + str(len(rows) + 1)
    rows.append({{"id":identity, "title":args[args.index("--name") + 1],
                 "description":"", "remote":{{"enabled":True,"destination":args[1],"state":"connected"}}}})
    print(identity)
elif args[0] == "workspace-action" and "--description" in args:
    for row in rows:
        if row["id"] == args[args.index("--workspace") + 1]:
            row["description"] = args[args.index("--description") + 1]
path.write_text(json.dumps(rows))
''')
        cmux.chmod(0o700)
        tmux = self.tools / "tmux"
        tmux.write_text("#!/bin/sh\ncase \"$1\" in has-session) echo 'no server running on /tmp/synthetic-tmux' >&2; exit 1;; esac\nexit 0\n")
        environment = dict(self.env, HOME=str(local), PATH=str(tools) + ":" + self.env["PATH"],
                           TRANSPORT_HOME=str(self.home), TRANSPORT_LOG=str(self.base / "transport.log"),
                           TRANSPORT_ROWS=str(self.base / "rows.json"), TRANSPORT_CMUX_LOG=str(self.base / "cmux.log"))
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
        missing = self.remote(environment, "repos", ok=False)
        self.assertIn("setup --root", missing.stderr)
        result = self.remote(environment, "doctor", "--json", ok=False)
        self.assertIn("remote-wt-missing", json.loads(result.stdout)["issues"])
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
        environment = self.transport()
        marker = self.base / "accepted"
        ssh = Path(environment["PATH"].split(":")[0]) / "ssh"
        request = json.dumps({"error": "personal-volume-trust-required", "root": str(self.root), "mount": str(self.root)})
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
            before = (self.base / "rows.json").read_text() if (self.base / "rows.json").exists() else "[]"
            refusal = self.remote(environment, "attach", names[0], "-r", str(project), ok=False)
            self.assertIn("--restart-agent", refusal.stderr)
            self.assertEqual((self.base / "rows.json").read_text(), before)
            self.remote(environment, "attach", names[0], "-r", str(project), "--restart-agent")
            rows = json.loads((self.base / "rows.json").read_text())
            self.assertTrue(any(row["title"] == names[0] and row["description"] == "@test-host · project" for row in rows))
            self.assertFalse(any(row["title"] == names[1] for row in rows))
            metadata = json.loads((project / ".git/wt" / (names[0] + ".json")).read_text())
            self.assertEqual(metadata["agent"], "claude")
            self.assertEqual(metadata["model"], "test-model")
            self.assertEqual(changed.read_text(), "Uncommitted task work.\n")
        commands = [json.loads(line) for line in (self.base / "cmux.log").read_text().splitlines()]
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
        self.assertIn("missing-python", json.loads(result.stdout)["issues"])
        # The system Python fallback can remain usable even when PATH no longer names Python.
        result = self.remote(environment, "setup", "--root", str(self.root), "--restore-only")
        self.assertIn("restored", result.stdout)
        client = self.base / "client"
        shutil.copytree(REPO / "bin", client / "bin")
        shutil.copytree(REPO / "lib", client / "lib")
        setup = client / "lib/workgrove/setup.sh"
        setup.write_text(setup.read_text().replace("/usr/bin/python3", str(self.base / "missing-system-python")))
        result = subprocess.run([str(self.tools / "bash"), str(client / "bin/wt"), "-H", "test-host", "setup",
                                 "--root", str(self.root), "--restore-only"], env=environment,
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Python 3 is missing", result.stderr)
        self.assertTrue((self.root / ".config/workgrove/profile.json").exists())

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
