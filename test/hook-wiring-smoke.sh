#!/usr/bin/env bash
# Check guard wiring and the retired notification hook's compatibility contract.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
python3 - "$REPO" <<'PY'
import copy
import json
from pathlib import Path
import os
import subprocess
import tempfile
import sys

repo = Path(sys.argv[1])
source = (repo / 'bin/agent-notify').read_text()
# Check source before execution so an older implementation cannot post a real banner.
assert 'osascript' not in source, 'agent-notify can still post notifications'
assert 'WT_COMPAT' in source, 'agent-notify needs a retirement condition'
policy = json.loads((repo / 'lib/workgrove/agent-config-policy.json').read_text())
assert policy['retired_hook_commands'] == {
    f'AGENT_NOTIFY_SOURCE={provider} {helper}': ''
    for provider in ("'Claude Code'", 'Codex')
    for helper in ('agent-notify', '~/.local/bin/agent-notify')
}, 'retirement must cover exactly four commands without replacements'
with tempfile.TemporaryDirectory() as scratch:
    home = Path(scratch)
    for shell in ('/bin/sh', '/bin/bash'):
        for event in ('UserPromptSubmit', 'PermissionRequest', 'Notification', 'Stop',
                      'StopFailure', 'Interrupt', 'SessionEnd', 'Unknown'):
            payload = json.dumps({'hook_event_name': event, 'session_id': 'retired'}) * 8192
            result = subprocess.run([shell, str(repo / 'bin/agent-notify')], input=payload,
                                    text=True, capture_output=True, timeout=10,
                                    env={'PATH': os.environ['PATH'], 'HOME': scratch})
            assert (result.returncode, result.stdout, result.stderr) == (0, '', ''), result
            assert not list(home.iterdir()), 'agent-notify wrote state'
    # The hook also works without HOME or a library and consumes the entire payload.
    with tempfile.TemporaryFile() as stream:
        stream.write(b'payload' * 65536)
        stream.seek(0)
        result = subprocess.run(['/bin/sh', str(repo / 'bin/agent-notify')], stdin=stream,
                                capture_output=True, timeout=10, env={'PATH': os.environ['PATH']})
        assert (result.returncode, result.stdout, result.stderr) == (0, b'', b''), result
        assert stream.read() == b'', 'agent-notify left payload unread'


def check_guard(name, hooks):
    expected = ('^Bash$', '~/.local/bin/github-guard --codex') if name.startswith('.codex/') else (
        'Bash', '~/.local/bin/github-guard')
    guards = [(event, group.get('matcher'), hook) for event, groups in hooks.items()
              for group in groups for hook in group['hooks']
              if 'github-guard' in hook.get('command', '')]
    assert guards == [('PreToolUse', expected[0], {
        'type': 'command', 'command': expected[1], 'timeout': 30})], (name, guards)


for name in ('.claude/settings.base.json', '.codex/hooks.base.json'):
    hooks = json.loads((repo / 'home' / name).read_text())['hooks']
    assert set(hooks) == {'PreToolUse'}, (name, 'retired lifecycle events remain')
    check_guard(name, hooks)
    missing = copy.deepcopy(hooks)
    del missing['PreToolUse']
    try:
        check_guard(name, missing)
    except AssertionError:
        pass
    else:
        raise AssertionError(f'{name}: deleting the guard still passes')
print('PASS: the compatibility hook drains input without output or state')
print('PASS: each provider retains its synchronous Bash guard without notification events')
PY
