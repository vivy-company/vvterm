import Foundation
import Combine
import AVFoundation
import os.log

struct AudioPCMBufferSnapshot {
    let format: AVAudioFormat
    let frameLength: AVAudioFrameCount
    let buffers: [Data]

    init(_ buffer: AVAudioPCMBuffer) {
        format = buffer.format
        frameLength = buffer.frameLength
        buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).map { audioBuffer in
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
                return Data()
            }
            return Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
        }
    }

    func makeBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        buffer.frameLength = frameLength
        let destinations = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destinations.count == buffers.count else { return nil }

        for index in buffers.indices {
            let data = buffers[index]
            guard data.count <= Int(destinations[index].mDataByteSize) else { return nil }
            if !data.isEmpty {
                guard let destination = destinations[index].mData else { return nil }
                data.copyBytes(
                    to: destination.assumingMemoryBound(to: UInt8.self),
                    count: data.count
                )
            }
            destinations[index].mDataByteSize = UInt32(data.count)
        }
        return buffer
    }
}

/// Bridges Xcode 26.5's `@Sendable` converter callback without weakening the
/// complete-concurrency checks for the rest of AVFoundation.
///
/// The buffer has unique ownership here, is only read by the converter, and
/// the callback cannot escape the synchronous `convert` call. Remove this
/// bridge after Xcode Cloud uses the SDK 27 AVFAudio overlay, which marks the
/// callback as non-Sendable.
private nonisolated struct SynchronousAudioConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

@MainActor
protocol AudioCaptureHardware: AnyObject {
    var inputFormat: AVAudioFormat { get }

    func activateAudioSession() throws
    func deactivateAudioSession()
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

@MainActor
final class AudioCaptureResources {
    private var cleanupActions: [() -> Void] = []

    func own(cleanup: @escaping () -> Void) {
        cleanupActions.append(cleanup)
    }

    func releaseAll() {
        let actions = cleanupActions
        cleanupActions.removeAll(keepingCapacity: true)
        for action in actions.reversed() {
            action()
        }
    }
}

@MainActor
private final class SystemAudioCaptureHardware: AudioCaptureHardware {
    private let logger = Logger.audio
    private let engine = AVAudioEngine()

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: [])
        let route = session.currentRoute.inputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        logger.info(
            "Audio session active [route: \(route, privacy: .public), sampleRate: \(session.sampleRate), inputChannels: \(session.inputNumberOfChannels)]"
        )
        #endif
    }

    func deactivateAudioSession() {
        #if os(iOS)
        // Release the session so system services (e.g. keyboard dictation) regain the mic.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        let inputNode = engine.inputNode
        logger.info(
            "Installing audio tap [sampleRate: \(format.sampleRate), channels: \(format.channelCount), bufferSize: \(bufferSize)]"
        )
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *) {
            try inputNode.installAudioTap(
                onBus: 0,
                bufferSize: bufferSize,
                format: format
            ) { buffer, _ in
                Task { @MainActor in
                    handler(AVAudioPCMBuffer(copying: buffer))
                }
            }
            return
        }
        #endif
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            let snapshot = AudioPCMBufferSnapshot(buffer)
            Task { @MainActor in
                guard let copiedBuffer = snapshot.makeBuffer() else { return }
                handler(copiedBuffer)
            }
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
        logger.info("Audio engine started")
    }

    func stop() {
        engine.stop()
    }
}

@MainActor
final class AudioCaptureService: ObservableObject {
    private enum CaptureState {
        case idle
        case starting(UUID)
        case recording(UUID)

        var generation: UUID? {
            switch self {
            case .idle:
                return nil
            case .starting(let generation), .recording(let generation):
                return generation
            }
        }

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0

    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?

    private let targetSampleRate: Double = 16_000
    private let logger = Logger.audio
    private let captureResources: AudioCaptureResources
    private let makeHardware: () -> any AudioCaptureHardware
    private var converter: AVAudioConverter?
    private var recordedSamples: [Float] = []
    private var captureState: CaptureState = .idle

    var sampleRate: Double { targetSampleRate }

    init() {
        captureResources = AudioCaptureResources()
        makeHardware = { SystemAudioCaptureHardware() }
    }

    init(captureResources: AudioCaptureResources) {
        self.captureResources = captureResources
        makeHardware = { SystemAudioCaptureHardware() }
    }

