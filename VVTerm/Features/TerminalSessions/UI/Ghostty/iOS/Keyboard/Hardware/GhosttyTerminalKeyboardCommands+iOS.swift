//
//  GhosttyTerminalKeyboardCommands+iOS.swift
//  VVTerm
//
//  iOS terminal keyboard command routing.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    override var keyCommands: [UIKeyCommand]? {
        terminalSplitCommands + terminalZoomCommands + (super.keyCommands ?? [])
    }

    func handleIMEProxyNavigationCommand(_ command: UIKeyCommand) {
        guard canRouteTerminalInput else { return }
        guard let input = command.input,
              let key = terminalKey(forKeyCommandInput: input) else { return }
        let mods = Ghostty.Input.Mods(uiKeyModifiers: command.modifierFlags)
        sendToolbarKey(key, accumulatedMods: mods)
    }

    @objc
    func handleTerminalZoomCommand(_ command: UIKeyCommand) {
        guard canRouteTerminalInput,
              let input = command.input,
              let key = TerminalZoomShortcutRouting.key(forCommandInput: input),
              let action = TerminalZoomShortcutRouting.action(
                  for: key,
                  hasCommandModifier: command.modifierFlags.contains(.command),
                  hasShiftModifier: command.modifierFlags.contains(.shift),
                  hasControlModifier: command.modifierFlags.contains(.control),
                  hasAlternateModifier: command.modifierFlags.contains(.alternate)
              ) else {
            return
        }
        performTerminalZoomAction(action)
    }

    @objc
    func handleTerminalSplitCommand(_ command: UIKeyCommand) {
        guard canRouteTerminalInput,
              let input = command.input else {
            return
        }
        _ = performTerminalSplitShortcut(
            input: input,
            modifiers: command.modifierFlags.terminalSplitShortcutModifiers
        )
    }

    func handlePasteShortcut(_ key: UIKey) -> Bool {
        let input = key.charactersIgnoringModifiers.lowercased()
        guard input == "v" else { return false }

        if key.modifierFlags.contains(.command) {
            performPasteAction(requestRenderAfterward: true)
            return true
        }

        if key.modifierFlags.contains(.control), interceptRichPasteIfNeeded() {
            return true
        }

        return false
    }

    @discardableResult
    func interceptRichPasteIfNeeded() -> Bool {
        richPasteInterceptor?(self) == true
    }

    func performPasteAction(requestRenderAfterward: Bool = false) {
        invalidateLocalTextInputSession()
        if interceptRichPasteIfNeeded() {
            clearSelectionAfterPaste()
            if requestRenderAfterward {
                requestRender()
            }
            return
        }

        pasteTextFromClipboard()
        clearSelectionAfterPaste()
        if requestRenderAfterward {
            requestRender()
        }
    }

    func handleCommandShortcut(_ key: UIKey) -> Bool {
        guard key.modifierFlags.contains(.command) else { return false }
        if performTerminalSplitCommand(terminalSplitCommand(for: key)) {
            return true
        }
        if let action = terminalZoomShortcutAction(for: key) {
            performTerminalZoomAction(action)
            return true
        }

        let input = key.charactersIgnoringModifiers.lowercased()
        switch input {
        case "c":
            if canPerformAction(#selector(copy(_:)), withSender: nil) {
                copy(nil)
            }
            return true
        case "f":
            if canPerformAction(#selector(find(_:)), withSender: nil) {
                find(nil)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func terminalSplitCommand(for key: UIKey) -> TerminalSplitCommand? {
        let physicalArrow: TerminalSplitShortcutKey?
        switch key.keyCode {
        case .keyboardUpArrow:
            physicalArrow = .upArrow
        case .keyboardDownArrow:
            physicalArrow = .downArrow
        case .keyboardLeftArrow:
            physicalArrow = .leftArrow
        case .keyboardRightArrow:
            physicalArrow = .rightArrow
        default:
            physicalArrow = nil
        }

        if let physicalArrow,
           let command = TerminalSplitShortcutRouting.command(
               for: physicalArrow,
               modifiers: key.modifierFlags.terminalSplitShortcutModifiers
           ) {
            return command
        }
        return terminalSplitCommand(
            input: key.charactersIgnoringModifiers,
            modifiers: key.modifierFlags
        )
    }

    private func terminalSplitCommand(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> TerminalSplitCommand? {
        // Caps Lock and UIKit's numeric-pad marker do not conflict with app
        // shortcuts; this matches the existing terminal zoom routing.
        return TerminalSplitShortcutRouting.command(
            for: input,
            modifiers: modifiers.terminalSplitShortcutModifiers
        )
    }

    @discardableResult
    func performTerminalSplitShortcut(
        input: String,
        modifiers: TerminalSplitShortcutModifiers
    ) -> Bool {
        performTerminalSplitCommand(
            TerminalSplitShortcutRouting.command(for: input, modifiers: modifiers)
        )
    }

    @discardableResult
    func performTerminalSplitShortcut(
        key: TerminalSplitShortcutKey,
        modifiers: TerminalSplitShortcutModifiers
    ) -> Bool {
        performTerminalSplitCommand(
            TerminalSplitShortcutRouting.command(for: key, modifiers: modifiers)
        )
    }

    @discardableResult
    private func performTerminalSplitCommand(_ command: TerminalSplitCommand?) -> Bool {
        guard let command else { return false }
        onPaneKeyboardShortcut?(command)
        return true
    }

    private func performTerminalZoomAction(_ action: TerminalZoomAction) {
        if let result = onZoomAction?(action) {
            showZoomIndicator(fontSize: result.effectiveFontSize)
        }
    }

    private func terminalZoomShortcutAction(for key: UIKey) -> TerminalZoomAction? {
        let physicalKey: TerminalZoomShortcutKey?
        switch key.keyCode {
        case .keyboardEqualSign:
            physicalKey = .equal
        case .keyboardHyphen:
            physicalKey = .minus
        case .keyboard0:
            physicalKey = .zero
        case .keypadPlus:
            physicalKey = .keypadPlus
        case .keypadHyphen:
            physicalKey = .keypadMinus
        case .keypad0:
            physicalKey = .keypadZero
        default:
            physicalKey = key.characters == "-" ? .minus : nil
        }

        let shortcutKey = TerminalZoomShortcutRouting.resolvedKey(
            physicalKey: physicalKey,
            characters: key.characters
        )
        guard let shortcutKey else { return nil }
        return TerminalZoomShortcutRouting.action(
            for: shortcutKey,
            hasCommandModifier: key.modifierFlags.contains(.command),
            hasShiftModifier: key.modifierFlags.contains(.shift),
            hasControlModifier: key.modifierFlags.contains(.control),
            hasAlternateModifier: key.modifierFlags.contains(.alternate)
        )
    }

    func terminalKey(forKeyCommandInput input: String) -> TerminalKey? {
        switch input {
        case UIKeyCommand.inputEscape:
            return .escape
        case UIKeyCommand.inputUpArrow:
            return .arrowUp
        case UIKeyCommand.inputDownArrow:
            return .arrowDown
        case UIKeyCommand.inputLeftArrow:
            return .arrowLeft
        case UIKeyCommand.inputRightArrow:
            return .arrowRight
        case UIKeyCommand.inputHome:
            return .home
        case UIKeyCommand.inputEnd:
            return .end
        case UIKeyCommand.inputPageUp:
            return .pageUp
        case UIKeyCommand.inputPageDown:
            return .pageDown
        default:
            return nil
        }
    }

}

#endif
