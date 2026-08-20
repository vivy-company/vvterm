//
//  GhosttyTerminalKeyboardInput+macOS.swift
//  VVTerm
//
//  macOS terminal keyboard input routing.
//

#if os(macOS)
import AppKit

extension GhosttyTerminalView {
    override func keyDown(with event: NSEvent) {
        if handleRichPasteShortcut(event) {
            return
        }
        inputHandler.handleKeyDown(with: event) { [weak self] events in
            self?.interpretKeyEvents(events)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isFirstResponder = window?.firstResponder === self

        if let action = MacTerminalShortcutRouting.zoomAction(
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags,
            isFirstResponder: isFirstResponder
        ) {
            if let result = onZoomAction?(action) {
                showZoomIndicator(fontSize: result.effectiveFontSize)
            }
            return true
        }

        switch true {
        case MacTerminalShortcutRouting.shouldHandle(
            MacTerminalShortcut.paste,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isFirstResponder: isFirstResponder
        ):
            paste(nil)
            return true
        case MacTerminalShortcutRouting.shouldHandle(
            MacTerminalShortcut.copy,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isFirstResponder: isFirstResponder
        ):
            copy(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func handleRichPasteShortcut(_ event: NSEvent) -> Bool {
        guard isRichPasteShortcut(event) else { return false }
        return interceptRichPasteIfNeeded()
    }

    private func isRichPasteShortcut(_ event: NSEvent) -> Bool {
        MacTerminalShortcut.richPaste.matches(event)
    }

    override func keyUp(with event: NSEvent) {
        inputHandler.handleKeyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputHandler.handleFlagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Override to suppress NSBeep when interpretKeyEvents encounters unhandled commands
        // Without this, keys like delete at beginning of line, cmd+c with no selection, etc. cause beeps
        // Terminal handles all input via Ghostty, so we silently ignore unhandled commands
    }
}

#endif
