#if os(macOS)
import AppKit
import SwiftUI

/// The control bar's pop-up menus.
enum MacPlayerMenu {
    /// Audio and subtitle tracks, and subtitle timing.
    case tracks
    case chapters
    case quality
    case speed
}

/// One row of a player pop-up menu.
enum MacMenuEntry {
    case header(String)
    case separator
    case item(MacMenuItem)
}

struct MacMenuItem {
    var title: String
    /// A smaller second line under the title.
    var subtitle: String?
    /// Secondary text aligned to the menu's trailing edge, such as a time.
    var trailing: String?
    var isChecked = false
    var isEnabled = true
    var action: () -> Void = {}
}

/// Where a player menu opens from: a view behind its control-bar button.
/// The screen owns one per menu, so a menu can also open from the keyboard.
@MainActor
final class MacMenuAnchor {
    fileprivate weak var view: NSView?

    /// Opens `entries` as a native menu just above the control and returns
    /// once it closes. False when the control isn't in a window.
    @discardableResult
    func popUp(_ entries: [MacMenuEntry]) -> Bool {
        guard let view, view.window != nil else { return false }
        let menu = MacMenuEntry.menu(for: entries)
        // The player is always dark, whatever the system appearance.
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.minimumWidth = max(view.bounds.width, 220)
        // The menu hangs down from its top-left corner; put that corner far
        // enough above the button for the whole menu to clear it. AppKit
        // moves the menu down if the screen has no room above.
        let gap: CGFloat = 6
        let top = view.isFlipped ? -gap - menu.size.height : view.bounds.maxY + gap + menu.size.height
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: top), in: view)
        return true
    }
}

/// The menu anchors for one player screen.
@MainActor
final class MacPlayerMenuAnchors {
    private var anchors: [MacPlayerMenu: MacMenuAnchor] = [:]

    subscript(menu: MacPlayerMenu) -> MacMenuAnchor {
        if let anchor = anchors[menu] { return anchor }
        let anchor = MacMenuAnchor()
        anchors[menu] = anchor
        return anchor
    }
}

extension View {
    /// Makes this view the place `anchor`'s menu opens from.
    func macMenuAnchor(_ anchor: MacMenuAnchor) -> some View {
        background(MacMenuAnchorView(anchor: anchor))
    }
}

private struct MacMenuAnchorView: NSViewRepresentable {
    let anchor: MacMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Building the menu

extension MacMenuEntry {
    @MainActor
    static func menu(for entries: [MacMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let trailingTab = trailingTabLocation(for: entries)
        for entry in entries {
            switch entry {
            case .header(let title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                menu.addItem(menuItem(for: item, trailingTab: trailingTab))
            }
        }
        return menu
    }

    @MainActor
    private static func menuItem(for item: MacMenuItem, trailingTab: CGFloat) -> NSMenuItem {
        let action = MacMenuAction(item.action)
        let menuItem = NSMenuItem(title: item.title, action: #selector(MacMenuAction.perform(_:)), keyEquivalent: "")
        menuItem.target = action
        // The item holds its action: `target` is weak.
        menuItem.representedObject = action
        menuItem.state = item.isChecked ? .on : .off
        menuItem.isEnabled = item.isEnabled
        menuItem.subtitle = item.subtitle
        if let trailing = item.trailing {
            menuItem.attributedTitle = attributedTitle(
                item.title,
                trailing: trailing,
                isEnabled: item.isEnabled,
                tab: trailingTab
            )
        }
        return menuItem
    }

    /// The title with `trailing` right-aligned at `tab`, in the menu font.
    /// An attributed title draws its colors as given, so a disabled one is
    /// dimmed here.
    private static func attributedTitle(_ title: String, trailing: String, isEnabled: Bool, tab: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: menuFont,
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph,
        ])
        text.append(NSAttributedString(string: "\t\(trailing)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize, weight: .regular),
            .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph,
        ]))
        return text
    }

    private static var menuFont: NSFont { NSFont.menuFont(ofSize: 0) }

    /// Far enough right for the widest title and the widest trailing text
    /// to sit apart.
    private static func trailingTabLocation(for entries: [MacMenuEntry]) -> CGFloat {
        let items = entries.compactMap { entry -> MacMenuItem? in
            if case .item(let item) = entry, item.trailing != nil { return item }
            return nil
        }
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: menuFont]).width
        }
        let titleWidth = items.map { width($0.title) }.max() ?? 0
        let trailingWidth = items.compactMap(\.trailing).map(width).max() ?? 0
        return ceil(titleWidth + 32 + trailingWidth)
    }
}

/// An NSMenuItem target that runs a closure.
private final class MacMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func perform(_ sender: NSMenuItem) {
        handler()
    }
}

// MARK: - Menu contents

@MainActor
enum MacPlayerMenuContent {
    static let playbackSpeeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func entries(for menu: MacPlayerMenu, viewModel: PlayerViewModel) -> [MacMenuEntry] {
        switch menu {
        case .tracks: return tracks(viewModel)
        case .chapters: return chapters(viewModel)
        case .quality: return quality(viewModel)
        case .speed: return speed(viewModel)
        }
    }

