import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SiloDownloadsActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadsLiveActivity()
    }
}

/// Renders the downloads Live Activity started by the host app's
/// `DownloadLiveActivityController`: a lock-screen card and the Dynamic
/// Island treatments. Tapping anywhere deep-links to the Downloads tab via
/// the `silo://downloads` route the app already handles.
struct DownloadsLiveActivity: Widget {
    private static let deepLink = URL(string: "silo://downloads")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadsLockScreenView(state: context.state, isStale: context.isStale)
                .padding(16)
                .appLanguage(context.state.language)
                // The extension has no accent asset, so `.tint` would fall
                // back to system blue; follow the lock screen's text color.
                .tint(.primary)
                .widgetURL(Self.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.symbolName)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.percentText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let line = context.state.contextLine {
                            line
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .appLanguage(context.state.language)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.fraction)
                            .progressViewStyle(.linear)
                            .tint(.white)
                        context.state.statusText(isStale: context.isStale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                    .appLanguage(context.state.language)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbolName)
                    .foregroundStyle(.white)
            } compactTrailing: {
                ProgressView(value: context.state.fraction)
                    .progressViewStyle(.circular)
                    .tint(.white)
            } minimal: {
                ProgressView(value: context.state.fraction)
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
            .widgetURL(Self.deepLink)
        }
    }
}

private struct DownloadsLockScreenView: View {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: state.phase.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let line = state.contextLine {
                        line
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if state.phase != .completed {
                    Text(state.percentText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if state.phase != .completed {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.linear)
                state.statusText(isStale: isStale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private extension DownloadActivityAttributes.ContentState.Phase {
    var symbolName: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .preparing: return "clock.arrow.circlepath"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

private extension View {
    /// Shows the catalog text below in the app's language, which the app
    /// passes in the content state; the system language when it hasn't.
    @ViewBuilder
    func appLanguage(_ tag: String?) -> some View {
        if let tag {
            environment(\.locale, Locale(identifier: tag))
        } else {
            self
        }
    }
}

private extension DownloadActivityAttributes.ContentState {
    var percentText: String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Secondary line under the title: item context plus queue position,
    /// e.g. "Severance · S1 · E4 · 2 of 5".
    var contextLine: Text? {
        guard totalCount > 1, phase != .completed else {
            return subtitle.map { Text(verbatim: $0) }
        }
        let current = "\(min(completedCount + 1, totalCount))"
        let total = "\(totalCount)"
        guard let subtitle else { return Text(.downloadsActivityPosition(current, total)) }
        return Text(.downloadsActivityContextPosition(subtitle, current, total))
    }

    func statusText(isStale: Bool) -> Text {
        switch phase {
        case .completed:
            return Text(.downloadsActivityComplete)
        case .paused:
            return Text(.downloadsStatusPaused)
        case .preparing:
            return Text(.downloadsStatusPreparing)
        case .downloading:
            // Past the stale date the app was suspended mid-transfer and
            // these numbers stopped ticking; say so instead of freezing a
            // live-looking counter.
            if isStale { return Text(.downloadsActivityContinuingInBackground) }
            guard bytesExpected > 0 else { return Text(.downloadsActivityDownloading) }
            let downloaded = bytesDownloaded.formatted(.byteCount(style: .file))
            let expected = bytesExpected.formatted(.byteCount(style: .file))
            guard let bytesPerSecond, bytesPerSecond > 0 else {
                return Text(.downloadsActivityBytes(downloaded, expected))
            }
            let rate = Int64(bytesPerSecond).formatted(.byteCount(style: .file)) + "/s"
            return Text(.downloadsActivityBytesRate(downloaded, expected, rate))
        }
    }
}
