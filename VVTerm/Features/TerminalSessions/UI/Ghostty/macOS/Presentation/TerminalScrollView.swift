//
//  TerminalScrollView.swift
//  VVTerm
//
//  NSScrollView wrapper for terminal with native macOS scrollbar support.
//  Adapted from Ghostty's SurfaceScrollView.swift
//

#if os(macOS)
import AppKit
import Combine

/// Wraps a Ghostty terminal view in an NSScrollView to provide native macOS scrollbar support.
///
/// ## Coordinate System
/// AppKit uses a +Y-up coordinate system (origin at bottom-left), while terminals conceptually
/// use +Y-down (row 0 at top). This class handles the inversion when converting between row
/// offsets and pixel positions.
///
/// ## Architecture
/// - `scrollView`: The outermost NSScrollView that manages scrollbar rendering and behavior
/// - `documentView`: A blank NSView whose height represents total scrollback (in pixels)
/// - `surfaceView`: The actual Ghostty terminal renderer, positioned to fill the visible rect
class TerminalScrollView: NSView, NSUserInterfaceValidations {
    private let scrollView: NSScrollView
    private let documentView: NSView
    let surfaceView: GhosttyTerminalView
    var shouldOwnFirstResponder = false {
        didSet {
            guard oldValue != shouldOwnFirstResponder else { return }
            reconcileFirstResponderOwnership()
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false

    /// The last row position sent via scroll_to_row action. Used to avoid
    /// sending redundant actions when the user drags the scrollbar but stays
    /// on the same row.
    private var lastSentRow: Int?

    init(contentSize: CGSize, surfaceView: GhosttyTerminalView) {
        self.surfaceView = surfaceView

        // The scroll view is our outermost view that controls all our scrollbar
        // rendering and behavior.
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        // Always use the overlay style. See mouseMoved for how we make
        // it usable without a scroll wheel or gestures.
        scrollView.scrollerStyle = .overlay
        // hide default background to show blur effect properly
        scrollView.drawsBackground = false
        // don't let the content view clip its subviews
        scrollView.contentView.clipsToBounds = false

        // The document view is what the scrollview is actually going
        // to be directly scrolling. We set it up to a "blank" NSView
        // with the desired content size.
        documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.documentView = documentView

        // The document view contains our actual surface as a child.
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)

        // CRITICAL: Enable autoresizing so we resize with parent (SwiftUI container)
        autoresizingMask = [.width, .height]
        scrollView.autoresizingMask = [.width, .height]

        // Our scroll view is our only view
        addSubview(scrollView)

        // Apply initial scrollbar settings
        synchronizeAppearance()

        // We listen for scroll events through bounds notifications on our NSClipView.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScrollChange()
            }
        })

        // Listen for scrollbar updates from Ghostty
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            guard let scrollbar = notification.userInfo?[Notification.Name.ScrollbarKey]
                as? Ghostty.Action.Scrollbar else {
                return
            }
            Task { @MainActor [weak self, scrollbar] in
                self?.handleScrollbarUpdate(scrollbar)
            }
        })

        // Listen for live scroll events
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLiveScrolling = true
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLiveScrolling = false
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLiveScroll()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScrollerStyleChange()
            }
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // The entire bounds is a safe area, so we override any default insets.
    override var safeAreaInsets: NSEdgeInsets { return NSEdgeInsetsZero }

    override var acceptsFirstResponder: Bool { surfaceView.acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(surfaceView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileFirstResponderOwnership()
    }

    override func keyDown(with event: NSEvent) {
        ensureSurfaceViewIsFirstResponder()
        surfaceView.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard surfaceViewOwnsFirstResponder else {
            return super.performKeyEquivalent(with: event)
        }
        if surfaceView.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard surfaceViewOwnsFirstResponder else { return }
        surfaceView.copy(sender)
    }

    @objc func paste(_ sender: Any?) {
        guard surfaceViewOwnsFirstResponder else { return }
        surfaceView.paste(sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        surfaceView.validateUserInterfaceItem(item)
    }

    override func layout() {
        super.layout()

        // Fill entire bounds with scroll view
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size

        // We only set the width of the documentView here, as the height depends
        // on the scrollbar state and is updated in synchronizeScrollView
        documentView.frame.size.width = scrollView.bounds.width

        // When our scrollview changes make sure our scroller and surface views are synchronized
        synchronizeScrollView()
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }

    // MARK: - Scrolling

    private func synchronizeAppearance() {
        // Update scroller appearance based on terminal background
        let hasLightBackground = scrollView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        scrollView.appearance = NSAppearance(named: hasLightBackground ? .aqua : .darkAqua)
        updateTrackingAreas()
    }

    private func ensureSurfaceViewIsFirstResponder() {
        guard let window, window.firstResponder !== surfaceView else { return }
        window.makeFirstResponder(surfaceView)
    }

    private func reconcileFirstResponderOwnership() {
        guard let window else { return }

        if shouldOwnFirstResponder {
            guard window.firstResponder !== surfaceView else { return }
            window.makeFirstResponder(surfaceView)
            return
        }

        guard window.firstResponder === surfaceView else { return }
        window.makeFirstResponder(nil)
    }

    private var surfaceViewOwnsFirstResponder: Bool {
        window?.firstResponder === surfaceView
    }

    /// Positions the surface view to fill the currently visible rectangle.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Inform the actual pty of our size change.
    private func synchronizeCoreSurface() {
        let width = scrollView.contentSize.width
        let height = surfaceView.frame.height
        if width > 0 && height > 0 {
            surfaceView.sizeDidChange(CGSize(width: width, height: height))
        }
    }

    /// Sizes the document view and scrolls the content view according to the scrollbar state
    private func synchronizeScrollView() {
        // Update the document height to give our scroller the correct proportions
        documentView.frame.size.height = documentHeight()

        // Only update our actual scroll position if we're not actively scrolling.
        if !isLiveScrolling {
            // Convert row units to pixels using cell height, ignore zero height.
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                // Invert coordinate system: terminal offset is from top, AppKit position from bottom
                let offsetY =
                    CGFloat(scrollbar.rowsBelowViewport) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))

                // Track the current row position to avoid redundant movements when we
                // move the scrollbar.
                lastSentRow = scrollbar.offsetAsInt
            }
        }

        // Always update our scrolled view with the latest dimensions
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Notifications

    /// Handles bounds changes in the scroll view's clip view, keeping the surface view synchronized.
    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    /// Handles scrollbar style changes
    private func handleScrollerStyleChange() {
        scrollView.scrollerStyle = .overlay
        synchronizeCoreSurface()
    }

    /// Handles live scroll events (user actively dragging the scrollbar).
    private func handleLiveScroll() {
        // If our cell height is currently zero then we avoid a div by zero below
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        // AppKit views are +Y going up, so we calculate from the bottom
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        guard let row = Ghostty.Action.Scrollbar.clampedRowIndex(
            Double(scrollOffset / cellHeight)
        ) else {
            return
        }

        // Only send action if the row changed to avoid action spam
        guard row != lastSentRow else { return }
        lastSentRow = row

        // Use the keybinding action to scroll.
        _ = surfaceView.surface?.perform(action: "scroll_to_row:\(row)")
    }

    /// Handles scrollbar state updates from the terminal core.
    private func handleScrollbarUpdate(_ scrollbar: Ghostty.Action.Scrollbar) {
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    // MARK: - Calculations

    /// Calculate the appropriate document view height given a scrollbar state
    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            // The document view must have the same vertical padding around the
            // scrollback grid as the content view has around the terminal grid
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }

    // MARK: - Mouse events

    override func mouseMoved(with: NSEvent) {
        // When the OS preferred style is .legacy, the user should be able to
        // click and drag the scroller without using scroll wheels or gestures,
        // so we flash it when the mouse is moved over the scrollbar area.
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        // To update our tracking area we just recreate it all.
        trackingAreas.forEach { removeTrackingArea($0) }

        super.updateTrackingAreas()

        // Our tracking area is the scroller frame
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil))
    }
}

// MARK: - GhosttyTerminalView Extension

extension GhosttyTerminalView {
    /// Notify the terminal of a size change (used by scroll view wrapper)
    func sizeDidChange(_ size: CGSize) {
        guard let surface = surface?.unsafeCValue else { return }
        let scaledSize = convertToBacking(size)
        guard let surfaceSize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: scaledSize.width,
            height: scaledSize.height
        ) else {
            return
        }
        ghostty_surface_set_size(surface, surfaceSize.width, surfaceSize.height)

        // Trigger a refresh to process the size change
        ghostty_surface_refresh(surface)

        // Force layout to update and notify resize callback
        needsLayout = true
    }
}
#endif
