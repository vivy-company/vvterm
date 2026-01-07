import Foundation
#if arch(arm64)
import MLX
@preconcurrency import MLXNN

// MARK: - Feed Forward Network

@preconcurrency nonisolated public class FeedForward: Module {
    let linear1: Linear
    let linear2: Linear
    let activation: SiLU

    public init(dModel: Int, dFF: Int, useBias: Bool = true) {
        self.linear1 = Linear(dModel, dFF, bias: useBias)
        self.linear2 = Linear(dFF, dModel, bias: useBias)
        self.activation = SiLU()
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        return linear2(self.activation(linear1(x)))
    }
}

// MARK: - Convolution Module

@preconcurrency nonisolated public class ConformerConvolution: Module {
    let padding: Int
    let pointwiseConv1: Conv1d
    let depthwiseConv: Conv1d
    let batchNorm: BatchNorm
    let pointwiseConv2: Conv1d
    let activation: SiLU

    public init(config: ConformerConfig) {
        assert((config.convKernelSize - 1) % 2 == 0)

        self.padding = (config.convKernelSize - 1) / 2

        self.pointwiseConv1 = Conv1d(
            inputChannels: config.dModel,
            outputChannels: config.dModel * 2,
            kernelSize: 1,
            stride: 1,
            padding: 0,
            bias: config.useBias
        )

        self.depthwiseConv = Conv1d(
            inputChannels: config.dModel,
            outputChannels: config.dModel,
            kernelSize: config.convKernelSize,
            stride: 1,
            padding: 0,
            groups: config.dModel,
            bias: config.useBias
        )

        self.batchNorm = BatchNorm(featureCount: config.dModel)
        self.activation = SiLU()
        self.pointwiseConv2 = Conv1d(
            inputChannels: config.dModel,
            outputChannels: config.dModel,
            kernelSize: 1,
            stride: 1,
            padding: 0,
            bias: config.useBias
        )

        super.init()
    }

    public func callAsFunction(_ x: MLXArray, cache: ConformerCache? = nil) -> MLXArray {
        var x = x

        x = self.pointwiseConv1(x)
        x = MLXNN.glu(x, axis: 2)

        // Handle caching for convolution if provided
        if let cache = cache {
            x = cache.updateAndFetchConv(x, padding: padding)
        } else {
            // Match Python exactly: mx.pad(x, ((0, 0), (self.padding, self.padding), (0, 0)))
            x = MLX.padded(
                x,
                widths: [(0, 0), (padding, padding), (0, 0)].map { IntOrPair($0) },
                mode: .constant,
                value: MLXArray(0.0)
            )
        }

        x = depthwiseConv(x)
        x = batchNorm(x)
        x = self.activation(x)
        x = self.pointwiseConv2(x)

        return x
    }
}

// MARK: - Conformer Block

