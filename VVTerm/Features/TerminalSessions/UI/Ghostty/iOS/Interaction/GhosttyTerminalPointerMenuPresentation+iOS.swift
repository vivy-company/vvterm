//
//  GhosttyTerminalPointerMenuPresentation+iOS.swift
//  VVTerm
//
//  iOS pointer context-menu presentation.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    func showPointerContextMenu(at location: CGPoint) {
        guard !isShuttingDown else { return }
        dismissEditMenuIfNeeded()
        editMenuPresentation = .pointerContext
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        editMenuInteraction?.presentEditMenu(with: config)
    }

    @discardableResult
    private func focusPointerContextTarget() -> Bool {
        guard !isShuttingDown else { return false }
        focusForHardwareKeyboardIfNeeded()
        terminalContextMenuActions?.focus()
        return true
    }

    func pointerContextMenuElements() -> [UIMenuElement] {
        guard !isShuttingDown else { return [] }
        var actions: [UIMenuElement] = []

        if let selectionText = currentSelectionText(), !selectionText.isEmpty {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let self, self.focusPointerContextTarget() else { return }
                self.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            guard let self, self.focusPointerContextTarget() else { return }
            self.paste(nil)
        })

        if terminalContextMenuActions != nil {
            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Split Right"), image: UIImage(systemName: "rectangle.righthalf.inset.filled")) { [weak self] _ in
                    guard let self,
                          self.focusPointerContextTarget(),
                          let terminalContextMenuActions = self.terminalContextMenuActions else { return }
                    terminalContextMenuActions.splitRight()
                },
                UIAction(title: String(localized: "Split Left"), image: UIImage(systemName: "rectangle.leadinghalf.inset.filled")) { [weak self] _ in
                    guard let self,
                          self.focusPointerContextTarget(),
                          let terminalContextMenuActions = self.terminalContextMenuActions else { return }
                    terminalContextMenuActions.splitLeft()
                },
                UIAction(title: String(localized: "Split Down"), image: UIImage(systemName: "rectangle.bottomhalf.inset.filled")) { [weak self] _ in
                    guard let self,
                          self.focusPointerContextTarget(),
                          let terminalContextMenuActions = self.terminalContextMenuActions else { return }
                    terminalContextMenuActions.splitDown()
                },
                UIAction(title: String(localized: "Split Up"), image: UIImage(systemName: "rectangle.tophalf.inset.filled")) { [weak self] _ in
                    guard let self,
                          self.focusPointerContextTarget(),
                          let terminalContextMenuActions = self.terminalContextMenuActions else { return }
                    terminalContextMenuActions.splitUp()
                }
            ]))
        }

        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Reset Terminal"), image: UIImage(systemName: "arrow.trianglehead.2.clockwise")) { [weak self] _ in
                guard let self, self.focusPointerContextTarget() else { return }
                self.resetTerminalForReconnect()
            },
            UIAction(
                title: String(localized: "Terminal Read-only"),
                image: UIImage(systemName: "eye.fill"),
                state: readonly ? .on : .off
            ) { [weak self] _ in
                guard let self, self.focusPointerContextTarget() else { return }
                if self.surface?.perform(action: "toggle_readonly") == true {
                    self.readonly.toggle()
                }
            }
        ]))

        if terminalContextMenuActions != nil {
            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Change Terminal Title..."), image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.presentTerminalTitleEditor()
                }
            ]))
        }

        return actions
    }

    private func presentTerminalTitleEditor() {
        guard focusPointerContextTarget(), let terminalContextMenuActions else { return }
        guard let presenter = nearestPresentingViewController() else { return }

        let alert = UIAlertController(
            title: String(localized: "Change Terminal Title"),
            message: String(localized: "Leave blank to restore the default."),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = terminalContextMenuActions.currentTitle()
            textField.clearButtonMode = .whileEditing
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.terminalTitleEditor = nil
        })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self, weak alert] _ in
            guard let self,
                  !self.isShuttingDown,
                  let terminalContextMenuActions = self.terminalContextMenuActions else { return }
            defer { self.terminalTitleEditor = nil }
            let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            terminalContextMenuActions.setTitle(title.isEmpty ? nil : title)
        })

        terminalTitleEditor = alert
        presenter.present(alert, animated: true)
    }
}

#endif
