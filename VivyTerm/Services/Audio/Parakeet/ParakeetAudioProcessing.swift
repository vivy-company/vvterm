import Accelerate
import Foundation
#if arch(arm64)
import MLX

// MARK: - Audio Processing Functions

/// Compute log mel spectrogram from audio data
nonisolated public func getLogMel(_ audio: MLXArray, config: PreprocessConfig) throws -> MLXArray {
    let originalDType = audio.dtype
    var x = audio

    // Pad audio if needed
    if config.padTo > 0 && x.shape.last! < config.padTo {
        let padLength = config.padTo - x.shape.last!
        let padArray = Array(repeating: (0, 0), count: x.ndim)
        var padArray2 = padArray
        padArray2[padArray2.count - 1] = (0, padLength)
        x = MLX.padded(
            x, widths: padArray2.map { IntOrPair($0) }, mode: .constant,
            value: MLXArray(config.padValue))
    }

    // Apply pre-emphasis high-pass filter to match mlx-audio preprocessing
    if config.preemph > 0 {
        let prefix = x[0..<1]
        let diff = x[1...] - config.preemph * x[0..<(x.shape[0] - 1)]
        x = MLX.concatenated([prefix, diff], axis: 0)
    }

    // Get window function
    let window = try getWindow(config.window, length: config.winLength, dtype: x.dtype)

    // Compute STFT
    x = try stft(
        x,
        nFFT: config.nFFT,
        hopLength: config.hopLength,
        winLength: config.winLength,
        window: window
    )

    // Compute magnitude spectrum
    let magnitude = abs(x)
    var powerSpectrum = magnitude

    if config.magPower != 1.0 {
        powerSpectrum = pow(magnitude, config.magPower)
    }

    // Apply mel filterbank
    let melFilters = try createMelFilterbank(
        sampleRate: config.sampleRate,
        nFFT: config.nFFT,
        nMels: config.features,
        normalize: config.normalize
    )

    let melSpectrum = matmul(
        melFilters.asType(powerSpectrum.dtype), powerSpectrum.transposed(axes: [1, 0]))
    let logMelSpectrum = log(melSpectrum + 1e-5)

    // Normalize
    let normalizedMel: MLXArray
    if config.normalize == "per_feature" {
        let mean = logMelSpectrum.mean(axes: [1], keepDims: true)
        let std = logMelSpectrum.std(axes: [1], keepDims: true)
        normalizedMel = (logMelSpectrum - mean) / (std + 1e-5)
    } else {
        let mean = logMelSpectrum.mean()
        let std = logMelSpectrum.std()
        normalizedMel = (logMelSpectrum - mean) / (std + 1e-5)
    }

    // Transpose and add batch dimension
    let output = normalizedMel.transposed(axes: [1, 0]).expandedDimensions(axis: 0)

    return output.asType(originalDType)
}

// MARK: - Window Functions

nonisolated private func getWindow(_ windowType: String, length: Int, dtype: DType) throws -> MLXArray {
    switch windowType.lowercased() {
    case "hanning", "hann":
        return hanningWindow(length: length, dtype: dtype)
    case "hamming":
        return hammingWindow(length: length, dtype: dtype)
    case "blackman":
        return blackmanWindow(length: length, dtype: dtype)
    case "bartlett":
        return bartlettWindow(length: length, dtype: dtype)
    default:
        throw ParakeetError.audioProcessingError("Unsupported window type: \(windowType)")
    }
}

nonisolated private func hanningWindow(length: Int, dtype: DType) -> MLXArray {
    let n = Float(length)
    let indices = MLXArray(0..<length).asType(.float32)
    let window = 0.5 * (1.0 - cos(2.0 * Float.pi * indices / (n - 1)))
    return window.asType(dtype)
}

nonisolated private func hammingWindow(length: Int, dtype: DType) -> MLXArray {
    let n = Float(length)
    let indices = MLXArray(0..<length).asType(.float32)
    let window = 0.54 - 0.46 * cos(2.0 * Float.pi * indices / (n - 1))
    return window.asType(dtype)
}

