//
//  GhosttyTerminalContextMenu+macOS.swift
//  VVTerm
//
//  macOS terminal context-menu presentation and actions.
//

#if os(macOS)
import AppKit

extension GhosttyTerminalView {
    override func menu(for event: NSEvent) -> NSMenu? {
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown:
            guard event.modifierFlags.contains(.control) else { return nil }
            guard surface?.mouseCaptured != true else { return nil }
            _ = inputHandler.handleRightMouseDown(with: event)
        default:
            return nil
        }

        focusContextMenuTarget()
        return makeTerminalContextMenu()
    }

    func updateReadonlyState(_ isReadonly: Bool) {
        readonly = isReadonly
    }

    private func makeTerminalContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if hasSelection {
            menu.addItem(makeMenuItem(title: String(localized: "Copy"), action: #selector(copy(_:))))
        }
        menu.addItem(makeMenuItem(title: String(localized: "Paste"), action: #selector(paste(_:))))

        if terminalContextMenuActions != nil {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(
                title: String(localized: "Split Right"),
                action: #selector(splitRight(_:)),
                systemImage: "rectangle.righthalf.inset.filled"
            ))
            menu.addItem(makeMenuItem(
                title: String(localized: "Split Left"),
                action: #selector(splitLeft(_:)),
                systemImage: "rectangle.leadinghalf.inset.filled"
            ))
            menu.addItem(makeMenuItem(
                title: String(localized: "Split Down"),
                action: #selector(splitDown(_:)),
                systemImage: "rectangle.bottomhalf.inset.filled"
            ))
            menu.addItem(makeMenuItem(
                title: String(localized: "Split Up"),
                action: #selector(splitUp(_:)),
                systemImage: "rectangle.tophalf.inset.filled"
            ))
        }

        menu.addItem(.separator())
        menu.addItem(makeMenuItem(
            title: String(localized: "Reset Terminal"),
            action: #selector(resetTerminal(_:)),
            systemImage: "arrow.trianglehead.2.clockwise"
        ))
        let readonlyItem = makeMenuItem(
            title: String(localized: "Terminal Read-only"),
            action: #selector(toggleReadonly(_:)),
            systemImage: "eye.fill"
        )
        readonlyItem.state = readonly ? .on : .off
        menu.addItem(readonlyItem)

        if terminalContextMenuActions != nil {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(
                title: String(localized: "Change Terminal Title..."),
                action: #selector(changeTerminalTitle(_:))
            ))
        }

        return menu
    }

    private var hasSelection: Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return ghostty_surface_has_selection(cSurface)
    }

    private func makeMenuItem(title: String, action: Selector, systemImage: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        }
        return item
    }

    func focusContextMenuTarget() {
        window?.makeFirstResponder(self)
        terminalContextMenuActions?.focus()
    }

    @objc private func splitRight(_ sender: Any?) {
        focusContextMenuTarget()
        terminalContextMenuActions?.splitRight()
    }

    @objc private func splitLeft(_ sender: Any?) {
        focusContextMenuTarget()
        terminalContextMenuActions?.splitLeft()
    }

    @objc private func splitDown(_ sender: Any?) {
        focusContextMenuTarget()
        terminalContextMenuActions?.splitDown()
    }

    @objc private func splitUp(_ sender: Any?) {
        focusContextMenuTarget()
        terminalContextMenuActions?.splitUp()
    }

    @objc private func resetTerminal(_ sender: Any?) {
        focusContextMenuTarget()
        resetTerminalForReconnect()
    }

    @objc func toggleReadonly(_ sender: Any?) {
        focusContextMenuTarget()
        if surface?.perform(action: "toggle_readonly") == true {
            readonly.toggle()
        }
    }

    @objc private func changeTerminalTitle(_ sender: Any?) {
        guard let terminalContextMenuActions else { return }
        focusContextMenuTarget()

        let alert = NSAlert()
        alert.messageText = String(localized: "Change Terminal Title")
        alert.informativeText = String(localized: "Leave blank to restore the default.")
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = terminalContextMenuActions.currentTitle()
        alert.accessoryView = textField
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = textField

        let completionHandler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let title = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            terminalContextMenuActions.setTitle(title.isEmpty ? nil : title)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: completionHandler)
        } else {
            completionHandler(alert.runModal())
        }
    }
}

#endif
