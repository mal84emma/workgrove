"""Exercise teardown signals with disposable workers and interrupted process probes."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wt-coordinator-')
        self.root = Path(self.temporary.name)
        self.lock = self.root / 'task.lock'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.worker = None
        self.coordinator = None
        self.environment = dict(os.environ, FIXTURE_ROOT=str(self.root), FIXTURE_PYTHON=sys.executable,
                                REAL_PS=shutil.which('ps'), PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        (self.bin / 'ps').write_text('''#!''' + sys.executable + '''
import os, pathlib, signal, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
if sys.argv[1] == '-axo':
    mode = os.environ.get('PROBE_FAULT', '')
    marker = root / 'interrupted'
    if mode == 'always' or (mode in ('once', 'repeated') and not marker.exists()):
        marker.touch()
        if mode == 'repeated':
            for _ in range(10):
                os.kill(os.getppid(), signal.SIGHUP)
        os.kill(os.getpid(), signal.SIGHUP)
    if mode == 'error': sys.exit(2)
    if mode == 'empty': sys.exit(0)
    if mode == 'malformed': print('unreadable'); sys.exit(0)
os.execv(os.environ['REAL_PS'], [os.environ['REAL_PS'], *sys.argv[1:]])
''')
        (self.bin / 'ps').chmod(0o755)
        (self.root / 'worker.py').write_text('''
import json, os, pathlib, signal, socket, subprocess, time
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
channel = socket.socket(fileno=int(os.environ['WG_TEARDOWN_CONTROL_FD']))
channel.sendall((json.dumps(dict(op='check', path=os.environ['WG_TEARDOWN_LOCK_PATH'])) + '\\n').encode())
assert channel.recv(100) == b'ok\\n'
(root / 'worker-pid').write_text(str(os.getpid()))
# A pipe holder models a hook child that survives the worker.
subprocess.Popen(['sleep', '60'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
received = 0
def handle(signum, frame):
    global received
    received = signum
for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
    signal.signal(signum, signal.SIG_IGN if (root / 'ignore-signals').exists() else handle)
(root / 'ready').touch()
while not received and not (root / 'release').exists():
    time.sleep(0.01)
raise SystemExit(128 + received if received else 0)
''')
        (self.root / 'worker.sh').write_text('exec "$FIXTURE_PYTHON" "$FIXTURE_ROOT/worker.py"\n')

    def tearDown(self):
        if self.coordinator is not None and self.coordinator.poll() is None:
            self.coordinator.kill()
            self.coordinator.communicate(timeout=5)
        if (self.root / 'worker-pid').exists():
            try:
                os.killpg(int((self.root / 'worker-pid').read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.temporary.cleanup()

    def wait_for(self, filename):
        for _ in range(500):
            if (self.root / filename).exists():
                return
            if self.coordinator.poll() is not None:
                self.fail(str(self.coordinator.communicate()))
            time.sleep(0.01)
        self.fail('fixture did not reach ' + filename)

    def launch(self, fault=''):
        self.coordinator = subprocess.Popen(
            [sys.executable, str(ROOT / 'lib/workgrove/coordinator.py'), str(self.lock), 'task',
             shutil.which('bash'), str(self.root / 'worker.sh'), ''],
            env=dict(self.environment, PROBE_FAULT=fault), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.wait_for('ready')
        self.worker = int((self.root / 'worker-pid').read_text())

    def finish(self):
        out, err = self.coordinator.communicate(timeout=10)
        self.assertNotIn('Traceback', err)
        with self.lock.open() as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return self.coordinator.returncode, out, err

    def test_interrupted_probe_retries_before_proving_absence(self):
        self.launch('once')
        (self.root / 'release').touch()
        status, _, err = self.finish()
        self.assertEqual(status, 0, err)
        self.assertTrue((self.root / 'interrupted').exists())
        self.assertEqual(self.lock.read_text(), '')
        listing = subprocess.check_output([self.environment['REAL_PS'], '-axo', 'pgid=,stat='], text=True)
        self.assertFalse(any(int(line.split()[0]) == self.worker and not line.split()[1].startswith('Z')
                             for line in listing.splitlines()))

    def test_repeated_signals_during_probe_cannot_reenter_cleanup(self):
        self.launch('repeated')
        (self.root / 'release').touch()
        status, _, _ = self.finish()
        self.assertEqual(status, 129)
        self.assertEqual(self.lock.read_text(), '')

    def test_signals_cancel_only_the_owned_group(self):
        unrelated = subprocess.Popen(['sleep', '60'], start_new_session=True)
        try:
            self.launch()
            os.kill(self.coordinator.pid, signal.SIGHUP)
            os.kill(self.coordinator.pid, signal.SIGTERM)
            status, _, _ = self.finish()
            self.assertNotEqual(status, 0)
            self.assertEqual(self.lock.read_text(), '')
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def cancel_ignoring_worker(self, signum):
        unrelated = subprocess.Popen(['sleep', '60'], start_new_session=True)
        try:
            (self.root / 'ignore-signals').touch()
            self.launch()
            os.kill(self.coordinator.pid, signum)
            status, _, _ = self.finish()
            self.assertNotEqual(status, 0)
            self.assertEqual(self.lock.read_text(), '')
            self.assertIsNone(unrelated.poll())
            listing = subprocess.check_output(
                [self.environment['REAL_PS'], '-axo', 'pgid=,stat='], text=True)
            self.assertFalse(any(int(line.split()[0]) == self.worker
                                 and not line.split()[1].startswith('Z')
                                 for line in listing.splitlines()))
            (self.root / 'worker-pid').unlink()
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_ignored_hangup_still_cancels_the_owned_group(self):
        self.cancel_ignoring_worker(signal.SIGHUP)

    def test_ignored_termination_still_cancels_the_owned_group(self):
        self.cancel_ignoring_worker(signal.SIGTERM)

    def test_uncertain_samples_keep_the_owner_record_and_fail(self):
        for fault in ('always', 'error', 'empty', 'malformed'):
            with self.subTest(fault=fault):
                self.launch(fault)
                (self.root / 'release').touch()
                status, _, err = self.finish()
                self.assertNotEqual(status, 0)
                self.assertIn('wt:', err)
                self.assertEqual(json.loads(self.lock.read_text())['group'], self.worker)
                retry = subprocess.run(
                    [sys.executable, str(ROOT / 'lib/workgrove/coordinator.py'), str(self.lock), 'task',
                     shutil.which('bash'), str(self.root / 'worker.sh'), ''],
                    env=self.environment, capture_output=True, text=True, timeout=5)
                self.assertNotEqual(retry.returncode, 0)
                self.assertIn('previous teardown commands are still running', retry.stderr)
                self.assertEqual(json.loads(self.lock.read_text())['group'], self.worker)
                # Release only this fixture's group before the next independent run.
                try:
                    os.killpg(self.worker, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.lock.unlink()
                for name in ('ready', 'release', 'worker-pid'):
                    (self.root / name).unlink(missing_ok=True)


if __name__ == '__main__':
    unittest.main()