nonisolated private func blackmanWindow(length: Int, dtype: DType) -> MLXArray {
    let n = Float(length)
    let indices = MLXArray(0..<length).asType(.float32)
    let a0: Float = 0.42
    let a1: Float = 0.5
    let a2: Float = 0.08
    let window =
        a0 - a1 * cos(2.0 * Float.pi * indices / (n - 1)) + a2
        * cos(4.0 * Float.pi * indices / (n - 1))
    return window.asType(dtype)
}

nonisolated private func bartlettWindow(length: Int, dtype: DType) -> MLXArray {
    let n = Float(length)
    let indices = MLXArray(0..<length).asType(.float32)
    let window = 1.0 - abs((indices - (n - 1) / 2.0) / ((n - 1) / 2.0))
    return window.asType(dtype)
}

// MARK: - STFT Implementation

nonisolated private func stft(
    _ x: MLXArray,
    nFFT: Int,
    hopLength: Int,
    winLength: Int,
    window: MLXArray
) throws -> MLXArray {
    var actualWindow = window
    if winLength != nFFT {
        if winLength > nFFT {
            actualWindow = window[0..<nFFT]
        } else {
            let padding = nFFT - winLength
            let padArray = [(0, padding)]
            actualWindow = MLX.padded(
                window,
                widths: padArray.map { IntOrPair($0) },
                mode: .constant,
                value: MLXArray(0.0)
            )
        }
    }

    let padding = nFFT / 2
    let prefix = x[1..<(padding + 1)].reversed(axes: [0])
    let suffix = x[(x.shape[0] - padding - 1)..<(x.shape[0] - 1)].reversed(axes: [0])
    let paddedX = MLX.concatenated([prefix, x, suffix], axis: 0)

    let numFrames = 1 + (paddedX.shape[0] - nFFT) / hopLength
    if numFrames <= 0 {
        throw ParakeetError.audioProcessingError(
            "Input is too short (length=\(paddedX.shape[0])) for nFFT=\(nFFT)"
        )
    }

    let frames = asStrided(
        paddedX,
        [numFrames, nFFT],
        strides: [hopLength, 1]
    )

    return MLX.rfft(frames * actualWindow, axis: -1)
}

// MARK: - Mel Filterbank

nonisolated private func createMelFilterbank(
    sampleRate: Int,
    nFFT: Int,
    nMels: Int,
    normalize: String
) throws -> MLXArray {
    let nFreqs = nFFT / 2 + 1
    let allFreqs = MLXArray.linspace(0.0, Float(sampleRate) / 2.0, count: nFreqs)

    let melMin = hzToMelSlaney(0.0)
    let melMax = hzToMelSlaney(Float(sampleRate) / 2.0)
    let melPoints = MLXArray.linspace(melMin, melMax, count: nMels + 2)
    let hzPoints = melToHzSlaney(melPoints)

    let fDiff = hzPoints[1...] - hzPoints[0..<(hzPoints.shape[0] - 1)]
    let slopes = hzPoints.expandedDimensions(axis: 0) - allFreqs.expandedDimensions(axis: 1)

    let downSlopes = (-slopes[0..., 0..<nMels]) / fDiff[0..<nMels]
    let upSlopes = slopes[0..., 2..<(nMels + 2)] / fDiff[1..<(nMels + 1)]

    var filterbank = MLX.maximum(
        MLXArray.zeros(downSlopes.shape),
        MLX.minimum(downSlopes, upSlopes)
    )

    if normalize == "slaney" {
        let enorm = 2.0 / (hzPoints[2..<(nMels + 2)] - hzPoints[0..<nMels])
        filterbank = filterbank * enorm.expandedDimensions(axis: 0)
    }

    return filterbank.transposed(axes: [1, 0])
}

