#!/usr/bin/env python3
"""Validate and record controls for the private current-source experiments."""
import argparse
import json
import os
from pathlib import Path
import re


PRIVATE_REF = 'refs/heads/private/apple-shared-spm-controller'
NAMESPACE = 'apple-phase1-20261007'


def controls(env):
    if (env.get('GITHUB_REPOSITORY'), env.get('GITHUB_EVENT_NAME'), env.get('GITHUB_REF')) != (
            'Silo-Server/silo-apple', 'workflow_dispatch', PRIVATE_REF):
        raise ValueError('Private controller requires its approved repository, event and branch')
    source = env.get('SILO_BENCHMARK_SOURCE_REF', '')
    if not re.fullmatch(r'[0-9a-f]{40}', source) or set(source) == {'0'}:
        raise ValueError('An explicit nonzero immutable app commit is required')
    result = {'source_sha': source, 'controller_sha': env.get('GITHUB_SHA', ''),
              'run_id': env.get('GITHUB_RUN_ID', ''), 'run_attempt': env.get('GITHUB_RUN_ATTEMPT', ''),
              'workflow_job': env.get('GITHUB_JOB', ''),
              'variant': env.get('SILO_BENCH_VARIANT', ''),
              'cache_mode': env.get('SILO_CACHE_MODE', ''),
              'cache_namespace': env.get('SILO_CACHE_NAMESPACE', ''),
              'spm_cache_profile': env.get('SILO_SPM_CACHE_PROFILE', ''),
              'platform': env.get('SILO_BENCHMARK_PLATFORM', ''),
              'cache_save_policy': env.get('SILO_CACHE_SAVE_POLICY', 'read_only'),
              'cache_probe': env.get('SILO_CACHE_PROBE', 'none')}
    for key, name in (('SILO_COMPILATION_CACHE_ENABLED', 'compilation_cache'),
                      ('SILO_UNFLAGGED_DEPENDENCY_CONTROL', 'unflagged_dependency_control'),
                      ('SILO_IOS_PARALLEL_PILOT', 'ios_parallel_pilot'),
                      ('SILO_RESOURCE_OBSERVATIONS', 'resource_observations'),
                      ('SILO_IOS_ONLY', 'ios_only'),
                      ('SILO_RECORD_PREVIEW', 'record_preview'),
                      ('SILO_EXPORT_SIMULATOR_TESTS', 'export_simulator_tests')):
        value = env.get(key, 'false')
        if value not in ('true', 'false'):
            raise ValueError('Private boolean controls must be true or false')
        result[name] = value == 'true'
    if (env.get('SILO_BASELINE_REF', '') or env.get('SILO_RELEASE_GATE', 'false') != 'false'
            or result['ios_only'] or result['record_preview'] or result['export_simulator_tests']):
        raise ValueError('Current-source timing requires complete requested suites without preview or export')
    if (result['variant'] not in ('baseline', 'optimized')
            or result['cache_mode'] not in ('off', 'dependencies', 'derived_data')
            or result['spm_cache_profile'] not in ('scheme', 'shared_qualified')
            or result['platform'] not in ('all', 'ios', 'tvos', 'macos')
            or result['cache_save_policy'] not in ('read_only', 'compiler_bootstrap')
            or result['cache_namespace'] != NAMESPACE or result['cache_probe'] != 'none'):
        raise ValueError('Unknown or ineligible private benchmark controls')
    if result['variant'] == 'baseline' and (
            result['cache_mode'] != 'off' or result['compilation_cache']
            or result['spm_cache_profile'] != 'scheme'):
        raise ValueError('The original sequence requires the explicit off profile')
    if result['compilation_cache'] and (
            result['variant'] != 'optimized' or result['cache_mode'] != 'derived_data'
            or result['platform'] != 'ios'):
        raise ValueError('The controlled compilation cache profile requires optimized derived_data iOS')
    if result['unflagged_dependency_control'] and (
            result['variant'] != 'optimized' or result['cache_mode'] != 'dependencies'
            or result['compilation_cache'] or result['platform'] != 'ios'
            or result['cache_save_policy'] != 'read_only'
            or result['spm_cache_profile'] != 'shared_qualified' or result['ios_parallel_pilot']):
        raise ValueError('The unflagged control requires optimized shared read-only dependency-only serial iOS')
    if result['resource_observations'] and result['platform'] != 'ios':
        raise ValueError('Resource observations require only the iOS suite')
    if result['ios_parallel_pilot'] and (
            result['variant'] != 'optimized' or result['platform'] != 'ios'):
        raise ValueError('The worker pilot requires the optimized iOS suite')
    if result['cache_save_policy'] == 'compiler_bootstrap' and (
            not result['compilation_cache'] or result['spm_cache_profile'] != 'shared_qualified'
            or result['ios_parallel_pilot']):
        raise ValueError('Compiler bootstrap requires the complete shared serial compiler profile')
    row = tuple(env.get(key, '') for key in ('PLATFORM', 'SCHEME', 'ACTION'))
    if any(row):
        result['selected_row'] = dict(zip(('platform', 'scheme', 'action'), row))
        if (result['compilation_cache'] or result['resource_observations']
                or result['ios_parallel_pilot'] or result['unflagged_dependency_control']) and row != ('iOS', 'Silo', 'test'):
            raise ValueError('The iOS experiment requires the actual complete iOS test row')
    result['measurement_requested'] = result['cache_save_policy'] == 'read_only'
    result['cache_profile_control'] = ('unflagged-defaults' if result['unflagged_dependency_control']
                                      else 'explicit-YES' if result['compilation_cache'] else 'explicit-NO')
    result['requested_caching'] = ('unknown' if result['unflagged_dependency_control']
                                   else 'YES' if result['compilation_cache'] else 'NO')
    result['requested_diagnostics'] = result['requested_caching']
    result['compilation_cache_marker_is_effective_state'] = False
    return result


