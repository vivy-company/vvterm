//
//  GhosttyTerminalIME+macOS.swift
//  VVTerm
//
//  macOS input method editor integration.
//

#if os(macOS)
import AppKit

/// NSTextInputClient protocol conformance for IME (Input Method Editor) support
extension GhosttyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        imeHandler.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        imeHandler.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    func unmarkText() {
        imeHandler.unmarkText()
    }

    func selectedRange() -> NSRange {
        return imeHandler.selectedRange()
    }

    func markedRange() -> NSRange {
        return imeHandler.markedRange()
    }

    func hasMarkedText() -> Bool {
        return imeHandler.hasMarkedText
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return imeHandler.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return imeHandler.validAttributesForMarkedText()
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return imeHandler.firstRect(
            forCharacterRange: range,
            actualRange: actualRange,
            viewFrame: frame,
            window: window,
            surface: surface?.unsafeCValue
        )
    }

    func characterIndex(for point: NSPoint) -> Int {
        return imeHandler.characterIndex(for: point)
    }
}

#endif
