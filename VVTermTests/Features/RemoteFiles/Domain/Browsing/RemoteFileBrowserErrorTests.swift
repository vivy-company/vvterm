import XCTest
@testable import VVTerm

final class RemoteFileBrowserErrorTests: XCTestCase {
    func testHostKeyApprovalKeepsTypedError() {
        XCTAssertEqual(
            RemoteFileBrowserError.map(SSHError.hostKeyApprovalRequired),
            .hostKeyApprovalRequired
        )
    }

    func testHostKeyApprovalDoesNotBecomeMissingCredentials() {
        XCTAssertNotEqual(
            RemoteFileBrowserError.hostKeyApprovalRequired.errorDescription,
            "No credentials found"
        )
    }

    func testMappingAlreadyTypedApprovalDoesNotEraseItsType() {
        XCTAssertEqual(
            RemoteFileBrowserError.map(
                RemoteFileBrowserError.hostKeyApprovalRequired
            ),
            .hostKeyApprovalRequired
        )
    }
}
