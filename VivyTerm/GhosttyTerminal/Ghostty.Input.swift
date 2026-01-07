import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
extension SwiftUI.EventModifiers {
    /// Initialize EventModifiers from NSEvent.ModifierFlags
    init(nsFlags: NSEvent.ModifierFlags) {
        var modifiers = SwiftUI.EventModifiers()
        if nsFlags.contains(.shift) { modifiers.insert(.shift) }
        if nsFlags.contains(.control) { modifiers.insert(.control) }
        if nsFlags.contains(.option) { modifiers.insert(.option) }
        if nsFlags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
#endif

extension Ghostty {
    // Input types split into separate files: Ghostty.Key.swift, Ghostty.MouseEvent.swift, Ghostty.KeyEvent.swift, Ghostty.Mods.swift
    struct Input {}

    #if os(macOS)
    // MARK: Keyboard Shortcuts

    /// Return the key equivalent for the given trigger.
    ///
    /// Returns nil if the trigger doesn't have an equivalent KeyboardShortcut. This is possible
    /// because Ghostty input triggers are a superset of what can be represented by a macOS
    /// KeyboardShortcut. For example, macOS doesn't have any way to represent function keys
    /// (F1, F2, ...) with a KeyboardShortcut. This doesn't represent a practical issue because input
    /// handling for Ghostty is handled at a lower level (usually). This function should generally only
    /// be used for things like NSMenu that only support keyboard shortcuts anyways.
    static func keyboardShortcut(for trigger: ghostty_input_trigger_s) -> KeyboardShortcut? {
        let key: KeyEquivalent
        switch (trigger.tag) {
        case GHOSTTY_TRIGGER_PHYSICAL:
            // Only functional keys can be converted to a KeyboardShortcut. Other physical
            // mappings cannot because KeyboardShortcut in Swift is inherently layout-dependent.
            if let equiv = Self.keyToEquivalent[trigger.key.physical.rawValue] {
                key = equiv
            } else {
                return nil
            }

        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = KeyEquivalent(Character(scalar))

        default:
            return nil
        }

        return KeyboardShortcut(
            key,
            modifiers: EventModifiers(nsFlags: Ghostty.eventModifierFlags(mods: trigger.mods)))
    }

    // MARK: Mods

    /// Returns the event modifier flags set for the Ghostty mods enum.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0);
        if (mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0) { flags.insert(.shift) }
        if (mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0) { flags.insert(.control) }
        if (mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0) { flags.insert(.option) }
        if (mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0) { flags.insert(.command) }
        return flags
    }

    /// Translate event modifier flags to a ghostty mods enum.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if (flags.contains(.shift)) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if (flags.contains(.control)) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if (flags.contains(.option)) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if (flags.contains(.command)) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if (flags.contains(.capsLock)) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Handle sided input. We can't tell that both are pressed in the
        // Ghostty structure but thats okay -- we don't use that information.
        let rawFlags = flags.rawValue
        if (rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0) { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0) { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0) { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0) { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    /// A map from the Ghostty key enum to the keyEquivalent string for shortcuts. Note that
    /// not all ghostty key enum values are represented here because not all of them can be
    /// mapped to a KeyEquivalent.
    static let keyToEquivalent: [UInt32 : KeyEquivalent] = [
        // Function keys
        GHOSTTY_KEY_ARROW_UP.rawValue: .upArrow,
        GHOSTTY_KEY_ARROW_DOWN.rawValue: .downArrow,
        GHOSTTY_KEY_ARROW_LEFT.rawValue: .leftArrow,
        GHOSTTY_KEY_ARROW_RIGHT.rawValue: .rightArrow,
        GHOSTTY_KEY_HOME.rawValue: .home,
        GHOSTTY_KEY_END.rawValue: .end,
        GHOSTTY_KEY_DELETE.rawValue: .delete,
        GHOSTTY_KEY_PAGE_UP.rawValue: .pageUp,
        GHOSTTY_KEY_PAGE_DOWN.rawValue: .pageDown,
        GHOSTTY_KEY_ESCAPE.rawValue: .escape,
        GHOSTTY_KEY_ENTER.rawValue: .return,
        GHOSTTY_KEY_TAB.rawValue: .tab,
        GHOSTTY_KEY_BACKSPACE.rawValue: .delete,
        GHOSTTY_KEY_SPACE.rawValue: .space,
    ]
    #else
    // MARK: iOS Modifier Conversion

    /// Translate UIKeyModifierFlags to a ghostty mods enum.
    static func ghosttyMods(_ flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        return ghostty_input_mods_e(mods)
    }
    #endif
}
