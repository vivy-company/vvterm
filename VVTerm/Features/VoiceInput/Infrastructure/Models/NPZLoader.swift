import Foundation
import MLX
import ZIPFoundation

enum NPZLoader {
    nonisolated enum NPZError: Error, Equatable {
        case invalidArchive
        case missingArrays
        case unsupportedEntry
        case memberCountLimitExceeded
        case entrySizeLimitExceeded
        case aggregateSizeLimitExceeded
        case compressionRatioLimitExceeded
        case duplicateArrayName
        case invalidArray
        case insufficientTemporaryStorage
    }

    nonisolated struct ArrayLayout: Equatable {
        let shape: [Int64]
        let elementByteWidth: Int64
        let payloadBytes: Int64
    }

    nonisolated enum ExpansionBudget {
        nonisolated static let maximumMemberCount = 4_096
        nonisolated static let maximumEntryBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
        nonisolated static let maximumAggregateBytes: Int64 = 6 * 1_024 * 1_024 * 1_024
        nonisolated static let maximumCompressionRatio: Int64 = 200
        nonisolated static let requiredFreeSpaceReserve: Int64 = 512 * 1_024 * 1_024

        nonisolated static func validateMemberCount(_ count: Int) throws {
            guard count > 0 else { return }
            guard count <= maximumMemberCount else {
                throw NPZError.memberCountLimitExceeded
            }
        }

        nonisolated static func validateEntry(
            compressedBytes: Int64,
            expandedBytes: Int64
        ) throws {
            guard compressedBytes > 0, expandedBytes > 0 else {
                throw NPZError.invalidArray
            }
            guard expandedBytes <= maximumEntryBytes else {
                throw NPZError.entrySizeLimitExceeded
            }
            let (maximumExpandedBytes, overflow) = compressedBytes.multipliedReportingOverflow(
                by: maximumCompressionRatio
            )
            guard !overflow, expandedBytes <= maximumExpandedBytes else {
                throw NPZError.compressionRatioLimitExceeded
            }
        }

        nonisolated static func addingExpandedBytes(_ bytes: Int64, to total: Int64) throws -> Int64 {
            let (newTotal, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow, newTotal <= maximumAggregateBytes else {
                throw NPZError.aggregateSizeLimitExceeded
            }
            return newTotal
        }

        nonisolated static func validateTemporaryStorage(
            largestEntryBytes: Int64,
            availableCapacity: Int64
        ) throws {
            let (requiredCapacity, overflow) = largestEntryBytes.addingReportingOverflow(
                requiredFreeSpaceReserve
            )
            guard !overflow, availableCapacity >= requiredCapacity else {
                throw NPZError.insufficientTemporaryStorage
            }
        }
    }

    nonisolated private struct ArchiveMember {
        let entry: Entry
        let key: String
    }

    nonisolated private static let maximumHeaderBytes = 64 * 1_024
    nonisolated private static let maximumDimensionCount = 8
    nonisolated private static let maximumDimension: Int64 = 1_000_000

    nonisolated static func loadArrays(from url: URL) throws -> [String: MLXArray] {
        try loadValidatedEntries(from: url) { entryURL in
            try loadArray(url: entryURL)
        }
    }

    nonisolated static func loadValidatedEntries<Value>(
        from url: URL,
        loader: (URL) throws -> Value
    ) throws -> [String: Value] {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw NPZError.invalidArchive
        }

        let members = try validatedMembers(in: archive)
        let largestEntryBytes = members.map { Int64($0.entry.uncompressedSize) }.max() ?? 0
        try ExpansionBudget.validateTemporaryStorage(
            largestEntryBytes: largestEntryBytes,
            availableCapacity: try availableTemporaryStorageCapacity()
        )

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        var arrays: [String: Value] = [:]
        arrays.reserveCapacity(members.count)

        for (index, member) in members.enumerated() {
            let tempURL = tempDirectory.appendingPathComponent("\(index).npy", isDirectory: false)
            let actualBytes = try extract(member.entry, from: archive, to: tempURL)
            defer { try? fileManager.removeItem(at: tempURL) }

            guard actualBytes == Int64(member.entry.uncompressedSize) else {
                throw NPZError.invalidArray
            }
            _ = try validateArray(at: tempURL, totalBytes: actualBytes)
            arrays[member.key] = try loader(tempURL)
        }

        guard !arrays.isEmpty else {
            throw NPZError.missingArrays
        }
        return arrays
    }

