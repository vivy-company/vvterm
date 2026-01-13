import Foundation
#if arch(arm64)
import MLX
@preconcurrency import MLXNN

// MARK: - Configuration Structures

nonisolated public struct PreprocessConfig: Codable {
    public let sampleRate: Int
    public let normalize: String
    public let windowSize: Float
    public let windowStride: Float
    public let window: String
    public let features: Int
    public let nFFT: Int
    public let dither: Float
    public let padTo: Int
    public let padValue: Float
    public let preemph: Float
    public let magPower: Float = 2.0

    public var winLength: Int {
        Int(windowSize * Float(sampleRate))
    }

    public var hopLength: Int {
        Int(windowStride * Float(sampleRate))
    }

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case normalize
        case windowSize = "window_size"
        case windowStride = "window_stride"
        case window
        case features
        case nFFT = "n_fft"
        case dither
        case padTo = "pad_to"
        case padValue = "pad_value"
        case preemph
        case magPower = "mag_power"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        normalize = try container.decode(String.self, forKey: .normalize)
        windowSize = try container.decode(Float.self, forKey: .windowSize)
        windowStride = try container.decode(Float.self, forKey: .windowStride)
        window = try container.decode(String.self, forKey: .window)
        features = try container.decode(Int.self, forKey: .features)
        nFFT = try container.decode(Int.self, forKey: .nFFT)
        dither = try container.decode(Float.self, forKey: .dither)
        padTo = try container.decodeIfPresent(Int.self, forKey: .padTo) ?? 0
        padValue = try container.decodeIfPresent(Float.self, forKey: .padValue) ?? 0.0
        preemph = try container.decodeIfPresent(Float.self, forKey: .preemph) ?? 0.97
    }
}

nonisolated public struct ConformerConfig: Codable {
    public let featIn: Int
    public let nLayers: Int
    public let dModel: Int
    public let nHeads: Int
    public let ffExpansionFactor: Int
    public let subsamplingFactor: Int
    public let selfAttentionModel: String
    public let subsampling: String
    public let convKernelSize: Int
    public let subsamplingConvChannels: Int
    public let posEmbMaxLen: Int
    public let causalDownsampling: Bool = false
    public let useBias: Bool = true
    public let xscaling: Bool = false
    public let subsamplingConvChunkingFactor: Int = 1
    public let attContextSize: [Int]?
    public let posBiasU: [Float]?
    public let posBiasV: [Float]?

    public func posBiasUArray() -> MLXArray? {
        posBiasU.map { MLXArray($0) }
    }

    public func posBiasVArray() -> MLXArray? {
        posBiasV.map { MLXArray($0) }
    }

    enum CodingKeys: String, CodingKey {
        case featIn = "feat_in"
        case nLayers = "n_layers"
        case dModel = "d_model"
        case nHeads = "n_heads"
        case ffExpansionFactor = "ff_expansion_factor"
        case subsamplingFactor = "subsampling_factor"
        case selfAttentionModel = "self_attention_model"
        case subsampling
        case convKernelSize = "conv_kernel_size"
        case subsamplingConvChannels = "subsampling_conv_channels"
        case posEmbMaxLen = "pos_emb_max_len"
        case causalDownsampling = "causal_downsampling"
        case useBias = "use_bias"
        case xscaling
        case subsamplingConvChunkingFactor = "subsampling_conv_chunking_factor"
        case attContextSize = "att_context_size"
        case posBiasU = "pos_bias_u"
        case posBiasV = "pos_bias_v"
    }
}

nonisolated public struct PredictNetworkConfig: Codable {
    public let predHidden: Int
    public let predRNNLayers: Int
    public let rnnHiddenSize: Int?

    enum CodingKeys: String, CodingKey {
        case predHidden = "pred_hidden"
        case predRNNLayers = "pred_rnn_layers"
        case rnnHiddenSize = "rnn_hidden_size"
    }
}

