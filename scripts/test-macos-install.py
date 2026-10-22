#!/usr/bin/env python3
"""Focused identity-guard tests; no real app or OS registration is changed."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('guard', Path(__file__).with_name('check-macos-install.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class InstallIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / 'new.app'
        self.installed = Path(self.temp.name) / 'old.app'
        self.signatures = {}
        self.requirement_checks = []
        for bundle in (self.source, self.installed):
            self.bundle(bundle)
            self.bundle(bundle / 'Contents/PlugIns/Print Progress Widget.appex', 'example.PrintProgress.widget')

    def bundle(self, path, identifier='example.PrintProgress', team='TESTTEAM', requirement='anchor apple generic and identifier "example.PrintProgress"'):
        (path / 'Contents').mkdir(parents=True, exist_ok=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        self.signatures[str(path)] = (team, requirement)

    def codesign(self, *args):
        team, requirement = self.signatures[args[-1]]
        if args[0] == '-d':
            return f'TeamIdentifier={team}\ndesignated => {requirement}\n'
        self.requirement_checks.append(args)
        if args[args.index('-R') + 1] != '=' + requirement:
            raise ValueError('Requirement does not match')
        return ''

    def testCompatibleUpdateChecksBothAppAndWidgetInBothDirections(self):
        guard.check_install(self.source, self.installed, self.codesign)
        self.assertEqual({args[-1] for args in self.requirement_checks}, set(self.signatures))

    def testTeamChangeStopsBeforeReplacement(self):
        self.signatures[str(self.source)] = ('OTHERTEAM', self.signatures[str(self.source)][1])
        with self.assertRaisesRegex(ValueError, 'signing team'):
            guard.check_install(self.source, self.installed, self.codesign)

    def testBundleRenameStopsBeforeReplacement(self):
        self.bundle(self.source, identifier='example.OtherApp')
        with self.assertRaisesRegex(ValueError, 'bundle ID'):
            guard.check_install(self.source, self.installed, self.codesign)

    def testCertificateChannelChangeWithinSameTeamIsRejected(self):
        self.signatures[str(self.source)] = ('TESTTEAM', 'anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM"')
        with self.assertRaisesRegex(ValueError, 'Requirement'):
            guard.check_install(self.source, self.installed, self.codesign)

    def testWidgetIdentityCannotDriftIndependently(self):
        path = str(self.source / 'Contents/PlugIns/Print Progress Widget.appex')
        self.signatures[path] = ('OTHERTEAM', self.signatures[path][1])
        with self.assertRaisesRegex(ValueError, 'signing team'):
            guard.check_install(self.source, self.installed, self.codesign)

    def testAdHocBuildIsRejectedEvenOnFirstInstall(self):
        self.signatures[str(self.source)] = ('not set', 'cdhash H"001122"')
        with self.assertRaisesRegex(ValueError, 'Apple-issued'):
            guard.check_install(self.source, Path(self.temp.name) / 'absent.app', self.codesign)


if __name__ == '__main__':
    unittest.main()
