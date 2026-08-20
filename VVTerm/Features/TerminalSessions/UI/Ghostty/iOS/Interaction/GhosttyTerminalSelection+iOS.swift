//
//  GhosttyTerminalSelection+iOS.swift
//  VVTerm
//
//  iOS native selection routing.
//

#if os(iOS)
import UIKit

// MARK: - Native Text Selection

extension GhosttyTerminalView: UITextInteractionDelegate {
    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        guard hasActiveSelectionInteraction else { return false }
        nativeSelectionLifecycle.prepare(restoreTerminalInput: isTerminalTextInputActive)
        refreshNativeSelectionSnapshot()
        guard nativeSelectionSnapshot.length > 0 else {
            nativeSelectionLifecycle.cancel()
            return false
        }
        return true
    }

    func interactionWillBegin(_ interaction: UITextInteraction) {
        let terminalInputWasActive = isTerminalTextInputActive
        nativeSelectionLifecycle.beginInteraction(restoreTerminalInput: terminalInputWasActive)
        if !isTerminalTextInputActive {
            _ = becomeFirstResponder()
        }
        refreshNativeSelectionSnapshot()
    }

    func interactionDidEnd(_ interaction: UITextInteraction) {
        let restorationID = nativeSelectionLifecycle.endInteraction()
        refreshNativeSelectionSnapshot()
        scheduleNativeSelectionTerminalInputRestoration(restorationID)
    }
}

