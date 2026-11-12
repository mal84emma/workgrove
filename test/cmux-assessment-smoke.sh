#!/usr/bin/env bash
# Check ownership results against characterized native snapshots.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=lib/workgrove/common.sh
source "$REPO/lib/workgrove/common.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-cmux-assessment.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
python3 - "$ROOT" <<'PYCASES'
import copy
import json
import sys
from pathlib import Path

ROOT = Path(sys.argv[1])
CASES = []

def base():
    return dict(include_processes=True, coding_agents=[dict(resources=dict(pids=[100], process_count=1))],
                windows=[dict(workspaces=[dict(id='target', resources=dict(pids=[90, 100, 101], process_count=3,
                    missing_pids=[]), panes=[dict(surfaces=[dict(tty_process_pids=[90, 100, 101],
                        processes=[dict(kind='process', pid=p, ppid=q, children=[])
                                   for p, q in [(90, 1), (100, 90), (101, 100)]])])])])])

def add(name, change=None, mode='normal', declared='claude', raw=None):
    value = base()
    if change:
        change(value)
    CASES.append(dict(name=name, sample=raw if raw is not None else json.dumps(value),
                      mode=mode, declared=declared))

def row(x):
    return x['windows'][0]['workspaces'][0]

def surface(x):
    return row(x)['panes'][0]['surfaces'][0]

def assign(path, value):
    def change(x):
        for key in path[:-1]:
            x = x[key]
        x[path[-1]] = value
    return change

add('self')
add('busy-independent', mode='independent')
add('busy-unreadable', mode='unreadable')
add('unknown-root', mode='no-root')
add('unknown-start', mode='start-failed')
add('unknown-empty-start', mode='empty-start')
add('unknown-provider', mode='provider-failed')
add('unknown-command', mode='command-failed')
add('codex-unproved-launch', declared='codex', mode='launch-failed')
add('codex-proved-launch', declared='codex')
add('changed-provider', mode='changed-start')
for name, raw in [('malformed', '{'), ('empty', ''), ('null', 'null'), ('array', '[]'), ('boolean', 'true'),
                  ('string', '"x"'), ('multiple-documents', '{}\n{}')]:
    add(name, raw=raw)
for key, values in [('coding_agents', [None, {}, '', 1, False])]:
    for i, v in enumerate(values):
        add(f'{key}-type-{i}', assign([key], v))
for i, v in enumerate([None, '1', -1, False, {}, []]):
    add(f'agent-count-{i}', assign(['coding_agents', 0, 'resources', 'process_count'], v))
for i, v in enumerate([None, {}, '', [None], ['100'], [True], [0], [1], [-2], [2.5], [100, 100]]):
    def change(x, v=v):
        r = x['coding_agents'][0]['resources']
        r['pids'] = v
        r['process_count'] = len(v) if isinstance(v, list) else 1
    add(f'agent-pids-{i}', change)
add('agent-count-mismatch', assign(['coding_agents', 0, 'resources', 'process_count'], 2))
add('agent-fractional-count', assign(['coding_agents', 0, 'resources', 'process_count'], 1.5))
add('agent-missing-pids-ignored', assign(['coding_agents', 0, 'resources', 'missing_pids'], [444]))
for name, change in [
    ('missing-row', lambda x: x['windows'][0].update(workspaces=[])),
    ('duplicate-row', lambda x: x['windows'][0]['workspaces'].append(copy.deepcopy(row(x)))),
    ('wrong-windows', lambda x: x.update(windows=None)),
    ('wrong-resources', lambda x: row(x).update(resources=None)),
    ('row-count-mismatch', lambda x: row(x)['resources'].update(process_count=4)),
    ('row-missing-pids', lambda x: row(x)['resources'].update(missing_pids=[444])),
    ('row-missing-pids-string', lambda x: row(x)['resources'].update(missing_pids='')),
    ('row-missing-pids-object', lambda x: row(x)['resources'].update(missing_pids={})),
    ('row-null-missing-pids', lambda x: row(x)['resources'].update(missing_pids=None)),
]:
    add(name, change)
