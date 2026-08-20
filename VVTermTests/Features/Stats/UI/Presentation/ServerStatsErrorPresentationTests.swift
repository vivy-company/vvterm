import XCTest
@testable import VVTerm

final class ServerStatsErrorPresentationTests: XCTestCase {
    func testCollectionStateMapsHostKeyApprovalMessage() {
        let request = ServerStatsApprovalRequest(
            id: "host-key",
            serverID: UUID()
        )
        let state = stateRequiringApproval(request)

        XCTAssertEqual(
            state.errorMessage,
            String(localized: "SSH host key approval is required before authentication.")
        )
    }

    func testCollectionFailuresMapExactMessages() {
        let cases: [(failure: ServerStatsCollectionFailure, message: String)] = [
            (
                .securityApprovalCancelled,
                String(localized: "Security approval was cancelled.")
            ),
            (
                .securityApprovalExpired,
                String(localized: "Security approval expired. Try again.")
            ),
            (
                .securityApprovalUnavailable,
                String(localized: "Security approval is no longer available. Try again.")
            ),
            (.external(detail: "Connection failed"), "Connection failed")
        ]

        for testCase in cases {
            XCTAssertEqual(
                stateFailed(with: testCase.failure).errorMessage,
                testCase.message
            )
        }
    }

    func testCollectionStateHasNoMessageOutsideErrors() {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()
        XCTAssertNil(state.errorMessage)

        state.start(attemptID: attemptID)
        XCTAssertNil(state.errorMessage)

        XCTAssertTrue(state.markConnected(attemptID: attemptID))
        XCTAssertNil(state.errorMessage)

        state.stop()
        XCTAssertNil(state.errorMessage)
    }

    func testProcessControlErrorsMapExactMessages() {
        XCTAssertEqual(
            ProcessControlError.notConnected.localizedDescription,
            String(localized: "Stats is not connected to the server.")
        )
        XCTAssertEqual(
            ProcessControlError.protectedProcess.localizedDescription,
            String(localized: "This process cannot be killed from Stats.")
        )
    }

    private func stateRequiringApproval(
        _ request: ServerStatsApprovalRequest
    ) -> ServerStatsCollectionState {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()
        state.start(attemptID: attemptID)
        XCTAssertTrue(state.requireApproval(attemptID: attemptID, request: request))
        return state
    }

    private func stateFailed(
        with failure: ServerStatsCollectionFailure
    ) -> ServerStatsCollectionState {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()
        state.start(attemptID: attemptID)
        XCTAssertTrue(state.finish(attemptID: attemptID, failure: failure))
        return state
    }
}
