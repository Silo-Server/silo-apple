//
//  SubtitleLanguageChoice.swift
//  Continuum (iOS + tvOS + macOS)
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
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
    }
}
#endif