@preconcurrency nonisolated public class ConformerBlock: Module {
    let config: ConformerConfig
    let normFeedForward1: LayerNorm
    let feedForward1: FeedForward
    let normSelfAtt: LayerNorm
    var selfAttn: Module
    let normConv: LayerNorm
    let conv: ConformerConvolution
    let normFeedForward2: LayerNorm
    let feedForward2: FeedForward
    let normOut: LayerNorm

    public init(config: ConformerConfig) {
        self.config = config
        let ffHiddenDim = config.dModel * config.ffExpansionFactor

        self.normFeedForward1 = LayerNorm(dimensions: config.dModel)
        self.feedForward1 = FeedForward(
            dModel: config.dModel, dFF: ffHiddenDim, useBias: config.useBias)

        self.normSelfAtt = LayerNorm(dimensions: config.dModel)

        // Choose attention type based on configuration
        switch config.selfAttentionModel {
        case "rel_pos":
            self.selfAttn = RelPositionMultiHeadAttention(
                nHeads: config.nHeads,
                nFeat: config.dModel,
                bias: config.useBias,
                posBiasU: config.posBiasUArray(),
                posBiasV: config.posBiasVArray()
            )
        case "rel_pos_local_attn":
            let contextSize = config.attContextSize ?? [-1, -1]
            guard contextSize.count >= 2 else {
                fatalError("Invalid Context Size config")
            }
            self.selfAttn = RelPositionMultiHeadLocalAttention(
                nHeads: config.nHeads,
                nFeat: config.dModel,
                bias: config.useBias,
                posBiasU: config.posBiasUArray(),
                posBiasV: config.posBiasVArray(),
                contextSize: (contextSize[0], contextSize[1])
            )
        default:
            self.selfAttn = MultiHeadAttention(
                nHeads: config.nHeads,
                nFeat: config.dModel,
                bias: true
            )
        }

        self.normConv = LayerNorm(dimensions: config.dModel)
        self.conv = ConformerConvolution(config: config)

        self.normFeedForward2 = LayerNorm(dimensions: config.dModel)
        self.feedForward2 = FeedForward(
            dModel: config.dModel, dFF: ffHiddenDim, useBias: config.useBias)

        self.normOut = LayerNorm(dimensions: config.dModel)

        super.init()
    }

    public func callAsFunction(
        _ x: MLXArray,
        posEmb: MLXArray? = nil,
        mask: MLXArray? = nil,
        cache: ConformerCache? = nil
    ) -> MLXArray {

        var x = x

        // First feed forward
        x = x + 0.5 * feedForward1(normFeedForward1(x))

        // Self attention
        let xNorm = normSelfAtt(x)
        let attentionOut: MLXArray

        if let relAttn = selfAttn as? RelPositionMultiHeadAttention {
            attentionOut = relAttn(
                xNorm,
                xNorm,
                xNorm,
                posEmb: posEmb,
                mask: mask,
                cache: cache
            )
        } else if let localAttn = selfAttn as? RelPositionMultiHeadLocalAttention {
            attentionOut = localAttn(
                xNorm,
                xNorm,
                xNorm,
                posEmb: posEmb,
                mask: mask,
                cache: cache
            )
        } else if let standardAttn = selfAttn as? MultiHeadAttention {
            attentionOut = standardAttn(xNorm, xNorm, xNorm, mask: mask)
        } else {
            fatalError("Unknown attention type")
        }

        x = x + attentionOut

        // Convolution
        x = x + conv(normConv(x), cache: cache)

        // Second feed forward
        x = x + 0.5 * feedForward2(normFeedForward2(x))

        return normOut(x)
    }

    /// Set the attention model for this Conformer block.
    /// - Parameters:
    ///   - name: The attention type: "rel_pos", "rel_pos_local_attn", or "normal"
    ///   - contextSize: The context size for local attention (default: (256, 256))
    public func setAttentionModel(
        _ name: String,
        contextSize: (Int, Int)? = (256, 256)
    ) {
        let newAttn: Module

        switch name {
        case "rel_pos":
            newAttn = RelPositionMultiHeadAttention(
                nHeads: self.config.nHeads,
                nFeat: self.config.dModel,
                bias: self.config.useBias,
                posBiasU: self.config.posBiasUArray(),
                posBiasV: self.config.posBiasVArray()
            )
        case "rel_pos_local_attn":
            newAttn = RelPositionMultiHeadLocalAttention(
                nHeads: self.config.nHeads,
                nFeat: self.config.dModel,
                bias: self.config.useBias,
                posBiasU: self.config.posBiasUArray(),
                posBiasV: self.config.posBiasVArray(),
                contextSize: contextSize ?? (256, 256)
            )
        case "normal":
            newAttn = MultiHeadAttention(
                nHeads: self.config.nHeads,
                nFeat: self.config.dModel,
                bias: true
            )
        default:
            fatalError("Unknown attention model: \(name)")
        }

        // In MLX Swift, use update(parameters:) instead of load_weights()
        newAttn.update(parameters: self.selfAttn.parameters())

        self.selfAttn = newAttn
    }
}

