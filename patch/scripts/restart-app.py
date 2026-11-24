#!/usr/bin/env python3
"""Restart the built Patch app, preserving the current graph and editor session."""
import json
from pathlib import Path
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TOKEN = Path.home() / 'Library/Application Support/Patch/api-token'


def api(path, body=None):
    req = urllib.request.Request(
        'http://127.0.0.1:9417/v1/' + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Bearer ' + TOKEN.read_text().strip(),
                 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


def state():
    return api('state')


def matching_session(session, restored):
    expected = json.loads(json.dumps(session['graph']))
    actual_nodes = {node['id']: node for node in restored['graph']['nodes']}
    # Plugin hosts refresh their reported schema after loading (for example,
    # discovering that a vendor's continuous parameter is actually a menu).
    # Permit schema refresh only when identity and normalized settings agree.
    for node in expected['nodes']:
        if node.get('kind') != 'audioPlugin' or not node.get('plugin'):
            continue
        actual = actual_nodes.get(node['id'], {})
        old_plugin, new_plugin = node['plugin'], actual.get('plugin', {})
        old_specs = {p['key']: p for p in old_plugin.get('parameters', [])}
        new_specs = {p['key']: p for p in new_plugin.get('parameters', [])}
        if old_specs.keys() != new_specs.keys() or old_plugin.get('identifier') != new_plugin.get('identifier'):
            continue
        for key, old in old_specs.items():
            new = new_specs[key]
            old_max = max(1, old.get('steps', 0) - 1)
            new_max = max(1, new.get('steps', 0) - 1)
            value = node.get('parameters', {}).get(key, old.get('initial', 0) * old_max)
            converted = value / old_max * new_max
            if new.get('steps', 0) > 1:
                converted = round(converted)
            current = actual.get('parameters', {}).get(key)
            if current is not None and abs(current - converted) < 0.00001:
                node.setdefault('parameters', {})[key] = current
        old_plugin['parameters'] = new_plugin.get('parameters', [])
    if restored['graph'] != expected:
        return False
    for key in ('selection', 'playing', 'backdropEnabled', 'backdropID', 'file', 'dirty', 'projectName', 'previewVisible'):
        if key in session and restored.get(key) != session[key]:
            return False
    if sorted(session.get('selectedNodes', [])) != sorted(restored.get('selectedNodes', [])):
        return False
    if session.get('tabs'):
        expected_tabs = session['tabs']
        actual_tabs = restored.get('tabs', [])
        if [t['tabID'] for t in expected_tabs] != [t['id'] for t in actual_tabs]:
            return False
        for expected_tab, actual_tab in zip(expected_tabs, actual_tabs):
            for key in ('running', 'dirty', 'file', 'graphRevision'):
                if key in expected_tab and expected_tab[key] != actual_tab.get(key):
                    return False
        if session.get('activeTab') != next((t['id'] for t in actual_tabs if t.get('selected')), None):
            return False
    return not session.get('editor') or restored.get('editor') == session['editor']


def main():
    app = ROOT / 'build/Patch.app'
    if not (app / 'Contents/MacOS/Patch').is_file():
        raise SystemExit('Build Patch first with scripts/build-app.sh')
    session = state()
    old_pid = session.get('processID')
    if session['graph'].get('version') != 2:
        raise SystemExit('The active session uses an older graph format. Save and convert its projects before restarting Patch.')
    result = api('commands', {'op': 'restart', 'appPath': str(app),
                              'allowLiveChanges': True,
                              'expectedRevision': session['graphRevision']})
    path = Path(result['session'])
    session = json.loads(path.read_text())
    print('Session saved:', path, flush=True)
    for _ in range(240):
        try:
            restored = state()
            if old_pid is not None and restored.get('processID') == old_pid:
                time.sleep(.25)
                continue
            if matching_session(session, restored):
                print('Patch restarted; project, unsaved edits, selection and editor state restored.')
                return
        except OSError:
            pass
        time.sleep(.25)
    raise SystemExit('Restart requested, but restoration could not be confirmed. '
                     'Session snapshot: ' + str(path))


if __name__ == '__main__':
    main()
