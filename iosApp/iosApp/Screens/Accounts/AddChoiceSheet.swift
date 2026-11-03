import SwiftUI

/// Add on "Who's watching?": each `AddChoice` with its icon and line, then
/// Cancel, in the app's own sheet (spec §4.1).
struct AddChoiceSheet: View {
    let choices: [AddChoice]
    let onChoose: (AddChoice) -> Void
    let onCancel: () -> Void

    @FocusState private var focusedChoice: AddChoice?

    var body: some View {
        MarqueeDialog(onCancel: onCancel) {
            MarqueeDialogHeader(title: "Add")
                .padding(.bottom, spacing * 1.5)
            VStack(spacing: spacing) {
                ForEach(choices) { choice in
                    Button {
                        onChoose(choice)
                    } label: {
                        AddChoiceLabel(choice: choice)
                    }
                    .buttonStyle(AddChoiceRowStyle())
                    .focused($focusedChoice, equals: choice)
                }
            }
            #if os(tvOS)
            // A full-width row like the choices, as Roku draws it.
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AddChoiceRowStyle())
            .padding(.top, spacing)
            #else
            Button("Cancel", action: onCancel)
                .buttonStyle(.marquee(.plain))
                .padding(.top, spacing)
            #endif
        }
        #if os(tvOS)
        // The picker under the sheet is disabled as it opens, so nothing is
        // focused until the sheet claims it.
        .defaultFocus($focusedChoice, choices.first)
        .onAppear { focusedChoice = choices.first }
        #endif
    }

    #if os(tvOS)
    private let spacing: CGFloat = 14
    #else
    private let spacing: CGFloat = 8
    #endif
}

private struct AddChoiceLabel: View {
    let choice: AddChoice
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    var body: some View {
        HStack(spacing: gap) {
            Image(systemName: choice.systemImage)
                .font(.system(size: iconFont, weight: .medium))
                .frame(width: iconSize, height: iconSize)
                #if os(tvOS)
                // Roku's glyph tile: it stays dark, its glyph light, on the
                // focused row's white.
                .foregroundStyle(Color.siloOnSurface)
                .background(
                    RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                        .fill(isFocused ? Color.black.opacity(0.85) : Color.white.opacity(0.1))
                )
                #else
                .background(Circle().fill(Color.white.opacity(0.1)))
                #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                    .font(.system(size: titleFont, weight: .semibold))
                Text(choice.detail)
                    .font(.system(size: detailFont))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    #if os(tvOS)
    private let gap: CGFloat = 22
    private let iconSize: CGFloat = 64
    private let iconFont: CGFloat = 28
    private let titleFont: CGFloat = 30
    private let detailFont: CGFloat = 22
    #elseif os(macOS)
    private let gap: CGFloat = 12
    private let iconSize: CGFloat = 32
    private let iconFont: CGFloat = 14
    private let titleFont: CGFloat = 14
    private let detailFont: CGFloat = 12
    #else
    private let gap: CGFloat = 14
    private let iconSize: CGFloat = 40
    private let iconFont: CGFloat = 17
    private let titleFont: CGFloat = 17
    private let detailFont: CGFloat = 14
    #endif
}

/// A choice row: a quiet tile that fills white under focus on Apple TV, as
/// the TV's other buttons do.
private struct AddChoiceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AddChoiceRowBody(configuration: configuration)
    }
}

private struct AddChoiceRowBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(isFocusedTV ? Color.black : Color.siloOnSurface)
            .padding(.horizontal, padding)
            .padding(.vertical, padding * 0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .scaleEffect(isFocusedTV && !reduceMotion ? 1.03 : 1)
            .marqueePressHaptic(configuration.isPressed)
            #if os(tvOS)
            .focusEffectDisabled()
            .animation(SiloTheme.springAnimation, value: isFocused)
            #endif
    }

    private var isFocusedTV: Bool {
        #if os(tvOS)
        isFocused
        #else
        false
        #endif
    }

    private var fill: Color {
        if isFocusedTV { return Color.siloOnSurface }
        return Color.white.opacity(configuration.isPressed ? 0.14 : 0.06)
    }

    #if os(tvOS)
    private let padding: CGFloat = 26
    private let corner: CGFloat = 24
    #else
    private let padding: CGFloat = 14
    private let corner: CGFloat = 16
    #endif
}
