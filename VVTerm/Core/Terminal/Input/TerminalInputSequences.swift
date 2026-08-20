//
//  TerminalInputSequences.swift
//  VVTerm
//
//  Shared terminal input keys and byte sequences.
//

import Foundation

/// Special keys that can be sent to the terminal
enum TerminalSpecialKey {
    case escape
    case tab
    case enter
    case backspace
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown
    case delete
}

/// Utility to get the escape sequence for a special key
enum TerminalSpecialKeySequence {
    static func escapeSequence(for key: TerminalSpecialKey) -> String {
        switch key {
        case .escape:
            return "\u{1B}"
        case .tab:
            return "\t"
        case .enter:
            return "\r"
        case .backspace:
            return "\u{7F}"
        case .delete:
            return "\u{1B}[3~"
        case .arrowUp:
            return "\u{1B}[A"
        case .arrowDown:
            return "\u{1B}[B"
        case .arrowLeft:
            return "\u{1B}[D"
        case .arrowRight:
            return "\u{1B}[C"
        case .home:
            return "\u{1B}[H"
        case .end:
            return "\u{1B}[F"
        case .pageUp:
            return "\u{1B}[5~"
        case .pageDown:
            return "\u{1B}[6~"
        }
    }
}

/// Utility to compute the control character for a given letter (Ctrl+A = 0x01, Ctrl+Z = 0x1A)
enum TerminalControlKey {
    /// Returns the control character for the given letter, or nil if not A-Z
    static func controlCharacter(for char: Character) -> Character? {
        let asciiValue = char.uppercased().first?.asciiValue ?? 0
        if asciiValue >= 65 && asciiValue <= 90 {
            return Character(UnicodeScalar(asciiValue - 64))
        }
        return nil
    }
}

/// Keys emitted by the iOS terminal keyboard and accessory controls.
indirect enum TerminalKey {
    case escape, tab, enter, backspace, delete, insert
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlA, ctrlE, ctrlK, ctrlU
    case modified(TerminalKey, mods: Ghostty.Input.Mods)

    func withCtrl() -> TerminalKey {
        withModifier(.ctrl)
    }

    func withAlt() -> TerminalKey {
        withModifier(.alt)
    }

    func withShift() -> TerminalKey {
        withModifier(.shift)
    }

    func withCommand() -> TerminalKey {
        withModifier(.super)
    }

    private func withModifier(_ modifier: Ghostty.Input.Mods) -> TerminalKey {
        switch self {
        case .modified(let key, let mods):
            return .modified(key, mods: mods.union(modifier))
        default:
            return .modified(self, mods: modifier)
        }
    }

    var ansiSequence: Data {
        switch self {
        case .escape: return Data([0x1B])
        case .tab: return Data([0x09])
        case .enter: return Data([0x0D])
        case .backspace: return Data([0x7F])
        case .delete: return "\u{1B}[3~".data(using: .utf8)!
        case .insert: return "\u{1B}[2~".data(using: .utf8)!
        case .arrowUp: return "\u{1B}[A".data(using: .utf8)!
        case .arrowDown: return "\u{1B}[B".data(using: .utf8)!
        case .arrowRight: return "\u{1B}[C".data(using: .utf8)!
        case .arrowLeft: return "\u{1B}[D".data(using: .utf8)!
        case .home: return "\u{1B}[H".data(using: .utf8)!
        case .end: return "\u{1B}[F".data(using: .utf8)!
        case .pageUp: return "\u{1B}[5~".data(using: .utf8)!
        case .pageDown: return "\u{1B}[6~".data(using: .utf8)!
        case .f1: return "\u{1B}OP".data(using: .utf8)!
        case .f2: return "\u{1B}OQ".data(using: .utf8)!
        case .f3: return "\u{1B}OR".data(using: .utf8)!
        case .f4: return "\u{1B}OS".data(using: .utf8)!
        case .f5: return "\u{1B}[15~".data(using: .utf8)!
        case .f6: return "\u{1B}[17~".data(using: .utf8)!
        case .f7: return "\u{1B}[18~".data(using: .utf8)!
        case .f8: return "\u{1B}[19~".data(using: .utf8)!
        case .f9: return "\u{1B}[20~".data(using: .utf8)!
        case .f10: return "\u{1B}[21~".data(using: .utf8)!
        case .f11: return "\u{1B}[23~".data(using: .utf8)!
        case .f12: return "\u{1B}[24~".data(using: .utf8)!
        case .ctrlC: return Data([0x03])
        case .ctrlD: return Data([0x04])
        case .ctrlZ: return Data([0x1A])
        case .ctrlL: return Data([0x0C])
        case .ctrlA: return Data([0x01])
        case .ctrlE: return Data([0x05])
        case .ctrlK: return Data([0x0B])
        case .ctrlU: return Data([0x15])
        case .modified(let key, _):
            return key.ansiSequence
        }
    }
}
