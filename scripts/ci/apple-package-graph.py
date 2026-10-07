#!/usr/bin/env python3
"""Attest a complete, already restored SwiftPM graph without resolving or repairing it.

Only the observed source-control/local-XCFramework workspace representation is
supported. An unknown representation fails before Xcode can repair the cache.
Git is used only for bounded, offline plumbing reads; checkout bytes are compared
with committed blob identities without trusting the index or Git status.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


LOCK = Path('iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
MAX_FILES = 50_000
MAX_BYTES = 4 * 1024 ** 3
MAX_SECONDS = 120
MAX_DOCUMENT = 8 * 1024 ** 2
MAX_GIT_OUTPUT = 64 * 1024 ** 2
IDENTITY = re.compile(r'[a-z0-9][a-z0-9._-]{0,127}')
NAME = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.+-]{0,127}')
REVISION = re.compile(r'[0-9a-f]{40}')

# This diagnostic is intentionally restricted to the reviewed dd254 package
# graph. Swift manifests are executable and Target properties are mutable;
# inferring all possible binary declarations with a text parser is unsound.
# Every root Package*.swift manifest is covered, including source-only packages.
# Updating a dependency requires reviewing its manifests and this profile.
SUPPORTED_GRAPH = {
    'aetherengine': {
        'revision': 'b1e4879e6a41477ebef3b68e8d9f65239d1ba80b',
        'manifests': {'Package.swift': '72b666c842f7117ec649c4d1dd1b310cf6f2a819a0e59b4ad5cd97a3e913f6b1'},
        'binaries': {},
    },
    'combine-schedulers': {
        'revision': '114354e8c1667a2edc4993700fb9fa4f90157b56',
        'manifests': {
            'Package.swift': '0a3b5eb496c130d9324236f7025b856719900c8a873eed2e4614bbb34ae1fa4a',
            'Package@swift-6.0.swift': '96555b060d69c415581da3d78966212783b2f656ebbfe57f42bc69d2986affbd',
            'Package@swift-6.1.swift': '641b0073d154806f102460f39be97028e83d3ec16ef6c6e8d6ceba782d88a400',
        },
        'binaries': {},
    },
    'ffmpegbuild': {
        'revision': '9ee46ba4fb533e35efa6492eb1a903ca4f8058fc',
        'manifests': {'Package.swift': 'eb9a8ebe9c28c9efdc4bd8495d9b2d52eff2647632f06fac414fd3d989543a30'},
        'binaries': {name: 'Sources/' + name + '.xcframework' for name in (
            'AetherLibavcodec', 'AetherLibavformat', 'AetherLibavutil', 'AetherLibswresample',
            'AetherLibswscale', 'AetherLibdav1d', 'AetherLibavfilter', 'AetherLibzimg', 'AetherLibzvbi')},
    },
    'libdovi': {
        'revision': '0d7cce1d6836a30d13a3a2326e50a153af53f014',
        'manifests': {'Package.swift': '91c9dd0b80297cc9e351a7d319bcbe3851de13d6fbc1769d68ca61ad12f15b38'},
        'binaries': {'Dovi': 'Dovi.xcframework'},
    },
    'nuke': {
        'revision': '30f7a7e72e0607d304fbf69c799474bd5fb6d1ce',
        'manifests': {'Package.swift': '533a4ea078e279d869d0dbf1e431d5aff1b08ce2615a77db01f35606a0120e29'},
        'binaries': {},
    },
    'siloobjectaudio': {
        'revision': '645b91c072fafb60146151fd5127f8ff0ca38b6f',
        'manifests': {'Package.swift': '07cb5ce130daddfdff6ad7b8db36de1da0c82499a306cfbeff08d2cd5875fbf9'},
        'binaries': {'SiloObjectAudio': 'SiloObjectAudio.xcframework'},
    },
    'smbclient': {
        'revision': 'e636c2b2458930770932a36d311ec9d478575b90',
        'manifests': {
            'Package.swift': '2ee48bf776b58cd36e9ebcbcd1d5afc3ccb3af19092e5e76112cb3c9fbb115fe',
            'Package@swift-5.5.swift': '87bb36c6fd03efc32f033802f9d1b30fc83fcee2268c6f575e870aa5fe52afda',
        },
        'binaries': {},
    },
    'swift-ass-renderer': {
        'revision': '28919f6b5ddd896d327b0283f8d97624902236e6',
        'manifests': {
            'Package.swift': '4148d637a1d2d02449be2d61706b439cb2ce993904d649a1a8ad1103e1c32445',
            'Package@swift-5.10.swift': '3c57a8a3b8688146c7abc00f2bca42ccdb6c2b8a08b449c2944670b66add3624',
            'Package@swift-6.0.swift': 'e110c883d0e4075b722f9ec0c144350d4f0519932c34d90f040f9b01b6d4f133',
        },
        'binaries': {},
    },
    'swift-concurrency-extras': {
        'revision': '5fa253428866f2360c3754e88537f700ed2656b5',
        'manifests': {'Package.swift': '95b005bbfe9e08a56a32354cc00e545e1f5167e6bb5a1c70ecd057ab8aab824d'},
        'binaries': {},
    },
    'swift-issue-reporting': {
        'revision': '71c7c9a761d1ca6ed4ccb6ced040fe1c1a39e8e7',
        'manifests': {'Package.swift': 'e2d0871f5eabbe680b88479a6a1342329c2c956eef064f81ec1ffde9de8cbd4e'},
        'binaries': {},
    },
    'swift-libass': {
        'revision': '6513c488e377a26c06db327fb2acfc2653a041d5',
        'manifests': {
            'Package.swift': 'f8f2e3d38f5d63bce418577f7c8384b467e2823de430166940e40b925e976f7a',
            'Package@swift-5.10.swift': '168574d96dae9809c94341ad927d0cea625c79a38629a9a0d35a4c45d20f95c8',
        },
        'binaries': {name: 'Libraries/XCFrameworks/' + name + '.xcframework' for name in (
            'fontconfig', 'freetype', 'harfbuzz', 'fribidi', 'libpng', 'libass')},
    },
}


class InventoryError(Exception):
    """All messages are fixed text: inputs, Git errors and machine paths stay private."""


def require(condition, message):
    if not condition:
        raise InventoryError(message)


class Budget:
    def __init__(self):
        self.deadline = time.monotonic() + MAX_SECONDS
        self.files = 0
        self.bytes = 0
        self.entries = 0

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, 'Inventory time limit exceeded')
        return remaining

    def entry(self):
        self.remaining()
        self.entries += 1
        require(self.entries <= MAX_FILES * 2, 'Inventory path limit exceeded')

    def file(self, size):
        self.remaining()
        self.files += 1
        require(self.files <= MAX_FILES, 'Inventory file limit exceeded')
        require(0 <= size <= MAX_BYTES - self.bytes, 'Inventory byte limit exceeded')

    def consume(self, size):
        self.remaining()
        self.bytes += size
        require(self.bytes <= MAX_BYTES, 'Inventory byte limit exceeded')


def relative(value):
    require(isinstance(value, str) and 0 < len(value) <= 2048,
            'Unsupported relative path')
    require(not any(ord(char) < 32 for char in value) and '\\' not in value,
            'Unsafe relative path')
    parts = value.split('/')
    require(all(part not in ('', '.', '..', '.git') for part in parts),
            'Unsafe relative path')
    require(not PurePosixPath(value).is_absolute() and ':' not in value,
            'Unsafe relative path')
    return value


def absolute(value):
    require(isinstance(value, str) and value.startswith('/') and len(value) <= 4096,
            'Unsupported workspace path bookkeeping')
    require(not any(ord(char) < 32 for char in value) and '\\' not in value,
            'Unsafe workspace path bookkeeping')
    require(all(part not in ('', '.', '..') for part in value.split('/')[1:]),
            'Unsafe workspace path bookkeeping')
    return value


def safe_path(base, rel, final_symlink=False):
    rel = relative(rel)
    path = base
    parts = rel.split('/')
    for index, part in enumerate(parts):
        path = path / part
        require(not path.is_symlink() or (final_symlink and index == len(parts) - 1),
                'Unsafe symlink in inventory path')
    return path


def normalized_input(path):
    path = Path(os.path.abspath(path))
    # macOS exposes these OS-owned aliases. Other symlink components still fail.
    for alias in ('tmp', 'var'):
        prefix = Path('/') / alias
        if path == prefix or prefix in path.parents:
            if prefix.is_symlink() and prefix.resolve() == Path('/private') / alias:
                path = Path('/private') / alias / path.relative_to(prefix)
    return path


def input_directory(path):
    path = normalized_input(path)
    for component in (path, *path.parents):
        require(not component.is_symlink(), 'Unsafe symlink in input directory')
    require(path.is_dir(), 'Required input directory is missing')
    return path


def shape(value, required, optional=()):
    require(isinstance(value, dict) and set(required) <= value.keys()
            and value.keys() <= set(required) | set(optional), 'Unsupported document schema')


def depth(value, level=0):
    require(level <= 32, 'Document nesting limit exceeded')
    if isinstance(value, dict):
        for item in value.values():
            depth(item, level + 1)
    elif isinstance(value, list):
        for item in value:
            depth(item, level + 1)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate document key')
        result[key] = value
    return result


class UniqueDictionary(dict):
    def __init__(self, pairs=()):
        super().__init__()
        for key, value in pairs:
            self[key] = value

    def __setitem__(self, key, value):
        require(key not in self, 'Duplicate document key')
        super().__setitem__(key, value)


def json_bytes(data):
    require(len(data) <= MAX_DOCUMENT, 'Document size limit exceeded')
    try:
        result = json.loads(data, object_pairs_hook=unique_pairs,
                            parse_constant=lambda value: (_ for _ in ()).throw(
                                InventoryError('Unsupported JSON value')))
    except (ValueError, UnicodeError, RecursionError):
        raise InventoryError('Malformed JSON document') from None
    depth(result)
    return result


def document(path):
    path = normalized_input(path)
    for component in (path, *path.parents):
        require(not component.is_symlink(), 'Unsafe document path')
    return json_bytes(bounded_bytes(path))


def bounded_bytes(path):
    require(not path.is_symlink() and path.is_file(), 'Required document is missing')
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    with os.fdopen(os.open(path, flags), 'rb') as handle:
        metadata = os.fstat(handle.fileno())
        require(stat.S_ISREG(metadata.st_mode), 'Unsupported document file type')
        require(metadata.st_size <= MAX_DOCUMENT, 'Document size limit exceeded')
        data = handle.read(MAX_DOCUMENT + 1)
    require(len(data) <= MAX_DOCUMENT, 'Document size limit exceeded')
    return data


def verified_bytes(path, record):
    content = bounded_bytes(path)
    require(hashlib.sha256(content).hexdigest() == record['sha256'],
            'Checkout metadata changed during inventory')
    return content


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def git(root, budget, *arguments, max_output=MAX_GIT_OUTPUT, allow_missing=False):
    # Inherited Git routing/config and lazy-fetch settings cannot change the
    # selected repository or contact a remote. stderr is never retained/emitted.
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
               GIT_NO_REPLACE_OBJECTS='1', GIT_NO_LAZY_FETCH='1',
               GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0',
               GIT_CEILING_DIRECTORIES=str(root.parent))
    command = ['git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
               '-c', 'protocol.allow=never', '-C', str(root), *arguments]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    output = bytearray()
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = min(budget.deadline, time.monotonic() + 30)
        while selector.get_map():
            remaining = min(budget.remaining(), deadline - time.monotonic())
            require(remaining > 0, 'Git inventory command timed out')
            ready = selector.select(remaining)
            require(ready, 'Git inventory command timed out')
            block = os.read(process.stdout.fileno(), 65536)
            if not block:
                selector.unregister(process.stdout)
            else:
                output.extend(block)
                require(len(output) <= max_output, 'Git inventory output limit exceeded')
        status = process.wait(timeout=min(budget.remaining(), max(0.01, deadline - time.monotonic())))
        require(status == 0 or (allow_missing and status == 1 and not output),
                'Git inventory command failed')
    except (subprocess.TimeoutExpired, OSError):
        raise InventoryError('Git inventory command failed') from None
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
    return bytes(output)


def repository(root, budget, checkout=False):
    if checkout:
        require((root / '.git').is_dir() and not (root / '.git').is_symlink(),
                'Unsupported checkout Git metadata')
    top = git(root, budget, 'rev-parse', '--show-toplevel', max_output=8192).decode().strip()
    require(top == str(root), 'Checkout is not an independent Git repository')
    require(git(root, budget, 'rev-parse', '--show-object-format', max_output=32).strip() == b'sha1',
            'Unsupported Git object format')
    require(not git(root, budget, 'config', '--local', '--get-regexp',
                    r'^(extensions\.partialclone|remote\..*\.promisor)$',
                    max_output=8192, allow_missing=True), 'Unsupported partial Git checkout')


def pins(root, budget):
    repository(root, budget)
    lock_path = safe_path(root, LOCK.as_posix())
    require(lock_path.is_file(), 'Committed dependency lock is missing')
    lock_bytes = git(root, budget, 'show', 'HEAD:' + LOCK.as_posix(), max_output=MAX_DOCUMENT)
    require(bounded_bytes(lock_path) == lock_bytes,
            'Dependency lock differs from committed source')
    lock = json_bytes(lock_bytes)
    shape(lock, ('version', 'pins'), ('originHash',))
    require(type(lock['version']) is int and lock['version'] == 3,
            'Unsupported dependency lock schema')
    require(isinstance(lock['pins'], list) and 0 < len(lock['pins']) <= 128,
            'Unsupported dependency pin inventory')
    result = {}
    locations = set()
    for pin in lock['pins']:
        shape(pin, ('identity', 'kind', 'location', 'state'))
        identity = pin['identity']
        require(isinstance(identity, str) and IDENTITY.fullmatch(identity), 'Unsupported package identity')
        require(identity not in result, 'Duplicate package identity')
        require(pin['kind'] == 'remoteSourceControl', 'Unsupported dependency pin representation')
        location = pin['location']
        require(isinstance(location, str) and not any(ord(char) < 32 for char in location),
                'Unsupported dependency location')
        parsed = urlsplit(location)
        require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                and not parsed.password and not parsed.query and not parsed.fragment,
                'Unsupported dependency location')
        require(location not in locations, 'Duplicate dependency location')
        locations.add(location)
        shape(pin['state'], ('revision',), ('version', 'branch'))
        require(isinstance(pin['state']['revision'], str) and REVISION.fullmatch(pin['state']['revision']),
                'Unsupported dependency revision')
        require(not (pin['state'].get('version') and pin['state'].get('branch')),
                'Unsupported dependency pin state')
        for field in ('version', 'branch'):
            require(field not in pin['state'] or isinstance(pin['state'][field], str)
                    and 0 < len(pin['state'][field]) <= 128, 'Unsupported dependency pin state')
        result[identity] = pin
    return result, hashlib.sha256(lock_bytes).hexdigest()


def package_ref(value, locked):
    shape(value, ('identity', 'kind', 'location', 'name'))
    require(isinstance(value['identity'], str) and value['identity'] in locked,
            'Workspace contains an unpinned package')
    pin = locked[value['identity']]
    require(value['kind'] == pin['kind'] and value['location'] == pin['location'],
            'Workspace package reference differs from the lock')
    require(isinstance(value['name'], str) and NAME.fullmatch(value['name']),
            'Unsupported workspace package name')
    expected_name = urlsplit(pin['location']).path.rstrip('/').rsplit('/', 1)[-1]
    if expected_name.endswith('.git'):
        expected_name = expected_name[:-4]
    require(value['name'] == expected_name, 'Workspace package name differs from its pinned reference')
    return value['identity']


def workspace(packages, locked):
    state = document(safe_path(packages, 'workspace-state.json'))
    shape(state, ('version', 'object'))
    require(type(state['version']) is int and state['version'] == 7,
            'Unsupported workspace-state schema')
    shape(state['object'], ('dependencies', 'artifacts', 'prebuilts'))
    require(state['object']['prebuilts'] == [], 'Unsupported prebuilt dependency representation')
    dependencies, artifacts = state['object']['dependencies'], state['object']['artifacts']
    require(isinstance(dependencies, list) and len(dependencies) == len(locked),
            'Workspace dependency inventory is incomplete')
    require(isinstance(artifacts, list) and len(artifacts) <= 512,
            'Unsupported binary artifact inventory')
    result = {}
    subpaths = set()
    for dependency in dependencies:
        shape(dependency, ('packageRef', 'state', 'subpath', 'basedOn'))
        require(dependency['basedOn'] is None, 'Unsupported edited dependency')
        identity = package_ref(dependency['packageRef'], locked)
        require(identity not in result, 'Duplicate workspace package identity')
        shape(dependency['state'], ('name', 'checkoutState'))
        require(dependency['state']['name'] == 'sourceControlCheckout',
                'Unsupported workspace dependency representation')
        checkout_state = dependency['state']['checkoutState']
        shape(checkout_state, ('revision',), ('version', 'branch'))
        require(checkout_state == locked[identity]['state'], 'Workspace dependency state differs from the lock')
        subpath = relative(dependency['subpath'])
        require('/' not in subpath and subpath not in subpaths,
                'Unsupported or duplicate checkout subpath')
        require(dependency['packageRef']['name'] == subpath, 'Workspace package name differs from its checkout')
        subpaths.add(subpath)
        result[identity] = subpath
    require(set(result) == set(locked), 'Workspace dependency inventory is incomplete')
    return result, artifacts, state


def resolved_tracked_path(path, checkout, tracked, budget):
    """Resolve each actual symlink hop without normalizing traversal away."""
    pending = list(path.relative_to(checkout).parts)
    current, hops = [], 0
    while pending:
        budget.remaining()
        component = pending.pop(0)
        if component in ('', '.'):
            continue
        if component == '..':
            require(current, 'Unsafe or incomplete tracked symlink')
            current.pop()
            continue
        require(component != '.git' and '\\' not in component
                and not any(ord(char) < 32 for char in component), 'Unsafe tracked symlink traversal')
        candidate = checkout.joinpath(*current, component)
        metadata = candidate.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            rel = '/'.join([*current, component])
            require(rel in tracked, 'Tracked symlink traverses an uninventoried link')
            target = os.readlink(candidate)
            require(not os.path.isabs(target) and '\\' not in target
                    and '.git' not in target.split('/')
                    and not any(ord(char) < 32 for char in target), 'Unsafe tracked symlink traversal')
            hops += 1
            require(hops <= 64, 'Tracked symlink traversal limit exceeded')
            pending = target.split('/') + pending
        else:
            require(stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode),
                    'Unsupported tracked symlink target type')
            require(not pending or stat.S_ISDIR(metadata.st_mode), 'Incomplete tracked symlink path')
            current.append(component)
    require(current, 'Tracked symlink target is outside the committed content inventory')
    destination = checkout.joinpath(*current)
    rel = relative('/'.join(current))
    require(rel in tracked if destination.is_file()
            else destination.is_dir() and any(item.startswith(rel + '/') for item in tracked),
            'Tracked symlink target is outside the committed content inventory')
    return destination


def file_record(path, mode, expected_blob, budget, checkout, tracked):
    before = path.lstat()
    is_link = stat.S_ISLNK(before.st_mode)
    require(is_link if mode == '120000' else stat.S_ISREG(before.st_mode),
            'Tracked checkout file type differs from the commit')
    if is_link:
        target = os.readlink(path)
        require(not os.path.isabs(target) and not any(ord(char) < 32 for char in target),
                'Unsafe tracked symlink')
        try:
            resolved_tracked_path(path, checkout, tracked, budget)
        except (OSError, ValueError, RuntimeError):
            raise InventoryError('Unsafe or incomplete tracked symlink') from None
        content = os.fsencode(target)
        budget.file(len(content))
        budget.consume(len(content))
        sha = hashlib.sha256(content).hexdigest()
        blob = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
        size = len(content)
    else:
        require(bool(before.st_mode & stat.S_IXUSR) == (mode == '100755'),
                'Tracked checkout file mode differs from the commit')
        budget.file(before.st_size)
        sha256 = hashlib.sha256()
        sha1 = hashlib.sha1(b'blob ' + str(before.st_size).encode() + b'\0')
        size = 0
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        with os.fdopen(os.open(path, flags), 'rb') as handle:
            require(stat.S_ISREG(os.fstat(handle.fileno()).st_mode), 'Unsupported inventory file type')
            while True:
                block = handle.read(1024 ** 2)
                if not block:
                    break
                budget.consume(len(block))
                size += len(block)
                sha256.update(block)
                sha1.update(block)
        sha, blob = sha256.hexdigest(), sha1.hexdigest()
    after = path.lstat()
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode)
            and size == before.st_size, 'Checkout changed during inventory')
    require(blob == expected_blob, 'Tracked checkout content differs from the commit')
    return {'path': path.relative_to(checkout).as_posix(), 'mode': mode,
            'bytes': size, 'sha256': sha}


def checkout_inventory(packages, subpath, revision, budget):
    checkout = safe_path(packages, 'checkouts/' + subpath)
    require(checkout.is_dir(), 'Restored checkout is missing')
    repository(checkout, budget, checkout=True)
    require(git(checkout, budget, 'rev-parse', 'HEAD', max_output=128).strip().decode() == revision,
            'Checkout HEAD differs from the locked revision')
    tree = git(checkout, budget, 'ls-tree', '-r', '-z', '--full-tree', 'HEAD')
    tracked = {}
    for item in tree.split(b'\0'):
        if not item:
            continue
        budget.entry()
        try:
            metadata, raw_path = item.split(b'\t', 1)
            mode, kind, blob = metadata.decode('ascii').split(' ')
            path = relative(raw_path.decode('utf-8'))
        except (ValueError, UnicodeError):
            raise InventoryError('Unsupported tracked Git tree entry') from None
        require(mode in ('100644', '100755', '120000') and kind == 'blob'
                and REVISION.fullmatch(blob) and path not in tracked, 'Unsupported tracked Git tree entry')
        tracked[path] = (mode, blob)
    require(tracked and 'Package.swift' in tracked, 'Checkout package manifest is missing')
    actual = set()
    pending = [checkout]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                budget.entry()
                if directory == checkout and entry.name == '.git':
                    continue
                path = Path(entry.path)
                rel = relative(path.relative_to(checkout).as_posix())
                if entry.is_dir(follow_symlinks=False):
                    pending.append(path)
                else:
                    require(rel in tracked, 'Checkout contains untracked or ignored content')
                    actual.add(rel)
    require(actual == set(tracked), 'Tracked checkout inventory is incomplete')
    records = {}
    for rel in sorted(tracked):
        mode, blob = tracked[rel]
        records[rel] = file_record(safe_path(checkout, rel, final_symlink=True), mode, blob, budget, checkout, tracked)
        if Path(rel).name == '.gitattributes':
            content = verified_bytes(safe_path(checkout, rel), records[rel]).decode('utf-8')
            require(not re.search(r'(?:^|\s)(?:filter|working-tree-encoding)(?:=|\s|$)', content),
                    'Unsupported checkout content filter')
    return checkout, records


def tree_summary(records):
    require(records, 'Binary library content is missing')
    ordered = [records[key] for key in sorted(records)]
    return {'tree_sha256': digest(ordered), 'files': len(ordered),
            'bytes': sum(record['bytes'] for record in ordered)}


def declared_artifacts(identity, checkout, records):
    profile = SUPPORTED_GRAPH[identity]
    manifests = {path: record['sha256'] for path, record in records.items()
                 if '/' not in path and path.startswith('Package') and path.endswith('.swift')}
    require(manifests == profile['manifests'], 'Unsupported package manifest profile')
    for manifest in manifests:
        verified_bytes(safe_path(checkout, manifest), records[manifest])
    return profile['binaries']


def local_artifacts(artifacts, locked, dependencies, checkouts):
    result = {}
    prefixes = set()
    for artifact in artifacts:
        shape(artifact, ('packageRef', 'targetName', 'source', 'path', 'kind'))
        identity = package_ref(artifact['packageRef'], locked)
        require(artifact['packageRef']['name'] == dependencies[identity],
                'Workspace binary package name differs from its checkout')
        target = artifact['targetName']
        require(isinstance(target, str) and NAME.fullmatch(target), 'Unsupported binary target name')
        require(artifact['source'] == {'type': 'local'}, 'Unsupported remote or archived binary artifact')
        require(artifact['kind'] == {'xcframework': {}}, 'Unsupported binary artifact representation')
        path = absolute(artifact['path'])
        suffix = '/checkouts/' + dependencies[identity] + '/'
        require(path.count('/checkouts/') == 1 and path.count(suffix) == 1,
                'Binary artifact path does not identify its pinned checkout')
        prefix, rel = path.split(suffix)
        absolute(prefix)
        prefixes.add(prefix)
        rel = relative(rel)
        require(rel.endswith('.xcframework'), 'Unsupported local binary artifact path')
        key = (identity, target)
        require(key not in result and (identity, rel) not in result.values(), 'Duplicate binary artifact')
        result[key] = (identity, rel)
    require(len(prefixes) <= 1, 'Workspace artifact paths use inconsistent package roots')
    declarations = {}
    for identity, (checkout, records) in checkouts.items():
        for target, rel in declared_artifacts(identity, checkout, records).items():
            declarations[(identity, target)] = (identity, rel)
    require(result == declarations, 'Workspace binary targets differ from their committed declarations')
    discovered = set()
    for identity, (_, records) in checkouts.items():
        for rel in records:
            parts = rel.split('/')
            for index, part in enumerate(parts):
                if part.endswith('.xcframework'):
                    discovered.add((identity, '/'.join(parts[:index + 1])))
                    break
    require(set(result.values()) == discovered, 'Workspace binary artifact inventory is incomplete')
    return result


def workspace_fingerprint(state, artifact_paths, dependencies):
    normalized_artifacts = []
    for artifact in state['object']['artifacts']:
        identity, target = artifact['packageRef']['identity'], artifact['targetName']
        _, rel = artifact_paths[(identity, target)]
        normalized_artifacts.append({**artifact, 'path': 'checkouts/' + dependencies[identity] + '/' + rel})
    normalized = {'version': state['version'], 'object': {
        'prebuilts': [],
        'dependencies': sorted(state['object']['dependencies'], key=lambda value: value['packageRef']['identity']),
        'artifacts': sorted(normalized_artifacts, key=lambda value: (value['packageRef']['identity'], value['targetName'])),
    }}
    # The source-control locations are validated inputs to this hash. They are
    # never included in the manifest, diagnostics, or command output.
    return digest(normalized)


def framework_inventory(identity, target, rel, checkout, records, budget):
    bundle = safe_path(checkout, rel)
    require(bundle.is_dir(), 'Local binary XCFramework is missing')
    info_rel = rel + '/Info.plist'
    require(info_rel in records and records[info_rel]['mode'] == '100644',
            'XCFramework Info.plist is missing or unsupported')
    info_path = safe_path(checkout, info_rel)
    require(info_path.stat().st_size <= MAX_DOCUMENT, 'XCFramework metadata size limit exceeded')
    try:
        info = plistlib.loads(verified_bytes(info_path, records[info_rel]), dict_type=UniqueDictionary)
    except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException, RecursionError):
        raise InventoryError('Malformed XCFramework metadata') from None
    depth(info)
    shape(info, ('AvailableLibraries', 'CFBundlePackageType', 'XCFrameworkFormatVersion'))
    require(info['CFBundlePackageType'] == 'XFWK' and info['XCFrameworkFormatVersion'] == '1.0',
            'Unsupported XCFramework metadata schema')
    require(isinstance(info['AvailableLibraries'], list) and 0 < len(info['AvailableLibraries']) <= 64,
            'XCFramework slice inventory is incomplete')
    slices, identifiers = [], set()
    for library in info['AvailableLibraries']:
        shape(library, ('LibraryIdentifier', 'LibraryPath', 'SupportedArchitectures', 'SupportedPlatform'),
              ('SupportedPlatformVariant', 'HeadersPath', 'DebugSymbolsPath', 'BitcodeSymbolMapsPath', 'BinaryPath'))
        identifier, library_path = relative(library['LibraryIdentifier']), relative(library['LibraryPath'])
        require('/' not in identifier and identifier not in identifiers, 'Duplicate or unsafe XCFramework slice')
        identifiers.add(identifier)
        platform = library['SupportedPlatform']
        variant = library.get('SupportedPlatformVariant', '')
        require(platform in ('ios', 'tvos', 'macos', 'watchos', 'xros', 'driverkit')
                and variant in ('', 'simulator', 'maccatalyst')
                and (variant != 'maccatalyst' or platform == 'ios')
                and (variant != 'simulator' or platform not in ('macos', 'driverkit')),
                'Unsupported XCFramework platform')
        architectures = library['SupportedArchitectures']
        require(isinstance(architectures, list) and architectures and len(architectures) <= 16
                and all(isinstance(arch, str) and arch in ('arm64', 'arm64e', 'x86_64', 'i386',
                         'armv7', 'armv7s', 'armv7k', 'arm64_32') for arch in architectures)
                and len(set(architectures)) == len(architectures), 'Unsupported XCFramework architectures')
        slice_rel = rel + '/' + identifier
        slice_path = safe_path(checkout, slice_rel)
        require(slice_path.is_dir(), 'XCFramework slice is missing')
        for field in ('HeadersPath', 'DebugSymbolsPath', 'BitcodeSymbolMapsPath'):
            if field in library:
                referenced = safe_path(checkout, slice_rel + '/' + relative(library[field]))
                require(referenced.is_dir(), 'XCFramework referenced content is missing')
        library_rel = slice_rel + '/' + library_path
        payload = safe_path(checkout, library_rel, final_symlink=True)
        require(not payload.is_symlink(), 'Unsupported symlink at XCFramework LibraryPath')
        require(payload.is_file() or payload.is_dir(), 'XCFramework slice library is missing')
        try:
            payload.resolve(strict=True).relative_to(bundle)
        except (OSError, ValueError, RuntimeError):
            raise InventoryError('Unsafe XCFramework library symlink') from None
        content = {key: value for key, value in records.items()
                   if key == library_rel or key.startswith(library_rel + '/')}
        summary = tree_summary(content)
        require(summary['bytes'] > 0, 'XCFramework slice library is empty')
        if payload.is_dir():
            require(library_path.endswith('.framework'), 'Unsupported XCFramework library directory')
            default_binary = library_path + '/' + Path(library_path).stem
        else:
            require(library_path.endswith(('.a', '.dylib')), 'Unsupported XCFramework library file')
            default_binary = library_path
        binary_rel = slice_rel + '/' + relative(library.get('BinaryPath', default_binary))
        binary = safe_path(checkout, binary_rel, final_symlink=True)
        require(binary.is_file() and binary_rel in records, 'XCFramework referenced binary is missing')
        require(binary_rel == library_rel or binary_rel.startswith(library_rel + '/'),
                'XCFramework binary does not belong to its library')
        resolved_binary = resolved_tracked_path(binary, checkout, records, budget).relative_to(checkout).as_posix()
        require((resolved_binary == library_rel or resolved_binary.startswith(library_rel + '/'))
                and resolved_binary in records and records[resolved_binary]['mode'] in ('100644', '100755')
                and records[resolved_binary]['bytes'] > 0, 'XCFramework binary payload is missing or empty')
        slice_content = {key: value for key, value in records.items() if key.startswith(slice_rel + '/')}
        slices.append({'identifier': identifier, 'platform': platform, 'variant': variant,
                       'architectures': sorted(architectures), 'library_path': library_rel,
                       'binary_path': binary_rel, 'binary_sha256': records[resolved_binary]['sha256'],
                       'slice_tree_sha256': tree_summary(slice_content)['tree_sha256'],
                       **summary})
    whole = {key: value for key, value in records.items() if key.startswith(rel + '/')}
    return {'identity': identity, 'target': target, 'path': rel,
            'info_sha256': records[info_rel]['sha256'], **tree_summary(whole),
            'slices': sorted(slices, key=lambda item: item['identifier'])}


def inventory(root, packages):
    budget = Budget()
    root, packages = input_directory(root), input_directory(packages)
    locked, lock_hash = pins(root, budget)
    require(locked.keys() == SUPPORTED_GRAPH.keys(), 'Unsupported package identity profile')
    require(all(pin['state']['revision'] == SUPPORTED_GRAPH[identity]['revision']
                for identity, pin in locked.items()), 'Unsupported package revision profile')
    dependencies, artifacts, state = workspace(packages, locked)
    checkouts_dir = safe_path(packages, 'checkouts')
    require(checkouts_dir.is_dir(), 'Restored checkout directory is missing')
    entries = set()
    with os.scandir(checkouts_dir) as contents:
        for entry in contents:
            budget.entry()
            require(entry.is_dir(follow_symlinks=False), 'Unsupported restored checkout entry')
            entries.add(entry.name)
    require(entries == set(dependencies.values()), 'Restored checkout inventory differs from the lock')
    checkouts = {}
    checkout_manifest = []
    for identity in sorted(locked):
        revision = locked[identity]['state']['revision']
        checkout, records = checkout_inventory(packages, dependencies[identity], revision, budget)
        checkouts[identity] = (checkout, records)
        checkout_manifest.append({'identity': identity, 'revision': revision,
                                  'path': 'checkouts/' + dependencies[identity], **tree_summary(records)})
    artifact_paths = local_artifacts(artifacts, locked, dependencies, checkouts)
    binary_manifest = []
    for (identity, target), (_, rel) in sorted(artifact_paths.items()):
        checkout, records = checkouts[identity]
        binary_manifest.append(framework_inventory(identity, target, rel, checkout, records, budget))
    for identity, (checkout, _) in checkouts.items():
        require(git(checkout, budget, 'rev-parse', 'HEAD', max_output=128).strip().decode()
                == locked[identity]['state']['revision'], 'Checkout HEAD changed during inventory')
    budget.remaining()
    result = {'schema_version': 1, 'workspace_schema_version': 7,
              'lock_sha256': lock_hash, 'checkouts': checkout_manifest,
              'workspace_state_sha256': workspace_fingerprint(state, artifact_paths, dependencies),
              'binary_artifacts': binary_manifest}
    result['graph_sha256'] = digest(result)
    return result


def save_manifest(result, output, compare=None):
    output = normalized_input(output)
    for path in (output, *output.parents):
        require(not path.is_symlink(), 'Unsafe manifest output path')
    require(output.parent.is_dir(), 'Manifest output directory is missing')
    if compare:
        prior = document(Path(compare))
        require(canonical(prior) == canonical(result), 'Package graph changed during locked resolution')
    data = canonical(result) + b'\n'
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.package-graph-', delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
        os.replace(temporary, output)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def main():
    class PrivateArgumentParser(argparse.ArgumentParser):
        def error(self, message):
            raise InventoryError('Invalid inventory arguments')

    parser = PrivateArgumentParser(prog='apple-package-graph.py', description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compare', type=Path)
    started = time.monotonic()
    def deadline_expired(signum, frame):
        raise InventoryError('Inventory time limit exceeded')

    previous_handler = signal.signal(signal.SIGALRM, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, MAX_SECONDS)
    try:
        args = parser.parse_args()
        result = inventory(args.root, args.packages)
        save_manifest(result, args.output, args.compare)
    except Exception:
        # Never print exception text from filesystem, parser or Git operations.
        print('Package graph inventory failed; cache is incomplete, mismatched or unsupported', file=sys.stderr)
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
    print('SILO_PACKAGE_GRAPH ' + result['graph_sha256']
          + ' checkouts=' + str(len(result['checkouts']))
          + ' binary_artifacts=' + str(len(result['binary_artifacts']))
          + ' hashed_files=' + str(sum(item['files'] for item in result['checkouts']))
          + ' hashed_bytes=' + str(sum(item['bytes'] for item in result['checkouts']))
          + ' elapsed_seconds=' + format(time.monotonic() - started, '.3f'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
