import SwiftUI

extension Workspace {
    var color: Color {
        Color.fromHex(colorHex)
    }

    static let defaultColors: [String] = [
        "#007AFF", "#AF52DE", "#FF2D55", "#FF3B30", "#FF9500",
        "#FFCC00", "#34C759", "#5AC8FA", "#00C7BE", "#5856D6"
    ]
}

extension ServerEnvironment {
    var color: Color {
        Color.fromHex(colorHex)
    }

    nonisolated var displayName: String {
        guard isBuiltIn else { return name }
        switch id {
        case ServerEnvironment.production.id: return String(localized: "Production")
        case ServerEnvironment.staging.id: return String(localized: "Staging")
        case ServerEnvironment.development.id: return String(localized: "Development")
        default: return name
        }
    }

    nonisolated var displayShortName: String {
        guard isBuiltIn else { return shortName }
        switch id {
        case ServerEnvironment.production.id: return String(localized: "Prod")
        case ServerEnvironment.staging.id: return String(localized: "Stag")
        case ServerEnvironment.development.id: return String(localized: "Dev")
        default: return shortName
        }
    }
}

extension CloudflareAccessMode {
    var displayName: String {
        switch self {
        case .oauth: return String(localized: "OAuth")
        case .serviceToken: return String(localized: "Service Token")
        }
    }
}

extension AuthMethod {
    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .sshKey: return String(localized: "SSH Key")
        case .sshKeyWithPassphrase: return String(localized: "SSH Key + Passphrase")
        }
    }

    var icon: String {
        switch self {
        case .password: return "key.fill"
        case .sshKey: return "lock.doc.fill"
        case .sshKeyWithPassphrase: return "lock.shield.fill"
        }
    }
}
