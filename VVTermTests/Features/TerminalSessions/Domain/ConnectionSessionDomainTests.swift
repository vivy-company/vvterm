import XCTest
@testable import VVTerm

final class ConnectionStateDomainTests: XCTestCase {
    func testConnectionStateFlagsReflectConnectedAndConnectingStates() {
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertTrue(ConnectionState.connecting.isConnecting)
        XCTAssertTrue(ConnectionState.reconnecting(attempt: 2).isConnecting)
        XCTAssertFalse(ConnectionState.failed(terminalExternalFailure("boom")).isConnecting)
    }
}
