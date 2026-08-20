//
//  GhosttyTerminalFind+iOS.swift
//  VVTerm
//
//  iOS native find delegate routing.
//

#if os(iOS)
import UIKit

@available(iOS 16.0, *)
extension GhosttyTerminalView: UIFindInteractionDelegate {
    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        guard view === self, usesNativeTouchSelection else { return nil }
        refreshNativeSelectionSnapshot()
        if let nativeFindSession {
            return nativeFindSession
        }

        let session = GhosttyNativeFindSession(
            onSearch: { [weak self] query, _ in
                guard let self else { return }
                self.performGhosttyFindQuery(
                    query,
                    keepNavigatorVisibleOnSearchEnd: query.isEmpty && self.isFindNavigatorActive
                )
            },
            onNavigate: { [weak self] direction in
                self?.navigateGhosttyFind(direction)
            },
            onInvalidate: { [weak self] in
                self?.invalidateGhosttyFindWithoutClosingNavigator()
            }
        )
        nativeFindSession = session
        applyStoredGhosttyFindResultsToNativeSession()
        return session
    }

    func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
        if !findNavigatorLifecycle.isActive {
            findNavigatorLifecycle.begin(restoreTerminalFocus: isTerminalTextInputActive)
        }
        refreshNativeSelectionSnapshot()
        applyStoredGhosttyFindResultsToNativeSession()
        notifyFindNavigatorVisibilityChange()
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        completeFindNavigatorDismissal()
    }
}

@available(iOS 16.0, *)
extension GhosttyTerminalView: UITextSearching {
    var selectedTextRange: UITextRange? {
        imeProxyTextView.selectedTextRange
    }

    typealias DocumentIdentifier = String

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: String?) -> ComparisonResult {
        guard let lhs = nativeSelectionSnapshot.nativeRange(from: foundRange),
              let rhs = nativeSelectionSnapshot.nativeRange(from: toRange) else {
            return .orderedSame
        }
        if lhs.location < rhs.location { return .orderedAscending }
        if lhs.location > rhs.location { return .orderedDescending }
        if lhs.length < rhs.length { return .orderedAscending }
        if lhs.length > rhs.length { return .orderedDescending }
        return .orderedSame
    }

    func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<String>) {
        refreshNativeSelectionSnapshot()
        nativeFindDecorations.removeAll()

        let ranges = nativeSelectionSnapshot.searchRanges(query: queryString, options: options)
        for range in ranges {
            guard let textRange = nativeSelectionSnapshot.nativeRange(range) else { continue }
            resultAggregator.foundRange(textRange, searchString: queryString, document: nativeFindDocumentIdentifier)
        }
        resultAggregator.finishedSearching()
    }

    func decorate(foundTextRange: UITextRange, document: String?, usingStyle style: UITextSearchFoundTextStyle) {
        guard let range = nativeSelectionSnapshot.nativeRange(from: foundTextRange) else { return }
        nativeFindDecorations.removeAll { NSEqualRanges($0.range, range) }
        nativeFindDecorations.append(TerminalNativeFindDecoration(range: range, style: style))
    }

    func clearAllDecoratedFoundText() {
        nativeFindDecorations.removeAll()
    }

    func willHighlight(foundTextRange: UITextRange, document: String?) {
        requestRender()
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument document: String?) {
        requestRender()
    }

    var selectedTextSearchDocument: String? {
        nativeFindDocumentIdentifier
    }

    func compare(document: String, toDocument other: String) -> ComparisonResult {
        document.compare(other)
    }
}

extension GhosttyTerminalView {
    func setupNativeFindInteraction() {
        guard #available(iOS 16.0, *), nativeFindInteraction == nil else { return }
        let interaction = UIFindInteraction(sessionDelegate: self)
        interaction.optionsMenuProvider = { _ in nil }
        addInteraction(interaction)
        nativeFindInteraction = interaction
    }

    func updateNativeFindOverlay() {
        guard usesNativeTouchSelection else { return }
        let highlights = nativeFindDecorations.flatMap { decoration in
            nativeSelectionSnapshot.selectionRects(for: decoration.range).map {
                TerminalNativeFindOverlayView.Highlight(rect: $0.rect, style: decoration.style)
            }
        }
        nativeFindOverlay.highlights = highlights
    }

    @available(iOS 16.0, *)
    private func beginFindNavigatorPresentation(restoreTerminalFocus: Bool) {
        logKeyboardLifecycle(
            "find.begin",
            detail: "restoreTerminalFocus=\(restoreTerminalFocus)"
        )
        findNavigatorLifecycle.begin(restoreTerminalFocus: restoreTerminalFocus)
        notifyFindNavigatorVisibilityChange()
        cancelTrackedHardwareInput()

        if !super.isFirstResponder {
            _ = super.becomeFirstResponder()
        }

        setSurfaceFocus(false)
    }

    private func endFindNavigatorLifecycle() -> Bool {
        let shouldRestoreTerminalFocus = findNavigatorLifecycle.end()
        if !shouldRestoreTerminalFocus, super.isFirstResponder {
            _ = super.resignFirstResponder()
        }
        return shouldRestoreTerminalFocus
    }

