import Testing
@testable import VVTerm

@MainActor
struct GhosttyRuntimeConfigurationTests {
    @Test
    func rawSettingsMapToTypedRuntimeConfiguration() {
        let configuration = Ghostty.RuntimeConfiguration(
            fontName: "Menlo",
            fontSize: TerminalDefaults.maximumFontSize + 20,
            cursorStyleRawValue: "invalid-cursor",
            cursorBlink: false,
            optionAsAltModeRawValue: TerminalOptionAsAltMode.right.rawValue,
            remoteClipboardReadPolicyRawValue: "invalid-clipboard-policy"
        )

        #expect(configuration.fontName == "Menlo")
        #expect(configuration.fontSize == TerminalDefaults.maximumFontSize)
        #expect(configuration.cursorStyle == TerminalDefaults.defaultCursorStyle)
        #expect(configuration.cursorBlink == false)
        #expect(configuration.optionAsAltMode == .right)
        #expect(configuration.remoteClipboardReadPolicy == .defaultValue)
    }

    @Test
    func appAcceptsRuntimeConfigurationBeforeStartup() {
        let configuration = Ghostty.RuntimeConfiguration(
            fontName: "Menlo",
            fontSize: 14,
            cursorStyleRawValue: TerminalCursorStyle.bar.rawValue,
            cursorBlink: false,
            optionAsAltModeRawValue: TerminalOptionAsAltMode.left.rawValue,
            remoteClipboardReadPolicyRawValue: TerminalRemoteClipboardReadPolicy.deny.rawValue
        )
        let app = GhosttyRuntime(autoStart: false)

        app.applyConfiguration(configuration)

        #expect(app.readiness == .idle)
        #expect(app.configuration == configuration)
    }
}
