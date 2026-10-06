#if os(tvOS)
import SwiftUI

/// Body of a Skyline library-type tab (Movies / Series / Music /
/// Audiobooks): the selected sub-destination's content, with the
/// Recommended landing as the default.
///
/// Collections and Browse are reached from the top-bar cascade (§5.3), which
/// commits `selectedPill`. Up from content goes straight to the bar.
struct TVLibraryTypeTabView: View {
    let type: TVLibraryTabType
    /// The library this tab is currently scoped to (§3.1). Resolved by the
    /// shell from the persisted per-profile scope, or the first library on
    /// cold start. The cascade selector (§5.3) switches it.
    let activeLibrary: Library?
    /// Selected sub-destination, owned by the shell so it survives tab
    /// switches within a session (§8); cold start always lands on
    /// Recommended. Written by the cascade dropdown.
    @Binding var selectedPill: TVLibraryPill
    var focusRequest: Int = 0
    var isTopMenuFocused: Bool = false
    let onTopMenuFocusRequest: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let activeLibrary {
                ZStack(alignment: .top) {
                    pillContent(for: activeLibrary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // §4.2 sub-destination content switch: the cascade
                        // dropdown commits a new `selectedPill`, and selecting
                        // the tab crossfades the swap. Keyed on the pill so a
                        // switch inserts the new content and removes the old;
                        // Reduce Motion drops the drift to opacity only.
                        .id(selectedPill)
                        .transition(pillContentTransition)
                }
                // Re-create the tab body when the scoped library changes so
                // section fetches and grid state reset cleanly.
                .id(activeLibrary.id)
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No \(type.title.lowercased()) libraries",
                    subtitle: "Libraries visible to this profile will appear here."
                )
                .padding(.top, TVTopMenuLayout.contentTopInset)
                .tvPageFocusOwner(
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: "No \(type.title.lowercased()) libraries",
                    onMoveUp: onTopMenuFocusRequest
                )
            }
        }
        .siloBackground()
    }

    @ViewBuilder
    private func pillContent(for library: Library) -> some View {
        switch selectedPill {
        case .recommended:
            TVLibraryBrowseView(
                library: library,
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onMoveUp: onTopMenuFocusRequest
            )
        case .collections:
            TVLibraryCollectionsView(
                library: library,
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onMoveUp: onTopMenuFocusRequest
            )
        case .browse:
            TVLibraryGridView(
                libraryId: library.id,
                libraryName: library.name,
                libraryType: library.type,
                initialFilter: .none,
                showsHeader: false,
                showsAlphabetRail: true,
                topContentInset: SiloTheme.Skyline.libraryContentTopInset,
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: onTopMenuFocusRequest
            )
        }
    }

    // MARK: - Selection & focus routing

    /// Asymmetric transition for the sub-destination content swap (§4.2).
    /// Incoming content fades in while drifting 12 px upward into place;
    /// outgoing content fades out without sliding. Reduce Motion → opacity
    /// only, no drift (the §4.2 acceptance "no drift animations").
    private var pillContentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: SiloTheme.Skyline.pillDriftY)),
            removal: .opacity
        )
    }
}
#endif
