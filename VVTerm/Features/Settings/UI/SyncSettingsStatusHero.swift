import SwiftUI

struct SyncSettingsStatusHero: View {
    let state: SyncSettingsUserState
    let lastSuccessfulSyncDate: Date?
    let primaryAction: SyncSettingsPrimaryAction?
    let onPrimaryAction: () -> Void

    var body: some View {
        platformBody
    }
}

struct SyncSettingsPrimaryActionButton: View {
    let action: SyncSettingsPrimaryAction
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            if action.isRunning {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(action.title)
                }
            } else {
                Text(action.title)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(action.isRunning)
        .accessibilityIdentifier("vvterm.settings.sync.action.primary")
    }
}

extension SyncSettingsUserState {
    var statusHeroSystemImage: String {
        switch self {
        case .readyToSync, .upToDate:
            "icloud.fill"
        case .syncing:
            "icloud.and.arrow.up.fill"
        case .waitingForNetwork, .disabled:
            "icloud.slash.fill"
        case .signInToICloud:
            "person.crop.circle.badge.exclamationmark"
        case .needsAttention:
            "exclamationmark.icloud.fill"
        }
    }

    var statusHeroTint: Color {
        switch self {
        case .readyToSync, .upToDate, .syncing:
            .blue
        case .waitingForNetwork, .signInToICloud:
            .orange
        case .needsAttention:
            .red
        case .disabled:
            .secondary
        }
    }
}

struct SyncSettingsStatusDetail: View {
    let state: SyncSettingsUserState
    let lastSuccessfulSyncDate: Date?

    var body: some View {
        Group {
            switch state {
            case .readyToSync:
                Text("No successful sync yet.")
            case .upToDate:
                if let lastSuccessfulSyncDate {
                    Text(
                        "Last synced \(lastSuccessfulSyncDate, format: .relative(presentation: .named))"
                    )
                }
            case .syncing:
                Text("Sync in progress")
            case .waitingForNetwork:
                Text("Changes will sync later.")
            case .signInToICloud:
                Text("Sign in to continue.")
            case .needsAttention:
                Text("Your data is safe.")
            case .disabled:
                Text("Data stays on this device.")
            }
        }
        .foregroundStyle(.secondary)
    }
}
