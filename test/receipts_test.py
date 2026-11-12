"""Characterize receipt policy and atomic writes against the pre-extraction boundaries."""
import importlib.util
import itertools
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'lib/workgrove/receipts.py'
STAGES = ('prepared', 'worktree_removed', 'branch_config_removing', 'sidecars_removing',
          'git_removed', 'close_requested', 'complete')
# Freeze the original read boundary as an independent compatibility oracle.
PREDICATE = '''.repo == $repo and .name == $name and .path == $path and .branch == ("wt/" + $name) and (.head | test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and all(.keep,.native,.remote; IN("0","1")) and (.stage | IN("prepared","worktree_removed","branch_config_removing","sidecars_removing","git_removed","close_requested","complete"))'''
spec = importlib.util.spec_from_file_location('receipts', HELPER)
MODULE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(MODULE)


def receipt(**updates):
    data = dict(repo='/repo', name='task', path='/repo/.worktrees/task', branch='wt/task',
                head='a' * 40, keep='0', native='0', remote='0', stage='prepared',
                metadata_hash='absent', base='main', base_object='', proof='ancestry',
                agent='none', row='', self='', session='', workspace='0')
    data.update(updates)
    return data


def old_read(raw):
    return subprocess.run(['jq', '-e', '--arg', 'repo', '/repo', '--arg', 'name', 'task',
                           '--arg', 'path', '/repo/.worktrees/task', PREDICATE],
                          input=raw, text=True, capture_output=True).returncode


def read(raw):
    try:
        MODULE.validate(MODULE.decode(raw), '/repo', 'task', '/repo/.worktrees/task')
        return True
    except (ValueError, TypeError):
        return False


def write(path, data):
    MODULE.write(str(path), json.loads(json.dumps(data)))