    init(makeHardware: @escaping () -> any AudioCaptureHardware) {
        captureResources = AudioCaptureResources()
        self.makeHardware = makeHardware
    }

    func start(lifecycleState: () -> AudioCaptureLifecycleState) throws {
        guard lifecycleState().allowsCapture else {
            throw RecordingError.inactiveLifecycle
        }
        if captureState.isRecording { return }

        cleanupCaptureResources()
        let generation = UUID()
        captureState = .starting(generation)

        recordedSamples.removeAll(keepingCapacity: true)
        audioLevel = 0
        recordingDuration = 0

        do {
            let hardware = makeHardware()
            captureResources.own { hardware.deactivateAudioSession() }
            try hardware.activateAudioSession()
            captureResources.own { hardware.stop() }

            let inputFormat = hardware.inputFormat
            if let rejection = AudioCaptureStartupPolicy.rejection(
                lifecycle: lifecycleState(),
                sampleRate: inputFormat.sampleRate,
                channelCount: Int(inputFormat.channelCount)
            ) {
                switch rejection {
                case .inactiveLifecycle:
                    throw RecordingError.inactiveLifecycle
                case .unavailableInputFormat:
                    throw RecordingError.inputUnavailable
                }
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw RecordingError.inputUnavailable
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw RecordingError.converterUnavailable
            }
            self.converter = converter

            guard lifecycleState().allowsCapture else {
                throw RecordingError.inactiveLifecycle
            }
            try hardware.installTap(bufferSize: 1024, format: inputFormat) { [weak self] buffer in
                self?.handleBuffer(
                    buffer,
                    inputFormat: inputFormat,
                    targetFormat: targetFormat,
                    generation: generation
                )
            }
            captureResources.own { hardware.removeTap() }

            guard lifecycleState().allowsCapture else {
                throw RecordingError.inactiveLifecycle
            }
            hardware.prepare()
            guard lifecycleState().allowsCapture else {
                throw RecordingError.inactiveLifecycle
            }
            try hardware.start()
            captureState = .recording(generation)
        } catch {
            captureState = .idle
            cleanupCaptureResources()
            throw error
        }
    }

    func stop() -> [Float] {
        let samples = captureState.isRecording ? recordedSamples : []
        captureState = .idle
        cleanupCaptureResources()
        audioLevel = 0
        recordingDuration = 0
        recordedSamples.removeAll(keepingCapacity: false)
        return samples
    }

    func cancel() {
        _ = stop()
        recordedSamples.removeAll(keepingCapacity: false)
        audioLevel = 0
        recordingDuration = 0
    }

    private func cleanupCaptureResources() {
        captureResources.releaseAll()
        converter = nil
    }

    private func handleBuffer(
        _ buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        generation: UUID
    ) {
        guard captureState.generation == generation else { return }
        guard let converter else { return }

        guard let outputFrameCapacity = AudioCaptureStartupPolicy.outputFrameCapacity(
            inputFrameCount: buffer.frameLength,
            inputSampleRate: inputFormat.sampleRate,
            targetSampleRate: targetSampleRate
        ) else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        let converterInput = SynchronousAudioConverterInput(buffer: buffer)
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return converterInput.buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if error != nil { audioLevel = 0; return }

        guard let channelData = convertedBuffer.floatChannelData else { return }
        let frameLength = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        guard captureState.generation == generation else { return }
        if recordedSamples.isEmpty {
            logger.info(
                "Received first audio buffer [frames: \(buffer.frameLength), sampleRate: \(inputFormat.sampleRate)]"
            )
        }
        updateMetrics(with: samples)
        bufferHandler?(convertedBuffer)
    }

    private func updateMetrics(with samples: [Float]) {
        guard !samples.isEmpty else { return }

        let sumSquares = samples.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(sumSquares / Float(samples.count))
        audioLevel = min(max(rms * 3, 0.05), 1.0)

        recordedSamples.append(contentsOf: samples)
        recordingDuration = Double(recordedSamples.count) / targetSampleRate
    }

    enum RecordingError: LocalizedError {
        case converterUnavailable
        case inactiveLifecycle
        case inputUnavailable

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "Failed to configure audio converter."
            case .inactiveLifecycle:
                return "Voice recording is only available while VVTerm is active."
            case .inputUnavailable:
                return "Audio input is temporarily unavailable."
            }
        }
    }
}
