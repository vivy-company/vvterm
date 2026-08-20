import Foundation

nonisolated extension TerminalSnippetSendMode {
    var title: String {
        switch self {
        case .insert:
            return String(localized: "Insert")
        case .insertAndEnter:
            return String(localized: "Insert + Enter")
        }
    }
}

nonisolated extension TerminalAccessoryCustomActionKind {
    var title: String {
        switch self {
        case .command:
            return String(localized: "Command")
        case .shortcut:
            return String(localized: "Shortcut")
        }
    }
}

nonisolated extension TerminalAccessoryShortcutModifiers {
    var displayParts: [String] {
        var parts: [String] = []
        if control {
            parts.append(String(localized: "Ctrl"))
        }
        if alternate {
            parts.append(String(localized: "Alt"))
        }
        if command {
            parts.append(String(localized: "Cmd"))
        }
        if shift {
            parts.append(String(localized: "Shift"))
        }
        return parts
    }

    func displayTitle(for keyTitle: String) -> String {
        (displayParts + [keyTitle]).joined(separator: "+")
    }
}

nonisolated extension TerminalAccessoryShortcutKey {
    var title: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        case .digit0: return "0"
        case .digit1: return "1"
        case .digit2: return "2"
        case .digit3: return "3"
        case .digit4: return "4"
        case .digit5: return "5"
        case .digit6: return "6"
        case .digit7: return "7"
        case .digit8: return "8"
        case .digit9: return "9"
        case .backquote: return "`"
        case .minus: return "-"
        case .equal: return "="
        case .bracketLeft: return "["
        case .bracketRight: return "]"
        case .backslash: return "\\"
        case .semicolon: return ";"
        case .quote: return "'"
        case .comma: return ","
        case .period: return "."
        case .slash: return "/"
        case .space: return String(localized: "Space")
        case .escape: return String(localized: "Esc")
        case .tab: return String(localized: "Tab")
        case .enter: return String(localized: "Enter")
        case .backspace: return String(localized: "Backspace")
        case .delete: return String(localized: "Delete")
        case .insert: return String(localized: "Insert")
        case .home: return String(localized: "Home")
        case .end: return String(localized: "End")
        case .pageUp: return String(localized: "Page Up")
        case .pageDown: return String(localized: "Page Down")
        case .arrowUp: return String(localized: "Arrow Up")
        case .arrowDown: return String(localized: "Arrow Down")
        case .arrowLeft: return String(localized: "Arrow Left")
        case .arrowRight: return String(localized: "Arrow Right")
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }
}

nonisolated extension TerminalAccessorySystemActionID {
    var listTitle: String {
        switch self {
        case .commandModifier: return String(localized: "Cmd")
        case .escape: return String(localized: "Esc")
        case .tab: return String(localized: "Tab")
        case .shiftTab: return String(localized: "Shift+Tab")
        case .enter: return String(localized: "Enter")
        case .backspace: return String(localized: "Backspace")
        case .delete: return String(localized: "Delete")
        case .insert: return String(localized: "Insert")
        case .home: return String(localized: "Home")
        case .end: return String(localized: "End")
        case .pageUp: return String(localized: "Page Up")
        case .pageDown: return String(localized: "Page Down")
        case .arrowUp: return String(localized: "Arrow Up")
        case .arrowDown: return String(localized: "Arrow Down")
        case .arrowLeft: return String(localized: "Arrow Left")
        case .arrowRight: return String(localized: "Arrow Right")
        case .f1: return String(localized: "F1")
        case .f2: return String(localized: "F2")
        case .f3: return String(localized: "F3")
        case .f4: return String(localized: "F4")
        case .f5: return String(localized: "F5")
        case .f6: return String(localized: "F6")
        case .f7: return String(localized: "F7")
        case .f8: return String(localized: "F8")
        case .f9: return String(localized: "F9")
        case .f10: return String(localized: "F10")
        case .f11: return String(localized: "F11")
        case .f12: return String(localized: "F12")
        case .ctrlC: return String(localized: "Ctrl+C")
        case .ctrlD: return String(localized: "Ctrl+D")
        case .ctrlZ: return String(localized: "Ctrl+Z")
        case .ctrlL: return String(localized: "Ctrl+L")
        case .ctrlA: return String(localized: "Ctrl+A")
        case .ctrlE: return String(localized: "Ctrl+E")
        case .ctrlK: return String(localized: "Ctrl+K")
        case .ctrlU: return String(localized: "Ctrl+U")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var toolbarTitle: String {
        switch self {
        case .commandModifier: return String(localized: "Cmd")
        case .escape: return String(localized: "Esc")
        case .tab: return String(localized: "Tab")
        case .shiftTab: return String(localized: "S-Tab")
        case .enter: return String(localized: "Enter")
        case .backspace: return String(localized: "Bksp")
        case .delete: return String(localized: "Del")
        case .insert: return String(localized: "Ins")
        case .home: return String(localized: "Home")
        case .end: return String(localized: "End")
        case .pageUp: return String(localized: "PgUp")
        case .pageDown: return String(localized: "PgDn")
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight: return ""
        case .f1: return String(localized: "F1")
        case .f2: return String(localized: "F2")
        case .f3: return String(localized: "F3")
        case .f4: return String(localized: "F4")
        case .f5: return String(localized: "F5")
        case .f6: return String(localized: "F6")
        case .f7: return String(localized: "F7")
        case .f8: return String(localized: "F8")
        case .f9: return String(localized: "F9")
        case .f10: return String(localized: "F10")
        case .f11: return String(localized: "F11")
        case .f12: return String(localized: "F12")
        case .ctrlC: return String(localized: "^C")
        case .ctrlD: return String(localized: "^D")
        case .ctrlZ: return String(localized: "^Z")
        case .ctrlL: return String(localized: "^L")
        case .ctrlA: return String(localized: "^A")
        case .ctrlE: return String(localized: "^E")
        case .ctrlK: return String(localized: "^K")
        case .ctrlU: return String(localized: "^U")
        case .unknown: return String(localized: "?")
        }
    }

    var iconName: String? {
        switch self {
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        default: return nil
        }
    }
}

nonisolated extension TerminalAccessoryCustomAction {
    var detailText: String {
        switch kind {
        case .command:
            return commandSendMode.title
        case .shortcut:
            return shortcutModifiers.displayTitle(for: shortcutKey.title)
        }
    }
}
