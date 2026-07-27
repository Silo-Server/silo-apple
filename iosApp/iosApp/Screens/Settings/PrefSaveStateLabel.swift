import SwiftUI

/// A settings save state that can be shown to the user.
///
/// iOS and tvOS each carry their own `PrefSaveState` enum on their own view
/// model, so this protocol is what lets one view render both. That matters
/// because the alternative is what shipped: the message existed only on the
/// Subtitles screens, so a failed audio-language save on the Playback screen —
/// a flaky connection, or the 403 a PIN-gated primary profile gets — left the
/// picker showing the value the server had just rejected, with no indication
/// anything had gone wrong, and surfaced the error on a different screen.
///
/// Each view model holds one of these per profile-backed write (audio,
/// subtitle, metadata) rather than one shared field, so a result always
/// renders under the row that produced it.
protocol PrefSaveStateRepresentable {
    var saveStateMessage: String { get }
    var saveStateIsError: Bool { get }
}

extension SettingsViewModel.PrefSaveState: PrefSaveStateRepresentable {
    var saveStateMessage: String {
        switch self {
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .failed(let message): return "Couldn't save: \(message)"
        }
    }

    var saveStateIsError: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The transient "Saving… / Saved / Couldn't save" line shown under a
/// server-backed settings section on iOS and macOS.
struct PrefSaveStateLabel<SaveState: PrefSaveStateRepresentable>: View {
    let state: SaveState

    var body: some View {
        Text(state.saveStateMessage)
            .foregroundStyle(state.saveStateIsError ? Color.continuumError : Color.continuumSecondaryText)
    }
}

#if os(tvOS)
extension TVSettingsViewModel.PrefSaveState: PrefSaveStateRepresentable {
    var saveStateMessage: String {
        switch self {
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .failed(let message): return "Couldn't save: \(message)"
        }
    }

    var saveStateIsError: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// tvOS variant, sized for the ten-foot UI. Extracted from
/// `TVSubtitleSettingsView` so the Playback pane, which also saves profile
/// fields, reports its result the same way instead of silently.
struct TVPrefSaveFooter<SaveState: PrefSaveStateRepresentable>: View {
    let state: SaveState?

    var body: some View {
        if let state {
            if state.saveStateIsError {
                Text(state.saveStateMessage)
                    .font(.system(size: 19))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            } else {
                TVSettingsFooter(state.saveStateMessage)
            }
        }
    }
}
#endif
