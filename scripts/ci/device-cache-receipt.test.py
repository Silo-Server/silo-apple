#!/usr/bin/env python3
"""Verify cache identity, restored bytes and bounded receipt download contracts."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('receipt', Path(__file__).with_name('device-cache-receipt.py'))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)
SOURCE, CONTROLLER, FIXTURE = 'a' * 40, 'b' * 40, 'c' * 40
META = {'source_dirty': 'false', 'source_sha': SOURCE, 'cache_namespace': 'apple-device-test',
        'toolchain_key': 'd' * 24, 'lock_sha256': 'e' * 64, 'compilation_cache_profile': 'standard',
        'spm_cache_profile_effective': 'scheme', 'toolchain_json': json.dumps({'Silo-device': {'sdk': 'iphoneos'}})}
CACHE = {'id': 22, 'key': receipt.key(META, 'apple-device-test', 'Silo-device'), 'version': 'v1',
         'ref': receipt.BRANCH, 'size_in_bytes': 1234, 'created_at': '2026-10-07T00:00:00Z'}
CONTEXT = {'controller_sha': CONTROLLER, 'source_sha': SOURCE, 'fixture_sha': FIXTURE,
           'namespace': 'apple-device-test', 'profile': 'warm'}
RUNTIME = {'ruby': '3.3.12', 'bundler': '4.0.15', 'fastlane': '2.240.1'}


def encode(value):
    return json.dumps(value, sort_keys=True).encode()


class Receipts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.report = self.root / 'report'
        self.report.mkdir()
        self.tree = {'sha256': 'f' * 64, 'files': 12, 'bytes': 2345, 'seconds': 1.2}
        for name, value in {'binding': {'qualified': True, 'context': CONTEXT}, 'metadata': META,
                'packages-restored': self.tree, 'cache-before': {'key': CACHE['key'], 'cache': CACHE},
                'lane-runtime': RUNTIME,
                'prime': {'receipt': {**CONTEXT, 'profile': 'prime', 'cache': CACHE,
                    'packages_before_save': self.tree, 'toolchain': {'sdk': 'iphoneos'}, 'lane_runtime': RUNTIME}}}.items():
            receipt.save(self.report / (name + '.json'), value)

    def tearDown(self):
        self.temp.cleanup()

    def restored(self, hit='true', profile='warm', scope='Silo-device'):
        return receipt.restored(self.report, profile, hit, 'scheme', scope, 'Silo-device')

    def test_exact_warm_hit_requires_same_identity_and_restored_bytes(self):
        self.assertTrue(self.restored()['qualified'])
        for field, replacement in (('id', 23), ('size_in_bytes', 1235), ('version', 'v2')):
            bad = copy.deepcopy(CACHE)
            bad[field] = replacement
            receipt.save(self.report / 'cache-before.json', {'key': CACHE['key'], 'cache': bad})
            with self.assertRaisesRegex(ValueError, 'Warm restore'):
                self.restored()
        receipt.save(self.report / 'cache-before.json', {'key': CACHE['key'], 'cache': CACHE})
        receipt.save(self.report / 'packages-restored.json', {**self.tree, 'sha256': '0' * 64})
        with self.assertRaisesRegex(ValueError, 'Warm restore'):
            self.restored()

    def test_warm_miss_or_shared_scope_cannot_qualify(self):
        with self.assertRaises(ValueError):
            self.restored(hit='false')
        with self.assertRaises(ValueError):
            self.restored(scope='shared-qualified-v1')

    def test_cold_requires_no_existing_cache_or_content(self):
        receipt.save(self.report / 'binding.json', {'qualified': True, 'context': {**CONTEXT, 'profile': 'prime'}})
        receipt.save(self.report / 'cache-before.json', {'key': CACHE['key'], 'cache': None})
        receipt.save(self.report / 'packages-restored.json', {'sha256': 'f' * 64, 'files': 0, 'bytes': 0})
        self.assertTrue(self.restored(profile='prime', hit='')['qualified'])
        with self.assertRaises(ValueError):
            self.restored(profile='prime', hit='true')
        receipt.save(self.report / 'packages-restored.json', self.tree)
        with self.assertRaises(ValueError):
            self.restored(profile='prime', hit='')

    def test_whole_tree_digest_covers_bytes_mode_and_symlink(self):
        packages = self.root / 'packages'
        packages.mkdir()
        file = packages / 'file'
        file.write_bytes(b'actual package bytes')
        original = receipt.tree(packages)
        packages.chmod(0o700)
        self.assertNotEqual(original['sha256'], receipt.tree(packages)['sha256'])
        packages.chmod(0o755)
        file.write_bytes(b'changed package bytes')
        self.assertNotEqual(original['sha256'], receipt.tree(packages)['sha256'])
        file.write_bytes(b'actual package bytes')
        file.chmod(0o755)
        self.assertNotEqual(original['sha256'], receipt.tree(packages)['sha256'])
        (packages / 'linked').symlink_to('file')
        with_link = receipt.tree(packages)
        self.assertEqual(2, with_link['files'])
        (packages / 'linked').unlink()
        (packages / 'linked').symlink_to('../report')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            receipt.tree(packages)

    def test_cache_query_rejects_duplicate_exact_rows_and_missing_size(self):
        api = receipt.GitHub('fixture-read-token')
        for rows in ([CACHE, CACHE], [{**CACHE, 'size_in_bytes': 0}], [], [{**CACHE, 'ref': 'refs/heads/main'}]):
            with patch.object(api, 'read', return_value={'total_count': len(rows), 'actions_caches': rows}):
                with self.assertRaises(ValueError):
                    api.cache(CACHE['key'], True)
        with patch.object(api, 'read', return_value={'total_count': 1, 'actions_caches': [{**CACHE, 'ref': 'refs/heads/main'}]}):
            with self.assertRaises(ValueError):
                api.cache(CACHE['key'], False)
        with patch.object(api, 'read', return_value={'total_count': 1, 'actions_caches': [CACHE]}):
            self.assertEqual(CACHE, api.cache(CACHE['key'], True))

    def prime_api(self, extra=None, corrupt_digest=False, wrong_run=False):
        artifact = {'qualified': True, 'source_sha': SOURCE, 'controller_sha': CONTROLLER, 'platform': 'ios'}
        artifact_raw = encode(artifact)
        prime = {**CONTEXT, 'qualified': True, 'profile': 'prime', 'run_id': '12', 'run_attempt': '1', 'platform': 'ios',
                 'artifact_receipt_sha256': hashlib.sha256(artifact_raw).hexdigest()}
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('receipt.json', encode(prime))
            archive.writestr('artifact.json', artifact_raw)
            if extra:
                archive.writestr(extra, b'bad member')
        data = buffer.getvalue()
        run = {'id': 12, 'event': 'workflow_dispatch', 'head_sha': CONTROLLER,
               'head_branch': receipt.BRANCH.removeprefix('refs/heads/'), 'path': receipt.WORKFLOW,
               'status': 'completed', 'conclusion': 'success', 'run_attempt': 1}
        if wrong_run:
            run['head_sha'] = '0' * 40
        api = receipt.GitHub('fixture-read-token')
        digest = 'sha256:' + ('0' * 64 if corrupt_digest else hashlib.sha256(data).hexdigest())
        responses = [run, {'total_count': 1, 'artifacts': [{'id': 13, 'name': 'device-dependencies-ios-prime-1',
                     'expired': False, 'size_in_bytes': len(data), 'digest': digest}]}, data]
        return api, responses

    def test_prime_artifact_is_pinned_to_run_source_controller_and_digest(self):
        api, responses = self.prime_api()
        with patch.object(api, 'read', side_effect=responses):
            prior, artifact, provenance = api.prime('12', 'ios', CONTROLLER, SOURCE, FIXTURE, 'apple-device-test')
        self.assertTrue(prior['qualified'] and artifact['qualified'])
        self.assertEqual(13, provenance['id'])
        api, responses = self.prime_api()
        with patch.object(api, 'read', side_effect=responses), self.assertRaises(ValueError):
            api.prime('12', 'ios', CONTROLLER, '0' * 40, FIXTURE, 'apple-device-test')

    def test_prime_download_rejects_changed_digest_unsafe_path_and_wrong_head(self):
        for kwargs in ({'corrupt_digest': True}, {'extra': '../escape.json'}, {'extra': 'artifact.ipa'}, {'wrong_run': True}):
            api, responses = self.prime_api(**kwargs)
            with patch.object(api, 'read', side_effect=responses), self.assertRaises(ValueError):
                api.prime('12', 'ios', CONTROLLER, SOURCE, FIXTURE, 'apple-device-test')

    def test_upload_bounds_rejects_binary_symlink_and_large_text(self):
        self.assertTrue(receipt.upload_bounds(self.report)['qualified'])
        binary = self.report / 'secret.ipa'
        binary.touch()
        with self.assertRaises(ValueError):
            receipt.upload_bounds(self.report)
        binary.unlink()
        linked = self.report / 'linked.json'
        linked.symlink_to('metadata.json')
        with self.assertRaises(ValueError):
            receipt.upload_bounds(self.report)
        linked.unlink()
        with patch.object(receipt, 'REPORT_LIMIT', 1), self.assertRaises(ValueError):
            receipt.upload_bounds(self.report)

    def test_finish_requires_complete_matching_artifact_graph_runtime_and_cache(self):
        artifact = {'qualified': True, 'platform': 'ios', 'source_sha': SOURCE,
                    'controller_sha': CONTROLLER, 'toolchain': {'sdk': 'iphoneos'}}
        for name, value in {'restore': self.restored(), 'lane': {'qualified': True}, 'artifact': artifact,
                'packages-before-save': self.tree, 'cache-after': {'key': CACHE['key'], 'cache': CACHE},
                'graph-before-archive': {'graph_sha256': 'f'*64}, 'graph-after-archive': {'graph_sha256': 'f'*64}}.items():
            receipt.save(self.report / (name + '.json'), value)
        with patch.dict(os.environ, {'DEVICE_JOB_STARTED': '1791378000'}):
            result = receipt.finish(self.report, 'ios', 'Silo-device')
            self.assertTrue(result['qualified'])
            self.assertEqual(CACHE, result['cache'])
            receipt.save(self.report / 'artifact.json', {**artifact, 'controller_sha': '0'*40})
            with self.assertRaises(ValueError):
                receipt.finish(self.report, 'ios', 'Silo-device')
            receipt.save(self.report / 'artifact.json', artifact)
            receipt.save(self.report / 'graph-after-archive.json', {'graph_sha256': '0'*64})
            with self.assertRaises(ValueError):
                receipt.finish(self.report, 'ios', 'Silo-device')


if __name__ == '__main__':
    unittest.main()
