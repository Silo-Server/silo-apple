#!/usr/bin/env python3
"""Blocks hardcoded interface text in the Apple paths that use the string catalog.

The paths are listed in scripts/ci/catalog-text-paths.txt, one per line; a path is
added once all of its text comes from the catalog (docs/i18n.md). In those paths
the guard flags:

- English in the first argument of a SwiftUI text API or an
  .accessibilityAction(named:) name, such as Text("Done"),
  Button(busy ? "Saving…" : "Save"), .navigationTitle("Profiles") or
  .accessibilityLabel(name ?? "Unknown"). SwiftUI would look such a literal up as
  a catalog key, so it shows English in every language.
- Prose passed to a labelled text argument of any call, such as
  EmptyStateView(title: "No favorites") or Overlay(message: isOn ? "On" : "Off").
  Identifiers ("chevron.left", "org.siloserver.silo") and logging calls pass.
- In a path listed with the `mappings` flag, a sentence mapped to shown text
  outside a call: `return "…"`, `case .x: "…"`, a ternary branch, a `??`
  fallback or `.append("…")`.

Use the generated key instead (Text(.commonDone)), Text(verbatim:) or
.verbatim(…) for text that isn't interface text, and end a line that must keep a
literal (a brand name, a value that is sent or stored) with
`// i18n-ignore: <reason>`.

Usage: scripts/ci/check-catalog-text.py [--root DIR]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PATH_LIST = "scripts/ci/catalog-text-paths.txt"
IGNORE = "i18n-ignore"

TEXT_API = re.compile(
    r"(?:\b(?:Text|Button|Label|Toggle|Section|Menu|Link|Picker|TextField|SecureField|TextEditor|"
    r"ProgressView|ContentUnavailableView|LabeledContent|NavigationLink|Stepper|DisclosureGroup|"
    r"GroupBox|Tab|ShareLink|DatePicker|Slider|TVSettingsSectionHeader|TVSettingsFooter|"
    r"TVSettingsWarningFooter)"
    r"|\.(?:navigationTitle|navigationSubtitle|navigationBarTitle|accessibilityLabel|accessibilityHint|"
    r"accessibilityValue|alert|confirmationDialog|help|badge))\s*\("
)
TEXT_LABEL = re.compile(
    r"(?<![\w.])(?:title|subtitle|message|label|detail|footer|header|placeholder|prompt|headline|"
    r"caption|eyebrow|confirmTitle|additionalDestructiveTitle|disabledHint|disabledMessage|"
    r"accessibilityLabel|accessibilityHint|value|description)\s*:(?!:)"
)
# .accessibilityAction(named: "…") names an action VoiceOver reads out.
ACTION_NAME = re.compile(r"\.accessibilityAction\s*\(\s*named\s*:")
# Calls whose labelled text goes to logs, not the screen: a logging type, or a
# logging method.
LOGGING_CALL = re.compile(
    r"(?:^|\.)(?:DiagTrace|DiagLog|LogRedactor|Logger|logger|os_log|breadcrumbJournal|earlyBootBuffer)\b"
    r"|(?:^|\.)(?:log|cmpLog|breadcrumb|recordBreadcrumb|renderedLine)$"
)
# A literal mapped to shown text outside a call: `return "…"`, `case .x: "…"`,
# either branch of a ternary, a `??` fallback, or `.append("…")`.
MAPPING = re.compile(
    r"(?:\breturn|\bcase\b[^:\n]*:|\?\??|\?[^:\n]*[^\s:?]\s+:|\.append\()\s*(?=\")"
)

LETTER = re.compile(r"[A-Za-z]")
WORDS = re.compile(r"[A-Za-z]{2,}")
# "chevron.left", "movie", "video_with_episodes", "org.siloserver.silo",
# "shell.siri.searchTerm", "librariesTabSelectedLibraryId", "rename:".
IDENTIFIER = re.compile(r"^[_a-z0-9][\w.:/-]*$")


def string_end(src: str, i: int) -> tuple[int, str]:
    """src[i] opens a string ("…" or \"\"\"…\"\"\"); returns (index after it, text outside interpolations)."""
    multiline = src.startswith('"""', i)
    text, j = [], i + (3 if multiline else 1)
    while j < len(src):
        c = src[j]
        if c == "\\" and j + 1 < len(src) and src[j + 1] == "(":
            j = parens_end(src, j + 1)
            continue
        if c == "\\":
            j += 2
            continue
        if multiline and src.startswith('"""', j):
            return j + 3, "".join(text)
        if not multiline and c in '"\n':
            return j + 1, "".join(text)
        text.append(c)
        j += 1
    return j, "".join(text)


def parens_end(src: str, i: int) -> int:
    """src[i] is "("; returns the index after its matching ")", skipping strings."""
    depth, j = 0, i
    while j < len(src):
        c = src[j]
        if c == '"':
            j, _ = string_end(src, j)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return j


def strip_comments(src: str) -> str:
    """Blanks // and /* */ comments outside strings, keeping offsets and newlines."""
    out, i = list(src), 0
    while i < len(src):
        if src[i] == '"':
            i, _ = string_end(src, i)
        elif src.startswith("//", i):
            j = src.find("\n", i)
            j = len(src) if j < 0 else j
            if IGNORE not in src[i:j]:
                out[i:j] = " " * (j - i)
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = len(src) if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def mask_strings(src: str) -> str:
    """Blanks the inside of string literals, so code patterns don't match text."""
    out, i = list(src), 0
    while i < len(src):
        if src[i] == '"':
            end, _ = string_end(src, i)
            for k in range(i + 1, end - 1):
                if out[k] != "\n":
                    out[k] = " "
            i = end
        else:
            i += 1
    return "".join(out)


def argument_literals(src: str, start: int) -> list[tuple[int, str]]:
    """(offset, text) of each literal shown by the argument starting at src[start]:
    its top-level literals, including inside grouping parentheses, and the
    literals of their interpolations' top-level expressions (`"\\(name ?? "Unknown")"`)."""
    found, groups, depth, j = [], [], 0, start
    while j < len(src):
        c = src[j]
        if c == '"':
            end, text = string_end(src, j)
            # Shown text sits at the argument's top level; a literal inside a
            # nested call or compared with == / != is not.
            compared = re.search(r"[=!]=\s*$", src[start:j]) or re.match(r"\s*[=!]=", src[end:])
            if depth == 0 and not compared:
                found.append((j, text))
                for inner in interpolations(src, j, end):
                    found += argument_literals(src, inner)
            j = end
            continue
        if c in "([{":
            # A bare `(` groups an expression; one after a name, `)`, `]` or `>`
            # calls, as does one after a postfix `?` / `!` (`f?(`, `f!(`). An
            # operator `?` / `!` (`??`, a ternary, `!x`) still groups.
            grouping = c == "(" and not re.search(r"(?:[\w)\]>]|[\w)\]][?!])$", src[start:j].rstrip())
            groups.append(grouping)
            depth += 0 if grouping else 1
        elif c in ")]}":
            if not groups:
                break
            depth -= 0 if groups.pop() else 1
        elif c == "," and not groups:
            break
        j += 1
    return found


def interpolations(src: str, begin: int, end: int) -> list[int]:
    """Start offsets of the `\\( … )` expressions inside the literal src[begin:end]."""
    starts, j = [], begin + 1
    while j < end:
        if src[j] == "\\" and src.startswith("(", j + 1):
            starts.append(j + 2)
            j = parens_end(src, j + 1)
            continue
        j += 2 if src[j] == "\\" else 1
    return starts


def enclosing_call(code: str, offset: int) -> str | None:
    """Name of the call whose argument list holds code[offset], if any (code has
    its strings masked)."""
    depth, j = 0, offset - 1
    while j >= 0:
        c = code[j]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                if c != "(":
                    return None
                m = re.search(r"([A-Za-z_][\w.]*)\s*$", code[max(0, j - 200):j])
                return m.group(1) if m else None
            depth -= 1
        j -= 1
    return None


def prose(text: str) -> bool:
    bare = text.strip()
    return bool(WORDS.search(bare)) and "=" not in bare and not IDENTIFIER.match(bare)


def scan_source(raw: str, mappings: bool = False) -> list[int]:
    """1-based line numbers holding hardcoded interface text."""
    lines = raw.split("\n")
    src = strip_comments(raw)
    code = mask_strings(src)
    hits: dict[int, None] = {}

    def report(offset: int, anchor: int) -> None:
        # The marker sits on the literal's line, or on the line just above
        # when the literal is wrapped onto its own line.
        n = src.count("\n", 0, offset)
        a = src.count("\n", 0, anchor)
        if IGNORE in lines[n] or (a == n - 1 and IGNORE in lines[a]):
            return
        hits[n + 1] = None

    for m in TEXT_API.finditer(code):
        head = src[m.end():m.end() + 40].lstrip()
        if re.match(r"[A-Za-z_]\w*\s*:", head):  # a labelled first argument such as verbatim:
            continue
        for offset, text in argument_literals(src, m.end()):
            if LETTER.search(text):
                report(offset, m.start())
    for m in ACTION_NAME.finditer(code):
        for offset, text in argument_literals(src, m.end()):
            if LETTER.search(text):
                report(offset, m.start())
    for m in TEXT_LABEL.finditer(code):
        call = enclosing_call(code, m.start())
        if call is None or LOGGING_CALL.search(call):
            continue
        for offset, text in argument_literals(src, m.end()):
            if prose(text):
                report(offset, m.start())
    for m in MAPPING.finditer(code) if mappings else ():
        call = enclosing_call(code, m.start())
        if call is not None and LOGGING_CALL.search(call):
            continue
        end, text = string_end(src, m.end())
        compared = re.match(r"\s*[=!]=", src[end:])
        if not compared and prose(text):
            report(m.end(), m.start())
    return sorted(hits)


def listed_paths(root: Path) -> list[tuple[Path, bool]]:
    """(path, whether mapped literals are checked too) for each listed path."""
    path_list = root / PATH_LIST
    if not path_list.is_file():
        raise SystemExit(f"check-catalog-text: missing {PATH_LIST}")
    paths = []
    for line in path_list.read_text(encoding="utf-8").splitlines():
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        entry, flags = fields[0], fields[1:]
        if any(flag != "mappings" for flag in flags):
            raise SystemExit(f"check-catalog-text: {PATH_LIST} has an unknown flag: {line.strip()}")
        path = root / entry
        if not path.exists():
            raise SystemExit(f"check-catalog-text: {PATH_LIST} names a missing path: {entry}")
        paths.append((path, bool(flags)))
    return paths


def scan(root: Path) -> list[str]:
    files: dict[Path, bool] = {}
    for path, mappings in listed_paths(root):
        for file in [path] if path.is_file() else sorted(path.rglob("*.swift")):
            files[file] = files.get(file, False) or mappings
    findings = []
    for file, mappings in files.items():
        raw = file.read_text(encoding="utf-8")
        lines = raw.split("\n")
        for n in scan_source(raw, mappings):
            findings.append(f"{file.relative_to(root)}:{n}: {lines[n - 1].strip()}")
    return findings


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    findings = scan(args.root)
    if not findings:
        print("check-catalog-text: ok")
        return 0
    print("\n".join(findings))
    print(
        "\nerror: these lines put English straight into interface text in a path whose\n"
        "text comes from the string catalog. Add a key to silo-translations and use its\n"
        "symbol (Text(.commonDone)), or use Text(verbatim:) / .verbatim(…) for text that\n"
        "isn't interface text. Mark a literal that must stay as is with a trailing\n"
        "`// i18n-ignore: <reason>`. See docs/i18n.md."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
