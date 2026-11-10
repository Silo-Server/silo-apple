#!/usr/bin/env python3
"""Tests for check-catalog-text.py."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_catalog_text", Path(__file__).with_name("check-catalog-text.py")
)
guard = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(guard)


class ScanSourceTests(unittest.TestCase):
    def assertFlags(self, source: str, line: int = 1) -> None:
        self.assertIn(line, guard.scan_source(source), source)

    def assertPasses(self, source: str) -> None:
        self.assertEqual(guard.scan_source(source), [], source)

    def test_flags_english_in_text_apis(self) -> None:
        for source in [
            'Text("Done")',
            'Button("Retry") {}',
            'Label("Remove", systemImage: "xmark")',
            '.navigationTitle("Profiles")',
            '.accessibilityLabel( "Close")',
            'Text("\\(count) items")',
            'Toggle("Autoplay", isOn: $on)',
            '.alert("Sign out?", isPresented: $shown) {}',
            'Text(busy ? "Saving…" : "Save")',
            'Button(title ?? "Retry") {}',
            'Text(title ?? ("Unknown"))',
            'Text(title ?? (busy ? "Saving…" : "Save"))',
            'Text(busy ? ("Saving…") : "Save")',
            'Text(!done ? "Saving…" : ("Save"))',
            '.accessibilityValue(isOn ? "On" : "Off")',
            'NavigationLink("View Report") {',
            'Section("Preferences") {',
            'TVSettingsFooter("Only this Apple TV.")',
            'Text("\\(name ?? "Unknown") is empty")',
            'Text(("Save changes"))',
            'Text("\\(name ?? "Unknown")")',
            '.accessibilityLabel("\\(isOn ? "Playing" : "Paused")")',
        ]:
            self.assertFlags(source)

    def test_flags_prose_in_labelled_text_arguments(self) -> None:
        for source in [
            'EmptyStateView(icon: "film", title: "No favorites")',
            'LoadingView(message: "Loading recommendations")',
            'TVSettingsPickerRow(title: isOn ? .settingsOn : "Off", value: v) {}',
            'Overlay(title: .commonDone, confirmTitle: "Forget Server", cancel: {})',
            'Card(subtitle: name ?? "Unknown title")',
            'showNotice(title: "Audio change failed", message: "Kept the current track.")',
            'PlayerNotice(title: "Skipped")',
            'TVSettingsPickerRow(title: .settingsFoo, value: isOn ? "On" : "Off")',
            '.accessibilityAction(named: "Mark Watched") { mark() }',
        ]:
            self.assertFlags(source)

    def test_passes_keys_data_and_ignored_lines(self) -> None:
        for source in [
            "Text(.commonDone)",
            'Text("\\(count)")',
            'Text("\\(name) · \\(Text(verbatim: code).bold())")',
            'Text(verbatim: "Silo")',
            "Text(title)",
            'Label(title, systemImage: "xmark")',
            'Image(systemName: "chevron.right")',
            '.accessibilityLabel("Silo") // i18n-ignore: brand',
            'Button(.commonCancel, role: .cancel) {}',
            'logger.info("Loaded \\(n) rows")',
            '/// Button("Retry") is the old form',
            '.accessibilityLabel(Text(.commonDone))',
            'Text(kind == "handoff" ? .commonDone : .commonNext)',
            'Text(String(name.first ?? "S"))',
            'Text(format?(value) ?? "")',
            'Text(make!("x"))',
            'Text("\\(names.joined(separator: ", "))")',
            'Text(foo("bar"))',
            'let queue = DispatchQueue(label: "org.siloserver.silo.loader")',
            '@Parameter(title: "shell.siri.searchTerm")',
            'PINKey(label: "delete.backward")',
            'DiagTrace.record(category: .player, message: "player presented")',
            'DiagTrace.breadcrumb(category: .ui, message: "screen changed")',
            'DiagLog.i(category: .net, message: "retry scheduled")',
            'Track(id: "file:\\(id):subtitle:\\(index)", index: index)',
            'if detail.type == "episode" { return nil }',
        ]:
            self.assertPasses(source)

    def test_mapped_literals_only_where_listed(self) -> None:
        for source in [
            'case .needsSetup: return "Setup needed"',
            'case .seasonPremiere: "NEW SEASON"',
            'let label = isOn ? "Remove from Watchlist" : "Add to Watchlist"',
            'let title = name ?? "Unknown title"',
            'tokens.append("Default")',
            'return "\\(name ?? "Unknown title")"',
            'return "\\(enabled ? "Enabled" : "Disabled")"',
            'case .off: "\\(prefix) \\(muted ? "Muted" : "Off")"',
            'return ("No items")',
            'let title = name ?? ("Unknown name")',
            'let label = on ? ("Enabled") : ("Disabled")',
            'let label = on ? "Enabled" : ( "Disabled" )',
            'let title = name??("Unknown name")',
            'return flag ? "chevron.up" : "Off"',
        ]:
            self.assertIn(1, guard.scan_source(source, mappings=True), source)
            self.assertEqual(guard.scan_source(source), [], source)
        for source in [
            'case .tv: "tv"',
            'return isMovie ? "movie" : "series"',
            'return "rename:\\(group.id)"',
            'return "frame=\\(Int(frame.minX))"',
            'return "\\(name ?? "")"',
            'return "\\(kind == "movie" ? 1 : 2)"',
            'return "\\(isMovie ? "movie" : "series")"',
            'return ("movie")',
            'return ("episode") == kind',
            'handler?("Done")',
            'return flag ? "chevron.up" : "chevron.down"',
            'if detail.type == "episode" { return nil }',
            'return "HDR"  // i18n-ignore: technical token',
            'DiagTrace.breadcrumb(message: done ? "Finished loading" : "Started loading")',
        ]:
            self.assertEqual(guard.scan_source(source, mappings=True), [], source)

    def test_reads_literals_across_lines(self) -> None:
        self.assertFlags('let x = 1\nText(\n    "Split across lines"\n)\n', line=3)
        self.assertFlags('EmptyStateView(\n    title:\n        "No items"\n)\n', line=3)
        self.assertFlags('let x = 1\nText("""\n    Save changes\n    """)\n', line=2)
        self.assertPasses('Text("""\n    \\(count)\n    """)\n')
        self.assertPasses('/*\n Text("In a comment")\n*/\n')
        self.assertPasses('Card(\n    title: // i18n-ignore: server name\n        "Living Room"\n)\n')
        self.assertFlags('Text( // i18n-ignore: brand\n    busy\n        ? "Saving"\n        : "Save"\n)\n', line=3)


class ScanTests(unittest.TestCase):
    def write(self, root: Path, path: str, text: str) -> None:
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text(text)

    def test_scans_only_listed_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(root, guard.PATH_LIST, "# comment\napp/Done  # trailing\napp/One.swift mappings\n")
            self.write(root, "app/Done/View.swift", 'let x = 1\nText("Hello")\nreturn "Not checked here"\n')
            self.write(root, "app/One.swift", 'Text(.commonDone)\nreturn "Checked here"\n')
            self.write(root, "app/Open/View.swift", 'Text("Not converted yet")\n')
            self.assertEqual(guard.scan(root), [
                'app/Done/View.swift:2: Text("Hello")',
                'app/One.swift:2: return "Checked here"',
            ])

    def test_missing_list_or_listed_path_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(SystemExit):
                guard.scan(root)
            self.write(root, guard.PATH_LIST, "app/Missing\n")
            with self.assertRaises(SystemExit):
                guard.scan(root)
            self.write(root, "app/One.swift", "")
            self.write(root, guard.PATH_LIST, "app/One.swift strict\n")
            with self.assertRaises(SystemExit):
                guard.scan(root)


if __name__ == "__main__":
    unittest.main()
