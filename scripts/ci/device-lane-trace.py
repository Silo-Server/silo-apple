#!/usr/bin/env python3
"""Run the existing unsigned lane and transparently record its native commands."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

LOCK = 'iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
TARGETS = {'ios': ('Silo', 'ios', 'ipa_ios_unsigned'),
           'tvos': ('SiloTV', 'ios', 'ipa_tvos_unsigned')}
LIMIT = 35 * 60


def require(ok, message):
    if not ok:
        raise ValueError(message)


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def locked(argv, config):
    for flag in ('-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile'):
        require(argv.count(flag) == 1, 'Missing or repeated locked package flag')
    for flag, value in (('-clonedSourcePackagesDirPath', config['packages']),
                        ('-scheme', config['scheme']),
                        ('-project', config['root'] + '/iosApp/Silo.xcodeproj')):
        require(argv.count(flag) == 1 and argv[argv.index(flag) + 1] == value,
                'Unexpected native ' + flag)


def graph(config, name, compare=False):
    report = Path(config['report'])
    argv = [sys.executable, config['graph_helper'], '--root', config['root'],
            '--packages', config['packages'], '--output', str(report / (name + '.json'))]
    if compare:
        argv += ['--compare', str(report / 'graph-before-archive.json')]
    started = time.monotonic()
    result = subprocess.run(argv, timeout=130)
    require(result.returncode == 0, 'Package graph attestation failed: ' + name)
    return time.monotonic() - started


def proxy(config_path, argv):
    config = json.loads(config_path.read_text())
    require(argv, 'Empty xcodebuild invocation')
    category = ('resolve' if '-resolvePackageDependencies' in argv else
                'archive' if 'archive' in argv else 'information')
    if category == 'information':
        require(argv in (['-version'], ['-version', '-sdk']),
                'Unexpected native build action outside the unsigned lane')
    else:
        locked(argv, config)
    before = graph(config, 'graph-before-archive') if category == 'archive' else 0
    started, wall = time.monotonic(), time.time()
    result = subprocess.run([config['native'], *argv])
    elapsed = time.monotonic() - started
    after = graph(config, 'graph-after-archive', True) if category == 'archive' and result.returncode == 0 else 0
    record = {'category': category, 'argv': argv, 'started_unix': wall,
              'native_seconds': elapsed, 'exit_code': result.returncode,
              'graph_before_seconds': before, 'graph_after_seconds': after}
    # One Fastlane lane runs commands serially. Each record is one atomic append.
    with (Path(config['report']) / 'native-commands.jsonl').open('a') as stream:
        stream.write(json.dumps(record, sort_keys=True) + '\n')
    # Preserve the shell-visible status used by Fastlane's pipefail command.
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


def run_lane(root, report, packages, platform, graph_helper, command=None, timeout=LIMIT):
    root, report, packages, graph_helper = (p.resolve() for p in (root, report, packages, graph_helper))
    require(root.is_dir() and graph_helper.is_file() and not graph_helper.is_symlink(), 'Invalid lane paths')
    require(packages == root / '.ci-cache/packages', 'Package path must use the checked shipping cache path')
    require(report.is_dir() and not list(report.glob('native-*')), 'Native report output already exists')
    derived = Path.home() / 'Library/Developer/Xcode/DerivedData'
    require(not derived.exists() or not any(derived.iterdir()), 'Default DerivedData must be empty before the lane')
    require(not (root / 'build').exists(), 'Archive output must be absent before the lane')
    require(not any(os.environ.get(k) for k in ('XCODE_DERIVED_DATA_PATH', 'XCODE_BUILD_PATH',
                'XCODE_SCHEME', 'XCODE_WORKSPACE', 'XCODE_PROJECT', 'XCODE_BUILDLOG_PATH')),
            'External Fastlane build overrides are present')
    scheme, lane_platform, lane = TARGETS[platform]
    native = shutil.which('xcodebuild')
    require(native and Path(native).is_file(), 'xcodebuild is unavailable')
    lock_before = hashlib.sha256((root / LOCK).read_bytes()).hexdigest()
    config = {'root': str(root), 'report': str(report), 'packages': str(packages),
              'graph_helper': str(graph_helper), 'scheme': scheme, 'native': native,
              'platform': platform, 'lock_before': lock_before}
    bin_dir = report.parent / ('device-native-proxy-' + platform)
    bin_dir.mkdir()
    config_path = bin_dir / 'config.json'
    save(config_path, config)
    wrapper = bin_dir / 'xcodebuild'
    wrapper.write_text('#!' + sys.executable + '\nimport os, sys\nos.execv(' +
                       repr(sys.executable) + ', [' + repr(sys.executable) + ', ' +
                       repr(str(Path(__file__).resolve())) + ", 'proxy', " +
                       repr(str(config_path)) + '] + sys.argv[1:])\n')
    wrapper.chmod(0o755)
    env = os.environ.copy()
    env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']
    argv = command or ['bundle', 'exec', 'fastlane', lane_platform, lane]
    require(command is not None or argv == ['bundle', 'exec', 'fastlane', lane_platform, lane], 'Invalid unsigned lane')
    started, wall = time.monotonic(), time.time()
    process = subprocess.Popen(argv, cwd=root, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    tail = bytearray()
    timed_out = False
    # A watchdog bounds the owned lane process group while stdout streams normally.
    def alarm(_signal, _frame):
        nonlocal timed_out
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
    previous = signal.signal(signal.SIGALRM, alarm)
    def cancelled(_signal, _frame):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        raise KeyboardInterrupt('Unsigned lane cancelled')
    cancellations = {sig: signal.signal(sig, cancelled) for sig in (signal.SIGTERM, signal.SIGINT)}
    signal.alarm(timeout)
    try:
        for chunk in iter(lambda: process.stdout.read(8192), b''):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            tail.extend(chunk)
            if len(tail) > 256 * 1024:
                del tail[:-256 * 1024]
        code = process.wait()
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        for sig, handler in cancellations.items():
            signal.signal(sig, handler)
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        process.stdout.close()
    elapsed = time.monotonic() - started
    (report / 'lane-tail.log').write_bytes(tail)
    records_path = report / 'native-commands.jsonl'
    records = [json.loads(line) for line in records_path.read_text().splitlines()] if records_path.exists() else []
    qualifies = (code == 0 and not timed_out and
                 [r['category'] for r in records if r['category'] != 'information'] == ['resolve', 'archive'] and
                 all(r['exit_code'] == 0 for r in records) and
                 hashlib.sha256((root / LOCK).read_bytes()).hexdigest() == lock_before and
                 not subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=no']).strip())
    result = {'schema_version': 1, 'qualified': qualifies, 'lane_argv': argv,
              'lane_exit_code': code, 'timed_out': timed_out, 'lane_started_unix': wall,
              'lane_seconds': elapsed, 'native_executable': native, 'default_derived_data_empty_at_start': True,
              'lock_before': lock_before, 'commands': records,
              'attestation_seconds': sum(r['graph_before_seconds'] + r['graph_after_seconds'] for r in records)}
    save(report / 'lane.json', result)
    archives = [r['argv'] for r in records if r['category'] == 'archive']
    if len(archives) == 1:
        save(report / 'archive-argv.json', archives[0])
    require(qualifies, 'Lane failed, changed source/lock, or did not execute exactly one resolve and archive')
    return result


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'proxy':
        return proxy(Path(sys.argv[2]), sys.argv[3:])
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'report', 'packages', 'graph-helper'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=TARGETS, required=True)
    args = parser.parse_args()
    run_lane(args.root, args.report, args.packages, args.platform, args.graph_helper)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError, IndexError, KeyError) as error:
        print('::error::Unsigned lane trace failed: ' + str(error)[:300], file=sys.stderr)
        raise SystemExit(1)