    /// Audio, then subtitles, then the selected subtitle's timing actions,
    /// as the TV app's audio and subtitles menu lays them out. Track details
    /// sit in a trailing column, so a file with dozens of subtitles still
    /// gets one line per track.
    private static func tracks(_ viewModel: PlayerViewModel) -> [MacMenuEntry] {
        var entries: [MacMenuEntry] = []
        if !viewModel.audioTracks.isEmpty {
            entries.append(.header("Audio"))
            for track in viewModel.audioTracks {
                entries.append(.item(MacMenuItem(
                    title: track.primaryLabel,
                    trailing: track.attributesLabel?.nilIfEmpty,
                    isChecked: viewModel.selectedAudioId == track.trackId,
                    action: { viewModel.selectAudio(track) }
                )))
            }
            entries.append(.separator)
        }

        entries.append(.header("Subtitles"))
        entries.append(.item(MacMenuItem(
            title: "Off",
            isChecked: viewModel.selectedSubtitleId == nil,
            action: { viewModel.disableSubtitles() }
        )))
        for track in viewModel.orderedSubtitleTracks {
            entries.append(.item(MacMenuItem(
                title: track.primaryLabel,
                trailing: subtitleDetail(for: track, viewModel: viewModel),
                isChecked: viewModel.selectedSubtitleId == track.trackId,
                isEnabled: !track.hasUnsupportedFormat,
                action: { viewModel.selectSubtitle(track) }
            )))
        }

        entries.append(contentsOf: timing(viewModel))
        return entries
    }

    private static func subtitleDetail(for track: PlayerTrack, viewModel: PlayerViewModel) -> String? {
        var parts: [String] = []
        if let attributes = track.attributesLabel, !attributes.isEmpty {
            parts.append(attributes)
        }
        // The attributes already end with "External" for a sidecar.
        if !track.isExternal {
            parts.append("Embedded")
        }
        if track.hasUnsupportedFormat {
            parts.append(PlayerTrack.unsupportedFormatLabel)
        } else if let status = viewModel.subtitleSyncStatus(for: track) {
            parts.append(status)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Sync to Audio" and "Reset Timing" for the selected subtitle, stored
    /// or a file next to the media. A running sync's progress and its
    /// outcome show in the sync card at the top of the player; a refusal
    /// (demo mode) replaces the actions with its explanation.
    private static func timing(_ viewModel: PlayerViewModel) -> [MacMenuEntry] {
        let sync = viewModel.subtitleSync
        guard let key = viewModel.selectedSubtitleSyncKey,
              let entry = sync.entry(for: key),
              sync.showsTimingControls(entry) else { return [] }

        var entries: [MacMenuEntry] = [.separator, .header("Timing")]
        if entry.isForbidden {
            entries.append(.item(MacMenuItem(
                title: "Sync to Audio",
                subtitle: sync.forbiddenMessage,
                isEnabled: false
            )))
            return entries
        }

        let isIdle = !entry.isBusy && !entry.isInProgress
        if sync.canSync(entry) {
            entries.append(.item(MacMenuItem(
                title: entry.isInProgress ? "Syncing to Audio…" : "Sync to Audio",
                subtitle: entry.error ?? entry.result?.text ?? (entry.isInProgress ? nil : entry.actionNote),
                isEnabled: isIdle,
                action: { Task { await sync.requestSync(key: key) } }
            )))
        }
        if entry.canReset {
            entries.append(.item(MacMenuItem(
                title: "Reset Timing",
                isEnabled: isIdle,
                action: { Task { await sync.resetTiming(key: key) } }
            )))
        }
        return entries
    }

    private static func chapters(_ viewModel: PlayerViewModel) -> [MacMenuEntry] {
        let current = viewModel.chapters.lastIndex { $0.time <= viewModel.currentTime }
        return viewModel.chapters.map { chapter in
            .item(MacMenuItem(
                title: chapter.title?.nilIfEmpty ?? "Chapter \(chapter.index + 1)",
                trailing: PlayerTimeFormatter.formatHMS(chapter.time),
                isChecked: chapter.index == current,
                action: { viewModel.jumpToChapter(at: chapter.time) }
            ))
        }
    }

    /// The same plan-built list iOS and tvOS offer: Auto, then each server
    /// rung in plan order. A second pick during a replan is refused as busy,
    /// so the rungs wait while one runs.
    private static func quality(_ viewModel: PlayerViewModel) -> [MacMenuEntry] {
        var entries: [MacMenuEntry] = []
        if viewModel.isQualitySwitching {
            entries.append(.header("Switching Quality…"))
        }
        for option in viewModel.qualityOptions {
            entries.append(.item(MacMenuItem(
                title: option.label,
                trailing: option.bitrateText,
                isChecked: option.id == viewModel.highlightedQualityOptionId,
                isEnabled: !viewModel.isQualitySwitching,
                action: { viewModel.switchQuality(option.id) }
            )))
        }
        if !viewModel.isQualitySwitching, let error = viewModel.qualitySwitchError {
            entries.append(.separator)
            entries.append(.item(MacMenuItem(title: error, isEnabled: false)))
        }
        return entries
    }

    private static func speed(_ viewModel: PlayerViewModel) -> [MacMenuEntry] {
        let current = viewModel.settings.playbackSpeed
        return [.header("Playback Speed")] + playbackSpeeds.map { speed in
            .item(MacMenuItem(
                title: speedLabel(speed, normal: "Normal"),
                isChecked: abs(current - speed) < 0.01,
                action: { viewModel.setPlaybackSpeed(speed) }
            ))
        }
    }

    /// "0.5×", "1.25×", "2×"; `normal` for 1×.
    static func speedLabel(_ speed: Double, normal: String = "1×") -> String {
        if abs(speed - 1.0) < 0.01 { return LocaleFormat.localized(normal) }
        return LocaleFormat.localized(String(format: "%g×", speed))
    }

    /// The speed one step slower (`offset` -1) or faster (+1) than `current`
    /// in the menu's list, held at its ends.
    static func adjacentSpeed(to current: Double, offset: Int) -> Double {
        let index = playbackSpeeds.indices.min { abs(playbackSpeeds[$0] - current) < abs(playbackSpeeds[$1] - current) } ?? 2
        return playbackSpeeds[max(0, min(playbackSpeeds.count - 1, index + offset))]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
