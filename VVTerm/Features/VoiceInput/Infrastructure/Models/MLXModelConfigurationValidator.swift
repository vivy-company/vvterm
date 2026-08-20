import Foundation

#if arch(arm64)
nonisolated enum MLXModelConfigurationError: Error, Equatable, LocalizedError {
    case invalid(String)
    case allocationBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .invalid(let field):
            return "Invalid model configuration: \(field)"
        case .allocationBudgetExceeded:
            return "The model configuration exceeds the allocation limit."
        }
    }
}

nonisolated enum MLXModelConfigurationValidator {
    private static let maximumEstimatedParameterBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    private static let maximumTensorBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    static func validateWhisper(_ dimensions: WhisperModelDimensions) throws {
        try require(dimensions.n_mels, in: 1...512, field: "n_mels")
        try require(dimensions.n_audio_ctx, in: 1...32_768, field: "n_audio_ctx")
        try validateAttention(
            state: dimensions.n_audio_state,
            heads: dimensions.n_audio_head,
            stateField: "n_audio_state",
            headField: "n_audio_head"
        )
        try require(dimensions.n_audio_state.isMultiple(of: 2), field: "n_audio_state parity")
        try require(dimensions.n_audio_state >= 4, field: "n_audio_state")
        try require(dimensions.n_audio_layer, in: 1...256, field: "n_audio_layer")
        try require(dimensions.n_vocab, in: 1...1_000_000, field: "n_vocab")
        try require(dimensions.n_text_ctx, in: 1...32_768, field: "n_text_ctx")
        try validateAttention(
            state: dimensions.n_text_state,
            heads: dimensions.n_text_head,
            stateField: "n_text_state",
            headField: "n_text_head"
        )
        try require(dimensions.n_text_layer, in: 1...256, field: "n_text_layer")

        try requireTensorWithinBudget(
            dimensions: [dimensions.n_audio_ctx, dimensions.n_audio_state],
            bytesPerElement: 4
        )
        try requireTensorWithinBudget(
            dimensions: [dimensions.n_text_ctx, dimensions.n_text_state],
            bytesPerElement: 2
        )

        let audioState = UInt64(dimensions.n_audio_state)
        let textState = UInt64(dimensions.n_text_state)
        let audioBlockParameters = try multiply(12, try multiply(audioState, audioState))
        let textBlockParameters = try multiply(16, try multiply(textState, textState))
        let audioParameters = try multiply(UInt64(dimensions.n_audio_layer), audioBlockParameters)
        let textParameters = try multiply(UInt64(dimensions.n_text_layer), textBlockParameters)
        let tokenParameters = try multiply(UInt64(dimensions.n_vocab), textState)
        let totalParameters = try add(try add(audioParameters, textParameters), tokenParameters)
        let estimatedBytes = try multiply(totalParameters, 4)
        try require(estimatedBytes <= maximumEstimatedParameterBytes, field: "estimated parameters")
    }

    static func validateParakeet(_ config: ParakeetTDTConfig) throws {
        try require(config.decoding.modelType == "tdt", field: "decoding.model_type")
        try validatePreprocessor(config.preprocessor)
        try validateConformer(config.encoder, featureCount: config.preprocessor.features)
        try validateDecoder(config.decoder)
        try validateJoint(config.joint, decoder: config.decoder, encoder: config.encoder)
        try validateDurations(config.decoding, extraOutputs: config.joint.numExtraOutputs)
        try validateParakeetAllocation(config)
    }

    private static func validatePreprocessor(_ config: PreprocessConfig) throws {
        try require(config.sampleRate, in: 8_000...192_000, field: "preprocessor.sample_rate")
        try require(config.windowSize.isFinite && config.windowSize > 0 && config.windowSize <= 1, field: "preprocessor.window_size")
        try require(config.windowStride.isFinite && config.windowStride > 0 && config.windowStride <= config.windowSize, field: "preprocessor.window_stride")
        try require(["hann", "hanning", "hamming", "blackman", "bartlett"].contains(config.window.lowercased()), field: "preprocessor.window")
        try require(config.features, in: 1...4_096, field: "preprocessor.features")
        try require(config.nFFT, in: 2...1_048_576, field: "preprocessor.n_fft")
        try require(config.dither.isFinite, field: "preprocessor.dither")
        try require(config.padTo, in: 0...16_777_216, field: "preprocessor.pad_to")
        try require(config.padValue.isFinite, field: "preprocessor.pad_value")
        try require(config.preemph.isFinite && config.preemph >= 0 && config.preemph <= 1, field: "preprocessor.preemph")

        let windowLength = Double(config.windowSize) * Double(config.sampleRate)
        let hopLength = Double(config.windowStride) * Double(config.sampleRate)
        try require(windowLength.isFinite && windowLength >= 2 && windowLength <= Double(Int.max), field: "preprocessor window length")
        try require(hopLength.isFinite && hopLength >= 1 && hopLength <= Double(Int.max), field: "preprocessor hop length")
    }

    private static func validateConformer(_ config: ConformerConfig, featureCount: Int) throws {
        try require(config.featIn == featureCount, field: "encoder.feat_in")
        try require(config.nLayers, in: 1...128, field: "encoder.n_layers")
        try validateAttention(
            state: config.dModel,
            heads: config.nHeads,
            stateField: "encoder.d_model",
            headField: "encoder.n_heads"
        )
        try require(config.dModel.isMultiple(of: 2), field: "encoder.d_model parity")
        try require(config.ffExpansionFactor, in: 1...16, field: "encoder.ff_expansion_factor")
        _ = try multiply(UInt64(config.dModel), UInt64(config.ffExpansionFactor))
        try require(config.convKernelSize, in: 1...1_023, field: "encoder.conv_kernel_size")
        try require(config.convKernelSize.isMultiple(of: 2) == false, field: "encoder.conv_kernel_size parity")
        try require(config.subsamplingConvChannels, in: 1...8_192, field: "encoder.subsampling_conv_channels")
        try require(config.posEmbMaxLen, in: 1...1_000_000, field: "encoder.pos_emb_max_len")
        try require(config.subsamplingConvChunkingFactor, in: 1...1_024, field: "encoder.subsampling_conv_chunking_factor")

        let supportedAttention = ["normal", "rel_pos", "rel_pos_local_attn"]
        try require(supportedAttention.contains(config.selfAttentionModel), field: "encoder.self_attention_model")
        if config.selfAttentionModel == "rel_pos_local_attn" {
            guard let context = config.attContextSize, context.count == 2 else {
                throw MLXModelConfigurationError.invalid("encoder.att_context_size")
            }
            try require(context.allSatisfy { $0 > 0 && $0 <= 65_536 }, field: "encoder.att_context_size")
        }

        if config.subsamplingFactor > 1 {
            try require(config.subsamplingFactor <= 1_024, field: "encoder.subsampling_factor")
            try require(config.subsamplingFactor.nonzeroBitCount == 1, field: "encoder.subsampling_factor")
            try require(config.subsampling == "dw_striding" && !config.causalDownsampling, field: "encoder.subsampling")

            var finalFrequency = config.featIn
            var remainingFactor = config.subsamplingFactor
            while remainingFactor > 1 {
                finalFrequency = (finalFrequency + 1) / 2
                try require(finalFrequency > 0, field: "encoder collapsed frequency")
                remainingFactor /= 2
            }
        } else {
            try require(config.subsamplingFactor == 1, field: "encoder.subsampling_factor")
        }

        try requireTensorWithinBudget(
            dimensions: [2 * config.posEmbMaxLen - 1, config.dModel],
            bytesPerElement: 4
        )

        if let biasU = config.posBiasU {
            try require(biasU.count == config.dModel && biasU.allSatisfy(\.isFinite), field: "encoder.pos_bias_u")
        }
        if let biasV = config.posBiasV {
            try require(biasV.count == config.dModel && biasV.allSatisfy(\.isFinite), field: "encoder.pos_bias_v")
        }
    }

    private static func validateDecoder(_ config: PredictConfig) throws {
        try require(config.vocabSize, in: 1...1_000_000, field: "decoder.vocab_size")
        try require(config.prednet.predHidden, in: 1...16_384, field: "decoder.pred_hidden")
        try require(config.prednet.predRNNLayers, in: 1...32, field: "decoder.pred_rnn_layers")
        if let hiddenSize = config.prednet.rnnHiddenSize {
            try require(hiddenSize, in: 1...16_384, field: "decoder.rnn_hidden_size")
        }
    }

    private static func validateJoint(
        _ config: JointConfig,
        decoder: PredictConfig,
        encoder: ConformerConfig
    ) throws {
        try require(config.numClasses == decoder.vocabSize, field: "joint.num_classes")
        try require(config.vocabulary.count == decoder.vocabSize, field: "joint.vocabulary")
        try require(config.numExtraOutputs, in: 1...256, field: "joint.num_extra_outputs")
        try require(config.jointnet.jointHidden, in: 1...16_384, field: "joint.joint_hidden")
        try require(config.jointnet.encoderHidden == encoder.dModel, field: "joint.encoder_hidden")
        try require(config.jointnet.predHidden == decoder.prednet.predHidden, field: "joint.pred_hidden")
        try require(["relu", "sigmoid", "tanh"].contains(config.jointnet.activation.lowercased()), field: "joint.activation")
    }

    private static func validateDurations(_ config: TDTDecodingConfig, extraOutputs: Int) throws {
        try require(config.durations.count == extraOutputs, field: "decoding.durations count")
        try require((1...256).contains(config.durations.count), field: "decoding.durations count")
        try require(config.durations.allSatisfy { (0...1_024).contains($0) }, field: "decoding.durations")
        try require(config.durations.contains { $0 > 0 }, field: "decoding.durations progress")
        let maxSymbols = config.greedy?["max_symbols"] as? Int ?? 10
        try require(maxSymbols, in: 1...256, field: "decoding.greedy.max_symbols")
    }

    private static func validateParakeetAllocation(_ config: ParakeetTDTConfig) throws {
        let state = UInt64(config.encoder.dModel)
        let expansion = UInt64(config.encoder.ffExpansionFactor)
        let stateSquared = try multiply(state, state)
        let blockParameters = try multiply(try add(try multiply(4, expansion), 8), stateSquared)
        let encoderParameters = try multiply(UInt64(config.encoder.nLayers), blockParameters)
        let decoderParameters = try multiply(UInt64(config.decoder.vocabSize), UInt64(config.decoder.prednet.predHidden))
        let jointParameters = try multiply(
            UInt64(config.joint.jointnet.jointHidden),
            try add(UInt64(config.joint.jointnet.encoderHidden), UInt64(config.joint.jointnet.predHidden))
        )
        let totalParameters = try add(try add(encoderParameters, decoderParameters), jointParameters)
        let estimatedBytes = try multiply(totalParameters, 4)
        guard estimatedBytes <= maximumEstimatedParameterBytes else {
            throw MLXModelConfigurationError.allocationBudgetExceeded
        }
    }

    private static func validateAttention(
        state: Int,
        heads: Int,
        stateField: String,
        headField: String
    ) throws {
        try require(state, in: 1...16_384, field: stateField)
        try require(heads, in: 1...1_024, field: headField)
        try require(state.isMultiple(of: heads), field: "\(stateField)/\(headField) divisibility")
    }

    private static func requireTensorWithinBudget(
        dimensions: [Int],
        bytesPerElement: UInt64
    ) throws {
        var elements: UInt64 = 1
        for dimension in dimensions {
            try require(dimension > 0, field: "tensor dimensions")
            elements = try multiply(elements, UInt64(dimension))
        }
        let bytes = try multiply(elements, bytesPerElement)
        guard bytes <= maximumTensorBytes else {
            throw MLXModelConfigurationError.allocationBudgetExceeded
        }
    }

    private static func require(_ condition: Bool, field: String) throws {
        guard condition else { throw MLXModelConfigurationError.invalid(field) }
    }

    private static func require(_ value: Int, in range: ClosedRange<Int>, field: String) throws {
        try require(range.contains(value), field: field)
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw MLXModelConfigurationError.allocationBudgetExceeded }
        return result
    }

    private static func multiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw MLXModelConfigurationError.allocationBudgetExceeded }
        return result
    }
}
#endif
