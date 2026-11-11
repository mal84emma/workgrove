"""Check projection contracts independently of representative selection."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('doctor_fixtures', ROOT / 'lib/workgrove/doctor_fixtures.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class FixtureTests(unittest.TestCase):
    def setUp(self):
        folder = ROOT / 'test/fixtures/cmux-0.65.2'
        self.bundle = {name: json.loads((folder / (name + '.json')).read_text()) for name in (
            'rows', 'rows_by_window', 'windows', 'top', 'notifications', 'event', 'automation', 'capabilities')}

    def reject(self, bundle):
        with self.assertRaises((ValueError, TypeError, KeyError)):
            fixtures.project(bundle)

    def scrub(self, bundle):
        return json.loads(subprocess.run(['jq', '-f', str(ROOT / 'lib/workgrove/doctor-sanitize.jq')],
                                        input=json.dumps(bundle), text=True, capture_output=True, check=True).stdout)

    def test_retention_and_unknown_nested_fields(self):
        original = fixtures.project(self.bundle)
        self.assertEqual(original, self.bundle)
        changed = copy.deepcopy(self.bundle)
        changed['private-map-key'] = {'command': 'private command'}
        changed['rows']['workspaces'][0]['remote']['unknown'] = {'body': 'private body'}
        changed['top']['coding_agents'][0]['resources']['unknown'] = {'pids': ['private PID']}
        changed['notifications'][0]['unknown'] = {'title': 'private title'}
        changed['event']['payload']['unknown'] = {'command': 'private command'}
        changed['capabilities']['methods'].append('unknown.method')
        self.assertEqual(original, fixtures.project(changed))
        self.assertEqual(set(original['capabilities']['methods']), set(fixtures.METHODS))
        for current in original['rows']['workspaces']:
            self.assertEqual(set(current), set(fixtures.ROW))
        self.assertEqual(set(original['notifications'][0]), {'id', 'workspace_id', 'title', 'body'})
        self.assertEqual(set(original['event']), {'name', 'workspace_id', 'payload'})
        self.assertEqual(original['automation'], self.bundle['automation'])
        self.assertEqual(original['top']['coding_agents'][0]['resources'],
                         self.bundle['top']['coding_agents'][0]['resources'])

    def test_required_field_mutations(self):
        remote_index = next(i for i, r in enumerate(self.bundle['rows']['workspaces']) if r['remote']['enabled'])
        paths = [
            ('rows', 'workspaces', 0, key) for key in fixtures.ROW
        ] + [
            ('rows', 'workspaces', 0, 'remote', key) for key in (
                'enabled', 'destination', 'state', 'terminal_transport',
                'active_terminal_sessions')
        ] + [
            ('rows', 'workspaces', remote_index, 'remote', key) for key in ('backend', 'remote_workspace_id', 'machine')
        ] + [
            ('windows', 0, key) for key in fixtures.WINDOW
        ] + [
            ('top', 'caller', 'workspace_id'), ('top', 'coding_agents'), ('top', 'windows'),
            ('top', 'coding_agents', 0, 'resources', 'process_count'),
            ('top', 'coding_agents', 0, 'resources', 'pids'),
            ('top', 'windows', 0, 'workspaces', 0, 'id'),
            ('top', 'windows', 0, 'workspaces', 0, 'resources', 'pids'),
            ('event', 'name'), ('event', 'workspace_id'), ('event', 'payload', 'notification_id'),
            ('capabilities', 'methods'),
        ] + [('notifications', 0, key) for key in ('id', 'workspace_id', 'title', 'body')]
        for path in paths:
            for mutation in ('remove', 'rename', 'retype'):
                with self.subTest(path=path, mutation=mutation):
                    changed = copy.deepcopy(self.bundle)
                    parent = changed
                    for part in path[:-1]:
                        parent = parent[part]
                    value = parent.pop(path[-1])
                    if mutation == 'rename':
                        parent['renamed'] = value
                    elif mutation == 'retype':
                        parent[path[-1]] = [] if type(value) is not list else {}
                    self.reject(changed)
        for method in fixtures.METHODS:
            for replacement in (None, 'renamed.method', 123):
                with self.subTest(method=method, replacement=replacement):
                    changed = copy.deepcopy(self.bundle)
                    methods = changed['capabilities']['methods']
                    methods.remove(method)
                    if replacement is not None:
                        methods.append(replacement)
                    self.reject(changed)

    def test_later_malformed_objects_cannot_hide(self):
        for path, malformed in [
            (('rows', 'workspaces'), {'id': 5}),
            (('top', 'coding_agents'), {'resources': {'process_count': '1'}}),
            (('top', 'windows'), {'ref': 'window:999', 'workspaces': [{'id': None}]}),
            (('notifications',), {'id': None}),
            (('windows',), {'id': None}),
        ]:
            with self.subTest(path=path):
                changed = copy.deepcopy(self.bundle)
                current = changed
                for part in path:
                    current = current[part]
                current.append(malformed)
                self.reject(changed)
        changed = copy.deepcopy(self.bundle)
        document = next(iter(changed['rows_by_window'].values()))
        document['workspaces'][-1]['remote']['enabled'] = 'true'
        self.reject(changed)

    def test_representatives_and_identity_anchors(self):
        changed = copy.deepcopy(self.bundle)
        # A repeated global agent and notification must not enlarge the sample.
        changed['top']['coding_agents'] *= 3
        changed['notifications'] *= 3
        result = fixtures.project(changed)
        self.assertEqual(len(result['top']['coding_agents']), 1)
        self.assertEqual(len(result['notifications']), 1)
        scrubbed = self.scrub(result)
        rows = {r['id']: r for r in scrubbed['rows']['workspaces']}
        for window in scrubbed['windows']:
            scoped = scrubbed['rows_by_window'][window['id']]
            self.assertEqual(window['workspace_count'], len(scoped['workspaces']))
            self.assertIn(window['selected_workspace_id'], rows)
            for current in scoped['workspaces']:
                self.assertEqual(rows[current['id']]['ref'], current['ref'])
        for window in scrubbed['top']['windows']:
            for current in window['workspaces']:
                self.assertEqual(rows[current['id']]['ref'], current['ref'])
        caller = scrubbed['top']['caller']
        self.assertEqual(rows[caller['workspace_id']]['ref'], caller['workspace_ref'])
        for source in ('event',):
            if result[source]['workspace_id'] in {r['id'] for r in result['rows']['workspaces']}:
                self.assertIn(scrubbed[source]['workspace_id'], rows)
        # Matching identities remain equal; unmatched retained events remain unmatched.
        before = result['event']['payload']['notification_id'] == result['notifications'][0]['id']
        after = scrubbed['event']['payload']['notification_id'] == scrubbed['notifications'][0]['id']
        self.assertEqual(before, after)
        self.assertLessEqual(sum(json.dumps(v, indent=2).count('\n') + 1 for v in result.values()), 400)

    def test_unrelated_rows_and_windows_are_not_retained(self):
        changed = copy.deepcopy(self.bundle)
        top_window = changed['top']['windows'][0]
        window = next(w for w in changed['windows']
                      if changed['rows_by_window'][w['id']].get('window_ref') == top_window.get('ref'))
        document = changed['rows_by_window'][window['id']]
        for number in range(100, 120):
            current = copy.deepcopy(changed['rows']['workspaces'][0])
            current.update(id=f'00000000-0000-4000-8000-{number:012d}', ref=f'workspace:{number}')
            changed['rows']['workspaces'].append(current)
            document['workspaces'].append(copy.deepcopy(current))
            top_window['workspaces'].append(dict(id=current['id'], ref=current['ref'],
                                                resources={'pids': [], 'process_count': 0}))
        window['workspace_count'] = len(document['workspaces'])
        empty_id = '00000000-0000-4000-8000-000000000999'
        changed['windows'].append(dict(id=empty_id, index=99, key=False,
                                       selected_workspace_id=None, workspace_count=0))
        changed['rows_by_window'][empty_id] = {'workspaces': [], 'window_ref': 'window:999'}
        original = fixtures.project(self.bundle)
        self.assertEqual(fixtures.project(changed), original)
        document['workspaces'][-1]['remote']['state'] = False
        self.reject(changed)

    def test_matching_event_notification_identity_is_preserved(self):
        changed = copy.deepcopy(self.bundle)
        changed['notifications'][0].update(id=changed['event']['payload']['notification_id'],
                                            workspace_id=changed['event']['workspace_id'])
        result = self.scrub(fixtures.project(changed))
        self.assertEqual(result['event']['workspace_id'], result['notifications'][0]['workspace_id'])
        self.assertEqual(result['event']['payload']['notification_id'], result['notifications'][0]['id'])

    def test_conflicting_later_notification_binding_cannot_hide(self):
        changed = copy.deepcopy(self.bundle)
        event = changed['event']
        first = dict(changed['notifications'][0], id='00000000-0000-4000-8000-000000001001')
        conflict = dict(first, id=event['payload']['notification_id'],
                        workspace_id='00000000-0000-4000-8000-000000001002')
        self.assertNotEqual(conflict['workspace_id'], event['workspace_id'])
        for notifications in ([first, conflict], [conflict, first]):
            changed['notifications'] = notifications
            self.reject(changed)
        conflict['workspace_id'] = event['workspace_id']
        changed['notifications'] = [first, conflict]
        result = fixtures.project(changed)
        self.assertEqual(result['notifications'][0]['id'], event['payload']['notification_id'])
        self.assertEqual(result['notifications'][0]['workspace_id'], event['workspace_id'])

    def test_duplicate_notification_ids_cannot_bind_different_rows(self):
        changed = copy.deepcopy(self.bundle)
        first = dict(changed['notifications'][0], id='00000000-0000-4000-8000-000000001001')
        conflict = dict(first, workspace_id='00000000-0000-4000-8000-000000001002')
        self.assertNotEqual(first['workspace_id'], conflict['workspace_id'])
        changed['notifications'] = [first, conflict]
        self.reject(changed)

    def test_absent_samples_and_empty_arrays(self):
        for remote in (False, True, None):
            changed = copy.deepcopy(self.bundle)
            changed['rows']['workspaces'] = [r for r in changed['rows']['workspaces']
                                              if r['remote']['enabled'] is remote]
            ids = {r['id'] for r in changed['rows']['workspaces']}
            for document in changed['rows_by_window'].values():
                document['workspaces'] = [r for r in document['workspaces'] if r['id'] in ids]
            for window in changed['windows']:
                members = changed['rows_by_window'][window['id']]['workspaces']
                window['workspace_count'] = len(members)
                window['selected_workspace_id'] = members[0]['id'] if members else None
            changed['top']['coding_agents'] = []
            changed['top']['windows'] = []
            changed['notifications'] = []
            result = fixtures.project(changed)
            self.assertTrue(all(r['remote']['enabled'] is remote for r in result['rows']['workspaces']))
            self.assertEqual(result['top']['coding_agents'], [])
            self.assertEqual(result['notifications'], [])
        changed['windows'] = []
        changed['rows_by_window'] = {}
        self.assertEqual(fixtures.project(changed)['windows'], [])

    def test_unknown_automation_remains_a_contract_difference(self):
        changed = copy.deepcopy(self.bundle)
        changed['automation']['private-command'] = {'command': 'private command', 'unexpected': True}
        output = self.scrub(fixtures.project(changed))
        self.assertNotEqual(output['automation'], self.bundle['automation'])
        self.assertNotIn('private', json.dumps(output))
        self.assertNotIn('private-map-key', self.scrub({'private-map-key': 'private'}))

    def test_bad_identity_bindings_fail(self):
        for path, value in [
            (('top', 'caller', 'workspace_ref'), 'workspace:999'),
            (('top', 'caller', 'window_ref'), 'window:999'),
            (('top', 'windows', 0, 'ref'), 'window:999'),
            (('top', 'windows', 0, 'workspaces', 0, 'ref'), 'workspace:999'),
            (('windows', 0, 'workspace_count'), 999),
        ]:
            changed = copy.deepcopy(self.bundle)
            current = changed
            for part in path[:-1]:
                current = current[part]
            current[path[-1]] = value
            self.reject(changed)

    def test_empty_strings_do_not_become_ready_values(self):
        changed = copy.deepcopy(self.bundle)
        for document in [changed['rows'], *changed['rows_by_window'].values()]:
            for current in document['workspaces']:
                current['remote']['remote_workspace_id'] = ''
                current['current_directory'] = ''
        result = self.scrub(fixtures.project(changed))
        for current in result['rows']['workspaces']:
            self.assertEqual(current['remote']['remote_workspace_id'], '')
            self.assertEqual(current['current_directory'], '')

    def test_resource_counts_and_pid_relationships(self):
        for resource in (self.bundle['top']['coding_agents'][0]['resources'],
                         self.bundle['top']['windows'][0]['workspaces'][0]['resources']):
            resource['pids'] = [10001, 20002]
            resource['process_count'] = 2
        result = self.scrub(fixtures.project(self.bundle))
        agents = result['top']['coding_agents'][0]['resources']
        row = result['top']['windows'][0]['workspaces'][0]['resources']
        self.assertEqual(agents['pids'], row['pids'])
        self.assertTrue(set(agents['pids']).isdisjoint({10001, 20002}))
        for pids, count in [([3], 2), ([3, 3], 2), ([True], 1), (['3'], 1)]:
            changed = copy.deepcopy(self.bundle)
            changed['top']['coding_agents'].append({'resources': {'pids': pids, 'process_count': count}})
            self.reject(changed)


if __name__ == '__main__':
    unittest.main()
