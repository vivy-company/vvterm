#if os(macOS)
import AppKit

struct MacKeyboardShortcut {
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

enum MacTerminalShortcut {
    static let copy = MacKeyboardShortcut(key: .c, modifiers: .command)!
    static let paste = MacKeyboardShortcut(key: .v, modifiers: .command)!
    static let richPaste = MacKeyboardShortcut(key: .v, modifiers: .control)!
    static let toggleVoiceRecording = MacKeyboardShortcut(key: .m, modifiers: [.command, .shift])!
}

enum MacTerminalShortcutRouting {
    static func shouldHandle(
        _ shortcut: MacKeyboardShortcut,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isFirstResponder: Bool
    ) -> Bool {
        isFirstResponder && shortcut.matches(keyCode: keyCode, modifiers: modifiers)
    }
}
#endif
