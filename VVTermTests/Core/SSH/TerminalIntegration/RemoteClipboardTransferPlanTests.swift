import Foundation
import Testing
@testable import VVTerm

struct RemoteClipboardTransferPlanTests {
    private let linuxEnvironment = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "zsh"),
        activeShellName: "zsh",
        powerShellExecutable: nil
    )

    private let powerShellEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .powershell(executableName: "powershell"),
        activeShellName: "powershell",
        powerShellExecutable: "powershell"
    )

    private let cmdEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .cmd,
        activeShellName: "cmd.exe",
        powerShellExecutable: "pwsh"
    )

    @Test
    func selectsPlatformSpecificUploadStrategies() throws {
        let posix = try RemoteClipboardTransferPlan.resolve(for: linuxEnvironment)
        let powerShell = try RemoteClipboardTransferPlan.resolve(for: powerShellEnvironment)
        let cmd = try RemoteClipboardTransferPlan.resolve(for: cmdEnvironment)

        guard case .posix(let posixUploadStrategy) = posix else {
            Issue.record("Expected POSIX transfer plan")
            return
        }
        guard case .automatic = posixUploadStrategy else {
            Issue.record("Expected automatic POSIX upload strategy")
            return
        }
        #expect(posix.usesSFTP == false)
        #expect(powerShell.usesSFTP)
        #expect(cmd.usesSFTP)
    }

    @Test
    func rejectsWindowsShellWithoutPowerShellHelper() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: nil
        )

        #expect(throws: TerminalRichPasteError.self) {
            _ = try RemoteClipboardTransferPlan.resolve(for: environment)
        }
    }

    @Test
    func convertsNativeWindowsDrivePathForOpenSSHSFTP() throws {
        let plan = try RemoteClipboardTransferPlan.resolve(for: powerShellEnvironment)

        #expect(
            try plan.transferPath(for: #"C:\Users\Wiedy Mi\AppData\Local\Temp\vvterm-clipboard-a1.png"#)
                == "/C:/Users/Wiedy Mi/AppData/Local/Temp/vvterm-clipboard-a1.png"
        )
    }

    @Test
    func parsesOnlyAbsoluteTemporaryPathsForEachPlatform() throws {
        let posix = try RemoteClipboardTransferPlan.resolve(for: linuxEnvironment)
        let windows = try RemoteClipboardTransferPlan.resolve(for: powerShellEnvironment)

        #expect(try posix.parseTemporaryPath("/tmp/vvterm-clipboard-a1.png\n") == "/tmp/vvterm-clipboard-a1.png")
        #expect(
            try windows.parseTemporaryPath(#"C:\Users\Wiedy Mi\AppData\Local\Temp\vvterm-clipboard-a1.png"#)
                == #"C:\Users\Wiedy Mi\AppData\Local\Temp\vvterm-clipboard-a1.png"#
        )
        #expect(throws: TerminalRichPasteError.self) {
            _ = try windows.parseTemporaryPath("vvterm-clipboard-a1.png")
        }
    }

    @Test
    func quotesPastedPathForPowerShellAndCmd() throws {
        let powerShell = try RemoteClipboardTransferPlan.resolve(for: powerShellEnvironment)
        let cmd = try RemoteClipboardTransferPlan.resolve(for: cmdEnvironment)

        #expect(
            try powerShell.pastedPathToken(for: #"C:\Users\O'Hara\My Images\image.png"#)
                == #"'C:\Users\O''Hara\My Images\image.png'"#
        )
        #expect(
            try cmd.pastedPathToken(for: #"C:\Users\Wiedy Mi\A&B^(1)\image.png"#)
                == #""C:\Users\Wiedy Mi\A&B^(1)\image.png""#
        )
    }

    @Test
    func rejectsCmdExpansionCharactersBeforeInsertion() throws {
        let cmd = try RemoteClipboardTransferPlan.resolve(for: cmdEnvironment)

        #expect(throws: TerminalRichPasteError.self) {
            _ = try cmd.pastedPathToken(for: #"C:\Users\%USERNAME%\image.png"#)
        }
        #expect(throws: TerminalRichPasteError.self) {
            _ = try cmd.pastedPathToken(for: #"C:\Users\Wiedy!\image.png"#)
        }
    }

    @Test
    func buildsExactWindowsCleanupAndOwnedStaleSweepCommands() throws {
        let plan = try RemoteClipboardTransferPlan.resolve(for: powerShellEnvironment)
        let path = #"C:\Users\O'Hara\AppData\Local\Temp\vvterm-clipboard-a1.png"#

        let deleteCommand = plan.deleteCommand(for: path)
        let sweepCommand = plan.staleSweepCommand

        #expect(deleteCommand.hasPrefix("powershell -NoLogo -NoProfile -EncodedCommand "))
        #expect(
            decodePowerShellCommand(deleteCommand)
                == #"[IO.File]::Delete('C:\Users\O''Hara\AppData\Local\Temp\vvterm-clipboard-a1.png')"#
        )
        #expect(sweepCommand.hasPrefix("powershell -NoLogo -NoProfile -EncodedCommand "))
        let decodedSweep = try #require(decodePowerShellCommand(sweepCommand))
        #expect(decodedSweep.contains("[IO.Path]::GetTempPath()"))
        #expect(decodedSweep.contains("vvterm-clipboard-*"))
        #expect(decodedSweep.contains("LastWriteTimeUtc"))
        #expect(decodedSweep.contains("[IO.File]::Delete($_.FullName)"))
    }

    @Test
    func sanitizesImageExtensionBeforeBuildingTempCommand() throws {
        let plan = try RemoteClipboardTransferPlan.resolve(for: powerShellEnvironment)
        let command = plan.temporaryPathCommand(fileExtension: "P.N/G")
        let decoded = try #require(decodePowerShellCommand(command))

        #expect(decoded.contains(".png"))
        #expect(!decoded.contains("P.N/G"))
    }

    private func decodePowerShellCommand(_ command: String) -> String? {
        guard let encoded = command.split(separator: " ").last,
              let data = Data(base64Encoded: String(encoded))
        else {
            return nil
        }
        return String(data: data, encoding: .utf16LittleEndian)
    }
}