    nonisolated static func validateArrayHeader(
        _ data: Data,
        totalBytes: Int64
    ) throws -> ArrayLayout {
        guard totalBytes > 0,
              data.count >= 10,
              Array(data.prefix(6)) == [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] else {
            throw NPZError.invalidArray
        }

        let majorVersion = data[data.startIndex + 6]
        let preambleBytes: Int
        let headerBytes: Int
        switch majorVersion {
        case 1:
            preambleBytes = 10
            headerBytes = littleEndianInteger(in: data, offset: 8, byteCount: 2)
        case 2, 3:
            guard data.count >= 12 else { throw NPZError.invalidArray }
            preambleBytes = 12
            headerBytes = littleEndianInteger(in: data, offset: 8, byteCount: 4)
        default:
            throw NPZError.invalidArray
        }

        guard headerBytes > 0, headerBytes <= maximumHeaderBytes else {
            throw NPZError.invalidArray
        }
        let (headerEnd, headerOverflow) = preambleBytes.addingReportingOverflow(headerBytes)
        guard !headerOverflow, headerEnd <= data.count else {
            throw NPZError.invalidArray
        }

        let headerData = data.subdata(in: preambleBytes..<headerEnd)
        let encoding: String.Encoding = majorVersion == 3 ? .utf8 : .isoLatin1
        guard let header = String(data: headerData, encoding: encoding),
              let descriptor = quotedValue(for: "descr", in: header),
              let shapeText = tupleValue(for: "shape", in: header) else {
            throw NPZError.invalidArray
        }

        let shape = try parseShape(shapeText)
        let elementByteWidth = try parseElementByteWidth(descriptor)
        var elementCount: Int64 = 1
        for dimension in shape {
            let (newCount, overflow) = elementCount.multipliedReportingOverflow(by: dimension)
            guard !overflow else { throw NPZError.invalidArray }
            elementCount = newCount
        }
        let (payloadBytes, payloadOverflow) = elementCount.multipliedReportingOverflow(
            by: elementByteWidth
        )
        guard !payloadOverflow, payloadBytes <= ExpansionBudget.maximumEntryBytes else {
            throw NPZError.entrySizeLimitExceeded
        }
        let (expectedTotalBytes, totalOverflow) = Int64(headerEnd).addingReportingOverflow(payloadBytes)
        guard !totalOverflow, expectedTotalBytes == totalBytes else {
            throw NPZError.invalidArray
        }

        return ArrayLayout(
            shape: shape,
            elementByteWidth: elementByteWidth,
            payloadBytes: payloadBytes
        )
    }

    private nonisolated static func validatedMembers(in archive: Archive) throws -> [ArchiveMember] {
        var members: [ArchiveMember] = []
        var keys: Set<String> = []
        var aggregateBytes: Int64 = 0

        for entry in archive {
            guard entry.type == .file, entry.path.lowercased().hasSuffix(".npy") else {
                throw NPZError.unsupportedEntry
            }
            try ExpansionBudget.validateMemberCount(members.count + 1)

            let compressedBytes = Int64(entry.compressedSize)
            let expandedBytes = Int64(entry.uncompressedSize)
            try ExpansionBudget.validateEntry(
                compressedBytes: compressedBytes,
                expandedBytes: expandedBytes
            )
            aggregateBytes = try ExpansionBudget.addingExpandedBytes(expandedBytes, to: aggregateBytes)

            let filename = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            let key = String(filename.dropLast(4))
            guard !key.isEmpty, keys.insert(key).inserted else {
                throw NPZError.duplicateArrayName
            }
            members.append(ArchiveMember(entry: entry, key: key))
        }

        guard !members.isEmpty else { throw NPZError.missingArrays }
        return members
    }

