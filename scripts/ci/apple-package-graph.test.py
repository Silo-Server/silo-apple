#!/usr/bin/env python3
"""Exercise restored package graphs using disposable, real Git repositories."""

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('package_graph', Path(__file__).with_name('apple-package-graph.py'))
graph = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(graph)


def git(root, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
    return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
                                    '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                                    '-C', str(root), *args], env=env, stderr=subprocess.DEVNULL).decode().strip()


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())


class Fixture:
    def __init__(self, base):
        self.root, self.packages = base / 'app', base / 'SourcePackages'
        self.root.mkdir()
        self.packages.mkdir()
        self.checkouts = {'sourcekit': 'SourceKit', 'mediakit': 'MediaKit'}
        self.binary_paths = {'Demo': 'Libraries/Demo.xcframework', 'Static': 'Libraries/Static.xcframework'}
        for identity, folder in self.checkouts.items():
            checkout = self.packages / 'checkouts' / folder
            checkout.mkdir(parents=True)
            git(checkout, 'init', '-q')
            write(checkout / 'Package.swift', '// swift-tools-version: 6.0\nimport PackageDescription\n'
                  + ('let package = Package(name: "SourceKit", targets: [])\n' if identity == 'sourcekit' else
                     'let package = Package(name: "MediaKit", targets: [\n'
                     ' .binaryTarget(name: "Demo", path: "Libraries/Demo.xcframework"),\n'
                     ' .binaryTarget(name: "Static", path: "Libraries/Static.xcframework")\n])\n'))
            write(checkout / 'Sources' / 'Feature.swift', 'struct Feature {}\n')
        self.media = self.packages / 'checkouts' / 'MediaKit'
        for name, rel in self.binary_paths.items():
            bundle = self.media / rel
            libraries = []
            for platform in ('ios', 'macos'):
                identifier = platform + '-arm64'
                slice_path = bundle / identifier
                if name == 'Static':
                    library = 'libStatic.a'
                    write(slice_path / library, b'!<arch>\nfixture-static-' + platform.encode())
                    write(slice_path / 'Headers' / 'Static.h', 'int fixture(void);\n')
                    extra = {'HeadersPath': 'Headers', 'BinaryPath': library}
                else:
                    library = 'Demo.framework'
                    framework = slice_path / library
                    if platform == 'macos':
                        write(framework / 'Versions' / 'A' / 'Demo', b'fixture-macos-mach-o')
                        write(framework / 'Versions' / 'A' / 'Headers' / 'Demo.h', 'int fixture(void);\n')
                        write(framework / 'Versions' / 'A' / 'Resources' / 'Info.plist', '<plist/>\n')
                        (framework / 'Versions' / 'Current').symlink_to('A')
                        (framework / 'Demo').symlink_to('Versions/Current/Demo')
                        (framework / 'Headers').symlink_to('Versions/Current/Headers')
                        (framework / 'Resources').symlink_to('Versions/Current/Resources')
                    else:
                        write(framework / 'Demo', b'fixture-ios-mach-o')
                        write(framework / 'Headers' / 'Demo.h', 'int fixture(void);\n')
                    extra = {'BinaryPath': library + '/Demo'}
                libraries.append({'LibraryIdentifier': identifier, 'LibraryPath': library,
                                  'SupportedArchitectures': ['arm64'], 'SupportedPlatform': platform, **extra})
            write(bundle / 'Info.plist', plistlib.dumps({'AvailableLibraries': libraries,
                  'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}))
        self.state = {'version': 7, 'object': {'dependencies': [], 'artifacts': [], 'prebuilts': []}}
        self.lock = {'version': 3, 'originHash': '0' * 64, 'pins': []}
        for identity, folder in self.checkouts.items():
            checkout = self.packages / 'checkouts' / folder
            git(checkout, 'add', '.')
            git(checkout, 'commit', '-qm', 'Package fixture')
            revision = git(checkout, 'rev-parse', 'HEAD')
            reference = {'identity': identity, 'kind': 'remoteSourceControl',
                         'location': 'https://example.invalid/' + folder, 'name': folder}
            self.lock['pins'].append({key: value for key, value in reference.items() if key != 'name'}
                                     | {'state': {'revision': revision}})
            self.state['object']['dependencies'].append({'basedOn': None, 'packageRef': reference,
                'state': {'name': 'sourceControlCheckout', 'checkoutState': {'revision': revision}}, 'subpath': folder})
            if identity == 'mediakit':
                for target, rel in self.binary_paths.items():
                    self.state['object']['artifacts'].append({'kind': {'xcframework': {}},
                        'packageRef': reference.copy(), 'path': '/old-runner/SourcePackages/checkouts/' + folder + '/' + rel,
                        'source': {'type': 'local'}, 'targetName': target})
        self.save_state()
        write(self.root / graph.LOCK, json.dumps(self.lock))
        git(self.root, 'init', '-q')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'App fixture')
        self.profile = {}
        for identity in self.checkouts:
            self.register_profile(identity)

    def register_profile(self, identity):
        checkout = self.packages / 'checkouts' / self.checkouts[identity]
        self.profile[identity] = {'revision': git(checkout, 'rev-parse', 'HEAD'),
            'manifests': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in checkout.glob('Package*.swift')},
            'binaries': self.binary_paths.copy() if identity == 'mediakit' else {}}

    def save_state(self):
        write(self.packages / 'workspace-state.json', json.dumps(self.state))

    def attest(self):
        return graph.inventory(self.root, self.packages)

    def recommit_media(self, identity='mediakit'):
        checkout = self.packages / 'checkouts' / self.checkouts[identity]
        git(checkout, 'add', '-A')
        git(checkout, 'commit', '-qm', 'Changed package fixture')
        revision = git(checkout, 'rev-parse', 'HEAD')
        self.profile[identity]['revision'] = revision
        next(pin for pin in self.lock['pins'] if pin['identity'] == identity)['state']['revision'] = revision
        next(dep for dep in self.state['object']['dependencies']
             if dep['packageRef']['identity'] == identity)['state']['checkoutState']['revision'] = revision
        self.save_state()
        write(self.root / graph.LOCK, json.dumps(self.lock))
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'Changed app lock fixture')


class PackageGraphTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = graph.normalized_input(Path(self.temp.name))
        self.fixture = Fixture(self.base)
        self.profile_patch = patch.object(graph, 'SUPPORTED_GRAPH', self.fixture.profile)
        self.profile_patch.start()

    def tearDown(self):
        self.profile_patch.stop()
        self.temp.cleanup()

    def test_complete_graph_hashes_every_platform_and_normalizes_only_bookkeeping(self):
        before = self.fixture.attest()
        self.assertEqual(len(before['checkouts']), 2)
        self.assertEqual(len(before['binary_artifacts']), 2)
        self.assertEqual({slice['platform'] for binary in before['binary_artifacts'] for slice in binary['slices']},
                         {'ios', 'macos'})
        serialized = graph.canonical(before).decode()
        self.assertNotIn('https:', serialized)
        self.assertNotIn('/old-runner/', serialized)
        self.assertNotIn(str(self.base), serialized)
        self.assertTrue(all(len(binary['tree_sha256']) == 64 for binary in before['binary_artifacts']))
        for artifact in self.fixture.state['object']['artifacts']:
            artifact['path'] = artifact['path'].replace('/old-runner/SourcePackages', '/new-host/cache/SourcePackages')
        self.fixture.state['object']['artifacts'].reverse()
        self.fixture.state['object']['dependencies'].reverse()
        self.fixture.save_state()
        after = self.fixture.attest()
        self.assertEqual(before, after)
        output, previous = self.base / 'after.json', self.base / 'before.json'
        graph.save_manifest(before, previous)
        graph.save_manifest(after, output, previous)
        self.assertEqual(output.read_bytes(), previous.read_bytes())

    def test_partial_seed_is_rejected_before_any_resolution(self):
        shutil.rmtree(self.fixture.packages / 'checkouts' / 'SourceKit')
        with self.assertRaisesRegex(graph.InventoryError, 'checkout inventory'):
            self.fixture.attest()

    def test_wrong_head_and_workspace_revision_are_rejected(self):
        write(self.fixture.media / 'new.swift', 'struct Changed {}\n')
        git(self.fixture.media, 'add', '.')
        git(self.fixture.media, 'commit', '-qm', 'Wrong pinned HEAD')
        with self.assertRaisesRegex(graph.InventoryError, 'HEAD differs'):
            self.fixture.attest()
        dependency = next(dep for dep in self.fixture.state['object']['dependencies']
                          if dep['packageRef']['identity'] == 'mediakit')
        dependency['state']['checkoutState']['revision'] = 'a' * 40
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'state differs'):
            self.fixture.attest()

    def test_hidden_dirty_file_and_deleted_tracked_file_are_rejected(self):
        source = self.fixture.media / 'Sources' / 'Feature.swift'
        git(self.fixture.media, 'update-index', '--assume-unchanged', 'Sources/Feature.swift')
        source.write_text('struct Changed {}\n')
        with self.assertRaisesRegex(graph.InventoryError, 'content differs'):
            self.fixture.attest()
        source.unlink()
        with self.assertRaisesRegex(graph.InventoryError, 'inventory is incomplete'):
            self.fixture.attest()

    def test_library_mutation_and_missing_slice_payload_fail(self):
        library = self.fixture.media / 'Libraries/Static.xcframework/ios-arm64/libStatic.a'
        library.write_bytes(b'!<arch>\nchanged payload')
        with self.assertRaisesRegex(graph.InventoryError, 'content differs'):
            self.fixture.attest()
        library.unlink()
        with self.assertRaisesRegex(graph.InventoryError, 'inventory is incomplete'):
            self.fixture.attest()

    def test_empty_actual_framework_binary_cannot_hide_behind_a_valid_symlink(self):
        binary = self.fixture.media / 'Libraries/Demo.xcframework/macos-arm64/Demo.framework/Versions/A/Demo'
        binary.write_bytes(b'')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'payload is missing or empty'):
            self.fixture.attest()

    def test_library_path_symlinks_are_outside_the_supported_inventory_schema(self):
        bundle = self.fixture.media / 'Libraries/Static.xcframework'
        payload = bundle / 'ios-arm64' / 'libStatic.a'
        payload.rename(bundle / 'ios-arm64' / 'actual.a')
        payload.symlink_to('actual.a')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'symlink at XCFramework LibraryPath'):
            self.fixture.attest()

    def test_tracked_executable_requires_owner_execute_permission(self):
        executable = self.fixture.media / 'build.sh'
        write(executable, '#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
        self.fixture.recommit_media()
        executable.chmod(0o645)
        with self.assertRaisesRegex(graph.InventoryError, 'mode differs'):
            self.fixture.attest()

    def test_committed_metadata_cannot_reference_a_missing_library(self):
        path = self.fixture.media / 'Libraries/Static.xcframework/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['AvailableLibraries'][0]['LibraryPath'] = 'missing.a'
        path.write_bytes(plistlib.dumps(info))
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'library is missing'):
            self.fixture.attest()

    def test_missing_workspace_artifact_and_wrong_target_fail(self):
        removed = self.fixture.state['object']['artifacts'].pop()
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'binary targets differ'):
            self.fixture.attest()
        self.fixture.state['object']['artifacts'].append(removed)
        removed['targetName'] = 'WrongName'
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'binary targets differ'):
            self.fixture.attest()

    def test_partial_or_mismatched_workspace_fields_fail_before_resolution(self):
        dependency = self.fixture.state['object']['dependencies'][0]
        del dependency['basedOn']
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'document schema'):
            self.fixture.attest()
        dependency['basedOn'] = None
        dependency['packageRef']['name'] = 'DifferentName'
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'package name differs'):
            self.fixture.attest()

    def test_unobserved_null_workspace_fields_fail_before_resolution(self):
        self.fixture.state['object']['dependencies'][0]['state']['checkoutState']['branch'] = None
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'state differs from the lock'):
            self.fixture.attest()

    def test_escaping_symlink_and_symlinked_checkout_root_fail(self):
        link = self.fixture.media / 'Libraries/Demo.xcframework/macos-arm64/Demo.framework/Demo'
        link.unlink()
        link.symlink_to('../../../../../../../outside')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'symlink'):
            self.fixture.attest()

    def test_symlinks_cannot_load_uninventoried_git_metadata_or_checkout_root(self):
        link = self.fixture.media / 'Sources' / 'GitConfig'
        link.symlink_to('../.git/config')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'symlink traversal'):
            self.fixture.attest()
        link.unlink()
        link.symlink_to('..')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'outside the committed content'):
            self.fixture.attest()
        checkout = self.fixture.packages / 'checkouts' / 'SourceKit'
        moved = self.base / 'MovedSourceKit'
        checkout.rename(moved)
        checkout.symlink_to(moved)
        with self.assertRaisesRegex(graph.InventoryError, 'checkout entry'):
            self.fixture.attest()

    def test_symlink_chain_cannot_route_through_untracked_git_metadata(self):
        write(self.fixture.media / '.git' / 'alias.swift', 'untracked metadata\n')
        (self.fixture.media / '.git' / 'alias.swift').unlink()
        (self.fixture.media / '.git' / 'alias.swift').symlink_to('../Sources/Feature.swift')
        link = self.fixture.media / 'Sources' / 'Alias.swift'
        link.symlink_to('../.git/alias.swift')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'symlink traversal'):
            self.fixture.attest()

    def test_symlink_traversal_cannot_hide_git_hops_behind_parent_components(self):
        (self.fixture.media / '.git' / 'hop').symlink_to('../Sources')
        link = self.fixture.media / 'Sources' / 'Alias.swift'
        link.symlink_to('../.git/hop/../../Sources/Feature.swift')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'symlink traversal'):
            self.fixture.attest()

    def test_unsafe_workspace_paths_are_never_normalized(self):
        artifact = self.fixture.state['object']['artifacts'][0]
        original = artifact['path']
        for path in ('/runner/../SourcePackages/checkouts/MediaKit/Libraries/Demo.xcframework',
                     '/runner/SourcePackages/checkouts/OtherPackage/Libraries/Demo.xcframework',
                     '/runner/SourcePackages/checkouts/MediaKit/../Libraries/Demo.xcframework',
                     '/runner/checkouts/OtherPackage/checkouts/MediaKit/Libraries/Demo.xcframework',
                     '/runner/checkouts/MediaKit/checkouts/MediaKit/Libraries/Demo.xcframework'):
            artifact['path'] = path
            self.fixture.save_state()
            with self.subTest(path=path), self.assertRaises(graph.InventoryError):
                self.fixture.attest()
        artifact['path'] = original.replace('/old-runner/', '/another-runner/')
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'inconsistent package roots'):
            self.fixture.attest()

    def test_unsupported_remote_artifacts_archives_and_schema_fail(self):
        artifact = self.fixture.state['object']['artifacts'][0]
        for source in ({'type': 'remote', 'url': 'https://secret.invalid/token', 'checksum': 'a' * 64},
                       {'type': 'local', 'checksum': 'a' * 64}):
            artifact['source'] = source
            self.fixture.save_state()
            with self.subTest(source=source), self.assertRaisesRegex(graph.InventoryError, 'remote or archived'):
                self.fixture.attest()
        artifact['source'] = {'type': 'local'}
        artifact['kind'] = {'artifactsArchive': {}}
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'artifact representation'):
            self.fixture.attest()
        for version in (6, 99, True):
            self.fixture.state['version'] = version
            self.fixture.save_state()
            with self.subTest(version=version), self.assertRaisesRegex(graph.InventoryError, 'workspace-state schema'):
                self.fixture.attest()

    def test_unpinned_or_duplicate_nodes_and_wrong_locations_fail(self):
        dependency = self.fixture.state['object']['dependencies'][0]
        dependency['packageRef']['location'] = 'https://other.invalid/SourceKit'
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'reference differs'):
            self.fixture.attest()
        dependency['packageRef']['location'] = 'https://example.invalid/SourceKit'
        self.fixture.state['object']['dependencies'][1] = dependency
        self.fixture.save_state()
        with self.assertRaisesRegex(graph.InventoryError, 'Duplicate workspace'):
            self.fixture.attest()

    def test_unsupported_manifest_expression_remote_binary_and_alternates_fail(self):
        manifest = self.fixture.media / 'Package.swift'
        original = manifest.read_text()
        for replacement in ('path: computedPath', 'url: "https://example.invalid/demo.zip", checksum: "abc"'):
            manifest.write_text(original.replace('path: "Libraries/Demo.xcframework"', replacement))
            self.fixture.recommit_media()
            with self.subTest(replacement=replacement), self.assertRaisesRegex(graph.InventoryError, 'manifest profile'):
                self.fixture.attest()
        manifest.write_text(original)
        write(self.fixture.media / 'Package@swift-6.0.swift', original.replace('name: "Demo"', 'name: "Alternate"'))
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'manifest profile'):
            self.fixture.attest()

    def test_raw_strings_and_mutated_targets_fail_outside_the_reviewed_profile(self):
        manifest = self.fixture.media / 'Package.swift'
        original = manifest.read_text()
        for addition in ('\nlet text = #"example with an escaped \\" quote"#\n',
                         '\npackage.targets[0].path = computedPath\n',
                         '\npackage.targets[0].url = "https://example.invalid/binary.zip"\n'):
            manifest.write_text(original + addition)
            self.fixture.recommit_media()
            with self.subTest(addition=addition), self.assertRaisesRegex(graph.InventoryError, 'manifest profile'):
                self.fixture.attest()

    def test_source_only_manifests_are_also_locked_against_dynamic_artifacts(self):
        checkout = self.fixture.packages / 'checkouts' / 'SourceKit'
        manifest = checkout / 'Package.swift'
        manifest.write_text(manifest.read_text() + '\npackage.targets.append(makeRemoteBinary())\n')
        self.fixture.recommit_media('sourcekit')
        with self.assertRaisesRegex(graph.InventoryError, 'manifest profile'):
            self.fixture.attest()

    def test_unknown_identity_or_revision_is_outside_the_supported_graph(self):
        pin = self.fixture.lock['pins'][0]
        pin['state']['revision'] = 'a' * 40
        write(self.fixture.root / graph.LOCK, json.dumps(self.fixture.lock))
        git(self.fixture.root, 'add', '.')
        git(self.fixture.root, 'commit', '-qm', 'Unsupported revision fixture')
        with self.assertRaisesRegex(graph.InventoryError, 'revision profile'):
            self.fixture.attest()
        pin['identity'] = 'unknownkit'
        write(self.fixture.root / graph.LOCK, json.dumps(self.fixture.lock))
        git(self.fixture.root, 'add', '.')
        git(self.fixture.root, 'commit', '-qm', 'Unsupported identity fixture')
        with self.assertRaisesRegex(graph.InventoryError, 'identity profile'):
            self.fixture.attest()

    def test_lock_must_match_committed_source_bytes(self):
        path = self.fixture.root / graph.LOCK
        path.write_text(path.read_text() + '\n')
        with self.assertRaisesRegex(graph.InventoryError, 'lock differs from committed'):
            self.fixture.attest()

    def test_fixed_libass_helper_is_attested_and_changes_are_detected(self):
        rel = 'Libraries/XCFrameworks/Demo.xcframework'
        previous = self.fixture.media / self.fixture.binary_paths['Demo']
        destination = self.fixture.media / rel
        destination.parent.mkdir(parents=True)
        previous.rename(destination)
        manifest = self.fixture.media / 'Package.swift'
        manifest.write_text('import PackageDescription\nfunc binaryTarget(_ libraryName: String) -> Target {\n'
            ' .binaryTarget(name: libraryName, path: "Libraries/XCFrameworks/\\(libraryName).xcframework")\n}\n'
            'let package = Package(name: "MediaKit", targets: [binaryTarget("Demo"),\n'
            ' .binaryTarget(name: "Static", path: "Libraries/Static.xcframework")])\n')
        self.fixture.state['object']['artifacts'][0]['path'] = '/old-runner/SourcePackages/checkouts/MediaKit/' + rel
        self.fixture.recommit_media()
        self.fixture.binary_paths['Demo'] = rel
        self.fixture.register_profile('mediakit')
        self.assertEqual(len(self.fixture.attest()['binary_artifacts']), 2)
        manifest.write_text(manifest.read_text().replace('binaryTarget("Demo")', 'binaryTarget(variableName)'))
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'manifest profile'):
            self.fixture.attest()

    def test_traversing_slice_identifiers_and_duplicate_plist_keys_fail(self):
        path = self.fixture.media / 'Libraries/Static.xcframework/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['AvailableLibraries'][0]['LibraryIdentifier'] = '../ios-arm64'
        path.write_bytes(plistlib.dumps(info))
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'Unsafe relative'):
            self.fixture.attest()
        info['AvailableLibraries'][0]['LibraryIdentifier'] = 'ios-arm64'
        data = plistlib.dumps(info).replace(b'<key>XCFrameworkFormatVersion</key>',
              b'<key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key>')
        path.write_bytes(data)
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'Duplicate document'):
            self.fixture.attest()

    def test_filters_untracked_files_and_partial_clones_are_rejected(self):
        write(self.fixture.media / '.gitattributes', '*.a filter=external\n')
        self.fixture.recommit_media()
        with self.assertRaisesRegex(graph.InventoryError, 'content filter'):
            self.fixture.attest()
        write(self.fixture.media / 'Untracked.swift', 'struct Untracked {}\n')
        with self.assertRaisesRegex(graph.InventoryError, 'untracked or ignored'):
            self.fixture.attest()
        git(self.fixture.media, 'config', 'remote.origin.promisor', 'true')
        with self.assertRaisesRegex(graph.InventoryError, 'partial Git checkout'):
            self.fixture.attest()

    def test_inherited_git_routing_cannot_select_a_different_repository(self):
        with patch.dict(os.environ, {'GIT_DIR': str(self.fixture.root / '.git'),
                                     'GIT_WORK_TREE': str(self.fixture.root), 'GIT_CONFIG_COUNT': '99'}):
            self.assertEqual(len(self.fixture.attest()['checkouts']), 2)

    def test_file_byte_time_and_command_output_limits_fail_closed(self):
        for setting, value, message in (('MAX_FILES', 1, 'path limit|file limit'),
                                        ('MAX_BYTES', 1, 'byte limit'),
                                        ('MAX_SECONDS', 0, 'time limit')):
            with self.subTest(setting=setting), patch.object(graph, setting, value), \
                    self.assertRaisesRegex(graph.InventoryError, message):
                self.fixture.attest()
        with self.assertRaisesRegex(graph.InventoryError, 'output limit'):
            graph.git(self.fixture.root, graph.Budget(), 'rev-parse', 'HEAD', max_output=1)

    def test_compare_rejects_mutation_without_overwriting_prior_proof(self):
        before = self.fixture.attest()
        previous, output = self.base / 'before.json', self.base / 'after.json'
        graph.save_manifest(before, previous)
        write(self.fixture.media / 'Sources/Feature.swift', 'struct Changed {}\n')
        self.fixture.recommit_media()
        after = self.fixture.attest()
        self.assertNotEqual(before['graph_sha256'], after['graph_sha256'])
        with self.assertRaisesRegex(graph.InventoryError, 'changed during locked resolution'):
            graph.save_manifest(after, output, previous)
        self.assertFalse(output.exists())
        self.assertEqual(json.loads(previous.read_text()), before)

    def test_compare_rejects_malformed_schema_types_even_if_python_considers_them_equal(self):
        before = self.fixture.attest()
        previous, output = self.base / 'before.json', self.base / 'after.json'
        for value in (True, 1.0):
            malformed = {**before, 'schema_version': value}
            write(previous, json.dumps(malformed))
            with self.subTest(value=value), self.assertRaisesRegex(graph.InventoryError, 'changed during locked resolution'):
                graph.save_manifest(before, output, previous)
        self.assertFalse(output.exists())

    def test_cli_failure_exposes_no_paths_locations_or_raw_git_state(self):
        state_path = self.fixture.packages / 'workspace-state.json'
        state_path.write_text('{"version":7,"version":99,"private":"https://secret.invalid/token"}')
        output = self.base / 'manifest.json'
        run = subprocess.run([sys.executable, str(Path(graph.__file__)), '--root', str(self.fixture.root),
                              '--packages', str(self.fixture.packages), '--output', str(output)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(run.returncode, 1)
        self.assertFalse(output.exists())
        self.assertEqual(run.stdout, '')
        self.assertNotIn(str(self.base), run.stderr)
        self.assertNotIn('secret.invalid', run.stderr)
        self.assertNotIn('Traceback', run.stderr)


if __name__ == '__main__':
    unittest.main()
