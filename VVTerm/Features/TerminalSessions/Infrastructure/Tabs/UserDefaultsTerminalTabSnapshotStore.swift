import Foundation

@MainActor
final class UserDefaultsTerminalTabSnapshotStore: TerminalTabSnapshotStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func loadSnapshotData() -> Data? {
        defaults.data(forKey: key)
    }

    func saveSnapshotData(_ data: Data) {
        defaults.set(data, forKey: key)
    }

    func removeSnapshotData() {
        defaults.removeObject(forKey: key)
    }
}
