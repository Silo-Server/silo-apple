#!/usr/bin/env python3
"""Bounded observations for an owned manual benchmark controller only."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import threading
import time

CPU_KEYS = ('hw.model', 'hw.ncpu', 'hw.physicalcpu', 'hw.logicalcpu',
            'hw.memsize', 'machdep.cpu.brand_string')
RELEVANT = {'xcodebuild', 'xctest', 'Silo', 'SiloTests', 'SiloTests-Runner',
            'Simulator', 'SimulatorTrampoline', 'CoreSimulatorService',
            'com.apple.CoreSimulator.CoreSimulatorService', 'CoreSimulatorBridge',
            'testmanagerd', 'simulatord', 'launchd_sim'}


def validate(env):
    if (env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or env.get('GITHUB_REPOSITORY') != 'Silo-Server/silo-apple'
            or env.get('SILO_RELEASE_GATE', 'false') != 'false'
            or env.get('SILO_BENCHMARK_PLATFORM') != 'ios'
            or env.get('SILO_BENCH_VARIANT') not in ('baseline', 'optimized')
            or env.get('SILO_BASELINE_REF')
            or env.get('SILO_IOS_ONLY', 'false') != 'false'
            or env.get('SILO_RECORD_PREVIEW', 'false') != 'false'
            or env.get('SILO_CACHE_PROBE', 'none') != 'none'
            or not re.fullmatch(r'[0-9a-f]{40}', env.get('SILO_BENCHMARK_SOURCE_REF', ''))):
        raise ValueError('Resource observations require an isolated manual full-iOS benchmark')
    if any(key in env for key in ('PLATFORM', 'SCHEME', 'ACTION')):
        if (env.get('PLATFORM'), env.get('SCHEME'), env.get('ACTION')) != ('iOS', 'Silo', 'test'):
            raise ValueError('Resource observations require the iOS simulator test row')


def run(args, timeout=3):
    start = time.monotonic()
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        return {'exit_code': result.returncode, 'stdout': result.stdout,
                'stderr': result.stderr[:2000], 'elapsed_seconds': time.monotonic() - start}
    except (OSError, subprocess.TimeoutExpired) as error:
        # No command arguments or environment values are copied into errors.
        return {'exit_code': None, 'stdout': '', 'stderr': type(error).__name__,
                'elapsed_seconds': time.monotonic() - start}


def processes(text):
    rows = []
    for line in text.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4 or not all(value.isdecimal() for value in fields[:3]):
            raise ValueError('Unexpected process inventory format')
        pid, ppid, rss = map(int, fields[:3])
        name = Path(fields[3]).name
        rows.append((pid, ppid, rss, name))
    selected = {pid for pid, _, _, name in rows if name in RELEVANT}
    selected.add(os.getpid())
    for _ in range(len(rows)):
        descendants = {pid for pid, ppid, _, _ in rows if ppid in selected}
        if descendants <= selected:
            break
        selected |= descendants
    return [{'pid': pid, 'ppid': ppid, 'rss_kib': rss,
             'process': 'resource-observer' if pid == os.getpid() else name if name in RELEVANT else 'benchmark-descendant'}
            for pid, ppid, rss, name in rows if pid in selected]


def write(path, result):
    path.write_text(json.dumps(result, sort_keys=True) + '\n')


def snapshot(folder, phase):
    folder.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    result = {'phase': phase, 'cpu_memory_identity': {}, 'device_query': {}}
    if phase == 'before':
        result['cpu_memory_identity'] = {key: run(['/usr/sbin/sysctl', '-n', key]) for key in CPU_KEYS}
    result['device_query'] = run(['xcrun', 'simctl', 'list', 'devices', '--json'], timeout=15)
    write(folder / (phase + '.json'), {**result, 'elapsed_seconds': time.monotonic() - started})


def sample(folder, interval, maximum):
    folder.mkdir(parents=True, exist_ok=True)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    started = time.monotonic()
    samples = 0
    query_seconds = 0.0
    self_cpu_start = resource.getrusage(resource.RUSAGE_SELF)
    child_cpu_start = resource.getrusage(resource.RUSAGE_CHILDREN)
    error_count = 0
    with (folder / 'samples.jsonl').open('w') as output:
        while not stop.is_set() and time.monotonic() - started < maximum:
            tick = time.monotonic()
            observed = {'offset_seconds': tick - started}
            for name, args in (('rss', ['/bin/ps', '-axo', 'pid=,ppid=,rss=,comm=']),
                               ('vm_stat', ['/usr/bin/vm_stat']),
                               ('swap_usage', ['/usr/sbin/sysctl', '-n', 'vm.swapusage'])):
                result = run(args)
                if name == 'rss':
                    try:
                        result['processes'] = processes(result.pop('stdout')) if result['exit_code'] == 0 else []
                    except ValueError as error:
                        result['processes'] = []
                        result['stderr'] = str(error)
                        result['exit_code'] = None
                    # Never write the unfiltered process inventory, paths or arguments.
                    result.pop('stdout', None)
                observed[name] = result
                query_seconds += result['elapsed_seconds']
                error_count += result['exit_code'] != 0
            output.write(json.dumps(observed, sort_keys=True) + '\n')
            output.flush()
            samples += 1
            if samples == 1:
                write(folder / 'sampler-ready.json', {'pid': os.getpid(), 'first_sample_seconds': time.monotonic() - tick})
            stop.wait(max(0, interval - (time.monotonic() - tick)))
    self_cpu_end = resource.getrusage(resource.RUSAGE_SELF)
    child_cpu_end = resource.getrusage(resource.RUSAGE_CHILDREN)
    write(folder / 'sampler-summary.json', {'samples': samples, 'elapsed_seconds': time.monotonic() - started,
          'observer_cpu_seconds': self_cpu_end.ru_utime + self_cpu_end.ru_stime - self_cpu_start.ru_utime - self_cpu_start.ru_stime,
          'query_child_cpu_seconds': child_cpu_end.ru_utime + child_cpu_end.ru_stime - child_cpu_start.ru_utime - child_cpu_start.ru_stime,
          'query_elapsed_seconds': query_seconds, 'query_errors': error_count,
          'interval_seconds': interval, 'maximum_seconds': maximum,
          'stopped_by_signal': stop.is_set(), 'maximum_reached': not stop.is_set(),
          'limitations': 'RSS can count shared memory more than once and misses short-lived processes; query elapsed time includes scheduling, not just CPU use. Process roles contain no command arguments or paths. Host counters include other host activity.'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('validate-controls', 'before', 'after', 'sample', 'terminal'))
    parser.add_argument('--folder', type=Path, default=Path('/tmp/apple-resource-observations'))
    parser.add_argument('--interval', type=float, default=2.0)
    parser.add_argument('--maximum', type=float, default=720.0)
    parser.add_argument('--xcodebuild-exit', type=int)
    parser.add_argument('--tee-exit', type=int)
    parser.add_argument('--sampler-exit', type=int)
    args = parser.parse_args()
    validate(os.environ)
    if args.action == 'validate-controls':
        return
    if args.action in ('before', 'after'):
        snapshot(args.folder, args.action)
    elif args.action == 'sample':
        if not 0.25 <= args.interval <= 10 or not 1 <= args.maximum <= 720:
            parser.error('Sampler interval or maximum is outside the bounded range')
        sample(args.folder, args.interval, args.maximum)
    else:
        args.folder.mkdir(parents=True, exist_ok=True)
        write(args.folder / 'terminal.json', {'xcodebuild_exit': args.xcodebuild_exit,
              'tee_exit': args.tee_exit, 'sampler_exit': args.sampler_exit})


if __name__ == '__main__':
    main()
