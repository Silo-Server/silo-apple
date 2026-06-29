//
//  SubtitleTranslateMenu.swift
//  Continuum (iOS + tvOS)
//
//  In-player "AI subtitles" menu: translate an existing text subtitle track,
//  transcribe an audio track (Whisper), or transcribe-and-translate. Presented
//  from ``TrackSelectionSheet`` and gated on the server's AI capabilities.
//
//  Drives ``PlayerViewModel/subtitleAI`` (a ``SubtitleAIController``), which
//  runs the job over polling (Milestone 3) and hands the completed track back
//  through the normal sidecar path so it appears in the picker and auto-selects.
//
//  Two-platform split mirrors ``TrackSelectionSheet``: iOS renders a sectioned
//  `List`; tvOS renders a centered floating panel with the same chrome and the
//  same `onExitCommand` / backdrop-tap dismissal. The row-builders are shared;
//  only the container + row view differ by platform.
//
//  Source resolution:
//    - Translate: a text subtitle track's combined index is `track.srcId`
//      (== `subtitle_urls[].index`). Embedded-text translation is out of scope
//      for v1, so only tracks with a resolvable `srcId` offer "Translate".
//    - Bitmap subs (PGS / DVD / DVB / VobSub, detected via `track.codec`)
//      cannot be translated → they offer "Transcribe" of the audio instead.
//    - Transcribe: the source index is the *audio* track index (`-1` = default).
//

import SwiftUI

