"""Validate complete cmux captures before selecting contract examples."""
import json
import re
import sys


METHODS = (
    'workspace.list', 'workspace.create', 'workspace.action', 'workspace.close',
    'workspace.select', 'notification.list', 'notification.dismiss', 'system.top',
    'surface.read_text',
)
ROW = ('id', 'ref', 'title', 'description', 'current_directory', 'has_custom_title', 'remote')
REMOTE = ('enabled', 'destination', 'state', 'backend', 'persistent_daemon_slot', 'terminal_transport',
          'remote_workspace_id', 'active_terminal_sessions')
WINDOW = ('id', 'index', 'key', 'selected_workspace_id', 'workspace_count')
RESOURCES = ('process_count', 'pids', 'missing_pids')


def require(condition):
    if not condition:
        raise ValueError('invalid cmux capture contract')


def keep(value, fields):
    return {key: value[key] for key in fields if key in value}


def array(value):
    require(type(value) is list)
    return value


def object_(value):
    require(type(value) is dict)
    return value


def string(value):
    require(type(value) is str)


def identifier(value):
    string(value)
    require(re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value) is not None)


def reference(value, kind):
    string(value)
    require(re.fullmatch(kind + r':[1-9][0-9]*', value) is not None)


def integer(value, minimum=0):
    require(type(value) is int and value >= minimum)


def resources(value):
    object_(value)
    integer(value['process_count'])
    pids = array(value['pids'])
    for pid in pids:
        integer(pid, 2)
    require(len(set(pids)) == len(pids) == value['process_count'])
    if 'missing_pids' in value:
        for pid in array(value['missing_pids']):
            integer(pid, 2)
    return keep(value, RESOURCES)


def row(value):
    object_(value)
    identifier(value['id'])
    reference(value['ref'], 'workspace')
    for field in ('title', 'current_directory'):
        string(value[field])
    require(value['description'] is None or type(value['description']) is str)
    require(type(value['has_custom_title']) is bool)
    remote = object_(value['remote'])
    require(type(remote['enabled']) is bool)
    for field in ('destination', 'backend', 'terminal_transport', 'remote_workspace_id'):
        if field in remote:
            require(remote[field] is None or type(remote[field]) is str)
    string(remote['state'])
    require('destination' in remote and 'terminal_transport' in remote)
    integer(remote['active_terminal_sessions'])
    if remote['enabled']:
        string(remote['destination'])
        string(remote['backend'])
        if remote['state'] == 'connected':
            require('remote_workspace_id' in remote)
    if 'persistent_daemon_slot' in remote and remote['persistent_daemon_slot'] is not None:
        integer(remote['persistent_daemon_slot'])
    result = keep(value, ROW)
    result['remote'] = keep(remote, REMOTE)
    return result


def row_document(value):
    object_(value)
    result = {'workspaces': [row(r) for r in array(value['workspaces'])]}
    if 'window_ref' in value:
        reference(value['window_ref'], 'window')
        result['window_ref'] = value['window_ref']
    return result


