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
DEVICE_SDKS = {'Silo-device': 'iphoneos', 'SiloTV-device': 'appletvos'}
SHARED_SPM_LOCK_SHA256 = '40e3e0fbe264adac749a1f7db3f91a311e67f6419eeecad6bd4d88c07efd9410'
SHARED_SPM_PROJECT_SHA256 = 'b698ee86dc410c8ada9251778a655f5428b2ea663ccfc8ba1291f180aa472eca'
SHARED_SPM_TOOLCHAIN_KEY = '5e23d2022187a1fa502ad4a6'

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


def compilation_cache_profile(env):
    enabled = env.get('SILO_COMPILATION_CACHE_ENABLED', 'false')
    if enabled not in ('true', 'false'):
        raise ValueError('Compilation cache opt-in must be true or false')
    if enabled == 'true':
        if env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch':
            raise ValueError('Compilation caching requires a manual benchmark')
        if env.get('SILO_BENCH_VARIANT') != 'optimized':
            raise ValueError('Compilation caching requires the optimized variant')
        if env.get('SILO_CACHE_MODE') != 'derived_data':
            raise ValueError('Compilation caching requires the derived_data cache mode')
        return 'compilation-cache-v1'
    return 'standard'


def spm_cache_scope(env, lock_sha256, project_sha256, toolchain_key='', *,
                    source_sha='', source_dirty=True):
    requested = env.get('SILO_SPM_CACHE_PROFILE', 'scheme')
    if requested not in ('scheme', 'shared_qualified'):
        raise ValueError('Unknown package cache profile')
    scheme = env.get('SCHEME') or {'iOS': 'Silo', 'tvOS': 'SiloTV', 'macOS': 'SiloMac'}.get(
        env.get('PLATFORM'), 'SiloMac')
    owner = env.get('SILO_SPM_CACHE_SAVE_OWNER', '')
    repository = 'Silo-Server/silo-apple'
    event = env.get('GITHUB_EVENT_NAME')
    ref = env.get('GITHUB_REF', '')
    # Reusable workflows inherit the caller's event. Release gates can read the
    # shared archive; the workflow's existing guard keeps their saves disabled.
    trusted_event = (event == 'workflow_dispatch'
                     or (event == 'pull_request'
                         and env.get('SILO_PULL_REQUEST_HEAD_REPOSITORY') == repository)
                     or (event == 'push' and (ref == 'refs/heads/main'
                         or (env.get('SILO_RELEASE_GATE') == 'true' and ref.startswith('refs/tags/')))))
    shared = (requested == 'shared_qualified'
              and env.get('GITHUB_REPOSITORY') == repository and trusted_event
              and env.get('SILO_BENCH_VARIANT') == 'optimized'
              and env.get('SILO_CACHE_MODE') in ('dependencies', 'derived_data')
              and env.get('SCHEME') in SDKS and owner in SDKS
              and isinstance(source_sha, str) and re.fullmatch(r'[0-9a-f]{40}', source_sha)
              and set(source_sha) != {'0'} and source_dirty is False
              and lock_sha256 == SHARED_SPM_LOCK_SHA256
              and project_sha256 == SHARED_SPM_PROJECT_SHA256
              and toolchain_key == SHARED_SPM_TOOLCHAIN_KEY)
    return {'spm_cache_profile_requested': requested,
            'spm_cache_profile_effective': 'shared_qualified' if shared else 'scheme',
            'spm_cache_scope': 'shared-qualified-v1' if shared else scheme,
            'spm_cache_save_owner': owner if shared else scheme}


def parallel_test_workers(env):
    enabled = env.get('SILO_IOS_PARALLEL_PILOT', 'false')
    if enabled not in ('true', 'false'):
        raise ValueError('Parallel iOS pilot must be true or false')
    if enabled == 'false':
        return 1
    if (env.get('GITHUB_REPOSITORY') != 'Silo-Server/silo-apple'
            or env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or env.get('SILO_RELEASE_GATE', 'false') != 'false'):
        raise ValueError('Parallel iOS pilot requires a manual Silo Apple benchmark')
    if (env.get('SILO_BENCH_VARIANT') != 'optimized'
            or env.get('SILO_BASELINE_REF')
            or env.get('SILO_BENCHMARK_PLATFORM') != 'ios'
            or env.get('SILO_IOS_ONLY', 'false') != 'false'
            or env.get('SILO_RECORD_PREVIEW', 'false') != 'false'):
        raise ValueError('Parallel iOS pilot requires only the optimized iOS benchmark suite')
    if not re.fullmatch(r'[0-9a-f]{40}', env.get('SILO_BENCHMARK_SOURCE_REF', '')):
        raise ValueError('Parallel iOS pilot requires an immutable app commit')
    # Selection validates controls before matrix expansion; each Mac job also
    # verifies that the selected row is the complete iOS simulator suite.
    if any(key in env for key in ('PLATFORM', 'SCHEME', 'ACTION')):
        if (env.get('PLATFORM'), env.get('SCHEME'), env.get('ACTION')) != ('iOS', 'Silo', 'test'):
            raise ValueError('Parallel iOS pilot requires the iOS simulator test row')
    return 2


