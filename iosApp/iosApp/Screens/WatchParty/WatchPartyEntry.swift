#if os(iOS) || os(tvOS)
import SwiftUI

@MainActor
enum WatchPartyEntry {
    // Release enablement follows the physical-device and mixed-client gate.
    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var isAvailable: Bool {
        guard isEnabled else { return false }
        let session = WatchPartySession.shared
        return session.capabilities?.supportsSocket == true
            && session.capabilities?.connectionReplaced == true && session.supportsPlayback
    }

    static func open(contentId: String, title: String, type: String, fileId: Int?,
                     libraryId: Int?, router: AppRouter) {
        let session = WatchPartySession.shared
        let selection = WatchPartySelection(contentId: contentId,
            fileId: fileId.map(String.init), libraryId: libraryId.map(String.init))
        router.dismissItemDetail()
        router.navigate(to: .watchParty)
        Task {
            if session.isEngaged {
                if session.room?.selfCanManageRoom == true, session.room?.selectionMode == .hostPick {
                    await session.select(selection)
                } else {
                    await session.addSuggestion(WatchPartyNewSuggestion(
                        contentId: contentId, contentType: type, title: title))
                }
            } else {
                await session.create(selection: selection)
            }
        }
    }
}

struct WatchPartyMenuButton: View {
    let contentId: String
    let title: String
    let type: String
    var fileId: Int? = nil
    @Environment(\.browseLibraryId) private var libraryId
    @Environment(AppRouter.self) private var router

    var body: some View {
        if WatchPartyEntry.isAvailable {
            Button("Watch Party", systemImage: "person.3") {
                WatchPartyEntry.open(contentId: contentId, title: title, type: type,
                    fileId: fileId, libraryId: libraryId, router: router)
            }
        }
    }
}
#endif