nonisolated public struct JointNetworkConfig: Codable {
    public let jointHidden: Int
    public let activation: String
    public let encoderHidden: Int
    public let predHidden: Int

    enum CodingKeys: String, CodingKey {
        case jointHidden = "joint_hidden"
        case activation
        case encoderHidden = "encoder_hidden"
        case predHidden = "pred_hidden"
    }
}

nonisolated public struct PredictConfig: Codable {
    public let blankAsPad: Bool
    public let vocabSize: Int
    public let prednet: PredictNetworkConfig

    enum CodingKeys: String, CodingKey {
        case blankAsPad = "blank_as_pad"
        case vocabSize = "vocab_size"
        case prednet
    }
}

nonisolated public struct JointConfig: Codable {
    public let numClasses: Int
    public let vocabulary: [String]
    public let jointnet: JointNetworkConfig
    public let numExtraOutputs: Int

    enum CodingKeys: String, CodingKey {
        case numClasses = "num_classes"
        case vocabulary
        case jointnet
        case numExtraOutputs = "num_extra_outputs"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numClasses = try container.decode(Int.self, forKey: .numClasses)
        vocabulary = try container.decode([String].self, forKey: .vocabulary)
        jointnet = try container.decode(JointNetworkConfig.self, forKey: .jointnet)
        numExtraOutputs = try container.decodeIfPresent(Int.self, forKey: .numExtraOutputs) ?? 0
    }
}

nonisolated public struct TDTDecodingConfig: Codable {
    public let modelType: String
    public let durations: [Int]
    public let greedy: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case durations
        case greedy
    }

    public init(modelType: String, durations: [Int], greedy: [String: Any]? = nil) {
        self.modelType = modelType
        self.durations = durations
        self.greedy = greedy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decode(String.self, forKey: .modelType)
        durations = try container.decode([Int].self, forKey: .durations)

        if container.contains(.greedy) {
            let greedyData = try container.decode([String: Int].self, forKey: .greedy)
            greedy = greedyData
        } else {
            greedy = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelType, forKey: .modelType)
        try container.encode(durations, forKey: .durations)
        if let greedy = greedy {
            try container.encode(greedy as? [String: Int], forKey: .greedy)
        }
    }
}

nonisolated public struct ParakeetTDTConfig: Codable {
    public let preprocessor: PreprocessConfig
    public let encoder: ConformerConfig
    public let decoder: PredictConfig
    public let joint: JointConfig
    public let decoding: TDTDecodingConfig
}

// MARK: - Aligned Token Structures

nonisolated public struct AlignedToken: Sendable {
    public let id: Int
    public var start: Float
    public var duration: Float
    public let text: String

    public var end: Float {
        get { start + duration }
        set { duration = newValue - start }
    }

    public init(id: Int, start: Float, duration: Float, text: String) {
        self.id = id
        self.start = start
        self.duration = duration
        self.text = text
    }
}

nonisolated public struct AlignedSentence: Sendable {
    public let tokens: [AlignedToken]
    public let start: Float
    public let end: Float

    public var text: String {
        tokens.map { $0.text }.joined()
    }

    public init(tokens: [AlignedToken]) {
        self.tokens = tokens
        self.start = tokens.first?.start ?? 0.0
        self.end = tokens.last?.end ?? 0.0
    }
}

nonisolated public struct AlignedResult: Sendable {
    public let sentences: [AlignedSentence]

    public var text: String {
        sentences.map { $0.text }.joined(separator: " ")
    }

    public init(sentences: [AlignedSentence]) {
        self.sentences = sentences
    }
}

// MARK: - Decoding Configuration

nonisolated public struct DecodingConfig {
    public let decoding: String

    public init(decoding: String = "greedy") {
        self.decoding = decoding
    }
}

// MARK: - Main Parakeet Model