    private nonisolated static func extract(
        _ entry: Entry,
        from archive: Archive,
        to url: URL
    ) throws -> Int64 {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        var extractedBytes: Int64 = 0
        do {
            _ = try archive.extract(entry) { chunk in
                let (newCount, overflow) = extractedBytes.addingReportingOverflow(Int64(chunk.count))
                guard !overflow,
                      newCount <= Int64(entry.uncompressedSize),
                      newCount <= ExpansionBudget.maximumEntryBytes else {
                    throw NPZError.entrySizeLimitExceeded
                }
                try handle.write(contentsOf: chunk)
                extractedBytes = newCount
            }
            try handle.close()
            return extractedBytes
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private nonisolated static func validateArray(at url: URL, totalBytes: Int64) throws -> ArrayLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytesToRead = maximumHeaderBytes + 12
        let prefix = try handle.read(upToCount: bytesToRead) ?? Data()
        return try validateArrayHeader(prefix, totalBytes: totalBytes)
    }

    private nonisolated static func availableTemporaryStorageCapacity() throws -> Int64 {
        let values = try FileManager.default.temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let capacity = values.volumeAvailableCapacityForImportantUsage,
              capacity >= 0 else {
            throw NPZError.insufficientTemporaryStorage
        }
        return capacity
    }

    private nonisolated static func littleEndianInteger(
        in data: Data,
        offset: Int,
        byteCount: Int
    ) -> Int {
        guard offset >= 0, byteCount > 0, offset + byteCount <= data.count else { return 0 }
        var value = 0
        for index in 0..<byteCount {
            value |= Int(data[data.startIndex + offset + index]) << (index * 8)
        }
        return value
    }

    private nonisolated static func quotedValue(for field: String, in header: String) -> String? {
        guard let fieldRange = fieldRange(for: field, in: header),
              let colon = header[fieldRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }
        let valueStart = header.index(after: colon)
        guard let quoteIndex = header[valueStart...].firstIndex(where: { $0 == "'" || $0 == "\"" }) else {
            return nil
        }
        let quote = header[quoteIndex]
        let contentStart = header.index(after: quoteIndex)
        guard let contentEnd = header[contentStart...].firstIndex(of: quote) else { return nil }
        return String(header[contentStart..<contentEnd])
    }

    private nonisolated static func tupleValue(for field: String, in header: String) -> String? {
        guard let fieldRange = fieldRange(for: field, in: header),
              let colon = header[fieldRange.upperBound...].firstIndex(of: ":"),
              let open = header[colon...].firstIndex(of: "("),
              let close = header[open...].firstIndex(of: ")") else {
            return nil
        }
        return String(header[header.index(after: open)..<close])
    }

    private nonisolated static func fieldRange(for field: String, in header: String) -> Range<String.Index>? {
        header.range(of: "'\(field)'") ?? header.range(of: "\"\(field)\"")
    }

    private nonisolated static func parseShape(_ value: String) throws -> [Int64] {
        let components = value.split(separator: ",", omittingEmptySubsequences: true)
        guard components.count <= maximumDimensionCount else { throw NPZError.invalidArray }

        return try components.map { component in
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let dimension = Int64(trimmed),
                  dimension > 0,
                  dimension <= maximumDimension else {
                throw NPZError.invalidArray
            }
            return dimension
        }
    }

    private nonisolated static func parseElementByteWidth(_ descriptor: String) throws -> Int64 {
        guard !descriptor.isEmpty else { throw NPZError.invalidArray }
        var value = descriptor[...]
        var byteOrder: Character?
        if let first = value.first, "<>=|".contains(first) {
            byteOrder = first
            value = value.dropFirst()
        }
        guard byteOrder != ">", let kind = value.first else {
            throw NPZError.invalidArray
        }
        value = value.dropFirst()

        let width: Int64
        if kind == "?" {
            width = 1
            guard value.isEmpty else { throw NPZError.invalidArray }
        } else {
            guard "biufc".contains(kind),
                  let parsedWidth = Int64(value),
                  parsedWidth > 0,
                  parsedWidth <= 16 else {
                throw NPZError.invalidArray
            }
            width = parsedWidth
        }
        if byteOrder == "|", width != 1 {
            throw NPZError.invalidArray
        }
        return width
    }
}

extension NPZLoader.NPZError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return String(localized: "The model archive is invalid.")
        case .missingArrays:
            return String(localized: "The model archive has no arrays.")
        case .unsupportedEntry:
            return String(localized: "The model archive contains an unsupported entry.")
        case .memberCountLimitExceeded:
            return String(localized: "The model archive contains too many arrays.")
        case .entrySizeLimitExceeded:
            return String(localized: "A model array is too large.")
        case .aggregateSizeLimitExceeded:
            return String(localized: "The expanded model archive is too large.")
        case .compressionRatioLimitExceeded:
            return String(localized: "The model archive compression ratio is unsafe.")
        case .duplicateArrayName:
            return String(localized: "The model archive contains duplicate array names.")
        case .invalidArray:
            return String(localized: "The model archive contains an invalid array.")
        case .insufficientTemporaryStorage:
            return String(localized: "There is not enough free storage to load this model.")
        }
    }
}
