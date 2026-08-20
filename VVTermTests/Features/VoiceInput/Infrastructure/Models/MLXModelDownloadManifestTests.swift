import Foundation
import XCTest
@testable import VVTerm

final class MLXModelDownloadManifestTests: XCTestCase {
    func testEveryCatalogModelHasAPinnedManifest() throws {
        for option in MLXModelCatalog.allOptions {
            let manifest = try XCTUnwrap(
                MLXModelCatalog.downloadManifest(for: option.id, kind: option.kind)
            )
            XCTAssertEqual(manifest.modelID, option.id)
            XCTAssertEqual(manifest.revision.count, 40)
            XCTAssertNotNil(manifest.expectedBytes)

            for file in manifest.files {
                XCTAssertFalse(file.sourceURL.contains("/main/"))
                XCTAssertEqual(file.sha256.count, 64)
                XCTAssertGreaterThan(file.expectedBytes, 0)
            }
        }
    }

    func testCatalogManifestsFitDownloadBudgets() throws {
        for option in MLXModelCatalog.allOptions {
            let manifest = try XCTUnwrap(
                MLXModelCatalog.downloadManifest(for: option.id, kind: option.kind)
            )
            let expectedBytes = try MLXModelDownloadBudget.validate(
                manifest: manifest,
                currentRepositoryBytes: 0,
                availableCapacity: MLXModelDownloadBudget.maximumDownloadBytes
                    + MLXModelDownloadBudget.requiredFreeSpaceReserve
            )
            XCTAssertEqual(expectedBytes, manifest.expectedBytes)
        }
    }

    func testBudgetRejectsFileCountSizeAggregateRepositoryAndFreeSpace() throws {
        let valid = manifest(files: [file(bytes: 100)])

        XCTAssertThrowsError(
            try MLXModelDownloadBudget.validate(
                manifest: manifest(
                    files: Array(
                        repeating: file(bytes: 1),
                        count: MLXModelDownloadBudget.maximumFileCount + 1
                    ).enumerated().map { index, file in
                        MLXModelDownloadFile(
                            sourceURL: file.sourceURL,
                            localFilename: "file-\(index)",
                            expectedBytes: file.expectedBytes,
                            sha256: file.sha256
                        )
                    }
                ),
                currentRepositoryBytes: 0,
                availableCapacity: Int64.max
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelDownloadError, .fileCountLimitExceeded)
        }

        XCTAssertThrowsError(
            try MLXModelDownloadBudget.validate(
                manifest: manifest(files: [file(bytes: MLXModelDownloadBudget.maximumFileBytes + 1)]),
                currentRepositoryBytes: 0,
                availableCapacity: Int64.max
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelDownloadError, .fileSizeLimitExceeded)
        }

        let halfAggregate = MLXModelDownloadBudget.maximumDownloadBytes / 2 + 1
        XCTAssertThrowsError(
            try MLXModelDownloadBudget.validate(
                manifest: manifest(files: [
                    file(bytes: halfAggregate),
                    MLXModelDownloadFile(
                        sourceURL: "https://example.com/file-2",
                        localFilename: "file-2",
                        expectedBytes: halfAggregate,
                        sha256: String(repeating: "b", count: 64)
                    )
                ]),
                currentRepositoryBytes: 0,
                availableCapacity: Int64.max
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelDownloadError, .aggregateSizeLimitExceeded)
        }

        XCTAssertThrowsError(
            try MLXModelDownloadBudget.validate(
                manifest: valid,
                currentRepositoryBytes: MLXModelDownloadBudget.maximumRepositoryBytes,
                availableCapacity: Int64.max
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelDownloadError, .repositoryQuotaExceeded)
        }

        XCTAssertThrowsError(
            try MLXModelDownloadBudget.validate(
                manifest: valid,
                currentRepositoryBytes: 0,
                availableCapacity: MLXModelDownloadBudget.requiredFreeSpaceReserve
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelDownloadError, .insufficientFreeSpace)
        }
    }

    func testFileVerifierChecksSizeAndSHA256() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("payload")
        try Data("hello".utf8).write(to: fileURL)

        XCTAssertNoThrow(
            try MLXModelFileVerifier.verify(
                fileURL,
                expectedBytes: 5,
                sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        )
        XCTAssertThrowsError(
            try MLXModelFileVerifier.verify(
                fileURL,
                expectedBytes: 4,
                sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelDownloadError, .unexpectedResponseSize)
        }
        XCTAssertThrowsError(
            try MLXModelFileVerifier.verify(
                fileURL,
                expectedBytes: 5,
                sha256: String(repeating: "0", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelDownloadError, .checksumMismatch)
        }
    }

    func testModelDirectoryCannotEscapeModelsRoot() {
        let root = MLXModelManager.modelsRoot
            .appendingPathComponent(MLXModelKind.whisper.folderName, isDirectory: true)
            .standardizedFileURL
        let directory = MLXModelManager.modelDirectory(
            for: .whisper,
            modelId: ".."
        ).standardizedFileURL

        XCTAssertTrue(directory.path.hasPrefix(root.path + "/"))
        XCTAssertNotEqual(directory.lastPathComponent, ".")
        XCTAssertNotEqual(directory.lastPathComponent, "..")
    }

    private func manifest(files: [MLXModelDownloadFile]) -> MLXModelDownloadManifest {
        MLXModelDownloadManifest(
            modelID: "test/model",
            revision: String(repeating: "a", count: 40),
            files: files
        )
    }

    private func file(bytes: Int64) -> MLXModelDownloadFile {
        MLXModelDownloadFile(
            sourceURL: "https://example.com/file",
            localFilename: "file",
            expectedBytes: bytes,
            sha256: String(repeating: "a", count: 64)
        )
    }
}
