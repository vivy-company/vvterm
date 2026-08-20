import Foundation

enum SyncSettingsPrimaryAction: Equatable {
    case syncNow
    case tryAgain
    case checkAgain
    case syncing

    var title: LocalizedStringResource {
        switch self {
        case .syncNow: "Sync Now"
        case .tryAgain: "Try Again"
        case .checkAgain: "Check Again"
        case .syncing: "Syncing"
        }
    }

    var isRunning: Bool {
        self == .syncing
    }
}

enum SyncSettingsContentSyncState: Equatable {
    case synced
    case included
    case notSyncing

    init(
        syncEnabled: Bool,
        userState: SyncSettingsUserState,
        lastSuccessfulSyncDate: Date?
    ) {
        if !syncEnabled {
            self = .notSyncing
        } else if userState == .upToDate, lastSuccessfulSyncDate != nil {
            self = .synced
        } else {
            self = .included
        }
    }

    var sectionTitle: LocalizedStringResource {
        switch self {
        case .synced: "Synced with iCloud"
        case .included: "Included in iCloud Sync"
        case .notSyncing: "iCloud Sync Includes"
        }
    }

    var rowTitle: LocalizedStringResource {
        switch self {
        case .synced: "Synced"
        case .included: "Included"
        case .notSyncing: "Not Syncing"
        }
    }
}

extension SyncSettingsUserState {
    var title: String {
        switch self {
        case .readyToSync: String(localized: "Ready to Sync")
        case .upToDate: String(localized: "Up to Date")
        case .syncing: String(localized: "Syncing")
        case .waitingForNetwork: String(localized: "Waiting for Network")
        case .signInToICloud: String(localized: "Sign In to iCloud")
        case .needsAttention: String(localized: "Sync Needs Attention")
        case .disabled: String(localized: "Sync is Off")
        }
    }

    var recoveryGuidance: String? {
        switch self {
        case .waitingForNetwork:
            String(localized: "Check your network connection.")
        case .signInToICloud:
            String(localized: "Sign in to iCloud and turn on iCloud Drive.")
        case .needsAttention:
            String(localized: "Try syncing again. Your changes are safe.")
        case .readyToSync, .upToDate, .syncing, .disabled:
            nil
        }
    }
}

extension SyncSettingsCredentialState {
    var statusTitle: LocalizedStringResource {
        switch self {
        case .storedInICloudKeychain: "iCloud Keychain"
        case .storedOnThisDevice: "On This Device"
        case .needsAttention: "Needs Attention"
        }
    }
}

extension SyncSettingsErrorCategory {
    var title: LocalizedStringResource {
        switch self {
        case .account: "Account"
        case .cloudData: "App Data"
        case .credentials: "Credentials"
        case .network: "Network"
        }
    }
}

extension SyncSettingsManualSyncState {
    var announcement: String? {
        switch self {
        case .success:
            String(localized: "iCloud Sync completed.")
        case .waitingForNetwork:
            String(localized: "iCloud Sync is waiting for the network.")
        case .accountActionRequired:
            String(localized: "Sign in to iCloud to sync.")
        case .failure:
            String(localized: "iCloud Sync needs attention.")
        case .idle, .running:
            nil
        }
    }
}
