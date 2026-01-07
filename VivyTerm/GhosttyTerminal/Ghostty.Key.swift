import Foundation

#if os(iOS)
import UIKit
#endif

extension Ghostty.Input {
    /// `ghostty_input_key_e`
    enum Key: String, CaseIterable {
        // Writing System Keys
        case backquote
        case backslash
        case bracketLeft
        case bracketRight
        case comma
        case digit0
        case digit1
        case digit2
        case digit3
        case digit4
        case digit5
        case digit6
        case digit7
        case digit8
        case digit9
        case equal
        case intlBackslash
        case intlRo
        case intlYen
        case a
        case b
        case c
        case d
        case e
        case f
        case g
        case h
        case i
        case j
        case k
        case l
        case m
        case n
        case o
        case p
        case q
        case r
        case s
        case t
        case u
        case v
        case w
        case x
        case y
        case z
        case minus
        case period
        case quote
        case semicolon
        case slash

        // Functional Keys
        case altLeft
        case altRight
        case backspace
        case capsLock
        case contextMenu
        case controlLeft
        case controlRight
        case enter
        case metaLeft
        case metaRight
        case shiftLeft
        case shiftRight
        case space
        case tab
        case convert
        case kanaMode
        case nonConvert

        // Control Pad Section
        case delete
        case end
        case help
        case home
        case insert
        case pageDown
        case pageUp

        // Arrow Pad Section
        case arrowDown
        case arrowLeft
        case arrowRight
        case arrowUp

        // Numpad Section
        case numLock
        case numpad0
        case numpad1
        case numpad2
        case numpad3
        case numpad4
        case numpad5
        case numpad6
        case numpad7
        case numpad8
        case numpad9
        case numpadAdd
        case numpadBackspace
        case numpadClear
        case numpadClearEntry
        case numpadComma
        case numpadDecimal
        case numpadDivide
        case numpadEnter
        case numpadEqual
        case numpadMemoryAdd
        case numpadMemoryClear
        case numpadMemoryRecall
        case numpadMemoryStore
        case numpadMemorySubtract
        case numpadMultiply
        case numpadParenLeft
        case numpadParenRight
        case numpadSubtract
        case numpadSeparator
        case numpadUp
        case numpadDown
        case numpadRight
        case numpadLeft
        case numpadBegin
        case numpadHome
        case numpadEnd
        case numpadInsert
        case numpadDelete
        case numpadPageUp
        case numpadPageDown

        // Function Section
        case escape
        case f1
        case f2
        case f3
        case f4
        case f5
        case f6
        case f7
        case f8
        case f9
        case f10
        case f11
        case f12
        case f13
        case f14
        case f15
        case f16
        case f17
        case f18
        case f19
        case f20
        case f21
        case f22
        case f23
        case f24
        case f25
        case fn
        case fnLock
        case printScreen
        case scrollLock
        case pause

        // Media Keys
        case browserBack
        case browserFavorites
        case browserForward
        case browserHome
        case browserRefresh
        case browserSearch
        case browserStop
        case eject
        case launchApp1
        case launchApp2
        case launchMail
        case mediaPlayPause
        case mediaSelect
        case mediaStop
        case mediaTrackNext
        case mediaTrackPrevious
        case power
        case sleep
        case audioVolumeDown
        case audioVolumeMute
        case audioVolumeUp
        case wakeUp

        // Legacy, Non-standard, and Special Keys
        case copy
        case cut
        case paste

        /// Get a key from a keycode
        init?(keyCode: UInt16) {
            if let key = Key.allCases.first(where: { $0.keyCode == keyCode }) {
                self = key
                return
            }

            return nil
        }

