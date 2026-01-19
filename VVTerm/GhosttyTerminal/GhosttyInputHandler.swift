//
//  GhosttyInputHandler.swift
//  aizen
//
//  Handles keyboard, mouse, and scroll input forwarding to Ghostty terminal
//

#if os(macOS)
import AppKit
import OSLog

/// Manages input event forwarding (keyboard, mouse, scroll) to Ghostty terminal
@MainActor
class GhosttyInputHandler {
    // MARK: - Properties

    private weak var view: NSView?
    private weak var surface: Ghostty.Surface?
    private weak var imeHandler: GhosttyIMEHandler?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "win.aizen.app", category: "GhosttyInput")

    // MARK: - Initialization

    init(view: NSView, surface: Ghostty.Surface?, imeHandler: GhosttyIMEHandler) {
        self.view = view
        self.surface = surface
        self.imeHandler = imeHandler
    }

    // MARK: - Public API

    /// Update surface reference
    func updateSurface(_ surface: Ghostty.Surface?) {
        self.surface = surface
    }

    // MARK: - Keyboard Input

    func handleKeyDown(with event: NSEvent, interpretKeyEvents: @escaping ([NSEvent]) -> Void) {
        guard let surface = surface else {
            Self.logger.warning("keyDown: no surface")
            // Even without surface, call interpretKeyEvents for IME support
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Track if we had marked text before this event
        // Important for handling ESC and backspace during IME composition
        let markedTextBefore = imeHandler?.hasMarkedText ?? false

        // Set up key text accumulator to track insertText calls
        imeHandler?.beginKeyTextAccumulation()
        defer {
            _ = imeHandler?.endKeyTextAccumulation()
        }

        // Call interpretKeyEvents to allow IME processing
        // This may call insertText (text committed) or setMarkedText (composing)
        interpretKeyEvents([event])

        // If we have accumulated text, it means insertText was called
        // Send the composed text to the terminal
        if let texts = imeHandler?.endKeyTextAccumulation(), !texts.isEmpty {
            for text in texts {
                text.withCString { ptr in
                    var keyEvent = event.ghosttyKeyEvent(action)
                    keyEvent.text = ptr
                    keyEvent.composing = false
                    ghostty_surface_key(surface.unsafeCValue, keyEvent)
                }
            }
            return
        }

        // If we're still composing (have marked text), don't send key event
        // OR if we had marked text before and pressed a key like backspace/ESC,
        // we're still in composing mode
        let isComposing = (imeHandler?.hasMarkedText ?? false) || markedTextBefore
        if isComposing {
            // ESC or backspace during composition shouldn't be sent to terminal
            return
        }

        // Normal key event - no IME involvement
        // Call ghostty_surface_key directly (like Ghostty does) to avoid
        // potential issues with Swift wrapper conversions dropping events
        var keyEvent = event.ghosttyKeyEvent(action)

        // Set text field if we have printable characters
        // Control characters (< 0x20) are encoded by Ghostty itself
        if let chars = event.ghosttyCharacters,
           let codepoint = chars.utf8.first,
           codepoint >= 0x20 {
            chars.withCString { textPtr in
                keyEvent.text = textPtr
                keyEvent.composing = false
                ghostty_surface_key(surface.unsafeCValue, keyEvent)
            }
        } else {
            keyEvent.text = nil
            keyEvent.composing = false
            ghostty_surface_key(surface.unsafeCValue, keyEvent)
        }
    }

    func handleKeyUp(with event: NSEvent) {
        guard let surface = surface else { return }

        var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE)
        keyEvent.text = nil

        if let inputEvent = Ghostty.Input.KeyEvent(cValue: keyEvent) {
            surface.sendKeyEvent(inputEvent)
        }
    }

    func handleFlagsChanged(with event: NSEvent) {
        guard let surface = surface?.unsafeCValue else { return }

        // Determine which modifier key changed
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        let mod: UInt32

        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // Determine if press or release
        let action: ghostty_input_action_e = (mods.rawValue & mod != 0)
            ? GHOSTTY_ACTION_PRESS
            : GHOSTTY_ACTION_RELEASE

        // Send to Ghostty
        var keyEvent = event.ghosttyKeyEvent(action)
        keyEvent.text = nil
        ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Mouse Input

    func handleMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }

        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .press,
            button: .left,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMouseButton(mouseEvent)
    }

    func handleMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }

        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .release,
            button: .left,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMouseButton(mouseEvent)
    }

    func handleRightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }

        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .press,
            button: .right,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMouseButton(mouseEvent)
    }

    func handleRightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }

        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .release,
            button: .right,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMouseButton(mouseEvent)
    }

    func handleOtherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        guard let surface = surface else { return }

        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .press,
            button: .middle,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMouseButton(mouseEvent)
    }

    func handleOtherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        guard let surface = surface else { return }

        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .release,
            button: .middle,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMouseButton(mouseEvent)
    }

    func handleMouseMoved(with event: NSEvent, viewFrame: NSRect, convertPoint: (NSPoint, NSView?) -> NSPoint) {
        guard let surface = surface else { return }

        // Convert window coords to view coords
        // Ghostty expects top-left origin (y inverted from AppKit)
        let pos = convertPoint(event.locationInWindow, nil)
        let mouseEvent = Ghostty.Input.MousePosEvent(
            x: pos.x,
            y: viewFrame.height - pos.y,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMousePos(mouseEvent)
    }

    func handleMouseEntered(with event: NSEvent, viewFrame: NSRect, convertPoint: (NSPoint, NSView?) -> NSPoint) {
        guard let surface = surface else { return }

        // Report mouse entering the viewport
        let pos = convertPoint(event.locationInWindow, nil)
        let mouseEvent = Ghostty.Input.MousePosEvent(
            x: pos.x,
            y: viewFrame.height - pos.y,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMousePos(mouseEvent)
    }

    func handleMouseExited(with event: NSEvent) {
        guard let surface = surface else { return }

        // Negative values signal cursor left viewport
        let mouseEvent = Ghostty.Input.MousePosEvent(
            x: -1,
            y: -1,
            mods: Ghostty.Input.Mods(nsFlags: event.modifierFlags)
        )
        surface.sendMousePos(mouseEvent)
    }

    // MARK: - Scroll Input

    func handleScrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas

        if precision {
            // 2x speed multiplier for precise scrolling (trackpad)
            x *= 2
            y *= 2
        }

        let scrollEvent = Ghostty.Input.MouseScrollEvent(
            x: x,
            y: y,
            mods: Ghostty.Input.ScrollMods(
                precision: precision,
                momentum: Ghostty.Input.Momentum(event.momentumPhase)
            )
        )
        surface.sendMouseScroll(scrollEvent)
    }
}

// MARK: - NSEvent Extensions

extension NSEvent {
    /// Create a Ghostty key event from NSEvent
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.mods = Ghostty.ghosttyMods(modifierFlags)
        keyEvent.consumed_mods = Ghostty.ghosttyMods(
            modifierFlags.subtracting([.control, .command])
        )

        // Unshifted codepoint for key identification
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            keyEvent.unshifted_codepoint = codepoint.value
        } else {
            keyEvent.unshifted_codepoint = 0
        }

        keyEvent.text = nil
        keyEvent.composing = false

        return keyEvent
    }

    /// Get characters appropriate for Ghostty (excluding control chars and PUA)
    var ghosttyCharacters: String? {
        guard let characters = characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // Skip control characters (Ghostty handles internally)
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            // Skip Private Use Area (function keys)
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
#endif
