#if os(macOS)
import AppKit
import SwiftUI

struct MacPlayerCommandCapture: NSViewRepresentable {
    let onCommand: (MacPlayerCommand) -> Void

    func makeNSView(context: Context) -> CommandCaptureView {
        let view = CommandCaptureView()
        view.onCommand = onCommand
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: CommandCaptureView, context: Context) {
        nsView.onCommand = onCommand
        DispatchQueue.main.async {
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

enum MacPlayerCommand {
    case playPause
    case skipBackward
    case skipForward
    case previousChapter
    case nextChapter
    case cycleAudio
    case cycleSubtitle
    case toggleSubtitle
    case options
    case escape
    case confirm
    case speedDown
    case speedUp
    case normalSpeed
}

final class CommandCaptureView: NSView {
    var onCommand: ((MacPlayerCommand) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let command = command(for: event) else {
            super.keyDown(with: event)
            return
        }
        onCommand?(command)
    }

    private func command(for event: NSEvent) -> MacPlayerCommand? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option])
        switch event.keyCode {
        case 49:
            return .playPause
        case 53:
            return .escape
        case 36, 76:
            return .confirm
        case 123:
            return modifiers.contains(.command) ? .previousChapter : .skipBackward
        case 124:
            return modifiers.contains(.command) ? .nextChapter : .skipForward
        default:
            break
        }

        let character = event.charactersIgnoringModifiers?.lowercased()
        switch character {
        case "a" where modifiers.contains(.control) && modifiers.contains(.command):
            return .cycleAudio
        case "s" where modifiers.contains(.control) && modifiers.contains(.command):
            return .cycleSubtitle
        case "g" where modifiers.contains(.control) && modifiers.contains(.command):
            return .toggleSubtitle
        case "s" where modifiers.contains(.command):
            return .options
        case "[" where modifiers.contains(.shift) && modifiers.contains(.command):
            return .normalSpeed
        case "[" where modifiers.contains(.shift):
            return .speedDown
        case "]" where modifiers.contains(.shift):
            return .speedUp
        default:
            return nil
        }
    }
}
#endif