        var cKey: ghostty_input_key_e {
            switch self {
            // Writing System Keys
            case .backquote: GHOSTTY_KEY_BACKQUOTE
            case .backslash: GHOSTTY_KEY_BACKSLASH
            case .bracketLeft: GHOSTTY_KEY_BRACKET_LEFT
            case .bracketRight: GHOSTTY_KEY_BRACKET_RIGHT
            case .comma: GHOSTTY_KEY_COMMA
            case .digit0: GHOSTTY_KEY_DIGIT_0
            case .digit1: GHOSTTY_KEY_DIGIT_1
            case .digit2: GHOSTTY_KEY_DIGIT_2
            case .digit3: GHOSTTY_KEY_DIGIT_3
            case .digit4: GHOSTTY_KEY_DIGIT_4
            case .digit5: GHOSTTY_KEY_DIGIT_5
            case .digit6: GHOSTTY_KEY_DIGIT_6
            case .digit7: GHOSTTY_KEY_DIGIT_7
            case .digit8: GHOSTTY_KEY_DIGIT_8
            case .digit9: GHOSTTY_KEY_DIGIT_9
            case .equal: GHOSTTY_KEY_EQUAL
            case .intlBackslash: GHOSTTY_KEY_INTL_BACKSLASH
            case .intlRo: GHOSTTY_KEY_INTL_RO
            case .intlYen: GHOSTTY_KEY_INTL_YEN
            case .a: GHOSTTY_KEY_A
            case .b: GHOSTTY_KEY_B
            case .c: GHOSTTY_KEY_C
            case .d: GHOSTTY_KEY_D
            case .e: GHOSTTY_KEY_E
            case .f: GHOSTTY_KEY_F
            case .g: GHOSTTY_KEY_G
            case .h: GHOSTTY_KEY_H
            case .i: GHOSTTY_KEY_I
            case .j: GHOSTTY_KEY_J
            case .k: GHOSTTY_KEY_K
            case .l: GHOSTTY_KEY_L
            case .m: GHOSTTY_KEY_M
            case .n: GHOSTTY_KEY_N
            case .o: GHOSTTY_KEY_O
            case .p: GHOSTTY_KEY_P
            case .q: GHOSTTY_KEY_Q
            case .r: GHOSTTY_KEY_R
            case .s: GHOSTTY_KEY_S
            case .t: GHOSTTY_KEY_T
            case .u: GHOSTTY_KEY_U
            case .v: GHOSTTY_KEY_V
            case .w: GHOSTTY_KEY_W
            case .x: GHOSTTY_KEY_X
            case .y: GHOSTTY_KEY_Y
            case .z: GHOSTTY_KEY_Z
            case .minus: GHOSTTY_KEY_MINUS
            case .period: GHOSTTY_KEY_PERIOD
            case .quote: GHOSTTY_KEY_QUOTE
            case .semicolon: GHOSTTY_KEY_SEMICOLON
            case .slash: GHOSTTY_KEY_SLASH

            // Functional Keys
            case .altLeft: GHOSTTY_KEY_ALT_LEFT
            case .altRight: GHOSTTY_KEY_ALT_RIGHT
            case .backspace: GHOSTTY_KEY_BACKSPACE
            case .capsLock: GHOSTTY_KEY_CAPS_LOCK
            case .contextMenu: GHOSTTY_KEY_CONTEXT_MENU
            case .controlLeft: GHOSTTY_KEY_CONTROL_LEFT
            case .controlRight: GHOSTTY_KEY_CONTROL_RIGHT
            case .enter: GHOSTTY_KEY_ENTER
            case .metaLeft: GHOSTTY_KEY_META_LEFT
            case .metaRight: GHOSTTY_KEY_META_RIGHT
            case .shiftLeft: GHOSTTY_KEY_SHIFT_LEFT
            case .shiftRight: GHOSTTY_KEY_SHIFT_RIGHT
            case .space: GHOSTTY_KEY_SPACE
            case .tab: GHOSTTY_KEY_TAB
            case .convert: GHOSTTY_KEY_CONVERT
            case .kanaMode: GHOSTTY_KEY_KANA_MODE
            case .nonConvert: GHOSTTY_KEY_NON_CONVERT

            // Control Pad Section
            case .delete: GHOSTTY_KEY_DELETE
            case .end: GHOSTTY_KEY_END
            case .help: GHOSTTY_KEY_HELP
            case .home: GHOSTTY_KEY_HOME
            case .insert: GHOSTTY_KEY_INSERT
            case .pageDown: GHOSTTY_KEY_PAGE_DOWN
            case .pageUp: GHOSTTY_KEY_PAGE_UP

            // Arrow Pad Section
            case .arrowDown: GHOSTTY_KEY_ARROW_DOWN
            case .arrowLeft: GHOSTTY_KEY_ARROW_LEFT
            case .arrowRight: GHOSTTY_KEY_ARROW_RIGHT
            case .arrowUp: GHOSTTY_KEY_ARROW_UP

            // Numpad Section
            case .numLock: GHOSTTY_KEY_NUM_LOCK
            case .numpad0: GHOSTTY_KEY_NUMPAD_0
            case .numpad1: GHOSTTY_KEY_NUMPAD_1
            case .numpad2: GHOSTTY_KEY_NUMPAD_2
            case .numpad3: GHOSTTY_KEY_NUMPAD_3
            case .numpad4: GHOSTTY_KEY_NUMPAD_4
            case .numpad5: GHOSTTY_KEY_NUMPAD_5
            case .numpad6: GHOSTTY_KEY_NUMPAD_6
            case .numpad7: GHOSTTY_KEY_NUMPAD_7
            case .numpad8: GHOSTTY_KEY_NUMPAD_8
            case .numpad9: GHOSTTY_KEY_NUMPAD_9
            case .numpadAdd: GHOSTTY_KEY_NUMPAD_ADD
            case .numpadBackspace: GHOSTTY_KEY_NUMPAD_BACKSPACE
            case .numpadClear: GHOSTTY_KEY_NUMPAD_CLEAR
            case .numpadClearEntry: GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY
            case .numpadComma: GHOSTTY_KEY_NUMPAD_COMMA
            case .numpadDecimal: GHOSTTY_KEY_NUMPAD_DECIMAL
            case .numpadDivide: GHOSTTY_KEY_NUMPAD_DIVIDE
            case .numpadEnter: GHOSTTY_KEY_NUMPAD_ENTER
            case .numpadEqual: GHOSTTY_KEY_NUMPAD_EQUAL
            case .numpadMemoryAdd: GHOSTTY_KEY_NUMPAD_MEMORY_ADD
            case .numpadMemoryClear: GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR
            case .numpadMemoryRecall: GHOSTTY_KEY_NUMPAD_MEMORY_RECALL
            case .numpadMemoryStore: GHOSTTY_KEY_NUMPAD_MEMORY_STORE
            case .numpadMemorySubtract: GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT
            case .numpadMultiply: GHOSTTY_KEY_NUMPAD_MULTIPLY
            case .numpadParenLeft: GHOSTTY_KEY_NUMPAD_PAREN_LEFT
            case .numpadParenRight: GHOSTTY_KEY_NUMPAD_PAREN_RIGHT
            case .numpadSubtract: GHOSTTY_KEY_NUMPAD_SUBTRACT
            case .numpadSeparator: GHOSTTY_KEY_NUMPAD_SEPARATOR
            case .numpadUp: GHOSTTY_KEY_NUMPAD_UP
            case .numpadDown: GHOSTTY_KEY_NUMPAD_DOWN
            case .numpadRight: GHOSTTY_KEY_NUMPAD_RIGHT
            case .numpadLeft: GHOSTTY_KEY_NUMPAD_LEFT
            case .numpadBegin: GHOSTTY_KEY_NUMPAD_BEGIN
            case .numpadHome: GHOSTTY_KEY_NUMPAD_HOME
            case .numpadEnd: GHOSTTY_KEY_NUMPAD_END
            case .numpadInsert: GHOSTTY_KEY_NUMPAD_INSERT
            case .numpadDelete: GHOSTTY_KEY_NUMPAD_DELETE
            case .numpadPageUp: GHOSTTY_KEY_NUMPAD_PAGE_UP
            case .numpadPageDown: GHOSTTY_KEY_NUMPAD_PAGE_DOWN

            // Function Section
            case .escape: GHOSTTY_KEY_ESCAPE
            case .f1: GHOSTTY_KEY_F1
            case .f2: GHOSTTY_KEY_F2
            case .f3: GHOSTTY_KEY_F3
            case .f4: GHOSTTY_KEY_F4
            case .f5: GHOSTTY_KEY_F5
            case .f6: GHOSTTY_KEY_F6
            case .f7: GHOSTTY_KEY_F7
            case .f8: GHOSTTY_KEY_F8
            case .f9: GHOSTTY_KEY_F9
            case .f10: GHOSTTY_KEY_F10
            case .f11: GHOSTTY_KEY_F11
            case .f12: GHOSTTY_KEY_F12
            case .f13: GHOSTTY_KEY_F13
            case .f14: GHOSTTY_KEY_F14
            case .f15: GHOSTTY_KEY_F15
            case .f16: GHOSTTY_KEY_F16
            case .f17: GHOSTTY_KEY_F17
            case .f18: GHOSTTY_KEY_F18
            case .f19: GHOSTTY_KEY_F19
            case .f20: GHOSTTY_KEY_F20
            case .f21: GHOSTTY_KEY_F21
            case .f22: GHOSTTY_KEY_F22
            case .f23: GHOSTTY_KEY_F23
            case .f24: GHOSTTY_KEY_F24
            case .f25: GHOSTTY_KEY_F25
            case .fn: GHOSTTY_KEY_FN
            case .fnLock: GHOSTTY_KEY_FN_LOCK
            case .printScreen: GHOSTTY_KEY_PRINT_SCREEN
            case .scrollLock: GHOSTTY_KEY_SCROLL_LOCK
            case .pause: GHOSTTY_KEY_PAUSE

            // Media Keys
            case .browserBack: GHOSTTY_KEY_BROWSER_BACK
            case .browserFavorites: GHOSTTY_KEY_BROWSER_FAVORITES
            case .browserForward: GHOSTTY_KEY_BROWSER_FORWARD
            case .browserHome: GHOSTTY_KEY_BROWSER_HOME
            case .browserRefresh: GHOSTTY_KEY_BROWSER_REFRESH
            case .browserSearch: GHOSTTY_KEY_BROWSER_SEARCH
            case .browserStop: GHOSTTY_KEY_BROWSER_STOP
            case .eject: GHOSTTY_KEY_EJECT
            case .launchApp1: GHOSTTY_KEY_LAUNCH_APP_1
            case .launchApp2: GHOSTTY_KEY_LAUNCH_APP_2
            case .launchMail: GHOSTTY_KEY_LAUNCH_MAIL
            case .mediaPlayPause: GHOSTTY_KEY_MEDIA_PLAY_PAUSE
            case .mediaSelect: GHOSTTY_KEY_MEDIA_SELECT
            case .mediaStop: GHOSTTY_KEY_MEDIA_STOP
            case .mediaTrackNext: GHOSTTY_KEY_MEDIA_TRACK_NEXT
            case .mediaTrackPrevious: GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS
            case .power: GHOSTTY_KEY_POWER
            case .sleep: GHOSTTY_KEY_SLEEP
            case .audioVolumeDown: GHOSTTY_KEY_AUDIO_VOLUME_DOWN
            case .audioVolumeMute: GHOSTTY_KEY_AUDIO_VOLUME_MUTE
            case .audioVolumeUp: GHOSTTY_KEY_AUDIO_VOLUME_UP
            case .wakeUp: GHOSTTY_KEY_WAKE_UP

            // Legacy, Non-standard, and Special Keys
            case .copy: GHOSTTY_KEY_COPY
            case .cut: GHOSTTY_KEY_CUT
            case .paste: GHOSTTY_KEY_PASTE
            }
        }