// MARK: - Depth-wise Striding Subsampling

@preconcurrency nonisolated public class DwStridingSubsampling: Module {
    let subsamplingConvChunkingFactor: Int
    let convChannels: Int
    let samplingNum: Int
    let stride: Int
    let kernelSize: Int
    let padding: Int
    let conv: [Module]
    let out: Linear
    let finalFreqDim: Int

    public init(config: ConformerConfig) {
        assert(
            config.subsamplingFactor > 0
                && (config.subsamplingFactor & (config.subsamplingFactor - 1)) == 0)

        self.subsamplingConvChunkingFactor = config.subsamplingConvChunkingFactor
        self.convChannels = config.subsamplingConvChannels
        self.samplingNum = Int(log2(Double(config.subsamplingFactor)))
        self.stride = 2
        self.kernelSize = 3
        self.padding = (self.kernelSize - 1) / 2

        var inChannels = 1
        var finalFreqDim = config.featIn

        for _ in 0..<samplingNum {
            finalFreqDim =
                Int(floor(Double(finalFreqDim + 2 * padding - kernelSize) / Double(stride))) + 1
            if finalFreqDim < 1 {
                fatalError("Non-positive final frequency dimension!")
            }
        }

        var convLayers: [Module] = []

        // First conv layer
        convLayers.append(
            Conv2d(
                inputChannels: inChannels,
                outputChannels: convChannels,
                kernelSize: IntOrPair((kernelSize, kernelSize)),
                stride: IntOrPair((stride, stride)),
                padding: IntOrPair((padding, padding))
            ))
        convLayers.append(ReLU())

        inChannels = convChannels

        // Remaining conv layers
        for _ in 0..<(samplingNum - 1) {
            // Depthwise convolution - this matches the actual pretrained model weights
            convLayers.append(
                Conv2d(
                    inputChannels: inChannels,
                    outputChannels: inChannels,
                    kernelSize: IntOrPair((kernelSize, kernelSize)),
                    stride: IntOrPair((stride, stride)),
                    padding: IntOrPair((padding, padding)),
                    groups: inChannels  // Depthwise convolution
                ))

            // Pointwise convolution (1x1)
            convLayers.append(
                Conv2d(
                    inputChannels: inChannels,
                    outputChannels: convChannels,
                    kernelSize: IntOrPair((1, 1)),
                    stride: IntOrPair((1, 1)),
                    padding: IntOrPair((0, 0))
                ))

            convLayers.append(ReLU())
        }

        self.conv = convLayers
        self.out = Linear(convChannels * finalFreqDim, config.dModel)

        self.finalFreqDim = finalFreqDim

        super.init()
    }

    private func convForward(_ x: MLXArray) -> MLXArray {
        // Input is [batch, channels, time, features] after expandedDimensions
        // Conv2d expects NHWC: [batch, height, width, channels]
        // So transpose from [batch, channels, time, features] to [batch, time, features, channels]
        var x = x.transposed(axes: [0, 2, 3, 1])  // [batch, channels, time, features] -> [batch, time, features, channels]

        for (i, layer) in conv.enumerated() {
            if let convLayer = layer as? Conv2d {
                x = convLayer(x)
            } else if let reluLayer = layer as? ReLU {
                x = reluLayer(x)
            }

            let afterMax = x.max().item(Float.self)
            if afterMax.isInfinite || afterMax.isNaN {
                fatalError("DwStridingSubsampling layer \(i) produced -inf values")
            }
        }

        // Transpose back to [batch, channels, time, features] format
        x = x.transposed(axes: [0, 3, 1, 2])  // [batch, time, features, channels] -> [batch, channels, time, features]

        return x
    }

    public func callAsFunction(_ x: MLXArray, lengths: MLXArray) -> (MLXArray, MLXArray) {

        var lengths = lengths

        // Update lengths based on subsampling
        for _ in 0..<samplingNum {
            lengths = floor((lengths + Float(2 * padding - kernelSize)) / Float(stride)) + 1.0
        }
        lengths = lengths.asType(.int32)

        var x = x.expandedDimensions(axis: 1)  // Add channel dimension: [batch, 1, time, features]

        x = convForward(x)

        // Match Python exactly: x = x.swapaxes(1, 2).reshape(x.shape[0], x.shape[2], -1)
        // After convForward: x is [batch, channels, time, features]
        // swapaxes(1, 2) -> [batch, time, channels, features]
        x = x.swappedAxes(1, 2)  // [batch, channels, time, features] -> [batch, time, channels, features]
        let batchSize = x.shape[0]
        let timeSteps = x.shape[1]
        let featuresFlattened = x.shape[2] * x.shape[3]  // channels * features

        x = x.reshaped([batchSize, timeSteps, featuresFlattened])

        x = out(x)

        return (x, lengths)
    }
}

