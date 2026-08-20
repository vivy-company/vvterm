import Foundation
import XCTest
@testable import VVTerm

final class ServerDataLoadStateTests: XCTestCase {
    func testFailureRemainsVisibleAfterLoadFinishes() {
        var state = ServerDataLoadState()
        let operationID = UUID()
        state.start(operationID: operationID)

        XCTAssertTrue(state.fail(operationID: operationID, message: "CloudKit unavailable"))

        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.errorMessage, "CloudKit unavailable")
    }

    func testStaleCompletionCannotFinishNewLoad() {
        var state = ServerDataLoadState()
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        state.start(operationID: firstOperationID)
        state.start(operationID: secondOperationID)

        XCTAssertFalse(state.finish(operationID: firstOperationID))
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)

        XCTAssertTrue(state.finish(operationID: secondOperationID))
        XCTAssertFalse(state.isLoading)
    }

    func testNewLoadClearsPreviousFailure() {
        var state = ServerDataLoadState()
        let failedOperationID = UUID()
        state.start(operationID: failedOperationID)
        state.fail(operationID: failedOperationID, message: "Failed")

        state.start(operationID: UUID())

        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }
}