// MARK: - Mel Scale Conversion (Slaney)

nonisolated private func hzToMelSlaney(_ hz: Float) -> Float {
    let fMin: Float = 0.0
    let fSp: Float = 200.0 / 3.0
    var mels = (hz - fMin) / fSp
    let minLogHz: Float = 1000.0
    let minLogMel: Float = (minLogHz - fMin) / fSp
    let logStep: Float = Foundation.log(6.4) / 27.0
    if hz >= minLogHz {
        mels = minLogMel + Foundation.log(hz / minLogHz) / logStep
    }
    return mels
}

nonisolated private func hzToMelSlaney(_ hz: MLXArray) -> MLXArray {
    let fMin: Float = 0.0
    let fSp: Float = 200.0 / 3.0
    let minLogHz: Float = 1000.0
    let minLogMel: Float = (minLogHz - fMin) / fSp
    let logStep: Float = Foundation.log(6.4) / 27.0
    let linear = (hz - fMin) / fSp
    let logPart = minLogMel + log(hz / minLogHz) / logStep
    return which(hz .>= minLogHz, logPart, linear)
}

nonisolated private func melToHzSlaney(_ mel: MLXArray) -> MLXArray {
    let fMin: Float = 0.0
    let fSp: Float = 200.0 / 3.0
    let minLogHz: Float = 1000.0
    let minLogMel: Float = (minLogHz - fMin) / fSp
    let logStep: Float = Foundation.log(6.4) / 27.0

    let freqs = fMin + fSp * mel
    let logFreqs = minLogHz * MLX.exp(logStep * (mel - minLogMel))
    return which(mel .>= minLogMel, logFreqs, freqs)
}

// MARK: - Utility Functions

nonisolated private func concatenate(_ arrays: [MLXArray], axis: Int) -> MLXArray {
    return MLX.concatenated(arrays, axis: axis)
}

nonisolated private func abs(_ x: MLXArray) -> MLXArray {
    return MLX.abs(x)
}

nonisolated private func pow(_ x: MLXArray, _ exp: Float) -> MLXArray {
    return MLX.pow(x, exp)
}

nonisolated private func pow(_ base: Float, _ exp: MLXArray) -> MLXArray {
    return MLX.pow(base, exp)
}

nonisolated private func log(_ x: MLXArray) -> MLXArray {
    return MLX.log(x)
}


nonisolated private func log10(_ x: MLXArray) -> MLXArray {
    return MLX.log(x) / MLX.log(MLXArray(10.0))
}

nonisolated private func cos(_ x: MLXArray) -> MLXArray {
    return MLX.cos(x)
}

nonisolated private func matmul(_ a: MLXArray, _ b: MLXArray) -> MLXArray {
    return MLX.matmul(a, b)
}

// MARK: - MLXArray Extensions

extension MLXArray {
    nonisolated func std(axes: [Int]? = nil, keepDims: Bool = false) -> MLXArray {
        let meanVal =
            axes != nil ? self.mean(axes: axes!, keepDims: true) : self.mean(keepDims: true)
        let variance =
            axes != nil
            ? ((self - meanVal) * (self - meanVal)).mean(axes: axes!, keepDims: keepDims)
            : ((self - meanVal) * (self - meanVal)).mean(keepDims: keepDims)
        return MLX.sqrt(variance)
    }

    nonisolated func reversed(axes: [Int]) -> MLXArray {
        // For 1D reversal on axis 0
        let indices = MLXArray((0..<self.shape[0]).reversed())
        return self[indices]
    }

    nonisolated static func linspace(_ start: Float, _ end: Float, count: Int) -> MLXArray {
        let step = (end - start) / Float(count - 1)
        let values = (0..<count).map { start + Float($0) * step }
        return MLXArray(values)
    }

    nonisolated static func stacked(_ arrays: [MLXArray], axis: Int) -> MLXArray {
        return MLX.stacked(arrays, axis: axis)
    }
}
#endif
