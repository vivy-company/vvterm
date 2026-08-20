nonisolated enum WelcomeFeatureID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case sshTerminal = "ssh_terminal"
    case sftpFiles = "sftp_files"
    case serverStats = "server_stats"
    case companionPlatform = "companion_platform"
    case iCloudSync = "icloud_sync"
    case sessionPersistence = "session_persistence"
    case secureStorage = "secure_storage"
    case voiceCommands = "voice_commands"

    var id: String { rawValue }
}
