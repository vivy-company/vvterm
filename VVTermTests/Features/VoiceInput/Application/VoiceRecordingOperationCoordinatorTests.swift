import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct VoiceRecordingOperationCoordinatorTests {
    private enum Event: Equatable {
        case firstStarted
        case firstReleased
        case firstSucceeded
        case firstFailed
        case secondStarted
        case secondSucceeded
        case secondFailed
    }

    private enum TestError: Error {
        case staleAttempt
    }

    @Test
    func cancellationSuppressesAStaleContinuationResult() async {
        let coordinator = VoiceRecordingOperationCoordinator()
        let gate = CancellationIgnoringGate()
        var events: [Event] = []
        var deliveredText: [String] = []

        let task = coordinator.startRecording(
            operation: { _ in
                events.append(.firstStarted)
                await gate.wait()
                events.append(.firstReleased)
            },
            onStarted: {
                deliveredText.append("stale transcription")
                events.append(.firstSucceeded)
            },
            onFailure: { _ in events.append(.firstFailed) }
        )

        await gate.waitUntilStarted()
        coordinator.cancel()
        gate.open()
        await task.value

        #expect(events == [.firstStarted, .firstReleased])
        #expect(deliveredText.isEmpty)
    }

    @Test
    func replacementOwnsCompletionWhenCancelledAttemptResumesLater() async {
        let coordinator = VoiceRecordingOperationCoordinator()
        let firstGate = CancellationIgnoringGate()
        var events: [Event] = []

        let firstTask = coordinator.startRecording(
            operation: { _ in
                events.append(.firstStarted)
                await firstGate.wait()
                events.append(.firstReleased)
                throw TestError.staleAttempt
            },
            onStarted: { events.append(.firstSucceeded) },
            onFailure: { _ in events.append(.firstFailed) }
        )
        await firstGate.waitUntilStarted()

        let secondTask = coordinator.startRecording(
            operation: { _ in events.append(.secondStarted) },
            onStarted: { events.append(.secondSucceeded) },
            onFailure: { _ in events.append(.secondFailed) }
        )
        await secondTask.value

        firstGate.open()
        await firstTask.value

        #expect(events == [
            .firstStarted,
            .secondStarted,
            .secondSucceeded,
            .firstReleased,
        ])
    }

    @Test
    func processingUsesTheRecordingOperationIdentity() async throws {
        let coordinator = VoiceRecordingOperationCoordinator()
        var recordingOperationID: UUID?
        var processingOperationID: UUID?
        var deliveredText: String?

        let recordingTask = coordinator.startRecording(
            operation: { operationID in
                recordingOperationID = operationID
            },
            onFailure: { _ in }
        )
        await recordingTask.value

        let expectedOperationID = try #require(recordingOperationID)
        #expect(coordinator.phase == .recording(operationID: expectedOperationID))
        #expect(coordinator.isActive)
        #expect(!coordinator.isProcessing)

        let pendingProcessingTask = coordinator.startProcessing(
            operation: { operationID in
                processingOperationID = operationID
                return "transcription"
            },
            onSuccess: { deliveredText = $0 },
            onFailure: { _ in }
        )
        let processingTask = try #require(pendingProcessingTask)
        #expect(coordinator.phase == .processing(operationID: expectedOperationID))

        await processingTask.value

        #expect(processingOperationID == expectedOperationID)
        #expect(deliveredText == "transcription")
        #expect(coordinator.phase == .idle)
    }
}
