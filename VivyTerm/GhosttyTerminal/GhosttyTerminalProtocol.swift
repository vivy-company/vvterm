//
//  GhosttyTerminalProtocol.swift
//  VivyTerm
//
//  Shared enums and utilities for Ghostty terminal views
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