@preconcurrency nonisolated public class ParakeetTDT: Module, @unchecked Sendable {
    public let preprocessConfig: PreprocessConfig
    public let encoderConfig: ConformerConfig
    public let vocabulary: [String]
    public let durations: [Int]
    public let maxSymbols: Int
    public let blankTokenId: Int
    public let numClasses: Int
    public let numExtraOutputs: Int

    private let encoder: Conformer
    private let decoder: PredictNetwork
    private let joint: JointNetwork
    private let decoderConfig: PredictConfig
    private let jointConfig: JointConfig

    public init(config: ParakeetTDTConfig) throws {
        guard config.decoding.modelType == "tdt" else {
            throw ParakeetError.invalidModelType("Model must be a TDT model")
        }

        self.preprocessConfig = config.preprocessor
        self.encoderConfig = config.encoder
        self.decoderConfig = config.decoder
        self.jointConfig = config.joint
        self.vocabulary = config.joint.vocabulary
        self.durations = config.decoding.durations
        self.maxSymbols = config.decoding.greedy?["max_symbols"] as? Int ?? 10
        let vocabSize = config.decoder.vocabSize
        self.numClasses = config.joint.numClasses > 0 ? config.joint.numClasses : vocabSize
        self.numExtraOutputs = config.joint.numExtraOutputs > 0 ? config.joint.numExtraOutputs : config.decoding.durations.count
        self.blankTokenId = vocabSize

        self.encoder = Conformer(config: config.encoder)
        self.decoder = PredictNetwork(config: config.decoder)
        self.joint = JointNetwork(config: config.joint)

        super.init()
    }

    public func transcribe(
        audioData: MLXArray,
        dtype: DType = .float32,
        chunkDuration: Float? = nil,
        overlapDuration: Float = 15.0,
        chunkCallback: ((Float, Float) -> Void)? = nil
    ) throws -> AlignedResult {

        let processedAudio = audioData.dtype == dtype ? audioData : audioData.asType(dtype)

        if let chunkDuration = chunkDuration {
            let audioLengthSeconds = Float(audioData.shape[0]) / Float(preprocessConfig.sampleRate)

            if audioLengthSeconds <= chunkDuration {
                let mel = try getLogMel(processedAudio, config: preprocessConfig)
                return try generate(mel: mel)[0]
            }

            return try transcribeChunked(
                audio: processedAudio,
                chunkDuration: chunkDuration,
                overlapDuration: overlapDuration,
                chunkCallback: chunkCallback
            )
        } else {
            let mel = try getLogMel(processedAudio, config: preprocessConfig)
            return try generate(mel: mel)[0]
        }
    }

    private func transcribeChunked(
        audio: MLXArray,
        chunkDuration: Float,
        overlapDuration: Float,
        chunkCallback: ((Float, Float) -> Void)?
    ) throws -> AlignedResult {

        let chunkSamples = Int(chunkDuration * Float(preprocessConfig.sampleRate))
        let overlapSamples = Int(overlapDuration * Float(preprocessConfig.sampleRate))
        let audioLength = audio.shape[0]

        var allTokens: [AlignedToken] = []
        var start = 0

        while start < audioLength {
            let end = min(start + chunkSamples, audioLength)

            chunkCallback?(Float(end), Float(audioLength))

            if end - start < preprocessConfig.hopLength {
                break
            }

            let chunkAudio = audio[start..<end]
            let chunkMel = try getLogMel(chunkAudio, config: preprocessConfig)
            let chunkResult = try generate(mel: chunkMel)[0]

            let chunkOffset = Float(start) / Float(preprocessConfig.sampleRate)
            var chunkTokens: [AlignedToken] = []

            for sentence in chunkResult.sentences {
                for var token in sentence.tokens {
                    token.start += chunkOffset
                    chunkTokens.append(token)
                }
            }

            if !allTokens.isEmpty {
                allTokens = try mergeLongestContiguous(
                    allTokens,
                    chunkTokens,
                    overlapDuration: overlapDuration
                )
            } else {
                allTokens = chunkTokens
            }

            start += chunkSamples - overlapSamples
        }

        return sentencesToResult(tokensToSentences(allTokens))
    }

    public func generate(mel: MLXArray) throws -> [AlignedResult] {
        let inputMel = mel.ndim == 2 ? mel.expandedDimensions(axis: 0) : mel

        let (features, lengths) = encoder(inputMel)

        let (results, _) = try decode(
            features: features,
            lengths: lengths,
            config: DecodingConfig()
        )

        return results.map { tokens in
            sentencesToResult(tokensToSentences(tokens))
        }
    }

    public func decode(
        features: MLXArray,
        lengths: MLXArray? = nil,
        lastToken: [Int?]? = nil,
        hiddenState: [(MLXArray, MLXArray)?]? = nil,
        config: DecodingConfig = DecodingConfig()
    ) throws -> ([[AlignedToken]], [(MLXArray, MLXArray)?]) {

        guard config.decoding == "greedy" else {
            throw ParakeetError.unsupportedDecoding(
                "Only greedy decoding is supported for TDT decoder")
        }

        let (B, S) = (features.shape[0], features.shape[1])
        let actualLengths = lengths ?? MLXArray(Array(repeating: S, count: B))
        let actualLastToken = lastToken ?? Array(repeating: nil, count: B)
        var actualHiddenState = hiddenState ?? Array(repeating: nil, count: B)

        var results: [[AlignedToken]] = []

        for batch in 0..<B {
            var hypothesis: [AlignedToken] = []
            let feature = features[batch].expandedDimensions(axis: 0)
            let length = Int(actualLengths[batch].item(Int32.self))

            var step = 0
            var newSymbols = 0
            var currentLastToken = actualLastToken[batch]

            while step < length {
                let decoderInput = currentLastToken.map { token in
                    MLXArray([token]).expandedDimensions(axis: 0)
                }

                let (decoderOut, newHidden) = decoder(decoderInput, actualHiddenState[batch])

                let decoderOutput = decoderOut.asType(feature.dtype)
                let decoderHidden = (
                    newHidden.0.asType(feature.dtype), newHidden.1.asType(feature.dtype)
                )

                let jointOut = joint(
                    feature[0..., step..<(step + 1)],
                    decoderOutput
                )

                MLX.eval(jointOut)

                let jointOutNaNCheck = jointOut.max().item(Float.self)
                if jointOutNaNCheck.isNaN {
                    break
                }

                let tokenCount = numClasses + 1
                let extraOutputs = numExtraOutputs

                guard jointOut.shape.count >= 4 else {
                    throw ParakeetError.audioProcessingError(
                        "Joint output has insufficient dimensions: \(jointOut.shape)")
                }

                let lastDim = jointOut.shape[jointOut.shape.count - 1]

                guard lastDim >= tokenCount + extraOutputs else {
                    throw ParakeetError.audioProcessingError(
                        "Joint output last dimension (\(lastDim)) is smaller than tokens+extra (\(tokenCount)+\(extraOutputs))"
                    )
                }

                let vocabSlice = jointOut[0, 0, 0..., 0..<tokenCount]
                let decisionSlice = jointOut[0, 0, 0..., tokenCount..<(tokenCount + extraOutputs)]

                guard vocabSlice.shape[0] > 0 && decisionSlice.shape[0] > 0 else {
                    throw ParakeetError.audioProcessingError(
                        "Empty slices: vocab=\(vocabSlice.shape), decision=\(decisionSlice.shape)")
                }

                let predToken = Int(vocabSlice.argMax(axis: -1).item(Int32.self))
                let decision = Int(decisionSlice.argMax(axis: -1).item(Int32.self))

                if predToken != blankTokenId, predToken >= 0, predToken < vocabulary.count {
                    let tokenText = ParakeetTokenizer.decode([predToken], vocabulary)
                    if tokenText.isEmpty == false {
                        let decisionIndex = min(decision, max(durations.count - 1, 0))
                        let startTime =
                            Float(step * encoderConfig.subsamplingFactor)
                            / Float(preprocessConfig.sampleRate) * Float(preprocessConfig.hopLength)
                        let duration =
                            Float(durations[decisionIndex] * encoderConfig.subsamplingFactor)
                            / Float(preprocessConfig.sampleRate) * Float(preprocessConfig.hopLength)

                        hypothesis.append(
                            AlignedToken(
                                id: predToken,
                                start: startTime,
                                duration: duration,
                                text: tokenText
                            ))

                        currentLastToken = predToken
                        actualHiddenState[batch] = decoderHidden
                    }
                }

                let stepDuration = durations[min(decision, max(durations.count - 1, 0))]
                step += stepDuration

                newSymbols += 1

                if stepDuration != 0 {
                    newSymbols = 0
                } else {
                    if newSymbols >= maxSymbols {
                        step += 1
                        newSymbols = 0
                    }
                }

                if newSymbols > 100 {
                    break
                }

            }

            results.append(hypothesis)
        }

        return (results, actualHiddenState)
    }

    public func loadWeights(from urls: [URL]) throws {
        var mappedWeights: [String: MLXArray] = [:]

        for url in urls {
            let weights = try MLX.loadArrays(url: url)
            for (safetensorsKey, weight) in weights {
                if let swiftKey = mapSafetensorsKeyToSwiftPath(safetensorsKey) {
                    mappedWeights[swiftKey] = weight
                }
            }
        }

        let flatWeights = ModuleParameters.unflattened(mappedWeights)
        self.update(parameters: flatWeights)
    }

    public func loadWeights(from arrays: [String: MLXArray]) throws {
        var mappedWeights: [String: MLXArray] = [:]
        for (key, weight) in arrays {
            if let swiftKey = mapSafetensorsKeyToSwiftPath(key) {
                mappedWeights[swiftKey] = weight
            }
        }
        let flatWeights = ModuleParameters.unflattened(mappedWeights)
        self.update(parameters: flatWeights)
    }

    public func loadWeights(from url: URL) throws {
        try loadWeights(from: [url])
    }

    private func mapSafetensorsKeyToSwiftPath(_ safetensorsKey: String) -> String? {
        if safetensorsKey.hasPrefix("encoder.") {
            let encoderKey = String(safetensorsKey.dropFirst("encoder.".count))

            if encoderKey.hasPrefix("pre_encode.") {
                let preEncodeKey = String(encoderKey.dropFirst("pre_encode.".count))

                if preEncodeKey.hasPrefix("conv.") {
                    return "encoder.preEncode.\(preEncodeKey)"
                }

                if preEncodeKey.hasPrefix("out.") {
                    return "encoder.preEncode.\(preEncodeKey)"
                }
            }

            if encoderKey.hasPrefix("layers.") {
                var layerKey = encoderKey

                layerKey = layerKey.replacingOccurrences(of: "norm_self_att", with: "normSelfAtt")
                layerKey = layerKey.replacingOccurrences(
                    of: "self_attn.linear_q", with: "selfAttn.linearQ")
                layerKey = layerKey.replacingOccurrences(
                    of: "self_attn.linear_k", with: "selfAttn.linearK")
                layerKey = layerKey.replacingOccurrences(
                    of: "self_attn.linear_v", with: "selfAttn.linearV")
                layerKey = layerKey.replacingOccurrences(
                    of: "self_attn.linear_out", with: "selfAttn.linearOut")
                layerKey = layerKey.replacingOccurrences(
                    of: "self_attn.linear_pos", with: "selfAttn.linearPos")
                layerKey = layerKey.replacingOccurrences(
                    of: "self_attn.pos_bias_u", with: "selfAttn.posBiasU")
                layerKey = layerKey.replacingOccurrences(
                    of: "self_attn.pos_bias_v", with: "selfAttn.posBiasV")
                layerKey = layerKey.replacingOccurrences(of: "norm_conv", with: "normConv")
                layerKey = layerKey.replacingOccurrences(
                    of: "conv.pointwise_conv1", with: "conv.pointwiseConv1")
                layerKey = layerKey.replacingOccurrences(
                    of: "conv.depthwise_conv", with: "conv.depthwiseConv")
                layerKey = layerKey.replacingOccurrences(
                    of: "conv.batch_norm", with: "conv.batchNorm")
                layerKey = layerKey.replacingOccurrences(
                    of: "conv.pointwise_conv2", with: "conv.pointwiseConv2")
                layerKey = layerKey.replacingOccurrences(
                    of: "norm_feed_forward1", with: "normFeedForward1")
                layerKey = layerKey.replacingOccurrences(of: "feed_forward1", with: "feedForward1")
                layerKey = layerKey.replacingOccurrences(
                    of: "norm_feed_forward2", with: "normFeedForward2")
                layerKey = layerKey.replacingOccurrences(of: "feed_forward2", with: "feedForward2")
                layerKey = layerKey.replacingOccurrences(of: "norm_out", with: "normOut")

                return "encoder.\(layerKey)"
            }
        }

        if safetensorsKey.hasPrefix("decoder.") {
            var decoderKey = String(safetensorsKey.dropFirst("decoder.".count))

            decoderKey = decoderKey.replacingOccurrences(of: "prediction.embed", with: "embed")
            decoderKey = decoderKey.replacingOccurrences(
                of: "prediction.dec_rnn.lstm", with: "decRNN.lstmLayers")

            return "decoder.\(decoderKey)"
        }

        if safetensorsKey.hasPrefix("joint.") {
            var jointKey = String(safetensorsKey.dropFirst("joint.".count))

            jointKey = jointKey.replacingOccurrences(of: "enc_proj", with: "encLinear")
            jointKey = jointKey.replacingOccurrences(of: "pred_proj", with: "predLinear")
            jointKey = jointKey.replacingOccurrences(of: "joint_proj", with: "jointLinear")

            jointKey = jointKey.replacingOccurrences(of: "enc.", with: "encLinear.")
            jointKey = jointKey.replacingOccurrences(of: "pred.", with: "predLinear.")

            if jointKey.hasPrefix("joint_net.") {
                let jointNetKey = String(jointKey.dropFirst("joint_net.".count))
                if jointNetKey.hasPrefix("2.") {
                    let layerParam = String(jointNetKey.dropFirst("2.".count))
                    jointKey = "jointLinear.\(layerParam)"
                } else {
                    return nil
                }
            }

            return "joint.\(jointKey)"
        }

        return nil
    }

    public func encode(_ input: MLXArray, cache: [ConformerCache?]? = nil) -> (MLXArray, MLXArray) {
        return encoder(input, cache: cache)
    }

}

