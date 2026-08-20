import Foundation

extension Ghostty {
    struct RuntimeConfiguration: Equatable {
        let fontName: String
        let fontSize: Double
        let cursorStyle: TerminalCursorStyle
        let cursorBlink: Bool
        let optionAsAltMode: TerminalOptionAsAltMode
        let remoteClipboardReadPolicy: TerminalRemoteClipboardReadPolicy

        init(
            fontName: String,
            fontSize: Double,
            cursorStyleRawValue: String,
            cursorBlink: Bool,
            optionAsAltModeRawValue: String,
            remoteClipboardReadPolicyRawValue: String
        ) {
            self.fontName = fontName
            self.fontSize = TerminalDefaults.clampedFontSize(fontSize)
            self.cursorStyle = TerminalCursorStyle(rawValue: cursorStyleRawValue)
                ?? TerminalDefaults.defaultCursorStyle
            self.cursorBlink = cursorBlink
            self.optionAsAltMode = TerminalOptionAsAltMode(rawValue: optionAsAltModeRawValue)
                ?? .none
            self.remoteClipboardReadPolicy = TerminalRemoteClipboardReadPolicy(
                rawValue: remoteClipboardReadPolicyRawValue
            ) ?? .defaultValue
        }

        @MainActor static var defaultValue: Self {
            Self(
                fontName: TerminalDefaults.defaultFontName,
                fontSize: TerminalDefaults.defaultFontSize,
                cursorStyleRawValue: TerminalDefaults.defaultCursorStyle.rawValue,
                cursorBlink: TerminalDefaults.defaultCursorBlink,
                optionAsAltModeRawValue: TerminalOptionAsAltMode.none.rawValue,
                remoteClipboardReadPolicyRawValue: TerminalRemoteClipboardReadPolicy.defaultValue.rawValue
            )
        }
    }
}
