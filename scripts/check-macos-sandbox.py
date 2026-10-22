#!/usr/bin/env python3
"""Check the signed app and widget's sandbox, network, and shared Keychain access.

Read-only. Prints no signing accounts, group identifiers, or connection data.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess


def entitlements(bundle):
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True, capture_output=True)
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)],
                            check=True, capture_output=True)
    return plistlib.loads(result.stdout)


def check(bundle):
    groups = []
    for label, path in [('app', bundle), ('widget', bundle / 'Contents/PlugIns/Print Progress Widget.appex')]:
        signed = entitlements(path)
        for key in ['com.apple.security.app-sandbox', 'com.apple.security.network.client']:
            if signed.get(key) is not True:
                raise ValueError(f'The {label} is missing {key}.')
        if any(key.startswith('com.apple.security.temporary-exception') for key in signed):
            raise ValueError(f'The {label} requests a temporary sandbox exception.')
        info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
        group = info.get('PrintProgressKeychainGroup')
        if not group or '$(' in group or group not in signed.get('keychain-access-groups', []):
            raise ValueError(f'The {label} has no resolved shared Keychain entitlement.')
        groups.append(group)
        print(f'{label}: signature, App Sandbox, outgoing network, and shared Keychain entitlement verified.')
    if groups[0] != groups[1]:
        raise ValueError('App and widget use different shared Keychain groups.')
    print('App and widget share the same Keychain group; no temporary sandbox exceptions.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        check(args.app)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, plistlib.InvalidFileException):
        parser.exit(1, 'Sandbox verification failed; check the signed entitlements and shared Keychain configuration.\n')