for i, v in enumerate([None, {}, '', [None], ['100'], [True], [0], [1], [-2], [2.5], [100, 100]]):
    def change(x, v=v):
        row(x)['resources'].update(pids=v, process_count=len(v) if isinstance(v, list) else 0)
    add(f'row-pids-{i}', change)
for field in ['panes']:
    for i, v in enumerate([None, {}, '']):
        add(f'{field}-type-{i}', lambda x, v=v: row(x).update(panes=v))
add('absent-panes', lambda x: row(x).pop('panes'), mode='all-live')
add('null-surfaces', lambda x: row(x)['panes'][0].update(surfaces=None))
for field in ['tty_process_pids', 'unattributed_tty_process_pids', 'tty_ownership_reasons']:
    for i, v in enumerate([None, '', 1, [], {}]):
        add(f'{field}-type-{i}', lambda x, field=field, v=v: surface(x).update({field: v}))
for i, v in enumerate([dict(pids=[], process_count=1), dict(pids=[333, 333], process_count=2),
                       dict(pids=[333], process_count=1, missing_pids=[444]),
                       dict(pids=[100], process_count=1), dict(pids=[333], process_count=1.5),
                       None, {}, dict(pids=[333], process_count=1, missing_pids={})]):
    add(f'unattributed-resources-{i}', lambda x, v=v: surface(x).update(unattributed_resources=v))
for name, values in [('zero', [0]), ('one', [1]), ('fraction', [2.5]), ('string', ['333']),
                     ('null', [None]), ('duplicate', [333, 333]), ('independent', [333])]:
    add('extra-' + name, lambda x, v=values: surface(x).update(unattributed_tty_process_pids=v))
add('reason-invalid-key', lambda x: surface(x).update(tty_ownership_reasons={'unknown': 'x'}))
add('reason-extra-key', lambda x: surface(x).update(tty_ownership_reasons={'333': 'x'}))
add('reason-attributed-key', lambda x: surface(x).update(tty_ownership_reasons={'90': 'x'}))
add('cross-row-idle', lambda x: x['coding_agents'][0]['resources'].update(pids=[444]))
add('cross-row-extra', lambda x: (x['coding_agents'][0]['resources'].update(pids=[444]),
                                surface(x).update(tty_process_pids=[333])))
add('cross-row-plus-self', lambda x: x['coding_agents'].append(dict(resources=dict(pids=[444], process_count=1))))
add('busy-second-provider', lambda x: x['coding_agents'][0]['resources'].update(pids=[100, 101], process_count=2), mode='independent')
add('agents-empty-idle', lambda x: x.update(coding_agents=[]))
add('agents-empty-extra', lambda x: (x.update(coding_agents=[]), surface(x).update(tty_process_pids=[333])))
add('agent-zero-idle', lambda x: x['coding_agents'][0]['resources'].update(pids=[], process_count=0))
add('agent-zero-extra', lambda x: (x['coding_agents'][0]['resources'].update(pids=[], process_count=0),
                                 surface(x).update(tty_process_pids=[333])))
add('empty-row-idle', lambda x: (x.update(coding_agents=[]), row(x)['resources'].update(pids=[], process_count=0), row(x).update(panes=[])))
for name, change in [
    ('not-included', lambda x: x.update(include_processes=False)),
    ('missing-node', lambda x: surface(x)['processes'].pop()),
    ('duplicate-node', lambda x: surface(x)['processes'].append(copy.deepcopy(surface(x)['processes'][0]))),
    ('wrong-kind', lambda x: surface(x)['processes'][0].update(kind='thread')),
    ('bad-ppid', lambda x: surface(x)['processes'][0].update(ppid='1')),
    ('self-cycle', lambda x: surface(x)['processes'][2].update(ppid=101)),
    ('cycle', lambda x: (surface(x)['processes'][0].update(ppid=101))),
    ('sibling', lambda x: surface(x)['processes'][2].update(ppid=90)),
    ('bad-children', lambda x: surface(x)['processes'][0].update(children='x')),
    ('bad-processes', lambda x: surface(x).update(processes=None)),
]:
    add('graph-' + name, change)
    add('graph-' + name + '-live', change, mode='all-live')
    def idle(x, change=change):
        change(x)
        x['coding_agents'] = []
    add('graph-' + name + '-idle', idle)
