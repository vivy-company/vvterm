import Foundation

nonisolated enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case system
    case mlxWhisper
    case mlxParakeet

    nonisolated var id: String { rawValue }
}

nonisolated struct VoiceSettings: Equatable, Sendable {
    var provider: TranscriptionProvider
    var whisperModelID: String
    var parakeetModelID: String
    var languageCode: String
    var terminalVoiceButtonEnabled: Bool
}
