#if os(iOS) || os(tvOS)
import SwiftUI

@MainActor
enum WatchPartyEntry {
    // Off in Release until the physical-device and mixed-client gate clears;
    // testers opt in from Settings > Experimental.
    static var isEnabled: Bool {
        ExperimentalFeatures.shared.isEnabled(.watchParty)
    }

    static func setEnabled(_ enabled: Bool) {
        ExperimentalFeatures.shared.setEnabled(.watchParty, enabled)
        let session = WatchPartySession.shared
        if enabled {
            Task { await session.refreshCapabilities() }
        } else {
            session.leave()
        }
    }

    static var isAvailable: Bool {
        isEnabled && WatchPartySession.shared.supportsSynchronizedParty
    }

    /// Inside a party, only a host-pick room's manager picks directly; everyone
    /// else adds a suggestion, so the entry point says so.
    static var actionTitle: String {
        let session = WatchPartySession.shared
        guard session.isEngaged else { return "Watch Party" }
        return session.room?.selfCanManageRoom == true && session.room?.selectionMode == .hostPick
            ? "Watch Party" : "Suggest to Party"
    }

    /// `preview` is what the caller already shows for the title; the lobby
    /// lays out from it instead of passing through its empty and loading states.
    static func open(contentId: String, title: String, type: String, fileId: Int?,
                     libraryId: Int?, preview: WatchPartySelectedItem? = nil, router: AppRouter) {
        let session = WatchPartySession.shared
        let selection = WatchPartySelection(contentId: contentId,
            fileId: fileId.map(String.init), libraryId: libraryId.map(String.init))
        router.dismissItemDetail()
        router.navigate(to: .watchParty)
        Task {
            if session.isEngaged {
                if session.room?.selfCanManageRoom == true, session.room?.selectionMode == .hostPick {
                    await session.select(selection, preview: preview)
                } else {
                    // The server stores what the suggester sends; without the
                    // preview's art the lobby shows a blank poster.
                    await session.addSuggestion(WatchPartyNewSuggestion(
                        contentId: contentId, contentType: type, title: title,
                        subtitle: preview?.subtitle, posterUrl: preview?.posterUrl))
                }
            } else {
                await session.create(selection: selection, preview: preview)
            }
        }
    }
}

struct WatchPartyMenuButton: View {
    let contentId: String
    let title: String
    let type: String
    var fileId: Int? = nil
    var preview: WatchPartySelectedItem? = nil
    /// Episode menus inherit a preview from the series page they sit on.
    var episode: EpisodeListItem? = nil
    @Environment(\.browseLibraryId) private var libraryId
    @Environment(\.watchPartyEpisodePreview) private var episodePreview
    @Environment(AppRouter.self) private var router

    var body: some View {
        if WatchPartyEntry.isAvailable {
            Button(WatchPartyEntry.actionTitle, systemImage: "person.3") {
                WatchPartyEntry.open(contentId: contentId, title: title, type: type,
                    fileId: fileId, libraryId: libraryId,
                    preview: preview ?? episode.flatMap { episodePreview?($0) }, router: router)
            }
        }
    }
}

private struct WatchPartyEpisodePreviewKey: EnvironmentKey {
    static let defaultValue: ((EpisodeListItem) -> WatchPartySelectedItem)? = nil
}

extension EnvironmentValues {
    /// Set by a series page so episode menus below it can hand the lobby a preview.
    var watchPartyEpisodePreview: ((EpisodeListItem) -> WatchPartySelectedItem)? {
        get { self[WatchPartyEpisodePreviewKey.self] }
        set { self[WatchPartyEpisodePreviewKey.self] = newValue }
    }
}
#endif
