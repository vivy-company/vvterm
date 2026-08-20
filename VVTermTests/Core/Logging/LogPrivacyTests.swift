import Foundation
import Testing
@testable import VVTerm

struct LogPrivacyTests {
    private struct RemoteControlledError: LocalizedError {
        var errorDescription: String? {
            "secret/path\nforged log line"
        }
    }

    @Test
    func errorClassDoesNotIncludeRemoteControlledDescription() {
        let value = LogPrivacy.errorClass(RemoteControlledError())

        #expect(value.contains("RemoteControlledError"))
        #expect(!value.contains("secret"))
        #expect(!value.contains("\n"))
    }
}