class ReceiptPolicy(unittest.TestCase):
    def test_optional_and_legacy_shapes(self):
        optional = dict(commands=None, sidecars=dict(metadata='absent', prompt='absent', started='absent'),
                        branch_config='', runtime=None, tmux_identity=None, tmux_owner=None, title='task', host='')
        for present in itertools.product((False, True), repeat=len(optional)):
            data = receipt(**{key: value for (key, value), enabled in zip(optional.items(), present) if enabled})
            for generation in ({}, {'generation': 'generation'}):
                data.update(generation)
                with self.subTest(present=present, generation=generation):
                    self.assertEqual(0, old_read(json.dumps(data)))
                    self.assertTrue(read(json.dumps(data)))
                    with tempfile.TemporaryDirectory() as directory:
                        target = Path(directory) / 'receipts/task.json'
                        write(target, data)
                        self.assertEqual(data, json.loads(target.read_text()))
        for size in (40, 64):
            for stage in STAGES:
                self.assertTrue(read(json.dumps(receipt(head='b' * size, stage=stage))))
        # Optional evidence belongs to its existing live consumer, not this boundary.
        self.assertTrue(read(json.dumps(receipt(commands=12, runtime=[], host=False))))

    def test_malformed_and_identity(self):
        for raw in ('', '{', 'null', '[]', 'true', '1', '"text"'):
            with self.subTest(raw=raw):
                self.assertFalse(read(raw))
        for field in ('repo', 'name', 'path', 'branch', 'head', 'keep', 'native', 'remote', 'stage'):
            for value in (None, [], {}, 1, True, 'wrong'):
                with self.subTest(field=field, value=value):
                    self.assertFalse(read(json.dumps(receipt(**{field: value}))))
            data = receipt()
            del data[field]
            self.assertFalse(read(json.dumps(data)))
        for head in ('A' * 40, 'a' * 39, 'a' * 41, 'a' * 63, 'a' * 65):
            self.assertFalse(read(json.dumps(receipt(head=head))))

    def test_jq_edge_results(self):
        valid = json.dumps(receipt())
        cases = [(valid, 0), ('', 4), ('null', 1), ('[]', 5), ('true', 5), ('1', 5),
                 (valid[:-1] + ',"keep":"1"}', 0),
                 (valid[:-1] + ',"keep":1}', 1),
                 (valid + ' trailing', 5), (valid + '\n' + valid, 0),
                 ('{}\n' + valid, 0)]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                if raw == '':
                    # jq 1.6 accepts an empty stream; Apple jq returns four.
                    self.assertIn(old_read(raw), (0, 4))
                    self.assertFalse(read(raw))
                    continue
                self.assertEqual(expected == 0, old_read(raw) == 0)
                if raw in (valid + '\n' + valid, '{}\n' + valid):
                    self.assertFalse(read(raw))
                else:
                    self.assertEqual(expected == 0, read(raw))

    def test_degenerate_json_never_broadens_jq_acceptance(self):
        valid = json.dumps(receipt())
        for raw in (valid[:-1] + ',"extra":NaN}', valid[:-1] + ',"extra":Infinity}',
                    '\ufeff' + valid, json.dumps(receipt(host='\ud800')),
                    json.dumps(receipt(host='\udfff'))):
            with self.subTest(raw=raw):
                # jq versions differ on degenerate JSON; the new boundary always refuses it.
                self.assertFalse(read(raw))
        self.assertTrue(read(json.dumps(receipt(title='\U0001f680'))))
        self.assertTrue(read(json.dumps(receipt(head='a' * 40 + '\n'))))

    def test_parser_limits_and_discarded_duplicate_values(self):
        base = json.dumps(receipt())[:-1]
        for opening, closing, accepted, refused in (('[', ']', 254, 255), ('{"n":', '}', 127, 128)):
            for count in (accepted, refused):
                raw = base + ',"extra":' + opening * count + '0' + closing * count + '}'
                with self.subTest(opening=opening, count=count):
                    self.assertEqual(count == accepted, old_read(raw) == 0)
                    self.assertEqual(count == accepted, read(raw))
            raw = base + ',"extra":' + opening * refused + '0' + closing * refused + ',"extra":0}'
            self.assertNotEqual(0, old_read(raw))
            self.assertFalse(read(raw))
        raw = base + ',"extra":"\\ud800","extra":"ok"}'
        self.assertNotEqual(0, old_read(raw))
        self.assertFalse(read(raw))
        self.assertTrue(read(json.dumps(receipt(title='[{"quoted": "["}]'))))

    def test_cli_validation_is_read_only(self):
        for data, status in ((receipt(), 0), (receipt(keep=1), 1)):
            raw = json.dumps(data)
            result = subprocess.run([sys.executable, str(HELPER), 'validate', '/repo', 'task',
                                     '/repo/.worktrees/task'], input=raw, text=True, capture_output=True)
            self.assertEqual(status, result.returncode, result.stderr)
            self.assertEqual('', result.stdout)

    def test_generation_matrix_and_retry_stages(self):
        for old_generation, new_generation, old_stage, new_stage in itertools.product(
                (None, 'old', 'new'), (None, 'old', 'new'), STAGES, STAGES):
            old, new = receipt(stage=old_stage), receipt(stage=new_stage)
            if old_generation is not None:
                old['generation'] = old_generation
            if new_generation is not None:
                new['generation'] = new_generation
            allowed = old_generation == new_generation or (old_stage == 'complete' and new_stage == 'prepared')
            with self.subTest(old=old_generation, new=new_generation, stages=(old_stage, new_stage)):
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / 'task.json'
                    path.write_text(json.dumps(old))
                    original = path.read_bytes()
                    if allowed:
                        write(path, new)
                        self.assertEqual(new, json.loads(path.read_text()))
                    else:
                        with self.assertRaisesRegex((SystemExit, ValueError), 'cleanup generation changed; kept the newer receipt'):
                            write(path, new)
                        self.assertEqual(original, path.read_bytes())

    def test_writer_does_not_add_read_constraints(self):
        for data in (receipt(keep=1), receipt(head='BAD'), receipt(stage='unknown'), {}, {'stage': 'prepared'}):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'task.json'
                write(path, data)
                self.assertEqual(data, json.loads(path.read_text()))


