import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Ghostty.Input {
    /// `ghostty_input_mods_e`
    struct Mods: OptionSet {
        let rawValue: UInt32

        static let none = Mods(rawValue: GHOSTTY_MODS_NONE.rawValue)
        static let shift = Mods(rawValue: GHOSTTY_MODS_SHIFT.rawValue)
        static let ctrl = Mods(rawValue: GHOSTTY_MODS_CTRL.rawValue)
        static let alt = Mods(rawValue: GHOSTTY_MODS_ALT.rawValue)
        static let `super` = Mods(rawValue: GHOSTTY_MODS_SUPER.rawValue)
        static let caps = Mods(rawValue: GHOSTTY_MODS_CAPS.rawValue)
        static let shiftRight = Mods(rawValue: GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        static let ctrlRight = Mods(rawValue: GHOSTTY_MODS_CTRL_RIGHT.rawValue)
        static let altRight = Mods(rawValue: GHOSTTY_MODS_ALT_RIGHT.rawValue)
        static let superRight = Mods(rawValue: GHOSTTY_MODS_SUPER_RIGHT.rawValue)

        var cMods: ghostty_input_mods_e {
            ghostty_input_mods_e(rawValue)
        }

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        init(cMods: ghostty_input_mods_e) {
            self.rawValue = cMods.rawValue
        }

        #if os(macOS)
        init(nsFlags: NSEvent.ModifierFlags) {
            self.init(cMods: Ghostty.ghosttyMods(nsFlags))
        }

        var nsFlags: NSEvent.ModifierFlags {
            Ghostty.eventModifierFlags(mods: cMods)
        }
        #else
        init(uiKeyModifiers: UIKeyModifierFlags) {
            var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
            if uiKeyModifiers.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
            if uiKeyModifiers.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
            if uiKeyModifiers.contains(.alternate) { mods |= GHOSTTY_MODS_ALT.rawValue }
            if uiKeyModifiers.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
            if uiKeyModifiers.contains(.alphaShift) { mods |= GHOSTTY_MODS_CAPS.rawValue }
            self.rawValue = mods
        }
        #endif
    }
}

// MARK: Ghostty.Input.ScrollMods

extension Ghostty.Input {
    /// `ghostty_input_scroll_mods_t` - Scroll event modifiers
    ///
    /// This is a packed bitmask that contains precision and momentum information
    /// for scroll events, matching the Zig `ScrollMods` packed struct.
    struct ScrollMods {
        let rawValue: Int32

        /// True if this is a high-precision scroll event (e.g., trackpad, Magic Mouse)
        var precision: Bool {
            rawValue & 0b0000_0001 != 0
        }

        /// The momentum phase of the scroll event for inertial scrolling
        var momentum: Momentum {
            let momentumBits = (rawValue >> 1) & 0b0000_0111
            return Momentum(rawValue: UInt8(momentumBits)) ?? .none
        }

        init(precision: Bool = false, momentum: Momentum = .none) {
            var value: Int32 = 0
            if precision {
                value |= 0b0000_0001
            }
            value |= Int32(momentum.rawValue) << 1
            self.rawValue = value
        }

        init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        var cScrollMods: ghostty_input_scroll_mods_t {
            rawValue
        }
    }
}