// MARK: - Error Types

nonisolated public enum ParakeetError: Error, LocalizedError {
    case invalidModelType(String)
    case unsupportedDecoding(String)
    case audioProcessingError(String)
    case modelLoadingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModelType(let message):
            return "Invalid model type: \(message)"
        case .unsupportedDecoding(let message):
            return "Unsupported decoding: \(message)"
        case .audioProcessingError(let message):
            return "Audio processing error: \(message)"
        case .modelLoadingError(let message):
            return "Model loading error: \(message)"
        }
    }
}

// MARK: - Utility Functions

nonisolated private func tokensToSentences(_ tokens: [AlignedToken]) -> [AlignedSentence] {
    guard !tokens.isEmpty else { return [] }

    var sentences: [AlignedSentence] = []
    var currentTokens: [AlignedToken] = []

    for token in tokens {
        currentTokens.append(token)

        if token.text.contains(".") || token.text.contains("!") || token.text.contains("?") {
            sentences.append(AlignedSentence(tokens: currentTokens))
            currentTokens = []
        }
    }

    if !currentTokens.isEmpty {
        sentences.append(AlignedSentence(tokens: currentTokens))
    }

    return sentences
}

nonisolated private func sentencesToResult(_ sentences: [AlignedSentence]) -> AlignedResult {
    return AlignedResult(sentences: sentences)
}

