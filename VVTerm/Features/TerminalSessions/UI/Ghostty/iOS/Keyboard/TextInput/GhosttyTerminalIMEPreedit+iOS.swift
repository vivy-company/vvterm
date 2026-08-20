//
//  GhosttyTerminalIMEPreedit+iOS.swift
//  VVTerm
//
//  iOS IME preedit presentation.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    private func shouldDisplayVisiblePreedit(for text: String) -> Bool {
        TerminalVisiblePreeditPolicy.shouldDisplay(
            text,
            inputModePrimaryLanguage: currentIMEPrimaryLanguage
        )
    }

    var currentIMEPrimaryLanguage: String? {
        imeProxyTextView.textInputMode?.primaryLanguage ?? textInputMode?.primaryLanguage
    }

    func syncIMEPreedit(_ text: String?) {
        let visibleText: String?
        if let text, !text.isEmpty {
            let normalized = text.precomposedStringWithCanonicalMapping
            visibleText = shouldDisplayVisiblePreedit(for: normalized) ? normalized : nil
        } else {
            visibleText = nil
        }

        guard visibleText != renderedIMEPreeditText else { return }
        renderedIMEPreeditText = visibleText

        guard let cSurface = surface?.unsafeCValue else { return }

        if let visibleText, !visibleText.isEmpty {
            let len = visibleText.utf8CString.count
            guard len > 0 else {
                ghostty_surface_preedit(cSurface, nil, 0)
                requestRender()
                return
            }
            visibleText.withCString { ptr in
                ghostty_surface_preedit(cSurface, ptr, UInt(len - 1))
            }
        } else {
            ghostty_surface_preedit(cSurface, nil, 0)
        }

        requestRender()
    }
}

#endif
