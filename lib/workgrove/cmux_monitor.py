"""Identify a task monitor for the existing command cancellation path."""
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import sys
import uuid

spec = importlib.util.spec_from_file_location('workgrove_commands', Path(__file__).with_name('commands.py'))
commands = importlib.util.module_from_spec(spec)
spec.loader.exec_module(commands)


def identifier(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value.lower():
        raise ValueError('invalid monitor identifier')
    return value.lower()


class Processes(commands.Processes):
    def image(self, pid):
        library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        path = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, path, len(path)) <= 0:
            raise OSError(ctypes.get_errno() or errno.EIO, 'cannot identify monitor executable')
        return os.fsdecode(path.value)

    def arguments(self, pid):
        library = ctypes.CDLL(None, use_errno=True)
        library.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                                   ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        library.sysctl.restype = ctypes.c_int
        mib = (ctypes.c_int * 3)(1, 49, pid)
        size = ctypes.c_size_t()
        if library.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not 4 < size.value <= 1_048_576:
            raise ValueError('cannot read monitor arguments')
        buffer = ctypes.create_string_buffer(size.value)
        if library.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
            raise ValueError('cannot read monitor arguments')
        return parse_arguments(buffer.raw[:size.value])


def parse_arguments(data):
    if len(data) < 5:
        raise ValueError('incomplete monitor arguments')
    count = struct.unpack_from('=i', data)[0]
    if not 10 <= count <= 18:
        raise ValueError('unexpected monitor arguments')
    offset = data.index(b'\0', 4) + 1
    while offset < len(data) and data[offset] == 0:
        offset += 1
    result = []
    for _ in range(count):
        end = data.index(b'\0', offset)
        result.append(data[offset:end].decode('utf-8'))
        offset = end + 1
    return result


def binding(evidence, row, provider, monitor):
    sample, tree = evidence['top'], evidence['tree']
    if sample.get('include_processes') is not True:
        raise ValueError('monitor needs a native process sample')
    rows = [r for w in sample['windows'] for r in w['workspaces'] if identifier(r['id']) == row]
    if len(rows) != 1:
        raise ValueError('ambiguous monitor row')
    current = rows[0]
    tags = [tag for tag in current['tags'] if tag.get('key', '').startswith('codex.')
            and provider in tag.get('root_pids', [])]
    if len(tags) != 1 or tags[0].get('root_pids') != [provider] or tags[0].get('pid') != provider:
        raise ValueError('monitor has no unique provider tag')
    tag = tags[0]
    session = identifier(tag['key'][6:])
    if tag.get('ref', '').lower() != f'workspace:{row}:tag:codex.{session}':
        raise ValueError('monitor tag belongs to another row')
    surfaces = [s for p in current['panes'] for s in p['surfaces']
                if provider in s['resources']['pids']]
    if len(surfaces) != 1 or surfaces[0].get('type') != 'terminal':
        raise ValueError('monitor has no unique provider surface')
    surface = surfaces[0]
    if (monitor not in surface['resources']['pids'] or surface['resources'].get('missing_pids', [])
            or monitor not in surface['cmux_process_pids']):
        raise ValueError('monitor is not attributed to the provider surface')
    tty = surface.get('tty')
    if not isinstance(tty, str) or not re.fullmatch(r'ttys[0-9]+', tty.removeprefix('/dev/')):
        raise ValueError('monitor terminal identity is unavailable')
    matches = [(r, s) for w in tree['windows'] for r in w['workspaces'] for p in r['panes']
               for s in p['surfaces'] if isinstance(s.get('tty'), str)
               and s['tty'].removeprefix('/dev/') == tty.removeprefix('/dev/')]
    if len(matches) != 1:
        raise ValueError('ambiguous monitor terminal')
    owner, terminal = matches[0]
    if identifier(owner['id']) != row or terminal.get('type') != 'terminal':
        raise ValueError('monitor terminal belongs to another row')
    return session, identifier(terminal['id'])


def validate(backend, evidence, row, task, provider, monitor, cli):
    if backend.platform != 'darwin' or min(provider, monitor) <= 1:
        raise ValueError('unsupported monitor process')
    row = identifier(row)
    session, surface = binding(evidence, row, provider, monitor)
    root, before = backend.identity(provider), backend.identity(monitor)
    if root is None or before is None or root['zombie'] or before['zombie'] or before['ppid'] != 1:
        raise ValueError('detached monitor identity is unavailable')
    executable = str(Path(cli).resolve(strict=True))
    if backend.image(monitor) != executable:
        raise ValueError('monitor executable differs from the cmux CLI')
    arguments = backend.arguments(monitor)
    if arguments[:4] != [executable, 'hooks', 'codex', 'monitor'] or len(arguments) % 2:
        raise ValueError('unexpected monitor invocation')
    keys, values = arguments[4::2], arguments[5::2]
    required = {'--workspace', '--surface', '--session'}
    allowed = required | {'--turn', '--transcript', '--cwd', '--lease'}
    if len(set(keys)) != len(keys) or not required <= set(keys) <= allowed or any(not v for v in values):
        raise ValueError('unexpected monitor options')
    options = dict(zip(keys, values))
    if (identifier(options['--workspace']) != row or identifier(options['--surface']) != surface
            or identifier(options['--session']) != session or options.get('--cwd', task) != task):
        raise ValueError('monitor targets another task')
    if (backend.arguments(monitor) != arguments or backend.image(monitor) != executable
            or backend.identity(monitor) != before or backend.identity(provider) != root):
        raise ValueError('monitor evidence changed during validation')
    return dict(pid=monitor, birth=before['birth'], comm=before['comm'], role='command')


def main():
    row, task, provider, monitor, cli = sys.argv[1:]
    print(json.dumps(validate(Processes(), json.load(sys.stdin), row, task, int(provider), int(monitor), cli)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError):
        sys.exit(1)
