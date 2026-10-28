"""Preserve tracked working bytes independently of Git's cleaning and stat cache."""
import hashlib
import json
import os
import re
import stat
import sys


def path_name(raw):
    value = raw.decode('utf-8')
    if not value or value.startswith('/') or any(p in ('', '.', '..') for p in value.split('/')):
        raise ValueError('invalid tracked path')
    return value


def records(path):
    data = open(path, 'rb').read()
    if data and not data.endswith(b'\0'):
        raise ValueError('incomplete Git records')
    return data[:-1].split(b'\0') if data else []


def plan(directory, metadata):
    entries = {}
    for record in records(directory + '/index'):
        header, raw = record.split(b'\t', 1)
        mode, oid, stage = header.split(b' ')
        name = path_name(raw)
        if (stage != b'0' or mode not in (b'100644', b'100755', b'120000', b'160000')
                or not re.fullmatch(rb'[0-9a-f]{40}([0-9a-f]{24})?', oid) or name in entries):
            raise ValueError('unmerged or invalid index')
        entries[name] = (mode.decode(), oid.decode())
    selected = set(entries)
    baseline = metadata.get('filtered_files', {})
    if not isinstance(baseline, dict):
        raise ValueError('invalid filtered-file snapshot')
    for name, digest in baseline.items():
        path_name(name.encode('utf-8'))
        if not isinstance(digest, str) or not re.fullmatch(r'[FL][0-9a-f]{64}', digest):
            raise ValueError('invalid filtered-file fingerprint')
        selected.add(name)
    return {name: entries.get(name) for name in sorted(selected)}


def index_fingerprint(entry, actual, blobs):
    if not entry or entry[0] == '160000':
        return None
    digest = blobs[entry[1]]
    if actual and actual.startswith('L'):
        return 'L' + digest[1:] if entry[0] == '120000' else None
    return digest


def check_private_modules(repo, checkout):
    # Deinitialized and removed gitlinks can retain unique objects in the task registration.
    registrations = os.path.join(repo, '.git', 'worktrees')
    if not os.path.lexists(registrations):
        return
    if os.path.islink(registrations) or not os.path.isdir(registrations):
        raise ValueError('invalid Git worktree registrations')
    target = os.path.abspath(os.path.join(checkout, '.git'))
    found = 0
    with os.scandir(registrations) as entries:
        for entry in entries:
            if not entry.is_dir(follow_symlinks=False):
                raise ValueError('invalid Git worktree registration')
            marker = os.path.join(entry.path, 'gitdir')
            fd = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    raise ValueError('invalid Git worktree pointer')
                pointer = source.read(1024 * 1024 + 1)
            if (len(pointer) > 1024 * 1024 or len(pointer) <= 1 or b'\0' in pointer
                    or not pointer.endswith(b'\n') or b'\n' in pointer[:-1]
                    or pointer[:-1].rstrip() != pointer[:-1]):
                raise ValueError('invalid Git worktree pointer')
            destination = os.path.abspath(os.path.join(entry.path, os.fsdecode(pointer[:-1])))
            if destination != target:
                continue
            found += 1
            modules = os.path.join(entry.path, 'modules')
            if not os.path.lexists(modules):
                continue
            if os.path.islink(modules) or not os.path.isdir(modules):
                raise ValueError('private submodule Git data requires independent preservation')
            with os.scandir(modules) as contents:
                if next(contents, None) is not None:
                    raise ValueError('private submodule Git data requires independent preservation')
    if found > 1:
        raise ValueError('ambiguous task Git registration')


def check_submodules(selected, checkout):
    for name, entry in selected.items():
        if not entry or entry[0] != '160000':
            continue
        path = os.path.join(checkout, name)
        if not os.path.lexists(path):
            continue
        if not os.path.islink(path) and os.path.isdir(path):
            with os.scandir(path) as contents:
                if next(contents, None) is None:
                    continue
        raise ValueError('initialized or nonempty submodule requires independent preservation: ' + name)


def fingerprint(path):
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(before.st_mode):
        return 'L' + hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError('unsupported filtered file type')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        opened = os.fstat(source.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError('filtered file changed while reading')
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
        after = os.fstat(source.fileno())
    if (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise ValueError('filtered file changed while reading')
    return 'F' + digest.hexdigest()


def blob_hashes(path):
    result = {}
    with open(path, 'rb') as source:
        while True:
            header = source.readline()
            if not header:
                break
            oid, kind, size = header.rstrip(b'\n').split(b' ')
            if kind != b'blob' or not size.isdigit():
                raise ValueError('invalid index blob')
            remaining = int(size)
            digest = hashlib.sha256()
            while remaining:
                chunk = source.read(min(remaining, 1024 * 1024))
                if not chunk:
                    raise ValueError('incomplete index blob')
                digest.update(chunk)
                remaining -= len(chunk)
            if source.read(1) != b'\n':
                raise ValueError('incomplete index blob record')
            result[oid.decode()] = 'F' + digest.hexdigest()
    return result


def main():
    if sys.argv[1] == 'admin':
        check_private_modules(*sys.argv[2:])
        return
    operation, directory, checkout, repo, sidecar = sys.argv[1:]
    try:
        os.lstat(sidecar)
    except FileNotFoundError:
        metadata = {}
    else:
        metadata = json.load(open(sidecar))
    if not isinstance(metadata, dict):
        raise ValueError('invalid task metadata')
    selected = plan(directory, metadata)
    if operation == 'oids':
        for oid in sorted({entry[1] for entry in selected.values() if entry and entry[0] != '160000'}):
            print(oid)
        return
    blobs = blob_hashes(directory + '/blobs')
    if operation == 'capture':
        snapshot = {}
        for name, entry in selected.items():
            if entry and entry[0] == '160000':
                continue
            digest = fingerprint(os.path.join(checkout, name))
            if digest and digest != index_fingerprint(entry, digest, blobs):
                snapshot[name] = digest
        print(json.dumps(snapshot, ensure_ascii=True, separators=(',', ':')))
        return
    if metadata.get('filtered_status', 'complete') != 'complete':
        raise ValueError('filtered-file snapshot is incomplete')
    if operation != 'check':
        raise ValueError('invalid tracked-file operation')
    check_submodules(selected, checkout)
    baseline = metadata.get('filtered_files', {})
    setup = {}
    setup_records = metadata.get('setup', [])
    if isinstance(setup_records, str):
        setup_records = setup_records.splitlines()
    if not isinstance(setup_records, list) or any(not isinstance(record, str) for record in setup_records):
        raise ValueError('invalid setup snapshot')
    for record in setup_records:
        name, _, digest = record.rpartition(':')
        setup[name] = digest if digest.startswith('L') else 'F' + digest
    failures = []
    for name, entry in selected.items():
        if entry and entry[0] == '160000':
            continue
        target = os.path.join(checkout, name)
        actual = fingerprint(target)
        if actual is None or actual in (baseline.get(name), setup.get(name)):
            continue
        if actual == index_fingerprint(entry, actual, blobs):
            continue
        surviving = os.path.join(repo, name)
        resolved = os.path.realpath(surviving)
        if os.path.commonpath((os.path.realpath(checkout), resolved)) != os.path.realpath(checkout):
            if actual == fingerprint(surviving):
                continue
        failures.append(name)
    if failures:
        raise ValueError('raw tracked files lack a surviving copy: ' + ', '.join(failures))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
        sys.exit('wt: ' + str(error))
