"""Exercise hard interruptions without touching live Git locks or sessions."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'lib/workgrove/branch_config.py'
spec = importlib.util.spec_from_file_location('branch_config', HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

CHILD = r'''
import importlib.util, json, os, pathlib, sys, time
helper, repo, expected, point = sys.argv[1:]
spec = importlib.util.spec_from_file_location('helper', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def pause():
    pathlib.Path(repo, 'ready').write_text('ready')
    while True:
        time.sleep(1)
if point == 'acquire':
    original = module.OwnedLocks.acquire
    def acquire(self):
        original(self)
        pause()
    module.OwnedLocks.acquire = acquire
elif point == 'link':
    original = os.link
    def link(source, target):
        original(source, target)
        pause()
    os.link = link
elif point.startswith('unlink-'):
    original = os.unlink
    def unlink(path, *args, **kwargs):
        original(path, *args, **kwargs)
        if str(path).endswith('/absent.branch-locks/' + point[7:]):
            pause()
    os.unlink = unlink
else:
    original = module.sync_directory
    def sync(path):
        original(path)
        if path == repo + '/.git' and not os.path.exists(repo + '/.git/config.lock'):
            pause()
    module.sync_directory = sync
sys.argv = [helper, 'remove', repo, 'wt/absent', expected, 'fixture']
module.main()
'''


class ConfigurationLocks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wt-config-lock-test-')
        self.repo = Path(self.directory.name)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'config', 'branch.wt/absent.remote', 'original'], check=True)
        self.expected = json.dumps(module.entries(str(self.repo / '.git/config'), 'wt/absent'))

    def tearDown(self):
        self.directory.cleanup()

    def remove(self, expected=None):
        return subprocess.run([sys.executable, str(HELPER), 'remove', str(self.repo), 'wt/absent',
                               expected or self.expected, 'fixture'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def interrupt(self, point):
        process = subprocess.Popen([sys.executable, '-c', CHILD, str(HELPER), str(self.repo), self.expected, point],
                                   start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not (self.repo / 'ready').exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.repo / 'ready').exists(), 'owned helper did not reach interruption point')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)

    def assert_clean(self):
        for path in ('.git/config.lock', '.git/refs/heads/wt/absent.lock', '.git/wt/teardown/absent.branch-locks'):
            self.assertFalse((self.repo / path).exists(), path)
        self.assertEqual('', module.entries(str(self.repo / '.git/config'), 'wt/absent'))

    def test_recovery_after_lock_acquisition(self):
        self.interrupt('acquire')
        result = self.remove()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assert_clean()

    def test_recovery_after_first_lock_link(self):
        self.interrupt('link')
        result = self.remove()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assert_clean()

    def test_recovery_after_config_replacement(self):
        self.interrupt('replace')
        result = self.remove()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assert_clean()

    def test_recovery_during_private_cleanup(self):
        for name in ('ref', 'config', 'owner.json', 'edited'):
            with self.subTest(name=name):
                subprocess.run(['git', '-C', str(self.repo), 'config', 'branch.wt/absent.remote', 'original'], check=True)
                (self.repo / 'ready').unlink(missing_ok=True)
                self.interrupt('unlink-' + name)
                result = self.remove()
                self.assertEqual(0, result.returncode, result.stderr)
                self.assert_clean()

    def test_keep_branch_recovery_only_releases_owned_locks(self):
        self.interrupt('acquire')
        subprocess.run([sys.executable, str(HELPER), 'recover', str(self.repo), 'wt/absent', 'null', 'fixture'], check=True)
        self.assertEqual(json.loads(self.expected), module.entries(str(self.repo / '.git/config'), 'wt/absent'))
        self.assertFalse((self.repo / '.git/config.lock').exists())
        self.assertFalse((self.repo / '.git/refs/heads/wt/absent.lock').exists())

    def test_dotted_unrelated_section_survives(self):
        subprocess.run(['git', '-C', str(self.repo), 'config', 'branch.wt/absent.other.remote', 'unrelated'], check=True)
        self.assertEqual(json.loads(self.expected), module.entries(str(self.repo / '.git/config'), 'wt/absent'))
        self.assertEqual(0, self.remove().returncode)
        self.assertEqual('', module.entries(str(self.repo / '.git/config'), 'wt/absent'))
        self.assertEqual(b'unrelated\n', subprocess.check_output(['git', '-C', str(self.repo), 'config', 'branch.wt/absent.other.remote']))
        self.assertEqual(0, self.remove().returncode)

    def test_unknown_lock_remains_untouched(self):
        lock = self.repo / '.git/config.lock'
        lock.write_bytes(b'unrelated Git command\n')
        result = self.remove()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b'unrelated Git command\n', lock.read_bytes())
        lock.unlink()
        self.assertEqual(0, self.remove().returncode)
        self.assert_clean()

    def test_replacement_lock_remains_untouched(self):
        self.interrupt('acquire')
        lock = self.repo / '.git/config.lock'
        lock.unlink()
        lock.write_bytes(b'replacement Git command\n')
        result = self.remove()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b'replacement Git command\n', lock.read_bytes())
        lock.unlink()
        self.assertEqual(0, self.remove().returncode)
        self.assert_clean()


if __name__ == '__main__':
    unittest.main()
