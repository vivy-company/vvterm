import SwiftUI

struct WelcomeFeaturePresentation: Identifiable {
    let id: WelcomeFeatureID
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let color: Color
}

enum WelcomeFeaturePresentationCatalog {
    static func features(
        companionPlatformTitle: LocalizedStringKey
    ) -> [WelcomeFeaturePresentation] {
        WelcomeFeatureID.allCases.map {
            presentation(for: $0, companionPlatformTitle: companionPlatformTitle)
        }
    }

    private static func presentation(
        for id: WelcomeFeatureID,
        companionPlatformTitle: LocalizedStringKey
    ) -> WelcomeFeaturePresentation {
        switch id {
        case .sshTerminal:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "terminal.fill",
                title: "SSH Terminal",
                description: "Connect to servers with GPU-accelerated terminal emulation.",
                color: .blue
            )
        case .sftpFiles:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "folder.fill",
                title: "SFTP Files",
                description: "Browse folders, preview files, and move things around on your server.",
                color: .indigo
            )
        case .serverStats:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "chart.xyaxis.line",
                title: "Server Stats",
                description: "Keep an eye on CPU, memory, disk, and network activity at a glance.",
                color: .mint
            )
        case .companionPlatform:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "macbook.and.iphone",
                title: companionPlatformTitle,
                description: "VVTerm is available on iPhone, iPad, and Mac. Pro purchases carry over with the same Apple ID.",
                color: .blue
            )
        case .iCloudSync:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "icloud.fill",
                title: "iCloud Sync",
                description: "Server metadata syncs with iCloud across your devices.",
                color: .cyan
            )
        case .sessionPersistence:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "clock.arrow.circlepath",
                title: "Session Persistence",
                description: "Keep sessions alive with tmux, even after disconnects.",
                color: .teal
            )
        case .secureStorage:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "key.fill",
                title: "Secure Storage",
                description: "Passwords and SSH keys protected by Keychain.",
                color: .green
            )
        case .voiceCommands:
            return WelcomeFeaturePresentation(
                id: id,
                icon: "waveform",
                title: "Voice Commands",
                description: "Speak commands with on-device speech recognition.",
                color: .orange
            )
        }
    }
}
