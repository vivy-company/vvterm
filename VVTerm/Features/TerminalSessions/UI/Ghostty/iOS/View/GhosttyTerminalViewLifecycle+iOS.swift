//
//  GhosttyTerminalViewLifecycle+iOS.swift
//  VVTerm
//
//  iOS terminal view layout, visibility, and color-scheme lifecycle.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    override func layoutSubviews() {
        super.layoutSubviews()
        imeProxyTextView.frame = bounds
        nativeFindOverlay.frame = bounds
        bringSubviewToFront(nativeFindOverlay)
        bringSubviewToFront(zoomIndicatorView)

        guard !isShuttingDown else { return }

        // Tell Ghostty the new size after the view has laid out.
        sizeDidChange(bounds.size)

    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        let isVisible = (window != nil)
        if !isVisible {
            cancelTrackedHardwareInput()
        }
        isPaused = !isVisible
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, isVisible)
        }
        onWindowAttachmentChange?(isVisible)
        logKeyboardLifecycle("terminal.didMoveToWindow", detail: "attached=\(isVisible)")

        if isVisible {
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
            sizeDidChange(frame.size)
            requestRender()
        }
    }

    // Use trait change registration API (iOS 17+) with fallback
    func registerColorSchemeObserver() {
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (view: GhosttyTerminalView, _: UITraitCollection) in
                self?.updateColorScheme()
            }
        }
    }

    private func updateColorScheme() {
        guard let surface = surface?.unsafeCValue else { return }
        let scheme: ghostty_color_scheme_e = traitCollection.userInterfaceStyle == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_surface_set_color_scheme(surface, scheme)
    }
}

#endif
