#if os(macOS)
import AppKit

nonisolated struct MacKeyboardShortcut: Sendable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init?(key: Ghostty.Input.Key, modifiers: NSEvent.ModifierFlags) {
        guard let keyCode = key.keyCode else { return nil }
        self.keyCode = keyCode
        self.modifiers = Self.normalize(modifiers)
    }

    func matches(_ event: NSEvent) -> Bool {
        matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode && Self.normalize(modifiers) == self.modifiers
    }

    private static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    private static func normalize(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(relevantModifierMask)
    }
}

nonisolated enum MacTerminalShortcut {
    static let copy = MacKeyboardShortcut(key: .c, modifiers: .command)!
    static let paste = MacKeyboardShortcut(key: .v, modifiers: .command)!
    static let richPaste = MacKeyboardShortcut(key: .v, modifiers: .control)!
    static let toggleVoiceRecording = MacKeyboardShortcut(key: .m, modifiers: [.command, .shift])!
}

nonisolated enum MacTerminalShortcutRouting {
    static func shouldHandle(
        _ shortcut: MacKeyboardShortcut,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isFirstResponder: Bool
    ) -> Bool {
        isFirstResponder && shortcut.matches(keyCode: keyCode, modifiers: modifiers)
    }

    static func zoomAction(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        isFirstResponder: Bool
    ) -> TerminalZoomAction? {
        guard isFirstResponder else { return nil }

        let physicalKey: TerminalZoomShortcutKey?
        switch keyCode {
        case Ghostty.Input.Key.equal.keyCode!:
            physicalKey = .equal
        case Ghostty.Input.Key.minus.keyCode!:
            physicalKey = .minus
        case Ghostty.Input.Key.digit0.keyCode!:
            physicalKey = .zero
        case Ghostty.Input.Key.numpadAdd.keyCode!:
            physicalKey = .keypadPlus
        case Ghostty.Input.Key.numpadSubtract.keyCode!:
            physicalKey = .keypadMinus
        case Ghostty.Input.Key.numpad0.keyCode!:
            physicalKey = .keypadZero
        default:
            physicalKey = characters == "-" ? .minus : nil
        }

        let shortcutKey = TerminalZoomShortcutRouting.resolvedKey(
            physicalKey: physicalKey,
            characters: characters ?? ""
        )
        guard let shortcutKey else { return nil }
        return TerminalZoomShortcutRouting.action(
            for: shortcutKey,
            hasCommandModifier: modifiers.contains(.command),
            hasShiftModifier: modifiers.contains(.shift),
            hasControlModifier: modifiers.contains(.control),
            hasAlternateModifier: modifiers.contains(.option)
        )
    }
}
#endif