def validate_controls(env):
    if env.get('SILO_CACHE_PROBE', 'none') != 'none':
        raise ValueError('Diagnostic cache probes are unavailable in this workflow')
    namespace = env.get('SILO_CACHE_NAMESPACE', 'v1')
    if not re.fullmatch(r'[a-z0-9_-]{1,32}', namespace):
        raise ValueError('Cache namespace must use 1-32 lowercase letters, digits, underscores or hyphens')
    source_ref = env.get('SILO_BENCHMARK_SOURCE_REF', '')
    if source_ref and not re.fullmatch(r'[0-9a-f]{40}', source_ref):
        raise ValueError('Benchmark source must be an immutable 40-character commit SHA')
    compilation_cache_profile(env)
    spm_cache_scope(env, '', '')
    parallel_test_workers(env)
    return namespace


def prepared_runtimes(path, scheme, identifier, sdk_version):
    if scheme not in ('Silo', 'SiloTV') or not identifier:
        raise ValueError('Prepared simulator identity is incomplete')
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate prepared simulator fields')
            result[key] = value
        return result
    data = json.loads(path.read_text(), object_pairs_hook=unique_keys)
    if not isinstance(data, dict) or not isinstance(data.get('runtimes'), list):
        raise ValueError('Prepared simulator inventory is invalid')
    runtimes = data['runtimes']
    if not all(isinstance(runtime, dict) for runtime in runtimes):
        raise ValueError('Prepared simulator inventory is invalid')
    selected = [runtime for runtime in runtimes if runtime.get('identifier') == identifier]
    prefix = 'com.apple.CoreSimulator.SimRuntime.' + ('iOS-' if scheme == 'Silo' else 'tvOS-')
    if (len(selected) != 1 or not identifier.startswith(prefix)
            or selected[0].get('isAvailable') is not True
            or selected[0].get('version') != sdk_version
            or not isinstance(selected[0].get('buildversion'), str)
            or not re.fullmatch(r'[A-Za-z0-9]+', selected[0]['buildversion'])):
        raise ValueError('Prepared simulator does not match the selected runtime and SDK')
    return runtimes


def toolchains(runtime_capture=None, selected_scheme='', runtime_identifier=''):
    xcode = parse_xcode(command('xcodebuild', '-version'))
    architecture = command('uname', '-m')
    sdk_versions = {scheme: command('xcrun', '--sdk', sdk, '--show-sdk-version')
                    for scheme, sdk in SDKS.items()}
    runtimes = (prepared_runtimes(runtime_capture, selected_scheme, runtime_identifier, sdk_versions.get(selected_scheme))
                if runtime_capture else
                json.loads(command('xcrun', 'simctl', 'list', 'runtimes', '--json'))['runtimes'])
    result = {}
    for scheme, sdk in SDKS.items():
        item = {**xcode, 'architecture': architecture,
                'sdk_version': sdk_versions[scheme],
                'sdk_build': command('xcrun', '--sdk', sdk, '--show-sdk-build-version')}
        if scheme != 'SiloMac':
            prefix = 'com.apple.CoreSimulator.SimRuntime.' + ('iOS-' if scheme == 'Silo' else 'tvOS-')
            matching = [runtime for runtime in runtimes if runtime.get('isAvailable')
                        and runtime.get('version') == item['sdk_version']
                        and runtime.get('identifier', '').startswith(prefix)
                        and (not runtime_capture or scheme != selected_scheme
                             or runtime.get('identifier') == runtime_identifier)]
            # A missing runtime prevents release-proof reuse. The test job may
            # download its runtime and record complete metadata afterwards.
            item.update(runtime_version=matching[0]['version'] if matching else '',
                        runtime_build=matching[0].get('buildversion', '') if matching else '')
        result[scheme] = item
    return result


def device_toolchain(scheme):
    sdk = DEVICE_SDKS[scheme]
    result = {**parse_xcode(command('xcodebuild', '-version')),
              'architecture': command('uname', '-m'), 'sdk': sdk,
              'sdk_version': command('xcrun', '--sdk', sdk, '--show-sdk-version'),
              'sdk_build': command('xcrun', '--sdk', sdk, '--show-sdk-build-version')}
    if result['architecture'] not in ('arm64', 'x86_64') or not re.fullmatch(
            r'[0-9]+(?:\.[0-9]+)*', result['sdk_version']) or not re.fullmatch(
            r'[A-Za-z0-9]+', result['sdk_build']):
        raise ValueError('Device SDK or architecture metadata is unavailable')
    return result


