#if os(macOS)
import AppKit
import SwiftUI

/// The player's keyboard shortcuts, for the player's window whatever has
/// focus in it. A text field that is editing keeps its keys.
///
/// A window-scoped monitor rather than a first responder: a control the
/// viewer clicked or tabbed to would otherwise take Space and the arrows
/// until something took focus back.
struct MacPlayerKeyMonitor: NSViewRepresentable {
    /// Off while a player menu is open: the menu takes the keys.
    let isEnabled: Bool
    let onCommand: (MacPlayerCommand) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onCommand = onCommand
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var isEnabled = true
        var onCommand: (MacPlayerCommand) -> Void = { _ in }
        private var monitor: MacLocalEventMonitor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = MacLocalEventMonitor(matching: .keyDown) { [weak self] event in
                guard let self, let command = self.command(for: event) else { return event }
                // Holding a key repeats seeks and speed steps; a held toggle
                // acts once.
                if !event.isARepeat || command.repeatsWhileHeld {
                    self.onCommand(command)
                }
                return nil
            }
        }

        func stopMonitoring() {
            monitor?.stop()
            monitor = nil
        }

        private func command(for event: NSEvent) -> MacPlayerCommand? {
            guard isEnabled, let window, event.window === window,
                  !(window.firstResponder is NSText) else { return nil }
            return MacPlayerCommand(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            )
        }
    }
}

enum MacPlayerCommand: Equatable {
    case playPause
    case skipBackward
    case skipForward
    case previousChapter
    case nextChapter
    case cycleAudio
    case cycleSubtitle
    case toggleSubtitle
    case trackMenu
    case playbackInfo
    case toggleFullScreen
    case escape
    case confirm
    case speedDown
    case speedUp
    case normalSpeed
    case volumeUp
    case volumeDown
    case toggleMute

    var repeatsWhileHeld: Bool {
        switch self {
        case .skipBackward, .skipForward, .previousChapter, .nextChapter, .speedDown, .speedUp,
             .volumeUp, .volumeDown:
            return true
        default:
            return false
        }
    }

    private enum KeyCode {
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    /// The command for a key press, or nil for a key the player leaves
    /// alone. Letters and brackets match by character so they follow the
    /// keyboard layout; Shift turns `[` into `{` on most layouts, so both
    /// count.
    init?(keyCode: UInt16, characters: String?, modifiers rawModifiers: NSEvent.ModifierFlags) {
        let modifiers = rawModifiers.intersection([.command, .control, .option, .shift])
        switch (keyCode, modifiers) {
        case (KeyCode.space, []): self = .playPause; return
        case (KeyCode.escape, []): self = .escape; return
        case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []): self = .confirm; return
        case (KeyCode.leftArrow, []): self = .skipBackward; return
        case (KeyCode.rightArrow, []): self = .skipForward; return
        case (KeyCode.upArrow, []): self = .volumeUp; return
        case (KeyCode.downArrow, []): self = .volumeDown; return
        case (KeyCode.leftArrow, .command): self = .previousChapter; return
        case (KeyCode.rightArrow, .command): self = .nextChapter; return
        default: break
        }

        switch (characters?.lowercased(), modifiers) {
        case ("a", [.control, .command]): self = .cycleAudio
        case ("s", [.control, .command]): self = .cycleSubtitle
        case ("g", [.control, .command]): self = .toggleSubtitle
        case ("s", .command): self = .trackMenu
        case ("i", .command): self = .playbackInfo
        case ("f", []): self = .toggleFullScreen
        case ("m", []): self = .toggleMute
        case ("[", .shift), ("{", .shift): self = .speedDown
        case ("]", .shift), ("}", .shift): self = .speedUp
        case ("[", [.shift, .command]), ("{", [.shift, .command]): self = .normalSpeed
        default: return nil
        }
    }
}
#endif
