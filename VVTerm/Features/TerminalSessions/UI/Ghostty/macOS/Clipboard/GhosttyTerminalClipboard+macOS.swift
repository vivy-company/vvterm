//
//  GhosttyTerminalClipboard+macOS.swift
//  VVTerm
//
//  macOS terminal clipboard commands and rich-paste routing.
//

#if os(macOS)
import AppKit

extension GhosttyTerminalView {
    @discardableResult
    func interceptRichPasteIfNeeded() -> Bool {
        richPasteInterceptor?(self) == true
    }

    private func performPasteAction() {
        if interceptRichPasteIfNeeded() {
            return
        }
        pasteTextFromClipboard()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let cSurface = surface?.unsafeCValue else { return false }
            return ghostty_surface_has_selection(cSurface)
        case #selector(paste(_:)):
            return true
        case #selector(toggleReadonly(_:)):
            if let item = item as? NSMenuItem {
                item.state = readonly ? .on : .off
            }
            return true
        default:
            return true
        }
    }

    @objc func copy(_ sender: Any?) {
        _ = surface?.perform(action: "copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        focusContextMenuTarget()
        performPasteAction()
    }
}

#endif
