#if os(iOS)
import UIKit

@available(iOS 16.0, *)
@MainActor
final class GhosttyNativeFindSession: UIFindSession {
    typealias SearchHandler = (_ query: String, _ options: UITextSearchOptions?) -> Void
    typealias NavigateHandler = (_ direction: UITextStorageDirection) -> Void
    typealias InvalidateHandler = () -> Void

    private let onSearch: SearchHandler
    private let onNavigate: NavigateHandler
    private let onInvalidate: InvalidateHandler

    private var reportedResultCount = 0
    private var reportedHighlightedResultIndex = NSNotFound
    private(set) var currentQuery = ""

    override var resultCount: Int {
        reportedResultCount
    }

    override var highlightedResultIndex: Int {
        reportedHighlightedResultIndex
    }

    override var supportsReplacement: Bool {
        false
    }

    override var allowsReplacementForCurrentlyHighlightedResult: Bool {
        false
    }

    init(
        onSearch: @escaping SearchHandler,
        onNavigate: @escaping NavigateHandler,
        onInvalidate: @escaping InvalidateHandler
    ) {
        self.onSearch = onSearch
        self.onNavigate = onNavigate
        self.onInvalidate = onInvalidate
        super.init()
        searchResultDisplayStyle = .currentAndTotal
    }

    override func performSearch(query: String, options: UITextSearchOptions?) {
        currentQuery = query
        resetReportedResults()
        onSearch(query, options)
    }

    override func highlightNextResult(in direction: UITextStorageDirection) {
        onNavigate(direction)
    }

    override func invalidateFoundResults() {
        currentQuery = ""
        resetReportedResults()
        onInvalidate()
    }

    func applyExternalQuery(_ query: String) {
        currentQuery = query
    }

    func updateReportedResults(total: Int?, highlightedIndex: Int?) -> Bool {
        let normalizedTotal = max(total ?? 0, 0)
        let normalizedHighlighted: Int
        if let highlightedIndex,
           normalizedTotal > 0,
           highlightedIndex >= 0,
           highlightedIndex < normalizedTotal {
            normalizedHighlighted = highlightedIndex
        } else {
            normalizedHighlighted = NSNotFound
        }

        guard reportedResultCount != normalizedTotal ||
                reportedHighlightedResultIndex != normalizedHighlighted else {
            return false
        }

        reportedResultCount = normalizedTotal
        reportedHighlightedResultIndex = normalizedHighlighted
        return true
    }

    func resetReportedResults() {
        _ = updateReportedResults(total: 0, highlightedIndex: nil)
    }
}
#endif
