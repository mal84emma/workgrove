"""Check task command identities without accessing live providers or services."""
import copy
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('commands', Path(__file__).resolve().parents[1] / 'lib/workgrove/commands.py')
commands = importlib.util.module_from_spec(spec)
spec.loader.exec_module(commands)
BOOT = '00000000-0000-0000-0000-000000000001'


class FakeProcesses:
    platform = 'linux'

    def __init__(self):
        self.nodes = {pid: dict(pid=pid, ppid=parent, birth=f'ticks:{pid}', comm=name, zombie=False)
                      for pid, parent, name in ((10, 1, 'codex'), (20, 10, 'exec-server'), (25, 20, 'bash'),
                                                (30, 25, 'bash'), (40, 30, 'python3'), (50, 40, 'bash'),
                                                (55, 50, 'python3'), (60, 20, 'sleep'), (70, 1, 'sleep'),
                                                (80, 10, 'codex-guardian'))}
        self.sent = []
        self.boot_id = BOOT

    def boot(self):
        return self.boot_id

    def table(self):
        return {p: dict(ppid=n['ppid'], start='expected start', comm=n['comm']) for p, n in self.nodes.items()}

    def identity(self, pid):
        return copy.deepcopy(self.nodes.get(pid))

    def send(self, pid, signum):
        self.sent.append((pid, signum))
        self.nodes.pop(pid, None)


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.backend = FakeProcesses()
        with patch.object(commands.os, 'getppid', return_value=50):
            self.manifest = commands.capture(self.backend, 'generation', 10, 'expected start', 30, None)

    def test_capture_excludes_only_cleanup_and_keeps_runtime_ancestors(self):
        records = {r['pid']: r for r in self.manifest['records']}
        self.assertEqual(set(records), {10, 20, 60, 80})
        self.assertEqual(records[60]['role'], 'command')
        self.assertEqual({p for p, r in records.items() if r['role'] == 'runtime'}, {10, 20, 80})

    def test_detached_command_dies_and_independent_process_survives(self):
        self.backend.nodes[60]['ppid'] = 1
        commands.stop(self.backend, self.manifest, 'generation', 'commands')
        self.assertEqual(self.backend.sent, [(60, signal.SIGTERM)])
        self.assertIn(70, self.backend.nodes)
        self.assertTrue(commands.remaining(self.backend, self.manifest, 'generation', 'all'))
        commands.stop(self.backend, self.manifest, 'generation', 'all')
        self.assertFalse(commands.remaining(self.backend, self.manifest, 'generation', 'all'))
        self.assertIn(70, self.backend.nodes)

    def test_replacement_birth_is_never_signaled(self):
        self.backend.nodes[60]['birth'] = 'ticks:999'
        commands.stop(self.backend, self.manifest, 'generation', 'commands')
        self.assertEqual(self.backend.sent, [])
        self.assertIn(60, self.backend.nodes)

    def test_executable_change_and_probe_failure_refuse(self):
        self.backend.nodes[60]['comm'] = 'replacement'
        with self.assertRaises(ValueError):
            commands.stop(self.backend, self.manifest, 'generation', 'commands')
        self.assertEqual(self.backend.sent, [])
        with patch.object(self.backend, 'identity', side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                commands.remaining(self.backend, self.manifest, 'generation', 'all')

    def test_signal_failure_refuses(self):
        with patch.object(self.backend, 'send', side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                commands.stop(self.backend, self.manifest, 'generation', 'commands')

    def test_changed_boot_never_signals_old_records(self):
        self.backend.boot_id = '00000000-0000-0000-0000-000000000002'
        commands.stop(self.backend, self.manifest, 'generation', 'all')
        self.assertEqual(self.backend.sent, [])

    def test_stale_malformed_or_empty_manifest_refuses(self):
        for value in (None, {}, [], dict(self.manifest, records=[]), dict(self.manifest, generation='old'),
                      dict(self.manifest, boot='invalid'), dict(self.manifest, version=True),
                      dict(self.manifest, records=self.manifest['records'] * 2)):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    commands.remaining(self.backend, value, 'generation', 'all')

    def test_new_descendant_is_merged_before_signaling(self):
        self.backend.nodes[90] = dict(pid=90, ppid=20, birth='ticks:90', comm='sleep', zombie=False)
        with patch.object(commands.os, 'getppid', return_value=50):
            refreshed = commands.capture(self.backend, 'generation', 10, 'expected start', 30, self.manifest)
        self.assertNotEqual(refreshed, self.manifest)
        self.assertIn(90, {r['pid'] for r in refreshed['records']})

    def test_real_owned_detached_child_ignores_term_and_is_reaped(self):
        backend = commands.Processes()
        child = subprocess.Popen([sys.executable, '-c',
                                  'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(60)'],
                                 start_new_session=True, stdout=subprocess.PIPE, text=True)
        independent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            owner = backend.identity(os.getpid())
            owned = backend.identity(child.pid)
            self.assertEqual(owned['ppid'], os.getpid())
            records = []
            for item, role in ((owner, 'runtime'), (owned, 'command')):
                records.append(dict(pid=item['pid'], birth=item['birth'], comm=item['comm'], role=role))
            manifest = dict(version=1, generation='real', boot=backend.boot(), platform=backend.platform, records=records)
            commands.stop(backend, manifest, 'real', 'commands')
            self.assertEqual(child.wait(timeout=5), -signal.SIGKILL)
            self.assertIsNone(independent.poll())
        finally:
            for process in (child, independent):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
            child.stdout.close()


if __name__ == '__main__':
    unittest.main()
