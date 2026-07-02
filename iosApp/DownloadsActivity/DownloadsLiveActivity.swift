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
/// the `continuum://downloads` route the app already handles.
struct DownloadsLiveActivity: Widget {
    private static let deepLink = URL(string: "continuum://downloads")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadsLockScreenView(state: context.state, isStale: context.isStale)
                .padding(16)
                .widgetURL(Self.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.symbolName)
                        .font(.title2)
                        .foregroundStyle(.tint)
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
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.fraction)
                            .progressViewStyle(.linear)
                        Text(context.state.statusText(isStale: context.isStale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbolName)
                    .foregroundStyle(.tint)
            } compactTrailing: {
                ProgressView(value: context.state.fraction)
                    .progressViewStyle(.circular)
                    .tint(.blue)
            } minimal: {
                ProgressView(value: context.state.fraction)
                    .progressViewStyle(.circular)
                    .tint(.blue)
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
                        Text(line)
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
                Text(state.statusText(isStale: isStale))
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

private extension DownloadActivityAttributes.ContentState {
    var percentText: String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Secondary line under the title: item context plus queue position,
    /// e.g. "Severance · S1 · E4 · 2 of 5".
    var contextLine: String? {
        var parts: [String] = []
        if let subtitle { parts.append(subtitle) }
        if totalCount > 1, phase != .completed {
            parts.append("\(min(completedCount + 1, totalCount)) of \(totalCount)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func statusText(isStale: Bool) -> String {
        switch phase {
        case .completed:
            return "Complete"
        case .paused:
            return "Paused"
        case .preparing:
            return "Preparing…"
        case .downloading:
            // Past the stale date the app was suspended mid-transfer and
            // these numbers stopped ticking; say so instead of freezing a
            // live-looking counter.
            if isStale { return "Continuing in background…" }
            guard bytesExpected > 0 else { return "Downloading…" }
            var text = bytesDownloaded.formatted(.byteCount(style: .file))
                + " of "
                + bytesExpected.formatted(.byteCount(style: .file))
            if let bytesPerSecond, bytesPerSecond > 0 {
                text += " · " + Int64(bytesPerSecond).formatted(.byteCount(style: .file)) + "/s"
            }
            return text
        }
    }
}