def project(bundle):
    """Keep observed samples and their identity anchors without repairing input."""
    rows = row_document(bundle['rows'])
    scoped = {key: row_document(value) for key, value in object_(bundle['rows_by_window']).items()}
    windows = array(bundle['windows'])
    for window in windows:
        object_(window)
        identifier(window['id'])
        integer(window['index'])
        require(type(window['key']) is bool)
        integer(window['workspace_count'])
        if window['selected_workspace_id'] is not None:
            identifier(window['selected_workspace_id'])
        require(window['id'] in scoped)
    require(set(scoped) == {w['id'] for w in windows})
    require(len({w['id'] for w in windows}) == len(windows))
    # Separate calls can race. Reject conflicting bindings.
    by_id, by_ref = {}, {}
    for document in [rows, *scoped.values()]:
        ids = [r['id'] for r in document['workspaces']]
        require(len(set(ids)) == len(ids))
        for current in document['workspaces']:
            require(by_id.get(current['id'], current['ref']) == current['ref'])
            require(by_ref.get(current['ref'], current['id']) == current['id'])
            by_id[current['id']] = current['ref']
            by_ref[current['ref']] = current['id']
    require({r['id'] for r in rows['workspaces']} ==
            {r['id'] for d in scoped.values() for r in d['workspaces']})
    scoped_ids = [r['id'] for d in scoped.values() for r in d['workspaces']]
    require(len(set(scoped_ids)) == len(scoped_ids))
    for window in windows:
        members = scoped[window['id']]['workspaces']
        require(window['workspace_count'] == len(members))
        require(window['selected_workspace_id'] is None or
                window['selected_workspace_id'] in {r['id'] for r in members})
    window_refs = {r['id']: d['window_ref'] for d in scoped.values() if 'window_ref' in d
                   for r in d['workspaces']}
    scoped_refs = [d['window_ref'] for d in scoped.values() if 'window_ref' in d]
    require(len(set(scoped_refs)) == len(scoped_refs))
    top = object_(bundle['top'])
    caller = object_(top['caller'])
    if caller['workspace_id'] is not None:
        identifier(caller['workspace_id'])
    for field, kind in [('workspace_ref', 'workspace'), ('window_ref', 'window')]:
        if caller.get(field) is not None:
            reference(caller[field], kind)
    if caller.get('workspace_ref') is not None and caller['workspace_id'] in by_id:
        require(caller['workspace_ref'] == by_id[caller['workspace_id']])
    if caller.get('window_ref') is not None and caller['workspace_id'] in window_refs:
        require(caller['window_ref'] == window_refs[caller['workspace_id']])
    agents = []
    for agent in array(top['coding_agents']):
        agents.append({'resources': resources(object_(agent)['resources'])})
    top_windows = []
    top_ids = []
    for window in array(top['windows']):
        if 'ref' in window:
            reference(window['ref'], 'window')
        members = []
        for current in array(window['workspaces']):
            identifier(current['id'])
            top_ids.append(current['id'])
            if 'ref' in current:
                reference(current['ref'], 'workspace')
                require(by_id.get(current['id'], current['ref']) == current['ref'])
                require(by_ref.get(current['ref'], current['id']) == current['id'])
            if 'ref' in window and current['id'] in window_refs:
                require(window['ref'] == window_refs[current['id']])
            members.append(dict(keep(current, ('id', 'ref')), resources=resources(current['resources'])))
        top_windows.append(dict(keep(window, ('ref',)), workspaces=members))
    require(len(set(top_ids)) == len(top_ids))
    notifications = array(bundle['notifications'])
    for notification in notifications:
        identifier(notification['id'])
        identifier(notification['workspace_id'])
        string(notification['title'])
        string(notification['body'])
    event = object_(bundle['event'])
    require(event['name'] == 'notification.created')
    identifier(event['workspace_id'])
    identifier(event['payload']['notification_id'])
    methods = array(bundle['capabilities']['methods'])
    for method in methods:
        string(method)
    require(all(method in methods for method in METHODS))

    # Prefer a notification associated with the retained event, if it still exists.
    notification = next((n for n in notifications if n['id'] == event['payload']['notification_id']
                         and n['workspace_id'] == event['workspace_id']), next(iter(notifications), None))
    wanted = {caller['workspace_id'], event['workspace_id']}
    if notification is not None:
        wanted.add(notification['workspace_id'])
    for remote in (False, True):
        example = next((r for r in rows['workspaces'] if r['remote']['enabled'] is remote), None)
        if example is not None:
            wanted.add(example['id'])
    selected_windows = [w for w in windows if any(r['id'] in wanted for r in scoped[w['id']]['workspaces'])]
    if not selected_windows and windows:
        selected_windows = windows[:1]
    wanted.update(w['selected_workspace_id'] for w in selected_windows)
    selected_scoped = {}
    for window in selected_windows:
        document = scoped[window['id']]
        document['workspaces'] = [r for r in document['workspaces'] if r['id'] in wanted]
        selected_scoped[window['id']] = document
    selected_rows = [r for r in rows['workspaces'] if r['id'] in wanted]
    selected_top = []
    refs = {r['ref'] for r in selected_rows}
    for window in top_windows:
        window['workspaces'] = [r for r in window['workspaces'] if r['id'] in wanted
                                or r.get('ref') in refs]
        if window['workspaces']:
            selected_top.append(window)
    return dict(
        rows=dict(keep(rows, ('window_ref',)), workspaces=selected_rows),
        rows_by_window=selected_scoped,
        windows=[dict(keep(w, WINDOW), workspace_count=len(selected_scoped[w['id']]['workspaces']))
                 for w in selected_windows],
        top={'caller': keep(caller, ('workspace_id', 'workspace_ref', 'window_ref')),
             'coding_agents': agents[:1], 'windows': selected_top},
        notifications=[keep(notification, ('id', 'workspace_id', 'title', 'body'))] if notification else [],
        event=dict(keep(event, ('name', 'workspace_id')),
                   payload=keep(event['payload'], ('notification_id',))),
        # Doctor compares the complete automation. Preserve unexpected keys for that comparison.
        automation=bundle['automation'],
        capabilities={'methods': list(dict.fromkeys(m for m in methods if m in METHODS))},
    )


if __name__ == '__main__':
    try:
        json.dump(project(json.load(sys.stdin)), sys.stdout)
        sys.stdout.write('\n')
    except (KeyError, TypeError, ValueError):
        sys.exit('invalid cmux capture contract; no fixtures written')