// MARK: - Positional Encoding (simplified implementations)

@preconcurrency nonisolated public class RelPositionalEncoding: Module {
    let dModel: Int
    var maxLen: Int
    let scaleInput: Bool
    var posEmb: MLXArray

    public init(dModel: Int, maxLen: Int, scaleInput: Bool = false) {
        assert(dModel % 2 == 0 && maxLen > 0, "dModel must be even and maxLen must be positive")

        self.dModel = dModel
        self.maxLen = maxLen
        self.scaleInput = scaleInput

        // Initialize positional embeddings properly - NOT zeros!
        self.posEmb = MLXArray.zeros([2 * maxLen - 1, dModel])

        super.init()

        // Calculate proper positional embeddings
        calculatePE()
    }

    internal func calculatePE() {
        // Create positions array: [maxLen-1, maxLen-2, ..., 1, 0, -1, ..., -(maxLen-1)]
        let positions = MLXArray(
            stride(from: maxLen - 1, through: -(maxLen - 1), by: -1).map(Float.init)
        )
        .expandedDimensions(axis: 1)

        // Calculate div_term = exp(-log(10000) * arange(0, d_model, 2) / d_model)
        let divTerm = exp(
            MLXArray(stride(from: 0, to: dModel, by: 2).map(Float.init))
                * (-log(10000.0) / Float(dModel))
        )

        let pe = MLXArray.zeros([2 * maxLen - 1, dModel])

        // pe[:, 0::2] = sin(positions * div_term)
        // pe[:, 1::2] = cos(positions * div_term)
        let sinValues = sin(matmul(positions, divTerm.expandedDimensions(axis: 0)))
        let cosValues = cos(matmul(positions, divTerm.expandedDimensions(axis: 0)))

        // Interleave sin and cos values
        for i in 0..<(dModel / 2) {
            pe[0..., 2 * i] = sinValues[0..., i]
            pe[0..., 2 * i + 1] = cosValues[0..., i]
        }

        self.posEmb = pe.expandedDimensions(axis: 0)  // Add batch dimension
        MLX.eval(self.posEmb)
    }

    public func callAsFunction(_ x: MLXArray, offset: Int = 0) -> (MLXArray, MLXArray) {
        var x = x
        let inputLen = x.shape[1] + offset

        // Scale input if needed
        if scaleInput {
            x = x * sqrt(Float(dModel))
        }

        // Check if we need to expand the positional embedding buffer (matching Python implementation)
        if inputLen > maxLen {
            maxLen = inputLen + 1
            calculatePE()
        }

        // Extract the relevant portion of positional embeddings
        let bufferLen = posEmb.shape[1]
        let startIdx = max(0, bufferLen / 2 - (inputLen - 1))
        let endIdx = min(bufferLen, bufferLen / 2 + (inputLen - 1) + 1)

        // Ensure we don't go out of bounds
        guard startIdx < bufferLen && endIdx <= bufferLen && startIdx < endIdx else {
            fatalError(
                "Positional encoding index out of bounds: startIdx=\(startIdx), endIdx=\(endIdx), bufferLen=\(bufferLen), inputLen=\(inputLen)"
            )
        }

        let posEmbSlice = posEmb[0..., startIdx..<endIdx].asType(x.dtype)

        return (x, posEmbSlice)
    }
}

