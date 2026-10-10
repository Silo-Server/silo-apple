import SwiftUI

/// Text the server reports as machine-translated by AI
/// (`machine_translated_fields` on a detail, season, episode or card).
enum MachineTranslation {
    /// Shown and spoken wherever machine-translated text appears.
    static let label = "Translated by AI"
    static let symbol = "translate"

    /// Whether the overview shown was machine-translated. Every surface in
    /// this app shows the overview but not the tagline, so a tagline-only
    /// mark (an AI tagline under a provider or hand-written overview) must not
    /// label it.
    static func isOverviewMarked(_ fields: [String]?) -> Bool {
        (fields ?? []).contains("overview")
    }
}

/// What a description area shows about its on-view translation, in the
/// space under (or, on tvOS, inside) the description.
enum DescriptionTranslationStatus: Equatable {
    /// A translation is running; the description is the original text.
    case translating
    /// The description shown was machine-translated by AI.
    case machineTranslated

    var text: String {
        switch self {
        case .translating: "Translating…"
        case .machineTranslated: MachineTranslation.label
        }
    }

    /// The status for an overview: a running translation wins over the
    /// label, since the text shown is still the original until it lands. The
    /// label needs `overview` among the machine-translated fields.
    static func resolve(translating: Bool, machineTranslatedFields: [String]?) -> DescriptionTranslationStatus? {
        if translating { return .translating }
        return MachineTranslation.isOverviewMarked(machineTranslatedFields) ? .machineTranslated : nil
    }
}

/// Subtle secondary label for machine-translated text: the translate symbol
/// and "Translated by AI". The compact form is the symbol alone for dense
/// rows such as episode cards; it keeps the words for VoiceOver.
struct MachineTranslatedLabel: View {
    var compact = false

    var body: some View {
        DescriptionTranslationStatusLabel(status: .machineTranslated, compact: compact)
    }
}

/// Renders a ``DescriptionTranslationStatus`` in the app's secondary text
/// style. Never focusable, so it adds no stop to a tvOS focus graph.
struct DescriptionTranslationStatusLabel: View {
    let status: DescriptionTranslationStatus
    var compact = false
    /// Point size for surfaces with their own type scale (tvOS heroes).
    var fontSize: CGFloat?

    var body: some View {
        if compact {
            Image(systemName: MachineTranslation.symbol)
                .font(font)
                .foregroundStyle(Color.siloSecondaryText.opacity(0.8))
                .accessibilityLabel(status.text)
                #if !os(tvOS)
                .help(status.text)
                #endif
        } else {
            HStack(spacing: 6) {
                Image(systemName: MachineTranslation.symbol)
                    .symbolEffect(.pulse, isActive: status == .translating)
                    .accessibilityHidden(true)
                Text(status.text)
            }
            .font(font)
            .foregroundStyle(Color.siloSecondaryText)
            .accessibilityElement(children: .combine)
        }
    }

    private var font: Font {
        if let fontSize { return .system(size: fontSize, weight: .medium) }
        return compact ? .caption2 : .caption
    }
}
