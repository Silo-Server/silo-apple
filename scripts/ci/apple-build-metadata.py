#!/usr/bin/env python3
"""Record the actual source, toolchain and cache state used by Apple CI."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

LOCK = Path('iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
SDKS = {'Silo': 'iphonesimulator', 'SiloTV': 'appletvsimulator', 'SiloMac': 'macosx'}


def command(*args, cwd=None):
    try:
        return subprocess.check_output(args, cwd=cwd, text=True, timeout=60).strip()
    except subprocess.TimeoutExpired:
        raise RuntimeError('Build metadata command timed out: ' + args[0]) from None


def parse_xcode(text):
    match = re.fullmatch(r'Xcode ([0-9]+(?:\.[0-9]+)*)\nBuild version ([A-Za-z0-9]+)', text.strip())
    if not match:
        raise ValueError('Unexpected xcodebuild version output')
    return {'xcode_version': match[1], 'xcode_build': match[2]}


def validate_controls(env):
    namespace = env.get('SILO_CACHE_NAMESPACE', 'v1')
    if not re.fullmatch(r'[a-z0-9_-]{1,32}', namespace):
        raise ValueError('Cache namespace must use 1-32 lowercase letters, digits, underscores or hyphens')
    source_ref = env.get('SILO_BENCHMARK_SOURCE_REF', '')
    if source_ref and not re.fullmatch(r'[0-9a-f]{40}', source_ref):
        raise ValueError('Benchmark source must be an immutable 40-character commit SHA')
    return namespace


def toolchains():
    xcode = parse_xcode(command('xcodebuild', '-version'))
    architecture = command('uname', '-m')
    runtimes = json.loads(command('xcrun', 'simctl', 'list', 'runtimes', '--json'))['runtimes']
    result = {}
    for scheme, sdk in SDKS.items():
        item = {**xcode, 'architecture': architecture,
                'sdk_version': command('xcrun', '--sdk', sdk, '--show-sdk-version'),
                'sdk_build': command('xcrun', '--sdk', sdk, '--show-sdk-build-version')}
        if scheme != 'SiloMac':
            prefix = 'com.apple.CoreSimulator.SimRuntime.' + ('iOS-' if scheme == 'Silo' else 'tvOS-')
            matching = [runtime for runtime in runtimes if runtime.get('isAvailable')
                        and runtime.get('version') == item['sdk_version']
                        and runtime.get('identifier', '').startswith(prefix)]
            # A missing runtime prevents release-proof reuse. The test job may
            # download its runtime and record complete metadata afterwards.
            item.update(runtime_version=matching[0]['version'] if matching else '',
                        runtime_build=matching[0].get('buildversion', '') if matching else '')
        result[scheme] = item
    return result


def metadata(root, env):
    namespace = validate_controls(env)
    sha = command('git', 'rev-parse', 'HEAD', cwd=root)
    fingerprint = command('git', 'rev-parse', 'HEAD^{tree}', cwd=root)
    lock = hashlib.sha256((root / LOCK).read_bytes()).hexdigest()
    tools = toolchains()
    # SDK build and architecture also scope caches; runtime changes are covered
    # separately by the complete release-proof toolchain metadata.
    cache_inputs = {'xcode': tools['Silo']['xcode_build'], 'architecture': tools['Silo']['architecture'],
                    'sdks': {scheme: tools[scheme]['sdk_build'] for scheme in SDKS}}
    key = hashlib.sha256(json.dumps(cache_inputs, sort_keys=True).encode()).hexdigest()[:24]
    config = hashlib.sha256()
    for path in [root / 'iosApp/project.yml', *sorted((root / 'iosApp/Signing').glob('*.xcconfig'))]:
        config.update(path.relative_to(root).as_posix().encode() + b'\0' + path.read_bytes() + b'\0')
    return {'source_sha': sha, 'fingerprint': fingerprint, 'lock_sha256': lock,
            'toolchain_key': key, 'build_config_sha256': config.hexdigest(), 'toolchain_json': json.dumps(tools, sort_keys=True, separators=(',', ':')),
            'cache_namespace': namespace}


def emit_outputs(result, path):
    with open(path, 'a') as output:
        for key, value in result.items():
            if '\n' in value or '\r' in value:
                raise ValueError('Multiline workflow output rejected')
            output.write(f'{key}={value}\n')


def benchmark(result, env):
    tools = json.loads(result['toolchain_json'])
    platform = env.get('PLATFORM', 'macOS')
    scheme = {'iOS': 'Silo', 'tvOS': 'SiloTV', 'macOS': 'SiloMac'}[platform]
    spm_hit = env.get('SILO_SPM_CACHE_HIT') == 'true'
    derived_hit = env.get('SILO_DERIVED_CACHE_HIT') == 'true'
    derived_restored = derived_hit or env.get('SILO_DERIVED_CACHE_RESTORED') == 'true'
    derived_key = env.get('SILO_DERIVED_CACHE_KEY', '')
    xcodegen_hit = env.get('SILO_XCODEGEN_CACHE_HIT') == 'true'
    return {'source_sha': result['source_sha'], 'variant': env.get('SILO_BENCH_VARIANT', 'optimized'),
            'cache_regime': 'warm' if spm_hit or derived_restored else 'cold',
            'cache_namespace': result['cache_namespace'], 'platform': platform,
            'toolchain': tools[scheme], 'spm_cache_hit': spm_hit,
            'derived_cache_hit': derived_hit, 'derived_cache_restored': derived_restored,
            'derived_cache_key': derived_key,
            'derived_cache_kind': 'exact' if derived_hit else 'prefix' if derived_restored else 'miss',
            'xcodegen_cache_hit': xcodegen_hit,
            'dependency_lock_sha256': result['lock_sha256'],
            'build_config_sha256': result['build_config_sha256'], 'cache_mode': env.get('SILO_CACHE_MODE', 'dependencies')}


def proof(result, root, env, scheme):
    if env['GITHUB_EVENT_NAME'] != 'push' or env['GITHUB_REF_NAME'] != 'main':
        raise ValueError('Only main push regressions produce trusted release proof')
    if result['source_sha'] != env['GITHUB_SHA'] or env.get('SILO_FULL_SUITE') != 'true':
        raise ValueError('Release proof requires the workflow source and complete suite')
    committed = subprocess.check_output(['git', 'show', f'HEAD:{LOCK.as_posix()}'], cwd=root)
    if hashlib.sha256(committed).hexdigest() != result['lock_sha256']:
        raise ValueError('Package.resolved changed during dependency preparation')
    tools = json.loads(result['toolchain_json'])[scheme]
    if scheme != 'SiloMac' and (not tools['runtime_version'] or not tools['runtime_build']):
        raise ValueError('Simulator runtime metadata is unavailable')
    return {'schema_version': 1, 'repository': env['GITHUB_REPOSITORY'],
            'workflow_path': '.github/workflows/player-regression.yml',
            'event': env['GITHUB_EVENT_NAME'], 'branch': env['GITHUB_REF_NAME'],
            'sha': result['source_sha'], 'run_id': int(env['GITHUB_RUN_ID']),
            'run_attempt': int(env['GITHUB_RUN_ATTEMPT']), 'scheme': scheme,
            'fingerprint': result['fingerprint'], 'toolchain': tools,
            'dependency_lock_sha256': result['lock_sha256'], 'frozen_dependencies': True,
            'full_suite': env.get('SILO_FULL_SUITE') == 'true'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--outputs', action='store_true')
    parser.add_argument('--benchmark', action='store_true')
    parser.add_argument('--proof', choices=SDKS)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = metadata(args.root.resolve(), os.environ)
    if args.outputs:
        emit_outputs(result, os.environ['GITHUB_OUTPUT'])
    elif args.benchmark:
        print('SILO_CI_BENCHMARK ' + json.dumps(benchmark(result, os.environ), sort_keys=True))
    elif args.proof:
        if not args.output:
            parser.error('--proof requires --output')
        args.output.write_text(json.dumps(proof(result, args.root.resolve(), os.environ, args.proof),
                                          sort_keys=True, indent=2) + '\n')
    else:
        print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