nonisolated private func mergeLongestContiguous(
    _ tokens1: [AlignedToken],
    _ tokens2: [AlignedToken],
    overlapDuration: Float
) throws -> [AlignedToken] {
    let cutoffTime = tokens1.last?.end ?? 0.0 - overlapDuration
    let filteredTokens1 = tokens1.filter { $0.end <= cutoffTime }
    let filteredTokens2 = tokens2.filter { $0.start >= cutoffTime }

    return filteredTokens1 + filteredTokens2
}

// MARK: - Streaming Support

nonisolated public class StreamingParakeet {
    let model: ParakeetTDT
    let contextSize: (Int, Int)
    let depth: Int
    let decodingConfig: DecodingConfig

    private var audioBuffer: MLXArray
    private var decoderHidden: (MLXArray, MLXArray)?
    private var lastToken: Int?
    private var cleanTokens: [AlignedToken] = []
    private var dirtyTokens: [AlignedToken] = []
    private var cache: [ConformerCache]

    public init(
        model: ParakeetTDT,
        contextSize: (Int, Int),
        depth: Int = 1,
        decodingConfig: DecodingConfig = DecodingConfig()
    ) {
        self.model = model
        self.contextSize = contextSize
        self.depth = depth
        self.decodingConfig = decodingConfig

        self.audioBuffer = MLXArray([])
        self.cache = Array(
            repeating: RotatingConformerCache(
                contextSize: contextSize.0,
                cacheDropSize: contextSize.1 * depth
            ), count: model.encoderConfig.nLayers)
    }

    public var dropSize: Int {
        contextSize.1 * depth
    }

    public var result: AlignedResult {
        sentencesToResult(tokensToSentences(cleanTokens + dirtyTokens))
    }

    public func addAudio(_ audio: MLXArray) throws {
        audioBuffer = MLX.concatenated([audioBuffer, audio], axis: 0)

        let mel = try getLogMel(audioBuffer, config: model.preprocessConfig)

        let (features, lengths) = model.encode(mel, cache: cache)
        let length = Int(lengths[0].item(Int32.self))

        let samplesToKeep =
            dropSize * model.encoderConfig.subsamplingFactor * model.preprocessConfig.hopLength
        if audioBuffer.shape[0] > samplesToKeep {
            audioBuffer = audioBuffer[(audioBuffer.shape[0] - samplesToKeep)...]
        }

        let cleanLength = max(0, length - dropSize)

        if cleanLength > 0 {
            let (cleanResult, cleanState) = try model.decode(
                features: features[0..., 0..<cleanLength],
                lengths: MLXArray([cleanLength]),
                lastToken: lastToken.map { [$0] },
                hiddenState: decoderHidden.map { [$0] },
                config: decodingConfig
            )

            decoderHidden = cleanState[0]
            lastToken = cleanResult[0].last?.id
            cleanTokens.append(contentsOf: cleanResult[0])
        }

        if length > cleanLength {
            let (dirtyResult, _) = try model.decode(
                features: features[0..., cleanLength...],
                lengths: MLXArray([Int(length - cleanLength)]),
                lastToken: lastToken.map { [$0] },
                hiddenState: decoderHidden.map { [$0] },
                config: decodingConfig
            )

            dirtyTokens = dirtyResult[0]
        }
    }
}

extension ParakeetTDT {
    public func transcribeStream(
        contextSize: (Int, Int) = (256, 256),
        depth: Int = 1
    ) -> StreamingParakeet {
        return StreamingParakeet(
            model: self,
            contextSize: contextSize,
            depth: depth
        )
    }
}
#endif
