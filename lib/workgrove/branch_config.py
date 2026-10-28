"""Remove frozen task configuration with recoverable, private Git lock ownership."""
import base64
import json
import os
import re
import stat
import subprocess
import sys


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def entries(path, branch):
    result = subprocess.run(['git', 'config', '--no-includes', '--null', '--file', path,
                             '--get-regexp', '^' + re.escape('branch.' + branch + '.') + '[a-z][a-z0-9-]*$'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in (0, 1):
        raise ValueError('cannot inspect local branch configuration')
    return base64.b64encode(result.stdout).decode('ascii')


def process_identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'stat='],
                            env=dict(os.environ, LC_ALL='C'), stdout=subprocess.PIPE, text=True)
    if result.returncode not in (0, 1):
        raise ValueError('cannot inspect branch cleanup lock owner')
    if not result.stdout.strip():
        return None
    start, state = result.stdout.strip().rsplit(None, 1)
    return None if state.startswith('Z') else start


def file_identity(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('unexpected branch cleanup lock type')
    return [info.st_dev, info.st_ino]


class OwnedLocks:
    def __init__(self, repo, branch, generation):
        self.git_dir = os.path.join(repo, '.git')
        self.directory = os.path.join(self.git_dir, 'wt', 'teardown', branch[3:] + '.branch-locks')
        self.owner_file = os.path.join(self.directory, 'owner.json')
        self.generation = generation
        self.paths = {'ref': os.path.join(self.git_dir, 'refs', 'heads', branch + '.lock'),
                      'config': os.path.join(self.git_dir, 'config.lock')}
        self.record = None

    def recover(self):
        if not os.path.lexists(self.directory):
            return
        if os.path.islink(self.directory) or not os.path.isdir(self.directory):
            raise ValueError('unexpected branch cleanup ownership directory')
        if os.path.lexists(self.owner_file):
            if not file_identity(self.owner_file):
                raise ValueError('invalid branch cleanup ownership record')
            with open(self.owner_file) as source:
                record = json.load(source)
            if not isinstance(record, dict):
                raise ValueError('invalid branch cleanup ownership record')
            if record.get('generation') != self.generation or type(record.get('pid')) is not int:
                raise ValueError('branch cleanup lock generation changed')
            if not isinstance(record.get('start'), str) or not record['start']:
                raise ValueError('invalid branch cleanup lock owner')
            if not isinstance(record.get('boot'), str) or not record['boot']:
                raise ValueError('invalid branch cleanup boot identity')
            boot = process_identity(1)
            if not boot:
                raise ValueError('cannot identify the current boot')
            if boot == record['boot'] and process_identity(record['pid']) == record['start']:
                raise ValueError('branch configuration cleanup is still running')
            identities = record.get('identities')
            if not isinstance(identities, dict) or set(identities) != set(self.paths):
                raise ValueError('invalid branch cleanup lock identities')
            for key, path in self.paths.items():
                expected = identities[key]
                if not isinstance(expected, list) or len(expected) != 2 or any(type(v) is not int for v in expected):
                    raise ValueError('invalid branch cleanup lock identity')
                anchor = os.path.join(self.directory, key)
                anchored = file_identity(anchor)
                actual = file_identity(path)
                if anchored is None and actual is None:
                    continue
                if anchored != expected:
                    raise ValueError('branch cleanup lock anchor changed')
                if actual is not None and actual != expected:
                    raise ValueError('another Git command owns the remaining lock')
            for key, path in self.paths.items():
                if file_identity(path) is not None:
                    os.unlink(path)
                    sync_directory(os.path.dirname(path))
        elif any(os.path.lexists(path) for path in self.paths.values()):
            raise ValueError('unknown Git lock blocks branch configuration cleanup')
        self.remove_private()

    def remove_private(self):
        for name in os.listdir(self.directory):
            if name not in ('ref', 'config', 'owner.json', 'owner.tmp', 'edited', 'edited.lock'):
                raise ValueError('unexpected branch cleanup ownership file')
            path = os.path.join(self.directory, name)
            file_identity(path)
            os.unlink(path)
        os.rmdir(self.directory)
        sync_directory(os.path.dirname(self.directory))

    def acquire(self):
        self.recover()
        start = process_identity(os.getpid())
        boot = process_identity(1)
        if not start or not boot:
            raise ValueError('cannot identify branch cleanup process and boot')
        os.makedirs(os.path.dirname(self.directory), mode=0o700, exist_ok=True)
        os.mkdir(self.directory, 0o700)
        identities = {}
        for key, path in self.paths.items():
            os.makedirs(os.path.dirname(path), exist_ok=True)
            anchor = os.path.join(self.directory, key)
            fd = os.open(anchor, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.fsync(fd)
            os.close(fd)
            identities[key] = file_identity(anchor)
        self.record = dict(generation=self.generation, pid=os.getpid(), start=start, boot=boot, identities=identities)
        with open(os.path.join(self.directory, 'owner.tmp'), 'x') as output:
            json.dump(self.record, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(os.path.join(self.directory, 'owner.tmp'), self.owner_file)
        sync_directory(self.directory)
        sync_directory(os.path.dirname(self.directory))
        for key, path in self.paths.items():
            os.link(os.path.join(self.directory, key), path)
            sync_directory(os.path.dirname(path))

    def release(self):
        if self.record is None:
            return
        for key, path in self.paths.items():
            actual = file_identity(path)
            if actual is not None:
                if actual != self.record['identities'][key]:
                    raise ValueError('Git lock ownership changed during branch cleanup')
                os.unlink(path)
                sync_directory(os.path.dirname(path))
        self.remove_private()


def main():
    operation, repo, branch = sys.argv[1:4]
    if not re.fullmatch(r'wt/[a-z0-9][a-z0-9_-]{0,62}', branch):
        raise ValueError('invalid task branch')
    path = os.path.join(repo, '.git', 'config')
    if operation == 'snapshot':
        print(json.dumps(entries(path, branch)))
        return
    expected = json.loads(sys.argv[4])
    if expected is not None and not isinstance(expected, str):
        raise ValueError('invalid branch configuration snapshot')
    generation = sys.argv[5] if len(sys.argv) > 5 else 'legacy'
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', generation):
        raise ValueError('invalid branch cleanup generation')
    locks = OwnedLocks(repo, branch, generation)
    if operation == 'recover':
        locks.recover()
        return
    if operation != 'remove':
        raise ValueError('invalid branch cleanup operation')
    try:
        locks.acquire()
        result = subprocess.run(['git', '-C', repo, 'show-ref', '--verify', '--quiet', 'refs/heads/' + branch])
        if result.returncode != 1:
            raise ValueError('task branch reappeared or is unreadable; kept its configuration')
        remove_config(path, branch, expected, locks)
    finally:
        locks.release()


def remove_config(path, branch, expected, locks):
    current = entries(path, branch)
    if not current:
        return
    if expected is None or current != expected:
        raise ValueError('local task branch configuration changed; cleanup remains pending')
    with open(path, 'rb') as source:
        before = source.read()
        mode = os.fstat(source.fileno()).st_mode & 0o777
    temporary = os.path.join(locks.directory, 'edited')
    with open(temporary, 'xb') as output:
        output.write(before)
    subprocess.run(['git', 'config', '--no-includes', '--file', temporary,
                    '--remove-section', 'branch.' + branch], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with open(temporary, 'rb') as source:
        after = source.read()
    if entries(temporary, branch):
        raise ValueError('branch configuration removal is incomplete')
    with open(path, 'rb') as source:
        if source.read() != before:
            raise ValueError('Git configuration changed outside its lock')
    fd = os.open(os.path.join(locks.directory, 'config'), os.O_WRONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'wb') as output:
        if file_identity(locks.paths['config']) != locks.record['identities']['config']:
            raise ValueError('Git configuration lock changed')
        info = os.fstat(output.fileno())
        if [info.st_dev, info.st_ino] != locks.record['identities']['config']:
            raise ValueError('Git configuration lock descriptor changed')
        os.ftruncate(output.fileno(), 0)
        os.fchmod(output.fileno(), mode)
        output.write(after)
        output.flush()
        os.fsync(output.fileno())
    os.replace(locks.paths['config'], path)
    sync_directory(os.path.dirname(path))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit('wt: ' + str(error))
