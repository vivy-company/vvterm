//
//  GhosttyTerminalResponderActions+iOS.swift
//  VVTerm
//
//  iOS terminal responder action routing.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            guard allowsHostTextSelection else { return false }
            if let nativeSelectedRange, nativeSelectedRange.length > 0 {
                return true
            }
            guard let cSurface = surface?.unsafeCValue else { return false }
            return ghostty_surface_has_selection(cSurface)
        case #selector(selectAll(_:)):
            guard allowsHostTextSelection else { return false }
            return nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil
        case #selector(find(_:)):
            return true
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            if #available(iOS 16.0, *) {
                return nativeFindInteraction?.isFindNavigatorVisible == true
            }
            return false
        case #selector(useSelectionForFind(_:)):
            guard allowsHostTextSelection else { return false }
            return normalizedSelectionMenuText() != nil
        case #selector(paste(_:)):
            return true
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc override func copy(_ sender: Any?) {
        guard let selectionText = currentSelectionText(), !selectionText.isEmpty else { return }
        copyTextToClipboard(selectionText)
    }

    @objc override func selectAll(_ sender: Any?) {
        selectAllVisibleText()
    }

    @objc override func paste(_ sender: Any?) {
        performPasteAction()
    }

    @objc override func find(_ sender: Any?) {
        showFindNavigator()
    }

    @objc override func useSelectionForFind(_ sender: Any?) {
        showFindNavigator(prefillingSelectedText: true)
    }

    @objc override func findNext(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findNext()
    }

    @objc override func findPrevious(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findPrevious()
    }
}

#endif
