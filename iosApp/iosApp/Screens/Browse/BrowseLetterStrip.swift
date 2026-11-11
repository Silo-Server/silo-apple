import SwiftUI

/// Letter row above the library grid on iPhone, iPad and Mac. Picking a
/// letter narrows the grid to titles whose sort title starts with it (the
/// catalog's `name_prefix`); All shows the whole library again.
///
/// There is no "#" entry: `name_prefix` is a literal prefix, so "#" would
/// match only titles that begin with that character, not numbers and symbols.
struct BrowseLetterStrip: View {
    /// The active prefix, or nil when the whole library shows.
    let selected: String?
    let onSelect: (String?) -> Void

    /// Grows with the text, so the active letter's capsule stays round at
    /// accessibility sizes.
    @ScaledMetric(relativeTo: .caption) private var minimumEntryWidth: CGFloat = 16

    private static let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
    private static let spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.spacing) {
            // All stays put while the letters scroll, so the way back to the
            // whole library is always on screen.
            entry(nil)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(Self.letters, id: \.self) { letter in
                            entry(letter)
                                .id(letter)
                        }
                    }
                    .padding(.trailing, SiloTheme.padding)
                    .mouseDragScrolling()
                }
                // The row is rebuilt when the grid gives way to the empty or
                // error state, which would leave a letter picked from the far
                // end off screen.
                .onAppear {
                    if let selected { proxy.scrollTo(selected, anchor: .center) }
                }
            }
        }
        .padding(.leading, SiloTheme.padding)
    }

    private func entry(_ letter: String?) -> some View {
        let isSelected = selected == letter
        return Button {
            onSelect(letter)
        } label: {
            label(for: letter)
                .font(.siloCaption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .siloBackground : .siloSecondaryText)
                .frame(minWidth: minimumEntryWidth)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color.siloOnSurface : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: letter))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A–Z are the catalog's `name_prefix` values, shown as is.
    private func label(for letter: String?) -> Text {
        letter.map { Text(verbatim: $0) } ?? Text(.catalogLettersAll)
    }

    private func accessibilityLabel(for letter: String?) -> Text {
        letter.map { Text(.libraryStartsWithLetter($0)) } ?? Text(.catalogLettersAll)
    }
}
