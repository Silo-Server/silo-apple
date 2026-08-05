#if os(tvOS)
import SwiftUI

/// Everything the root Settings view needs to present one modal picker while
/// preserving the exact detail row that should regain focus on dismissal.
struct TVSettingsPickerRequest: Identifiable {
    let id: String
    let title: String
    let options: [TVSettingsOption]
    let selection: Binding<String>
    var subtitlePreviewAppearance: SubtitleAppearance? = nil
    let returnFocus: TVSettingsDetailFocus
}
#endif