def metadata(root, env, runtime_capture=None, *, device_scheme=None):
    namespace = validate_controls(env)
    sha = command('git', 'rev-parse', 'HEAD', cwd=root)
    fingerprint = command('git', 'rev-parse', 'HEAD^{tree}', cwd=root)
    dirty = bool(command('git', 'status', '--porcelain', '--untracked-files=no', cwd=root))
    lock = hashlib.sha256((root / LOCK).read_bytes()).hexdigest()
    project = hashlib.sha256((root / 'iosApp/project.yml').read_bytes()).hexdigest()
    if device_scheme:
        tools = {device_scheme: device_toolchain(device_scheme)}
        cache_inputs = {'profile': device_scheme, **tools[device_scheme]}
    else:
        tools = toolchains(runtime_capture, env.get('SCHEME', ''), env.get('SILO_TEST_RUNTIME_IDENTIFIER', ''))
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
            'cache_namespace': namespace, 'compilation_cache_profile': compilation_cache_profile(env),
            'source_dirty': str(dirty).lower(), 'project_yml_sha256': project,
            **spm_cache_scope(env, lock, project, key, source_sha=sha, source_dirty=dirty)}


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
    profile = compilation_cache_profile(env)
    spm_scope = spm_cache_scope(env, result['lock_sha256'], result.get('project_yml_sha256', ''),
                              result.get('toolchain_key', ''), source_sha=result['source_sha'],
                              source_dirty=result.get('source_dirty') != 'false')
    # The restore action reports the actual selected profile even on a cache miss.
    if env.get('SILO_SPM_CACHE_PROFILE_EFFECTIVE'):
        spm_scope['spm_cache_profile_effective'] = env['SILO_SPM_CACHE_PROFILE_EFFECTIVE']
        spm_scope['spm_cache_scope'] = env['SILO_SPM_CACHE_SCOPE']
        spm_scope['spm_cache_save_owner'] = (env['SILO_SPM_CACHE_SAVE_OWNER']
            if env['SILO_SPM_CACHE_PROFILE_EFFECTIVE'] == 'shared_qualified' else env['SILO_SPM_CACHE_SCOPE'])
    dirty = result.get('source_dirty', 'false') == 'true'
    workers = parallel_test_workers(env)
    return {'source_sha': result['source_sha'], 'variant': env.get('SILO_BENCH_VARIANT', 'optimized'),
            'cache_probe': 'none',
            'cache_regime': 'warm' if spm_hit or derived_restored else 'cold',
            'cache_namespace': result['cache_namespace'], 'platform': platform,
            'toolchain': tools[scheme], 'spm_cache_hit': spm_hit,
            'derived_cache_hit': derived_hit, 'derived_cache_restored': derived_restored,
            'derived_cache_key': derived_key,
            'compilation_cache_profile': profile,
            **spm_scope, 'project_yml_sha256': result.get('project_yml_sha256', ''),
            'source_dirty': dirty, 'timing_eligible': not dirty,
            'parallel_testing_enabled': workers == 2, 'parallel_testing_worker_count': workers,
            'test_destination': env.get('SILO_TEST_DESTINATION', ''),
            'test_runtime_identifier': env.get('SILO_TEST_RUNTIME_IDENTIFIER', ''),
            'compilation_cache_enabled': profile != 'standard',
            'compilation_cache_diagnostic_remarks': profile != 'standard',
            'derived_cache_kind': 'exact' if derived_hit else 'prefix' if derived_restored else 'miss',
            'xcodegen_cache_hit': xcodegen_hit,
            'dependency_lock_sha256': result['lock_sha256'],
            'build_config_sha256': result['build_config_sha256'], 'cache_mode': env.get('SILO_CACHE_MODE', 'dependencies')}


def proof(result, root, env, scheme):
    if env['GITHUB_EVENT_NAME'] != 'push' or env['GITHUB_REF_NAME'] != 'main':
        raise ValueError('Only main push regressions produce trusted release proof')
    if result['source_sha'] != env['GITHUB_SHA'] or env.get('SILO_FULL_SUITE') != 'true':
        raise ValueError('Release proof requires the workflow source and complete suite')
    if (result.get('source_dirty') != 'false'
            or command('git', 'status', '--porcelain', '--untracked-files=no', cwd=root)):
        raise ValueError('Release proof requires clean tracked source')
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
    parser.add_argument('--validate-controls', action='store_true')
    parser.add_argument('--outputs', action='store_true')
    profile = parser.add_mutually_exclusive_group()
    profile.add_argument('--benchmark', action='store_true')
    profile.add_argument('--proof', choices=SDKS)
    profile.add_argument('--device-scheme', choices=DEVICE_SDKS)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.validate_controls:
        validate_controls(os.environ)
        return
    # Reuse only the inventory that selected this job's mobile test runtime.
    # Initial inputs and macOS proof metadata retain live runtime discovery.
    runtime_capture = (Path(os.environ['SILO_PREPARED_SIMULATOR_RUNTIMES'])
                       if (args.benchmark or args.proof in ('Silo', 'SiloTV'))
                       and os.environ.get('SILO_PREPARED_SIMULATOR_RUNTIMES') else None)
    if runtime_capture and args.proof and args.proof != os.environ.get('SCHEME'):
        raise ValueError('Release proof scheme does not match the prepared simulator')
    result = metadata(args.root.resolve(), os.environ, runtime_capture, device_scheme=args.device_scheme)
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
