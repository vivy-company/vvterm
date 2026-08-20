#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalCloseAlertTests {
    @Test
    func closeIsThePreferredAlertAction() throws {
        let alert = TerminalCloseAlertFactory.make(
            message: "Message",
            onCancel: {},
            onClose: {}
        )

        let close = try #require(
            alert.actions.first { $0.title == "Close" }
        )
        let cancel = try #require(
            alert.actions.first { $0.title == "Cancel" }
        )

        #expect(alert.preferredAction === close)
        #expect(close.style == .destructive)
        #expect(cancel.style == .cancel)
    }
}
#endif
