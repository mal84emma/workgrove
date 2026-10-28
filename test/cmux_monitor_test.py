"""Check detached monitor proof with native process samples and owned temporary files."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cmux_monitor', Path(__file__).resolve().parents[1] / 'lib/workgrove/cmux_monitor.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)
ROW = '00000000-0000-0000-0000-000000000001'
SURFACE = '00000000-0000-0000-0000-000000000002'
SESSION = '00000000-0000-0000-0000-000000000003'
TURN = '00000000-0000-0000-0000-000000000004'
BROWSER = '00000000-0000-0000-0000-000000000005'


class FakeProcesses:
    platform = 'darwin'

    def __init__(self, executable, arguments):
        self.executable = executable
        self.argv = arguments
        self.identities = {
            100: dict(pid=100, ppid=90, birth='bsd:1000:0', comm='codex', zombie=False),
            200: dict(pid=200, ppid=1, birth='bsd:1010:500000', comm='cmux', zombie=False),
        }

    def identity(self, pid):
        return copy.deepcopy(self.identities.get(pid))

    def image(self, pid):
        return self.executable

    def arguments(self, pid):
        return self.argv.copy()


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wt-monitor-proof-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.cli = self.home / 'cmux'
        self.cli.write_text('fixture executable')
        self.cli.chmod(0o755)
        self.task = str(self.home / 'task')
        options = ['--workspace', ROW, '--session', SESSION, '--surface', SURFACE, '--turn', TURN,
                   '--transcript', str(self.home / 'transcript.jsonl'), '--cwd', self.task,
                   '--lease', str(self.home / 'lease.json')]
        self.backend = FakeProcesses(str(self.cli), [str(self.cli), 'hooks', 'codex', 'monitor', *options])
        surface = dict(type='terminal', ref='surface:1000050163', tty='ttys010',
                       resources=dict(pids=[100, 200], missing_pids=[]), cmux_process_pids=[200])
        tag = dict(key='codex.' + SESSION, pid=100, root_pids=[100],
                   ref=f'workspace:{ROW}:tag:codex.{SESSION}')
        row = dict(id=ROW, tags=[tag], panes=[dict(surfaces=[surface])])
        tree_row = dict(id=ROW, panes=[dict(surfaces=[dict(id=SURFACE, type='terminal', tty='ttys010')])])
        self.evidence = dict(top=dict(include_processes=True, windows=[dict(workspaces=[row])]),
                             tree=dict(windows=[dict(workspaces=[tree_row])]))

    def check(self):
        return monitor.validate(self.backend, self.evidence, ROW, self.task, 100, 200, str(self.cli))

    def test_native_monitor_and_optional_dev_prefix(self):
        self.evidence['tree']['windows'][0]['workspaces'][0]['panes'][0]['surfaces'].append(
            dict(id=BROWSER, type='browser', tty=None))
        self.assertEqual(self.check(), dict(pid=200, birth='bsd:1010:500000', comm='cmux', role='command'))
        self.evidence['top']['windows'][0]['workspaces'][0]['panes'][0]['surfaces'][0]['tty'] = '/dev/ttys010'
        self.check()

    def test_other_process_image_or_mode_is_not_exempt(self):
        self.backend.executable = '/another/cmux'
        with self.assertRaises(ValueError): self.check()
        self.backend.executable = str(self.cli)
        self.backend.argv[3] = 'session-end'
        with self.assertRaises(ValueError): self.check()

    def test_duplicate_extra_fork_and_wrong_target_options_refuse(self):
        original = self.backend.argv.copy()
        for mutation in (
                original + ['--fork-parent', SESSION],
                original[:4] + ['--workspace', ROW] + original[6:14] + ['--workspace', ROW] + original[16:],
                [SURFACE if value == ROW else value for value in original],
                [ROW if value == SURFACE else value for value in original]):
            with self.subTest(arguments=mutation):
                self.backend.argv = mutation
                with self.assertRaises(ValueError): self.check()

    def test_ambiguous_native_tag_surface_and_tree_refuse(self):
        original = copy.deepcopy(self.evidence)
        row = self.evidence['top']['windows'][0]['workspaces'][0]
        row['tags'].append(copy.deepcopy(row['tags'][0]))
        with self.assertRaises(ValueError): self.check()
        self.evidence = copy.deepcopy(original)
        row = self.evidence['top']['windows'][0]['workspaces'][0]
        row['panes'][0]['surfaces'].append(copy.deepcopy(row['panes'][0]['surfaces'][0]))
        with self.assertRaises(ValueError): self.check()
        self.evidence = copy.deepcopy(original)
        tree_row = self.evidence['tree']['windows'][0]['workspaces'][0]
        tree_row['panes'][0]['surfaces'].append(copy.deepcopy(tree_row['panes'][0]['surfaces'][0]))
        with self.assertRaises(ValueError): self.check()

    def test_unattributed_or_missing_monitor_refuses(self):
        surface = self.evidence['top']['windows'][0]['workspaces'][0]['panes'][0]['surfaces'][0]
        for key, value in (('cmux_process_pids', []), ('resources', dict(pids=[100], missing_pids=[])),
                           ('resources', dict(pids=[100, 200], missing_pids=[200]))):
            original = copy.deepcopy(surface[key])
            surface[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.check()
            surface[key] = original
        self.backend.identities[200]['ppid'] = 90
        with self.assertRaises(ValueError): self.check()

    def test_identity_and_image_changes_or_probe_failure_refuse(self):
        original = self.backend.identity
        count = 0
        def changed(pid):
            nonlocal count
            record = original(pid)
            if pid == 200:
                count += 1
                if count > 1: record['birth'] = 'bsd:1011:0'
            return record
        self.backend.identity = changed
        with self.assertRaises(ValueError): self.check()
        self.backend.identity = original
        def denied(pid): raise PermissionError('fixture probe refusal')
        self.backend.image = denied
        with self.assertRaises(PermissionError): self.check()

    def test_kernel_arguments_use_nul_boundaries_and_omit_environment(self):
        arguments = self.backend.argv.copy()
        arguments[15] = self.task + ' with spaces'
        data = struct.pack('=i', 18) + str(self.cli).encode() + b'\0\0\0'
        data += b'\0'.join(item.encode() for item in arguments) + b'\0PRIVATE=not-an-argument\0'
        self.assertEqual(monitor.parse_arguments(data), arguments)
        with self.assertRaises(ValueError): monitor.parse_arguments(data[:12])

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin kernel process interfaces')
    def test_detached_observer_is_canceled_before_its_deadline(self):
        backend = monitor.Processes()
        executable = backend.image(os.getpid())
        (self.home / 'hooks').write_text('import time; time.sleep(6000)\n')
        arguments = [executable, 'hooks', 'codex', 'monitor', *self.backend.argv[4:]]
        launcher = 'import json,subprocess,sys; child=subprocess.Popen(json.loads(sys.argv[1]),start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(child.pid)'
        pid = int(subprocess.check_output([executable, '-c', launcher, json.dumps(arguments)], cwd=self.home, text=True))
        owner = None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                owner = backend.identity(pid)
                if owner and owner['ppid'] == 1:
                    break
                time.sleep(0.02)
            self.assertIsNotNone(owner)
            self.assertEqual(owner['ppid'], 1)
            provider = os.getpid()
            row = self.evidence['top']['windows'][0]['workspaces'][0]
            row['tags'][0].update(pid=provider, root_pids=[provider])
            surface = row['panes'][0]['surfaces'][0]
            surface['resources']['pids'] = [provider, pid]
            surface['cmux_process_pids'] = [pid]
            record = monitor.validate(backend, self.evidence, ROW, self.task, provider, pid, executable)
            root = backend.identity(provider)
            runtime = dict(pid=provider, birth=root['birth'], comm=root['comm'], role='runtime')
            manifest = dict(version=1, generation='observer', boot=backend.boot(), platform=backend.platform,
                            records=[runtime, record])
            started = time.monotonic()
            monitor.commands.stop(backend, manifest, 'observer', 'commands')
            self.assertLess(time.monotonic() - started, 10)
            self.assertFalse(monitor.commands.live(backend, record))
            self.assertTrue(monitor.commands.live(backend, runtime))
        finally:
            current = backend.identity(pid)
            if owner and current and current['birth'] == owner['birth'] and not current['zombie']:
                os.kill(pid, 9)

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin kernel argument interface')
    def test_real_owned_kernel_arguments_and_identity(self):
        arguments = [sys.executable, '-c', 'import time; print("ready",flush=True); time.sleep(60)',
                     *[f'argument {index}' for index in range(15)]]
        child = subprocess.Popen(arguments, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            backend = monitor.Processes()
            before = backend.identity(child.pid)
            image = backend.image(child.pid)
            self.assertEqual(backend.arguments(child.pid), [image, *arguments[1:]])
            self.assertTrue(Path(image).is_absolute())
            self.assertEqual(backend.identity(child.pid), before)
        finally:
            child.terminate()
            child.wait(timeout=5)
            child.stdout.close()


if __name__ == '__main__':
    unittest.main()