def monitor(x):
    row(x)['resources'].update(pids=[90, 100, 200])
    surface(x).update(tty_process_pids=[90, 100, 200])
    surface(x)['processes'][2].update(pid=200)
add('observer-proved', monitor, mode='observer', declared='codex')
add('observer-refused', monitor, mode='observer-refused', declared='codex')
# The earlier diagnostic must win even when later stages fail.
add('precedence-count-pids-row', lambda x: (x['coding_agents'][0]['resources'].update(process_count=-1, pids=None), x.update(windows=None)))
add('precedence-pids-row', lambda x: (x['coding_agents'][0]['resources'].update(pids=None), x.update(windows=None)))
add('precedence-row-extras', lambda x: (row(x)['resources'].update(missing_pids=[444]), surface(x).update(tty_process_pids='x')))
add('self-live', mode='all-live')
add('row-false-missing-pids', lambda x: row(x)['resources'].update(missing_pids=False))
add('extras-zero-missing-pids', lambda x: surface(x).update(unattributed_resources=dict(pids=[], process_count=0, missing_pids=0)))
add('null-surface', lambda x: row(x)['panes'][0].update(surfaces=[None]))
add('null-surface-live', lambda x: row(x)['panes'][0].update(surfaces=[None]), mode='all-live')
add('numeric-reason-key', lambda x: surface(x).update(tty_ownership_reasons={'9e1': 'root'}))
add('nested-processes', lambda x: surface(x).update(processes=[dict(kind='process', pid=90, ppid=1, children=[dict(kind='process', pid=100, ppid=90, children=[dict(kind='process', pid=101, ppid=100)])])]))
add('object-children', lambda x: surface(x)['processes'][0].update(children={}))
def chain_case(x, size):
    pids = [90, 100, 101] + list(range(1000, 1000 + size - 3))
    row(x)['resources'].update(pids=pids, process_count=len(pids))
    surface(x).update(tty_process_pids=pids, processes=[dict(kind='process', pid=p, ppid=q, children=[]) for p, q in zip(pids, [1] + pids[:-1])])
for size in (127, 128, 129):
    add('graph-depth-' + str(size), lambda x, size=size: chain_case(x, size))
# jq accepts a sequence of JSON documents. Preserve that existing boundary too.
by_name = {c['name']: c for c in CASES}
for first in ['self', 'agents-empty-idle', 'cross-row-extra', 'agent-count-0', 'row-missing-pids', 'graph-cycle', 'null']:
    for last in ['self', 'agents-empty-idle', 'cross-row-extra', 'graph-not-included']:
        add('stream-' + first + '-then-' + last,
            raw=by_name[first]['sample'] + '\n' + by_name[last]['sample'])

