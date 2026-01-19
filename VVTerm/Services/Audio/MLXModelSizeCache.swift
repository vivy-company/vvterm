import Foundation

actor MLXModelSizeCache {
    static let shared = MLXModelSizeCache()

    private var cache: [String: Int64] = [:]
    private var failed: Set<String> = []

    private struct HFModelSizeInfo: Decodable {
        let usedStorage: Int64?
    }

    func size(for modelId: String) async -> Int64? {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let cached = cache[normalized] { return cached }
        if failed.contains(normalized) { return nil }

        do {
            let url = URL(string: "https://huggingface.co/api/models/\(normalized)")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(HFModelSizeInfo.self, from: data)
            if let size = info.usedStorage {
                cache[normalized] = size
                return size
            }
            failed.insert(normalized)
            return nil
        } catch {
            failed.insert(normalized)
            return nil
        }
    }
}