def derived_state(env, phase):
    control = controls(env)
    path = Path(env['SILO_DERIVED_DATA'])
    present = path.exists() or path.is_symlink()
    result = {'phase': phase, 'path': str(path), 'present': present,
              'cache_mode': control['cache_mode'], 'cache_save_policy': control['cache_save_policy']}
    if phase == 'pre_restore' and present:
        raise ValueError('The experiment requires a fresh explicit DerivedData path before restore')
    if phase == 'pre_build':
        if control['cache_mode'] in ('off', 'dependencies') and present:
            raise ValueError('The control requires fresh DerivedData immediately before building')
        if control['spm_cache_profile'] == 'shared_qualified' and control['cache_mode'] != 'off':
            if (env.get('SILO_SPM_CACHE_PROFILE_EFFECTIVE') != 'shared_qualified'
                    or env.get('SILO_SPM_CACHE_HIT') != 'true'):
                raise ValueError('The measured shared package archive requires an exact qualified hit')
        if control['cache_mode'] == 'derived_data' and control['cache_save_policy'] == 'read_only':
            if env.get('SILO_DERIVED_CACHE_HIT') != 'true' or not present:
                raise ValueError('The warm treatment requires an exact current-source archive')
    return result


def resolved_settings(env, raw):
    control = controls(env)
    expected = 'YES' if control['compilation_cache'] else 'NO'
    if not isinstance(raw, list) or not raw:
        raise ValueError('Resolved build settings must contain target records')
    records = []
    for item in raw:
        if not isinstance(item, dict):
            raise ValueError('Resolved build settings must contain target objects')
        settings = item.get('buildSettings', {})
        if not isinstance(settings, dict):
            raise ValueError('Resolved build settings must contain settings objects')
        target = item.get('target', '')
        if not isinstance(target, str) or not target:
            raise ValueError('Resolved build settings must identify each target')
        caching = settings.get('COMPILATION_CACHE_ENABLE_CACHING')
        diagnostics = settings.get('COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS')
        records.append({'target': target, 'caching': caching, 'diagnostics': diagnostics,
                        'caching_present': 'COMPILATION_CACHE_ENABLE_CACHING' in settings,
                        'diagnostics_present': 'COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS' in settings})
        if not control['unflagged_dependency_control'] and (caching != expected or diagnostics != expected):
            raise ValueError('Resolved compilation cache settings contradict the declared profile')
    required = {env.get('SCHEME', '')}
    if env.get('ACTION') == 'test':
        required.add(env.get('TEST_TARGET', ''))
    if '' in required or not required.issubset({item['target'] for item in records}):
        raise ValueError('Resolved build settings omit a required application or test target')
    effective = {}
    for name in ('caching', 'diagnostics'):
        values = [item[name] for item in records]
        effective['effective_' + name] = values[0] if values[0] in ('YES', 'NO') and all(
            value == values[0] for value in values) else 'unknown'
    return {'source_sha': control['source_sha'], 'controller_sha': control['controller_sha'],
            'run_id': control['run_id'], 'run_attempt': control['run_attempt'],
            'workflow_job': control['workflow_job'], 'scheme': env['SCHEME'],
            'query_action': 'build-for-testing' if env.get('ACTION') == 'test' else 'build',
            'cache_profile_control': control['cache_profile_control'], 'targets': records,
            'requested_caching': control['requested_caching'],
            'requested_diagnostics': control['requested_diagnostics'], **effective,
            'compilation_cache_marker_is_effective_state': False,
            'actual_swift_driver_qualification_required': True,
            'unflagged_shipping_default_equivalence_proven': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=('controls', 'pre_restore', 'pre_build', 'settings'))
    parser.add_argument('--folder', type=Path)
    parser.add_argument('--input', type=Path)
    args = parser.parse_args()
    try:
        if args.operation == 'controls':
            result = controls(os.environ)
        elif args.operation == 'settings':
            if args.input is None:
                raise ValueError('Resolved build settings input is required')
            result = resolved_settings(os.environ, json.loads(args.input.read_text()))
        else:
            result = derived_state(os.environ, args.operation)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(2, f'::error::{error}\n')
    if args.folder:
        args.folder.mkdir(parents=True, exist_ok=True)
        (args.folder / f'{args.operation}.json').write_text(json.dumps(result, sort_keys=True) + '\n')
    print('SILO_PRIVATE_CONTROLLER_' + args.operation.upper() + '=' + json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