extension GhosttyTerminalView {
    @objc func handleNativeSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginNativeSelection(at: recognizer.location(in: self))
        case .changed:
            extendNativeSelection(to: recognizer.location(in: self))
        case .ended:
            finishNativeSelectionInteraction(
                presentingMenuAt: recognizer.location(in: self)
            )
        case .cancelled, .failed:
            nativeSelectionLongPressAnchor = nil
            if nativeSelectionLifecycle.selection == nil {
                nativeSelectionLifecycle.cancel()
            } else {
                finishNativeSelectionInteraction(presentingMenuAt: nil)
            }
        default:
            break
        }
    }

    private func beginNativeSelection(at point: CGPoint) {
        selectNativeText(at: point, granularity: .word, keepsDragAnchor: true)
    }

    @objc private func handleNativeSelectionMultiTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              canRouteTerminalInput,
              !isPaused,
              !isShuttingDown else {
            return
        }
        let granularity: UITextGranularity = recognizer.numberOfTapsRequired >= 3
            ? .paragraph
            : .word
        selectNativeText(
            at: recognizer.location(in: self),
            granularity: granularity,
            keepsDragAnchor: false
        )
        finishNativeSelectionInteraction(
            presentingMenuAt: recognizer.location(in: self)
        )
    }

    private func selectNativeText(
        at point: CGPoint,
        granularity: UITextGranularity,
        keepsDragAnchor: Bool
    ) {
        nativeSelectionLongPressAnchor = nil
        nativeSelectionLifecycle.prepare(restoreTerminalInput: isTerminalTextInputActive)
        nativeSelectionLifecycle.beginInteraction(restoreTerminalInput: isTerminalTextInputActive)
        refreshNativeSelectionSnapshot()
        guard nativeSelectionSnapshot.length > 0 else {
            nativeSelectionLongPressAnchor = nil
            nativeSelectionLifecycle.cancel()
            return
        }

        let offset = nativeSelectionSnapshot.offset(for: point)
        let position = TerminalNativeTextPosition(offset: offset)
        let direction = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let tokenRange = imeProxyTextView.tokenizer.rangeEnclosingPosition(
            position,
            with: granularity,
            inDirection: direction
        )
        let range = nativeSelectionSnapshot.nativeRange(from: tokenRange)
            ?? nativeSelectionSnapshot.characterRange(at: point)
        nativeSelectionLongPressAnchor = keepsDragAnchor ? range : nil
        setNativeSelectedRange(range)
    }

    private func extendNativeSelection(to point: CGPoint) {
        guard let anchor = nativeSelectionLongPressAnchor,
              let target = nativeSelectionSnapshot.characterRange(at: point) else {
            return
        }
        let lowerBound = min(anchor.location, target.location)
        let upperBound = max(
            nativeSelectionSnapshot.upperBound(of: anchor),
            nativeSelectionSnapshot.upperBound(of: target)
        )
        setNativeSelectedRange(
            NSRange(location: lowerBound, length: upperBound - lowerBound)
        )
    }

    private func finishNativeSelectionInteraction(presentingMenuAt point: CGPoint?) {
        nativeSelectionLongPressAnchor = nil
        if nativeSelectionLifecycle.interactionIsActive {
            let restorationID = nativeSelectionLifecycle.endInteraction()
            scheduleNativeSelectionTerminalInputRestoration(restorationID)
        }
        if let point, (nativeSelectionLifecycle.selection?.length ?? 0) > 0 {
            presentNativeSelectionEditMenu(at: point)
        }
    }

    func setupNativeTextSelectionInteractions() {
        let interaction = UITextInteraction(for: .editable)
        interaction.delegate = self
        interaction.textInput = imeProxyTextView
        imeProxyTextView.addInteraction(interaction)
        nativeTextInteraction = interaction
        for gesture in interaction.gesturesForFailureRequirements {
            scrollRecognizer.require(toFail: gesture)
        }

        let nativeSelectionDoubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleNativeSelectionMultiTap(_:))
        )
        nativeSelectionDoubleTap.numberOfTapsRequired = 2
        nativeSelectionDoubleTap.cancelsTouchesInView = false
        nativeSelectionDoubleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        nativeSelectionDoubleTap.delegate = self

        let nativeSelectionTripleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleNativeSelectionMultiTap(_:))
        )
        nativeSelectionTripleTap.numberOfTapsRequired = 3
        nativeSelectionTripleTap.cancelsTouchesInView = false
        nativeSelectionTripleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        nativeSelectionTripleTap.delegate = self

        nativeSelectionDoubleTap.require(toFail: nativeSelectionTripleTap)
        directTouchTapRecognizer.require(toFail: nativeSelectionDoubleTap)
        for gesture in interaction.gesturesForFailureRequirements {
            gesture.require(toFail: directTouchTapRecognizer)
            gesture.require(toFail: nativeSelectionLongPressRecognizer)
            gesture.require(toFail: nativeSelectionDoubleTap)
            gesture.require(toFail: nativeSelectionTripleTap)
        }
        imeProxyTextView.addGestureRecognizer(nativeSelectionDoubleTap)
        imeProxyTextView.addGestureRecognizer(nativeSelectionTripleTap)
    }

    private func notifyNativeSelectionLayoutChange() {
        guard nativeSelectionLifecycle.shouldRefreshSnapshot else { return }
        imeProxyTextView.inputDelegate?.textWillChange(imeProxyTextView)
        imeProxyTextView.inputDelegate?.textDidChange(imeProxyTextView)
        imeProxyTextView.inputDelegate?.selectionWillChange(imeProxyTextView)
        imeProxyTextView.inputDelegate?.selectionDidChange(imeProxyTextView)
    }

    func refreshNativeSelectionSnapshot(resetSelection: Bool = false) {
        nativeSelectionSnapshot = buildNativeSelectionSnapshot()
        updateNativeFindOverlay()
        if resetSelection {
            setNativeSelectedRange(nil)
            return
        }

        guard let nativeSelectedRange = nativeSelectionLifecycle.selection else { return }
        let clamped = nativeSelectionSnapshot.clampedRange(nativeSelectedRange)
        if clamped != nativeSelectedRange {
            setNativeSelectedRange(clamped)
        } else {
            notifyNativeSelectionLayoutChange()
        }
    }

    private func buildNativeSelectionSnapshot() -> TerminalNativeTextSnapshot {
        guard let surface = surface?.unsafeCValue,
              let metrics = selectionGridMetrics() else {
            return .empty
        }

        let rows = (0..<metrics.rows).map { readNativeSelectionLine(surface: surface, row: $0, columns: metrics.cols) }
        return TerminalNativeTextSnapshot(lines: rows, cellSize: metrics.cellSize, columns: metrics.cols)
    }

    private func readNativeSelectionLine(surface: ghostty_surface_t, row: Int, columns: Int) -> String {
        guard columns > 0,
              let wireRow = UInt32(exactly: row),
              let wireEndColumn = UInt32(exactly: columns - 1) else {
            return ""
        }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: wireRow
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: wireEndColumn,
                y: wireRow
            ),
            rectangle: true
        )

        let rawLine: String
        if ghostty_surface_read_text(surface, selection, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            rawLine = ghosttyTextString(text)
        } else {
            rawLine = ""
        }

        var line = rawLine
        while line.last == "\n" || line.last == "\r" {
            line.removeLast()
        }

        while let scalar = line.unicodeScalars.last,
              CharacterSet.whitespaces.contains(scalar) {
            line.removeLast()
        }

        let lineNSString = line as NSString
        if lineNSString.length > columns {
            line = lineNSString.substring(to: columns)
        }

        return line
    }

    func setNativeSelectedRange(_ range: NSRange?) {
        let clampedRange = range.map { nativeSelectionSnapshot.clampedRange($0) }
        if nativeSelectionLifecycle.selection == clampedRange {
            notifyNativeSelectionLayoutChange()
            return
        }

        imeProxyTextView.inputDelegate?.selectionWillChange(imeProxyTextView)
        let restorationID = nativeSelectionLifecycle.setSelection(clampedRange)
        imeProxyTextView.inputDelegate?.selectionDidChange(imeProxyTextView)
        scheduleNativeSelectionTerminalInputRestoration(restorationID)
    }

    func scheduleNativeSelectionTerminalInputRestoration(_ restorationID: UUID?) {
        guard let restorationID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.nativeSelectionLifecycle.completeRestoration(id: restorationID),
                  !self.isShuttingDown,
                  self.isTextInputSessionEligible,
                  !self.isFindNavigatorActive else {
                return
            }
            _ = self.requestKeyboardFocus(for: .selectionGesture)
        }
    }

    func isPointOnNativeSelectionHandleHitArea(_ point: CGPoint) -> Bool {
        guard let nativeSelectedRange = nativeSelectionLifecycle.selection,
              nativeSelectedRange.length > 0 else {
            return false
        }
        let clamped = nativeSelectionSnapshot.clampedRange(nativeSelectedRange)
        guard clamped.length > 0 else { return false }

        let startRect = nativeSelectionSnapshot.caretRect(for: clamped.location)
        let endRect = nativeSelectionSnapshot.caretRect(
            for: nativeSelectionSnapshot.upperBound(of: clamped)
        )
        let hitSlop = max(28, nativeSelectionSnapshot.cellSize.height * 1.5)
        return startRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
            || endRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
    }

    private func selectedNativeSelectionText() -> String? {
        guard allowsHostTextSelection else { return nil }
        guard let nativeSelectedRange = nativeSelectionLifecycle.selection,
              nativeSelectedRange.length > 0 else { return nil }
        return nativeSelectionSnapshot.text(in: nativeSelectedRange)
    }
    var usesNativeTouchSelection: Bool {
        return UIDevice.current.userInterfaceIdiom == .phone
            || UIDevice.current.userInterfaceIdiom == .pad
    }

    func selectionGridMetrics() -> (cols: Int, rows: Int, cellSize: CGSize)? {
        guard let terminalSize = terminalSize() else { return nil }
        let cols = max(Int(terminalSize.columns), 1)
        let rows = max(Int(terminalSize.rows), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : max(bounds.width / CGFloat(cols), 1)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : max(bounds.height / CGFloat(rows), 1)
        return (cols, rows, CGSize(width: resolvedCellWidth, height: resolvedCellHeight))
    }

    func currentSelectionText() -> String? {
        guard allowsHostTextSelection else { return nil }

        if let nativeSelectionText = selectedNativeSelectionText() {
            return nativeSelectionText
        }
        return ghosttySelectionText()
    }

    private func ghosttySelectionText() -> String? {
        guard let surface = surface?.unsafeCValue else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return ghosttyTextString(text)
    }

    private func ghosttyTextString(_ text: ghostty_text_s) -> String {
        guard let rawText = text.text else { return "" }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(rawText).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    func copyTextToClipboard(_ text: String) {
        let cleaned = TerminalTextCleaner.cleanText(text, settings: .current())
        Clipboard.copy(cleaned)
    }

    func selectAllVisibleText() {
        guard allowsHostTextSelection else { return }

        refreshNativeSelectionSnapshot()
        guard nativeSelectionSnapshot.length > 0 else { return }
        setNativeSelectedRange(NSRange(location: 0, length: nativeSelectionSnapshot.length))
    }

    func clearSelectionAfterPaste() {
        if nativeSelectedRange != nil {
            setNativeSelectedRange(nil)
        }
    }
}

#endif
