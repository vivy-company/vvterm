//
//  GhosttyTerminalPointerInput+macOS.swift
//  VVTerm
//
//  macOS terminal pointer and scroll input routing.
//

#if os(macOS)
import AppKit

extension GhosttyTerminalView {
    override func mouseDown(with event: NSEvent) {
        inputHandler.handleMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        inputHandler.handleMouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if inputHandler.handleRightMouseDown(with: event) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if inputHandler.handleRightMouseUp(with: event) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        inputHandler.handleOtherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        inputHandler.handleOtherMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        inputHandler.handleMouseMoved(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        inputHandler.handleMouseEntered(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseExited(with event: NSEvent) {
        inputHandler.handleMouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        inputHandler.handleScrollWheel(with: event)
    }
}

#endif
