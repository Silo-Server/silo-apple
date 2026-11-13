#if !os(tvOS)
import SwiftUI

enum PhonePlaybackSelectorKind: String, Identifiable {
    case edition
    case version
    case audio
    case subtitles

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .edition: return .detailEdition
        case .version: return .detailVersion
        case .audio: return .detailAudio
        case .subtitles: return .detailSubtitles
        }
    }

    /// The row's spoken label: its title, then the current `value`.
    func spokenLabel(_ value: String) -> LocalizedStringResource {
        switch self {
        case .edition: return .detailEditionSpoken(value)
        case .version: return .detailVersionSpoken(value)
        case .audio: return .detailAudioSpoken(value)
        case .subtitles: return .detailSubtitlesSpoken(value)
        }
    }

    var icon: String {
        switch self {
        case .edition: return "rectangle.stack"
        case .version: return "4k.tv"
        case .audio: return "speaker.wave.2"
        case .subtitles: return "captions.bubble"
        }
    }
}

/// Opaque, low-cost placeholder for the common version/audio/subtitle card.
/// It deliberately mirrors `PhonePlaybackSelectorRow`'s three rows so an
/// episode change never removes or inserts vertical space while networking.
/// Row metrics come from `PhonePlaybackSelectorMetrics`, so the placeholder
/// keeps matching the loaded card as Dynamic Type grows it.
struct PhonePlaybackSelectorSkeleton: View {
    /// Card height at the default text size; larger sizes only grow it.
    /// Three rows and two hairline dividers.
    static let standardHeight: CGFloat = 3 * PhonePlaybackSelectorMetrics.rowHeight + 1

    private let kinds: [PhonePlaybackSelectorKind] = [.version, .audio, .subtitles]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = PhonePlaybackSelectorMetrics.rowHeight
    @ScaledMetric(relativeTo: .footnote) private var iconWidth = PhonePlaybackSelectorMetrics.iconWidth

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element.id) { index, kind in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, iconWidth + PhonePlaybackSelectorMetrics.iconSpacing)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    stackedRow(kind)
                } else {
                    HStack(spacing: PhonePlaybackSelectorMetrics.iconSpacing) {
                        icon(kind)

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: kind == .subtitles ? 64 : 50, height: 10)

                        Spacer(minLength: 12)

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.16))
                            .frame(width: skeletonValueWidth(for: kind), height: 10)
                    }
                    .frame(height: rowHeight)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Self.standardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func icon(_ kind: PhonePlaybackSelectorKind) -> some View {
        Image(systemName: kind.icon)
            .siloScaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
            .foregroundStyle(Color.white.opacity(0.24))
            .frame(width: iconWidth, alignment: .leading)
    }

    /// The loaded card's accessibility-size row, with redacted text standing
    /// in for the title and value so both lines take their real height.
    private func stackedRow(_ kind: PhonePlaybackSelectorKind) -> some View {
        VStack(alignment: .leading, spacing: PhonePlaybackSelectorMetrics.stackedLineSpacing) {
            HStack(spacing: PhonePlaybackSelectorMetrics.iconSpacing) {
                icon(kind)
                Text(kind.title)
                    .siloScaledFont(size: 14, weight: .medium, relativeTo: .subheadline)
            }
            Text(.commonLoading)
                .siloScaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
        }
        .foregroundStyle(Color.white.opacity(0.16))
        .redacted(reason: .placeholder)
        .padding(.vertical, PhonePlaybackSelectorMetrics.stackedVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
    }

    private func skeletonValueWidth(for kind: PhonePlaybackSelectorKind) -> CGFloat {
        switch kind {
        case .version: return 126
        case .audio: return 102
        case .subtitles: return 42
        case .edition: return 82
        }
    }
}

/// Row geometry shared by the selector card and its loading placeholder.
/// Values are the default-text-size points; both views scale them.
enum PhonePlaybackSelectorMetrics {
    #if os(macOS)
    /// Pointer-sized rows keep the Mac detail header short enough to leave
    /// the backdrop and the seasons below it on the first screen.
    static let rowHeight: CGFloat = 38
    #else
    static let rowHeight: CGFloat = 44
    #endif
    static let iconWidth: CGFloat = 20
    static let iconSpacing: CGFloat = 10
    static let stackedLineSpacing: CGFloat = 4
    static let stackedVerticalPadding: CGFloat = 10
}