        // Based on src/input/keycodes.zig
        var keyCode: UInt16? {
            switch self {
            // Writing System Keys
            case .backquote: return 0x0032
            case .backslash: return 0x002a
            case .bracketLeft: return 0x0021
            case .bracketRight: return 0x001e
            case .comma: return 0x002b
            case .digit0: return 0x001d
            case .digit1: return 0x0012
            case .digit2: return 0x0013
            case .digit3: return 0x0014
            case .digit4: return 0x0015
            case .digit5: return 0x0017
            case .digit6: return 0x0016
            case .digit7: return 0x001a
            case .digit8: return 0x001c
            case .digit9: return 0x0019
            case .equal: return 0x0018
            case .intlBackslash: return 0x000a
            case .intlRo: return 0x005e
            case .intlYen: return 0x005d
            case .a: return 0x0000
            case .b: return 0x000b
            case .c: return 0x0008
            case .d: return 0x0002
            case .e: return 0x000e
            case .f: return 0x0003
            case .g: return 0x0005
            case .h: return 0x0004
            case .i: return 0x0022
            case .j: return 0x0026
            case .k: return 0x0028
            case .l: return 0x0025
            case .m: return 0x002e
            case .n: return 0x002d
            case .o: return 0x001f
            case .p: return 0x0023
            case .q: return 0x000c
            case .r: return 0x000f
            case .s: return 0x0001
            case .t: return 0x0011
            case .u: return 0x0020
            case .v: return 0x0009
            case .w: return 0x000d
            case .x: return 0x0007
            case .y: return 0x0010
            case .z: return 0x0006
            case .minus: return 0x001b
            case .period: return 0x002f
            case .quote: return 0x0027
            case .semicolon: return 0x0029
            case .slash: return 0x002c

            // Functional Keys
            case .altLeft: return 0x003a
            case .altRight: return 0x003d
            case .backspace: return 0x0033
            case .capsLock: return 0x0039
            case .contextMenu: return 0x006e
            case .controlLeft: return 0x003b
            case .controlRight: return 0x003e
            case .enter: return 0x0024
            case .metaLeft: return 0x0037
            case .metaRight: return 0x0036
            case .shiftLeft: return 0x0038
            case .shiftRight: return 0x003c
            case .space: return 0x0031
            case .tab: return 0x0030
            case .convert: return nil // No Mac keycode
            case .kanaMode: return nil // No Mac keycode
            case .nonConvert: return nil // No Mac keycode

            // Control Pad Section
            case .delete: return 0x0075
            case .end: return 0x0077
            case .help: return nil // No Mac keycode
            case .home: return 0x0073
            case .insert: return 0x0072
            case .pageDown: return 0x0079
            case .pageUp: return 0x0074

            // Arrow Pad Section
            case .arrowDown: return 0x007d
            case .arrowLeft: return 0x007b
            case .arrowRight: return 0x007c
            case .arrowUp: return 0x007e

            // Numpad Section
            case .numLock: return 0x0047
            case .numpad0: return 0x0052
            case .numpad1: return 0x0053
            case .numpad2: return 0x0054
            case .numpad3: return 0x0055
            case .numpad4: return 0x0056
            case .numpad5: return 0x0057
            case .numpad6: return 0x0058
            case .numpad7: return 0x0059
            case .numpad8: return 0x005b
            case .numpad9: return 0x005c
            case .numpadAdd: return 0x0045
            case .numpadBackspace: return nil // No Mac keycode
            case .numpadClear: return nil // No Mac keycode
            case .numpadClearEntry: return nil // No Mac keycode
            case .numpadComma: return 0x005f
            case .numpadDecimal: return 0x0041
            case .numpadDivide: return 0x004b
            case .numpadEnter: return 0x004c
            case .numpadEqual: return 0x0051
            case .numpadMemoryAdd: return nil // No Mac keycode
            case .numpadMemoryClear: return nil // No Mac keycode
            case .numpadMemoryRecall: return nil // No Mac keycode
            case .numpadMemoryStore: return nil // No Mac keycode
            case .numpadMemorySubtract: return nil // No Mac keycode
            case .numpadMultiply: return 0x0043
            case .numpadParenLeft: return nil // No Mac keycode
            case .numpadParenRight: return nil // No Mac keycode
            case .numpadSubtract: return 0x004e
            case .numpadSeparator: return nil // No Mac keycode
            case .numpadUp: return nil // No Mac keycode
            case .numpadDown: return nil // No Mac keycode
            case .numpadRight: return nil // No Mac keycode
            case .numpadLeft: return nil // No Mac keycode
            case .numpadBegin: return nil // No Mac keycode
            case .numpadHome: return nil // No Mac keycode
            case .numpadEnd: return nil // No Mac keycode
            case .numpadInsert: return nil // No Mac keycode
            case .numpadDelete: return nil // No Mac keycode
            case .numpadPageUp: return nil // No Mac keycode
            case .numpadPageDown: return nil // No Mac keycode

            // Function Section
            case .escape: return 0x0035
            case .f1: return 0x007a
            case .f2: return 0x0078
            case .f3: return 0x0063
            case .f4: return 0x0076
            case .f5: return 0x0060
            case .f6: return 0x0061
            case .f7: return 0x0062
            case .f8: return 0x0064
            case .f9: return 0x0065
            case .f10: return 0x006d
            case .f11: return 0x0067
            case .f12: return 0x006f
            case .f13: return 0x0069
            case .f14: return 0x006b
            case .f15: return 0x0071
            case .f16: return 0x006a
            case .f17: return 0x0040
            case .f18: return 0x004f
            case .f19: return 0x0050
            case .f20: return 0x005a
            case .f21: return nil // No Mac keycode
            case .f22: return nil // No Mac keycode
            case .f23: return nil // No Mac keycode
            case .f24: return nil // No Mac keycode
            case .f25: return nil // No Mac keycode
            case .fn: return nil // No Mac keycode
            case .fnLock: return nil // No Mac keycode
            case .printScreen: return nil // No Mac keycode
            case .scrollLock: return nil // No Mac keycode
            case .pause: return nil // No Mac keycode

            // Media Keys
            case .browserBack: return nil // No Mac keycode
            case .browserFavorites: return nil // No Mac keycode
            case .browserForward: return nil // No Mac keycode
            case .browserHome: return nil // No Mac keycode
            case .browserRefresh: return nil // No Mac keycode
            case .browserSearch: return nil // No Mac keycode
            case .browserStop: return nil // No Mac keycode
            case .eject: return nil // No Mac keycode
            case .launchApp1: return nil // No Mac keycode
            case .launchApp2: return nil // No Mac keycode
            case .launchMail: return nil // No Mac keycode
            case .mediaPlayPause: return nil // No Mac keycode
            case .mediaSelect: return nil // No Mac keycode
            case .mediaStop: return nil // No Mac keycode
            case .mediaTrackNext: return nil // No Mac keycode
            case .mediaTrackPrevious: return nil // No Mac keycode
            case .power: return nil // No Mac keycode
            case .sleep: return nil // No Mac keycode
            case .audioVolumeDown: return 0x0049
            case .audioVolumeMute: return 0x004a
            case .audioVolumeUp: return 0x0048
            case .wakeUp: return nil // No Mac keycode

            // Legacy, Non-standard, and Special Keys
            case .copy: return nil // No Mac keycode
            case .cut: return nil // No Mac keycode
            case .paste: return nil // No Mac keycode
            }
        }

