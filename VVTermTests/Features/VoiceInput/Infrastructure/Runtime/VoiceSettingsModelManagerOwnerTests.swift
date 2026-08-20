import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class VoiceSettingsModelManagerOwnerTests: XCTestCase {
    private final class SessionInvalidationRecorder {
        private(set) var count = 0

        func invalidate(_ session: URLSession) {
            count += 1
            session.invalidateAndCancel()
        }
    }

    @MainActor
    private final class CancellationProbe {
        private var recordedValue: Bool?
        private var continuations: [CheckedContinuation<Bool, Never>] = []

        func record(_ value: Bool) {
            recordedValue = value
            let continuations = continuations
            self.continuations.removeAll(keepingCapacity: false)
            continuations.forEach { $0.resume(returning: value) }
        }

        func value() async -> Bool {
            if let recordedValue { return recordedValue }
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    func testModelSelectionUsesPersistedSettingsWithoutDuplicateSelectionState() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(defaults: defaults)
        )
        let recorder = SessionInvalidationRecorder()
        var owner: VoiceSettingsModelManagerOwner? = makeOwner(
            store: store,
            recorder: recorder
        )
        let whisperManager = owner!.whisperManager

        owner!.selectWhisperModel("mlx-community/whisper-medium-mlx")

        XCTAssertEqual(store.settings.whisperModelID, "mlx-community/whisper-medium-mlx")
        XCTAssertEqual(whisperManager.modelId, "mlx-community/whisper-medium-mlx")
        XCTAssertEqual(
            defaults.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId),
            "mlx-community/whisper-medium-mlx"
        )

        owner = nil
        XCTAssertEqual(recorder.count, 2)
    }

    func testTwoModelManagerOwnersAreIsolated() {
        let (firstDefaults, firstSuiteName) = makeDefaults()
        let (secondDefaults, secondSuiteName) = makeDefaults()
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuiteName)
            secondDefaults.removePersistentDomain(forName: secondSuiteName)
        }
        let firstStore = VoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(defaults: firstDefaults)
        )
        let secondStore = VoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(defaults: secondDefaults)
        )
        let firstRecorder = SessionInvalidationRecorder()
        let secondRecorder = SessionInvalidationRecorder()
        var firstOwner: VoiceSettingsModelManagerOwner? = makeOwner(
            store: firstStore,
            recorder: firstRecorder
        )
        var secondOwner: VoiceSettingsModelManagerOwner? = makeOwner(
            store: secondStore,
            recorder: secondRecorder
        )

        firstOwner!.selectWhisperModel("mlx-community/whisper-medium-mlx")

        XCTAssertEqual(firstOwner!.whisperManager.modelId, "mlx-community/whisper-medium-mlx")
        XCTAssertEqual(
            secondOwner!.whisperManager.modelId,
            TranscriptionSettingsDefaults.mlxWhisperModelId
        )

        firstOwner = nil
        secondOwner = nil
        XCTAssertEqual(firstRecorder.count, 2)
        XCTAssertEqual(secondRecorder.count, 2)
    }

    func testOwnerReleaseCancelsActiveStatusWorkAndTerminatesBothSessions() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(defaults: defaults)
        )
        let recorder = SessionInvalidationRecorder()
        let gate = CancellationIgnoringGate()
        let cancellationProbe = CancellationProbe()
        let operations = MLXModelManagerOperations(
            adoptLegacyDownload: { _, _, _ in
                await gate.wait()
                await cancellationProbe.record(Task.isCancelled)
                return .adopted
            }
        )
        var owner: VoiceSettingsModelManagerOwner? = makeOwner(
            store: store,
            recorder: recorder,
            operations: operations
        )
        let manager = owner!.whisperManager

        manager.refreshStatus()
        await gate.waitUntilStarted()
        owner = nil

        XCTAssertEqual(recorder.count, 2)
        gate.open()
        let wasCancelled = await cancellationProbe.value()
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(manager.state, .idle)
    }

    func testSessionTerminationIsIdempotent() {
        let recorder = SessionInvalidationRecorder()
        let modelID = TranscriptionSettingsDefaults.mlxWhisperModelId
        let manager = MLXModelManager(
            kind: .whisper,
            selectedModelID: { modelID },
            storageRoot: makeStorageRoot(),
            sessionLifecycle: sessionLifecycle(recorder: recorder),
            operations: .live
        )

        manager.shutdown()
        manager.shutdown()

        XCTAssertEqual(recorder.count, 1)
    }

    private func makeOwner(
        store: VoiceSettingsStore,
        recorder: SessionInvalidationRecorder,
        operations: MLXModelManagerOperations = .live
    ) -> VoiceSettingsModelManagerOwner {
        let lifecycle = sessionLifecycle(recorder: recorder)
        let storageRoot = makeStorageRoot()
        return VoiceSettingsModelManagerOwner(settingsStore: store) { kind, selectedModelID in
            MLXModelManager(
                kind: kind,
                selectedModelID: selectedModelID,
                storageRoot: storageRoot,
                sessionLifecycle: lifecycle,
                operations: operations
            )
        }
    }

    private func sessionLifecycle(
        recorder: SessionInvalidationRecorder
    ) -> MLXModelSessionLifecycle {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        return MLXModelSessionLifecycle(
            configuration: configuration,
            invalidate: { recorder.invalidate($0) }
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "VoiceSettingsModelManagerOwnerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeStorageRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VoiceSettingsModelManagerOwnerTests.\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
