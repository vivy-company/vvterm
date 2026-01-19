//
//  Clipboard.swift
//  VVTerm
//
//  Shared pasteboard helper for simple text copies
//

#if os(macOS)
import AppKit

enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func copy(lines: [String], separator: String = "\n") {
        copy(lines.joined(separator: separator))
    }
}
#else
import UIKit

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func readString() -> String? {
        UIPasteboard.general.string
    }

    static func copy(lines: [String], separator: String = "\n") {
        copy(lines.joined(separator: separator))
    }
}
#endif
