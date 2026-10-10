#!/usr/bin/env python3
import importlib.util
import json
import os
import sys
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).with_name('apple-build-metadata.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)

QUALIFIED_SPM_LOCK = '40e3e0fbe264adac749a1f7db3f91a311e67f6419eeecad6bd4d88c07efd9410'
QUALIFIED_SPM_PROJECT = 'b698ee86dc410c8ada9251778a655f5428b2ea663ccfc8ba1291f180aa472eca'
QUALIFIED_SPM_TOOLCHAIN = '5e23d2022187a1fa502ad4a6'


class MetadataTests(unittest.TestCase):
    def test_device_metadata_queries_the_selected_device_sdk_without_simulators(self):
        for scheme, sdk in metadata.DEVICE_SDKS.items():
            calls = []
            def command(*args):
                calls.append(args)
                return {('xcodebuild', '-version'): 'Xcode 27.0\nBuild version 27A266a',
                        ('uname', '-m'): 'arm64',
                        ('xcrun', '--sdk', sdk, '--show-sdk-version'): '27.0',
                        ('xcrun', '--sdk', sdk, '--show-sdk-build-version'): '24A100'}[args]
            with self.subTest(scheme=scheme), patch.object(metadata, 'command', command):
                result = metadata.device_toolchain(scheme)
            self.assertEqual(result['sdk'], sdk)
            self.assertEqual(result['sdk_version'], '27.0')
            self.assertEqual(result['sdk_build'], '24A100')
            self.assertEqual(len(calls), 4)
            self.assertNotIn('runtime_build', result)

    def test_device_cache_key_changes_with_actual_sdk_toolchain_and_profile(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / metadata.LOCK).parent.mkdir(parents=True)
            (root / metadata.LOCK).write_text('locked packages')
            (root / 'iosApp/project.yml').write_text('project')
            toolchain = {'xcode_version': '27.0', 'xcode_build': '27A266a',
                         'architecture': 'arm64', 'sdk': 'iphoneos',
                         'sdk_version': '27.0', 'sdk_build': '24A100'}
            with patch.object(metadata, 'command', return_value='a' * 40), \
                    patch.object(metadata, 'toolchains', side_effect=AssertionError('simulator query')), \
                    patch.object(metadata, 'device_toolchain', return_value=toolchain):
                original = metadata.metadata(root, {}, device_scheme='Silo-device')
                self.assertEqual(json.loads(original['toolchain_json']), {'Silo-device': toolchain})
                for key, value in [('xcode_version', '27.1'), ('xcode_build', '27B100'),
                                   ('architecture', 'x86_64'), ('sdk', 'appletvos'),
                                   ('sdk_version', '27.1'), ('sdk_build', '24A101')]:
                    with self.subTest(changed=key), patch.object(
                            metadata, 'device_toolchain', return_value={**toolchain, key: value}):
                        changed = metadata.metadata(root, {}, device_scheme='Silo-device')
                        self.assertNotEqual(original['toolchain_key'], changed['toolchain_key'])
                other = metadata.metadata(root, {}, device_scheme='SiloTV-device')
                self.assertNotEqual(original['toolchain_key'], other['toolchain_key'])

    def test_device_metadata_rejects_missing_or_malformed_sdk_and_architecture(self):
        valid = {('xcodebuild', '-version'): 'Xcode 27.0\nBuild version 27A266a',
                 ('uname', '-m'): 'arm64',
                 ('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'): '27.0',
                 ('xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'): '24A100'}
        for args, value in [(('uname', '-m'), ''), (('uname', '-m'), 'unknown'),
                            (('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'), ''),
                            (('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'), '27.0\nother'),
                            (('xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'), ''),
                            (('xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'), 'bad/build')]:
            with self.subTest(args=args, value=value), patch.object(
                    metadata, 'command', side_effect=lambda *call: {**valid, args: value}[call]):
                with self.assertRaisesRegex(ValueError, 'Device SDK or architecture'):
                    metadata.device_toolchain('Silo-device')

    def test_device_profiles_cannot_be_used_for_simulator_proof_or_benchmarks(self):
        for option in ('--benchmark', '--proof=Silo'):
            with self.subTest(option=option), patch.object(sys, 'argv',
                    ['metadata', '--device-scheme=Silo-device', option]), \
                    patch.object(metadata, 'metadata', side_effect=AssertionError('metadata queried')):
                with self.assertRaises(SystemExit) as error:
                    metadata.main()
                self.assertEqual(error.exception.code, 2)

    def spm_scope(self, env, lock, project, toolchain='', *, source_sha='a' * 40, source_dirty=False):
        return metadata.spm_cache_scope(env, lock, project, toolchain,
                                        source_sha=source_sha, source_dirty=source_dirty)

    def test_rejects_mutable_or_shell_source_and_unsafe_cache_namespace(self):
        for value in ('main', 'a' * 39, 'a' * 40 + '\n', '$(id)', '../other'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.validate_controls({'SILO_BENCHMARK_SOURCE_REF': value})
        for value in ('../cache', 'space here', 'A', 'a' * 33, 'v1\nkey=other'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.validate_controls({'SILO_CACHE_NAMESPACE': value})
        self.assertEqual(metadata.validate_controls({'SILO_CACHE_NAMESPACE': 'bench-1'}), 'bench-1')

    def test_actual_cli_rejects_two_requested_refs_before_source_or_toolchain_work(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for baseline, source in [('a' * 40, 'b' * 40), ('a' * 40, 'a' * 40),
                                     ('refs/tags/historical-baseline', 'b' * 40)]:
                for option in ('--validate-controls', '--outputs', '--benchmark'):
                    with self.subTest(baseline=baseline, source=source, option=option):
                        result = subprocess.run(
                            [sys.executable, str(Path(metadata.__file__).resolve()),
                             '--root', str(root / 'missing-source'), option],
                            cwd=root, env={'PATH': str(root / 'no-tools'),
                                           'SILO_BASELINE_REF': baseline,
                                           'SILO_BENCHMARK_SOURCE_REF': source},
                            capture_output=True, text=True)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn('baseline_ref and benchmark_source_ref cannot be combined',
                                      result.stderr)
                        self.assertEqual(result.stdout, '')

    def test_actual_control_cli_preserves_single_ref_and_explicit_variant_inputs(self):
        valid = [{}, {'SILO_BASELINE_REF': 'refs/tags/historical-baseline',
                      'SILO_BENCH_VARIANT': 'baseline', 'SILO_CACHE_MODE': 'off'},
                 {'SILO_BENCHMARK_SOURCE_REF': 'a' * 40, 'SILO_BENCH_VARIANT': 'optimized'},
                 {'SILO_BENCHMARK_SOURCE_REF': 'a' * 40, 'SILO_BENCH_VARIANT': 'baseline',
                  'SILO_CACHE_MODE': 'off'},
                 {'SILO_BASELINE_REF': 'historical', 'SILO_BENCHMARK_SOURCE_REF': ''},
                 {'SILO_BASELINE_REF': '', 'SILO_BENCHMARK_SOURCE_REF': 'a' * 40},
                 {'SILO_BASELINE_REF': '', 'SILO_BENCHMARK_SOURCE_REF': ''}]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for env in valid:
                with self.subTest(env=env):
                    result = subprocess.run(
                        [sys.executable, str(Path(metadata.__file__).resolve()),
                         '--root', str(root / 'missing-source'), '--validate-controls'],
                        cwd=root, env={'PATH': str(root / 'no-tools'), **env},
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertEqual(result.stderr, '')

    def test_shipping_metadata_rejects_diagnostic_probes_before_source_inspection(self):
        metadata.validate_controls({'SILO_CACHE_PROBE': 'none'})
        for probe in ('fail_test', 'graph_only', '', 'NONE', 'none\nother=value'):
            with self.subTest(probe=probe), patch.dict(os.environ, {'SILO_CACHE_PROBE': probe}, clear=True), \
                    patch.object(sys, 'argv', ['metadata', '--validate-controls']), \
                    patch.object(metadata, 'metadata', side_effect=AssertionError('Source inspection started')), \
                    patch.object(metadata, 'command', side_effect=AssertionError('Toolchain inspection started')):
                with self.assertRaisesRegex(ValueError, 'Diagnostic cache probes'):
                    metadata.main()

    def test_command_is_bounded_and_timeout_is_a_failure(self):
        with patch.object(metadata.subprocess, 'check_output',
                          side_effect=subprocess.TimeoutExpired(('xcrun', 'simctl'), 60)) as run:
            with self.assertRaisesRegex(RuntimeError, 'Build metadata command timed out: xcrun'):
                metadata.command('xcrun', 'simctl', 'list', 'runtimes', '--json')
        self.assertEqual(run.call_args.kwargs['timeout'], 60)
        self.assertNotIn('shell', run.call_args.kwargs)

    def test_xcode_build_is_measured_and_version_output_is_validated(self):
        self.assertEqual(metadata.parse_xcode('Xcode 27.0\nBuild version 27A266a\n'),
                         {'xcode_version': '27.0', 'xcode_build': '27A266a'})
        with self.assertRaises(ValueError):
            metadata.parse_xcode('Xcode 27.0')

    def test_runtime_must_match_platform_sdk_and_be_available(self):
        runtimes = {'runtimes': [
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0',
             'buildversion': '24A100', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.tvOS-27-0', 'version': '27.0',
             'buildversion': '24J100', 'isAvailable': False},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.tvOS-26-0', 'version': '26.0',
             'buildversion': '23J100', 'isAvailable': True}]}
        def command(*args):
            if args == ('xcodebuild', '-version'):
                return 'Xcode 27.0\nBuild version 27A266a'
            if args == ('uname', '-m'):
                return 'arm64'
            if args[-1] == '--show-sdk-build-version':
                return '24A100'
            if args == ('xcrun', 'simctl', 'list', 'runtimes', '--json'):
                return json.dumps(runtimes)
            return '27.0'
        with patch.object(metadata, 'command', command):
            tools = metadata.toolchains()
        self.assertEqual(tools['Silo']['runtime_build'], '24A100')
        self.assertEqual(tools['SiloTV']['runtime_build'], '')
        self.assertNotIn('runtime_build', tools['SiloMac'])

    def runtime_inventory(self, **changes):
        return {'runtimes': [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                             'version': '27.0', 'buildversion': '24A100',
                             'isAvailable': True, **changes}]}

    def live_tool_command(self, *args, cwd=None):
        if args == ('xcodebuild', '-version'):
            return 'Xcode 27.0\nBuild version 27A266a'
        if args[0:2] == ('git', 'rev-parse'):
            return ('a' if args[2] == 'HEAD' else 'b') * 40
        if args[0:2] == ('git', 'status'):
            return ''
        if args == ('uname', '-m'):
            return 'arm64'
        if args[-1] == '--show-sdk-build-version':
            return '24A100'
        if args[-1] == '--show-sdk-version':
            return '27.0'
        raise AssertionError('Unexpected live tool command: ' + repr(args))

    def test_prepared_runtime_uses_the_selected_entry_and_preserves_live_tool_reads(self):
        selected = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0-selected'
        inventory = self.runtime_inventory()
        inventory['runtimes'].append({**inventory['runtimes'][0], 'identifier': selected,
                                      'buildversion': '24A200'})
        with tempfile.TemporaryDirectory() as folder:
            capture = Path(folder) / 'runtimes.json'
            capture.write_text(json.dumps(inventory))
            with patch.object(metadata, 'command', side_effect=self.live_tool_command) as run:
                tools = metadata.toolchains(capture, 'Silo', selected)
        self.assertEqual(tools['Silo']['runtime_build'], '24A200')
        self.assertEqual(tools['Silo']['xcode_build'], '27A266a')
        for sdk in metadata.SDKS.values():
            self.assertIn(('xcrun', '--sdk', sdk, '--show-sdk-version'),
                          [call.args for call in run.call_args_list])
        self.assertNotIn(('xcrun', 'simctl', 'list', 'runtimes', '--json'),
                         [call.args for call in run.call_args_list])

    def test_prepared_runtime_rejects_missing_unavailable_ambiguous_and_stale_identity(self):
        identifier = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
        invalid = [({}, 'Silo', identifier), ({'runtimes': {}}, 'Silo', identifier),
                   ({'runtimes': [None]}, 'Silo', identifier),
                   (self.runtime_inventory(isAvailable=False), 'Silo', identifier),
                   (self.runtime_inventory(isAvailable=1), 'Silo', identifier),
                   (self.runtime_inventory(version='26.0'), 'Silo', identifier),
                   (self.runtime_inventory(buildversion=''), 'Silo', identifier),
                   (self.runtime_inventory(buildversion='24A100\nother=value'), 'Silo', identifier),
                   (self.runtime_inventory(), 'SiloTV', identifier),
                   (self.runtime_inventory(), 'SiloMac', identifier),
                   (self.runtime_inventory(), 'Silo', ''),
                   (self.runtime_inventory(), 'Silo', identifier + '-other'),
                   ({'runtimes': self.runtime_inventory()['runtimes'] * 2}, 'Silo', identifier)]
        with tempfile.TemporaryDirectory() as folder:
            capture = Path(folder) / 'runtimes.json'
            with self.assertRaises(FileNotFoundError):
                metadata.prepared_runtimes(capture, 'Silo', identifier, '27.0')
            for inventory, scheme, selected in invalid:
                with self.subTest(inventory=inventory, scheme=scheme, selected=selected):
                    capture.write_text(json.dumps(inventory))
                    with self.assertRaises(ValueError):
                        metadata.prepared_runtimes(capture, scheme, selected, '27.0')
            for text in ('{', '{"runtimes": [], "runtimes": []}'):
                capture.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    metadata.prepared_runtimes(capture, 'Silo', identifier, '27.0')

    def test_changed_current_sdk_invalidates_the_prepared_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            capture = Path(folder) / 'runtimes.json'
            capture.write_text(json.dumps(self.runtime_inventory()))
            def changed_sdk(*args):
                if args == ('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'):
                    return '27.1'
                return self.live_tool_command(*args)
            with patch.object(metadata, 'command', changed_sdk), self.assertRaises(ValueError):
                metadata.toolchains(capture, 'Silo', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')

    def test_final_metadata_recomputes_source_config_dirty_and_all_sdk_builds(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            lock = root / metadata.LOCK
            lock.parent.mkdir(parents=True)
            lock.write_text('original lock')
            project = root / 'iosApp/project.yml'
            project.write_text('original project')
            capture = root / 'runtime.json'
            capture.write_text(json.dumps(self.runtime_inventory()))
            env = {'SCHEME': 'Silo', 'SILO_TEST_RUNTIME_IDENTIFIER':
                   'com.apple.CoreSimulator.SimRuntime.iOS-27-0'}
            with patch.object(metadata, 'command', side_effect=self.live_tool_command):
                original = metadata.metadata(root, env, capture)
            lock.write_text('changed lock')
            project.write_text('changed project')
            def changed_source(*args, cwd=None):
                if args[0:2] == ('git', 'rev-parse'):
                    return ('c' if args[2] == 'HEAD' else 'd') * 40
                if args[0:2] == ('git', 'status'):
                    return ' M iosApp/Tests/PlaybackTimelineMapperTests.swift'
                return self.live_tool_command(*args, cwd=cwd)
            with patch.object(metadata, 'command', side_effect=changed_source) as run:
                changed = metadata.metadata(root, env, capture)
            self.assertEqual(changed['source_sha'], 'c' * 40)
            self.assertEqual(changed['fingerprint'], 'd' * 40)
            self.assertEqual(changed['source_dirty'], 'true')
            self.assertNotEqual(changed['lock_sha256'], original['lock_sha256'])
            self.assertNotEqual(changed['build_config_sha256'], original['build_config_sha256'])
            for sdk in metadata.SDKS.values():
                self.assertIn(('xcrun', '--sdk', sdk, '--show-sdk-build-version'),
                              [call.args for call in run.call_args_list])

    def test_only_final_benchmark_accepts_the_prepared_inventory(self):
        env = {'SILO_PREPARED_SIMULATOR_RUNTIMES': '/tmp/owned-runtime-inventory.json'}
        for arguments, expected in (([], None), (['--benchmark'], Path(env['SILO_PREPARED_SIMULATOR_RUNTIMES']))):
            with self.subTest(arguments=arguments), patch.dict(os.environ, env, clear=True), \
                    patch.object(sys, 'argv', ['metadata', *arguments]), \
                    patch.object(metadata, 'metadata', return_value={}) as inspect, \
                    patch.object(metadata, 'benchmark', return_value={}), patch('builtins.print'):
                metadata.main()
            self.assertEqual(inspect.call_args.args[2], expected)

    def committed_proof_source(self, root):
        root.mkdir()
        lock = root / metadata.LOCK
        lock.parent.mkdir(parents=True)
        lock.write_text('committed dependency lock\n')
        (root / 'iosApp/project.yml').write_text('committed project\n')
        source = root / 'iosApp/Tests/TrackedSource.swift'
        source.parent.mkdir(parents=True)
        source.write_text('let testedValue = "committed"\n')
        for args in (['git', 'init', '--quiet'], ['git', 'add', '.'],
                     ['git', '-c', 'user.name=CI fixture', '-c', 'user.email=ci-fixture@invalid',
                      'commit', '--quiet', '-m', 'Committed proof fixture']):
            subprocess.run(args, cwd=root, check=True, capture_output=True)
        return source

    def proof_env(self, root, capture, scheme='Silo'):
        return {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF_NAME': 'main',
                'GITHUB_SHA': metadata.command('git', 'rev-parse', 'HEAD', cwd=root),
                'GITHUB_REPOSITORY': 'Silo-Server/silo-apple', 'GITHUB_RUN_ID': '100',
                'GITHUB_RUN_ATTEMPT': '1', 'SILO_FULL_SUITE': 'true', 'SCHEME': scheme,
                'SILO_COMPILATION_CACHE_ENABLED': 'false', 'SILO_BENCHMARK_SOURCE_REF': '',
                'SILO_PREPARED_SIMULATOR_RUNTIMES': str(capture),
                'SILO_TEST_RUNTIME_IDENTIFIER': 'com.apple.CoreSimulator.SimRuntime.' +
                    ('tvOS-27-0' if scheme == 'SiloTV' else 'iOS-27-0')}

    def proof_inventory(self):
        return {'runtimes': [*self.runtime_inventory()['runtimes'],
                            {'identifier': 'com.apple.CoreSimulator.SimRuntime.tvOS-27-0',
                             'version': '27.0', 'buildversion': '24J100', 'isAvailable': True}]}

    def test_actual_cli_produces_captured_mobile_proof_and_live_mac_proof(self):
        original_command = metadata.command
        inventory = self.proof_inventory()
        def command(*args, cwd=None):
            if args[0] == 'git':
                return original_command(*args, cwd=cwd)
            if args == ('xcrun', 'simctl', 'list', 'runtimes', '--json'):
                return json.dumps(inventory)
            return self.live_tool_command(*args, cwd=cwd)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'source'
            self.committed_proof_source(root)
            capture = Path(folder) / 'runtimes.json'
            capture.write_text(json.dumps(inventory))
            for scheme in metadata.SDKS:
                output = Path(folder) / (scheme + '.json')
                env = self.proof_env(root, capture, scheme)
                with self.subTest(scheme=scheme), patch.dict(os.environ, env), \
                        patch.object(sys, 'argv', ['metadata', '--root', str(root), '--proof', scheme,
                                                  '--output', str(output)]), \
                        patch.object(metadata, 'command', side_effect=command) as run:
                    metadata.main()
                value = json.loads(output.read_text())
                self.assertEqual(value['sha'], env['GITHUB_SHA'])
                self.assertEqual(value['fingerprint'], original_command('git', 'rev-parse', 'HEAD^{tree}', cwd=root))
                self.assertTrue(value['full_suite'])
                self.assertEqual(value['toolchain']['architecture'], 'arm64')
                self.assertEqual(value['toolchain']['sdk_build'], '24A100')
                queried = ('xcrun', 'simctl', 'list', 'runtimes', '--json') in [call.args for call in run.call_args_list]
                self.assertEqual(queried, scheme == 'SiloMac')
                if scheme != 'SiloMac':
                    self.assertEqual(value['toolchain']['runtime_build'], '24J100' if scheme == 'SiloTV' else '24A100')

    def test_actual_cli_rejects_invalid_capture_partial_or_changed_source_without_emitting_proof(self):
        original_command = metadata.command
        def command(*args, cwd=None):
            if args[0] == 'git':
                return original_command(*args, cwd=cwd)
            if args == ('xcrun', 'simctl', 'list', 'runtimes', '--json'):
                raise AssertionError('Captured proof repeated runtime discovery')
            if change_sdk and args == ('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'):
                return '27.1'
            return self.live_tool_command(*args, cwd=cwd)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'source'
            source = self.committed_proof_source(root)
            capture = Path(folder) / 'runtimes.json'
            output = Path(folder) / 'proof.json'
            cases = ('dirty_source', 'partial_suite', 'wrong_source', 'untrusted_event',
                     'wrong_branch', 'missing_capture', 'malformed_capture', 'unavailable_runtime',
                     'wrong_runtime', 'wrong_scheme', 'changed_sdk')
            for case in cases:
                source.write_text('let testedValue = "committed"\n')
                capture.write_text(json.dumps(self.proof_inventory()))
                env = self.proof_env(root, capture)
                change_sdk = case == 'changed_sdk'
                if case == 'dirty_source':
                    source.write_text('let testedValue = "uncommitted mutation"\n')
                elif case == 'partial_suite':
                    env['SILO_FULL_SUITE'] = 'false'
                elif case == 'wrong_source':
                    env['GITHUB_SHA'] = 'f' * 40
                elif case == 'untrusted_event':
                    env['GITHUB_EVENT_NAME'] = 'workflow_dispatch'
                elif case == 'wrong_branch':
                    env['GITHUB_REF_NAME'] = 'private/fixture'
                elif case == 'missing_capture':
                    capture.unlink()
                elif case == 'malformed_capture':
                    capture.write_text('{')
                elif case == 'unavailable_runtime':
                    capture.write_text(json.dumps(self.runtime_inventory(isAvailable=False)))
                elif case == 'wrong_runtime':
                    env['SILO_TEST_RUNTIME_IDENTIFIER'] = 'com.apple.CoreSimulator.SimRuntime.tvOS-27-0'
                elif case == 'wrong_scheme':
                    env['SCHEME'] = 'SiloTV'
                with self.subTest(case=case), patch.dict(os.environ, env), \
                        patch.object(sys, 'argv', ['metadata', '--root', str(root), '--proof', 'Silo',
                                                  '--output', str(output)]), \
                        patch.object(metadata, 'command', side_effect=command):
                    if case == 'dirty_source':
                        measured = metadata.metadata(root, env, capture)
                        self.assertEqual(measured['source_sha'], env['GITHUB_SHA'])
                        self.assertEqual(measured['fingerprint'], original_command('git', 'rev-parse', 'HEAD^{tree}', cwd=root))
                        self.assertEqual(measured['source_dirty'], 'true')
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        metadata.main()
                    self.assertFalse(output.exists())

    def test_proof_rechecks_actual_source_after_a_clean_metadata_record(self):
        original_command = metadata.command
        def command(*args, cwd=None):
            if args[0] == 'git':
                return original_command(*args, cwd=cwd)
            return self.live_tool_command(*args, cwd=cwd)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'source'
            source = self.committed_proof_source(root)
            capture = Path(folder) / 'runtimes.json'
            capture.write_text(json.dumps(self.proof_inventory()))
            env = self.proof_env(root, capture)
            with patch.object(metadata, 'command', command):
                clean = metadata.metadata(root, env, capture)
                self.assertEqual(clean['source_dirty'], 'false')
                source.write_text('let testedValue = "mutation after metadata"\n')
                self.assertEqual(original_command('git', 'rev-parse', 'HEAD', cwd=root), clean['source_sha'])
                self.assertEqual(original_command('git', 'rev-parse', 'HEAD^{tree}', cwd=root), clean['fingerprint'])
                with self.assertRaisesRegex(ValueError, 'clean tracked source'):
                    metadata.proof(clean, root, env, 'Silo')

    def test_cache_hit_claim_requires_actual_restore_hit(self):
        result = {'source_sha': 'a' * 40, 'cache_namespace': 'v1',
                  'lock_sha256': 'b' * 64, 'build_config_sha256': 'c' * 64,
                  'toolchain_json': json.dumps({'Silo': {'xcode_build': '27A266a'}})}
        env = {'PLATFORM': 'iOS', 'SILO_SPM_CACHE_HIT': 'false', 'SILO_CACHE_MODE': 'dependencies'}
        self.assertEqual(metadata.benchmark(result, env)['cache_regime'], 'cold')
        self.assertEqual(metadata.benchmark(result, env)['cache_probe'], 'none')
        env['SILO_SPM_CACHE_HIT'] = 'true'
        self.assertEqual(metadata.benchmark(result, env)['cache_regime'], 'warm')
        env.update(SILO_SPM_CACHE_HIT='false', SILO_DERIVED_CACHE_HIT='false',
                   SILO_DERIVED_CACHE_RESTORED='true', SILO_DERIVED_CACHE_KEY='prior-source-key')
        partial = metadata.benchmark(result, env)
        self.assertEqual(partial['cache_regime'], 'warm')
        self.assertFalse(partial['derived_cache_hit'])
        self.assertTrue(partial['derived_cache_restored'])
        self.assertEqual(partial['derived_cache_kind'], 'prefix')
        self.assertEqual(partial['derived_cache_key'], 'prior-source-key')

    def shared_spm_env(self):
        return {'SILO_SPM_CACHE_PROFILE': 'shared_qualified',
                'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REPOSITORY': 'Silo-Server/silo-apple',
                'GITHUB_REF': 'refs/heads/fixture', 'SILO_BENCH_VARIANT': 'optimized',
                'SILO_CACHE_MODE': 'dependencies', 'SCHEME': 'Silo', 'PLATFORM': 'iOS',
                'SILO_SPM_CACHE_SAVE_OWNER': 'SiloMac'}

    def test_shared_spm_scope_requires_qualified_inputs_and_keeps_the_explicit_owner(self):
        for scheme in ('Silo', 'SiloTV', 'SiloMac'):
            for cache_mode in ('dependencies', 'derived_data'):
                for owner in ('Silo', 'SiloTV', 'SiloMac'):
                    env = {**self.shared_spm_env(), 'SCHEME': scheme, 'SILO_CACHE_MODE': cache_mode,
                           'SILO_SPM_CACHE_SAVE_OWNER': owner}
                    with self.subTest(scheme=scheme, cache_mode=cache_mode, owner=owner):
                        self.assertEqual(self.spm_scope(env, QUALIFIED_SPM_LOCK, QUALIFIED_SPM_PROJECT,
                                                                  QUALIFIED_SPM_TOOLCHAIN),
                            {'spm_cache_profile_requested': 'shared_qualified',
                             'spm_cache_profile_effective': 'shared_qualified',
                             'spm_cache_scope': 'shared-qualified-v1', 'spm_cache_save_owner': owner})

    def test_unqualified_shared_requests_fall_back_to_the_current_scheme_and_owner(self):
        cases = {'GITHUB_EVENT_NAME': ('pull_request', 'push', 'workflow_call', ''),
                 'GITHUB_REPOSITORY': ('other/silo-apple', ''),
                 'SILO_BENCH_VARIANT': ('baseline', ''), 'SILO_CACHE_MODE': ('off', ''),
                 'SCHEME': ('SiloDevice', ''), 'SILO_SPM_CACHE_SAVE_OWNER': ('SiloDevice', 'silo', '')}
        for key, values in cases.items():
            for value in values:
                env = {**self.shared_spm_env(), key: value}
                current_scheme = env['SCHEME'] or 'Silo'
                with self.subTest(key=key, value=value):
                    self.assertEqual(self.spm_scope(env, QUALIFIED_SPM_LOCK, QUALIFIED_SPM_PROJECT,
                                                              QUALIFIED_SPM_TOOLCHAIN),
                        {'spm_cache_profile_requested': 'shared_qualified',
                         'spm_cache_profile_effective': 'scheme', 'spm_cache_scope': current_scheme,
                         'spm_cache_save_owner': current_scheme})
        for omitted in ('GITHUB_EVENT_NAME', 'GITHUB_REPOSITORY', 'SILO_BENCH_VARIANT', 'SILO_CACHE_MODE',
                        'SCHEME', 'SILO_SPM_CACHE_SAVE_OWNER'):
            env = self.shared_spm_env()
            del env[omitted]
            with self.subTest(omitted=omitted):
                self.assertEqual(self.spm_scope(env, QUALIFIED_SPM_LOCK, QUALIFIED_SPM_PROJECT,
                                                          QUALIFIED_SPM_TOOLCHAIN),
                    {'spm_cache_profile_requested': 'shared_qualified',
                     'spm_cache_profile_effective': 'scheme', 'spm_cache_scope': 'Silo',
                     'spm_cache_save_owner': 'Silo'})

    def test_either_measured_graph_hash_mismatch_disables_shared_scope(self):
        for lock, project in (('a' * 64, QUALIFIED_SPM_PROJECT),
                              (QUALIFIED_SPM_LOCK, 'b' * 64),
                              ('', QUALIFIED_SPM_PROJECT), (QUALIFIED_SPM_LOCK, '')):
            with self.subTest(lock=lock, project=project):
                result = self.spm_scope(self.shared_spm_env(), lock, project, QUALIFIED_SPM_TOOLCHAIN)
                self.assertEqual(result['spm_cache_profile_requested'], 'shared_qualified')
                self.assertEqual(result['spm_cache_profile_effective'], 'scheme')
                self.assertEqual(result['spm_cache_scope'], 'Silo')
                self.assertEqual(result['spm_cache_save_owner'], 'Silo')

    def test_changed_or_missing_toolchain_key_disables_shared_scope(self):
        for key in ('0' * 24, '', QUALIFIED_SPM_TOOLCHAIN.upper()):
            with self.subTest(toolchain_key=key):
                self.assertEqual(self.spm_scope(self.shared_spm_env(), QUALIFIED_SPM_LOCK,
                                                          QUALIFIED_SPM_PROJECT, key),
                    {'spm_cache_profile_requested': 'shared_qualified', 'spm_cache_profile_effective': 'scheme',
                     'spm_cache_scope': 'Silo', 'spm_cache_save_owner': 'Silo'})
        missing = self.spm_scope(self.shared_spm_env(), QUALIFIED_SPM_LOCK, QUALIFIED_SPM_PROJECT)
        self.assertEqual(missing['spm_cache_profile_effective'], 'scheme')
        self.assertEqual(missing['spm_cache_scope'], 'Silo')
        self.assertEqual(missing['spm_cache_save_owner'], 'Silo')

    def test_scheme_profile_defaults_follow_the_current_scheme_or_platform(self):
        for env, scheme in (({}, 'SiloMac'), ({'PLATFORM': 'iOS'}, 'Silo'),
                            ({'PLATFORM': 'tvOS'}, 'SiloTV'), ({'PLATFORM': 'macOS'}, 'SiloMac'),
                            ({'SCHEME': 'SiloTV', 'PLATFORM': 'iOS',
                              'SILO_SPM_CACHE_SAVE_OWNER': 'SiloMac'}, 'SiloTV')):
            with self.subTest(env=env):
                self.assertEqual(self.spm_scope(env, QUALIFIED_SPM_LOCK, QUALIFIED_SPM_PROJECT,
                                                          QUALIFIED_SPM_TOOLCHAIN),
                    {'spm_cache_profile_requested': 'scheme', 'spm_cache_profile_effective': 'scheme',
                     'spm_cache_scope': scheme, 'spm_cache_save_owner': scheme})
        env = {**self.shared_spm_env(), 'SILO_SPM_CACHE_PROFILE': 'scheme'}
        self.assertEqual(self.spm_scope(env, QUALIFIED_SPM_LOCK, QUALIFIED_SPM_PROJECT,
                                                  QUALIFIED_SPM_TOOLCHAIN)['spm_cache_scope'],
                         'Silo')

    def test_same_repository_pr_main_push_and_inherited_release_events_can_share(self):
        events = ({'GITHUB_EVENT_NAME': 'pull_request', 'SILO_PULL_REQUEST_HEAD_REPOSITORY': 'Silo-Server/silo-apple'},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/main'},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/main', 'SILO_RELEASE_GATE': 'true'},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.0', 'SILO_RELEASE_GATE': 'true'},
                  {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'SILO_RELEASE_GATE': 'true'})
        for changes in events:
            with self.subTest(changes=changes):
                result = self.spm_scope({**self.shared_spm_env(), **changes}, QUALIFIED_SPM_LOCK,
                                        QUALIFIED_SPM_PROJECT, QUALIFIED_SPM_TOOLCHAIN)
                self.assertEqual(result['spm_cache_profile_effective'], 'shared_qualified')

    def test_fork_pr_non_main_push_and_tag_without_release_gate_fall_back(self):
        events = ({'GITHUB_EVENT_NAME': 'pull_request', 'SILO_PULL_REQUEST_HEAD_REPOSITORY': 'fork/silo-apple'},
                  {'GITHUB_EVENT_NAME': 'pull_request', 'SILO_PULL_REQUEST_HEAD_REPOSITORY': ''},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/feature'},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': ''},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.0'},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.0', 'SILO_RELEASE_GATE': 'false'},
                  {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.0', 'SILO_RELEASE_GATE': 'TRUE'})
        for changes in events:
            with self.subTest(changes=changes):
                result = self.spm_scope({**self.shared_spm_env(), **changes}, QUALIFIED_SPM_LOCK,
                                        QUALIFIED_SPM_PROJECT, QUALIFIED_SPM_TOOLCHAIN)
                self.assertEqual(result['spm_cache_profile_effective'], 'scheme')
                self.assertEqual(result['spm_cache_save_owner'], 'Silo')

    def test_dirty_or_unverified_source_falls_back(self):
        sources = (('', False), ('main', False), ('a' * 39, False), ('A' * 40, False), ('0' * 40, False),
                   ('a' * 40 + '\n', False), ('a' * 40, True), ('a' * 40, 'false'), ('a' * 40, None))
        for sha, dirty in sources:
            with self.subTest(sha=sha, dirty=dirty):
                result = self.spm_scope(self.shared_spm_env(), QUALIFIED_SPM_LOCK, QUALIFIED_SPM_PROJECT,
                                        QUALIFIED_SPM_TOOLCHAIN, source_sha=sha, source_dirty=dirty)
                self.assertEqual(result['spm_cache_profile_effective'], 'scheme')
        missing = metadata.spm_cache_scope(self.shared_spm_env(), QUALIFIED_SPM_LOCK,
                                            QUALIFIED_SPM_PROJECT, QUALIFIED_SPM_TOOLCHAIN)
        self.assertEqual(missing['spm_cache_profile_effective'], 'scheme')

    def test_metadata_qualifies_the_actual_commit_and_tracked_source_state(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / metadata.LOCK).parent.mkdir(parents=True)
            (root / metadata.LOCK).write_text('fixture lock')
            (root / 'iosApp/project.yml').write_text('fixture project')
            for status, expected_dirty in (('', False), (' M iosApp/project.yml', True)):
                def command(*args, cwd=None):
                    if args == ('git', 'rev-parse', 'HEAD'):
                        return 'a' * 40
                    if args == ('git', 'rev-parse', 'HEAD^{tree}'):
                        return 'b' * 40
                    if args == ('git', 'status', '--porcelain', '--untracked-files=no'):
                        return status
                    return 'fixture toolchain'
                with self.subTest(status=status), patch.object(metadata, 'command', command), \
                        patch.object(metadata, 'toolchains', return_value={scheme: {'xcode_build': '27A266a', 'architecture': 'arm64', 'sdk_build': 'fixture-sdk-build'} for scheme in metadata.SDKS}), \
                        patch.object(metadata, 'spm_cache_scope', wraps=metadata.spm_cache_scope) as scope:
                    result = metadata.metadata(root, self.shared_spm_env())
                self.assertEqual(scope.call_args.kwargs, {'source_sha': 'a' * 40, 'source_dirty': expected_dirty})
                self.assertEqual(result['source_dirty'], str(expected_dirty).lower())

    def test_unknown_spm_profile_fails_before_source_or_toolchain_inspection(self):
        for profile in ('shared', 'SHARED_QUALIFIED', 'shared_qualified\nother=value', ''):
            env = {**self.shared_spm_env(), 'SILO_SPM_CACHE_PROFILE': profile}
            with self.subTest(profile=profile), patch.dict(os.environ, env, clear=True), \
                    patch.object(sys, 'argv', ['metadata', '--validate-controls']), \
                    patch.object(metadata, 'metadata', side_effect=AssertionError('Source inspection started')), \
                    patch.object(metadata, 'command', side_effect=AssertionError('Toolchain inspection started')):
                with self.assertRaises(ValueError):
                    metadata.main()

    def test_benchmark_marker_reports_the_measured_scope_even_after_requested_profile_falls_back(self):
        result = {'source_sha': 'a' * 40, 'cache_namespace': 'v1', 'source_dirty': 'false',
                  'lock_sha256': QUALIFIED_SPM_LOCK, 'build_config_sha256': 'c' * 64,
                  'toolchain_key': QUALIFIED_SPM_TOOLCHAIN,
                  'toolchain_json': json.dumps({'Silo': {'xcode_build': '27A266a'}}),
                  'spm_cache_profile_requested': 'shared_qualified'}
        profiles = (('shared_qualified', 'shared-qualified-v1', 'SiloMac', QUALIFIED_SPM_PROJECT,
                     QUALIFIED_SPM_TOOLCHAIN),
                    ('scheme', 'Silo', 'Silo', '0' * 64, QUALIFIED_SPM_TOOLCHAIN),
                    ('scheme', 'Silo', 'Silo', QUALIFIED_SPM_PROJECT, '0' * 24))
        for effective, scope, owner, project, toolchain in profiles:
            fields = {'spm_cache_profile_effective': effective, 'spm_cache_scope': scope,
                      'spm_cache_save_owner': owner}
            with self.subTest(effective=effective, project=project, toolchain=toolchain):
                marker = metadata.benchmark({**result, 'project_yml_sha256': project, 'toolchain_key': toolchain},
                                            self.shared_spm_env())
                self.assertEqual(marker['spm_cache_profile_requested'], 'shared_qualified')
                for key, value in fields.items():
                    self.assertEqual(marker[key], value)
                self.assertTrue(marker['timing_eligible'])


    def compilation_env(self):
        return {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'SILO_BENCH_VARIANT': 'optimized',
                'SILO_CACHE_MODE': 'derived_data', 'SILO_COMPILATION_CACHE_ENABLED': 'true',
                'SILO_BENCHMARK_PLATFORM': 'ios', 'PLATFORM': 'iOS'}

    def test_compilation_cache_requires_manual_optimized_derived_data(self):
        env = self.compilation_env()
        self.assertEqual(metadata.compilation_cache_profile(env), 'compilation-cache-v1')
        self.assertEqual(metadata.compilation_cache_profile({}), 'standard')
        for key, values in {'GITHUB_EVENT_NAME': ('pull_request', 'push', 'workflow_call', ''),
                            'SILO_BENCH_VARIANT': ('baseline', ''),
                            'SILO_CACHE_MODE': ('off', 'dependencies', ''),
                            'SILO_COMPILATION_CACHE_ENABLED': ('TRUE', '1', 'true\n')}.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    metadata.validate_controls({**env, key: value})

    def test_early_control_validation_does_not_inspect_or_build_source(self):
        with patch.dict(os.environ, self.compilation_env(), clear=True), \
                patch.object(sys, 'argv', ['metadata', '--validate-controls']), \
                patch.object(metadata, 'metadata', side_effect=AssertionError('Source preparation started')):
            metadata.main()
        with patch.dict(os.environ, {**self.compilation_env(), 'SILO_CACHE_MODE': 'off'}, clear=True), \
                patch.object(sys, 'argv', ['metadata', '--validate-controls']), \
                patch.object(metadata, 'metadata', side_effect=AssertionError('Source preparation started')):
            with self.assertRaisesRegex(ValueError, 'requires the derived_data'):
                metadata.main()

    def test_compilation_profile_reports_dirty_source_and_excludes_timing(self):
        result = {'source_sha': 'a' * 40, 'cache_namespace': 'v1', 'source_dirty': 'true',
                  'lock_sha256': 'b' * 64, 'build_config_sha256': 'c' * 64,
                  'toolchain_json': json.dumps({'Silo': {'xcode_build': '27A266a'}})}
        env = {**self.compilation_env(), 'SILO_DERIVED_CACHE_RESTORED': 'true'}
        marker = metadata.benchmark(result, env)
        self.assertTrue(marker['compilation_cache_enabled'])
        self.assertTrue(marker['compilation_cache_diagnostic_remarks'])
        self.assertEqual(marker['compilation_cache_profile'], 'compilation-cache-v1')
        self.assertTrue(marker['source_dirty'])
        self.assertFalse(marker['timing_eligible'])
        self.assertEqual(marker['source_sha'], 'a' * 40)
        clean = metadata.benchmark({**result, 'source_dirty': 'false'},
                                   env)
        self.assertTrue(clean['timing_eligible'])
        normal = metadata.benchmark({**result, 'source_dirty': 'false'}, {'PLATFORM': 'iOS'})
        self.assertFalse(normal['compilation_cache_enabled'])
        self.assertEqual(normal['compilation_cache_profile'], 'standard')

    def test_actions_output_rejects_multiline_values(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                metadata.emit_outputs({'toolchain_key': 'one\nother=two'}, Path(folder) / 'output')


if __name__ == '__main__':
    unittest.main()
