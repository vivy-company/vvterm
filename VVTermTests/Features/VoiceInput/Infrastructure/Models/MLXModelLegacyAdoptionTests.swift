import CryptoKit
import XCTest
@testable import VVTerm

final class MLXModelLegacyAdoptionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVTermLegacyModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testDiscoversAndAdoptsValidLegacyDirectory() throws {
        let modelID = "test/model"
        let manifest = try makeLegacyDownload(modelID: modelID)
        let source = try XCTUnwrap(
            MLXModelStorageLayout.legacyDirectories(
                root: root,
                kind: .whisper,
                modelID: modelID
            ).first
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let result = MLXModelLegacyAdopter.adoptIfPossible(
            root: root,
            kind: .whisper,
            modelID: modelID,
            trustedManifest: manifest
        )

        let destination = MLXModelStorageLayout.currentDirectory(
            root: root,
            kind: .whisper,
            modelID: modelID
        )
        XCTAssertEqual(result, .adopted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let marker = destination.appendingPathComponent(MLXModelDownloadManifest.markerFilename)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), manifest.revision)
    }

    func testEverySavedLegacyMediumIDMigratesToPinnedMediumModel() {
        let target = "mlx-community/whisper-medium-mlx"
        for legacyID in [
            "mlx-community/whisper-medium",
            "mlx-community/whisper-medium-mlx-8bit",
            "mlx-community/whisper-medium-mlx-q4",
            "mlx-community/whisper-medium-mlx-fp32"
        ] {
            XCTAssertEqual(
                MLXModelLegacyMigration.resolveModelID(legacyID, kind: .whisper),
                .migrated(from: legacyID, to: target)
            )
        }
        XCTAssertNotNil(MLXModelCatalog.downloadManifest(for: target, kind: .whisper))
    }

    func testFailedAdoptionPreservesLegacyDirectory() throws {
        let modelID = "test/model"
        var manifest = try makeLegacyDownload(modelID: modelID)
        let invalidFile = MLXModelDownloadFile(
            sourceURL: manifest.files[1].sourceURL,
            localFilename: manifest.files[1].localFilename,
            expectedBytes: manifest.files[1].expectedBytes,
            sha256: String(repeating: "0", count: 64)
        )
        manifest = MLXModelDownloadManifest(
            modelID: manifest.modelID,
            revision: manifest.revision,
            files: [manifest.files[0], invalidFile]
        )
        let source = try XCTUnwrap(
            MLXModelStorageLayout.legacyDirectories(
                root: root,
                kind: .whisper,
                modelID: modelID
            ).first
        )

        let result = MLXModelLegacyAdopter.adoptIfPossible(
            root: root,
            kind: .whisper,
            modelID: modelID,
            trustedManifest: manifest
        )

        XCTAssertEqual(result, .updateRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: MLXModelStorageLayout.currentDirectory(
                    root: root,
                    kind: .whisper,
                    modelID: modelID
                ).path
            )
        )
    }

    func testRemoveAndReinstallUsesAtomicInstaller() throws {
        let final = root.appendingPathComponent("final", isDirectory: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: final.appendingPathComponent("weights"))

        var staging = root.appendingPathComponent("staging-1", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staging.appendingPathComponent("weights"))
        try MLXModelStorageInstaller.install(stagingDirectory: staging, finalDirectory: final)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("weights")), Data("new".utf8))

        try FileManager.default.removeItem(at: final)
        staging = root.appendingPathComponent("staging-2", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: staging.appendingPathComponent("weights"))
        try MLXModelStorageInstaller.install(stagingDirectory: staging, finalDirectory: final)

        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("weights")), Data("newer".utf8))
    }

    private func makeLegacyDownload(modelID: String) throws -> MLXModelDownloadManifest {
        let source = try XCTUnwrap(
            MLXModelStorageLayout.legacyDirectories(
                root: root,
                kind: .whisper,
                modelID: modelID
            ).first
        )
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let config = Data("config".utf8)
        let weights = Data("weights".utf8)
        try config.write(to: source.appendingPathComponent("config.json"))
        try weights.write(to: source.appendingPathComponent("weights.npz"))

        return MLXModelDownloadManifest(
            modelID: modelID,
            revision: String(repeating: "a", count: 40),
            files: [
                file(name: "config.json", data: config),
                file(name: "weights.npz", data: weights)
            ]
        )
    }

    private func file(name: String, data: Data) -> MLXModelDownloadFile {
        MLXModelDownloadFile(
            sourceURL: "https://example.invalid/\(name)",
            localFilename: name,
            expectedBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}
