import Foundation

#if os(iOS)
import UIKit
#endif

extension Ghostty.Input {
    /// `ghostty_input_key_s`
    struct KeyEvent {
        let action: Action
        let key: Key
        let text: String?
        let composing: Bool
        let mods: Mods
        let consumedMods: Mods
        let unshiftedCodepoint: UInt32

        init(
            key: Key,
            action: Action = .press,
            text: String? = nil,
            composing: Bool = false,
            mods: Mods = [],
            consumedMods: Mods = [],
            unshiftedCodepoint: UInt32 = 0
        ) {
            self.key = key
            self.action = action
            self.text = text
            self.composing = composing
            self.mods = mods
            self.consumedMods = consumedMods
            self.unshiftedCodepoint = unshiftedCodepoint
        }

        init?(cValue: ghostty_input_key_s) {
            // Convert action
            switch cValue.action {
            case GHOSTTY_ACTION_PRESS: self.action = .press
            case GHOSTTY_ACTION_RELEASE: self.action = .release
            case GHOSTTY_ACTION_REPEAT: self.action = .repeat
            default: self.action = .press
            }

            // Convert key from keycode
            guard let key = Key(keyCode: UInt16(cValue.keycode)) else { return nil }
            self.key = key

            // Convert text
            if let textPtr = cValue.text {
                self.text = String(cString: textPtr)
            } else {
                self.text = nil
            }

            // Set composing state
            self.composing = cValue.composing

            // Convert modifiers
            self.mods = Mods(cMods: cValue.mods)
            self.consumedMods = Mods(cMods: cValue.consumed_mods)

            // Set unshifted codepoint
            self.unshiftedCodepoint = cValue.unshifted_codepoint
        }

        #if os(iOS)
        /// Create a KeyEvent from a UIKey (iOS hardware keyboard)
        init?(uiKey: UIKey, action: Action) {
            let mods = Mods(uiKeyModifiers: uiKey.modifierFlags)
            let hasModifierShortcut = mods.contains(.ctrl) || mods.contains(.alt) || mods.contains(.super)

            let characters = uiKey.characters.precomposedStringWithCanonicalMapping
            let filteredCharacters: String? = {
                guard !characters.isEmpty else { return nil }
                if characters.count == 1, let scalar = characters.unicodeScalars.first {
                    // Skip control characters and PUA function-key scalars.
                    if scalar.value < 0x20 { return nil }
                    if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
                }
                return characters
            }()

            // Map UIKey to Ghostty key
            guard let key = Key(uiKeyCode: uiKey.keyCode) else {
                // If we can't map the key but have characters, create a text-based event
                if !hasModifierShortcut, let text = filteredCharacters {
                    self.key = .space  // Fallback key
                    self.action = action
                    self.text = text
                    self.composing = false
                    self.mods = mods
                    self.consumedMods = []
                    self.unshiftedCodepoint = text.unicodeScalars.first?.value ?? 0
                    return
                }
                return nil
            }

            self.key = key
            self.action = action
            // For modifier shortcuts (Ctrl/Alt/Cmd), pass pure key+mods through
            // and avoid injecting text payload that can confuse terminal handling.
            if hasModifierShortcut {
                self.text = nil
            } else {
                self.text = filteredCharacters
            }
            self.composing = false
            self.mods = mods
            self.consumedMods = []

            // Get unshifted codepoint from charactersIgnoringModifiers if available
            let unshiftedChars = uiKey.charactersIgnoringModifiers.precomposedStringWithCanonicalMapping
            if let scalar = unshiftedChars.unicodeScalars.first,
               scalar.value >= 0x20,
               !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF) {
                self.unshiftedCodepoint = scalar.value
            } else {
                self.unshiftedCodepoint = 0
            }
        }
        #endif

        /// Executes a closure with a temporary C representation of this KeyEvent.
        ///
        /// This method safely converts the Swift KeyEntity to a C `ghostty_input_key_s` struct
        /// and passes it to the provided closure. The C struct is only valid within the closure's
        /// execution scope. The text field's C string pointer is managed automatically and will
        /// be invalid after the closure returns.
        ///
        /// - Parameter execute: A closure that receives the C struct and returns a value
        /// - Returns: The value returned by the closure
        @discardableResult
        func withCValue<T>(execute: (ghostty_input_key_s) -> T) -> T {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action.cAction
            keyEvent.keycode = UInt32(key.keyCode ?? 0)
            keyEvent.composing = composing
            keyEvent.mods = mods.cMods
            keyEvent.consumed_mods = consumedMods.cMods
            keyEvent.unshifted_codepoint = unshiftedCodepoint

            // Handle text with proper memory management
            if let text = text {
                return text.withCString { textPtr in
                    keyEvent.text = textPtr
                    return execute(keyEvent)
                }
            } else {
                keyEvent.text = nil
                return execute(keyEvent)
            }
        }
    }
}

// MARK: Ghostty.Input.Action

extension Ghostty.Input {
    /// `ghostty_input_action_e`
    enum Action: String, CaseIterable {
        case release
        case press
        case `repeat`

        var cAction: ghostty_input_action_e {
            switch self {
            case .release: GHOSTTY_ACTION_RELEASE
            case .press: GHOSTTY_ACTION_PRESS
            case .repeat: GHOSTTY_ACTION_REPEAT
            }
        }
    }
}
