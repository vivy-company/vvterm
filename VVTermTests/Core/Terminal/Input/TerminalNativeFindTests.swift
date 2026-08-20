#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalNativeFindTests {
    @Test
    func findsRepeatedVisibleMatchesAcrossLines() {
        let snapshot = TerminalNativeTextSnapshot(
            lines: [
                "alpha beta",
                "beta gamma",
                "delta beta"
            ],
            cellSize: CGSize(width: 10, height: 20),
            columns: 20
        )

        let ranges = snapshot.searchRanges(query: "beta", options: UITextSearchOptions())

        #expect(ranges == [
            NSRange(location: 6, length: 4),
            NSRange(location: 11, length: 4),
            NSRange(location: 28, length: 4)
        ])
    }

    @Test
    func trimsWhitespaceOnlyQueriesBeforeSearching() {
        let snapshot = TerminalNativeTextSnapshot(
            lines: ["vvterm find test"],
            cellSize: CGSize(width: 10, height: 20),
            columns: 20
        )

        let ranges = snapshot.searchRanges(query: "  find  ", options: UITextSearchOptions())

        #expect(ranges == [NSRange(location: 7, length: 4)])
    }
}
#endif
