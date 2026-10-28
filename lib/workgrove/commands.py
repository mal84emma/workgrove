"""Record task-owned commands and stop them without signaling replacement processes."""
import ctypes
import errno
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


class Processes:
    platform = sys.platform

    def boot(self):
        if sys.platform == 'darwin':
            return subprocess.check_output(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'], text=True).strip()
        return Path('/proc/sys/kernel/random/boot_id').read_text().strip()

    def table(self):
        result = {}
        listing = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,comm='], env=dict(os.environ, LC_ALL='C'), text=True)
        for line in listing.splitlines():
            fields = line.split(None, 7)
            if len(fields) != 8 or not fields[0].isdigit() or not fields[1].isdigit():
                raise ValueError('cannot parse task process ancestry')
            pid = int(fields[0])
            if pid in result:
                raise ValueError('duplicate task process sample')
            result[pid] = dict(ppid=int(fields[1]), start=' '.join(fields[2:7]), comm=fields[7])
        return result

    def identity(self, pid):
        try:
            if sys.platform == 'darwin':
                class BSDInfo(ctypes.Structure):
                    _fields_ = [(name, ctypes.c_uint32) for name in (
                        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
                    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
                    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
                    _fields_ += [('nice', ctypes.c_int32), ('seconds', ctypes.c_uint64), ('microseconds', ctypes.c_uint64)]
                library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
                library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
                library.proc_pidinfo.restype = ctypes.c_int
                info = BSDInfo()
                size = library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
                if size != ctypes.sizeof(info):
                    error = ctypes.get_errno()
                    if error == errno.ESRCH:
                        return None
                    raise OSError(error or errno.EIO, 'cannot read kernel process identity')
                if info.pid != pid or not info.seconds:
                    raise ValueError('invalid kernel process identity')
                return dict(pid=pid, ppid=info.ppid, birth=f'bsd:{info.seconds}:{info.microseconds}',
                            comm=os.fsdecode(info.name or info.comm), zombie=info.status == 5)
            data = Path(f'/proc/{pid}/stat').read_bytes()
            end = data.rfind(b') ')
            fields = data[end + 2:].split()
            if end < 0 or len(fields) < 20 or not fields[19].isdigit():
                raise ValueError('invalid kernel process identity')
            return dict(pid=pid, ppid=int(fields[1]), birth='ticks:' + fields[19].decode(),
                        comm=os.fsdecode(data[data.index(b'(') + 1:end]), zombie=fields[0] == b'Z')
        except (FileNotFoundError, ProcessLookupError):
            return None

    def send(self, pid, signum):
        os.kill(pid, signum)


def descends(pid, root, table):
    seen = set()
    while pid > 1 and pid not in seen:
        if pid == root:
            return True
        seen.add(pid)
        pid = table.get(pid, {}).get('ppid', 0)
    return False


def validate(manifest, generation):
    if (not isinstance(manifest, dict) or set(manifest) != {'version', 'generation', 'boot', 'platform', 'records'}
            or type(manifest.get('version')) is not int or manifest['version'] != 1
            or manifest.get('generation') != generation or not isinstance(manifest.get('boot'), str)
            or not re.fullmatch(r'[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', manifest['boot'])
            or manifest.get('platform') not in ('linux', 'darwin') or not isinstance(manifest.get('records'), list)):
        raise ValueError('invalid task command manifest')
    seen = set()
    for record in manifest['records']:
        if (not isinstance(record, dict) or set(record) != {'pid', 'birth', 'comm', 'role'}
                or type(record.get('pid')) is not int or record['pid'] <= 1
                or not isinstance(record.get('birth'), str) or not re.fullmatch(r'(bsd:[0-9]+:[0-9]+|ticks:[0-9]+)', record['birth'])
                or not isinstance(record.get('comm'), str) or not record['comm']
                or record.get('role') not in ('runtime', 'command')):
            raise ValueError('invalid task command identity')
        key = (record['pid'], record['birth'])
        if record['birth'].startswith('bsd:') != (manifest['platform'] == 'darwin'):
            raise ValueError('task command identity platform changed')
        if key in seen:
            raise ValueError('duplicate task command identity')
        seen.add(key)
    if not any(record['role'] == 'runtime' for record in manifest['records']):
        raise ValueError('task command manifest has no verified runtime')
    return manifest


def capture(backend, generation, provider, expected_start, origin, previous):
    table = backend.table()
    if provider not in table or table[provider]['start'].split() != expected_start.split():
        raise ValueError('verified provider identity changed before command capture')
    if not descends(origin, provider, table) or not descends(os.getppid(), origin, table):
        raise ValueError('cleanup caller does not belong to the verified provider')
    root_identity = backend.identity(provider)
    if root_identity is None:
        raise ValueError('verified provider disappeared during command capture')
    boot = backend.boot()
    if not boot:
        raise ValueError('cannot identify task command boot')
    records = {}
    if previous is not None:
        validate(previous, generation)
        if previous['platform'] != backend.platform:
            raise ValueError('task command platform changed before capture')
        if previous['boot'] == boot:
            records = {(r['pid'], r['birth']): r for r in previous['records']}
    runtime = {provider}
    provider_name = os.path.basename(table[provider]['comm']).lower()
    current = provider if origin == provider else table[origin]['ppid']
    while current != provider:
        if current not in table or current <= 1:
            raise ValueError('incomplete cleanup caller ancestry')
        if os.path.basename(table[current]['comm']).lstrip('-') not in ('bash', 'zsh', 'sh', 'dash', 'ksh'):
            runtime.add(current)
        current = table[current]['ppid']
    records[(provider, root_identity['birth'])] = {
        key: root_identity[key] for key in ('pid', 'birth', 'comm')}
    records[(provider, root_identity['birth'])]['role'] = 'runtime'
    for pid, sample in table.items():
        if not descends(pid, provider, table) or descends(pid, origin, table):
            continue
        if pid not in runtime and descends(origin, pid, table):
            continue
        actual = backend.identity(pid)
        if actual is None:
            continue
        if actual['ppid'] != sample['ppid']:
            raise ValueError('task process ancestry changed during capture')
        record = {key: actual[key] for key in ('pid', 'birth', 'comm')}
        helper = any(provider_name.startswith(name) and actual['comm'].lower().startswith(name)
                     for name in ('claude', 'codex'))
        record['role'] = 'runtime' if pid in runtime or helper else 'command'
        records[(pid, actual['birth'])] = record
    if backend.identity(provider) != root_identity:
        raise ValueError('verified provider changed during command capture')
    return validate(dict(version=1, generation=generation, boot=boot, platform=backend.platform,
                         records=list(records.values())), generation)


def live(backend, record):
    actual = backend.identity(record['pid'])
    if actual is None or actual['birth'] != record['birth']:
        return False
    if actual['comm'] != record['comm']:
        raise ValueError('task command executable changed; kept the process')
    return not actual['zombie']


def remaining(backend, manifest, generation, scope):
    validate(manifest, generation)
    if manifest['platform'] != backend.platform or scope not in ('commands', 'all'):
        raise ValueError('invalid task command platform or scope')
    if backend.boot() != manifest['boot']:
        return []
    return [r for r in manifest['records'] if (scope == 'all' or r['role'] == 'command') and live(backend, r)]


def stop(backend, manifest, generation, scope):
    for signum in (signal.SIGTERM, signal.SIGKILL):
        for record in remaining(backend, manifest, generation, scope):
            if live(backend, record):
                try:
                    backend.send(record['pid'], signum)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if not remaining(backend, manifest, generation, scope):
                return
            time.sleep(0.02)
    raise ValueError('task commands remain active; cleanup is pending')


def main():
    if sys.argv[1:] == ['probe']:
        backend = Processes()
        if not backend.boot() or backend.identity(os.getpid()) is None:
            raise ValueError('kernel task command identity is unavailable')
        return
    operation, generation, *arguments = sys.argv[1:]
    if not re.fullmatch(r'[A-Za-z0-9_-]+', generation):
        raise ValueError('invalid task command generation')
    manifest = json.load(sys.stdin)
    backend = Processes()
    if operation == 'capture':
        provider, expected_start, origin = arguments
        print(json.dumps(capture(backend, generation, int(provider), expected_start, int(origin), manifest), separators=(',', ':')))
    elif operation == 'stop':
        stop(backend, manifest, generation, arguments[0])
    elif operation == 'observe':
        if remaining(backend, manifest, generation, 'all'):
            raise ValueError('task runtime or commands remain active')
    elif operation == 'validate':
        validate(manifest, generation)
    else:
        raise ValueError('invalid task command operation')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit('wt: ' + str(error))
