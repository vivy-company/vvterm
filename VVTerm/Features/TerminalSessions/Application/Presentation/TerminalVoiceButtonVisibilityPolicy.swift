nonisolated enum TerminalVoiceButtonVisibilityPolicy {
    static func isVisible(
        settingEnabled: Bool,
        tabSelected: Bool,
        paneFocused: Bool,
        recording: Bool
    ) -> Bool {
        settingEnabled && tabSelected && paneFocused && !recording
    }
}
