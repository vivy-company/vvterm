#if os(macOS)
import AppKit
import Testing
@testable import VVTerm

struct MacKeyboardShortcutTests {
    @Test
    func commandVMatchesPhysicalVKey() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: .command))
    }

    @Test
    func commandVIgnoresNonShortcutModifiersLikeCapsLock() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: [.command, .capsLock]))
    }

    @Test
    func commandVRejectsWrongModifierSet() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: [.command, .shift]) == false)
    }

    @Test
    func commandCMatchesPhysicalCKey() {
        #expect(MacTerminalShortcut.copy.matches(keyCode: Ghostty.Input.Key.c.keyCode!, modifiers: .command))
    }

    @Test
    func controlVMatchesRichPasteShortcut() {
        #expect(MacTerminalShortcut.richPaste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: .control))
    }

    @Test
    func voiceShortcutMatchesCommandShiftM() {
        #expect(MacTerminalShortcut.toggleVoiceRecording.matches(keyCode: Ghostty.Input.Key.m.keyCode!, modifiers: [.command, .shift]))
    }

    @Test
    func neighboringKeyDoesNotMatchShortcut() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.c.keyCode!, modifiers: .command) == false)
    }

    @Test
    func commandVPasteRequiresFirstResponderOwnership() {
        #expect(
            MacTerminalShortcutRouting.shouldHandle(
                MacTerminalShortcut.paste,
                keyCode: Ghostty.Input.Key.v.keyCode!,
                modifiers: .command,
                isFirstResponder: true
            )
        )
        #expect(
            MacTerminalShortcutRouting.shouldHandle(
                MacTerminalShortcut.paste,
                keyCode: Ghostty.Input.Key.v.keyCode!,
                modifiers: .command,
                isFirstResponder: false
            ) == false
        )
    }

    @Test
    func commandCCopyRequiresFirstResponderOwnership() {
        #expect(
            MacTerminalShortcutRouting.shouldHandle(
                MacTerminalShortcut.copy,
                keyCode: Ghostty.Input.Key.c.keyCode!,
                modifiers: .command,
                isFirstResponder: true
            )
        )
        #expect(
            MacTerminalShortcutRouting.shouldHandle(
                MacTerminalShortcut.copy,
                keyCode: Ghostty.Input.Key.c.keyCode!,
                modifiers: .command,
                isFirstResponder: false
            ) == false
        )
    }
}
#endif
