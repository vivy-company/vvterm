import Foundation
import MLX
import ZIPFoundation

enum NPZLoader {
    enum NPZError: Error {
        case invalidArchive
        case missingArrays
    }

    nonisolated static func loadArrays(from url: URL) throws -> [String: MLXArray] {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw NPZError.invalidArchive
        }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        var arrays: [String: MLXArray] = [:]

        for entry in archive {
            guard entry.path.lowercased().hasSuffix(".npy") else { continue }

            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }

            let filename = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            let key = filename.replacingOccurrences(of: ".npy", with: "")
            let tempURL = tempDir.appendingPathComponent(filename)
            try data.write(to: tempURL, options: [.atomic])

            let array = try loadArray(url: tempURL)
            arrays[key] = array
        }

        if arrays.isEmpty {
            throw NPZError.missingArrays
        }

        return arrays
    }
}
