#!/usr/bin/env bash
# Compare the portable hook events with agent-notify's event dispatch.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
python3 - "$REPO" <<'PY'
import json
from pathlib import Path
import re
import sys

repo = Path(sys.argv[1])
source = (repo / 'bin/agent-notify').read_text()
dispatch = source.split('case $event in', 1)[1].split('\nesac', 1)[0]
handled = set()
for pattern in re.findall(r'^  ([A-Za-z][A-Za-z|]*)\)', dispatch, re.M):
    handled.update(pattern.split('|'))
assert handled, 'agent-notify event dispatch is empty'
wired = set()
for name in ('.claude/settings.base.json', '.codex/hooks.base.json'):
    hooks = json.loads((repo / 'home' / name).read_text())['hooks']
    events = set()
    for event, groups in hooks.items():
        for group in groups:
            for hook in group['hooks']:
                command = hook.get('command', '')
                if 'agent-notify' in command:
                    assert command.endswith(' ~/.local/bin/agent-notify'), (name, event, command)
                    events.add(event)
    assert events, f'{name}: no agent-notify hooks'
    assert events <= handled, f'{name}: unhandled events: {events - handled}'
    wired.update(events)
assert wired == handled, f'agent-notify events without hooks: {handled - wired}'
print('PASS: both base files use the explicit helper path and match agent-notify events')
PY
