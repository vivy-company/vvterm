import Foundation

// MARK: - Server Model (CloudKit synced)

struct Server: Identifiable, Codable, Hashable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var tags: [String]
    var notes: String?
    var lastConnected: Date?
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date

    // Keychain reference (not synced to CloudKit)
    var keychainCredentialId: String

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        environment: ServerEnvironment = .production,
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        tags: [String] = [],
        notes: String? = nil,
        lastConnected: Date? = nil,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        keychainCredentialId: String? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.environment = environment
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.tags = tags
        self.notes = notes
        self.lastConnected = lastConnected
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.keychainCredentialId = keychainCredentialId ?? id.uuidString
    }

    var displayAddress: String {
        if port == 22 {
            return "\(username)@\(host)"
        }
        return "\(username)@\(host):\(port)"
    }
}

// MARK: - Authentication Method

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case sshKey
    case sshKeyWithPassphrase

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return "Password"
        case .sshKey: return "SSH Key"
        case .sshKeyWithPassphrase: return "SSH Key + Passphrase"
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

// MARK: - Server Credentials (for authentication)

struct ServerCredentials {
    let serverId: UUID
    var password: String?
    var privateKey: Data?
    var passphrase: String?

    var sshKey: Data? {
        get { privateKey }
        set { privateKey = newValue }
    }

    var sshPassphrase: String? {
        get { passphrase }
        set { passphrase = newValue }
    }
}

// MARK: - Stored SSH Key Entry (reusable keys in Keychain)

struct SSHKeyEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var hasPassphrase: Bool
    var createdAt: Date
    var keyType: SSHKeyType?
    var publicKey: String?

    init(
        id: UUID = UUID(),
        name: String,
        hasPassphrase: Bool = false,
        createdAt: Date = Date(),
        keyType: SSHKeyType? = nil,
        publicKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
        self.keyType = keyType
        self.publicKey = publicKey
    }
}
