#!/usr/bin/env python3
"""Inspect unsigned device artifacts and compare their complete IPA payloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import posixpath
import re
import signal
import stat
import subprocess
import zipfile

VERSION, BUILD = '0.0.1', '2026100701'
SOURCE_PREFIX = 'https://github.com/Silo-Server/silo-apple/releases/download/v0.0.1-ci-device-benchmark/Silo-source-'
TARGETS = {
    'ios': ('Silo', 'iphoneos', 'iPhoneOS', {'2', 'IOS'}, {
        'SiloNotificationService.appex': 'org.siloserver.silo.NotificationService',
        'SiloDownloadsActivity.appex': 'org.siloserver.silo.DownloadsActivity'}),
    'tvos': ('SiloTV', 'appletvos', 'AppleTVOS', {'3', 'TVOS'}, {
        'SiloTVTopShelf.appex': 'org.siloserver.silo.topshelf'})}
MAGIC = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
                                  'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
LIMIT_BYTES, LIMIT_ENTRIES = 4 * 1024 ** 3, 100000


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(stream):
    sha, size = hashlib.sha256(), 0
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        size += len(chunk)
        require(size <= LIMIT_BYTES, 'Artifact member exceeds byte limit')
        sha.update(chunk)
    return sha.hexdigest(), size


def node(path, mode, data=None, stream=None):
    kind = stat.S_IFMT(mode)
    require(kind in (stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK), 'Unsupported node type: ' + path)
    entry = {'path': path, 'type': {stat.S_IFDIR: 'directory', stat.S_IFREG: 'file',
                                  stat.S_IFLNK: 'symlink'}[kind], 'mode': stat.S_IMODE(mode)}
    if stream is not None:
        entry['sha256'], entry['size'] = digest(stream)
    else:
        data = data or b''
        entry.update(sha256=hashlib.sha256(data).hexdigest(), size=len(data))
    if kind == stat.S_IFLNK:
        entry['target'] = data.decode('utf-8')
    return entry


def validate_links(entries, app_prefix):
    by_path = {entry['path']: entry for entry in entries}
    for entry in entries:
        for ancestor in Path(entry['path']).parents:
            require(by_path.get(ancestor.as_posix(), {}).get('type', 'directory') == 'directory',
                    'Member beneath a nondirectory: ' + entry['path'])
        if entry['type'] != 'symlink':
            continue
        current, seen = entry['path'], set()
        while by_path.get(current, {}).get('type') == 'symlink':
            require(current not in seen, 'Symlink cycle: ' + entry['path'])
            seen.add(current)
            target = by_path[current]['target']
            require(target and not target.startswith('/') and '\\' not in target and '\0' not in target,
                    'Unsafe symlink: ' + current)
            current = posixpath.normpath(posixpath.join(posixpath.dirname(current), target))
            require(current == app_prefix or current.startswith(app_prefix + '/'),
                    'Symlink escapes app: ' + entry['path'])
            require(current in by_path, 'Dangling symlink: ' + entry['path'])


def app_manifest(app, prefix):
    require(app.is_dir() and not app.is_symlink(), 'Archived app is missing or is a symlink')
    entries = []
    paths = [app, *sorted(app.rglob('*'))]
    require(len(paths) <= LIMIT_ENTRIES and
            sum(p.lstat().st_size for p in paths if not p.is_dir() or p.is_symlink()) <= LIMIT_BYTES,
            'Archived app exceeds limits')
    for path in paths:
        relative = path.relative_to(app).as_posix()
        name = prefix if relative == '.' else prefix + '/' + relative
        mode = path.lstat().st_mode
        if stat.S_ISREG(mode):
            with path.open('rb') as stream:
                entries.append(node(name, mode, stream=stream))
        else:
            entries.append(node(name, mode, os.readlink(path).encode() if path.is_symlink() else b''))
    require(len(entries) <= LIMIT_ENTRIES and sum(e['size'] for e in entries) <= LIMIT_BYTES,
            'Archived app exceeds limits')
    validate_links(entries, prefix)
    return sorted(entries, key=lambda e: e['path'])


def ipa_manifest(ipa, prefix):
    entries, wrapper, seen = [], [], set()
    with zipfile.ZipFile(ipa) as archive:
        require(len(archive.infolist()) <= LIMIT_ENTRIES, 'IPA exceeds entry limit')
        require(sum(info.file_size for info in archive.infolist()) <= LIMIT_BYTES, 'IPA exceeds byte limit')
        for info in archive.infolist():
            require(info.orig_filename == info.filename and '\0' not in info.orig_filename,
                    'Transformed or NUL IPA member name')
            name = info.filename.rstrip('/')
            require(name and all(p not in ('', '.', '..') for p in name.split('/')) and
                    not name.startswith('/') and '\\' not in name and '\0' not in name,
                    'Unsafe IPA member')
            require(name not in seen, 'Duplicate IPA member: ' + name)
            seen.add(name)
            require(name == 'Payload' or name == prefix or name.startswith(prefix + '/'),
                    'Unexpected IPA member: ' + name)
            require(not info.flag_bits & 1, 'Encrypted IPA member')
            mode = info.external_attr >> 16
            require(info.create_system == 3 and stat.S_IFMT(mode) != 0, 'Missing Unix node metadata: ' + name)
            require(info.is_dir() == stat.S_ISDIR(mode), 'Inconsistent IPA directory metadata: ' + name)
            require(not stat.S_ISLNK(mode) or info.file_size <= 4096, 'Oversized symlink')
            with archive.open(info) as stream:
                data = stream.read() if stat.S_ISLNK(mode) else None
                entry = node(name, mode, data=data, stream=None if data is not None else stream)
            require(entry['size'] == info.file_size, 'IPA member size mismatch: ' + name)
            require(name != 'Payload' or entry['type'] == 'directory' and entry['size'] == 0,
                    'Payload root is not an empty directory')
            entries.append(entry)
            wrapper.append({'path': name, 'timestamp': list(info.date_time), 'compression': info.compress_type,
                            'compressed_bytes': info.compress_size, 'crc32': info.CRC,
                            'extra_sha256': hashlib.sha256(info.extra).hexdigest(),
                            'comment_sha256': hashlib.sha256(info.comment).hexdigest()})
    validate_links(entries, prefix)
    return sorted(entries, key=lambda e: e['path']), sorted(wrapper, key=lambda e: e['path'])


def run(argv):
    result = subprocess.run(argv, capture_output=True, timeout=60)
    require(len(result.stdout) + len(result.stderr) <= 1024 ** 2, 'Native tool output exceeds limit')
    return result.returncode, result.stdout, result.stderr


def native(binary, platforms, runner, expected_sdk=None):
    code, output, error = runner(['xcrun', 'lipo', '-archs', str(binary)])
    require(code == 0 and not error, 'Architecture inspection failed')
    arches = output.decode().split()
    require(arches and len(arches) == len(set(arches)) and set(arches) <= {'arm64', 'arm64e'} and
            'arm64' in arches, 'Unexpected device architectures')
    slices = []
    for architecture in arches:
        code, output, error = runner(['xcrun', 'otool', '-arch', architecture, '-l', str(binary)])
        require(code == 0 and not error, 'Load command inspection failed')
        text = output.decode()
        found = re.findall(r'^\s*platform\s+(\S+)\s*$', text, re.M)
        sdk_versions = re.findall(r'^\s*sdk\s+([0-9]+(?:\.[0-9]+)*)\s*$', text, re.M)
        minimum_versions = re.findall(r'^\s*minos\s+([0-9]+(?:\.[0-9]+)*)\s*$', text, re.M)
        require(text.count('cmd LC_BUILD_VERSION') == 1 and len(found) == 1 and
                len(sdk_versions) == 1 and len(minimum_versions) == 1 and
                set(found) <= platforms, 'Missing, duplicate or wrong device build platform')
        if expected_sdk is not None:
            require(sdk_versions == [expected_sdk], 'Generated executable uses the wrong SDK')
        code, output, error = runner(['codesign', '-d', '--architecture', architecture, '--verbose=4', str(binary)])
        signing = error.decode()
        if code:
            require('code object is not signed at all' in signing and 'cmd LC_CODE_SIGNATURE' not in text,
                    'Unknown or malformed unsigned signature')
            signature = 'unsigned'
        else:
            require('Signature=adhoc' in signing and not re.search(r'^Authority=', signing, re.M) and
                    re.findall(r'^TeamIdentifier=(.*)$', signing, re.M) in ([], ['not set']) and
                    text.count('cmd LC_CODE_SIGNATURE') == 1,
                    'Certificate or team signing is present')
            code, entitlements, error = runner(['codesign', '-d', '--architecture', architecture,
                                               '--entitlements', ':-', str(binary)])
            require(code == 0 and (not entitlements.strip() or plistlib.loads(entitlements) == {}),
                    'Signed entitlements are present or unreadable')
            signature = 'adhoc-no-identity'
        slices.append({'architecture': architecture, 'platform': found[0], 'signature': signature,
                       'sdk_version': sdk_versions[0], 'minimum_os_version': minimum_versions[0],
                       'uuids': re.findall(r'^\s*uuid\s+(\S+)\s*$', text, re.M),
                       'has_code_signature_command': 'cmd LC_CODE_SIGNATURE' in text})
    if any(s['signature'] == 'adhoc-no-identity' for s in slices):
        code, output, error = runner(['codesign', '--verify', '--strict', str(binary)])
        app = next((p for p in binary.parents if p.suffix == '.app'), None)
        label = binary.relative_to(app.parent).as_posix() if app else binary.name
        detail = error.decode(errors='replace').strip().replace(str(binary), binary.name)
        require(code == 0, 'Ad-hoc signature integrity verification failed: ' + label +
                '; exit=' + str(code) + '; stderr=' + detail[:160])
    return {'architectures': arches, 'slices': slices}


def inspect(archive, ipa, platform, source_sha, controller_sha, toolchain, archive_argv, runner=run):
    require(re.fullmatch('[0-9a-f]{40}', source_sha) and re.fullmatch('[0-9a-f]{40}', controller_sha),
            'Source and controller must be immutable SHAs')
    app_name, sdk, supported, platforms, extensions = TARGETS[platform]
    source_url = SOURCE_PREFIX + source_sha + '.tar.gz'
    expected_flags = {'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=',
                      'CODE_SIGN_ENTITLEMENTS=', 'SILO_BUILD_CHANNEL=sideload', 'MARKETING_VERSION=' + VERSION,
                      'CURRENT_PROJECT_VERSION=' + BUILD, 'SILO_SOURCE_URL=' + source_url}
    if platform == 'tvos':
        expected_flags.add('SILO_USER_INDEPENDENT_KEYCHAIN=NO')
    require(expected_flags <= set(archive_argv) and archive_argv.count('archive') == 1,
            'Archive invocation lacks required literal unsigned settings')
    for expected in expected_flags:
        require([arg for arg in archive_argv if arg.startswith(expected.split('=', 1)[0] + '=')] == [expected],
                'Conflicting archive build setting')
    for flag, expected in [('-scheme', app_name), ('-destination', 'generic/platform=' + {'ios': 'iOS', 'tvos': 'tvOS'}[platform]),
                           ('-archivePath', str(archive))]:
        require(archive_argv.count(flag) == 1 and archive_argv[archive_argv.index(flag) + 1] == expected,
                'Archive invocation has wrong ' + flag)
    require(toolchain['sdk'] == sdk, 'Toolchain uses the wrong device SDK')
    require(archive.is_dir() and not archive.is_symlink() and archive.suffix == '.xcarchive' and
            ipa.is_file() and not ipa.is_symlink() and ipa.suffix == '.ipa', 'Invalid archive or IPA paths')
    applications = archive / 'Products/Applications'
    require(all(p.is_dir() and not p.is_symlink() for p in (archive / 'Products', applications)),
            'Archive Products and Applications must be real directories')
    require(sorted(p.name for p in applications.iterdir()) == [app_name + '.app'], 'Unexpected archived app inventory')
    app = applications / (app_name + '.app')
    prefix = 'Payload/' + app.name
    archived = app_manifest(app, prefix)
    members, wrapper = ipa_manifest(ipa, prefix)
    require([e for e in members if e['path'] != 'Payload'] == archived, 'IPA payload differs from archived app')
    require(not any(Path(e['path']).name.lower() in ('embedded.mobileprovision', 'embedded.provisionprofile')
                    for e in archived), 'Provisioning profile is present')
    bundles = [app, *sorted(app.rglob('*.appex'))]
    require({p.relative_to(app).as_posix() for p in bundles[1:]} ==
            {'PlugIns/' + name for name in extensions} and
            all(p.is_dir() and not p.is_symlink() for p in bundles[1:]) and len(bundles) == 1 + len(extensions),
            'Unexpected extension inventory')
    bundle_info, binaries, executables = {}, {}, set()
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        expected = {'CFBundleIdentifier': 'org.siloserver.silo' if bundle == app else extensions[bundle.name],
                    'CFBundlePackageType': 'APPL' if bundle == app else 'XPC!',
                    'CFBundleVersion': BUILD, 'CFBundleShortVersionString': VERSION,
                    'CFBundleSupportedPlatforms': [supported], 'DTPlatformName': sdk,
                    'DTSDKBuild': toolchain['sdk_build'], 'DTSDKName': sdk + toolchain['sdk_version'],
                    'DTXcodeBuild': toolchain['xcode_build']}
        if bundle == app:
            expected.update(SiloBuildChannel='sideload', SiloSourceURL=source_url)
        require(all(info.get(k) == v for k, v in expected.items()), 'Bundle metadata mismatch: ' + bundle.name)
        executable = info.get('CFBundleExecutable')
        require(isinstance(executable, str) and executable == bundle.stem and
                Path(executable).name == executable and '\\' not in executable and '\0' not in executable,
                'Unsafe bundle executable name')
        require((bundle / executable).is_file() and not (bundle / executable).is_symlink(),
                'Bundle executable must be its own regular file')
        require((bundle / executable).stat().st_mode & 0o111, 'Bundle executable lacks execute permission')
        executables.add((bundle / executable).relative_to(app).as_posix())
        with (bundle / executable).open('rb') as stream:
            require(stream.read(4) in MAGIC, 'Bundle executable is not Mach-O')
        bundle_info[bundle.relative_to(app).as_posix()] = expected
    for entry in archived:
        if entry['type'] != 'file':
            continue
        path = app / entry['path'][len(prefix) + 1:]
        with path.open('rb') as stream:
            if stream.read(4) in MAGIC:
                relative = path.relative_to(app).as_posix()
                binaries[relative] = native(path, platforms, runner,
                                            toolchain['sdk_version'] if relative in executables else None)
    with ipa.open('rb') as stream:
        raw_sha, raw_size = digest(stream)
    return {'schema_version': 1, 'qualified': True, 'platform': platform, 'source_sha': source_sha,
            'controller_sha': controller_sha, 'toolchain': toolchain, 'archive_argv': archive_argv,
            'raw_ipa_sha256': raw_sha, 'raw_ipa_bytes': raw_size, 'members': members,
            'zip_wrapper': wrapper, 'bundles': bundle_info, 'native': binaries}


def compare(receipts):
    require(len(receipts) >= 2, 'At least two receipts are required')
    keys = ('schema_version', 'platform', 'source_sha', 'controller_sha', 'toolchain', 'archive_argv',
            'members', 'bundles', 'native')
    differences = []
    for index, candidate in enumerate(receipts):
        require(isinstance(candidate, dict) and candidate.get('qualified') is True and candidate.get('schema_version') == 1 and
                all(key in candidate for key in keys) and candidate['members'] and candidate['bundles'] and
                candidate['native'] and re.fullmatch('[0-9a-f]{64}', candidate.get('raw_ipa_sha256', '')) and
                isinstance(candidate.get('raw_ipa_bytes'), int) and 0 < candidate['raw_ipa_bytes'] <= LIMIT_BYTES and
                'zip_wrapper' in candidate, 'An input receipt is unqualified or incomplete')
        for key in keys:
            if candidate.get(key) != receipts[0].get(key):
                difference = {'receipt_index': index, 'field': key}
                if key == 'members':
                    before = {e['path']: e for e in receipts[0]['members']}
                    after = {e['path']: e for e in candidate['members']}
                    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
                    difference.update(changed_paths=len(changed), members=[
                        {'path': p, 'before': before.get(p), 'after': after.get(p)} for p in changed[:20]])
                differences.append(difference)
    return {'qualified': not differences, 'differences': differences[:100],
            'raw_ipa_hashes': [r['raw_ipa_sha256'] for r in receipts],
            'raw_ipa_identical': all(r['raw_ipa_sha256'] == receipts[0]['raw_ipa_sha256'] for r in receipts),
            'zip_wrapper_identical': all(r['zip_wrapper'] == receipts[0]['zip_wrapper'] for r in receipts)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('inspect', 'compare'))
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--platform', choices=TARGETS)
    parser.add_argument('--source-sha')
    parser.add_argument('--controller-sha')
    parser.add_argument('--toolchain', type=Path)
    parser.add_argument('--archive-argv', type=Path)
    parser.add_argument('--receipts', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    def timeout(_signal, _frame):
        raise TimeoutError('Artifact inspection exceeded 120 seconds')
    previous_handler = signal.signal(signal.SIGALRM, timeout)
    signal.alarm(120)
    try:
        if args.operation == 'compare':
            result = compare([json.loads(p.read_text()) for p in args.receipts or []])
        else:
            require(all(value is not None for value in (args.archive, args.ipa, args.platform,
                    args.source_sha, args.controller_sha, args.toolchain, args.archive_argv)),
                    'Inspect requires archive, IPA, platform, source, controller, toolchain and argv')
            result = inspect(args.archive, args.ipa, args.platform, args.source_sha, args.controller_sha,
                             json.loads(args.toolchain.read_text()), json.loads(args.archive_argv.read_text()))
    except (ValueError, OSError, KeyError, TypeError, IndexError, zipfile.BadZipFile,
            subprocess.TimeoutExpired) as error:
        result = {'qualified': False, 'error': (type(error).__name__ + ': ' + str(error))[:300]}
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_handler)
    args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    return 0 if result['qualified'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
