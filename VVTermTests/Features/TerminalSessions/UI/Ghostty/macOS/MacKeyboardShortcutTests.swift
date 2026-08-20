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

    @Test
    func terminalZoomShortcutsUsePhysicalMainAndKeypadKeys() {
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.equal.keyCode!,
            characters: "+",
            modifiers: .command,
            isFirstResponder: true
        ) == .zoomIn)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.equal.keyCode!,
            characters: "=",
            modifiers: .command,
            isFirstResponder: true
        ) == .zoomIn)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.equal.keyCode!,
            characters: "+",
            modifiers: [.command, .shift],
            isFirstResponder: true
        ) == .zoomIn)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.minus.keyCode!,
            characters: "-",
            modifiers: .command,
            isFirstResponder: true
        ) == .zoomOut)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.numpadAdd.keyCode!,
            characters: "+",
            modifiers: [.command, .numericPad],
            isFirstResponder: true
        ) == .zoomIn)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.numpadSubtract.keyCode!,
            characters: "-",
            modifiers: [.command, .numericPad],
            isFirstResponder: true
        ) == .zoomOut)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.digit0.keyCode!,
            characters: "0",
            modifiers: .command,
            isFirstResponder: true
        ) == .reset)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.numpad0.keyCode!,
            characters: "0",
            modifiers: [.command, .numericPad],
            isFirstResponder: true
        ) == .reset)
    }

    @Test
    func terminalZoomShortcutsRequireFocusedTerminalAndExactCommandModifiers() {
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.equal.keyCode!,
            characters: "+",
            modifiers: [.command, .shift],
            isFirstResponder: false
        ) == nil)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.minus.keyCode!,
            characters: "_",
            modifiers: [.command, .shift],
            isFirstResponder: true
        ) == nil)
        #expect(MacTerminalShortcutRouting.zoomAction(
            keyCode: Ghostty.Input.Key.minus.keyCode!,
            characters: "-",
            modifiers: [.command, .option],
            isFirstResponder: true
        ) == nil)
    }
}
#endif
