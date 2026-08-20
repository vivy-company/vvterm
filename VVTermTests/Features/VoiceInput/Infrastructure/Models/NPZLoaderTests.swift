import Foundation
import XCTest
import ZIPFoundation
@testable import VVTerm

final class NPZLoaderTests: XCTestCase {
    func testExtractsAndValidatesAValidArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("model.npz")
        let archive = try XCTUnwrap(Archive(url: archiveURL, accessMode: .create))
        let arrayData = makeArray(descriptor: "<f4", shape: [2], payloadBytes: 8)
        try addEntry(named: "weight.npy", data: arrayData, to: archive)

        let arrays = try NPZLoader.loadValidatedEntries(from: archiveURL) { entryURL in
            try Data(contentsOf: entryURL)
        }

        XCTAssertEqual(Set(arrays.keys), ["weight"])
        XCTAssertEqual(arrays["weight"], arrayData)
    }

    func testValidHeaderReturnsBoundedArrayLayout() throws {
        let data = makeArray(descriptor: "<f4", shape: [2, 3], payloadBytes: 24)

        let layout = try NPZLoader.validateArrayHeader(data, totalBytes: Int64(data.count))

        XCTAssertEqual(layout.shape, [2, 3])
        XCTAssertEqual(layout.elementByteWidth, 4)
        XCTAssertEqual(layout.payloadBytes, 24)
    }

    func testHeaderRejectsObjectAndBigEndianArrays() {
        let object = makeArray(descriptor: "|O8", shape: [1], payloadBytes: 8)
        let bigEndian = makeArray(descriptor: ">f4", shape: [1], payloadBytes: 4)

        assertError(.invalidArray) {
            _ = try NPZLoader.validateArrayHeader(object, totalBytes: Int64(object.count))
        }
        assertError(.invalidArray) {
            _ = try NPZLoader.validateArrayHeader(bigEndian, totalBytes: Int64(bigEndian.count))
        }
    }

    func testHeaderRejectsExcessiveDimensionsAndMismatchedPayload() {
        let tooManyDimensions = makeArray(
            descriptor: "<f4",
            shape: Array(repeating: 1, count: 9),
            payloadBytes: 4
        )
        let mismatchedPayload = makeArray(descriptor: "<f4", shape: [2], payloadBytes: 4)

        assertError(.invalidArray) {
            _ = try NPZLoader.validateArrayHeader(
                tooManyDimensions,
                totalBytes: Int64(tooManyDimensions.count)
            )
        }
        assertError(.invalidArray) {
            _ = try NPZLoader.validateArrayHeader(
                mismatchedPayload,
                totalBytes: Int64(mismatchedPayload.count)
            )
        }
    }

    func testHeaderRejectsDimensionProductOverflow() {
        let data = makeArray(
            descriptor: "<f4",
            shape: Array(repeating: 1_000_000, count: 8),
            payloadBytes: 4
        )

        assertError(.invalidArray) {
            _ = try NPZLoader.validateArrayHeader(data, totalBytes: Int64(data.count))
        }
    }

    func testExpansionBudgetRejectsCountEntryAggregateRatioAndStorage() throws {
        assertError(.memberCountLimitExceeded) {
            try NPZLoader.ExpansionBudget.validateMemberCount(
                NPZLoader.ExpansionBudget.maximumMemberCount + 1
            )
        }
        assertError(.entrySizeLimitExceeded) {
            try NPZLoader.ExpansionBudget.validateEntry(
                compressedBytes: 1,
                expandedBytes: NPZLoader.ExpansionBudget.maximumEntryBytes + 1
            )
        }
        assertError(.compressionRatioLimitExceeded) {
            try NPZLoader.ExpansionBudget.validateEntry(
                compressedBytes: 1,
                expandedBytes: NPZLoader.ExpansionBudget.maximumCompressionRatio + 1
            )
        }
        assertError(.aggregateSizeLimitExceeded) {
            _ = try NPZLoader.ExpansionBudget.addingExpandedBytes(
                1,
                to: NPZLoader.ExpansionBudget.maximumAggregateBytes
            )
        }
        assertError(.insufficientTemporaryStorage) {
            try NPZLoader.ExpansionBudget.validateTemporaryStorage(
                largestEntryBytes: 1,
                availableCapacity: NPZLoader.ExpansionBudget.requiredFreeSpaceReserve
            )
        }
    }

    private func makeArray(
        descriptor: String,
        shape: [Int],
        payloadBytes: Int
    ) -> Data {
        let shapeValue: String
        if shape.isEmpty {
            shapeValue = ""
        } else if shape.count == 1 {
            shapeValue = "\(shape[0]),"
        } else {
            shapeValue = shape.map(String.init).joined(separator: ", ")
        }
        let dictionary = "{'descr': '\(descriptor)', 'fortran_order': False, 'shape': (\(shapeValue)), }"
        let preambleBytes = 10
        let newlineBytes = 1
        let paddingBytes = (16 - ((preambleBytes + dictionary.utf8.count + newlineBytes) % 16)) % 16
        let header = dictionary + String(repeating: " ", count: paddingBytes) + "\n"
        let headerLength = UInt16(header.utf8.count)

        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x01, 0x00])
        data.append(UInt8(headerLength & 0x00FF))
        data.append(UInt8((headerLength >> 8) & 0x00FF))
        data.append(contentsOf: header.utf8)
        data.append(Data(repeating: 0, count: payloadBytes))
        return data
    }

    private func addEntry(named name: String, data: Data, to archive: Archive) throws {
        try archive.addEntry(
            with: name,
            type: .file,
            uncompressedSize: UInt32(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let end = min(position + size, data.count)
            guard position < end else { return Data() }
            return data.subdata(in: position..<end)
        }
    }

    private func assertError(
        _ expected: NPZLoader.NPZError,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? NPZLoader.NPZError, expected)
        }
    }
}