GOLDEN = {'0|self||0|100|stable|[]': ['self',
                             'codex-proved-launch',
                             'agent-missing-pids-ignored',
                             'row-null-missing-pids',
                             'absent-panes',
                             'tty_process_pids-type-3',
                             'unattributed_tty_process_pids-type-3',
                             'tty_ownership_reasons-type-4',
                             'reason-attributed-key',
                             'cross-row-plus-self',
                             'graph-not-included-live',
                             'graph-missing-node-live',
                             'graph-duplicate-node-live',
                             'graph-wrong-kind-live',
                             'graph-bad-ppid-live',
                             'graph-self-cycle-live',
                             'graph-cycle-live',
                             'graph-sibling-live',
                             'graph-bad-children',
                             'graph-bad-children-live',
                             'graph-bad-processes-live',
                             'self-live',
                             'row-false-missing-pids',
                             'extras-zero-missing-pids',
                             'null-surface-live',
                             'numeric-reason-key',
                             'nested-processes',
                             'object-children',
                             'graph-depth-127',
                             'graph-depth-128',
                             'stream-self-then-self',
                             'stream-self-then-graph-not-included',
                             'stream-agents-empty-idle-then-self',
                             'stream-agents-empty-idle-then-graph-not-included',
                             'stream-agent-count-0-then-self',
                             'stream-agent-count-0-then-graph-not-included',
                             'stream-row-missing-pids-then-self',
                             'stream-row-missing-pids-then-graph-not-included',
                             'stream-graph-cycle-then-self',
                             'stream-null-then-self'],
 '0|busy|process 101 is independent of requesting agent 100, or its ancestry is unreadable|0|||[]': ['busy-independent',
                                                                                                     'busy-unreadable'],
 '1|busy|agent session ownership is unverified in cmux row target; kept the worktree. Shared-server sessions need a task-owned restart with wt run|0|||[]': ['unknown-root'],
 '1|busy|cannot identify the requesting provider; kept the worktree|0|||[]': ['unknown-start'],
 '1|busy|requesting provider identity is empty; kept the worktree|0|||[]': ['unknown-empty-start'],
 '1|busy||0|||[]': ['unknown-provider', 'unknown-command'],
 '1|busy|cannot verify task-owned Codex launch in row target; legacy shared-server ancestry is insufficient; kept the worktree|0|||[]': ['codex-unproved-launch'],
 '1|busy|requesting provider changed during ownership verification|0|||[]': ['changed-provider'],
 '1|busy|cannot check the agent in cmux row target; kept the worktree|0|||[]': ['malformed',
                                                                                'empty',
                                                                                'null',
                                                                                'array',
                                                                                'boolean',
                                                                                'string',
                                                                                'multiple-documents',
                                                                                'coding_agents-type-0',
                                                                                'coding_agents-type-1',
                                                                                'coding_agents-type-2',
                                                                                'coding_agents-type-3',
                                                                                'coding_agents-type-4',
                                                                                'agent-count-0',
                                                                                'agent-count-1',
                                                                                'agent-count-2',
                                                                                'agent-count-3',
                                                                                'agent-count-4',
                                                                                'agent-count-5',
                                                                                'precedence-count-pids-row'],
 '1|busy|cannot verify agent process data; kept the worktree|0|||[]': ['agent-pids-0',
                                                                       'agent-pids-1',
                                                                       'agent-pids-2',
                                                                       'agent-pids-3',
                                                                       'agent-pids-4',
                                                                       'agent-pids-5',
                                                                       'agent-pids-6',
                                                                       'agent-pids-7',
                                                                       'agent-pids-8',
                                                                       'agent-pids-9',
                                                                       'agent-pids-10',
                                                                       'agent-count-mismatch',
                                                                       'agent-fractional-count',
                                                                       'precedence-pids-row'],
 '1|busy|cannot verify ownership of the agent in cmux row target; incomplete process sample; kept the worktree|0|||[]': ['missing-row',
                                                                                                                         'duplicate-row',
                                                                                                                         'wrong-windows',
                                                                                                                         'wrong-resources',
                                                                                                                         'row-count-mismatch',
                                                                                                                         'row-missing-pids',
                                                                                                                         'row-missing-pids-string',
                                                                                                                         'row-missing-pids-object',
                                                                                                                         'row-pids-0',
                                                                                                                         'row-pids-1',
                                                                                                                         'row-pids-2',
                                                                                                                         'row-pids-3',
                                                                                                                         'row-pids-4',
                                                                                                                         'row-pids-5',
                                                                                                                         'row-pids-6',
                                                                                                                         'row-pids-7',
                                                                                                                         'row-pids-8',
                                                                                                                         'row-pids-9',
                                                                                                                         'row-pids-10',
                                                                                                                         'precedence-row-extras'],
 '1|busy|cannot inspect unattributed row processes; kept the worktree|0|||[]': ['panes-type-0',
                                                                                'panes-type-1',
                                                                                'panes-type-2',
                                                                                'null-surfaces',
                                                                                'tty_process_pids-type-0',
                                                                                'tty_process_pids-type-1',
                                                                                'tty_process_pids-type-2',
                                                                                'tty_process_pids-type-4',
                                                                                'unattributed_tty_process_pids-type-0',
                                                                                'unattributed_tty_process_pids-type-1',
                                                                                'unattributed_tty_process_pids-type-2',
                                                                                'unattributed_tty_process_pids-type-4',
                                                                                'tty_ownership_reasons-type-0',
                                                                                'tty_ownership_reasons-type-1',
                                                                                'tty_ownership_reasons-type-2',
                                                                                'tty_ownership_reasons-type-3',
                                                                                'unattributed-resources-0',
                                                                                'unattributed-resources-1',
                                                                                'unattributed-resources-2',
                                                                                'unattributed-resources-3',
                                                                                'unattributed-resources-4',
                                                                                'unattributed-resources-5',
                                                                                'unattributed-resources-6',
                                                                                'extra-zero',
                                                                                'extra-one',
                                                                                'extra-fraction',
                                                                                'extra-string',
                                                                                'extra-null',
                                                                                'reason-invalid-key'],
 '0|busy|process 333 is independent of requesting agent 100, or its ancestry is unreadable|0|||[]': ['unattributed-resources-7',
                                                                                                     'extra-duplicate',
                                                                                                     'extra-independent',
                                                                                                     'reason-extra-key',
                                                                                                     'stream-cross-row-extra-then-self',
                                                                                                     'stream-cross-row-extra-then-graph-not-included'],
 '0|idle||0|||[]': ['cross-row-idle',
                    'agents-empty-idle',
                    'agent-zero-idle',
                    'empty-row-idle',
                    'graph-not-included-idle',
                    'graph-missing-node-idle',
                    'graph-duplicate-node-idle',
                    'graph-wrong-kind-idle',
                    'graph-bad-ppid-idle',
                    'graph-self-cycle-idle',
                    'graph-cycle-idle',
                    'graph-sibling-idle',
                    'graph-bad-children-idle',
                    'graph-bad-processes-idle',
                    'stream-self-then-agents-empty-idle',
                    'stream-agents-empty-idle-then-agents-empty-idle',
                    'stream-agent-count-0-then-agents-empty-idle',
                    'stream-row-missing-pids-then-agents-empty-idle',
                    'stream-graph-cycle-then-agents-empty-idle',
                    'stream-null-then-agents-empty-idle'],
 '1|busy|row process attribution is uncertain; kept the worktree|0|||[]': ['cross-row-extra',
                                                                           'agents-empty-extra',
                                                                           'agent-zero-extra',
                                                                           'stream-agents-empty-idle-then-cross-row-extra',
                                                                           'stream-cross-row-extra-then-agents-empty-idle',
                                                                           'stream-cross-row-extra-then-cross-row-extra',
                                                                           'stream-null-then-cross-row-extra'],
 '0|busy|additional provider process 101 does not belong to requesting agent 100|0|||[]': ['busy-second-provider'],
 '1|busy|a row process disappeared without verified ownership; kept the worktree|1|||[]': ['graph-not-included',
                                                                                           'graph-missing-node',
                                                                                           'graph-duplicate-node',
                                                                                           'graph-wrong-kind',
                                                                                           'graph-bad-ppid',
                                                                                           'graph-self-cycle',
                                                                                           'graph-cycle',
                                                                                           'graph-sibling',
                                                                                           'graph-bad-processes',
                                                                                           'null-surface',
                                                                                           'graph-depth-129',
                                                                                           'stream-graph-cycle-then-graph-not-included',
                                                                                           'stream-null-then-graph-not-included'],
 '0|self||0|100|stable|[{"pid":200,"birth":"bsd:1:1","comm":"cmux","role":"command"}]': ['observer-proved'],
 '0|busy|process 200 is independent of requesting agent 100, or its ancestry is unreadable|0|||[]': ['observer-refused'],
 '0|busy|process  is independent of requesting agent 100, or its ancestry is unreadable|0|||[]': ['stream-self-then-cross-row-extra',
                                                                                                  'stream-agent-count-0-then-cross-row-extra',
                                                                                                  'stream-row-missing-pids-then-cross-row-extra',
                                                                                                  'stream-graph-cycle-then-cross-row-extra']}
