"""Exercise SSH registration with synthetic files and no network connections."""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
import unittest

REPO = Path(__file__).resolve().parents[1]
REAL_SSH = shutil.which("ssh")
CANARY = "SYNTHETIC-CONFIDENTIAL-CANARY"


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ssh-host-", dir=os.environ.get("TEST_ROOT"))
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.config = self.home / ".ssh/config"
        self.fragment = self.root / "connection.conf"
        self.fragment.write_text("HostName example.invalid\nPort 2222\nUser worker\nHostKeyAlias opaque-test-key\n")
        self.tools = self.root / "bin"
        self.tools.mkdir()
        self.log = self.root / "ssh.log"
        self.status = self.root / "status"
        self.status.write_text("0")
        ssh = self.tools / "ssh"
        ssh.write_text(f'''#!{sys.executable}
import json, os, pathlib, subprocess, sys, tempfile
with open(os.environ["SSH_TEST_LOG"], "a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
if "-G" in sys.argv[1:]:
    if "-F" not in sys.argv[1:]:
        config = pathlib.Path(os.environ["HOME"]) / ".ssh/config"
        text = config.read_text() if config.exists() else ""
        text += "\\nHost *\\n" + os.environ.get("SSH_TEST_SYSTEM", "")
        with tempfile.NamedTemporaryFile(mode="w") as stream:
            stream.write(text)
            stream.flush()
            result = subprocess.run([{REAL_SSH!r}, "-F", stream.name, *sys.argv[1:]], check=False)
        if os.environ.get("SSH_TEST_MUTATION"):
            config.write_text(os.environ["SSH_TEST_MUTATION"])
        sys.exit(result.returncode)
    sys.exit(subprocess.run([{REAL_SSH!r}, *sys.argv[1:]], check=False).returncode)
print({CANARY!r}, file=sys.stderr)
sys.exit(int(open(os.environ["SSH_TEST_STATUS"]).read()))
''')
        ssh.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.tools) + ":" + os.environ["PATH"],
                        SSH_TEST_LOG=str(self.log), SSH_TEST_STATUS=str(self.status))
        self.env.pop("WORKGROVE_REEXEC", None)

    def run_helper(self, *args, ok=True):
        result = subprocess.run([str(REPO / "bin/wt-ssh-host"), "-F", str(self.config), *args],
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=30)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def add(self, ok=True):
        return self.run_helper("add", "test-host", "--fragment", str(self.fragment), ok=ok)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def existing(self, text):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(text)
        self.config.chmod(0o644)

    def test_add_list_remove_preserve_unrelated_bytes_and_modes(self):
        original = "# Personal configuration.\r\nHost another-host\r\n    HostName other.invalid"
        self.existing(original)
        self.add()
        self.assertTrue(self.config.read_bytes().endswith(original.encode()))
        self.assertEqual(self.config.with_name("config.bak").read_bytes(), original.encode())
        for path in (self.config, self.config.with_name("config.bak")):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        discovery = subprocess.run([os.environ["BASH"], "-c", 'source "$1/lib/workgrove/common.sh"; ssh_hosts',
                                    "test", str(REPO)], env=self.env, capture_output=True, text=True, check=True)
        self.assertIn("test-host", discovery.stdout.splitlines())
        calls = self.calls()
        self.assertEqual(sum("-G" in call for call in calls), 2)
        self.assertIn("StrictHostKeyChecking=yes", calls[-1])
        self.assertIn("BatchMode=yes", calls[-1])
        before = len(calls)
        rows = json.loads(self.run_helper("list", "--json").stdout)
        self.assertEqual(rows, [{"alias": "test-host", "fragment": str(self.fragment), "status": "configured"}])
        self.assertEqual(len(self.calls()), before)
        self.run_helper("rm", "test-host")
        self.assertEqual(self.config.read_bytes(), original.encode())
        self.assertTrue(self.fragment.exists())

    def test_new_directory_and_config_are_private(self):
        self.add()
        self.assertEqual(stat.S_IMODE(self.config.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertFalse(self.config.with_name("config.bak").exists())
        self.assertFalse(list(self.config.parent.glob(".wt-ssh-host-*-*")))

    def test_idempotency_endpoint_refresh_and_identity_pin(self):
        self.add()
        original = self.config.read_bytes()
        self.add()
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse(self.config.with_name("config.bak").exists())
        replacement = self.root / "replacement"
        replacement.write_text(self.fragment.read_text().replace("2222", "3333"))
        replacement.replace(self.fragment)
        self.add()
        self.fragment.write_text(self.fragment.read_text().replace("opaque-test-key", "different-key"))
        result = self.add(ok=False)
        self.assertIn("identity-change-requires-registration-removal", result.stderr)
        self.assertEqual(self.config.read_bytes(), original)
        before = len(self.calls())
        self.assertEqual(json.loads(self.run_helper("list", "--json").stdout)[0]["status"], "identity-changed")
        self.assertEqual(len(self.calls()), before)
        self.run_helper("rm", "test-host")
        self.add()
        self.assertIn("HostKeyAlias different-key", self.config.read_text())

    def test_preexisting_global_settings_keep_their_scope(self):
        self.existing("User global-user\nServerAliveInterval 37\nHost another-host\n    HostName other.invalid\n")
        before = subprocess.run([str(self.tools / "ssh"), "-G", "-F", str(self.config), "another-host"],
                                env=self.env, capture_output=True, check=True).stdout
        self.add()
        after = subprocess.run([str(self.tools / "ssh"), "-G", "-F", str(self.config), "another-host"],
                               env=self.env, capture_output=True, check=True).stdout
        self.assertEqual(before, after)
        self.assertIn(b"user global-user", after)
        self.assertIn(b"serveraliveinterval 37", after)

    def test_absent_identity_pin_cannot_be_added_silently(self):
        self.fragment.write_text("HostName example.invalid\n")
        self.add()
        self.fragment.write_text("HostName example.invalid\nHostKeyAlias different-key\n")
        self.add(ok=False)

    def test_rejected_fragments_never_invoke_ssh(self):
        for directive in (
            "Host *", "Match exec touch-canary", "Include other", "ProxyCommand command-canary",
            "LocalCommand command-canary", "KnownHostsCommand command-canary", "UnknownKeyword value",
            "HostName another.invalid", "User worker\nuser somebody", "Port 0", "Port 65536",
            "StrictHostKeyChecking accept-new", "IdentityFile ~/.ssh/%h", "IdentityFile ${HOME}/key",
            "IdentityFile /keys/*", "IdentityFile relative/key", "User a b", 'User "unterminated',
            "User `canary`", "HostKeyAlias %h",
        ):
            with self.subTest(directive=directive):
                self.fragment.write_text("HostName example.invalid\n" + directive + "\n")
                self.add(ok=False)
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.config.exists())

    def test_quoted_paths_spaces_percent_and_equals(self):
        self.fragment = self.root / "supplier % data" / "connection.conf"
        self.fragment.parent.mkdir()
        key = self.root / "identity % key"
        trust = self.root / "trusted % hosts"
        key.write_text(CANARY)
        trust.write_text(CANARY)
        self.fragment.write_text(
            f'HostName=example.invalid\nPort = 2222\nUser worker\n'
            f'IdentityFile "{str(key).replace("%", "%%")}"\n'
            f'UserKnownHostsFile "{str(trust).replace("%", "%%")}"\n'
            'IdentitiesOnly yes\nHashKnownHosts no\nStrictHostKeyChecking yes\n'
            'HostKeyAlgorithms ssh-ed25519\nServerAliveInterval 15\n')
        self.add()
        self.assertEqual(key.read_text(), CANARY)
        self.assertEqual(trust.read_text(), CANARY)
        self.assertEqual(json.loads(self.run_helper("list", "--json").stdout)[0]["fragment"], str(self.fragment))

    def test_existing_wildcards_preserve_matching_policy_or_refuse(self):
        self.existing("Host *\n    User unexpected\n    Port 9000\n")
        self.add()
        self.run_helper("rm", "test-host")
        original = "Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n"
        self.existing(original)
        backup_before = self.config.with_name("config.bak").read_bytes()
        result = self.add(ok=False)
        self.assertIn("effective-config-conflict", result.stderr)
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(self.config.with_name("config.bak").read_bytes(), backup_before)
        self.assertTrue(all("-G" in call for call in self.calls()[-2:]))

    def test_inherited_identity_and_trust_policy_conflicts(self):
        self.fragment.write_text(self.fragment.read_text() + "IdentityFile /supplier/key\nIdentitiesOnly yes\n")
        for policy in ("IdentityFile /different/key", "CertificateFile /different/cert.pub",
                       "KnownHostsCommand echo-secret", "VerifyHostKeyDNS yes",
                       "GlobalKnownHostsFile /dev/null", "UpdateHostKeys no"):
            with self.subTest(policy=policy):
                original = "Host *\n    " + policy + "\n"
                self.existing(original)
                before = len(self.calls())
                self.assertIn("effective-config-conflict", self.add(ok=False).stderr)
                self.assertEqual(self.config.read_text(), original)
                self.assertTrue(all("-G" in call for call in self.calls()[before:]))

    def test_check_rejects_inherited_certificate_without_connecting(self):
        self.fragment.write_text(self.fragment.read_text() + "IdentityFile /supplier/key\nIdentitiesOnly yes\n")
        self.add()
        with self.config.open("a") as stream:
            stream.write("Host *\n    CertificateFile /different/cert.pub\n")
        original = self.config.read_bytes()
        before = len(self.calls())
        result = self.run_helper("check", "test-host", ok=False)
        self.assertIn("effective-config-conflict", result.stderr)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertTrue(all("-G" in call for call in self.calls()[before:]))

    def test_unmanaged_alias_and_broken_markers_leave_config_unchanged(self):
        for original in (
            "Host test-host\n    HostName example.invalid\n",
            "Host=another-host test-host\n    HostName example.invalid\n",
            "Match host test-host\n    User worker\n",
            "# >>> wt-ssh-host test-host\nHost test-host\n",
            "# <<< wt-ssh-host test-host\n",
            "# >>> wt-ssh-host test-host\n# <<< wt-ssh-host test-host\n",
            "# >>> wt-ssh-host test-host\nHost test-host\n    StrictHostKeyChecking yes\n"
            "    HostKeyAlias \n    Include /tmp/example.conf\nHost *\n# <<< wt-ssh-host test-host\n",
        ):
            with self.subTest(original=original):
                self.existing(original)
                self.add(ok=False)
                self.assertEqual(self.config.read_text(), original)
                self.assertEqual(self.calls(), [])

    def test_fragment_health_and_removal_do_not_connect(self):
        self.add()
        self.fragment.write_text("HostName example.invalid\nMatch exec command-canary\n")
        self.assertEqual(json.loads(self.run_helper("list", "--json").stdout)[0]["status"], "invalid")
        self.fragment.unlink()
        before = len(self.calls())
        self.assertEqual(json.loads(self.run_helper("list", "--json").stdout)[0]["status"], "missing")
        self.run_helper("rm", "test-host")
        self.assertEqual(len(self.calls()), before)

    def test_openssh_configuration_errors_do_not_echo_values(self):
        self.fragment.write_text("HostName example.invalid\nHostKeyAlgorithms " + CANARY + "\n")
        result = self.add(ok=False)
        self.assertIn("effective-config-unavailable", result.stderr)
        self.assertFalse(self.config.exists())
        self.assertTrue(all("-G" in call for call in self.calls()))

    def test_failed_verification_retains_registration_without_diagnostics(self):
        self.status.write_text("255")
        missing_trust = self.root / "missing-trust"
        self.fragment.write_text(self.fragment.read_text() + f"UserKnownHostsFile {missing_trust}\n")
        result = self.add(ok=False)
        self.assertFalse(missing_trust.exists())
        self.assertIn("registered-but-unavailable", result.stderr)
        self.assertTrue(self.config.exists())
        self.assertEqual(json.loads(self.run_helper("list", "--json").stdout)[0]["status"], "configured")

    def test_repository_boundaries_and_symlinked_parents(self):
        repository = self.root / "repository"
        repository.mkdir()
        subprocess.run(["git", "init", "-q", str(repository)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        link = self.root / "linked-parent"
        link.symlink_to(repository, target_is_directory=True)
        for config in (repository / "config", repository / ".git/config", link / "nested/config"):
            with self.subTest(config=str(config)):
                self.config = config
                before = config.read_bytes() if config.exists() else None
                self.assertIn("repository-destination", self.add(ok=False).stderr)
                self.assertEqual(config.read_bytes() if config.exists() else None, before)
        self.assertEqual(self.calls(), [])

    def test_bare_repository_destination_is_rejected(self):
        repository = self.root / "bare"
        subprocess.run(["git", "init", "-q", "--bare", str(repository)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.config = repository / "new/config"
        self.assertIn("repository-destination", self.add(ok=False).stderr)
        self.assertFalse(self.config.exists())

    def test_fragment_inside_repository_is_a_permitted_read_only_reference(self):
        repository = self.root / "supplier-checkout"
        repository.mkdir()
        (repository / ".git").mkdir()
        self.fragment = repository / "connection.conf"
        self.fragment.write_text("HostName example.invalid\n")
        before = self.fragment.read_bytes()
        self.add()
        self.assertEqual(self.fragment.read_bytes(), before)

    def test_existing_config_link_is_preserved_outside_repositories(self):
        self.config.parent.mkdir()
        target = self.root / "user-config"
        target.write_text("# Preserve this.\n")
        self.config.symlink_to(target)
        self.add()
        self.assertTrue(self.config.is_symlink())
        self.assertIn("Host test-host", target.read_text())
        self.run_helper("rm", "test-host")
        self.assertEqual(target.read_text(), "# Preserve this.\n")

    def test_backup_symlink_and_hardlink_refusals(self):
        self.existing("# Original.\n")
        protected = self.root / "protected"
        protected.write_text(CANARY)
        backup = self.config.with_name("config.bak")
        backup.symlink_to(protected)
        self.add(ok=False)
        self.assertEqual(protected.read_text(), CANARY)
        backup.unlink()
        os.link(protected, backup)
        self.add(ok=False)
        self.assertEqual(protected.read_text(), CANARY)
        self.assertEqual(self.calls(), [])

    def test_concurrent_registrations_preserve_both_aliases(self):
        self.existing("# Original.\n")
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(self.run_helper, "add", alias, "--fragment", str(self.fragment))
                       for alias in ("first-host", "second-host")]
            for future in futures:
                future.result()
        rows = json.loads(self.run_helper("list", "--json").stdout)
        self.assertEqual({row["alias"] for row in rows}, {"first-host", "second-host"})
        self.assertTrue(self.config.read_text().endswith("# Original.\n"))
        original = self.config.read_bytes()
        backup = self.config.with_name("config.bak").read_bytes()
        self.run_helper("add", "first-host", "--fragment", str(self.fragment))
        self.run_helper("add", "second-host", "--fragment", str(self.fragment))
        self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual(self.config.with_name("config.bak").read_bytes(), backup)

    def test_another_invalid_managed_fragment_is_rejected_before_openssh(self):
        self.add()
        alternate = self.root / "alternate.conf"
        alternate.write_text("HostName other.invalid\n")
        self.fragment.write_text("HostName example.invalid\nMatch exec command-canary\n")
        before = len(self.calls())
        self.run_helper("add", "other-host", "--fragment", str(alternate), ok=False)
        self.assertEqual(len(self.calls()), before)

    def test_comments_and_opaque_identity_values(self):
        self.fragment.write_text("# Don't expand $HOME or \\ anywhere.\n"
                                 "HostName example.invalid # Don't interpret this comment.\n"
                                 "HostKeyAlias [opaque:test]/identity\n")
        self.add()
        self.assertIn("HostKeyAlias [opaque:test]/identity", self.config.read_text())

    def test_check_revalidates_without_connecting(self):
        self.add()
        before = len(self.calls())
        self.run_helper("check", "test-host")
        self.assertTrue(all("-G" in call for call in self.calls()[before:]))
        self.fragment.write_text(self.fragment.read_text().replace("opaque-test-key", "changed-key"))
        before = len(self.calls())
        self.run_helper("check", "test-host", ok=False)
        self.assertEqual(len(self.calls()), before)

    def test_apostrophes_and_spaces_round_trip_through_registration(self):
        renamed = self.root / "user's fragment.conf"
        self.fragment.rename(renamed)
        self.fragment = renamed
        self.add()
        self.run_helper("check", "test-host")
        self.assertEqual(json.loads(self.run_helper("list", "--json").stdout)[0]["fragment"], str(renamed))
        self.run_helper("rm", "test-host")

    def test_alias_case_variants_share_one_registration_and_policy(self):
        self.run_helper("add", "Test-Host", "--fragment", str(self.fragment))
        self.run_helper("add", "TEST-HOST", "--fragment", str(self.fragment))
        self.assertEqual(len(json.loads(self.run_helper("list", "--json").stdout)), 1)
        with self.config.open("a") as stream:
            stream.write("Host *\n    IdentityFile /different/key\n")
        self.assertIn("effective-config-conflict", self.run_helper("check", "test-host", ok=False).stderr)
        self.assertIn("effective-config-conflict", self.run_helper("check", "TEST-HOST", ok=False).stderr)
        self.run_helper("rm", "tEsT-hOsT")
        self.assertEqual(json.loads(self.run_helper("list", "--json").stdout), [])

    def test_duplicate_case_variant_managed_regions_are_refused(self):
        self.add()
        original = self.config.read_text()
        self.config.write_text(original + original.replace("test-host", "TEST-HOST"))
        for args in (("list",), ("check", "test-host"), ("rm", "TEST-HOST")):
            self.assertIn("malformed-managed-region", self.run_helper(*args, ok=False).stderr)

    def default_helper(self, *args, ok=True):
        result = subprocess.run([str(REPO / "bin/wt-ssh-host"), *args], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return result

    def test_default_validation_includes_system_policy_and_rolls_back(self):
        original = "# Original configuration.\n"
        backup = self.config.with_name("config.bak")
        for policy in ("IdentityFile /different/system-key", "CertificateFile /different/system-cert.pub"):
            with self.subTest(policy=policy):
                self.existing(original)
                backup.write_text("# Previous backup.\n")
                self.env["SSH_TEST_SYSTEM"] = policy + "\n"
                result = self.default_helper("add", "test-host", "--fragment", str(self.fragment), ok=False)
                self.assertIn("effective-config-conflict", result.stderr)
                self.assertEqual(self.config.read_text(), original)
                self.assertEqual(backup.read_text(), "# Previous backup.\n")
                self.assertTrue(all("-G" in call for call in self.calls()))
                self.config.unlink()
                self.default_helper("add", "test-host", "--fragment", str(self.fragment), ok=False)
                self.assertFalse(self.config.exists())
                self.assertEqual(backup.read_text(), "# Previous backup.\n")

    def test_default_check_and_verification_use_ordinary_transport_semantics(self):
        self.default_helper("add", "test-host", "--fragment", str(self.fragment))
        self.assertNotIn("-F", self.calls()[-1])
        self.env["SSH_TEST_SYSTEM"] = "IdentityFile /different/system-key\n"
        self.assertIn("effective-config-conflict", self.default_helper("check", "TEST-HOST", ok=False).stderr)
        self.run_helper("check", "TEST-HOST")
        self.add()

    def test_default_validation_does_not_overwrite_concurrent_configuration(self):
        original = "# Original configuration.\n"
        self.existing(original)
        self.env["SSH_TEST_SYSTEM"] = "IdentityFile /different/system-key\n"
        self.env["SSH_TEST_MUTATION"] = "# Concurrent edit.\n"
        result = self.default_helper("add", "test-host", "--fragment", str(self.fragment), ok=False)
        self.assertIn("config-changed", result.stderr)
        self.assertEqual(self.config.read_text(), "# Concurrent edit.\n")
        self.assertFalse(self.config.with_name("config.bak").exists())

    def test_invalid_fragment_blocks_workgrove_transports(self):
        self.add()
        self.fragment.write_text("HostName example.invalid\nMatch exec " + CANARY + "\n")
        before = len(self.calls())
        uname = self.tools / "uname"
        uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n")
        uname.chmod(0o700)
        for args in (("-H", "test-host", "repos"), ("hosts", "--json")):
            result = subprocess.run([os.environ["BASH"], str(REPO / "bin/wt"), *args], env=self.env,
                                    capture_output=True, text=True, timeout=15)
            self.assertNotIn(CANARY, result.stdout + result.stderr)
            if args[0] == "hosts":
                self.assertEqual(json.loads(result.stdout)[0]["status"], "unavailable")
            else:
                self.assertNotEqual(result.returncode, 0)
        script = ('source "$1/lib/workgrove/common.sh"; '
                  'CMUX_ROWS_FULL=1; CMUX_ROWS_JSON=\'{"workspaces":[]}\'; '
                  'cmux_call() { echo unexpected-cmux-call; }; '
                  'cmux_row_create_ssh test-host task description command')
        result = subprocess.run([os.environ["BASH"], "-c", script, "test", str(REPO)], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unexpected-cmux-call", result.stdout)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        self.assertEqual(len(self.calls()), before)

    def test_invalid_arguments_do_not_echo_values(self):
        result = self.run_helper("add", "test-host", "--fragment", str(self.fragment), "--unexpected", CANARY, ok=False)
        self.assertIn("invalid-arguments", result.stderr)


if __name__ == "__main__":
    unittest.main()
