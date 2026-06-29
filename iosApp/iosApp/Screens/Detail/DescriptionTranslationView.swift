import SwiftUI

/// On-view "translate this description" affordance, hosted just under the
/// synopsis on item detail (iOS + tvOS).
///
/// Renders nothing unless the server reports a description that exists but
/// isn't yet in the viewer's resolved metadata language — i.e. the item's
/// `pendingTranslationLanguage` is non-nil — and the server's `on_view`
/// mode allows it:
/// - `.off`   → nothing.
/// - `.button`→ a "Translate" button; tapping runs the translation.
/// - `.auto`  → fires once automatically on appear, showing only the
///              in-progress spinner.
///
/// The target language is the item's own `pendingTranslationLanguage` (the
/// server already resolved request param → profile pref → library default
/// to produce it). Completion is observed by the coordinator re-fetching
/// the detail until the pending flag clears.
struct DescriptionTranslationView: View {
    /// The detail view model that owns `detail`; refreshed payloads are
    /// written straight back so the overview re-renders in place.
    let viewModel: ItemDetailViewModel
    let contentId: String

    @State private var coordinator = DescriptionTranslationCoordinator()
    /// Per-item latch for `.auto` mode. The auto branch fires from
    /// `onAppear`, which re-runs every time the row re-appears (scrolling,
    /// re-layout) while `pendingTranslationLanguage` is still set. Without
    /// this, each re-appear would re-kick the translation. Keyed on
    /// `contentId` so a genuinely different item still auto-fires once.
    @State private var autoFiredFor: String?

    private var pendingLanguage: String? {
        viewModel.detail?.pendingTranslationLanguage
    }

    private var onViewMode: MetadataAIStatus.OnViewMode {
        AICapabilities.shared.metadataOnView
    }

    var body: some View {
        Group {
            if onViewMode != .off, let target = pendingLanguage, !target.isEmpty {
                content(targetLanguage: target)
            }
        }
        .onDisappear { coordinator.cancel() }
    }

    @ViewBuilder
    private func content(targetLanguage: String) -> some View {
        switch coordinator.phase {
        case .translating:
            HStack(spacing: 8) {
                ProgressView()
                    #if os(tvOS)
                    .scaleEffect(0.7)
                    #endif
                Text("Translating…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Button {
                startTranslation(targetLanguage: targetLanguage)
            } label: {
                translateLabel
            }
            .buttonStyle(.plain)
        case .idle:
            if onViewMode == .button {
                Button {
                    startTranslation(targetLanguage: targetLanguage)
                } label: {
                    translateLabel
                }
                .buttonStyle(.plain)
            } else {
                // .auto — fire once per item when the row appears. The latch
                // prevents a re-appear from re-kicking while the pending flag
                // is still set.
                Color.clear
                    .frame(height: 0)
                    .onAppear {
                        guard autoFiredFor != contentId else { return }
                        autoFiredFor = contentId
                        startTranslation(targetLanguage: targetLanguage)
                    }
            }
        }
    }

    private var translateLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble")
            Text("Translate")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.continuumPrimary)
    }

    private func startTranslation(targetLanguage: String) {
        coordinator.translate(
            contentId: contentId,
            targetLanguage: targetLanguage
        ) { refreshed in
            viewModel.detail = refreshed
        }
    }
}
