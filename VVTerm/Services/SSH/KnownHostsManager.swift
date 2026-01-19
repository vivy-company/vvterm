import Foundation
import os.log

final class KnownHostsManager: @unchecked Sendable {
    static let shared = KnownHostsManager()

    struct Entry: Codable {
        let host: String
        let port: Int
        let fingerprint: String
        let keyType: Int
        let addedAt: Date
        var lastSeenAt: Date

        var id: String { "\(host):\(port)" }
    }

    private let storageKey = "vvterm.knownHosts"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "KnownHosts")
    private let lock = NSLock()

    private init() {}

    func entry(for host: String, port: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[hostKey(host: host, port: port)]
    }

    func updateSeen(host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        let key = hostKey(host: host, port: port)
        if var entry = entries[key] {
            entry.lastSeenAt = Date()
            entries[key] = entry
            saveAll(entries)
        }
    }

    func save(entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        entries[entry.id] = entry
        saveAll(entries)
    }

    private func hostKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    private func loadAll() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func saveAll(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            logger.error("Failed to encode known hosts store")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