        #if os(iOS)
        /// Create a Key from a UIKeyboardHIDUsage code (iOS hardware keyboard)
        init?(uiKeyCode: UIKeyboardHIDUsage) {
            // Map UIKeyboardHIDUsage to Ghostty Key
            switch uiKeyCode {
            // Letters
            case .keyboardA: self = .a
            case .keyboardB: self = .b
            case .keyboardC: self = .c
            case .keyboardD: self = .d
            case .keyboardE: self = .e
            case .keyboardF: self = .f
            case .keyboardG: self = .g
            case .keyboardH: self = .h
            case .keyboardI: self = .i
            case .keyboardJ: self = .j
            case .keyboardK: self = .k
            case .keyboardL: self = .l
            case .keyboardM: self = .m
            case .keyboardN: self = .n
            case .keyboardO: self = .o
            case .keyboardP: self = .p
            case .keyboardQ: self = .q
            case .keyboardR: self = .r
            case .keyboardS: self = .s
            case .keyboardT: self = .t
            case .keyboardU: self = .u
            case .keyboardV: self = .v
            case .keyboardW: self = .w
            case .keyboardX: self = .x
            case .keyboardY: self = .y
            case .keyboardZ: self = .z

            // Numbers
            case .keyboard0: self = .digit0
            case .keyboard1: self = .digit1
            case .keyboard2: self = .digit2
            case .keyboard3: self = .digit3
            case .keyboard4: self = .digit4
            case .keyboard5: self = .digit5
            case .keyboard6: self = .digit6
            case .keyboard7: self = .digit7
            case .keyboard8: self = .digit8
            case .keyboard9: self = .digit9

            // Functional keys
            case .keyboardReturnOrEnter: self = .enter
            case .keyboardEscape: self = .escape
            case .keyboardDeleteOrBackspace: self = .backspace
            case .keyboardTab: self = .tab
            case .keyboardSpacebar: self = .space
            case .keyboardHyphen: self = .minus
            case .keyboardEqualSign: self = .equal
            case .keyboardOpenBracket: self = .bracketLeft
            case .keyboardCloseBracket: self = .bracketRight
            case .keyboardBackslash: self = .backslash
            case .keyboardSemicolon: self = .semicolon
            case .keyboardQuote: self = .quote
            case .keyboardGraveAccentAndTilde: self = .backquote
            case .keyboardComma: self = .comma
            case .keyboardPeriod: self = .period
            case .keyboardSlash: self = .slash

            // Arrow keys
            case .keyboardUpArrow: self = .arrowUp
            case .keyboardDownArrow: self = .arrowDown
            case .keyboardLeftArrow: self = .arrowLeft
            case .keyboardRightArrow: self = .arrowRight

            // Navigation
            case .keyboardHome: self = .home
            case .keyboardEnd: self = .end
            case .keyboardPageUp: self = .pageUp
            case .keyboardPageDown: self = .pageDown
            case .keyboardDeleteForward: self = .delete
            case .keyboardInsert: self = .insert

            // Modifiers
            case .keyboardCapsLock: self = .capsLock
            case .keyboardLeftShift: self = .shiftLeft
            case .keyboardRightShift: self = .shiftRight
            case .keyboardLeftControl: self = .controlLeft
            case .keyboardRightControl: self = .controlRight
            case .keyboardLeftAlt: self = .altLeft
            case .keyboardRightAlt: self = .altRight
            case .keyboardLeftGUI: self = .metaLeft
            case .keyboardRightGUI: self = .metaRight

            // Function keys
            case .keyboardF1: self = .f1
            case .keyboardF2: self = .f2
            case .keyboardF3: self = .f3
            case .keyboardF4: self = .f4
            case .keyboardF5: self = .f5
            case .keyboardF6: self = .f6
            case .keyboardF7: self = .f7
            case .keyboardF8: self = .f8
            case .keyboardF9: self = .f9
            case .keyboardF10: self = .f10
            case .keyboardF11: self = .f11
            case .keyboardF12: self = .f12

            // Numpad
            case .keypad0: self = .numpad0
            case .keypad1: self = .numpad1
            case .keypad2: self = .numpad2
            case .keypad3: self = .numpad3
            case .keypad4: self = .numpad4
            case .keypad5: self = .numpad5
            case .keypad6: self = .numpad6
            case .keypad7: self = .numpad7
            case .keypad8: self = .numpad8
            case .keypad9: self = .numpad9
            case .keypadPlus: self = .numpadAdd
            case .keypadHyphen: self = .numpadSubtract
            case .keypadAsterisk: self = .numpadMultiply
            case .keypadSlash: self = .numpadDivide
            case .keypadEnter: self = .numpadEnter
            case .keypadPeriod: self = .numpadDecimal
            case .keypadEqualSign: self = .numpadEqual

            default: return nil
            }
        }
        #endif
    }
}
