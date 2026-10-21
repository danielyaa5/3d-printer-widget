#!/usr/bin/env python3
"""Fail if app/widget metadata cannot resolve the action used by widget buttons."""
import argparse
import json
import pathlib

p = argparse.ArgumentParser()
p.add_argument('app', type=pathlib.Path)
a = p.parse_args().app
root = a / 'Contents' if (a / 'Contents').is_dir() else a
resources = root / 'Resources' if (root / 'Resources').is_dir() else root
extension = next((root / 'PlugIns').glob('*.appex'))
ext_root = extension / 'Contents' if (extension / 'Contents').is_dir() else extension
ext_resources = ext_root / 'Resources' if (ext_root / 'Resources').is_dir() else ext_root
for directory in (resources, ext_resources):
    data = json.loads((directory / 'Metadata.appintents/extract.actionsdata').read_text())
    action = data['actions'].get('WidgetPrintActionIntent')
    assert action and action['identifier'] == 'WidgetPrintActionIntent', 'Widget action is absent or mismatched'
    assert action['openAppWhenRun'] is False
    assert action['authenticationPolicy'] == 2, 'Printer controls require device authentication'
    assert {p['name'] for p in action['parameters']} == {'context', 'command'}
# The extractor does not evaluate interpolated custom persistentIdentifier values.
# A runtime value differing from the generated identifier silently breaks clicks.
source = pathlib.Path(__file__).resolve().parents[1] / 'Shared/WidgetPrinterControl.swift'
assert 'persistentIdentifier' not in source.read_text(), 'Recheck runtime versus extracted intent identifiers'
print('PASS: app and widget expose matching, authenticated action metadata.')
