import Foundation
import AVFoundation
import Testing
@testable import VVTerm

struct SpeechRecognitionOperationStateTests {
    @Test
    func finishingOperationContinuesAcceptingItsFinalResult() {
        let generation = UUID()
        let state = SpeechRecognitionOperationState.finishing(generation)

        #expect(state.acceptsResult(for: generation))
        #expect(state.generation == generation)
    }

    @Test
    func replacementRejectsThePreviousOperationsResult() {
        let previousGeneration = UUID()
        let replacementGeneration = UUID()
        let state = SpeechRecognitionOperationState.running(replacementGeneration)

        #expect(!state.acceptsResult(for: previousGeneration))
        #expect(state.acceptsResult(for: replacementGeneration))
    }

    @Test
    func finalResultSignalCompletesTheBoundedWait() async {
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        completion.continuation.yield()
        completion.continuation.finish()

        let clock = ContinuousClock()
        let startedAt = clock.now
        await SpeechRecognitionService.waitForRecognitionCompletion(
            completion.stream,
            timeout: .seconds(2)
        )

        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }

    @Test
    func resultStateResumesExactlyOnce() async throws {
        let state = SpeechRecognitionResultState()

        #expect(state.resolve(.success("first")))
        #expect(!state.resolve(.success("second")))
        #expect(try await state.value() == "first")
    }

    @Test
    func cancellationBeforeWaitStillResumesTheWaiter() async {
        let state = SpeechRecognitionResultState()

        #expect(state.resolve(.failure(CancellationError())))
        await #expect(throws: CancellationError.self) {
            try await state.value()
        }
    }

    @Test
    func concurrentResultsHaveExactlyOneWinner() async throws {
        let state = SpeechRecognitionResultState()

        let winnerCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for value in 0..<100 {
                group.addTask {
                    state.resolve(.success(String(value)))
                }
            }

            var count = 0
            for await didResolve in group where didResolve {
                count += 1
            }
            return count
        }

        #expect(winnerCount == 1)
        #expect(Int(try await state.value()) != nil)
    }

    @Test
    func audioInputValidationRejectsEmptyOverflowingAndInvalidShapes() {
        let maximumFrameCount = Int(AVAudioFrameCount.max)

        #expect(SpeechRecognitionService.acceptsAudioInput(sampleCount: 1, sampleRate: 16_000))
        #expect(SpeechRecognitionService.acceptsAudioInput(sampleCount: maximumFrameCount, sampleRate: 16_000))
        #expect(!SpeechRecognitionService.acceptsAudioInput(sampleCount: 0, sampleRate: 16_000))
        #expect(!SpeechRecognitionService.acceptsAudioInput(sampleCount: maximumFrameCount + 1, sampleRate: 16_000))
        #expect(!SpeechRecognitionService.acceptsAudioInput(sampleCount: 1, sampleRate: 0))
        #expect(!SpeechRecognitionService.acceptsAudioInput(sampleCount: 1, sampleRate: .infinity))
    }
}