struct SubtitleTranslateMenu: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    /// Which step of the menu is showing.
    private enum Stage: Equatable {
        case chooseSource
        case chooseTarget(PendingAction)
    }

    /// A source the user picked that still needs a target language.
    private enum PendingAction: Equatable {
        /// Translate this text subtitle track (carries its own `srcId`).
        case translateSubtitle(PlayerTrack)
        /// Transcribe-and-translate this audio track index (`-1` = default).
        case transcribeAndTranslate(audioIndex: Int)
    }

    @State private var stage: Stage = .chooseSource

    /// Codecs the server treats as bitmap subtitles (cannot be AI-translated).
    /// Mirrors `ApplePlaybackRoutePlanner.siloBitmapSubtitleCodecs`.
    private static let bitmapSubtitleCodecs: Set<String> = [
        "pgs", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "dvb_subtitle", "vobsub"
    ]

    private var controller: SubtitleAIController { viewModel.subtitleAI }

    private static func isBitmap(_ track: PlayerTrack) -> Bool {
        guard let codec = track.codec?.lowercased(), !codec.isEmpty else { return false }
        if bitmapSubtitleCodecs.contains(codec) { return true }
        // Tolerant substring match — codec strings vary across demuxers
        // (e.g. "hdmv_pgs_subtitle", "dvb_subtitle (dvbsub)").
        return codec.contains("pgs") || codec.contains("dvdsub")
            || codec.contains("dvd_sub") || codec.contains("dvbsub")
            || codec.contains("dvb_sub") || codec.contains("vobsub")
    }

    /// Text subtitle tracks with a resolvable combined index — the only ones
    /// that can be AI-translated in v1.
    private var translatableSubtitleTracks: [PlayerTrack] {
        viewModel.subtitleTracks.filter { !Self.isBitmap($0) && $0.srcId != nil }
    }

    /// Bitmap subtitle tracks — offered "Transcribe" instead of "Translate".
    private var bitmapSubtitleTracks: [PlayerTrack] {
        viewModel.subtitleTracks.filter { Self.isBitmap($0) }
    }

    private var capabilities: AICapabilities { .shared }

    var body: some View {
        #if os(tvOS)
        tvOSPanel
        #else
        phoneList
        #endif
    }

    // MARK: - Shared content

    /// True while a job is in flight — the menu collapses to a progress view.
    private var isBusy: Bool { controller.isBusy }

    private var title: String {
        switch stage {
        case .chooseSource: return "AI Subtitles"
        case .chooseTarget: return "Translate Into"
        }
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSPanel: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    if case .chooseTarget = stage {
                        Button {
                            stage = .chooseSource
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    Text(title.uppercased())
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 12)

                if isBusy || controller.phase == .failed {
                    progressPanel
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            stageContent
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, maxHeight: 720)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .onExitCommand {
            if case .chooseTarget = stage { stage = .chooseSource }
            else { onDismiss() }
        }
        .task { await controller.refreshQuota() }
        .onChange(of: controller.phase) { _, newPhase in
            // Auto-dismiss once the handoff is done — the completed track is
            // now in the picker and selected. Attached to the always-mounted
            // root so it fires even as the progress panel is torn down.
            if newPhase == .completed { onDismiss() }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .chooseSource:
            sourceRows
        case .chooseTarget(let action):
            targetRows(for: action)
        }
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneList: some View {
        NavigationStack {
            Group {
                if isBusy || controller.phase == .failed {
                    progressPanel
                } else {
                    List {
                        switch stage {
                        case .chooseSource:
                            sourceSections
                        case .chooseTarget(let action):
                            Section {
                                targetRows(for: action)
                            } header: {
                                Text("Translate Into")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .chooseTarget = stage {
                        Button("Back") { stage = .chooseSource }
                    } else {
                        Button("Done") { onDismiss() }
                    }
                }
            }
            .task { await controller.refreshQuota() }
            .onChange(of: controller.phase) { _, newPhase in
                // Auto-dismiss once the handoff is done — the completed track
                // is now in the picker and selected.
                if newPhase == .completed { onDismiss() }
            }
        }
    }

    @ViewBuilder
    private var sourceSections: some View {
        if capabilities.subtitleEnabled, !translatableSubtitleTracks.isEmpty {
            Section("Translate Subtitles") {
                ForEach(translatableSubtitleTracks) { track in
                    MenuRow(
                        name: track.primaryLabel,
                        detail: track.attributesLabel,
                        systemImage: "character.bubble"
                    ) {
                        beginTranslate(track)
                    }
                }
            }
        }

        if capabilities.transcribeEnabled, !bitmapSubtitleTracks.isEmpty {
            Section {
                ForEach(bitmapSubtitleTracks) { track in
                    MenuRow(
                        name: track.primaryLabel,
                        detail: bitmapDetail(track),
                        systemImage: "waveform"
                    ) {
                        beginTranscribe()
                    }
                }
            } header: {
                Text("Image Subtitles")
            } footer: {
                Text("Image-based subtitles can't be translated. Transcribe the audio instead.")
            }
        }

        if capabilities.transcribeEnabled, !viewModel.audioTracks.isEmpty {
            Section {
                quotaRow
                MenuRow(
                    name: "Transcribe Audio",
                    detail: transcribeDetail,
                    systemImage: "waveform",
                    isDisabled: isQuotaExhausted
                ) {
                    beginTranscribe()
                }
                MenuRow(
                    name: "Transcribe & Translate",
                    detail: "Generate captions, then translate them.",
                    systemImage: "captions.bubble",
                    isDisabled: isQuotaExhausted
                ) {
                    beginTranscribeAndTranslate()
                }
            } header: {
                Text("Transcribe")
            }
        }
    }
    #endif

    // MARK: - Shared row builders (tvOS uses these directly)

    @ViewBuilder
    private var sourceRows: some View {
        if capabilities.subtitleEnabled, !translatableSubtitleTracks.isEmpty {
            sectionHeader("Translate Subtitles")
            ForEach(translatableSubtitleTracks) { track in
                MenuRow(
                    name: track.primaryLabel,
                    detail: track.attributesLabel,
                    systemImage: "character.bubble"
                ) {
                    beginTranslate(track)
                }
            }
        }

        if capabilities.transcribeEnabled, !bitmapSubtitleTracks.isEmpty {
            sectionHeader("Image Subtitles")
            ForEach(bitmapSubtitleTracks) { track in
                MenuRow(
                    name: track.primaryLabel,
                    detail: bitmapDetail(track),
                    systemImage: "waveform"
                ) {
                    beginTranscribe()
                }
            }
        }

        if capabilities.transcribeEnabled, !viewModel.audioTracks.isEmpty {
            sectionHeader("Transcribe")
            quotaRow
            MenuRow(
                name: "Transcribe Audio",
                detail: transcribeDetail,
                systemImage: "waveform",
                isDisabled: isQuotaExhausted
            ) {
                beginTranscribe()
            }
            MenuRow(
                name: "Transcribe & Translate",
                detail: "Generate captions, then translate them.",
                systemImage: "captions.bubble",
                isDisabled: isQuotaExhausted
            ) {
                beginTranscribeAndTranslate()
            }
        }
    }

    @ViewBuilder
    private func targetRows(for action: PendingAction) -> some View {
        ForEach(PlaybackLanguageOption.all) { option in
            MenuRow(
                name: option.label,
                detail: nil,
                systemImage: "globe"
            ) {
                commit(action, target: option.code)
            }
        }
    }

    // MARK: - Progress / failure panel

    @ViewBuilder
    private var progressPanel: some View {
        let job = controller.activeJob
        VStack(alignment: .leading, spacing: 16) {
            if controller.phase == .failed {
                Label(controller.errorMessage ?? "Subtitle translation failed.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                progressButton(title: "Dismiss") { onDismiss() }
            } else {
                Text(progressTitle(for: job))
                    .font(.headline)
                ProgressView(value: clampedProgress(job))
                    .progressViewStyle(.linear)
                if let message = job?.progressMessage, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                progressButton(title: "Cancel") {
                    controller.cancelActiveJob()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressTitle(for job: SubtitleJob?) -> String {
        switch job?.kind {
        case .transcribe: return "Transcribing audio…"
        case .transcribeTranslate: return "Transcribing & translating…"
        case .translate, .none: return "Translating subtitles…"
        }
    }

    private func clampedProgress(_ job: SubtitleJob?) -> Double {
        guard let p = job?.progress else { return 0 }
        return min(max(p, 0), 1)
    }

    // MARK: - Quota gauge

    private var isQuotaExhausted: Bool {
        guard let quota = controller.quota, quota.limited else { return false }
        if let remaining = quota.remaining { return remaining <= 0 }
        return false
    }

    private var quotaText: String? {
        guard let quota = controller.quota, quota.limited else { return nil }
        let used = quota.used ?? 0
        if let limit = quota.limit {
            let period = quota.period.map { " / \($0)" } ?? ""
            return "\(used) of \(limit) used\(period)"
        }
        if let remaining = quota.remaining {
            return "\(remaining) remaining"
        }
        return nil
    }

    // MARK: - Actions

    private func beginTranslate(_ track: PlayerTrack) {
        guard track.srcId != nil else { return }
        stage = .chooseTarget(.translateSubtitle(track))
    }

    private func beginTranscribe() {
        // Transcribe the default audio track (`-1`). The server picks the
        // active audio stream; offering a per-audio-track picker is deferred.
        viewModel.startSubtitleTranscription(audioIndex: -1, translateTo: nil)
    }

    private func beginTranscribeAndTranslate() {
        stage = .chooseTarget(.transcribeAndTranslate(audioIndex: -1))
    }

    private func commit(_ action: PendingAction, target: String) {
        switch action {
        case .translateSubtitle(let track):
            viewModel.startSubtitleTranslation(track: track, to: target)
        case .transcribeAndTranslate(let audioIndex):
            viewModel.startSubtitleTranscription(audioIndex: audioIndex, translateTo: target)
        }
    }

    // MARK: - Detail strings

    private func bitmapDetail(_ track: PlayerTrack) -> String? {
        track.attributesLabel
    }

    private var transcribeDetail: String? {
        "Generate captions from the spoken audio."
    }
}

// MARK: - Section header (tvOS inline) + quota row

private extension SubtitleTranslateMenu {
    @ViewBuilder
    func sectionHeader(_ text: String) -> some View {
        #if os(tvOS)
        Text(text.uppercased())
            .font(.system(size: 14, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.top, 10)
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    var quotaRow: some View {
        if let quotaText {
            #if os(tvOS)
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.white.opacity(0.5))
                Text(quotaText)
                    .font(.system(size: 16))
                    .foregroundStyle(isQuotaExhausted ? Color.continuumWarning : .white.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            #else
            HStack {
                Label("Transcription quota", systemImage: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(quotaText)
                    .foregroundStyle(isQuotaExhausted ? Color.continuumWarning : .secondary)
            }
            .font(.footnote)
            #endif
        }
    }

    @ViewBuilder
    func progressButton(title: String, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(title, action: action)
            .buttonStyle(.bordered)
        #else
        Button(title, action: action)
            .buttonStyle(.bordered)
        #endif
    }
}

// MARK: - Menu row (platform-split, mirroring TrackSelectionSheet.TrackRow)

#if os(tvOS)
/// tvOS menu row: icon + two lines, row-fill focus highlight, bare
/// `.focusable` + tap (no system halo), matching `TrackSelectionSheet`.
private struct MenuRow: View {
    let name: String
    let detail: String?
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .focusable(!isDisabled)
        .focused($isFocused)
        .onTapGesture(perform: action)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name)
    }
}
#else
/// iOS menu row: standard List row with a leading icon and a chevron.
private struct MenuRow: View {
    let name: String
    let detail: String?
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .disabled(isDisabled)
    }
}
#endif
