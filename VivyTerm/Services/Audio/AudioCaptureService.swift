import Foundation
import Combine
import AVFoundation

@MainActor
final class AudioCaptureService: ObservableObject {
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0

    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?

    private let targetSampleRate: Double = 16_000
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var recordedSamples: [Float] = []
    private var isRecording = false

    var sampleRate: Double { targetSampleRate }

    func start() throws {
        if isRecording { return }

        recordedSamples.removeAll(keepingCapacity: true)
        audioLevel = 0
        recordingDuration = 0

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        guard let converter else {
            throw RecordingError.converterUnavailable
        }

        self.audioEngine = engine
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        audioEngine = nil
        converter = nil
        audioLevel = 0
        recordingDuration = 0
        let samples = recordedSamples
        recordedSamples.removeAll(keepingCapacity: false)
        return samples
    }

    func cancel() {
        _ = stop()
        recordedSamples.removeAll(keepingCapacity: false)
        audioLevel = 0
        recordingDuration = 0
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if error != nil {
            Task { @MainActor in
                self.audioLevel = 0
            }
            return
        }

        guard let channelData = convertedBuffer.floatChannelData else { return }
        let frameLength = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        Task { @MainActor in
            self.updateMetrics(with: samples)
            self.bufferHandler?(convertedBuffer)
        }
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

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "Failed to configure audio converter."
            }
        }
    }
}
