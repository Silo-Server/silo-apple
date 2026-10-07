#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('controller-controls.py')
spec = importlib.util.spec_from_file_location('controls', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ControllerTests(unittest.TestCase):
    def environment(self, **changes):
        return {
            'GITHUB_REPOSITORY': 'Silo-Server/silo-apple', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
            'GITHUB_REF': module.PRIVATE_REF, 'GITHUB_SHA': 'b' * 40,
            'GITHUB_RUN_ID': '12345', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'validate',
            'SILO_BENCHMARK_SOURCE_REF': 'a' * 40, 'SILO_BENCH_VARIANT': 'optimized',
            'SILO_CACHE_MODE': 'dependencies', 'SILO_CACHE_NAMESPACE': module.NAMESPACE,
            'SILO_SPM_CACHE_PROFILE': 'shared_qualified', 'SILO_BENCHMARK_PLATFORM': 'ios',
            'SILO_COMPILATION_CACHE_ENABLED': 'false', 'SILO_IOS_PARALLEL_PILOT': 'false',
            'SILO_UNFLAGGED_DEPENDENCY_CONTROL': 'false',
            'SILO_RESOURCE_OBSERVATIONS': 'true', 'SILO_CACHE_PROBE': 'none',
            'SILO_CACHE_SAVE_POLICY': 'read_only', 'SILO_BASELINE_REF': '',
            'SILO_IOS_ONLY': 'false', 'SILO_RECORD_PREVIEW': 'false',
            'SILO_EXPORT_SIMULATOR_TESTS': 'false', 'SILO_RELEASE_GATE': 'false',
            'PLATFORM': 'iOS', 'SCHEME': 'Silo', 'ACTION': 'test', 'TEST_TARGET': 'SiloTests',
            **changes}

    def test_declared_current_source_cohorts_and_bootstrap_timing(self):
        cohorts = [
            {'SILO_BENCH_VARIANT': 'baseline', 'SILO_CACHE_MODE': 'off',
             'SILO_SPM_CACHE_PROFILE': 'scheme', 'SILO_BENCHMARK_PLATFORM': 'all',
             'SILO_RESOURCE_OBSERVATIONS': 'false'},
            {'SILO_CACHE_MODE': 'off', 'SILO_SPM_CACHE_PROFILE': 'scheme',
             'SILO_BENCHMARK_PLATFORM': 'all', 'SILO_RESOURCE_OBSERVATIONS': 'false'},
            {},
            {'SILO_CACHE_MODE': 'derived_data', 'SILO_COMPILATION_CACHE_ENABLED': 'true'},
            {'SILO_CACHE_MODE': 'derived_data', 'SILO_COMPILATION_CACHE_ENABLED': 'true',
             'SILO_CACHE_SAVE_POLICY': 'compiler_bootstrap'},
            {'SILO_IOS_PARALLEL_PILOT': 'true'},
            {'SILO_UNFLAGGED_DEPENDENCY_CONTROL': 'true'}]
        for changes in cohorts:
            env = self.environment(**changes)
            result = module.controls(env)
            self.assertEqual(result['source_sha'], 'a' * 40)
            self.assertEqual(result['controller_sha'], 'b' * 40)
            self.assertEqual(result['measurement_requested'], env['SILO_CACHE_SAVE_POLICY'] == 'read_only')

    def test_invalid_controls_fail_the_real_cli_before_receipt_creation(self):
        invalid = {'GITHUB_REPOSITORY': ['other/repo'], 'GITHUB_EVENT_NAME': ['push', 'pull_request', 'workflow_call'],
                   'GITHUB_REF': ['refs/heads/main', 'refs/heads/private/other'],
                   'SILO_BENCHMARK_SOURCE_REF': ['', 'main', 'a' * 39, 'A' * 40, '0' * 40, 'a' * 40 + '\n'],
                   'SILO_CACHE_MODE': ['delete'], 'SILO_CACHE_NAMESPACE': ['../unsafe', 'production'],
                   'SILO_SPM_CACHE_PROFILE': ['generic'], 'SILO_BENCHMARK_PLATFORM': ['linux'],
                   'SILO_CACHE_SAVE_POLICY': ['save_all'], 'SILO_CACHE_PROBE': ['fail_test', 'graph_inventory'],
                   'SILO_BASELINE_REF': ['c' * 40], 'SILO_IOS_ONLY': ['true'],
                   'SILO_RECORD_PREVIEW': ['true'], 'SILO_EXPORT_SIMULATOR_TESTS': ['true'],
                   'SILO_RELEASE_GATE': ['true'], 'SILO_COMPILATION_CACHE_ENABLED': ['TRUE'],
                   'SILO_UNFLAGGED_DEPENDENCY_CONTROL': ['TRUE', '1'],
                   'SILO_IOS_PARALLEL_PILOT': ['1'], 'SILO_RESOURCE_OBSERVATIONS': ['false\n']}
        with tempfile.TemporaryDirectory() as temporary:
            for key, values in invalid.items():
                for value in values:
                    with self.subTest(key=key, value=value):
                        folder = Path(temporary) / 'receipts'
                        run = subprocess.run([sys.executable, str(SCRIPT), 'controls', '--folder', str(folder)],
                                             env={**os.environ, **self.environment(**{key: value})},
                                             capture_output=True, text=True, timeout=3)
                        self.assertEqual(run.returncode, 2, run.stdout)
                        self.assertFalse(folder.exists())

    def test_bootstrap_and_actual_ios_row_cannot_expand_to_other_profiles(self):
        bootstrap = self.environment(SILO_CACHE_MODE='derived_data', SILO_COMPILATION_CACHE_ENABLED='true',
                                     SILO_CACHE_SAVE_POLICY='compiler_bootstrap')
        for changes in ({'SILO_CACHE_MODE': 'dependencies'}, {'SILO_COMPILATION_CACHE_ENABLED': 'false'},
                        {'SILO_SPM_CACHE_PROFILE': 'scheme'}, {'SILO_IOS_PARALLEL_PILOT': 'true'},
                        {'SILO_BENCHMARK_PLATFORM': 'all'}, {'SCHEME': 'SiloTV'}, {'ACTION': 'build'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                module.controls({**bootstrap, **changes})
        with self.assertRaises(ValueError):
            module.controls(self.environment(SILO_BENCHMARK_PLATFORM='all'))

    def test_unflagged_control_is_limited_to_the_exact_dependency_ios_profile(self):
        env = self.environment(SILO_UNFLAGGED_DEPENDENCY_CONTROL='true')
        result = module.controls(env)
        self.assertFalse(result['compilation_cache'])
        self.assertEqual(result['cache_profile_control'], 'unflagged-defaults')
        self.assertEqual(result['requested_caching'], 'unknown')
        self.assertEqual(result['requested_diagnostics'], 'unknown')
        self.assertFalse(result['compilation_cache_marker_is_effective_state'])
        for changes in ({'SILO_BENCH_VARIANT': 'baseline'}, {'SILO_CACHE_MODE': 'off'},
                        {'SILO_CACHE_MODE': 'derived_data'}, {'SILO_COMPILATION_CACHE_ENABLED': 'true'},
                        {'SILO_BENCHMARK_PLATFORM': 'all'}, {'SILO_BENCHMARK_PLATFORM': 'tvos'},
                        {'SILO_CACHE_SAVE_POLICY': 'compiler_bootstrap'}, {'SILO_SPM_CACHE_PROFILE': 'scheme'},
                        {'SILO_IOS_PARALLEL_PILOT': 'true'}, {'SILO_EXPORT_SIMULATOR_TESTS': 'true'},
                        {'SILO_CACHE_PROBE': 'graph_inventory'}, {'SILO_RECORD_PREVIEW': 'true'},
                        {'PLATFORM': 'tvOS'}, {'SCHEME': 'SiloTV'}, {'ACTION': 'build'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                module.controls({**env, **changes})
        with tempfile.TemporaryDirectory() as temporary:
            prepared = {**env, 'SILO_DERIVED_DATA': str(Path(temporary) / 'fresh'),
                        'SILO_SPM_CACHE_PROFILE_EFFECTIVE': 'shared_qualified', 'SILO_SPM_CACHE_HIT': 'true'}
            self.assertFalse(module.derived_state(prepared, 'pre_build')['present'])
            with self.assertRaises(ValueError):
                module.derived_state({**prepared, 'SILO_SPM_CACHE_HIT': 'false'}, 'pre_build')

    def test_derived_state_rejects_existing_control_and_nonexact_warm_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'derived'
            env = self.environment(SILO_DERIVED_DATA=str(path), SILO_SPM_CACHE_PROFILE_EFFECTIVE='shared_qualified',
                                   SILO_SPM_CACHE_HIT='true')
            self.assertFalse(module.derived_state(env, 'pre_restore')['present'])
            self.assertFalse(module.derived_state(env, 'pre_build')['present'])
            for changes in ({'SILO_SPM_CACHE_PROFILE_EFFECTIVE': 'scheme'}, {'SILO_SPM_CACHE_HIT': 'false'}):
                with self.assertRaises(ValueError):
                    module.derived_state({**env, **changes}, 'pre_build')
            path.mkdir()
            with self.assertRaises(ValueError):
                module.derived_state(env, 'pre_restore')
            with self.assertRaises(ValueError):
                module.derived_state(env, 'pre_build')
            warm = {**env, 'SILO_CACHE_MODE': 'derived_data', 'SILO_COMPILATION_CACHE_ENABLED': 'true'}
            with self.assertRaises(ValueError):
                module.derived_state({**warm, 'SILO_DERIVED_CACHE_HIT': 'false'}, 'pre_build')
            self.assertTrue(module.derived_state({**warm, 'SILO_DERIVED_CACHE_HIT': 'true'}, 'pre_build')['present'])
            bootstrap = {**warm, 'SILO_CACHE_SAVE_POLICY': 'compiler_bootstrap'}
            self.assertTrue(module.derived_state(bootstrap, 'pre_build')['present'])
            path.rmdir()
            path.symlink_to(Path(temporary) / 'missing')
            with self.assertRaises(ValueError):
                module.derived_state(env, 'pre_restore')

    def settings(self, state):
        return [{'target': name, 'buildSettings': {'COMPILATION_CACHE_ENABLE_CACHING': state,
                                                'COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS': state}}
                for name in ('Silo', 'SiloTests')]

    def test_resolved_profile_must_cover_required_targets_and_actual_switches(self):
        for enabled, state in (('false', 'NO'), ('true', 'YES')):
            env = self.environment(SILO_COMPILATION_CACHE_ENABLED=enabled,
                                   SILO_CACHE_MODE='derived_data' if enabled == 'true' else 'dependencies')
            result = module.resolved_settings(env, self.settings(state))
            self.assertEqual(result['source_sha'], 'a' * 40)
            self.assertEqual(result['run_id'], '12345')
            self.assertFalse(result['unflagged_shipping_default_equivalence_proven'])
            for wrong in ([], {}, self.settings(state)[:1], self.settings('YES' if state == 'NO' else 'NO'),
                          [{'target': 'Silo', 'buildSettings': {}}]):
                with self.subTest(enabled=enabled, wrong=wrong), self.assertRaises(ValueError):
                    module.resolved_settings(env, wrong)
            wrong_diagnostic = self.settings(state)
            wrong_diagnostic[0]['buildSettings']['COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS'] = 'YES' if state == 'NO' else 'NO'
            with self.assertRaises(ValueError):
                module.resolved_settings(env, wrong_diagnostic)

    def test_settings_receipt_discards_unrelated_raw_settings(self):
        raw = self.settings('NO')
        raw[0]['buildSettings']['DO_NOT_PUBLISH'] = 'fixture-sensitive-value'
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            source = folder / 'raw.json'
            source.write_text(json.dumps(raw))
            output = folder / 'receipt'
            run = subprocess.run([sys.executable, str(SCRIPT), 'settings', '--input', str(source),
                                  '--folder', str(output)], env={**os.environ, **self.environment()},
                                 capture_output=True, text=True, timeout=3)
            self.assertEqual(run.returncode, 0, run.stderr)
            receipt = (output / 'settings.json').read_text()
            self.assertNotIn('fixture-sensitive-value', run.stdout + receipt)
            self.assertEqual(len(json.loads(receipt)['targets']), 2)

    def test_unflagged_settings_preserve_missing_raw_fields_and_unknown_effective_state(self):
        env = self.environment(SILO_UNFLAGGED_DEPENDENCY_CONTROL='true')
        raw = [{'target': name, 'buildSettings': {}} for name in ('Silo', 'SiloTests')]
        result = module.resolved_settings(env, raw)
        self.assertEqual(result['cache_profile_control'], 'unflagged-defaults')
        for key in ('requested_caching', 'requested_diagnostics', 'effective_caching', 'effective_diagnostics'):
            self.assertEqual(result[key], 'unknown')
        for target in result['targets']:
            self.assertIsNone(target['caching'])
            self.assertIsNone(target['diagnostics'])
            self.assertFalse(target['caching_present'])
            self.assertFalse(target['diagnostics_present'])
        self.assertFalse(result['compilation_cache_marker_is_effective_state'])
        self.assertFalse(result['unflagged_shipping_default_equivalence_proven'])
        for state in ('NO', 'YES'):
            observed = module.resolved_settings(env, self.settings(state))
            self.assertEqual(observed['effective_caching'], state)
            self.assertEqual(observed['effective_diagnostics'], state)
            self.assertEqual(observed['requested_caching'], 'unknown')
        mixed = self.settings('NO')
        mixed[1]['buildSettings']['COMPILATION_CACHE_ENABLE_CACHING'] = 'YES'
        self.assertEqual(module.resolved_settings(env, mixed)['effective_caching'], 'unknown')
        raw[0]['buildSettings']['COMPILATION_CACHE_ENABLE_CACHING'] = None
        result = module.resolved_settings(env, raw)
        self.assertTrue(result['targets'][0]['caching_present'])
        self.assertIsNone(result['targets'][0]['caching'])
        with self.assertRaises(ValueError):
            module.resolved_settings(env, raw[:1])
        with self.assertRaises(ValueError):
            module.resolved_settings(self.environment(), raw)


if __name__ == '__main__':
    unittest.main()
