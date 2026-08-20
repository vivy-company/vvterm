import AVFoundation
import Testing
@testable import VVTerm

@MainActor
struct AudioCaptureStartupPolicyTests {
    @Test
    func backgroundApplicationRejectsAudioStartup() {
        let rejection = AudioCaptureStartupPolicy.rejection(
            lifecycle: AudioCaptureLifecycleState(
                applicationIsActive: false,
                sceneIsActive: true
            ),
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(rejection == .inactiveLifecycle)
    }

    @Test
    func inactiveSceneRejectsAudioStartup() {
        let rejection = AudioCaptureStartupPolicy.rejection(
            lifecycle: AudioCaptureLifecycleState(
                applicationIsActive: true,
                sceneIsActive: false
            ),
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(rejection == .inactiveLifecycle)
    }

    @Test(arguments: [
        (sampleRate: 0.0, channelCount: 1),
        (sampleRate: 48_000.0, channelCount: 0),
        (sampleRate: Double.nan, channelCount: 1)
    ])
    func unavailableInputFormatRejectsAudioStartup(sampleRate: Double, channelCount: Int) {
        let rejection = AudioCaptureStartupPolicy.rejection(
            lifecycle: AudioCaptureLifecycleState(
                applicationIsActive: true,
                sceneIsActive: true
            ),
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        #expect(rejection == .unavailableInputFormat)
    }

    @Test
    func outputCapacityIsBoundedBeforeIntegerConversion() {
        #expect(
            AudioCaptureStartupPolicy.outputFrameCapacity(
                inputFrameCount: 1_024,
                inputSampleRate: 48_000,
                targetSampleRate: 16_000
            ) == 342
        )
        #expect(
            AudioCaptureStartupPolicy.outputFrameCapacity(
                inputFrameCount: .max,
                inputSampleRate: Double.leastNonzeroMagnitude,
                targetSampleRate: 16_000
            ) == nil
        )
    }

    @Test
    func audioBufferSnapshotReconstructsCapturedFrames() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        source.frameLength = 4
        let sourceSamples = try #require(source.floatChannelData?[0])
        sourceSamples[0] = 0.25
        sourceSamples[1] = -0.5
        sourceSamples[2] = 0.75
        sourceSamples[3] = -1

        let copiedBuffer = try #require(AudioPCMBufferSnapshot(source).makeBuffer())
        let copiedSamples = try #require(copiedBuffer.floatChannelData?[0])

        #expect(copiedBuffer.frameLength == source.frameLength)
        let samples = Array(UnsafeBufferPointer(start: copiedSamples, count: 4))
        #expect(samples == [0.25, -0.5, 0.75, -1])
    }

    @Test
    func partialStartupCleanupReleasesEveryOwnedResourceExactlyOnce() {
        var releases: [String] = []
        let resources = AudioCaptureResources()
        resources.own { releases.append("session") }
        resources.own { releases.append("engine") }
        resources.own { releases.append("tap") }
        let service = AudioCaptureService(captureResources: resources)

        #expect(service.stop().isEmpty)
        #expect(service.stop().isEmpty)
        #expect(releases == ["tap", "engine", "session"])
    }

    @Test
    func cleanupBeforeTapInstallationReleasesOnlyAcquiredResources() {
        var releases: [String] = []
        let resources = AudioCaptureResources()
        resources.own { releases.append("session") }
        resources.own { releases.append("engine") }
        let service = AudioCaptureService(captureResources: resources)

        #expect(service.stop().isEmpty)
        #expect(releases == ["engine", "session"])
    }

