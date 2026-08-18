//
//  SubtitleLanguageChoice.swift
//  Silo (iOS + tvOS + macOS)
//
//  Types shared by the two in-player subtitle sheets, ``SubtitleTranslateMenu``
//  and ``SubtitleSearchMenu``: the language row model both menus list, and the
//  tvOS panel row both menus render.
//

import SwiftUI

/// One selectable language row, shared by the AI and search subtitle menus.
/// `hint` floats a short provenance tag ("Preferred" / "Original language")
/// next to the suggested rows; nil for the plain language list.
struct SubtitleLanguageChoice: Identifiable {
    let code: String
    let label: String
    let hint: String?
    var id: String { code }

    /// Display name for a language code, preferring the curated label.
    static func displayName(_ code: String) -> String {
        if let opt = PlaybackLanguageOption.all.first(where: {
            $0.code.caseInsensitiveCompare(code) == .orderedSame
        }) {
            return opt.label
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    /// The full offered language list: the given hinted codes floated to the
    /// top in the order supplied, then every ``PlaybackLanguageOption``, all
    /// deduped case-insensitively.
    static func ordered(hinted: [(code: String, hint: String)]) -> [SubtitleLanguageChoice] {
        var result: [SubtitleLanguageChoice] = []
        var seen = Set<String>()
        func add(_ code: String, hint: String?) {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(.init(code: trimmed, label: displayName(trimmed), hint: hint))
        }
        for entry in hinted {
            add(entry.code, hint: entry.hint)
        }
        for option in PlaybackLanguageOption.all {
            add(option.code, hint: nil)
        }
        return result
    }

    /// ``ordered(hinted:)`` split into the floated suggestions (kept in
    /// priority order) and the alphabetized remainder.
    static func sections(
        hinted: [(code: String, hint: String)]
    ) -> (suggested: [SubtitleLanguageChoice], other: [SubtitleLanguageChoice]) {
        let all = ordered(hinted: hinted)
        return (
            suggested: all.filter { $0.hint != nil },
            other: all
                .filter { $0.hint == nil }
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        )
    }
}

// MARK: - tvOS focus row

#if os(tvOS)
/// Generic panel row for the subtitle menus: bare `.focusable` + tap (no
/// system halo), row-fill focus highlight, focus driven by the panel-level
/// `@FocusState.Binding` keyed on `rowID`. Shared by ``SubtitleSearchMenu``
/// and ``SubtitleTranslateMenu``.
struct SubtitleSheetTVRow<Content: View>: View {
    let rowID: String
    var isDisabled: Bool = false
    @FocusState.Binding var focusedID: String?
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    private var isFocused: Bool { focusedID == rowID }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .focusable(!isDisabled)
        .focused($focusedID, equals: rowID)
        .onTapGesture(perform: action)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
    }
}

/// Inline section header for the tvOS subtitle panels. Shared by
/// ``SubtitleSearchMenu`` and ``SubtitleTranslateMenu``.
struct SubtitleSheetSectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 14, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }
}
#endif
