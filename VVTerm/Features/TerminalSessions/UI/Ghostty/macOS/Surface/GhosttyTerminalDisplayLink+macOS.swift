//
//  GhosttyTerminalDisplayLink+macOS.swift
//  VVTerm
//
//  macOS display-link rendering.
//

#if os(macOS)
import AppKit
import CoreVideo

extension GhosttyTerminalView {
    /// Setup CVDisplayLink for display-synchronized rendering (SSH mode only)
    /// Event-driven: starts on activity, stops after idle timeout to save CPU
    func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }

        // Prevent capture of self in C callback by using a weak reference wrapper
        let callbackContext = DisplayLinkCallbackContext(view: self)
        let retainedRef = Unmanaged.passRetained(callbackContext)
        displayLinkCallbackContext = retainedRef

        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let callbackContext = Unmanaged<DisplayLinkCallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
            guard let view = callbackContext.view else { return kCVReturnSuccess }

            DispatchQueue.main.async {
                view.displayLinkTick()
            }
            return kCVReturnSuccess
        }, retainedRef.toOpaque())

        self.displayLink = displayLink
        // Don't start immediately - will start on first activity
        setupIdleCheckTimer()
    }

    /// Called by display link callback - checks if we should continue or go idle
    private func displayLinkTick() {
        guard !isShuttingDown else { return }

        // Check if we've been idle too long
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            // Stop display link to save CPU when idle
            if let link = displayLink, CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
            return
        }

        // Process any pending render
        if needsRender, let surface = surface?.unsafeCValue {
            needsRender = false
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }

        // Always tick for cursor blink when active
        ghosttyAppWrapper?.appTick()
    }

    /// Setup timer to periodically check for idle state
    private func setupIdleCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.idleTimeout, repeating: Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            self?.checkIdleState()
        }
        timer.resume()
        idleCheckTimer = timer
    }

    /// Check if display link should be stopped due to idle
    private func checkIdleState() {
        guard !isShuttingDown else { return }
        guard let link = displayLink, CVDisplayLinkIsRunning(link) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            CVDisplayLinkStop(link)
        }
    }

    /// Request a render - starts display link if needed
    func requestRender() {
        guard !isShuttingDown else { return }
        lastActivityTime = CFAbsoluteTimeGetCurrent()
        needsRender = true

        // Start display link if not running
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    /// Stop and release the display link, including the weak reference
    func stopDisplayLink() {
        // Cancel idle check timer
        idleCheckTimer?.cancel()
        idleCheckTimer = nil

        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil

        // Release the retained weak reference to prevent memory leak
        displayLinkCallbackContext?.release()
        displayLinkCallbackContext = nil
    }
}

// MARK: - Weak Reference Wrapper for CVDisplayLink callback

/// Thread-safe weak reference wrapper for use in C callbacks
final class DisplayLinkCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private let weakViewTable = NSHashTable<GhosttyTerminalView>.weakObjects()

    init(view: GhosttyTerminalView) {
        lock.lock()
        weakViewTable.add(view)
        lock.unlock()
    }

    var view: GhosttyTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return weakViewTable.allObjects.first
    }
}

#endif
