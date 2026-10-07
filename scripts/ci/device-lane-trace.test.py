#!/usr/bin/env python3
"""Exercise the real proxy and owned-process deadline using disposable executables."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('trace', Path(__file__).with_name('device-lane-trace.py'))
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class Trace(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.root, self.report, self.bin = (self.base / name for name in ('source', 'report', 'bin'))
        for path in (self.root, self.report, self.bin):
            path.mkdir()
        lock = self.root / trace.LOCK
        lock.parent.mkdir(parents=True)
        lock.write_text('immutable lock bytes')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=fixture', '-c',
                        'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        self.graph = self.base / 'graph.py'
        self.graph.write_text("import sys,json,pathlib\np=pathlib.Path(sys.argv[sys.argv.index('--output')+1])\n"
                              "p.write_text(json.dumps({'graph_sha256':'a'*64}))\n")
        native = self.bin / 'xcodebuild'
        native.write_text('#!' + sys.executable + '\nimport sys,os,json\n'
                          "with open(os.environ['ACTUAL_NATIVE'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                          "if os.environ.get('NATIVE_SIGNAL'): os.kill(os.getpid(),int(os.environ['NATIVE_SIGNAL']))\n"
                          "sys.exit(int(os.environ.get('NATIVE_EXIT','0')))\n")
        native.chmod(0o755)
        self.lane = self.base / 'lane.py'
        self.lane.write_text("import os,subprocess,sys\nr=os.environ['LANE_ROOT']; s=os.environ['LANE_SCHEME']\n"
            "common=['-project',r+'/iosApp/Silo.xcodeproj','-scheme',s,'-disableAutomaticPackageResolution',"
            "'-onlyUsePackageVersionsFromResolvedFile','-clonedSourcePackagesDirPath',r+'/.ci-cache/packages']\n"
            "for action in ('-resolvePackageDependencies','archive'):\n"
            " code=subprocess.call(['xcodebuild',action]+common)\n"
            " if code: sys.exit(code)\n")
        self.env = patch.dict(os.environ, {'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'ACTUAL_NATIVE': str(self.base / 'actual.jsonl'), 'LANE_ROOT': str(self.root), 'LANE_SCHEME': 'Silo'}, clear=False)
        self.env.start()
        self.home = patch.object(trace.Path, 'home', return_value=self.base)
        self.home.start()

    def tearDown(self):
        self.home.stop()
        self.env.stop()
        self.temp.cleanup()

    def lane_run(self, **kwargs):
        return trace.run_lane(self.root, self.report, self.root / '.ci-cache/packages', 'ios', self.graph,
                              command=[sys.executable, str(self.lane)], **kwargs)

    def test_actual_native_argv_is_unchanged_and_graph_binds_archive(self):
        result = self.lane_run()
        actual = [json.loads(line) for line in (self.base / 'actual.jsonl').read_text().splitlines()]
        self.assertEqual(actual, [record['argv'] for record in result['commands']])
        self.assertEqual(['resolve', 'archive'], [record['category'] for record in result['commands']])
        self.assertTrue(result['qualified'])
        self.assertGreater(result['attestation_seconds'], 0)
        self.assertTrue((self.report / 'graph-before-archive.json').exists())
        self.assertTrue((self.report / 'graph-after-archive.json').exists())

    def test_native_nonzero_is_preserved_and_never_qualifies(self):
        with patch.dict(os.environ, {'NATIVE_EXIT': '7'}), self.assertRaisesRegex(ValueError, 'Lane failed'):
            self.lane_run()
        result = json.loads((self.report / 'lane.json').read_text())
        self.assertEqual(7, result['lane_exit_code'])
        self.assertFalse(result['qualified'])
        self.assertEqual(1, len(result['commands']))

    def test_native_signal_keeps_actual_record_and_shell_visible_status(self):
        with patch.dict(os.environ, {'NATIVE_SIGNAL': '15'}), self.assertRaisesRegex(ValueError, 'Lane failed'):
            self.lane_run()
        result = json.loads((self.report / 'lane.json').read_text())
        self.assertEqual(-15, result['commands'][0]['exit_code'])
        self.assertEqual(143, result['lane_exit_code'])
        self.assertFalse(result['qualified'])

    def test_graph_failure_stops_archive_before_native_execution(self):
        self.graph.write_text('raise SystemExit(3)\n')
        with self.assertRaisesRegex(ValueError, 'Lane failed'):
            self.lane_run()
        actual = [json.loads(line) for line in (self.base / 'actual.jsonl').read_text().splitlines()]
        self.assertEqual(1, len(actual))
        self.assertIn('-resolvePackageDependencies', actual[0])

    def test_timeout_kills_owned_lane_and_records_failure(self):
        self.lane.write_text('import time\ntime.sleep(120)\n')
        with self.assertRaisesRegex(ValueError, 'Lane failed'):
            self.lane_run(timeout=1)
        result = json.loads((self.report / 'lane.json').read_text())
        self.assertTrue(result['timed_out'])
        self.assertLess(result['lane_seconds'], 3)
        self.assertFalse(result['qualified'])

    def test_lock_mutation_rejects_native_success(self):
        self.lane.write_text(self.lane.read_text() + "open(r+'/' + " + repr(trace.LOCK) + ", 'w').write('changed')\n")
        with self.assertRaisesRegex(ValueError, 'Lane failed'):
            self.lane_run()
        self.assertFalse(json.loads((self.report / 'lane.json').read_text())['qualified'])

    def test_missing_locked_flag_prevents_native_execution(self):
        self.lane.write_text(self.lane.read_text().replace("'-disableAutomaticPackageResolution',", ''))
        with self.assertRaisesRegex(ValueError, 'Lane failed'):
            self.lane_run()
        self.assertFalse((self.base / 'actual.jsonl').exists())

    def test_dirty_derived_data_fails_before_any_lane(self):
        derived = self.base / 'Library/Developer/Xcode/DerivedData'
        derived.mkdir(parents=True)
        (derived / 'prior').touch()
        with self.assertRaisesRegex(ValueError, 'DerivedData'):
            self.lane_run()
        self.assertFalse((self.base / 'actual.jsonl').exists())

    def test_both_unsigned_lanes_use_ios_fastlane_platform(self):
        self.assertEqual(('Silo', 'ios', 'ipa_ios_unsigned'), trace.TARGETS['ios'])
        self.assertEqual(('SiloTV', 'ios', 'ipa_tvos_unsigned'), trace.TARGETS['tvos'])


if __name__ == '__main__':
    unittest.main()
