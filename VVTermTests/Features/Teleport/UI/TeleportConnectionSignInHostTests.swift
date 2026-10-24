import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TeleportConnectionSignInHostTests {
    @Test
    func approvalNamesTheSelectedServerAndTeleport() {
        let prompt = TeleportConnectionSignInHost.signInPrompt(serverName: "Lab node")
        #expect(prompt.contains("Lab node"))
        #expect(prompt.contains("Teleport"))
    }

    @Test(arguments: ["\n\t", String(repeating: "Node\n", count: 1000), "e" + String(repeating: "\u{0301}", count: 1000)])
    func approvalStaysWithinTheLibraryPromptLimits(serverName: String) {
        let prompt = TeleportConnectionSignInHost.signInPrompt(serverName: serverName)
        #expect(!prompt.isEmpty)
        #expect(prompt.utf8.count <= 1024)
        #expect(!prompt.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }
}
