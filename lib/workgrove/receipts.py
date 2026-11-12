"""Own teardown receipt identity, recovery shape, and generation replacement policy."""
import json
import os
import re
import sys
import tempfile

STAGES = ('prepared', 'worktree_removed', 'branch_config_removing', 'sidecars_removing',
          'git_removed', 'close_requested', 'complete')


def decode(raw):
    """Read one JSON record without changing its stored bytes."""
    def invalid_constant(value):
        raise ValueError('invalid JSON constant: ' + value)
    data = json.loads(raw, parse_constant=invalid_constant)
    # Python accepts unpaired surrogates that jq can reject, including in optional fields.
    json.dumps(data, ensure_ascii=False).encode('utf-8')
    return data


def validate(data, repo, name, path):
    """Check the recovery boundary; optional evidence stays with its live consumer."""
    if not isinstance(data, dict):
        raise ValueError('invalid teardown receipt')
    expected = dict(repo=repo, name=name, path=path, branch='wt/' + name)
    if any(data.get(key) != value for key, value in expected.items()):
        raise ValueError('invalid teardown receipt')
    head = data.get('head')
    if not isinstance(head, str) or re.search(r'^[0-9a-f]{40}([0-9a-f]{24})?$', head) is None:
        raise ValueError('invalid teardown receipt')
    if any(data.get(key) not in ('0', '1') for key in ('keep', 'native', 'remote')):
        raise ValueError('invalid teardown receipt')
    if data.get('stage') not in STAGES:
        raise ValueError('invalid teardown receipt')


def validate_replacement(old, data):
    """Permit retries and new prepared generations after completed cleanup."""
    if old.get('generation') != data.get('generation') and not (
            old.get('stage') == 'complete' and data['stage'] == 'prepared'):
        sys.exit('wt: cleanup generation changed; kept the newer receipt')


def write(path, data):
    """Replace a checkpoint atomically, then synchronize the containing directory."""
    # Historical writes did not apply recovery shape checks or a stage-transition graph.
    if os.path.exists(path):
        with open(path) as previous:
            old = json.load(previous)
        validate_replacement(old, data)
    parent = os.path.dirname(path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    operation, *arguments = sys.argv[1:]
    if operation == 'write':
        path, = arguments
        write(path, json.load(sys.stdin))
    elif operation == 'validate':
        repo, name, path = arguments
        try:
            validate(decode(sys.stdin.read()), repo, name, path)
        except (ValueError, TypeError):
            return 1
    else:
        raise ValueError('unknown receipt operation: ' + operation)
    return 0


if __name__ == '__main__':
    sys.exit(main())
