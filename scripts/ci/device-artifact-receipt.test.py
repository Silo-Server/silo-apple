#!/usr/bin/env python3
"""Exercise real ZIP/filesystem validation with injected native tool results."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import stat
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import warnings
import zipfile

spec = importlib.util.spec_from_file_location('receipt', Path(__file__).with_name('device-artifact-receipt.py'))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)
SHA, CONTROLLER = 'a' * 40, 'b' * 40


class Fixture:
    def __init__(self, root, platform='ios', signature='unsigned'):
        self.platform, self.signature, self.calls = platform, signature, []
        name, sdk, supported, self.platforms, extensions = receipt.TARGETS[platform]
        self.archive, self.ipa = root / 'app.xcarchive', root / 'app.ipa'
        self.app = self.archive / 'Products/Applications' / (name + '.app')
        self.toolchain = {'sdk': sdk, 'sdk_version': '27.0', 'sdk_build': '24A430',
                          'xcode_build': '27A266a', 'architecture': 'arm64'}
        for bundle, identifier in [(self.app, 'org.siloserver.silo'),
                                   *[(self.app / 'PlugIns' / path, identifier)
                                     for path, identifier in extensions.items()]]:
            bundle.mkdir(parents=True)
            info = {'CFBundleExecutable': bundle.stem, 'CFBundleIdentifier': identifier,
                    'CFBundlePackageType': 'APPL' if bundle == self.app else 'XPC!',
                    'CFBundleVersion': receipt.BUILD, 'CFBundleShortVersionString': receipt.VERSION,
                    'CFBundleSupportedPlatforms': [supported], 'DTPlatformName': sdk,
                    'DTSDKBuild': '24A430', 'DTSDKName': sdk + '27.0', 'DTXcodeBuild': '27A266a'}
            if bundle == self.app:
                info.update(SiloBuildChannel='sideload', SiloSourceURL=receipt.SOURCE_PREFIX + SHA + '.tar.gz')
            (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
            (bundle / bundle.stem).write_bytes(bytes.fromhex('cffaedfe') + b'fixture binary')
            (bundle / bundle.stem).chmod(0o755)
        framework = self.app / 'Frameworks/Example.framework'
        framework.mkdir(parents=True)
        (framework / 'Example').write_bytes(bytes.fromhex('cffaedfe') + b'fixture framework')
        (framework / 'Example').chmod(0o755)
        (self.app / 'resource.txt').write_text('actual resource bytes')
        (self.app / 'linked-resource').symlink_to('resource.txt')
        self.argv = ['xcodebuild', 'archive', '-scheme', name, '-destination',
                     'generic/platform=' + {'ios': 'iOS', 'tvos': 'tvOS'}[platform],
                     '-archivePath', str(self.archive), 'CODE_SIGNING_ALLOWED=NO',
                     'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'CODE_SIGN_ENTITLEMENTS=',
                     'SILO_BUILD_CHANNEL=sideload', 'MARKETING_VERSION=' + receipt.VERSION,
                     'CURRENT_PROJECT_VERSION=' + receipt.BUILD,
                     'SILO_SOURCE_URL=' + receipt.SOURCE_PREFIX + SHA + '.tar.gz']
        if platform == 'tvos':
            self.argv.append('SILO_USER_INDEPENDENT_KEYCHAIN=NO')
        self.repack()

    def repack(self, timestamp=(2026, 10, 7, 12, 0, 0)):
        prefix = 'Payload/' + self.app.name
        with zipfile.ZipFile(self.ipa, 'w') as archive:
            info = zipfile.ZipInfo('Payload/', timestamp)
            info.create_system, info.external_attr = 3, (stat.S_IFDIR | 0o755) << 16
            archive.writestr(info, b'')
            for entry in receipt.app_manifest(self.app, prefix):
                suffix = '/' if entry['type'] == 'directory' else ''
                info = zipfile.ZipInfo(entry['path'] + suffix, timestamp)
                info.create_system = 3
                kind = {'directory': stat.S_IFDIR, 'file': stat.S_IFREG, 'symlink': stat.S_IFLNK}[entry['type']]
                info.external_attr = (kind | entry['mode']) << 16
                if entry['type'] == 'file':
                    data = (self.app / entry['path'][len(prefix) + 1:]).read_bytes()
                else:
                    data = entry.get('target', '').encode()
                archive.writestr(info, data)

    def runner(self, argv):
        self.calls.append(argv)
        if argv[1:3] == ['lipo', '-archs']:
            return 0, b'arm64\n', b''
        if argv[1] == 'otool':
            text = ('file:\n cmd LC_BUILD_VERSION\n platform ' + sorted(self.platforms)[0] +
                    '\n sdk 27.0\n minos 17.0\n uuid 1234-ABCD\n')
            if self.signature != 'unsigned':
                text += ' cmd LC_CODE_SIGNATURE\n'
            return 0, text.encode(), b''
        if '--entitlements' in argv:
            return 0, plistlib.dumps({}), b''
        if '--verify' in argv:
            return 0, b'', b''
        if self.signature == 'unsigned':
            return 1, b'', b'fixture: code object is not signed at all\n'
        if self.signature == 'certificate':
            return 0, b'', b'Signature=adhoc\nAuthority=Developer Test\nTeamIdentifier=not set\n'
        return 0, b'', b'Signature=adhoc\nTeamIdentifier=not set\n'

    def inspect(self, runner=None):
        return receipt.inspect(self.archive, self.ipa, self.platform, SHA, CONTROLLER,
                               self.toolchain, self.argv, runner or self.runner)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)

    def tearDown(self):
        self.folder.cleanup()

    def test_both_platforms_include_every_extension_and_framework_executable(self):
        for platform, binaries in [('ios', 4), ('tvos', 3)]:
            with self.subTest(platform=platform):
                root = self.root / platform
                root.mkdir()
                fixture = Fixture(root, platform)
                result = fixture.inspect()
                self.assertTrue(result['qualified'])
                self.assertEqual(len(result['native']), binaries)
                self.assertEqual(len([a for a in fixture.calls if a[1:3] == ['lipo', '-archs']]), binaries)
                self.assertIn('symlink', {e['type'] for e in result['members']})

    def test_linker_adhoc_is_accepted_but_certificate_or_entitlements_are_rejected(self):
        fixture = Fixture(self.root, signature='adhoc')
        self.assertEqual({s['signature'] for n in fixture.inspect()['native'].values()
                          for s in n['slices']}, {'adhoc-no-identity'})
        fixture.signature = 'certificate'
        with self.assertRaisesRegex(ValueError, 'Certificate or team'):
            fixture.inspect()
        fixture.signature = 'adhoc'
        def entitled(argv):
            return (0, plistlib.dumps({'application-identifier': 'TEST.app'}), b'') if '--entitlements' in argv else fixture.runner(argv)
        with self.assertRaisesRegex(ValueError, 'entitlements'):
            fixture.inspect(entitled)

    def test_invalid_adhoc_reports_payload_path_exit_and_bounded_stderr(self):
        fixture = Fixture(self.root, signature='adhoc')
        binary = fixture.app / 'Frameworks/Example.framework/Example'
        for suffix in ('code or signature modified', 'code or signature modified ' + 'x' * 1000):
            with self.subTest(suffix_length=len(suffix)):
                def invalid(argv):
                    if '--verify' in argv and argv[-1] == str(binary):
                        detail = (str(binary) + ': ' + suffix).encode()
                        return 7, b'', detail
                    return fixture.runner(argv)
                with self.assertRaises(ValueError) as failure:
                    fixture.inspect(invalid)
                message = str(failure.exception)
                self.assertIn('Silo.app/Frameworks/Example.framework/Example', message)
                self.assertIn('exit=7', message)
                self.assertIn('stderr=Example: code or signature modified', message)
                self.assertNotIn(str(fixture.archive), message)
                self.assertLessEqual(len(message), 300)

    def test_unknown_codesign_failure_is_not_unsigned_proof(self):
        fixture = Fixture(self.root)
        def malformed(argv):
            return (1, b'', b'malformed code object') if argv[0] == 'codesign' else fixture.runner(argv)
        with self.assertRaisesRegex(ValueError, 'Unknown or malformed'):
            fixture.inspect(malformed)

    def test_every_fat_slice_is_checked_for_identity_and_entitlements(self):
        fixture = Fixture(self.root, signature='adhoc')
        def fat(argv):
            return (0, b'arm64 arm64e\n', b'') if argv[1:3] == ['lipo', '-archs'] else fixture.runner(argv)
        result = fixture.inspect(fat)
        self.assertTrue(all(len(n['slices']) == 2 for n in result['native'].values()))
        for binary in result['native']:
            for architecture in ('arm64', 'arm64e'):
                self.assertIn(['codesign', '-d', '--architecture', architecture, '--verbose=4',
                               str(fixture.app / binary)], fixture.calls)
                self.assertIn(['codesign', '-d', '--architecture', architecture, '--entitlements', ':-',
                               str(fixture.app / binary)], fixture.calls)
        def certificate_slice(argv):
            if argv[0] == 'codesign' and '--architecture' in argv and 'arm64e' in argv and '--verbose=4' in argv:
                return 0, b'', b'Signature=adhoc\nAuthority=Developer Test\nTeamIdentifier=not set\n'
            return fat(argv)
        with self.assertRaisesRegex(ValueError, 'Certificate or team'):
            fixture.inspect(certificate_slice)
        def entitled_slice(argv):
            if '--entitlements' in argv and 'arm64e' in argv:
                return 0, plistlib.dumps({'application-identifier': 'TEST.app'}), b''
            return fat(argv)
        with self.assertRaisesRegex(ValueError, 'entitlements'):
            fixture.inspect(entitled_slice)

    def test_device_architecture_does_not_accept_a_simulator_platform(self):
        fixture = Fixture(self.root)
        def simulator(argv):
            result = fixture.runner(argv)
            return (0, result[1].replace(b'platform 2', b'platform 7'), b'') if argv[1] == 'otool' else result
        with self.assertRaisesRegex(ValueError, 'device build platform'):
            fixture.inspect(simulator)

    def test_conflicting_signing_flags_are_rejected(self):
        fixture = Fixture(self.root)
        fixture.argv.append('CODE_SIGNING_ALLOWED=YES')
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            fixture.inspect()

    def test_wrong_versions_are_rejected(self):
        fixture = Fixture(self.root)
        info = plistlib.loads((fixture.app / 'Info.plist').read_bytes())
        info['CFBundleVersion'] = '1'
        (fixture.app / 'Info.plist').write_bytes(plistlib.dumps(info))
        fixture.repack()
        with self.assertRaisesRegex(ValueError, 'Bundle metadata mismatch'):
            fixture.inspect()

    def test_missing_extension_is_rejected(self):
        fixture = Fixture(self.root)
        shutil.rmtree(fixture.app / 'PlugIns/SiloDownloadsActivity.appex')
        fixture.repack()
        with self.assertRaisesRegex(ValueError, 'extension inventory'):
            fixture.inspect()

    def test_extensions_must_reside_in_plugins(self):
        fixture = Fixture(self.root)
        (fixture.app / 'Resources').mkdir()
        shutil.move(fixture.app / 'PlugIns/SiloDownloadsActivity.appex', fixture.app / 'Resources')
        fixture.repack()
        with self.assertRaisesRegex(ValueError, 'extension inventory'):
            fixture.inspect()

    def test_actual_executable_sdk_must_match_measured_toolchain(self):
        fixture = Fixture(self.root)
        def old_sdk(argv):
            result = fixture.runner(argv)
            return (0, result[1].replace(b'sdk 27.0', b'sdk 26.0'), b'') if argv[1] == 'otool' else result
        with self.assertRaisesRegex(ValueError, 'wrong SDK'):
            fixture.inspect(old_sdk)

    def test_malformed_signature_command_cannot_be_classified_unsigned(self):
        fixture = Fixture(self.root)
        def malformed(argv):
            result = fixture.runner(argv)
            return (0, result[1] + b' cmd LC_CODE_SIGNATURE\n', b'') if argv[1] == 'otool' else result
        with self.assertRaisesRegex(ValueError, 'Unknown or malformed'):
            fixture.inspect(malformed)

    def test_provisioning_profile_is_rejected(self):
        fixture = Fixture(self.root)
        (fixture.app / 'embedded.mobileprovision').write_bytes(b'not a permitted signing profile')
        fixture.repack()
        with self.assertRaisesRegex(ValueError, 'Provisioning'):
            fixture.inspect()

    def test_ipa_must_match_archive_app_bytes(self):
        fixture = Fixture(self.root)
        (fixture.app / 'resource.txt').write_text('archive changed after packaging')
        with self.assertRaisesRegex(ValueError, 'differs from archived app'):
            fixture.inspect()

    def test_archive_subtree_symlink_cannot_replace_a_framework(self):
        fixture = Fixture(self.root)
        framework = fixture.app / 'Frameworks/Example.framework'
        outside = self.root / 'outside-framework'
        shutil.move(framework, outside)
        framework.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Unsafe symlink'):
            receipt.app_manifest(fixture.app, 'Payload/' + fixture.app.name)

    def test_archive_products_and_applications_must_be_real_directories(self):
        for directory in ('Products', 'Products/Applications'):
            with self.subTest(directory=directory):
                root = self.root / directory.replace('/', '-')
                root.mkdir()
                fixture = Fixture(root)
                original = fixture.archive / directory
                outside = root / 'outside'
                shutil.move(original, outside)
                original.symlink_to(outside, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, 'must be real directories'):
                    fixture.inspect()

    def test_extension_cannot_reuse_another_bundle_executable_via_symlink(self):
        fixture = Fixture(self.root)
        binary = fixture.app / 'PlugIns/SiloNotificationService.appex/SiloNotificationService'
        binary.unlink()
        binary.symlink_to('../../Silo')
        fixture.repack()
        with self.assertRaisesRegex(ValueError, 'own regular file'):
            fixture.inspect()

    def test_each_bundle_binary_requires_executable_permission(self):
        fixture = Fixture(self.root)
        for binary in (fixture.app / 'Silo', fixture.app / 'PlugIns/SiloDownloadsActivity.appex/SiloDownloadsActivity'):
            with self.subTest(binary=binary):
                binary.chmod(0o644)
                fixture.repack()
                with self.assertRaisesRegex(ValueError, 'execute permission'):
                    fixture.inspect()
                binary.chmod(0o755)

    def test_duplicate_traversal_and_additional_app_members_are_rejected(self):
        fixture = Fixture(self.root)
        for name in ('Payload/' + fixture.app.name + '/resource.txt', '../escape', 'Payload/Other.app/file'):
            with self.subTest(name=name):
                fixture.repack()
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', UserWarning)
                    with zipfile.ZipFile(fixture.ipa, 'a') as archive:
                        archive.writestr(name, b'untrusted')
                with self.assertRaises(ValueError):
                    fixture.inspect()

    def test_embedded_nul_raw_zip_names_are_rejected_before_python_truncation(self):
        fixture = Fixture(self.root)
        with zipfile.ZipFile(fixture.ipa) as archive:
            entries = [(info, archive.read(info)) for info in archive.infolist()]
        with zipfile.ZipFile(fixture.ipa, 'w') as archive:
            for info, data in entries:
                if info.filename.endswith('/resource.txt'):
                    info.filename += 'XXXX'
                    info.orig_filename = info.filename
                archive.writestr(info, data)
        encoded = fixture.ipa.read_bytes()
        self.assertEqual(encoded.count(b'resource.txtXXXX'), 2)
        fixture.ipa.write_bytes(encoded.replace(b'resource.txtXXXX', b'resource.txt\0ZZZ'))
        with zipfile.ZipFile(fixture.ipa) as archive:
            affected = archive.getinfo('Payload/Silo.app/resource.txt')
            self.assertIn('\0', affected.orig_filename)
            self.assertEqual(archive.read(affected), b'actual resource bytes')
        with self.assertRaisesRegex(ValueError, 'NUL IPA member name'):
            fixture.inspect()

    def test_symlinks_cannot_escape_or_form_cycles(self):
        fixture = Fixture(self.root)
        link = fixture.app / 'linked-resource'
        link.unlink()
        link.symlink_to('../../outside')
        with self.assertRaisesRegex(ValueError, 'escapes app'):
            receipt.app_manifest(fixture.app, 'Payload/' + fixture.app.name)
        link.unlink()
        link.symlink_to('linked-resource')
        with self.assertRaisesRegex(ValueError, 'cycle'):
            receipt.app_manifest(fixture.app, 'Payload/' + fixture.app.name)

    def test_zip_wrapper_dates_are_reported_without_erasing_payload_differences(self):
        fixture = Fixture(self.root)
        first = fixture.inspect()
        fixture.repack((2026, 10, 7, 13, 0, 0))
        second = fixture.inspect()
        result = receipt.compare([first, second])
        self.assertTrue(result['qualified'])
        self.assertFalse(result['zip_wrapper_identical'])
        self.assertNotEqual(first['raw_ipa_sha256'], second['raw_ipa_sha256'])
        (fixture.app / 'resource.txt').write_text('payload timestamp=2026-10-07T13:00:00Z')
        fixture.repack()
        result = receipt.compare([first, fixture.inspect()])
        self.assertFalse(result['qualified'])
        self.assertIn('members', {d['field'] for d in result['differences']})

    def test_source_toolchain_and_native_payload_mutations_fail_parity(self):
        fixture = Fixture(self.root)
        original = fixture.inspect()
        for field, value in [('source_sha', 'c' * 40), ('toolchain', {'sdk': 'wrong'}), ('native', {})]:
            altered = copy.deepcopy(original)
            altered[field] = value
            if not value:
                with self.assertRaises(ValueError):
                    receipt.compare([original, altered])
            else:
                self.assertFalse(receipt.compare([original, altered])['qualified'])
        executable = fixture.app / fixture.app.stem
        executable.write_bytes(executable.read_bytes() + b'changed native UUID or code bytes')
        fixture.repack()
        self.assertFalse(receipt.compare([original, fixture.inspect()])['qualified'])

    def test_incomplete_or_failed_receipts_cannot_prove_parity(self):
        fixture = Fixture(self.root)
        original = fixture.inspect()
        for altered in [{'qualified': True}, {**original, 'qualified': False}, {**original, 'members': []}]:
            with self.subTest(altered=altered.get('qualified')), self.assertRaises(ValueError):
                receipt.compare([original, altered])

    def test_cli_total_deadline_emits_an_unqualified_receipt(self):
        fixture = Fixture(self.root)
        toolchain, argv, output = self.root / 'toolchain.json', self.root / 'argv.json', self.root / 'result.json'
        toolchain.write_text(json.dumps(fixture.toolchain))
        argv.write_text(json.dumps(fixture.argv))
        args = ['receipt', 'inspect', '--archive', str(fixture.archive), '--ipa', str(fixture.ipa),
                '--platform', 'ios', '--source-sha', SHA, '--controller-sha', CONTROLLER,
                '--toolchain', str(toolchain), '--archive-argv', str(argv), '--output', str(output)]
        alarm = signal.alarm
        with patch.object(sys, 'argv', args), patch.object(receipt, 'inspect', side_effect=lambda *a: time.sleep(3)), \
                patch.object(receipt.signal, 'alarm', side_effect=lambda seconds: alarm(1 if seconds else 0)):
            self.assertEqual(receipt.main(), 1)
        result = json.loads(output.read_text())
        self.assertFalse(result['qualified'])
        self.assertIn('TimeoutError', result['error'])

    def test_cli_missing_inspect_input_emits_an_unqualified_receipt(self):
        output = self.root / 'result.json'
        with patch.object(sys, 'argv', ['receipt', 'inspect', '--output', str(output)]):
            self.assertEqual(receipt.main(), 1)
        result = json.loads(output.read_text())
        self.assertFalse(result['qualified'])
        self.assertIn('Inspect requires', result['error'])


if __name__ == '__main__':
    unittest.main()
