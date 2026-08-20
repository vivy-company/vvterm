#if os(macOS)
import Foundation
import Testing

struct TerminfoResourcesTests {
    @Test
    func sourceAndBundledTerminfoStaySemanticallyEquivalent() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let validator = repository.appendingPathComponent("scripts/validate_terminfo.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [validator.path]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        if process.terminationStatus != 0 {
            Issue.record("Terminfo validation failed:\n\(diagnostics)")
        }
        #expect(process.terminationStatus == 0)
    }
}
#endif