@preconcurrency nonisolated public class LocalRelPositionalEncoding: RelPositionalEncoding {
    let leftContext: Int
    let rightContext: Int

    public init(
        dModel: Int, maxLen: Int, scaleInput: Bool = false, contextSize: (Int, Int) = (256, 256)
    ) {
        self.leftContext = contextSize.0
        self.rightContext = contextSize.1
        super.init(dModel: dModel, maxLen: maxLen, scaleInput: scaleInput)
    }

    override func calculatePE() {
        // For local attention, positions range from leftContext to -rightContext
        let positions = MLXArray(
            stride(from: leftContext, through: -rightContext, by: -1).map(Float.init)
        )
        .expandedDimensions(axis: 1)

        // Calculate div_term = exp(-log(10000) * arange(0, d_model, 2) / d_model)
        let divTerm = exp(
            MLXArray(stride(from: 0, to: dModel, by: 2).map(Float.init))
                * (-log(10000.0) / Float(dModel))
        )

        let pe = MLXArray.zeros([leftContext + rightContext + 1, dModel])

        // pe[:, 0::2] = sin(positions * div_term)
        // pe[:, 1::2] = cos(positions * div_term)
        let sinValues = sin(matmul(positions, divTerm.expandedDimensions(axis: 0)))
        let cosValues = cos(matmul(positions, divTerm.expandedDimensions(axis: 0)))

        // Interleave sin and cos values
        for i in 0..<(dModel / 2) {
            pe[0..., 2 * i] = sinValues[0..., i]
            pe[0..., 2 * i + 1] = cosValues[0..., i]
        }

        self.posEmb = pe.expandedDimensions(axis: 0)  // Add batch dimension
        MLX.eval(self.posEmb)
    }

    public override func callAsFunction(_ x: MLXArray, offset: Int = 0) -> (MLXArray, MLXArray) {
        var x = x

        // Scale input if needed
        if scaleInput {
            x = x * sqrt(Float(dModel))
        }

        // For local attention, use the entire positional embedding buffer
        let endIdx = leftContext + rightContext + 1
        let posEmbSlice = posEmb[0..., 0..<endIdx].asType(x.dtype)

        return (x, posEmbSlice)
    }
}

