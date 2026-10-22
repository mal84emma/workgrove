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
        self.command("restore", "--root", str(self.root), env=dict(self.env, PATH=str(self.base / "no-tools")))
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
        self.command("restore", "--root", str(self.root))
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
                self.command("restore", "--root", str(self.root), ok=False,
                             env=dict(self.env, PATH=str(self.base / "no-tools")))
                self.assertIn("installation-has-local-edits", self.install(ok=False).stderr)
                path.write_bytes(before)
        path = self.source / "lib/workgrove/remote.sh"
        path.write_text(path.read_text() + "\n# Updated public runtime.\n")
        self.git("add", str(path))
        self.git("commit", "-qm", "Update synthetic runtime")
        self.install()
        self.command("restore", "--root", str(self.root))
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
        self.command("restore", "--root", str(self.root), ok=False)
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
        self.assertIn("profile-upgrade-run-full-setup", self.command("restore", "--root", str(self.root), ok=False).stderr)
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("profile-upgrade-run-full-setup", report["issues"])
        (self.home / ".claude.json").write_text("stranded global state")
        self.install()
        self.assertEqual(self.profile()["schema"], 2)
        self.assertEqual(self.claude_lookup()[1], "stranded global state")
        self.command("restore", "--root", str(self.root))

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
                self.assertIn("shared-configuration-target", self.command("restore", "--root", str(self.root), ok=False).stderr)
                self.assertIn("shared-configuration-target", self.install(ok=False).stderr)
                path.chmod(0o600)
        self.assertTrue(json.loads(self.command("doctor", "--json").stdout)["ready"])

    def test_mutable_configuration_links_and_hardlinks_fail_every_entry_point(self):
        self.install("--persist-agents")
        codex = Path(self.profile()["agent_roots"]["codex"])
        path = codex / "config.toml"
        path.unlink()
        path.symlink_to(self.source / "home/.codex/config.base.toml")
        for command in (("doctor", "--json"), ("restore", "--root", str(self.root)),
                        ("install", "--root", str(self.root))):
            result = self.command(*command, ok=False)
            self.assertIn("repository-destination", result.stdout + result.stderr)
        path.unlink()
        path.write_text("custom = true\n")
        original = self.base / "authentication"
        original.write_text(CANARY)
        os.link(original, codex / "auth.json")
        for command in (("doctor", "--json"), ("restore", "--root", str(self.root)),
                        ("install", "--root", str(self.root))):
            result = self.command(*command, ok=False)
            self.assertIn("hardlinked-file", result.stdout + result.stderr)

    def test_trusted_volume_does_not_require_exact_runtime_mode_bits(self):
        self.volume_install("--persist-agents", "--trust-personal-volume")
        for path in (self.source / "lib/workgrove/remote.sh",
                     Path(self.profile()["agent_roots"]["codex"]) / "config.toml"):
            path.chmod(0o666)
        self.assertTrue(json.loads(self.volume_command("doctor", "--json").stdout)["ready"])
        self.volume_command("restore", "--root", str(self.root))
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
        self.command("restore", "--root", str(self.root))
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
        self.command("restore", "--root", str(self.root))
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
        self.command("restore", "--root", str(self.root), ok=False)
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
        report = json.loads(self.command("doctor", "--json", ok=False).stdout)
        self.assertIn("persistent-agent-configuration-missing", report["issues"])
        self.command("doctor", "--preflight", ok=False)
        self.command("restore", "--root", str(self.root), ok=False)
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
        self.command("restore", "--root", str(self.root), ok=False)
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