class AtomicReceipt(unittest.TestCase):
    def test_bytes_modes_and_sync_order(self):
        data = receipt(title='caf\u00e9', runtime={'n': 1.0, 'nested': [True, None]}, generation='g')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private/task.json'
            events = []
            real_sync, real_replace = os.fsync, os.replace

            def sync(fd):
                events.append('directory' if stat.S_ISDIR(os.fstat(fd).st_mode) else 'file')
                return real_sync(fd)

            def replace(source, target):
                events.append('replace')
                return real_replace(source, target)

            with patch('os.fsync', side_effect=sync), patch('os.replace', side_effect=replace):
                write(path, data)
            self.assertEqual(['file', 'replace', 'directory'], events)
            self.assertEqual((json.dumps(data) + '\n').encode(), path.read_bytes())
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
            self.assertEqual(0o700, stat.S_IMODE(path.parent.stat().st_mode))
            self.assertEqual([path], list(path.parent.iterdir()))

    def test_existing_directory_mode_and_jq_number_encoding(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'task.json'
            os.chmod(directory, 0o750)
            raw = '{"stage":"old","runtime":{"n":1.0,"big":9007199254740993,"small":1e-20}}'
            normalized = subprocess.check_output(['jq', '-c', '--arg', 'stage', 'prepared',
                                                   '.stage=$stage'], input=raw, text=True)
            script = r'''source "$1/lib/workgrove/teardown.sh"
WG_VERSION_ROOT=$1
WT_TEARDOWN_FILE=$2
WT_TEARDOWN_JSON=$3
teardown_control() { :; }
teardown_interpreter() { "$PYTHON" "$@"; }
die() { echo "$*" >&2; exit 1; }
teardown_save prepared
'''
            result = subprocess.run(['bash', '-c', script, 'test', str(ROOT), str(path), raw],
                                    env=dict(os.environ, PYTHON=sys.executable), capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual((json.dumps(json.loads(normalized)) + '\n').encode(), path.read_bytes())
            self.assertEqual(0o750, stat.S_IMODE(path.parent.stat().st_mode))

    def test_failure_removes_temporary_and_preserves_previous(self):
        for point in ('dump', 'file-sync', 'replace', 'directory-sync'):
            with self.subTest(point=point), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'task.json'
                write(path, receipt())
                previous = path.read_bytes()
                real_sync = os.fsync

                def sync(fd):
                    is_dir = stat.S_ISDIR(os.fstat(fd).st_mode)
                    if is_dir == (point == 'directory-sync'):
                        raise OSError('injected sync failure')
                    return real_sync(fd)

                target = {'dump': 'json.dump', 'replace': 'os.replace'}.get(point, 'os.fsync')
                with patch(target, side_effect=sync if target == 'os.fsync' else OSError('injected failure')):
                    with self.assertRaises(OSError):
                        write(path, receipt(keep='1'))
                self.assertEqual([path], list(path.parent.iterdir()))
                self.assertEqual(receipt(keep='1') if point == 'directory-sync' else json.loads(previous),
                                 json.loads(path.read_text()))

    def test_shell_checkpoint_and_capture_retries(self):
        script = r'''
source "$1/lib/workgrove/teardown.sh"
# Replace only external effects; keep checkpoint and capture orchestration.
teardown_control() { echo "$1" >>"$LOG"; }
teardown_interpreter() {
  if [[ $* == *commands.py* ]]; then printf 'null\n'; else "$PYTHON" "$@"; fi
}
teardown_commands_stop() { :; }
die() { echo "$*" >&2; exit 1; }
WT_TEARDOWN_FILE="$2/task.json"
WT_TEARDOWN_JSON='{"generation":"g","stage":"git_removed","self":""}'
WG_VERSION_ROOT=$1 WG_TEARDOWN_CLOSE_PHASE=1 WG_TEARDOWN_ORIGIN_PID=$$
teardown_save close_requested
teardown_save close_requested
teardown_commands_capture 1 start
[[ $(jq -r .stage "$WT_TEARDOWN_FILE") == close_requested ]]
'''
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'control'
            result = subprocess.run(['bash', '-c', script, 'test', str(ROOT), directory],
                                    env=dict(os.environ, PYTHON=sys.executable, LOG=str(log)),
                                    text=True, capture_output=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(['acquire', 'release'] * 3, log.read_text().splitlines())


if __name__ == '__main__':
    unittest.main()
