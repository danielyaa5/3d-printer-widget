#!/usr/bin/env python3
"""Test the real Stop review using only the separately identified fictional QA app."""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess
import time

BUNDLE = 'org.example.printprogresswidgetqa.PrintProgressMac'
p = argparse.ArgumentParser()
p.add_argument('--app', type=pathlib.Path, required=True)
p.add_argument('--output', type=pathlib.Path, default=pathlib.Path('build/WidgetClick.noindex'))
args = p.parse_args()
app = args.app.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != BUNDLE:
    raise SystemExit('Refusing a production or unknown app.')
out = args.output.resolve()
if not any(part.endswith('.noindex') for part in out.parts):
    raise SystemExit('Reports require an ignored .noindex directory.')
out.mkdir(parents=True, exist_ok=True)


def script(source):
    return subprocess.check_output(['osascript', '-e', source], text=True).strip()


def quit_app():
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    subprocess.run(["pkill", "-TERM", "-f", "^" + re.escape(str(executable)) + r"($| )"], check=False)
    for _ in range(50):
        count = script(f'tell application "System Events" to get count of (application processes whose bundle identifier is "{BUNDLE}")')
        if count == '0':
            return
        time.sleep(0.1)
    raise RuntimeError('QA app did not finish quitting; no further action taken.')


def report(name, reset=False):
    target = out / name
    target.unlink(missing_ok=True)
    command = ['open', '-na', str(app), '--args', '--widget-qa-report', str(target)]
    if reset:
        command.append('--widget-qa-reset')
    subprocess.run(command, check=True)
    for _ in range(50):
        if target.exists():
            return json.loads(target.read_text())
        time.sleep(0.1)
    raise RuntimeError('The isolated app did not export its report.')


def review(url):
    subprocess.run(['open', url], check=True)
    for _ in range(50):
        value = script(f'''tell application "System Events"
            set matches to application processes whose bundle identifier is "{BUNDLE}"
            if (count of matches) > 0 then
                tell item 1 of matches
                    if (count of windows) > 0 then
                        if (count of sheets of window 1) > 0 then
                            return value of every static text of group 1 of sheet 1 of window 1
                        end if
                    end if
                end tell
            end if
            return "waiting"
        end tell''')
        if 'Stop the print on Widget Test?' in value and 'Test planter' in value:
            return
        time.sleep(0.1)
    raise RuntimeError('Expected fictional Stop confirmation was not shown.')


def press_review(button):
    # The current production view orders Keep printing before Stop print.
    # Verify the fictional labels again immediately before acting.
    script(f'''tell application "System Events"
        tell (first application process whose bundle identifier is "{BUNDLE}")
            set g to group 1 of sheet 1 of window 1
            set labels to value of every static text of g
            if labels does not contain "Test planter" then error "Not the fictional job"
            if labels does not contain "Stop the print on Widget Test?" then error "Not the fictional printer"
            if name of every action of button {button} of g does not contain "AXPress" then error "Control unavailable"
            perform action "AXPress" of button {button} of g
        end tell
    end tell''')


# Initialize only this QA namespace. No network backend exists on this path.
quit_app()
initial = report('stop-initial.json', reset=True)
assert initial['state'] == 'printing' and initial['receipts'] == []
quit_app()
review(initial['stopURL'])
press_review(1)
script(f'''tell application "System Events" to tell (first application process whose bundle identifier is "{BUNDLE}")
    perform action "AXPress" of (first button of window 1 whose subrole is "AXCloseButton")
    if (count of windows) is not 0 then error "QA window did not close"
end tell''')
review(initial['stopURL'])
press_review(1)
quit_app()
after_cancel = report('stop-after-cancel.json')
assert after_cancel['state'] == 'printing' and after_cancel['receipts'] == [], 'Cancel sent a command'
review(after_cancel['stopURL'])
press_review(2)
for _ in range(50):
    value = script(f'''tell application "System Events" to tell (first application process whose bundle identifier is "{BUNDLE}")
        if (count of sheets of window 1) is 0 then return "done"
        return "waiting"
    end tell''')
    if value == 'done':
        break
    time.sleep(0.1)
else:
    raise RuntimeError('Stop review did not finish')
quit_app()
after_stop = report('stop-after-confirm.json')
assert after_stop['state'] == 'cancelled'
assert [item['command'] for item in after_stop['receipts']] == ['stop']
quit_app()
(out / 'stop-test-summary.json').write_text(json.dumps({
    'passed': True, 'coldLaunchReview': True, 'closedWindowReview': True,
    'cancelSentNoCommands': True, 'confirmedStopReceipts': 1,
    'realPrinterCommands': 0,
}, indent=2) + '\n')
print('PASS: cold and closed-window Stop review, Keep printing sends nothing, confirmed Stop produces one fictional receipt.')
