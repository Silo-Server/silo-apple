#if os(tvOS)
import SwiftUI

/// Right-edge A–Z jump rail for tvOS. Holding the remote's direction pad
/// through 100k items is not a real navigation strategy — this rail lets the
/// user jump directly to a title prefix.
///
/// The server supports `name_prefix` as a LIKE-pattern match on `sort_title`
/// (see `Continuum/internal/catalog/browse.go`). "#" jumps to titles whose
/// sort-title begins with a non-alpha character (numeric titles, punctuation).
/// The server has no letter-count endpoint, so the rail renders every letter
/// unconditionally — empty letters just yield empty result pages.
struct TVAlphabetRail: View {
    /// Currently-selected prefix, or nil when no filter is applied.
    @Binding var selected: String?
    let onSelect: (String?) -> Void

    /// Tracks which letter (if any) currently has focus. `nil` means
    /// focus is outside the rail — in that state the rail collapses to
    /// a slim edge peek so the grid can breathe. Focus moving into any
    /// letter flips this non-nil and the rail expands.
    @FocusState private var focusedLetter: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool { focusedLetter != nil }

    private let letters: [String] = {
        var result: [String] = ["All", "#"]
        result.append(contentsOf: (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map { String($0) } })
        return result
    }()

    var body: some View {
        // `GeometryReader` hands the ScrollView's full height down to
        // the inner VStack, which forces `minHeight` to the container
        // size so the `alignment: .center` actually has room to push
        // the letters to the vertical middle. When expanded the
        // letters overflow this minimum and the ScrollView takes over
        // naturally; when collapsed everything fits and centers cleanly.
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(letters, id: \.self) { letter in
                        LetterButton(
                            letter: letter,
                            isSelected: isSelected(letter),
                            isExpanded: isExpanded,
                            action: {
                                let newValue: String?
                                switch letter {
                                case "All": newValue = nil
                                case "#":   newValue = "#"
                                default:    newValue = letter
                                }
                                selected = newValue
                                onSelect(newValue)
                            }
                        )
                        .focused($focusedLetter, equals: letter)
                    }
                }
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    minHeight: proxy.size.height,
                    alignment: .center
                )
            }
        }
        .frame(width: isExpanded ? 96 : 18)
        .frame(maxHeight: .infinity)
        // Reduce Motion snaps the collapse/expand instead of sliding the
        // rail width (§4.2 acceptance: no drift animations).
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isExpanded)
        .focusSection()
    }

    private func isSelected(_ letter: String) -> Bool {
        switch letter {
        case "All": return selected == nil
        case "#":   return selected == "#"
        default:    return selected == letter
        }
    }
}

private struct LetterButton: View {
    let letter: String
    let isSelected: Bool
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(letter)
                // Monospaced per §6.4 ("mono 15"): SF Mono at the spec size
                // when expanded, a slim mono peek when collapsed. Mono keeps
                // every letter the same advance width so the column reads as
                // an even rail rather than a ragged proportional list.
                .font(.system(
                    size: isExpanded ? SiloTheme.Skyline.alphabetRailLetterSize : 10,
                    weight: .semibold,
                    design: .monospaced
                ))
                .frame(
                    width: isExpanded ? 38 : 10,
                    height: isExpanded ? 38 : 10
                )
                .opacity(isExpanded ? 1 : 0.35)
        }
        .buttonStyle(LetterButtonStyle(isSelected: isSelected))
    }
}

private struct LetterButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        LetterButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct LetterButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundColor(foreground)
            .background(
                // §6.4: the current/selected letter is a white rounded chip,
                // and the focused letter inverts the same way. A rounded
                // rectangle (not a capsule) gives the "chip" read; both
                // states fill white so each reads clearly.
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous)
                    .fill(background)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            // Reduce Motion snaps the focus/press treatment (§4.2 acceptance).
            .animation(reduceMotion ? nil : .easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var foreground: Color {
        // White-chip states (focused or current) take a dark label so the
        // letter stays legible on the inverted fill.
        if isFocused || isSelected { return .siloBackground }
        return .siloSecondaryText
    }

    private var background: Color {
        // Current letter inverts to a solid white chip (§6.4); the focused
        // letter inverts identically. Everything else is bare.
        if isFocused || isSelected { return .siloOnSurface }
        return .clear
    }
}
#endif
