import Foundation

nonisolated struct WorkspaceSelectionPreferencesCodec: Sendable {
    static let maximumStoredByteCount = 65_536

    func decodeEnvironmentFilters(
        _ stored: String?
    ) -> StoredWorkspaceEnvironmentFilters {
        guard let stored, !stored.isEmpty else { return .absent }
        guard stored.utf8.count <= Self.maximumStoredByteCount,
              let data = stored.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [UUID]].self, from: data) else {
            return .requiresNormalization(.empty)
        }

        let selections = decoded.reduce(into: [UUID: Set<UUID>]()) { result, item in
            guard let workspaceID = UUID(uuidString: item.key) else { return }
            result[workspaceID, default: []].formUnion(item.value)
        }
        let filters = WorkspaceEnvironmentFilters(
            selectionsByWorkspace: selections
        )
        return encodeEnvironmentFilters(filters) == stored
            ? .current(filters)
            : .requiresNormalization(filters)
    }

    func encodeEnvironmentFilters(
        _ filters: WorkspaceEnvironmentFilters
    ) -> String? {
        guard !filters.selectionsByWorkspace.isEmpty else { return "" }

        let encodable = filters.selectionsByWorkspace.reduce(into: [String: [UUID]]()) { result, item in
            result[item.key.uuidString] = item.value.sorted {
                $0.uuidString < $1.uuidString
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(encodable),
              data.count <= Self.maximumStoredByteCount else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    func decodeLegacyEnvironmentFilters(
        _ stored: String?
    ) -> LegacyWorkspaceEnvironmentFilters {
        guard let stored, !stored.isEmpty else {
            return LegacyWorkspaceEnvironmentFilters(
                selectedIDs: [],
                hasStoredValue: false
            )
        }
        guard stored.utf8.count <= Self.maximumStoredByteCount else {
            return LegacyWorkspaceEnvironmentFilters(
                selectedIDs: [],
                hasStoredValue: true
            )
        }
        return LegacyWorkspaceEnvironmentFilters(
            selectedIDs: Set(
                stored
                    .split(separator: ",")
                    .compactMap { UUID(uuidString: String($0)) }
            ),
            hasStoredValue: true
        )
    }
}

@MainActor
final class WorkspaceSelectionUserDefaultsPersistence: WorkspaceSelectionPersisting {
    static let environmentFiltersKey = "environmentFilters.v2"
    static let legacyEnvironmentFiltersKey = "environmentFilters"

    private let defaults: UserDefaults
    private let codec: WorkspaceSelectionPreferencesCodec

    init(
        defaults: UserDefaults,
        codec: WorkspaceSelectionPreferencesCodec = WorkspaceSelectionPreferencesCodec()
    ) {
        self.defaults = defaults
        self.codec = codec
    }

    func loadEnvironmentFilters() -> StoredWorkspaceEnvironmentFilters {
        codec.decodeEnvironmentFilters(
            defaults.string(forKey: Self.environmentFiltersKey)
        )
    }

    func saveEnvironmentFilters(_ filters: WorkspaceEnvironmentFilters) -> Bool {
        guard let encoded = codec.encodeEnvironmentFilters(filters) else {
            return false
        }
        defaults.set(encoded, forKey: Self.environmentFiltersKey)
        return true
    }

    func loadLegacyEnvironmentFilters() -> LegacyWorkspaceEnvironmentFilters {
        codec.decodeLegacyEnvironmentFilters(
            defaults.string(forKey: Self.legacyEnvironmentFiltersKey)
        )
    }

    func clearLegacyEnvironmentFilters() {
        defaults.removeObject(forKey: Self.legacyEnvironmentFiltersKey)
    }
}

@MainActor
enum WorkspaceSelectionLiveComposition {
    static func makeStore(defaults: UserDefaults) -> WorkspaceSelectionStore {
        WorkspaceSelectionStore(
            persistence: WorkspaceSelectionUserDefaultsPersistence(
                defaults: defaults
            )
        )
    }
}
