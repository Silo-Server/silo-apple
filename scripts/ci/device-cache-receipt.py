#!/usr/bin/env python3
"""Bind isolated device package-cache receipts to GitHub runs and exact content."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPO = 'Silo-Server/silo-apple'
BRANCH = 'refs/heads/private/apple-device-dependency-controller'
WORKFLOW = '.github/workflows/player-regression.yml'
REPORT_LIMIT = 32 * 1024 ** 2
TREE_LIMIT = 4 * 1024 ** 3
FILES_LIMIT = 100000


def require(ok, message):
    if not ok:
        raise ValueError(message)


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def tree(root):
    started, entries, total = time.monotonic(), [], 0
    if not root.exists():
        return {'sha256': hashlib.sha256(b'[]').hexdigest(), 'files': 0, 'bytes': 0, 'seconds': 0}
    require(root.is_dir() and not root.is_symlink(), 'Package cache root is invalid')
    root_node = {'path': '.', 'type': 'directory', 'mode': stat.S_IMODE(root.stat().st_mode)}
    for folder, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(folder) / name
            before = path.lstat()
            mode = before.st_mode
            kind = stat.S_IFMT(mode)
            require(kind in (stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK), 'Unsupported package-cache node')
            entry = {'path': path.relative_to(root).as_posix(), 'mode': stat.S_IMODE(mode),
                     'type': {stat.S_IFDIR: 'directory', stat.S_IFREG: 'file', stat.S_IFLNK: 'symlink'}[kind]}
            if kind == stat.S_IFREG:
                sha, size = hashlib.sha256(), 0
                with path.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(1024 ** 2), b''):
                        sha.update(chunk)
                        size += len(chunk)
                        require(time.monotonic() - started <= 120, 'Package cache inventory timed out')
                entry.update(sha256=sha.hexdigest(), size=size)
                after = path.lstat()
                require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) ==
                        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode) and
                        size == before.st_size, 'Package cache file changed during inventory')
                total += size
            elif kind == stat.S_IFLNK:
                target = os.readlink(path)
                require(not Path(target).is_absolute() and path.resolve().is_relative_to(root.resolve()),
                        'Package cache symlink escapes its root')
                entry['target'] = target
            entries.append(entry)
            require(len(entries) <= FILES_LIMIT and total <= TREE_LIMIT and
                    time.monotonic() - started <= 120, 'Package cache inventory exceeds limits')
    entries.sort(key=lambda item: item['path'])
    return {'sha256': hashlib.sha256(json.dumps([root_node, *entries], sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'files': len(entries), 'bytes': total, 'seconds': time.monotonic() - started}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _req, _fp, _code, _msg, _headers, _newurl):
        return None


class GitHub:
    def __init__(self, token):
        require(token, 'Read-only GitHub token is missing')
        self.token = token

    def read(self, path, binary=False):
        require(path.startswith('/repos/' + REPO + '/actions/'), 'Unexpected GitHub API route')
        request = urllib.request.Request('https://api.github.com' + path, headers={
            'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'silo-device-ci-receipt'})
        try:
            response = urllib.request.build_opener(NoRedirect()).open(request, timeout=20)
        except urllib.error.HTTPError as error:
            if binary and error.code in (301, 302, 303, 307, 308):
                url = error.headers.get('Location', '')
                parsed = urllib.parse.urlparse(url)
                require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password,
                        'Invalid artifact download redirect')
                # Presigned storage receives no GitHub credential. Redirect URLs are never logged.
                response = urllib.request.urlopen(urllib.request.Request(url, headers={
                    'User-Agent': 'silo-device-ci-receipt'}), timeout=20)
            else:
                raise ValueError('Read-only GitHub request failed with status ' + str(error.code)) from None
        with response:
            require(int(response.headers.get('Content-Length', '0')) <= REPORT_LIMIT, 'API response exceeds limit')
            data = response.read(REPORT_LIMIT + 1)
        require(len(data) <= REPORT_LIMIT, 'API response exceeds limit')
        return data if binary else json.loads(data)

    def cache(self, key, required):
        query = urllib.parse.urlencode({'key': key, 'per_page': 100})
        result = self.read('/repos/' + REPO + '/actions/caches?' + query)
        require(result['total_count'] <= 100, 'Cache query is ambiguous')
        matches = [row for row in result['actions_caches'] if row['key'] == key]
        require(len(matches) == int(required) and all(row['ref'] == BRANCH for row in matches),
                'Expected exactly ' + str(int(required)) + ' exact private cache entries without another ref competing')
        if not matches:
            return None
        row = matches[0]
        require(isinstance(row['id'], int) and row['id'] > 0 and isinstance(row['size_in_bytes'], int) and
                row['size_in_bytes'] > 0 and isinstance(row['version'], str) and row['version'],
                'Cache identity or archive size is unavailable')
        return {key: row[key] for key in ('id', 'key', 'version', 'ref', 'size_in_bytes', 'created_at')}

    def prime(self, run_id, platform, controller_sha, source_sha, fixture_sha, namespace):
        require(re.fullmatch('[1-9][0-9]*', run_id or ''), 'Invalid prime run ID')
        run = self.read('/repos/' + REPO + '/actions/runs/' + run_id)
        require(run['id'] == int(run_id) and run['event'] == 'workflow_dispatch' and
                run['head_sha'] == controller_sha and run['head_branch'] == BRANCH.removeprefix('refs/heads/') and
                run['path'] == WORKFLOW and run['status'] == 'completed' and run['conclusion'] == 'success',
                'Prime run has unexpected provenance or result')
        result = self.read('/repos/' + REPO + '/actions/runs/' + run_id + '/artifacts?per_page=100')
        require(result['total_count'] <= 100, 'Prime artifact inventory exceeds limit')
        name = 'device-dependencies-' + platform + '-prime-' + str(run['run_attempt'])
        matches = [row for row in result['artifacts'] if row['name'] == name and not row['expired']]
        require(len(matches) == 1, 'Prime receipt artifact is missing or ambiguous')
        artifact = matches[0]
        require(0 < artifact['size_in_bytes'] <= REPORT_LIMIT and
                re.fullmatch('sha256:[0-9a-f]{64}', artifact.get('digest', '')), 'Prime artifact digest or size is invalid')
        data = self.read('/repos/' + REPO + '/actions/artifacts/' + str(artifact['id']) + '/zip', binary=True)
        require('sha256:' + hashlib.sha256(data).hexdigest() == artifact['digest'], 'Prime artifact digest mismatch')
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            require(len(archive.infolist()) <= 32 and sum(item.file_size for item in archive.infolist()) <= REPORT_LIMIT,
                    'Prime receipt artifact exceeds limits')
            names = set()
            for item in archive.infolist():
                require(item.orig_filename == item.filename and '\0' not in item.orig_filename and
                        item.filename == Path(item.filename).name and item.filename not in names and
                        not item.is_dir() and item.filename.endswith(('.json', '.jsonl', '.log')) and
                        stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG) and not item.flag_bits & 1,
                        'Unsafe or duplicate receipt member')
                names.add(item.filename)
            require({'receipt.json', 'artifact.json'} <= names, 'Prime receipt files are missing')
            receipt = json.loads(archive.read('receipt.json'))
            artifact_raw = archive.read('artifact.json')
            artifact_receipt = json.loads(artifact_raw)
        require(receipt.get('qualified') is True and receipt.get('profile') == 'prime' and
                receipt.get('run_id') == run_id and receipt.get('run_attempt') == str(run['run_attempt']) and
                receipt.get('controller_sha') == controller_sha and receipt.get('platform') == platform and
                receipt.get('source_sha') == source_sha and receipt.get('fixture_sha') == fixture_sha and
                receipt.get('namespace') == namespace and
                receipt.get('artifact_receipt_sha256') == hashlib.sha256(artifact_raw).hexdigest() and
                artifact_receipt.get('source_sha') == source_sha and artifact_receipt.get('controller_sha') == controller_sha and
                artifact_receipt.get('platform') == platform and
                artifact_receipt.get('qualified') is True, 'Prime receipt is unqualified or mismatched')
        return receipt, artifact_receipt, {'id': artifact['id'], 'name': name, 'digest': artifact['digest'],
                                        'size_in_bytes': artifact['size_in_bytes'], 'run_id': run_id}


def key(metadata, namespace, scheme):
    require(re.fullmatch('apple-device-[a-z0-9_-]{1,16}', namespace), 'Invalid isolated namespace')
    require(scheme in ('Silo-device', 'SiloTV-device') and metadata['source_dirty'] == 'false' and
            metadata['compilation_cache_profile'] == 'standard' and
            metadata['spm_cache_profile_effective'] == 'scheme',
            'Device metadata contains unsafe controls')
    return 'silo-spm-v2-' + namespace + '-' + metadata['toolchain_key'] + '-' + scheme + '-' + metadata['lock_sha256']


def restored(report, profile, hit, effective_profile, scope, scheme):
    binding = json.loads((report / 'binding.json').read_text())
    context = binding['context']
    metadata = json.loads((report / 'metadata.json').read_text())
    restored_tree = json.loads((report / 'packages-restored.json').read_text())
    cache = json.loads((report / 'cache-before.json').read_text())
    expected = key(metadata, context['namespace'], scheme)
    require(binding['qualified'] is True and context['profile'] == profile and
            metadata['source_sha'] == context['source_sha'] and cache['key'] == expected and
            effective_profile == 'scheme' and scope == scheme, 'Restore scope or source binding differs')
    if profile in ('off', 'prime'):
        require(hit in ('', 'false') and restored_tree['files'] == 0 and restored_tree['bytes'] == 0 and
                cache['cache'] is None, 'Cold lane restored package content or an existing cache')
    else:
        prior = json.loads((report / 'prime.json').read_text())['receipt']
        require(hit == 'true' and cache['cache'] is not None and cache['cache'] == prior['cache'] and
                restored_tree['sha256'] == prior['packages_before_save']['sha256'] and
                restored_tree['files'] == prior['packages_before_save']['files'] and
                restored_tree['bytes'] == prior['packages_before_save']['bytes'] and
                json.loads(metadata['toolchain_json'])[scheme] == prior['toolchain'] and
                json.loads((report / 'lane-runtime.json').read_text()) == prior['lane_runtime'],
                'Warm restore differs from the qualified prime cache identity or content')
        for name in ('controller_sha', 'source_sha', 'fixture_sha', 'namespace'):
            require(prior[name] == context[name], 'Warm restore differs from prime ' + name)
    return {'qualified': True, 'cache_key': expected, 'profile': profile, 'cache_hit': hit == 'true',
            'effective_profile': effective_profile, 'scope': scope}


def finish(report, platform, scheme):
    context = json.loads((report / 'binding.json').read_text())['context']
    metadata = json.loads((report / 'metadata.json').read_text())
    restore = json.loads((report / 'restore.json').read_text())
    lane = json.loads((report / 'lane.json').read_text())
    artifact = json.loads((report / 'artifact.json').read_text())
    packages = json.loads((report / 'packages-before-save.json').read_text())
    cache = json.loads((report / 'cache-after.json').read_text())
    require(restore['qualified'] and lane['qualified'] and artifact['qualified'] and packages['files'] > 0 and
            cache['key'] == restore['cache_key'] and artifact['platform'] == platform and
            artifact['source_sha'] == context['source_sha'] and artifact['controller_sha'] == context['controller_sha'] and
            artifact['toolchain'] == json.loads(metadata['toolchain_json'])[scheme], 'Device evidence is incomplete')
    if context['profile'] == 'prime':
        require(cache['cache'] is not None, 'Qualified prime cache was not saved')
    elif context['profile'] == 'warm':
        require(cache['cache'] == json.loads((report / 'cache-before.json').read_text())['cache'],
                'Warm cache identity changed')
    else:
        require(cache['cache'] is None, 'Off arm recorded cache mutation')
    result = {**context, 'schema_version': 1, 'qualified': True, 'platform': platform,
              'cache': cache['cache'], 'cache_key': restore['cache_key'],
              'packages_before_save': packages, 'restore': restore, 'lane': lane,
              'toolchain': json.loads(metadata['toolchain_json'])[scheme],
              'graph_before': json.loads((report / 'graph-before-archive.json').read_text())['graph_sha256'],
              'graph_after': json.loads((report / 'graph-after-archive.json').read_text())['graph_sha256'],
              'artifact_receipt_sha256': hashlib.sha256((report / 'artifact.json').read_bytes()).hexdigest(),
              'runner_image': {name: os.environ.get(name, '') for name in ('ImageOS', 'ImageVersion', 'RUNNER_OS', 'RUNNER_ARCH')},
              'xcodegen_cache_hit': os.environ.get('DEVICE_XCODEGEN_HIT') == 'true'}
    result['lane_runtime'] = json.loads((report / 'lane-runtime.json').read_text())
    require(result['lane_runtime']['fastlane'] == '2.240.1' and result['lane_runtime']['bundler'] == '4.0.15' and
            re.fullmatch('3\\.3\\.[0-9]+', result['lane_runtime']['ruby']), 'Lane runtime differs from the controlled version')
    result['job_started_unix'] = int(os.environ['DEVICE_JOB_STARTED'])
    result['receipt_completed_unix'] = time.time()
    require(result['graph_before'] == result['graph_after'], 'Archive changed the pinned package graph')
    return result


def upload_bounds(report):
    require(report.is_dir() and not report.is_symlink(), 'Report directory is invalid')
    entries, total = [], 0
    for path in sorted(report.iterdir()):
        require(path.is_file() and not path.is_symlink() and path.suffix in ('.json', '.jsonl', '.log') and
                re.fullmatch('[a-z0-9_-]+\.(json|jsonl|log)', path.name), 'Report contains an unexpected node')
        total += path.stat().st_size
        entries.append(path.name)
    require(0 < len(entries) <= 32 and total <= REPORT_LIMIT, 'Tiny report exceeds entry or byte limit')
    return {'qualified': True, 'files': entries, 'bytes': total}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('tree', 'cache', 'prime', 'restored', 'finish', 'metadata', 'prime-artifact', 'upload-bounds'))
    parser.add_argument('--packages', type=Path)
    parser.add_argument('--metadata', type=Path)
    parser.add_argument('--namespace')
    parser.add_argument('--scheme')
    parser.add_argument('--required', choices=('true', 'false'))
    parser.add_argument('--run-id')
    parser.add_argument('--platform', choices=('ios', 'tvos'))
    parser.add_argument('--controller-sha')
    parser.add_argument('--source-sha')
    parser.add_argument('--fixture-sha')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--profile', choices=('off', 'prime', 'warm'))
    parser.add_argument('--hit', default='')
    parser.add_argument('--effective-profile')
    parser.add_argument('--scope')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.operation == 'tree':
        result = tree(args.packages)
    elif args.operation == 'cache':
        metadata = json.loads(args.metadata.read_text())
        cache_key = key(metadata, args.namespace, args.scheme)
        result = {'key': cache_key, 'cache': None if args.profile == 'off' else
                  GitHub(os.environ.get('GH_TOKEN')).cache(cache_key, args.required == 'true')}
    elif args.operation == 'prime':
        receipt, artifact, provenance = GitHub(os.environ.get('GH_TOKEN')).prime(
            args.run_id, args.platform, args.controller_sha, args.source_sha, args.fixture_sha, args.namespace)
        result = {'receipt': receipt, 'artifact': artifact, 'provenance': provenance}
    elif args.operation == 'restored':
        result = restored(args.report, args.profile, args.hit, args.effective_profile, args.scope, args.scheme)
    elif args.operation == 'metadata':
        metadata = json.loads(args.metadata.read_text())
        key(metadata, metadata['cache_namespace'], args.scheme)
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            for name, value in metadata.items():
                require(isinstance(value, str) and '\n' not in value and '\r' not in value,
                        'Metadata workflow output contains unsupported values')
                stream.write(name + '=' + value + '\n')
        result = json.loads(metadata['toolchain_json'])[args.scheme]
    elif args.operation == 'prime-artifact':
        result = json.loads((args.report / 'prime.json').read_text())['artifact']
    elif args.operation == 'upload-bounds':
        result = upload_bounds(args.report)
    else:
        result = finish(args.report, args.platform, args.scheme)
    save(args.output, result)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, urllib.error.URLError) as error:
        message = str(error)[:200] if isinstance(error, ValueError) else type(error).__name__
        print('::error::Device cache receipt failed: ' + message)
        raise SystemExit(1)
