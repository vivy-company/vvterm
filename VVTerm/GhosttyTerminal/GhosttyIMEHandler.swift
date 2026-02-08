//
//  GhosttyIMEHandler.swift
//  aizen
//
//  Handles Input Method Editor (IME) support for Ghostty terminal
//  Enables proper input for Japanese, Chinese, Korean, etc.
//

#if os(macOS)
import AppKit
import OSLog

/// Manages IME (Input Method Editor) state and text input handling for Ghostty terminal
@MainActor
class GhosttyIMEHandler {
    // MARK: - Properties

    private weak var view: NSView?
    private weak var surface: Ghostty.Surface?

    /// Track marked text for IME composition
    private(set) var markedText: String = ""

    /// Attributes for displaying marked text
    private let markedTextAttributes: [NSAttributedString.Key: Any] = [
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.textColor
    ]

    /// Accumulates text from insertText calls during keyDown
    /// Set to non-nil during keyDown to track if IME inserted text
    private(set) var keyTextAccumulator: [String]?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "win.aizen.app", category: "GhosttyIME")

    // MARK: - Initialization

    init(view: NSView, surface: Ghostty.Surface?) {
        self.view = view
        self.surface = surface
    }

    // MARK: - Public API

    /// Update surface reference
    func updateSurface(_ surface: Ghostty.Surface?) {
        self.surface = surface
    }

    /// Check if currently composing marked text
    var hasMarkedText: Bool {
        !markedText.isEmpty
    }

    /// Start accumulating text from insertText calls (call before interpretKeyEvents)
    func beginKeyTextAccumulation() {
        keyTextAccumulator = []
    }

    /// End accumulation and return accumulated texts (call after interpretKeyEvents)
    func endKeyTextAccumulation() -> [String]? {
        defer { keyTextAccumulator = nil }
        return keyTextAccumulator
    }

    /// Clear marked text state
    func clearMarkedText() {
        if !markedText.isEmpty {
            markedText = ""
            view?.needsDisplay = true
        }
    }

    // MARK: - NSTextInputClient Methods

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = anyToString(string) else { return }

        // Clear any marked text when committing
        clearMarkedText()

        // If we're in a keyDown event (accumulator exists), accumulate the text
        // The keyDown handler will send it to the terminal
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }

        // Otherwise send directly to terminal (e.g., paste operation)
        surface?.sendText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let text = anyToString(string) else { return }

        // Update marked text state
        markedText = text

        // Tell system we've handled the marked text
        view?.inputContext?.invalidateCharacterCoordinates()
        view?.needsDisplay = true

        Self.logger.debug("IME marked text: \(text)")
    }

    func unmarkText() {
        // NSTextInputClient commits through insertText; unmarkText only ends composition.
        // Sending marked text here can emit partial Jamo/phonetic fragments.
        clearMarkedText()
    }

    func selectedRange() -> NSRange {
        // Terminals don't have text selection in the traditional sense for IME
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        // Return range of marked text if we have any
        if markedText.isEmpty {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // Return attributed marked text for IME window
        guard !markedText.isEmpty else { return nil }

        let attributedString = NSAttributedString(
            string: markedText,
            attributes: markedTextAttributes
        )

        if actualRange != nil {
            actualRange?.pointee = NSRange(location: 0, length: markedText.utf16.count)
        }

        return attributedString
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return [
            .underlineStyle,
            .underlineColor,
            .backgroundColor,
            .foregroundColor
        ]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?, viewFrame: NSRect, window: NSWindow?, surface: ghostty_surface_t?) -> NSRect {
        // Get cursor position from Ghostty for IME window placement
        guard let surface = surface else {
            return NSRect(x: viewFrame.origin.x, y: viewFrame.origin.y, width: 0, height: 0)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0

        // Get IME cursor position from Ghostty
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // Ghostty coordinates are in top-left (0, 0) origin, but AppKit expects bottom-left
        // Convert Y coordinate by subtracting from frame height
        let viewRect = NSRect(
            x: x,
            y: viewFrame.size.height - y,
            width: range.length == 0 ? 0 : max(width, 1),
            height: max(height, 1)
        )

        // Convert to window coordinates
        guard let view = view else { return viewRect }
        let windowRect = view.convert(viewRect, to: nil)

        // Convert to screen coordinates
        guard let window = window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    // MARK: - Helper

    private func anyToString(_ string: Any) -> String? {
        switch string {
        case let string as NSString:
            return (string as String).precomposedStringWithCanonicalMapping
        case let string as NSAttributedString:
            return string.string.precomposedStringWithCanonicalMapping
        default:
            return nil
        }
    }
}
#endif