    @Test
    func failedEngineStartReleasesRegisteredHardwareResources() throws {
        let inputFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let hardware = FailingAudioCaptureHardware(inputFormat: inputFormat)
        let service = AudioCaptureService(makeHardware: { hardware })

        #expect(throws: FailingAudioCaptureHardware.StartError.self) {
            try service.start(lifecycleState: {
                AudioCaptureLifecycleState(applicationIsActive: true, sceneIsActive: true)
            })
        }
        #expect(hardware.events == [
            .sessionActivated,
            .tapInstalled,
            .enginePrepared,
            .engineStartAttempted,
            .tapRemoved,
            .engineStopped,
            .sessionDeactivated,
        ])
        #expect(service.stop().isEmpty)
        #expect(hardware.events.count == 7)
    }

    @Test
    func failedTapInstallationStopsEngineAndDeactivatesSessionWithoutRemovingTap() throws {
        let inputFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let hardware = TapFailingAudioCaptureHardware(inputFormat: inputFormat)
        let service = AudioCaptureService(makeHardware: { hardware })

        #expect(throws: TapFailingAudioCaptureHardware.InstallError.self) {
            try service.start(lifecycleState: {
                AudioCaptureLifecycleState(applicationIsActive: true, sceneIsActive: true)
            })
        }
        #expect(hardware.events == [
            .sessionActivated,
            .tapInstallAttempted,
            .engineStopped,
            .sessionDeactivated,
        ])
    }

    @Test
    func failedSessionActivationStillDeactivatesPartialSessionState() throws {
        let inputFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let hardware = ActivationFailingAudioCaptureHardware(inputFormat: inputFormat)
        let service = AudioCaptureService(makeHardware: { hardware })

        #expect(throws: ActivationFailingAudioCaptureHardware.ActivationError.self) {
            try service.start(lifecycleState: { activeLifecycle })
        }
        #expect(hardware.events == [.activationAttempted, .sessionDeactivated])
    }

    @Test
    func staleTapCallbackCannotReachAReplacementCapture() throws {
        let inputFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let hardware = EmittingAudioCaptureHardware(inputFormat: inputFormat)
        let service = AudioCaptureService(makeHardware: { hardware })

        try service.start(lifecycleState: { activeLifecycle })
        let staleHandler = try #require(hardware.handler)
        _ = service.stop()

        var deliveredBuffers = 0
        service.bufferHandler = { _ in deliveredBuffers += 1 }
        try service.start(lifecycleState: { activeLifecycle })

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16))
        buffer.frameLength = 16
        staleHandler(buffer)

        #expect(deliveredBuffers == 0)
        #expect(service.recordingDuration == 0)
        _ = service.stop()
    }

    private var activeLifecycle: AudioCaptureLifecycleState {
        AudioCaptureLifecycleState(applicationIsActive: true, sceneIsActive: true)
    }
}

@MainActor
private final class FailingAudioCaptureHardware: AudioCaptureHardware {
    enum StartError: Error {
        case failed
    }

    enum Event: Equatable {
        case sessionActivated
        case sessionDeactivated
        case tapInstalled
        case tapRemoved
        case enginePrepared
        case engineStartAttempted
        case engineStopped
    }

    let inputFormat: AVAudioFormat
    private(set) var events: [Event] = []

    init(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
    }

    func activateAudioSession() throws {
        events.append(.sessionActivated)
    }

    func deactivateAudioSession() {
        events.append(.sessionDeactivated)
    }

    func installTap(
        bufferSize _: AVAudioFrameCount,
        format _: AVAudioFormat,
        handler _: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        events.append(.tapInstalled)
    }

    func removeTap() {
        events.append(.tapRemoved)
    }

    func prepare() {
        events.append(.enginePrepared)
    }

    func start() throws {
        events.append(.engineStartAttempted)
        throw StartError.failed
    }

    func stop() {
        events.append(.engineStopped)
    }
}

@MainActor
private final class TapFailingAudioCaptureHardware: AudioCaptureHardware {
    enum InstallError: Error {
        case failed
    }

    enum Event: Equatable {
        case sessionActivated
        case sessionDeactivated
        case tapInstallAttempted
        case engineStopped
    }

    let inputFormat: AVAudioFormat
    private(set) var events: [Event] = []

    init(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
    }

    func activateAudioSession() throws {
        events.append(.sessionActivated)
    }

    func deactivateAudioSession() {
        events.append(.sessionDeactivated)
    }

    func installTap(
        bufferSize _: AVAudioFrameCount,
        format _: AVAudioFormat,
        handler _: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        events.append(.tapInstallAttempted)
        throw InstallError.failed
    }

    func removeTap() {
        Issue.record("A failed tap installation must not be removed")
    }

    func prepare() {
        Issue.record("The engine must not be prepared after tap installation fails")
    }

    func start() throws {
        Issue.record("The engine must not start after tap installation fails")
    }

    func stop() {
        events.append(.engineStopped)
    }
}

@MainActor
private final class EmittingAudioCaptureHardware: AudioCaptureHardware {
    let inputFormat: AVAudioFormat
    private(set) var handler: (@MainActor (AVAudioPCMBuffer) -> Void)?

    init(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
    }

    func activateAudioSession() throws {}
    func deactivateAudioSession() {}

    func installTap(
        bufferSize _: AVAudioFrameCount,
        format _: AVAudioFormat,
        handler: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        self.handler = handler
    }

    func removeTap() {}
    func prepare() {}
    func start() throws {}
    func stop() {}
}

@MainActor
private final class ActivationFailingAudioCaptureHardware: AudioCaptureHardware {
    enum ActivationError: Error {
        case failed
    }

    enum Event: Equatable {
        case activationAttempted
        case sessionDeactivated
    }

    let inputFormat: AVAudioFormat
    private(set) var events: [Event] = []

    init(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
    }

    func activateAudioSession() throws {
        events.append(.activationAttempted)
        throw ActivationError.failed
    }

    func deactivateAudioSession() {
        events.append(.sessionDeactivated)
    }

    func installTap(
        bufferSize _: AVAudioFrameCount,
        format _: AVAudioFormat,
        handler _: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        Issue.record("Tap installation must not run after session activation fails")
    }

    func removeTap() {}
    func prepare() {}
    func start() throws {}
    func stop() {}
}
