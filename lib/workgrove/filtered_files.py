"""Preserve raw filtered-file bytes that Git status can hide."""
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
        if stage != b'0' or not re.fullmatch(rb'[0-9a-f]{40}([0-9a-f]{24})?', oid):
            raise ValueError('unmerged or invalid index')
        entries[name] = (mode.decode(), oid.decode())
    attrs = records(directory + '/attrs')
    if len(attrs) % 3:
        raise ValueError('incomplete attributes')
    ambiguous = set()
    for record in records(directory + '/filters'):
        key, value = record.split(b'\n', 1)
        match = re.fullmatch(rb'filter\.(unset|unspecified)\.(clean|process)', key)
        if not match:
            raise ValueError('invalid filter configuration')
        if value:
            ambiguous.add(match.group(1))
    selected = set()
    seen = set()
    for offset in range(0, len(attrs), 3):
        raw, key, value = attrs[offset:offset + 3]
        name = path_name(raw)
        if key != b'filter' or name not in entries or name in seen:
            raise ValueError('invalid attributes')
        seen.add(name)
        if (value not in (b'unspecified', b'unset') or value in ambiguous) and entries[name][0] in ('100644', '100755'):
            selected.add(name)
    if seen != set(entries):
        raise ValueError('incomplete tracked attributes')
    baseline = metadata.get('filtered_files', {})
    if not isinstance(baseline, dict):
        raise ValueError('invalid filtered-file snapshot')
    for name, digest in baseline.items():
        path_name(name.encode('utf-8'))
        if not isinstance(digest, str) or not re.fullmatch(r'F[0-9a-f]{64}', digest):
            raise ValueError('invalid filtered-file fingerprint')
        selected.add(name)
    return {name: entries.get(name) for name in sorted(selected)}


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
        for oid in sorted({entry[1] for entry in selected.values() if entry and entry[0] in ('100644', '100755')}):
            print(oid)
        return
    if operation == 'capture':
        snapshot = {}
        for name in selected:
            digest = fingerprint(os.path.join(checkout, name))
            if digest and digest.startswith('F'):
                snapshot[name] = digest
        print(json.dumps(snapshot, ensure_ascii=True, separators=(',', ':')))
        return
    if metadata.get('filtered_status', 'complete') != 'complete':
        raise ValueError('filtered-file snapshot is incomplete')
    blobs = blob_hashes(directory + '/blobs')
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
        target = os.path.join(checkout, name)
        actual = fingerprint(target)
        if actual is None or actual in (baseline.get(name), setup.get(name)):
            continue
        if entry and entry[0] in ('100644', '100755') and actual == blobs[entry[1]]:
            continue
        surviving = os.path.join(repo, name)
        resolved = os.path.realpath(surviving)
        if os.path.commonpath((os.path.realpath(checkout), resolved)) != os.path.realpath(checkout):
            if actual == fingerprint(surviving):
                continue
        failures.append(name)
    if failures:
        raise ValueError('raw filtered files lack a surviving copy: ' + ', '.join(failures))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
        sys.exit('wt: ' + str(error))