    @available(iOS 16.0, *)
    func completeFindNavigatorDismissal() {
        guard findNavigatorLifecycle.isActive else { return }
        logKeyboardLifecycle("find.end.begin")
        let shouldRestoreTerminalFocus = endFindNavigatorLifecycle()
        nativeFindDecorations.removeAll()
        nativeFindSession?.resetReportedResults()
        nativeFindSession = nil
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        // UIFindInteraction can still report `isFindNavigatorVisible == true`
        // from inside its didEnd callback. The lifecycle end is authoritative;
        // publishing the stale UIKit value leaves the coordinator believing
        // Find still owns input after the navigator has disappeared.
        notifyFindNavigatorVisibilityChange(false)
        endGhosttyFindSearchForNavigatorDismissal()
        if shouldRestoreTerminalFocus {
            DispatchQueue.main.async { [weak self] in
                self?.notifyDirectTouchOnTerminal()
            }
        }
        logKeyboardLifecycle(
            "find.end.complete",
            detail: "restoreTerminalFocus=\(shouldRestoreTerminalFocus)"
        )
    }

    @available(iOS 16.0, *)
    func presentFindNavigator(prefillingSelectedText: Bool = false) {
        guard let nativeFindInteraction else { return }
        beginFindNavigatorPresentation(restoreTerminalFocus: isTerminalTextInputActive)
        refreshNativeSelectionSnapshot()
        if prefillingSelectedText, let selectionText = normalizedSelectionMenuText() {
            nativeFindInteraction.searchText = selectionText
            nativeFindSession?.applyExternalQuery(selectionText)
            performGhosttyFindQuery(selectionText)
        }
        nativeFindInteraction.presentFindNavigator(showingReplace: false)
    }

    func showFindNavigator(prefillingSelectedText: Bool = false) {
        guard usesNativeTouchSelection else { return }
        if #available(iOS 16.0, *) {
            presentFindNavigator(prefillingSelectedText: prefillingSelectedText)
        }
    }

    func dismissFindNavigator() {
        guard #available(iOS 16.0, *), isFindNavigatorActive else { return }
        if nativeFindInteraction?.isFindNavigatorVisible == true {
            nativeFindInteraction?.dismissFindNavigator()
        } else if findNavigatorLifecycle.isActive {
            completeFindNavigatorDismissal()
        }
    }

    @MainActor
    @discardableResult
    func performGhosttyFindQuery(
        _ query: String,
        keepNavigatorVisibleOnSearchEnd: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        let action = "search:\(query)"
        if keepNavigatorVisibleOnSearchEnd {
            findNavigatorLifecycle.suppressNextGhosttySearchEnd()
        }
        guard surface.perform(action: action) else {
            if keepNavigatorVisibleOnSearchEnd {
                findNavigatorLifecycle.cancelSuppressedGhosttySearchEnd()
            }
            return false
        }
        if query.isEmpty {
            nativeFindSession?.resetReportedResults()
            nativeFindInteraction?.updateResultCount()
        }
        return true
    }

    @MainActor
    func navigateGhosttyFind(_ direction: UITextStorageDirection) {
        guard let surface else { return }
        let action = direction == .backward ? "navigate_search:previous" : "navigate_search:next"
        _ = surface.perform(action: action)
    }

    @MainActor
    private func endGhosttyFindSearchForNavigatorDismissal() {
        guard let surface else { return }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        findNavigatorLifecycle.suppressNextGhosttySearchEnd()
        if !surface.perform(action: "end_search") {
            findNavigatorLifecycle.cancelSuppressedGhosttySearchEnd()
        }
    }

    @MainActor
    func invalidateGhosttyFindWithoutClosingNavigator() {
        performGhosttyFindQuery("", keepNavigatorVisibleOnSearchEnd: true)
    }

    @MainActor
    func applyStoredGhosttyFindResultsToNativeSession() {
        guard #available(iOS 16.0, *), let nativeFindSession else { return }
        if nativeFindSession.updateReportedResults(
            total: ghosttyFindReportedTotal,
            highlightedIndex: ghosttyFindReportedSelectedIndex
        ) {
            nativeFindInteraction?.updateResultCount()
        }
    }

    func handleGhosttySearchStarted(needle: String) {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        if #available(iOS 16.0, *) {
            nativeFindInteraction?.searchText = needle
            nativeFindSession?.applyExternalQuery(needle)
            applyStoredGhosttyFindResultsToNativeSession()
            if nativeFindInteraction?.isFindNavigatorVisible != true {
                beginFindNavigatorPresentation(restoreTerminalFocus: isTerminalTextInputActive)
                nativeFindInteraction?.presentFindNavigator(showingReplace: false)
            }
        }
    }

    func handleGhosttySearchEnded() {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        if #available(iOS 16.0, *) {
            nativeFindSession?.resetReportedResults()
            nativeFindInteraction?.updateResultCount()
            if findNavigatorLifecycle.consumeSuppressedGhosttySearchEnd() {
                return
            } else if nativeFindInteraction?.isFindNavigatorVisible == true {
                nativeFindInteraction?.dismissFindNavigator()
            } else if findNavigatorLifecycle.isActive {
                _ = endFindNavigatorLifecycle()
                notifyFindNavigatorVisibilityChange()
            }
        }
    }

    func handleGhosttySearchTotalChange(_ total: Int?) {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedTotal = total
        if #available(iOS 16.0, *) {
            applyStoredGhosttyFindResultsToNativeSession()
        }
    }

    func handleGhosttySearchSelectedChange(_ selected: Int?) {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedSelectedIndex = selected
        if #available(iOS 16.0, *) {
            applyStoredGhosttyFindResultsToNativeSession()
        }
    }

}

#endif
