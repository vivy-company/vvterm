import Foundation
import Testing
@testable import VVTerm

struct TerminalAccessoryPresentationTests {
    @Test
    func actionKindsAndSendModesKeepTheirLocalizedTitles() {
        #expect(TerminalAccessoryCustomActionKind.command.title == String(localized: "Command"))
        #expect(TerminalAccessoryCustomActionKind.shortcut.title == String(localized: "Shortcut"))
        #expect(TerminalSnippetSendMode.insert.title == String(localized: "Insert"))
        #expect(TerminalSnippetSendMode.insertAndEnter.title == String(localized: "Insert + Enter"))
    }

    @Test
    func shortcutPresentationKeepsModifierOrderAndKeyTitles() {
        let modifiers = TerminalAccessoryShortcutModifiers(
            control: true,
            alternate: true,
            command: true,
            shift: true
        )
        let expectedParts = [
            String(localized: "Ctrl"),
            String(localized: "Alt"),
            String(localized: "Cmd"),
            String(localized: "Shift")
        ]

        #expect(modifiers.displayParts == expectedParts)
        #expect(
            modifiers.displayTitle(for: TerminalAccessoryShortcutKey.backslash.title)
                == (expectedParts + ["\\"]).joined(separator: "+")
        )
        #expect(TerminalAccessoryShortcutKey.a.title == "A")
        #expect(TerminalAccessoryShortcutKey.digit0.title == "0")
        #expect(TerminalAccessoryShortcutKey.space.title == String(localized: "Space"))
        #expect(TerminalAccessoryShortcutKey.pageDown.title == String(localized: "Page Down"))
        #expect(TerminalAccessoryShortcutKey.f12.title == "F12")
    }

    @Test
    func systemActionPresentationKeepsLongShortAndIconVariants() {
        #expect(TerminalAccessorySystemActionID.shiftTab.listTitle == String(localized: "Shift+Tab"))
        #expect(TerminalAccessorySystemActionID.shiftTab.toolbarTitle == String(localized: "S-Tab"))
        #expect(TerminalAccessorySystemActionID.backspace.toolbarTitle == String(localized: "Bksp"))
        #expect(TerminalAccessorySystemActionID.delete.toolbarTitle == String(localized: "Del"))
        #expect(TerminalAccessorySystemActionID.insert.toolbarTitle == String(localized: "Ins"))
        #expect(TerminalAccessorySystemActionID.pageUp.toolbarTitle == String(localized: "PgUp"))
        #expect(TerminalAccessorySystemActionID.pageDown.toolbarTitle == String(localized: "PgDn"))
        #expect(TerminalAccessorySystemActionID.ctrlC.listTitle == String(localized: "Ctrl+C"))
        #expect(TerminalAccessorySystemActionID.ctrlC.toolbarTitle == String(localized: "^C"))
        #expect(TerminalAccessorySystemActionID.unknown.listTitle == String(localized: "Unknown"))
        #expect(TerminalAccessorySystemActionID.unknown.toolbarTitle == String(localized: "?"))

        let icons = Dictionary(uniqueKeysWithValues: TerminalAccessorySystemActionID.allCases.compactMap { id in
            id.iconName.map { (id, $0) }
        })
        #expect(icons == [
            .arrowUp: "arrow.up",
            .arrowDown: "arrow.down",
            .arrowLeft: "arrow.left",
            .arrowRight: "arrow.right"
        ])
        #expect(TerminalAccessorySystemActionID.arrowUp.toolbarTitle.isEmpty)
        #expect(TerminalAccessorySystemActionID.arrowDown.toolbarTitle.isEmpty)
        #expect(TerminalAccessorySystemActionID.arrowLeft.toolbarTitle.isEmpty)
        #expect(TerminalAccessorySystemActionID.arrowRight.toolbarTitle.isEmpty)
    }

    @Test
    func customActionDetailUsesUICatalogPresentation() {
        let command = TerminalAccessoryCustomAction(
            title: "Deploy",
            kind: .command,
            commandContent: "deploy",
            commandSendMode: .insertAndEnter
        )
        let shortcut = TerminalAccessoryCustomAction(
            title: "Interrupt",
            kind: .shortcut,
            shortcutKey: .c,
            shortcutModifiers: TerminalAccessoryShortcutModifiers(control: true)
        )

        #expect(command.detailText == String(localized: "Insert + Enter"))
        #expect(shortcut.detailText == "\(String(localized: "Ctrl"))+C")
    }
}
