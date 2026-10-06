import SwiftUI

/// Where Shuffle is offered, decided from what a screen already knows.
enum ShuffleAvailability {
    /// Movie, TV, and mixed libraries hold the movies and episodes a shuffle
    /// plays; audiobook and other libraries do not.
    static func isShuffleLibraryType(_ type: String?) -> Bool {
        guard let type else { return false }
        return SiloMediaType.isMovieLibrary(type)
            || SiloMediaType.isSeries(type)
            || SiloMediaType.isMixedLibrary(type)
    }

    /// A shuffle of one item would only replay it.
    static func hasEnoughToShuffle(playableCount: Int) -> Bool {
        playableCount > 1
    }
}

/// Starts a shuffle and opens the player on its first pick. Each screen with
/// a Shuffle action owns one, so its button can show progress and its alert
/// reports a failure.
@MainActor
@Observable
final class ShuffleLauncher {
    private(set) var isStarting = false
    var failureMessage: String?

    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func start(_ scope: ShuffleScopeRequest, router: AppRouter) {
        guard !isStarting else { return }
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false }
            do {
                let shuffle = try await api.createShuffle(scope: scope)
                router.presentShuffle(shuffle)
            } catch {
                // The server or profile changed while the shuffle started:
                // the screen that asked belongs to the previous owner.
                guard !Self.isOwnerChange(error) else { return }
                failureMessage = Self.failureMessage(for: error)
            }
        }
    }

    nonisolated static func isOwnerChange(_ error: Error) -> Bool {
        switch error {
        case is APIv2OwnerChangedBeforeDispatch, HTTPError.authorityChanged, HTTPError.requestIdentityChanged:
            return true
        default:
            return false
        }
    }

    nonisolated static func failureMessage(for error: Error) -> String {
        switch ShuffleError.classify(error) {
        case .nothingToPlay: return "Nothing here can be played."
        case .notFound: return "This is no longer available to shuffle."
        case nil: return "Couldn't start the shuffle. Try again."
        }
    }
}

private struct ShuffleFailureAlert: ViewModifier {
    @Bindable var launcher: ShuffleLauncher

    func body(content: Content) -> some View {
        content.alert(
            "Couldn't Shuffle",
            isPresented: Binding(
                get: { launcher.failureMessage != nil },
                set: { if !$0 { launcher.failureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launcher.failureMessage ?? "")
        }
    }
}

extension View {
    func shuffleFailureAlert(_ launcher: ShuffleLauncher) -> some View {
        modifier(ShuffleFailureAlert(launcher: launcher))
    }
}

/// The Shuffle button on collection screens.
struct ShuffleButton: View {
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Shuffle", systemImage: "shuffle")
        }
        #if os(tvOS)
        .buttonStyle(TVBrowseControlPillStyle())
        .font(.system(size: 24, weight: .medium))
        // Stays enabled while starting: a disabled button loses focus, and
        // the launcher ignores repeat presses.
        .opacity(isStarting ? 0.6 : 1)
        #else
        .siloSecondaryButton()
        .disabled(isStarting)
        #endif
        .accessibilityIdentifier("collection-shuffle")
    }
}

extension LibraryCollectionKind {
    var shuffleScopeKind: ShuffleScopeKind {
        switch self {
        case .regular: return .libraryCollection
        case .userCollections: return .userCollection
        }
    }
}
