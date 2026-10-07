#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).with_name('apple-build-metadata.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class MetadataTests(unittest.TestCase):
    def test_rejects_mutable_or_shell_source_and_unsafe_cache_namespace(self):
        for value in ('main', 'a' * 39, 'a' * 40 + '\n', '$(id)', '../other'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.validate_controls({'SILO_BENCHMARK_SOURCE_REF': value})
        for value in ('../cache', 'space here', 'A', 'a' * 33, 'v1\nkey=other'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.validate_controls({'SILO_CACHE_NAMESPACE': value})
        self.assertEqual(metadata.validate_controls({'SILO_CACHE_NAMESPACE': 'bench-1'}), 'bench-1')

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

    def test_cache_hit_claim_requires_actual_restore_hit(self):
        result = {'source_sha': 'a' * 40, 'cache_namespace': 'v1',
                  'lock_sha256': 'b' * 64, 'build_config_sha256': 'c' * 64,
                  'toolchain_json': json.dumps({'Silo': {'xcode_build': '27A266a'}})}
        env = {'PLATFORM': 'iOS', 'SILO_SPM_CACHE_HIT': 'false', 'SILO_CACHE_MODE': 'dependencies'}
        self.assertEqual(metadata.benchmark(result, env)['cache_regime'], 'cold')
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

    def test_actions_output_rejects_multiline_values(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                metadata.emit_outputs({'toolchain_key': 'one\nother=two'}, Path(folder) / 'output')


if __name__ == '__main__':
    unittest.main()
