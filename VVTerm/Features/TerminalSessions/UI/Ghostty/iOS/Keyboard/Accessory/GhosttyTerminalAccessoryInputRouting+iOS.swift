//
//  GhosttyTerminalAccessoryInputRouting+iOS.swift
//  VVTerm
//
//  iOS terminal accessory input routing.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    func sendToolbarKey(_ key: TerminalKey, accumulatedMods: Ghostty.Input.Mods = []) {
        if case .modified(let baseKey, let mods) = key {
            sendToolbarKey(baseKey, accumulatedMods: accumulatedMods.union(mods))
            return
        }
        if accumulatedMods.contains(.super),
           let splitKey = key.terminalSplitShortcutKey,
           performTerminalSplitShortcut(
               key: splitKey,
               modifiers: accumulatedMods.terminalSplitShortcutModifiers
           ) {
            return
        }

        switch key {
        case .modified:
            return
        case .escape:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                invalidateLocalTextInputSession()
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false)
            } else {
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false)
            }
        case .tab:
            sendToolbarGhosttyKey(.tab, mods: accumulatedMods)
        case .enter:
            sendToolbarGhosttyKey(.enter, mods: accumulatedMods)
        case .backspace:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                imeProxyTextView.deleteBackward()
            } else {
                sendToolbarGhosttyKey(.backspace, mods: accumulatedMods)
            }
        case .delete:
            sendToolbarGhosttyKey(.delete, mods: accumulatedMods)
        case .insert:
            sendToolbarGhosttyKey(.insert, mods: accumulatedMods)
        case .arrowUp:
            sendToolbarGhosttyKey(.arrowUp, mods: accumulatedMods)
        case .arrowDown:
            sendToolbarGhosttyKey(.arrowDown, mods: accumulatedMods)
        case .arrowLeft:
            sendToolbarGhosttyKey(.arrowLeft, mods: accumulatedMods)
        case .arrowRight:
            sendToolbarGhosttyKey(.arrowRight, mods: accumulatedMods)
        case .home:
            sendToolbarGhosttyKey(.home, mods: accumulatedMods)
        case .end:
            sendToolbarGhosttyKey(.end, mods: accumulatedMods)
        case .pageUp:
            sendToolbarGhosttyKey(.pageUp, mods: accumulatedMods)
        case .pageDown:
            sendToolbarGhosttyKey(.pageDown, mods: accumulatedMods)
        case .f1:
            sendToolbarGhosttyKey(.f1, mods: accumulatedMods)
        case .f2:
            sendToolbarGhosttyKey(.f2, mods: accumulatedMods)
        case .f3:
            sendToolbarGhosttyKey(.f3, mods: accumulatedMods)
        case .f4:
            sendToolbarGhosttyKey(.f4, mods: accumulatedMods)
        case .f5:
            sendToolbarGhosttyKey(.f5, mods: accumulatedMods)
        case .f6:
            sendToolbarGhosttyKey(.f6, mods: accumulatedMods)
        case .f7:
            sendToolbarGhosttyKey(.f7, mods: accumulatedMods)
        case .f8:
            sendToolbarGhosttyKey(.f8, mods: accumulatedMods)
        case .f9:
            sendToolbarGhosttyKey(.f9, mods: accumulatedMods)
        case .f10:
            sendToolbarGhosttyKey(.f10, mods: accumulatedMods)
        case .f11:
            sendToolbarGhosttyKey(.f11, mods: accumulatedMods)
        case .f12:
            sendToolbarGhosttyKey(.f12, mods: accumulatedMods)
        case .ctrlC:
            sendToolbarControlShortcut(.c, letter: "c", mods: accumulatedMods)
        case .ctrlD:
            sendToolbarControlShortcut(.d, letter: "d", mods: accumulatedMods)
        case .ctrlZ:
            sendToolbarControlShortcut(.z, letter: "z", mods: accumulatedMods)
        case .ctrlL:
            sendToolbarControlShortcut(.l, letter: "l", mods: accumulatedMods)
        case .ctrlA:
            sendToolbarControlShortcut(.a, letter: "a", mods: accumulatedMods)
        case .ctrlE:
            sendToolbarControlShortcut(.e, letter: "e", mods: accumulatedMods)
        case .ctrlK:
            sendToolbarControlShortcut(.k, letter: "k", mods: accumulatedMods)
        case .ctrlU:
            sendToolbarControlShortcut(.u, letter: "u", mods: accumulatedMods)
        }
    }

    func sendToolbarGhosttyKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32? = nil,
        invalidateLocalSession: Bool = true
    ) {
        let codepoint = unshiftedCodepoint ?? text?.unicodeScalars.first?.value ?? 0
        sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: codepoint,
            invalidateLocalSession: invalidateLocalSession
        )
    }

    private func sendToolbarControlShortcut(
        _ key: Ghostty.Input.Key,
        letter: String,
        mods: Ghostty.Input.Mods
    ) {
        var mergedMods = mods
        mergedMods.insert(.ctrl)
        let codepoint = letter.unicodeScalars.first?.value ?? 0
        sendToolbarGhosttyKey(key, mods: mergedMods, text: nil, unshiftedCodepoint: codepoint)
    }

    func handleToolbarCustomAction(_ action: TerminalAccessoryCustomAction) {
        switch action.kind {
        case .command:
            sendText(action.commandContent)
            if action.commandSendMode == .insertAndEnter {
                sendKeyPress(.enter)
            }
        case .shortcut:
            if action.shortcutModifiers.command,
               let splitKey = action.shortcutKey.terminalSplitShortcutKey,
               performTerminalSplitShortcut(
                   key: splitKey,
                   modifiers: action.shortcutModifiers.terminalSplitShortcutModifiers
               ) {
                return
            }
            guard let key = Ghostty.Input.Key(rawValue: action.shortcutKey.rawValue) else { return }
            let mods = action.shortcutModifiers.ghosttyModifiers
            let text: String?
            if action.shortcutModifiers.control || action.shortcutModifiers.alternate || action.shortcutModifiers.command {
                text = nil
            } else if action.shortcutModifiers.shift {
                text = action.shortcutKey.shiftedText ?? action.shortcutKey.unshiftedText
            } else {
                text = action.shortcutKey.unshiftedText
            }

            let codepoint = action.shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
            sendToolbarGhosttyKey(key, mods: mods, text: text, unshiftedCodepoint: codepoint)
        }
    }

    func ghosttyKeyMapping(for character: Character) -> (key: Ghostty.Input.Key, text: String?, codepoint: UInt32, requiresShift: Bool)? {
        let string = String(character)

        for shortcutKey in TerminalAccessoryShortcutKey.allCases {
            if shortcutKey.unshiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.unshiftedText, codepoint, false)
            }

            if shortcutKey.shiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.shiftedText, codepoint, true)
            }
        }

        return nil
    }
}

extension TerminalAccessoryShortcutModifiers {
    var ghosttyModifiers: Ghostty.Input.Mods {
        var mods: Ghostty.Input.Mods = []
        if control {
            mods.insert(.ctrl)
        }
        if alternate {
            mods.insert(.alt)
        }
        if command {
            mods.insert(.super)
        }
        if shift {
            mods.insert(.shift)
        }
        return mods
    }
}

private extension TerminalKey {
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
            return nil
        }
    }
}

#endif