@preconcurrency nonisolated public class Conformer: Module {
    let config: ConformerConfig
    let posEnc: Module?
    let preEncode: Module
    let layers: [ConformerBlock]

    public init(config: ConformerConfig) {
        self.config = config

        // Initialize positional encoding based on attention model
        switch config.selfAttentionModel {
        case "rel_pos":
            self.posEnc = RelPositionalEncoding(
                dModel: config.dModel,
                maxLen: config.posEmbMaxLen,
                scaleInput: config.xscaling
            )
        case "rel_pos_local_attn":
            self.posEnc = LocalRelPositionalEncoding(
                dModel: config.dModel,
                maxLen: config.posEmbMaxLen,
                scaleInput: config.xscaling
            )
        default:
            self.posEnc = nil
        }

        // Initialize pre-encoding layer
        if config.subsamplingFactor > 1 {
            if config.subsampling == "dw_striding" && !config.causalDownsampling {
                self.preEncode = DwStridingSubsampling(config: config)
            } else {
                fatalError("Other subsampling methods not implemented yet!")
            }
        } else {
            self.preEncode = Linear(config.featIn, config.dModel)
        }

        // Initialize conformer blocks
        self.layers = (0..<config.nLayers).map { _ in ConformerBlock(config: config) }

        super.init()
    }

    public func callAsFunction(
        _ x: MLXArray,
        lengths: MLXArray? = nil,
        cache: [ConformerCache?]? = nil
    ) -> (MLXArray, MLXArray) {

        let actualLengths = lengths ?? MLXArray(Array(repeating: x.shape[1], count: x.shape[0]))
        let actualCache = cache ?? Array(repeating: nil, count: layers.count)

        var x = x
        var outLengths = actualLengths

        // Pre-encoding
        if let dwSubsampling = preEncode as? DwStridingSubsampling {
            (x, outLengths) = dwSubsampling(x, lengths: actualLengths)
        } else if let linear = preEncode as? Linear {
            x = linear(x)
        } else {
            fatalError("Non-implemented pre-encoding layer type!")
        }

        // Positional encoding
        var posEmb: MLXArray?
        if let posEncLayer = posEnc as? RelPositionalEncoding {
            let offset = actualCache[0]?.offset ?? 0
            (x, posEmb) = posEncLayer(x, offset: offset)
        } else if let localPosEncLayer = posEnc as? LocalRelPositionalEncoding {
            let offset = actualCache[0]?.offset ?? 0
            (x, posEmb) = localPosEncLayer(x, offset: offset)
        }

        // Apply conformer blocks
        for (_, (layer, cache)) in zip(layers, actualCache).enumerated() {
            x = layer(x, posEmb: posEmb, cache: cache)
            let xAfter = x.max().item(Float.self)

            if xAfter.isInfinite {
                break
            }
        }

        return (x, outLengths)
    }

    public func setAttentionModel(
        _ name: String,
        contextSize: (Int, Int)? = (256, 256)
    ) {
        // Update positional encoding
        switch name {
        case "rel_pos":
            // Would need to replace posEnc with RelPositionalEncoding
            break
        case "rel_pos_local_attn":
            // Would need to replace posEnc with LocalRelPositionalEncoding
            break
        default:
            // Set to no positional encoding
            break
        }

        // Update attention in all layers
        for layer in layers {
            layer.setAttentionModel(name, contextSize: contextSize)
        }
    }
}

// MARK: - Cache Classes (simplified)

nonisolated public class ConformerCache {
    public var offset: Int = 0

    public init() {}

    public func updateAndFetchConv(_ x: MLXArray, padding: Int) -> MLXArray {
        // Simplified cache implementation
        let padArray = Array(repeating: (0, 0), count: x.ndim)
        var padArray2 = padArray
        padArray2[1] = (padding, padding)
        return MLX.padded(
            x, widths: padArray2.map { IntOrPair($0) }, mode: .constant, value: MLXArray(0.0))
    }
}

nonisolated public class RotatingConformerCache: ConformerCache {
    let contextSize: Int
    let cacheDropSize: Int

    public init(contextSize: Int, cacheDropSize: Int) {
        self.contextSize = contextSize
        self.cacheDropSize = cacheDropSize
        super.init()
    }
}

// MARK: - Utility Functions

nonisolated private func floor(_ x: MLXArray) -> MLXArray {
    return MLX.floor(x)
}

nonisolated private func sin(_ x: MLXArray) -> MLXArray {
    return MLX.sin(x)
}

nonisolated private func cos(_ x: MLXArray) -> MLXArray {
    return MLX.cos(x)
}

nonisolated private func exp(_ x: MLXArray) -> MLXArray {
    return MLX.exp(x)
}

nonisolated private func log(_ x: Float) -> Float {
    return Foundation.log(x)
}

nonisolated private func sqrt(_ x: Float) -> Float {
    return Foundation.sqrt(x)
}

nonisolated private func matmul(_ a: MLXArray, _ b: MLXArray) -> MLXArray {
    return MLX.matmul(a, b)
}
#endif
