#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('observations', Path(__file__).with_name('resource-observations.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ObservationTests(unittest.TestCase):
    def controls(self):
        return {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REPOSITORY': 'Silo-Server/silo-apple',
                'SILO_BENCHMARK_PLATFORM': 'ios', 'SILO_BENCH_VARIANT': 'optimized',
                'SILO_BENCHMARK_SOURCE_REF': 'a' * 40, 'SILO_CACHE_PROBE': 'none'}

    def test_preflight_rejects_wrong_scope_before_any_query(self):
        for key, values in {'GITHUB_EVENT_NAME': ('push', 'pull_request', 'workflow_call'),
                            'GITHUB_REPOSITORY': ('other/repo', ''),
                            'SILO_RELEASE_GATE': ('true',), 'SILO_BENCHMARK_PLATFORM': ('all', 'tvos', 'macos'),
                            'SILO_BENCH_VARIANT': ('unknown',), 'SILO_BASELINE_REF': ('main',),
                            'SILO_IOS_ONLY': ('true',), 'SILO_RECORD_PREVIEW': ('true',),
                            'SILO_CACHE_PROBE': ('fail_test', 'mutate_source', ''),
                            'SILO_BENCHMARK_SOURCE_REF': ('', 'main', 'a' * 39)}.items():
            for value in values:
                with self.subTest(key=key, value=value), patch.object(module, 'run', side_effect=AssertionError('Queries started')):
                    with self.assertRaises(ValueError):
                        module.validate({**self.controls(), key: value})
        module.validate(self.controls())
        module.validate({**self.controls(), 'SILO_BENCH_VARIANT': 'baseline'})

    def test_actual_matrix_row_is_checked_before_source_or_resource_queries(self):
        env = {**self.controls(), 'PLATFORM': 'iOS', 'SCHEME': 'Silo', 'ACTION': 'test'}
        module.validate(env)
        for key, values in {'PLATFORM': ('tvOS', 'macOS', ''), 'SCHEME': ('SiloTV', 'SiloMac', ''),
                            'ACTION': ('build', '')}.items():
            for value in values:
                with self.subTest(key=key, value=value), patch.object(module, 'run', side_effect=AssertionError('Queries started')):
                    with self.assertRaises(ValueError):
                        module.validate({**env, key: value})

    def test_process_snapshot_excludes_arguments_paths_and_unrelated_processes(self):
        inventory = '1 0 100 /Applications/Xcode.app/xcodebuild\n2 1 200 /private/secret/child name\n3 0 300 /private/secret/other\n4 0 400 /Library/CoreSimulator/testmanagerd\n9 0 90 /private/observer/python3\n10 9 40 /bin/ps\n'
        with patch.object(module.os, 'getpid', return_value=9):
            result = module.processes(inventory)
        self.assertEqual({item['pid'] for item in result}, {1, 2, 4, 9, 10})
        self.assertEqual(sum(item['rss_kib'] for item in result), 830)
        text = json.dumps(result)
        self.assertNotIn('/private', text)
        self.assertNotIn('secret', text)
        self.assertNotIn('child name', text)
        self.assertIn('resource-observer', text)
        self.assertNotIn('argv', text)
        with self.assertRaises(ValueError):
            module.processes('pid ppid rss command')

    def test_core_simulator_service_is_included_outside_the_test_tree(self):
        inventory = '1 0 100 /sbin/launchd\n11 1 4896 /Library/CoreSimulator/com.apple.CoreSimulator.CoreSimulatorService\n12 1 800 /Library/CoreSimulator/CoreSimulatorBridge\n'
        with patch.object(module.os, 'getpid', return_value=99):
            result = module.processes(inventory)
        self.assertEqual({item['pid'] for item in result}, {11, 12})
        self.assertEqual(next(item for item in result if item['pid'] == 11)['rss_kib'], 4896)
        self.assertEqual(next(item for item in result if item['pid'] == 11)['process'],
                         'com.apple.CoreSimulator.CoreSimulatorService')

    def test_query_failures_retain_type_duration_and_exit_without_exception_arguments(self):
        for error in (subprocess.TimeoutExpired(['sensitive argument'], 3), OSError('sensitive value')):
            with self.subTest(error=type(error).__name__), patch.object(module.subprocess, 'run', side_effect=error):
                result = module.run(['/bin/ps'])
            self.assertIsNone(result['exit_code'])
            self.assertEqual(result['stderr'], type(error).__name__)
            self.assertNotIn('sensitive', json.dumps(result))
            self.assertGreaterEqual(result['elapsed_seconds'], 0)
        with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 7, '', 'query failed')):
            self.assertEqual(module.run(['/bin/ps'])['exit_code'], 7)

    def test_identity_and_device_query_failures_are_saved_without_retry(self):
        calls = []
        def query(args, timeout=3):
            calls.append((args, timeout))
            return {'exit_code': 9, 'stdout': '', 'stderr': 'fixture failure', 'elapsed_seconds': 0.1}
        with tempfile.TemporaryDirectory() as folder, patch.object(module, 'run', side_effect=query):
            path = Path(folder)
            module.snapshot(path, 'before')
            module.snapshot(path, 'after')
            before = json.loads((path/'before.json').read_text())
            after = json.loads((path/'after.json').read_text())
        self.assertEqual(len(before['cpu_memory_identity']), 6)
        self.assertEqual(before['device_query']['exit_code'], 9)
        self.assertEqual(after['device_query']['exit_code'], 9)
        self.assertEqual(len(calls), 8)
        self.assertEqual(calls[-1][1], 15)

    def test_sampler_captures_private_rss_memory_failures_and_own_cost(self):
        responses = [
            {'exit_code': 0, 'stdout': '1 0 100 /Applications/xcodebuild\n2 1 150 /private/secret/child\n', 'stderr': '', 'elapsed_seconds': 0.01},
            {'exit_code': 0, 'stdout': 'Pages free: 42.\nPageouts: 3.\n', 'stderr': '', 'elapsed_seconds': 0.02},
            {'exit_code': 7, 'stdout': '', 'stderr': 'swap query failed', 'elapsed_seconds': 0.03}]
        class StopAfterSample:
            def __init__(self): self.stopped = False
            def set(self): self.stopped = True
            def is_set(self): return self.stopped
            def wait(self, _): self.stopped = True
        with tempfile.TemporaryDirectory() as folder, patch.object(module.threading, 'Event', StopAfterSample), \
                patch.object(module.signal, 'signal'), patch.object(module, 'run', side_effect=responses):
            root = Path(folder)
            module.sample(root, 2, 720)
            data = json.loads((root/'samples.jsonl').read_text())
            summary = json.loads((root/'sampler-summary.json').read_text())
            ready = json.loads((root/'sampler-ready.json').read_text())
        self.assertEqual(data['rss']['processes'][0]['rss_kib'], 100)
        self.assertNotIn('stdout', data['rss'])
        self.assertNotIn('secret', json.dumps(data))
        self.assertEqual(data['swap_usage']['exit_code'], 7)
        self.assertEqual(summary['query_errors'], 1)
        self.assertAlmostEqual(summary['query_elapsed_seconds'], 0.06)
        self.assertEqual(summary['samples'], 1)
        self.assertFalse(summary['maximum_reached'])
        self.assertGreaterEqual(summary['observer_cpu_seconds'], 0)
        self.assertGreaterEqual(summary['query_child_cpu_seconds'], 0)
        self.assertIn('pid', ready)


    def test_actual_sampler_process_stops_on_owned_signal_and_seals_output(self):
        helper = str(Path(__file__).with_name('resource-observations.py'))
        script = """import importlib.util,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('observer',sys.argv[1])
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def query(args,timeout=3):
    text=str(os.getpid())+' 0 123 /private/python3\\n' if args[0]=='/bin/ps' else 'safe fixture counter'
    return {'exit_code':0,'stdout':text,'stderr':'','elapsed_seconds':0.001}
module.run=query
module.sample(Path(sys.argv[2]),0.25,720)
"""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            worker = subprocess.Popen([sys.executable, '-c', script, helper, str(root)],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while not (root/'sampler-ready.json').exists() and worker.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root/'sampler-ready.json').exists())
                worker.terminate()
                output, error = worker.communicate(timeout=3)
                self.assertEqual(worker.returncode, 0, error)
                self.assertEqual(output, '')
                summary = json.loads((root/'sampler-summary.json').read_text())
                self.assertTrue(summary['stopped_by_signal'])
                self.assertFalse(summary['maximum_reached'])
                self.assertGreaterEqual(summary['samples'], 1)
                self.assertEqual(summary['query_errors'], 0)
                observed = json.loads((root/'samples.jsonl').read_text().splitlines()[0])
                self.assertEqual(observed['rss']['processes'][0]['process'], 'resource-observer')
                self.assertNotIn('/private', json.dumps(observed))
            finally:
                if worker.poll() is None:
                    worker.kill()
                    worker.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
