//
//  GhosttyTerminalIMEProxyBridge+iOS.swift
//  VVTerm
//
//  iOS terminal IME-proxy state synchronization.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    func textInputGridMetrics() -> (cols: Int, rows: Int, cellSize: CGSize, length: Int) {
        let cols = max(lastReportedGrid.cols, 1)
        let rows = max(lastReportedGrid.rows, 1)
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        if cellSize.width > 0 {
            cellWidth = cellSize.width
        } else if bounds.width > 0 {
            cellWidth = bounds.width / CGFloat(cols)
        } else {
            cellWidth = 1
        }
        if cellSize.height > 0 {
            cellHeight = cellSize.height
        } else if bounds.height > 0 {
            cellHeight = bounds.height / CGFloat(rows)
        } else {
            cellHeight = 1
        }
        let size = CGSize(width: max(cellWidth, 1), height: max(cellHeight, 1))
        let length = max(cols * rows, 1)
        return (cols, rows, size, length)
    }

    private func textInputDocumentLength() -> Int {
        textInputModel.documentLength
    }

    private func clampTextInputIndex(_ index: Int) -> Int {
        min(max(index, 0), textInputDocumentLength())
    }

    var imeProxyCanBecomeFirstResponder: Bool {
        isTextInputSessionEligible && !isFindNavigatorActive
    }

    var currentTextInputContextIdentifier: String? {
        guard isTextInputSessionEligible, !isFindNavigatorActive else { return nil }
        return Self.textInputContextID
    }

    var resolvedKeyboardAppearance: UIKeyboardAppearance {
        if #available(iOS 13.0, *) {
            return traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        return .default
    }

    func imeProxySnapshot() -> IMEProxySnapshot {
        IMEProxySnapshot(
            text: imeProxyTextView.text ?? "",
            selectedRange: imeProxyTextView.selectedRange,
            markedRange: imeProxyMarkedRange()
        )
    }

    func imeProxyMarkedRange() -> NSRange? {
        guard let range = imeProxyTextView.markedTextRange else { return nil }
        let start = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        let end = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.end)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func withSuppressedIMEProxyCallbacks<T>(_ body: () -> T) -> T {
        let previous = suppressIMEProxyCallbacks
        suppressIMEProxyCallbacks = true
        defer { suppressIMEProxyCallbacks = previous }
        return body()
    }

    private func resetIMEProxyState() {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.text = ""
            imeProxyTextView.selectedRange = NSRange(location: 0, length: 0)
            imeProxyTextView.unmarkText()
        }
    }

    func syncTextInputModelFromIMEProxy() {
        guard !suppressIMEProxyCallbacks else { return }
        let snapshot = imeProxySnapshot()
        let effects = textInputModel.handleExternalState(
            text: snapshot.text,
            selectedRange: .init(location: snapshot.selectedRange.location, length: snapshot.selectedRange.length),
            markedRange: snapshot.markedRange.map { .init(location: $0.location, length: $0.length) }
        )
        applyTerminalTextInputEffects(effects)
        if snapshot.markedRange == nil {
            syncIMEPreedit(nil)
        }
    }

    var hasLocalTextInputSession: Bool {
        textInputModel.documentLength > 0 || textInputModel.hasActiveIMEComposition
    }

    func imeProxyDidDeleteBackward(before: IMEProxySnapshot?) {
        guard !suppressIMEProxyCallbacks else { return }
        let after = imeProxySnapshot()
        if before == after,
           let before,
           before.text.isEmpty,
           before.markedRange == nil,
           before.selectedRange.length == 0,
           before.selectedRange.location == 0 {
            applyTerminalTextInputEffects([.sendSpecialKey(.backspace)])
            return
        }
        syncTextInputModelFromIMEProxy()
    }

    func imeProxyFocusDidChange(isFocused: Bool) {
        setSurfaceFocus(isFocused)
        if isFocused {
            // UIKit has just resolved this responder's input views. Refresh
            // hardware state, but do not immediately invalidate the new
            // InputUI session unless that state changes its configuration.
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: false)
        } else {
            imeProxyTextView.endDictationSession(commit: true)
            invalidateLocalTextInputSession()
            cancelTrackedHardwareInput()
        }
    }

    func imeProxyCaretRect(for position: UITextPosition) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: position)
        return textInputCaretRect(for: index)
    }

    func imeProxyFirstRect(for range: UITextRange) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        return textInputCaretRect(for: index)
    }

    func invalidateLocalTextInputSession() {
        resetIMEProxyState()
        let effects = textInputModel.invalidateSession()
        applyTerminalTextInputEffects(effects, notifiesInputDelegate: true)
        syncIMEPreedit(nil)
    }

    func applyTerminalTextInputEffects(
        _ effects: [TerminalTextInputModel.Effect],
        notifiesInputDelegate: Bool = false
    ) {
        for effect in effects {
            switch effect {
            case .willTextChange:
                if notifiesInputDelegate {
                    imeProxyTextView.inputDelegate?.textWillChange(imeProxyTextView)
                }
            case .willSelectionChange:
                if notifiesInputDelegate {
                    imeProxyTextView.inputDelegate?.selectionWillChange(imeProxyTextView)
                }
            case .didTextChange:
                if notifiesInputDelegate {
                    imeProxyTextView.inputDelegate?.textDidChange(imeProxyTextView)
                }
            case .didSelectionChange:
                if notifiesInputDelegate {
                    imeProxyTextView.inputDelegate?.selectionDidChange(imeProxyTextView)
                }
            case let .syncPreedit(text):
                syncIMEPreedit(text)
            case let .sendText(text):
                sendTerminalInputText(text)
            case let .sendBackspaces(count):
                for _ in 0..<count {
                    sendKeyPress(.backspace)
                }
            case let .moveCursor(delta):
                let key: Ghostty.Input.Key = delta < 0 ? .arrowLeft : .arrowRight
                for _ in 0..<abs(delta) {
                    sendKeyPress(key)
                }
            case let .sendSpecialKey(key):
                switch key {
                case .enter:
                    sendKeyPress(.enter)
                case .tab:
                    sendKeyPress(.tab)
                case .backspace:
                    sendKeyPress(.backspace)
                }
            }
        }
    }

    func textInputCaretRect(for index: Int) -> CGRect {
        guard let surface = surface?.unsafeCValue else {
            let metrics = textInputGridMetrics()
            return CGRect(x: 0, y: 0, width: metrics.cellSize.width, height: metrics.cellSize.height)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let cellWidth = max(cellSize.width, CGFloat(max(width, 1)))
        let cellHeight = max(cellSize.height, CGFloat(max(height, 1)))
        let currentCharacterIndex = textInputModel.committedCursorCharacterIndex
        let targetCharacterIndex = textInputModel.committedCharacterIndex(forDocumentOffset: clampTextInputIndex(index))
        let delta = targetCharacterIndex - currentCharacterIndex

        return CGRect(
            x: CGFloat(x) + CGFloat(delta) * cellWidth,
            y: CGFloat(y),
            width: max(CGFloat(width), cellWidth),
            height: max(CGFloat(height), cellHeight)
        )
    }
}

#endif
