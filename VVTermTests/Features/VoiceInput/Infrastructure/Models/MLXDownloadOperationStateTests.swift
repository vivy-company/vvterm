import Foundation
import XCTest
@testable import VVTerm

final class MLXDownloadOperationStateTests: XCTestCase {
    func testSecondDownloadCannotStartWhileOperationIsActive() throws {
        var state = MLXDownloadOperationState()

        XCTAssertNotNil(state.start())
        XCTAssertNil(state.start())
    }

    func testStaleTaskCallbacksAreRejected() throws {
        var state = MLXDownloadOperationState()
        let operationID = try XCTUnwrap(state.start())
        XCTAssertTrue(state.beginTask(operationID: operationID, taskIdentifier: 41))

        XCTAssertFalse(state.accepts(taskIdentifier: 40))
        XCTAssertFalse(state.finishTask(taskIdentifier: 40))
        XCTAssertTrue(state.accepts(taskIdentifier: 41))
    }

    func testOperationCannotFinishUntilItsFileFinishes() throws {
        var state = MLXDownloadOperationState()
        let operationID = try XCTUnwrap(state.start())
        XCTAssertTrue(state.beginTask(operationID: operationID, taskIdentifier: 8))

        XCTAssertFalse(state.finish(operationID: operationID))
        XCTAssertTrue(state.finishTask(taskIdentifier: 8))
        XCTAssertTrue(state.finish(operationID: operationID))
        XCTAssertEqual(state.phase, .idle)
    }

    func testCancelledOperationRejectsLateCallback() throws {
        var state = MLXDownloadOperationState()
        let operationID = try XCTUnwrap(state.start())
        XCTAssertTrue(state.beginTask(operationID: operationID, taskIdentifier: 9))

        XCTAssertTrue(state.cancel(operationID: operationID))

        XCTAssertFalse(state.accepts(taskIdentifier: 9))
        XCTAssertEqual(state.phase, .idle)
    }

    func testShutdownRejectsLateCompletionAndNewWork() throws {
        var state = MLXDownloadOperationState()
        let operationID = try XCTUnwrap(state.start())
        XCTAssertTrue(state.beginTask(operationID: operationID, taskIdentifier: 17))

        state.shutdown()

        XCTAssertTrue(state.isShutdown)
        XCTAssertFalse(state.accepts(taskIdentifier: 17))
        XCTAssertFalse(state.finishTask(taskIdentifier: 17))
        XCTAssertFalse(state.finish(operationID: operationID))
        XCTAssertNil(state.start())
    }

    func testByteAdditionSaturatesOnOverflow() {
        XCTAssertEqual(MLXModelManager.addingBytes(Int64.max - 2, 10), Int64.max)
    }
}
