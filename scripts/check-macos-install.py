#!/usr/bin/env python3
"""Reject an update that changes the app or widget's signing identity.

Run before replacing the installed bundle. Does not read credentials or change
permissions. Source and installed signatures must already verify with codesign.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess


def run_codesign(*args):
    result = subprocess.run(['/usr/bin/codesign', *args], capture_output=True, text=True)
    if result.returncode:
        raise ValueError('Unable to verify the signing identity. Installation stopped.')
    return result.stdout + result.stderr


def metadata(bundle, run=run_codesign):
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    output = run('-d', '--verbose=2', '-r-', str(bundle))
    values = dict(line.split('=', 1) for line in output.splitlines() if '=' in line)
    requirement = next((line.partition(' => ')[2] for line in output.splitlines()
                        if line.startswith('designated => ')), '')
    team = values.get('TeamIdentifier', '')
    if not team or team == 'not set' or not requirement or 'anchor apple' not in requirement:
        raise ValueError('Use an Apple-issued signing identity; local ad hoc signatures are not supported for installation.')
    return info['CFBundleIdentifier'], team, requirement


def validate_update(source, installed, run=run_codesign):
    source_id, source_team, source_requirement = metadata(source, run)
    target_id, target_team, target_requirement = metadata(installed, run)
    if source_id != target_id or source_team != target_team:
        raise ValueError('The update changes the bundle ID or signing team. Installation stopped to preserve app identity.')
    # A matching team alone is insufficient: Development and Developer ID
    # signatures can have different designated requirements within one team.
    run('--verify', '--strict', '-R', '=' + target_requirement, str(source))
    run('--verify', '--strict', '-R', '=' + source_requirement, str(installed))


def check_install(source, installed, run=run_codesign):
    metadata(source, run)
    source_widget = source / 'Contents/PlugIns/Print Progress Widget.appex'
    metadata(source_widget, run)
    if installed.exists():
        validate_update(source, installed, run)
        installed_widget = installed / 'Contents/PlugIns/Print Progress Widget.appex'
        if installed_widget.exists():
            validate_update(source_widget, installed_widget, run)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('installed', type=Path)
    args = parser.parse_args()
    try:
        check_install(args.source, args.installed)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
    print('App and widget signing identities are compatible.')
