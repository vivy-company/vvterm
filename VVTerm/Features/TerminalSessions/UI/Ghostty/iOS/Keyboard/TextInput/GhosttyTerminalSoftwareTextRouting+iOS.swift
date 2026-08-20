//
//  GhosttyTerminalSoftwareTextRouting+iOS.swift
//  VVTerm
//
//  iOS software text and paste routing.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    /// Send text to the terminal (called from keyboard toolbar or software keyboard)
    func sendText(_ text: String) {
        guard canRouteTerminalInput else { return }
        surface?.sendText(text)
        requestRender()
    }

    func pasteTextFromClipboard() {
        guard canRouteTerminalInput else { return }
        _ = surface?.perform(action: "paste_from_clipboard")
        requestRender()
    }

    func sendTerminalInputText(_ text: String) {
        guard canRouteTerminalInput else { return }
        let normalized = text.precomposedStringWithCanonicalMapping
        guard normalized.count == 1, let character = normalized.first else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false)
            return
        }
        guard let mapping = ghosttyKeyMapping(for: character) else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false)
            return
        }

        var mods: Ghostty.Input.Mods = []
        if mapping.requiresShift {
            mods.insert(.shift)
        }
        sendModifiedKey(
            mapping.key,
            mods: mods,
            text: mapping.text,
            unshiftedCodepoint: mapping.codepoint,
            invalidateLocalSession: false
        )
    }

    private func sendRawTerminalInputText(_ text: String, invalidateLocalSession: Bool = true) {
        guard canRouteTerminalInput else { return }
        let terminalText = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        let data = Data(terminalText.utf8)
        guard !data.isEmpty else { return }

        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        if let writeCallback {
            writeCallback(data)
        } else {
            surface?.sendText(terminalText)
        }
        requestRender()
    }

    func handleIMEProxyInsertText(_ text: String, fromIMEComposition: Bool = false) -> Bool {
        guard canRouteTerminalInput else { return true }
        if fromIMEComposition {
            cancelTrackedHardwareInput()
        }
        if isNativeSelectionTextInputContext {
            clearNativeSelectionStateForTerminalInput()
        }

        let normalized = text.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return true }
        if let key = terminalKey(forKeyCommandInput: normalized) {
            sendToolbarKey(key)
            return true
        }
        if normalized.hasPrefix("UIKeyInput") {
            return true
        }

        if !fromIMEComposition,
           let key = consumePendingSystemTextInputHardwareKey(),
           sendInterpretedHardwareKeyText(normalized, for: key) {
            invalidateLocalTextInputSession()
            return true
        }
        if !fromIMEComposition, updateActiveInterpretedHardwareKeyRepeat(text: normalized) {
            return true
        }

        let mods = keyboardToolbar?.consumeModifiers() ?? (ctrl: false, alt: false, command: false, shift: false)
        if mods.command {
            var splitModifiers: TerminalSplitShortcutModifiers = [.command]
            if mods.ctrl { splitModifiers.insert(.control) }
            if mods.alt { splitModifiers.insert(.alternate) }
            if mods.shift { splitModifiers.insert(.shift) }
            if let firstCharacter = normalized.first,
               ghosttyKeyMapping(for: firstCharacter)?.requiresShift == true {
                splitModifiers.insert(.shift)
            }
            if performTerminalSplitShortcut(input: normalized, modifiers: splitModifiers) {
                return true
            }
        }
        if mods.ctrl, normalized.compare("v", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
           interceptRichPasteIfNeeded() {
            invalidateLocalTextInputSession()
            return true
        }
        if normalized == "\n" || normalized == "\r" {
            commitIMEProxyMarkedTextIfNeeded()
            sendToolbarGhosttyKey(.enter, mods: imeProxyGhosttyModifiers(from: mods))
            return true
        }
        if normalized == "\t" {
            commitIMEProxyMarkedTextIfNeeded()
            sendToolbarGhosttyKey(.tab, mods: imeProxyGhosttyModifiers(from: mods))
            return true
        }

        guard mods.ctrl || mods.alt || mods.command else {
            // Plain text goes into the persistent local document; the text input
            // model reconciles it with the terminal by sending the delta.
            imeProxyTextView.insertCommittedText(normalized)
            return true
        }
        guard let firstChar = normalized.first else { return true }

        if let mapping = ghosttyKeyMapping(for: firstChar) {
            var ghostMods: Ghostty.Input.Mods = []
            if mods.ctrl { ghostMods.insert(.ctrl) }
            if mods.alt { ghostMods.insert(.alt) }
            if mods.command { ghostMods.insert(.super) }
            if mods.shift || mapping.requiresShift { ghostMods.insert(.shift) }
            let keyText = mods.ctrl || mods.alt || mods.command ? nil : mapping.text
            sendModifiedKey(mapping.key, mods: ghostMods, text: keyText, unshiftedCodepoint: mapping.codepoint)
        } else {
            if mods.command {
                return true
            }
            var data = Data()
            if mods.alt {
                data.append(0x1B)
            }
            if mods.ctrl, let controlChar = TerminalControlKey.controlCharacter(for: firstChar) {
                data.append(contentsOf: String(controlChar).utf8)
            } else {
                data.append(contentsOf: String(firstChar).utf8)
            }
            sendAnsiSequence(data)
        }

        if normalized.count > 1 {
            sendText(String(normalized.dropFirst()))
        }
        return true
    }

    private func imeProxyGhosttyModifiers(from mods: (ctrl: Bool, alt: Bool, command: Bool, shift: Bool)) -> Ghostty.Input.Mods {
        var ghostMods: Ghostty.Input.Mods = []
        if mods.ctrl { ghostMods.insert(.ctrl) }
        if mods.alt { ghostMods.insert(.alt) }
        if mods.command { ghostMods.insert(.super) }
        if mods.shift { ghostMods.insert(.shift) }
        return ghostMods
    }

    private func commitIMEProxyMarkedTextIfNeeded() {
        guard imeProxyMarkedRange() != nil else { return }
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.unmarkText()
        }
        syncTextInputModelFromIMEProxy()
    }
}

#endif
