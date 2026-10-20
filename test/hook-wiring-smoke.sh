#!/usr/bin/env bash
# Compare each provider's portable hook events with agent-notify's event dispatch.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
python3 - "$REPO" <<'PY'
import copy
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
# Each provider lacks the events that only the other provider emits.
unsupported = {
    '.claude/settings.base.json': {'Interrupt'},
    '.codex/hooks.base.json': {'Notification', 'StopFailure'},
}


def check_provider(name, hooks):
    events = set()
    for event, groups in hooks.items():
        for group in groups:
            for hook in group['hooks']:
                command = hook.get('command', '')
                if 'agent-notify' in command:
                    assert command.endswith(' ~/.local/bin/agent-notify'), (name, event, command)
                    events.add(event)
    expected = handled - unsupported[name]
    assert events == expected, (name, f'missing: {expected - events}; unexpected: {events - expected}')
    return events


wired = set()
providers = {}
for name in unsupported:
    hooks = json.loads((repo / 'home' / name).read_text())['hooks']
    providers[name] = hooks
    wired.update(check_provider(name, hooks))
assert wired == handled, f'agent-notify events without hooks: {handled - wired}'
# A shared event must remain required in each provider independently.
shared = set.intersection(*(handled - excluded for excluded in unsupported.values()))
assert shared, 'no shared events to check'
for name, hooks in providers.items():
    for event in shared:
        missing = copy.deepcopy(hooks)
        del missing[event]
        try:
            check_provider(name, missing)
        except AssertionError:
            continue
        raise AssertionError(f'{name}: deleting {event} still passes')
print('PASS: each provider uses the explicit helper path and matches agent-notify events')
print('PASS: deleting any shared event from either provider fails the cross-check')
PY