struct PhonePlaybackSelectorRow: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    /// The title's effective subtitle settings, for previewing what "Auto"
    /// plays. Off after the viewer picks Auto on the page: the title then
    /// inherits settings the page hasn't read yet, so the row says "Auto".
    var previewsAutoSubtitle = false
    var subtitleLanguage: String? = nil
    var subtitleMode: String? = nil
    var subtitleSignature: SubtitleTrackSignature? = nil
    var showForcedSubtitles = true
    let onSelectVersion: (Int?) -> Void
    /// Takes a `PlaybackEditions.Edition.id`; Version stays on Auto.
    let onSelectEdition: (String) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.detailSelectorPopover) private var selectorPopover
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The values come from `DetailPlaybackFormatting` as strings in the app
    /// language; reading the locale re-renders them when it changes.
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = PhonePlaybackSelectorMetrics.rowHeight
    @ScaledMetric(relativeTo: .footnote) private var iconWidth = PhonePlaybackSelectorMetrics.iconWidth
    @State private var activeSelector: PhonePlaybackSelectorKind?

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    var body: some View {
        let _ = locale
        if currentVersion != nil, !selectorKinds.isEmpty {
            #if os(iOS)
            if usesPopoverLayout {
                selectorCard
                    .popover(
                        item: $activeSelector,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: selectorPopover.arrowEdge
                    ) { kind in
                        selectorPresentation(for: kind)
                    }
            } else {
                selectorCard
                    .sheet(item: $activeSelector) { kind in
                        selectorPresentation(for: kind)
                    }
            }
            #else
            // Each row anchors its own drop-down; see `selectorButton`.
            selectorCard
            #endif
        }
    }

    /// The "Auto" preview, or nil for a bare "Auto". Also nil when the
    /// player follows the device's caption settings, which the detail page
    /// can't predict.
    private var subtitleAutoContext: DetailPlaybackFormatting.SubtitleAutoContext? {
        guard previewsAutoSubtitle,
              !PlayerSettings.shared.subtitleMatchesSystemAppearance else { return nil }
        return DetailPlaybackFormatting.SubtitleAutoContext(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            preferredLanguage: subtitleLanguage,
            mode: subtitleMode,
            signature: subtitleSignature,
            showForced: showForcedSubtitles
        )
    }

    private func selectorPresentation(
        for kind: PhonePlaybackSelectorKind
    ) -> PhonePlaybackSelectorSheet {
        PhonePlaybackSelectorSheet(
            kind: kind,
            versions: versions,
            currentVersion: currentVersion,
            selectedVersionFileId: selectedVersionFileId,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            popover: presentedPopover,
            onSelectVersion: onSelectVersion,
            onSelectEdition: onSelectEdition,
            onSelectAudioTrack: onSelectAudioTrack,
            onSelectSubtitleTrack: onSelectSubtitleTrack
        )
    }

    /// Nil when the selectors present a sheet.
    private var presentedPopover: DetailSelectorPopover? {
        #if os(iOS)
        usesPopoverLayout ? selectorPopover : nil
        #else
        nil
        #endif
    }

    private var usesPopoverLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && verticalSizeClass == .regular
        #else
        false
        #endif
    }

    /// Settings-style rows: icon and label lead, value trails, chevron last.
    /// Rows never truncate and grow to fit the edition selector. At
    /// accessibility text sizes the value moves under the label, where it
    /// has the card's full width instead of whatever the label leaves.
    private var selectorCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(selectorKinds.enumerated()), id: \.element.id) { index, kind in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, iconWidth + PhonePlaybackSelectorMetrics.iconSpacing)
                }

                selectorButton(kind) {
                    selectorRowContent(kind)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func selectorRowContent(_ kind: PhonePlaybackSelectorKind) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: PhonePlaybackSelectorMetrics.stackedLineSpacing) {
                HStack(spacing: PhonePlaybackSelectorMetrics.iconSpacing) {
                    selectorIcon(kind)
                    selectorTitle(kind)
                    Spacer(minLength: 12)
                    selectorChevron(kind)
                }
                selectorValue(kind)
                    .lineLimit(3)
            }
            .padding(.vertical, PhonePlaybackSelectorMetrics.stackedVerticalPadding)
        } else {
            HStack(spacing: PhonePlaybackSelectorMetrics.iconSpacing) {
                selectorIcon(kind)
                selectorTitle(kind)

                Spacer(minLength: 12)

                selectorValue(kind)
                    .lineLimit(1)
                    .truncationMode(.middle)

                selectorChevron(kind)
            }
        }
    }

    private func selectorIcon(_ kind: PhonePlaybackSelectorKind) -> some View {
        Image(systemName: kind.icon)
            .siloScaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
            .foregroundColor(.white.opacity(0.55))
            .frame(width: iconWidth, alignment: .leading)
    }

    private func selectorTitle(_ kind: PhonePlaybackSelectorKind) -> some View {
        Text(kind.title)
            .siloScaledFont(size: 14, weight: .medium, relativeTo: .subheadline)
            .foregroundColor(.white.opacity(0.72))
    }

    private func selectorValue(_ kind: PhonePlaybackSelectorKind) -> some View {
        Text(value(for: kind))
            .siloScaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
            .foregroundColor(.white)
    }

    /// Mac rows open a drop-down below them; elsewhere they open a sheet
    /// or popover.
    #if os(macOS)
    private static let chevronSymbol = "chevron.down"
    #else
    private static let chevronSymbol = "chevron.forward"
    #endif

    @ViewBuilder
    private func selectorChevron(_ kind: PhonePlaybackSelectorKind) -> some View {
        if isInteractive(kind) {
            Image(systemName: Self.chevronSymbol)
                .siloScaledFont(size: 11, weight: .bold, relativeTo: .caption2)
                .foregroundColor(.white.opacity(0.35))
        }
    }

    /// Wraps a layout's row/column in a button when that selector can
    /// actually be changed, and leaves it inert when it cannot.
    @ViewBuilder
    private func selectorButton<Content: View>(
        _ kind: PhonePlaybackSelectorKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isInteractive(kind) {
            Button { activeSelector = kind } label: { content() }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(kind.spokenLabel(value(for: kind))))
                #if os(macOS)
                .popover(isPresented: dropDownBinding(for: kind), arrowEdge: .bottom) {
                    selectorPresentation(for: kind)
                }
                #endif
        } else {
            content()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(kind.spokenLabel(value(for: kind))))
        }
    }

    #if os(macOS)
    /// Presents `kind`'s drop-down while it is the active selector.
    private func dropDownBinding(for kind: PhonePlaybackSelectorKind) -> Binding<Bool> {
        Binding(
            get: { activeSelector == kind },
            set: { isPresented in
                if !isPresented, activeSelector == kind { activeSelector = nil }
            }
        )
    }
    #endif

    private var selectorKinds: [PhonePlaybackSelectorKind] {
        var kinds: [PhonePlaybackSelectorKind] = []
        if shouldShowEditionSelector {
            kinds.append(.edition)
        }
        if shouldShowVersionValue {
            kinds.append(.version)
        }
        if shouldShowAudioValue {
            kinds.append(.audio)
        }
        if shouldShowSubtitleValue {
            kinds.append(.subtitles)
        }
        return kinds
    }

    private var shouldShowEditionSelector: Bool {
        editions.count > 1
    }

    private var shouldShowVersionValue: Bool {
        currentVersion != nil
    }

    private var shouldEnableVersionSelector: Bool {
        DetailPlaybackFormatting.shouldEnableVersionSelector(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    private var shouldShowAudioValue: Bool {
        DetailPlaybackFormatting.shouldShowAudioValue(version: currentVersion)
    }

    private var shouldEnableAudioSelector: Bool {
        DetailPlaybackFormatting.shouldEnableAudioSelector(version: currentVersion)
    }

    private var shouldShowSubtitleValue: Bool {
        DetailPlaybackFormatting.shouldShowSubtitleValue(version: currentVersion)
    }

    private var shouldEnableSubtitleSelector: Bool {
        DetailPlaybackFormatting.shouldEnableSubtitleSelector(version: currentVersion)
    }

    private func isInteractive(_ kind: PhonePlaybackSelectorKind) -> Bool {
        switch kind {
        case .edition:
            return shouldShowEditionSelector
        case .version:
            return shouldEnableVersionSelector
        case .audio:
            return shouldEnableAudioSelector
        case .subtitles:
            return shouldEnableSubtitleSelector
        }
    }

    private func value(for kind: PhonePlaybackSelectorKind) -> String {
        switch kind {
        case .edition:
            let label = DetailPlaybackFormatting.currentEdition(
                versions: versions,
                currentVersion: currentVersion
            )?.label ?? currentVersion?.editionDisplayLabel ?? PlaybackEditions.standardLabel
            return PlaybackEditions.displayLabel(label, locale: locale)
        case .version:
            return DetailPlaybackFormatting.versionShortLabel(currentVersion)
        case .audio:
            return DetailPlaybackFormatting.audioValueLabel(
                version: currentVersion,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            )
        case .subtitles:
            return DetailPlaybackFormatting.subtitleValueLabel(
                version: currentVersion,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                autoContext: subtitleAutoContext
            )
        }
    }
}
private struct PhonePlaybackSelectorSheet: View {
    let kind: PhonePlaybackSelectorKind
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    /// Nil when presented as a sheet.
    let popover: DetailSelectorPopover?
    let onSelectVersion: (Int?) -> Void
    let onSelectEdition: (String) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var preferredSubtitleLanguage: String?
    #if os(macOS)
    /// Height of the Mac drop-down's rows; nil until first measured.
    @State private var macRowsHeight: CGFloat?
    #endif

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    private var currentEdition: PlaybackEditions.Edition? {
        DetailPlaybackFormatting.currentEdition(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    var body: some View {
        #if os(iOS)
        if isCompactPopover {
            compactList
        } else {
            titledList
        }
        #else
        macDropDown
        #endif
    }

    #if os(macOS)
    private static let macDropDownWidth: CGFloat = 400
    private static let macMaxListHeight: CGFloat = 440
    /// Scroll target for the checked row. Optional to match the row's `id`.
    private static let selectedRowID: String? = "selected"

    /// The options, dropping down from the selector row. Choosing one, a
    /// click outside, or Escape closes it. A popover takes its content's
    /// ideal size, which a `List` barely has, so the rows sit in a measured
    /// scroll view: it grows to fit them up to `macMaxListHeight`, then
    /// scrolls, opening at the checked row like a pop-up menu.
    private var macDropDown: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    optionContent
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    macRowsHeight = $0
                }
            }
            .onChange(of: macRowsHeight != nil) {
                proxy.scrollTo(Self.selectedRowID, anchor: .center)
            }
        }
        .frame(width: Self.macDropDownWidth)
        .frame(height: macRowsHeight.map { min($0, Self.macMaxListHeight) })
        // The default glass takes on whatever is behind it, and the white
        // Play button just below the selectors washes out the rows.
        .presentationBackground(Color.siloSurfaceVariant.opacity(0.94))
        .task { await loadPreferredSubtitleLanguage() }
    }
    #endif

    #if os(iOS)
    /// Just the options, sized to fit and scrolling once they outgrow the
    /// space above the selectors. Choosing one or tapping outside dismisses.
    private var compactList: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            optionContent
        }
        .padding(.vertical, 6)
        return ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }
        }
        .frame(width: 300)
        .frame(maxHeight: 360)
        .task { await loadPreferredSubtitleLanguage() }
        .presentationCompactAdaptation(.popover)
    }
    #endif

    private var isCompactPopover: Bool {
        popover?.isCompact == true
    }

    private func loadPreferredSubtitleLanguage() async {
        await ProfilePrefsStore.shared.hydrateIfNeeded()
        preferredSubtitleLanguage = ProfilePrefsStore.shared.preferredSubtitleLanguage
    }

    #if os(iOS)
    private var titledList: some View {
        NavigationStack {
            List {
                optionContent
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .siloSheetBackground(legacyColor: .siloBackground)
            .task { await loadPreferredSubtitleLanguage() }
            .navigationTitle(Text(kind.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text(.commonDone) }
                        .tint(.siloOnSurface)
                }
            }
        }
        // Regular-width iPad uses this view as an anchored popover instead
        // of forcing a phone detent into the split-view detail column.
        .frame(
            width: popover == nil ? nil : 440,
            height: popover == nil ? nil : 480
        )
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

    @ViewBuilder
    private var optionContent: some View {
        switch kind {
        case .edition:
            editionOptions
        case .version:
            versionOptions
        case .audio:
            audioOptions
        case .subtitles:
            subtitleOptions
        }
    }

    @ViewBuilder
    private var editionOptions: some View {
        Section {
            if editions.isEmpty {
                optionButton(
                    title: AppLanguage.string(.detailEditionStandard, locale: locale),
                    detail: nil,
                    isSelected: true,
                    isEnabled: false
                ) {}
            } else {
                ForEach(editions) { edition in
                    optionButton(
                        title: PlaybackEditions.displayLabel(edition.label, locale: locale),
                        detail: AppLanguage.string(.detailEditionVersionCount(edition.versions.count), locale: locale),
                        isSelected: currentEdition?.id == edition.id
                    ) {
                        onSelectEdition(edition.id)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var versionOptions: some View {
        Section {
            optionButton(
                title: AppLanguage.string(.detailAuto, locale: locale),
                detail: AppLanguage.string(.detailAutoVersion, locale: locale),
                isSelected: selectedVersionFileId == nil
            ) {
                onSelectVersion(nil)
                dismiss()
            }
            ForEach(scopedVersions) { version in
                optionButton(
                    title: DetailPlaybackFormatting.versionPrimaryText(version),
                    detail: DetailPlaybackFormatting.versionSecondaryText(version),
                    isSelected: selectedVersionFileId == version.fileId
                ) {
                    onSelectVersion(version.fileId)
                    dismiss()
                }
            }
        }
    }

    private var scopedVersions: [FileVersion] {
        DetailPlaybackFormatting.versionSelectorVersions(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    @ViewBuilder
    private var audioOptions: some View {
        Section {
            optionButton(
                title: AppLanguage.string(.detailAuto, locale: locale),
                detail: AppLanguage.string(.detailPickerFileDefaultTrack, locale: locale),
                isSelected: selectedAudioTrackIndex == nil
            ) {
                onSelectAudioTrack(nil)
                dismiss()
            }
            let options = DetailPlaybackFormatting.audioOptions(
                version: currentVersion,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            )
            if options.isEmpty {
                optionButton(
                    title: AppLanguage.string(.detailUnknown, locale: locale),
                    detail: AppLanguage.string(.detailNoAudioMetadata, locale: locale),
                    isSelected: false,
                    isEnabled: false
                ) {}
            } else {
                ForEach(options) { option in
                    optionButton(
                        title: option.title,
                        detail: option.detail,
                        isSelected: selectedAudioTrackIndex == option.ordinal
                    ) {
                        onSelectAudioTrack(option.ordinal)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleOptions: some View {
        Section {
            optionButton(
                title: AppLanguage.string(.detailAuto, locale: locale),
                detail: AppLanguage.string(.detailAutoSubtitles, locale: locale),
                isSelected: selectedSubtitleTrackIndex == nil
            ) {
                onSelectSubtitleTrack(nil)
                dismiss()
            }
            optionButton(
                title: AppLanguage.string(.detailOff, locale: locale),
                detail: AppLanguage.string(.detailOffDetail, locale: locale),
                isSelected: selectedSubtitleTrackIndex == -1
            ) {
                onSelectSubtitleTrack(-1)
                dismiss()
            }
            ForEach(DetailPlaybackFormatting.subtitleOptions(
                version: currentVersion,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                preferredLanguage: preferredSubtitleLanguage
            )) { option in
                optionButton(
                    title: option.title,
                    detail: option.detail,
                    isSelected: option.isSelected,
                    isEnabled: option.isSelectable
                ) {
                    if let selectionIndex = option.selectionIndex {
                        onSelectSubtitleTrack(selectionIndex)
                        dismiss()
                    }
                }
            }
        }
    }

    private func optionButton(
        title: String,
        detail: String?,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .siloScaledFont(size: 16, weight: .semibold, relativeTo: .callout)
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.siloCaption)
                            .foregroundColor(.siloSecondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .siloScaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                        .foregroundColor(.siloOnSurface)
                }
            }
            #if os(macOS)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            #else
            .padding(.vertical, isCompactPopover ? 10 : 4)
            .padding(.horizontal, isCompactPopover ? 16 : 0)
            #endif
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(MacSelectorOptionButtonStyle())
        .id(isSelected ? Self.selectedRowID : nil)
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.56)
        .listRowBackground(Color.siloSurfaceVariant)
    }
}

#if os(macOS)
/// Highlights a Mac drop-down row under the pointer and while pressed.
private struct MacSelectorOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(highlightOpacity))
                )
                .onHover { isHovered = $0 }
        }

        private var highlightOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.14 }
            return isHovered ? 0.08 : 0
        }
    }
}
#endif
#endif
