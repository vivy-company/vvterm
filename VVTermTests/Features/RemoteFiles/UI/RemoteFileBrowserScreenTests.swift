import SwiftUI
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileBrowserScreenTests {
    @Test
    func uploadSelectionStartsTransferAfterPickerDismissal() throws {
        let suiteName = "RemoteFileBrowserScreenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let browser = RemoteFileBrowserStore(defaults: defaults)
        let server = Server(
            workspaceId: UUID(),
            name: "Upload test",
            host: "example.com",
            username: "test"
        )
        let tab = RemoteFileTab(serverId: server.id)
        let screen = RemoteFileBrowserScreen(
            browser: browser,
            server: server,
            fileTab: tab,
            connectionActions: { EmptyView() }
        )
        let coordinator = browser.operationCoordinator(for: tab, server: server)
        defer { coordinator.cancelAll() }

        // UIKit can return the selection after SwiftUI has cleared the sheet state.
        #expect(screen.presentation == nil)
        screen.handleUploadSelection(
            .success([URL(fileURLWithPath: "/selected.txt")]),
            toPresentedDestination: "/destination"
        )

        let operation = try #require(coordinator.operations.first)
        #expect(coordinator.operations.count == 1)
        #expect(operation.kind == .upload)
        guard case .running = operation.phase else {
            Issue.record("The selected file must start an upload.")
            return
        }
    }
}
