#if os(iOS)
import OSLog
import UIKit

nonisolated struct IMEProxySnapshot: Equatable, Sendable {
    var text: String
    var selectedRange: NSRange
    var markedRange: NSRange?
}

/// Replaces the software keyboard while the terminal keeps first-responder
/// ownership for hardware input. Let UIKit negotiate the host height through
/// UIInputView's self-sizing contract instead of installing a required
/// zero-height constraint that conflicts with InputUI's own inputHeight
/// constraint during iPad responder handoffs.
final class TerminalSuppressedKeyboardInputView: UIInputView {
    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        .zero
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        .zero
    }
}

enum TerminalEditMenuPresentation {
    case selection
    case pointerContext
}

extension UIViewController {
    var topMostPresentedViewController: UIViewController {
        var controller = self
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
}

nonisolated struct TerminalFindNavigatorLifecycle: Sendable {
    private(set) var isActive = false
    private(set) var suppressedGhosttySearchEndCount = 0
    private var restoreTerminalFocusAfterEnd = false

    mutating func begin(restoreTerminalFocus: Bool) {
        if isActive {
            restoreTerminalFocusAfterEnd = restoreTerminalFocusAfterEnd || restoreTerminalFocus
        } else {
            restoreTerminalFocusAfterEnd = restoreTerminalFocus
        }
        isActive = true
    }

    mutating func end() -> Bool {
        isActive = false
        let shouldRestoreFocus = restoreTerminalFocusAfterEnd
        restoreTerminalFocusAfterEnd = false
        return shouldRestoreFocus
    }

    mutating func suppressNextGhosttySearchEnd() {
        suppressedGhosttySearchEndCount += 1
    }

    mutating func cancelSuppressedGhosttySearchEnd() {
        guard suppressedGhosttySearchEndCount > 0 else { return }
        suppressedGhosttySearchEndCount -= 1
    }

    mutating func consumeSuppressedGhosttySearchEnd() -> Bool {
        guard suppressedGhosttySearchEndCount > 0 else { return false }
        suppressedGhosttySearchEndCount -= 1
        return true
    }
}

@MainActor
func makeTerminalZoomKeyCommands(action: Selector) -> [UIKeyCommand] {
    let shortcuts: [(input: String, modifiers: UIKeyModifierFlags)] = [
        ("=", .command),
        ("=", [.command, .shift]),
        ("+", .command),
        ("+", [.command, .shift]),
        ("-", .command),
        ("0", .command),
    ]

    return shortcuts.map { shortcut in
        let command = UIKeyCommand(
            input: shortcut.input,
            modifierFlags: shortcut.modifiers,
            action: action
        )
        if #available(iOS 15.0, *) {
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            command.allowsAutomaticMirroring = false
        }
        return command
    }
}

@MainActor
func makeTerminalSplitKeyCommands(action: Selector) -> [UIKeyCommand] {
    let shortcuts: [(input: String, modifiers: UIKeyModifierFlags, title: String)] = [
        ("d", .command, String(localized: "Split Right")),
        ("d", [.command, .shift], String(localized: "Split Down")),
        ("w", .command, String(localized: "Close Pane")),
        ("\r", [.command, .shift], String(localized: "Zoom Split")),
        ("[", .command, String(localized: "Select Previous Split")),
        ("]", .command, String(localized: "Select Next Split")),
        (UIKeyCommand.inputUpArrow, [.command, .alternate], String(localized: "Select Split Above")),
        (UIKeyCommand.inputDownArrow, [.command, .alternate], String(localized: "Select Split Below")),
        (UIKeyCommand.inputLeftArrow, [.command, .alternate], String(localized: "Select Split Left")),
        (UIKeyCommand.inputRightArrow, [.command, .alternate], String(localized: "Select Split Right")),
        ("=", [.command, .control], String(localized: "Equalize Splits")),
        (UIKeyCommand.inputUpArrow, [.command, .control], String(localized: "Move Divider Up")),
        (UIKeyCommand.inputDownArrow, [.command, .control], String(localized: "Move Divider Down")),
        (UIKeyCommand.inputLeftArrow, [.command, .control], String(localized: "Move Divider Left")),
        (UIKeyCommand.inputRightArrow, [.command, .control], String(localized: "Move Divider Right")),
    ]

    return shortcuts.map { shortcut in
        let command = UIKeyCommand(
            input: shortcut.input,
            modifierFlags: shortcut.modifiers,
            action: action
        )
        command.discoverabilityTitle = shortcut.title
        if #available(iOS 15.0, *) {
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            command.allowsAutomaticMirroring = false
        }
        return command
    }
}

extension UIKeyModifierFlags {
    var terminalSplitShortcutModifiers: TerminalSplitShortcutModifiers {
        var result: TerminalSplitShortcutModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.control) { result.insert(.control) }
        if contains(.alternate) { result.insert(.alternate) }
        return result
    }
}

extension Ghostty.Input.Mods {
    var terminalSplitShortcutModifiers: TerminalSplitShortcutModifiers {
        var result: TerminalSplitShortcutModifiers = []
        if contains(.super) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.ctrl) { result.insert(.control) }
        if contains(.alt) { result.insert(.alternate) }
        return result
    }
}

extension TerminalAccessoryShortcutModifiers {
    var terminalSplitShortcutModifiers: TerminalSplitShortcutModifiers {
        var result: TerminalSplitShortcutModifiers = []
        if command { result.insert(.command) }
        if shift { result.insert(.shift) }
        if control { result.insert(.control) }
        if alternate { result.insert(.alternate) }
        return result
    }
}

extension TerminalAccessoryShortcutKey {
    var terminalSplitShortcutKey: TerminalSplitShortcutKey? {
        switch self {
        case .enter:
            return .character("\r")
        case .arrowUp:
            return .upArrow
        case .arrowDown:
            return .downArrow
        case .arrowLeft:
            return .leftArrow
        case .arrowRight:
            return .rightArrow
        default:
            return unshiftedText.map(TerminalSplitShortcutKey.character)
        }
    }
}

#endif