expected = {name: result for result, names in GOLDEN.items() for name in names}
assert set(expected) == {case['name'] for case in CASES}
with (ROOT / 'manifest.tsv').open('w') as manifest:
    for case in CASES:
        path = ROOT / (case['name'] + '.json')
        path.write_text(case['sample'])
        manifest.write('\t'.join([case['name'], case['mode'], case['declared'], str(path), expected[case['name']]]) + '\n')
PYCASES
wt_meta() { printf '%s/absent.json' "$ROOT"; }
wt_path() { printf /fixture/task; }
cmux_call() { printf '%s' "$SAMPLE"; }
process_descends() {
  [[ $1 != "$2" ]] || return 0
  [[ $MODE != no-root ]] || return 1
  if [[ $1 == "$CALLER_PID" && $2 == 100 ]]; then return 0; fi
  [[ $1 != 100 || $2 != 90 ]] || return 0
  [[ $2 == 100 ]] || return 1
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1000 && $1 <= 1200 )) && return 0
  [[ $1 != 101 || $MODE != all-live ]] || return 0
  return 1
}
# Process 101 disappears except in explicit live, independent, and unreadable cases.
process_vanished() {
  [[ $1 == 101 && $MODE != independent && $MODE != unreadable && $MODE != all-live ]]
}
codex_owned_launch() { [[ $MODE != launch-failed ]]; }
cmux_codex_monitor() {
  [[ $MODE == observer && $4 == 200 ]] || return 1
  printf '%s' '{"pid":200,"birth":"bsd:1:1","comm":"cmux","role":"command"}'
}
ps() {
  case ${4:-} in
    command=) [[ $MODE != command-failed ]] || return 1; printf claude ;;
    comm=) [[ $MODE != provider-failed ]] || return 1; printf claude ;;
    lstart=)
      [[ $MODE != start-failed ]] || return 1
      [[ $MODE != empty-start ]] || return 0
      if [[ $MODE == changed-start ]]; then
        if [[ -f $ROOT/start-seen ]]; then printf changed; else touch "$ROOT/start-seen"; printf stable; fi
      else printf stable; fi ;;
    *) return 1 ;;
  esac
}
begin_scenario 'native snapshot assessment contract' || exit 0
while IFS=$'\t' read -r name MODE declared file expected; do
  SAMPLE=$(<"$file")
  WT_TEARDOWN_JSON="{\"agent\":\"$declared\"}"
  rm -f "$ROOT/start-seen"
  actual=$(
    CMUX_ERROR='' CMUX_SAMPLE_RETRY=0 ROW_AGENT=old ROW_AGENT_PID=old ROW_AGENT_START=old ROW_AGENT_OBSERVERS=old
    CALLER_PID=$BASHPID
    rc=0
    row_agent_once target task || rc=$?
    printf '%s|%s|%s|%s|%s|%s|%s' "$rc" "$ROW_AGENT" "$CMUX_ERROR" "$CMUX_SAMPLE_RETRY" \
      "$ROW_AGENT_PID" "$ROW_AGENT_START" "$ROW_AGENT_OBSERVERS"
  )
  assert_eq "$name" "$expected" "$actual"
done <"$ROOT/manifest.tsv"
end_scenario
lib_summary
