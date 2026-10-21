#!/usr/bin/env python3
"""Actual desktop-widget clicks. Explicit native-click approval is required.

Only the separately installed fictional QA build is accepted. Add its small
Print Progress QA widget to the desktop first. Reports stay in .noindex.
"""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--app', type=pathlib.Path, required=True)
p.add_argument('--helper', type=pathlib.Path, required=True)
p.add_argument('--allow-native-click', action='store_true', required=True)
p.add_argument('--output', type=pathlib.Path, default=pathlib.Path('build/WidgetClick.noindex'))
a = p.parse_args()
app = a.app.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
bundle = 'org.example.printprogresswidgetqa.PrintProgressMac'
assert info['CFBundleIdentifier'] == bundle, 'Refusing production or unknown app'
out = a.output.resolve()
assert any(s.endswith('.noindex') for s in out.parts)
out.mkdir(parents=True, exist_ok=True)

def script(s):
    return subprocess.check_output(['osascript', '-e', s], text=True).strip()

def quit_app():
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    subprocess.run(['pkill', '-TERM', '-f', '^' + re.escape(str(executable)) + r'($| )'], check=False)
    for _ in range(50):
        if closed():
            return
        time.sleep(.1)
    raise RuntimeError('QA app did not quit')

def closed():
    return script(f'tell application "System Events" to get count of (application processes whose bundle identifier is "{bundle}")') == '0'

def report(name, reset=False):
    quit_app()
    path = out / name
    path.unlink(missing_ok=True)
    cmd = ['open', '-na', str(app), '--args', '--widget-qa-report', str(path)]
    if reset:
        cmd.append('--widget-qa-reset')
    subprocess.run(cmd, check=True)
    for _ in range(100):
        if path.exists():
            value = json.loads(path.read_text())
            quit_app()
            return value
        time.sleep(.1)
    raise RuntimeError('Missing isolated report')

def wait_state(state):
    for _ in range(150):
        values = script('tell application "System Events" to tell process "NotificationCenter" to get value of every static text of group 1 of group 1 of (first window whose name is "Print Progress QA")')
        if 'Widget Test' in values and state in values:
            return
        time.sleep(.2)
    raise RuntimeError(f'QA widget did not show {state}')

initial = report('actions-initial.json', reset=True)
assert initial['state'] == 'printing' and initial['receipts'] == []
wait_state('Printing')
for before, after in [('Printing', 'Paused'), ('Paused', 'Printing')]:
    assert closed(), 'Containing app must be closed before widget control'
    script('tell application "Finder" to activate')
    subprocess.run([str(a.helper.resolve()), '--allow-native-click', '2', before], check=True)
    wait_state(after)
    assert closed(), 'Widget unexpectedly launched its containing app'
final = report('actions-final.json')
assert final['state'] == 'printing'
assert [r['command'] for r in final['receipts']] == ['pause', 'resume'], 'Expected exactly one command per click'
(out / 'actions-test-summary.json').write_text(json.dumps({
    'passed': True, 'nativeDesktopWidgetClicks': ['pause', 'resume'],
    'containingAppStayedClosed': True, 'fictionalReceipts': ['pause', 'resume'],
    'realPrinterCommands': 0,
}, indent=2) + '\n')
print('PASS: actual widget Pause/Resume, two fictional receipts, containing app stayed closed.')
