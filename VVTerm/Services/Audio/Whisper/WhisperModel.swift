import Foundation
#if arch(arm64)
import MLX
import MLXNN

nonisolated struct WhisperModelDimensions: Codable {
    let n_mels: Int
    let n_audio_ctx: Int
    let n_audio_state: Int
    let n_audio_head: Int
    let n_audio_layer: Int
    let n_vocab: Int
    let n_text_ctx: Int
    let n_text_state: Int
    let n_text_head: Int
    let n_text_layer: Int
}

nonisolated struct WhisperKVCache {
    let key: MLXArray
    let value: MLXArray
}

nonisolated struct WhisperBlockCache {
    var selfKV: WhisperKVCache?
    var crossKV: WhisperKVCache?
}

nonisolated final class WhisperMultiHeadAttention: Module {
    let nHead: Int
    let query: Linear
    let key: Linear
    let value: Linear
    let out: Linear

    init(nState: Int, nHead: Int) {
        self.nHead = nHead
        self.query = Linear(nState, nState)
        self.key = Linear(nState, nState, bias: false)
        self.value = Linear(nState, nState)
        self.out = Linear(nState, nState)
        super.init()
    }

    override func items() -> ModuleItems {
        NestedDictionary(values: [
            "query": .value(.module(query)),
            "key": .value(.module(key)),
            "value": .value(.module(value)),
            "out": .value(.module(out))
        ])
    }

    func callAsFunction(
        _ x: MLXArray,
        xa: MLXArray? = nil,
        mask: MLXArray? = nil,
        kvCache: WhisperKVCache? = nil
    ) -> (MLXArray, WhisperKVCache) {
        let q = query(x)
        var k: MLXArray
        var v: MLXArray

        if let xa {
            if let kvCache {
                k = kvCache.key
                v = kvCache.value
            } else {
                k = key(xa)
                v = value(xa)
            }
        } else {
            k = key(x)
            v = value(x)
            if let kvCache {
                k = concatenated([kvCache.key, k], axis: 1)
                v = concatenated([kvCache.value, v], axis: 1)
            }
        }

        let (wv, _) = qkvAttention(q: q, k: k, v: v, mask: mask)
        let output = out(wv)
        return (output, WhisperKVCache(key: k, value: v))
    }

    private func qkvAttention(q: MLXArray, k: MLXArray, v: MLXArray, mask: MLXArray?) -> (MLXArray, MLXArray) {
        let batch = q.dim(0)
        let nCtx = q.dim(1)
        let nState = q.dim(2)
        let headDim = nState / nHead

        let scale = pow(Float(headDim), -0.25)
        let q = q.reshaped(batch, nCtx, nHead, headDim).transposed(0, 2, 1, 3) * scale
        let k = k.reshaped(batch, k.dim(1), nHead, headDim).transposed(0, 2, 3, 1) * scale
        let v = v.reshaped(batch, v.dim(1), nHead, headDim).transposed(0, 2, 1, 3)

        var qk = matmul(q, k)
        if let mask {
            let maskSlice = mask[0 ..< nCtx, 0 ..< nCtx]
            qk = qk + maskSlice
        }

        let w = softmax(qk, axis: -1, precise: true)
        let out = matmul(w, v).transposed(0, 2, 1, 3).reshaped(batch, nCtx, nState)
        return (out, qk)
    }
}

nonisolated final class WhisperEncoderBlock: Module {
    let attn: WhisperMultiHeadAttention
    let attnLn: LayerNorm
    let mlp1: Linear
    let mlp2: Linear
    let mlpLn: LayerNorm

    init(nState: Int, nHead: Int) {
        self.attn = WhisperMultiHeadAttention(nState: nState, nHead: nHead)
        self.attnLn = LayerNorm(dimensions: nState)
        self.mlp1 = Linear(nState, nState * 4)
        self.mlp2 = Linear(nState * 4, nState)
        self.mlpLn = LayerNorm(dimensions: nState)
        super.init()
    }

    override func items() -> ModuleItems {
        NestedDictionary(values: [
            "attn": .value(.module(attn)),
            "attn_ln": .value(.module(attnLn)),
            "mlp1": .value(.module(mlp1)),
            "mlp2": .value(.module(mlp2)),
            "mlp_ln": .value(.module(mlpLn))
        ])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        let (y, _) = attn(attnLn(x), mask: nil, kvCache: nil)
        x = x + y
        x = x + mlp2(gelu(mlp1(mlpLn(x))))
        return x
    }
}

nonisolated final class WhisperDecoderBlock: Module {
    let attn: WhisperMultiHeadAttention
    let attnLn: LayerNorm
    let crossAttn: WhisperMultiHeadAttention
    let crossAttnLn: LayerNorm
    let mlp1: Linear
    let mlp2: Linear
    let mlpLn: LayerNorm

    init(nState: Int, nHead: Int) {
        self.attn = WhisperMultiHeadAttention(nState: nState, nHead: nHead)
        self.attnLn = LayerNorm(dimensions: nState)
        self.crossAttn = WhisperMultiHeadAttention(nState: nState, nHead: nHead)
        self.crossAttnLn = LayerNorm(dimensions: nState)
        self.mlp1 = Linear(nState, nState * 4)
        self.mlp2 = Linear(nState * 4, nState)
        self.mlpLn = LayerNorm(dimensions: nState)
        super.init()
    }

    override func items() -> ModuleItems {
        NestedDictionary(values: [
            "attn": .value(.module(attn)),
            "attn_ln": .value(.module(attnLn)),
            "cross_attn": .value(.module(crossAttn)),
            "cross_attn_ln": .value(.module(crossAttnLn)),
            "mlp1": .value(.module(mlp1)),
            "mlp2": .value(.module(mlp2)),
            "mlp_ln": .value(.module(mlpLn))
        ])
    }

    func callAsFunction(
        _ x: MLXArray,
        xa: MLXArray,
        mask: MLXArray?,
        cache: WhisperBlockCache?
    ) -> (MLXArray, WhisperBlockCache) {
        var x = x
        let selfCache = cache?.selfKV
        let (selfAttn, newSelfCache) = attn(attnLn(x), mask: mask, kvCache: selfCache)
        x = x + selfAttn

        let crossCache = cache?.crossKV
        let (crossAttnOut, newCrossCache) = crossAttn(crossAttnLn(x), xa: xa, mask: nil, kvCache: crossCache)
        x = x + crossAttnOut

        x = x + mlp2(gelu(mlp1(mlpLn(x))))
        return (x, WhisperBlockCache(selfKV: newSelfCache, crossKV: newCrossCache))
    }
}

nonisolated final class WhisperAudioEncoder: Module {
    let conv1: Conv1d
    let conv2: Conv1d
    let positionalEmbedding: MLXArray
    let blocks: [WhisperEncoderBlock]
    let lnPost: LayerNorm

    init(dims: WhisperModelDimensions) {
        self.conv1 = Conv1d(inputChannels: dims.n_mels, outputChannels: dims.n_audio_state, kernelSize: 3, padding: 1)
        self.conv2 = Conv1d(inputChannels: dims.n_audio_state, outputChannels: dims.n_audio_state, kernelSize: 3, stride: 2, padding: 1)
        self.positionalEmbedding = WhisperModel.sinusoids(length: dims.n_audio_ctx, channels: dims.n_audio_state)
            .asType(.float16)
        self.blocks = (0 ..< dims.n_audio_layer).map { _ in
            WhisperEncoderBlock(nState: dims.n_audio_state, nHead: dims.n_audio_head)
        }
        self.lnPost = LayerNorm(dimensions: dims.n_audio_state)
        super.init()
    }

    override func items() -> ModuleItems {
        let blockItems = blocks.map { NestedItem<String, ModuleValue>.value(.module($0)) }
        return NestedDictionary(values: [
            "conv1": .value(.module(conv1)),
            "conv2": .value(.module(conv2)),
            "blocks": .array(blockItems),
            "ln_post": .value(.module(lnPost))
        ])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = gelu(conv1(x))
        x = gelu(conv2(x))
        x = x + positionalEmbedding

        for block in blocks {
            x = block(x)
        }

        return lnPost(x)
    }
}

nonisolated final class WhisperTextDecoder: Module {
    let tokenEmbedding: Embedding
    let positionalEmbedding: MLXArray
    let blocks: [WhisperDecoderBlock]
    let ln: LayerNorm
    let mask: MLXArray

    init(dims: WhisperModelDimensions, dtype: DType) {
        self.tokenEmbedding = Embedding(embeddingCount: dims.n_vocab, dimensions: dims.n_text_state)
        self.positionalEmbedding = MLXArray.zeros([dims.n_text_ctx, dims.n_text_state], dtype: dtype)
        self.blocks = (0 ..< dims.n_text_layer).map { _ in
            WhisperDecoderBlock(nState: dims.n_text_state, nHead: dims.n_text_head)
        }
        self.ln = LayerNorm(dimensions: dims.n_text_state)
        self.mask = MLXNN.MultiHeadAttention.createAdditiveCausalMask(dims.n_text_ctx, dtype: dtype)
        super.init()
    }

    override func items() -> ModuleItems {
        let blockItems = blocks.map { NestedItem<String, ModuleValue>.value(.module($0)) }
        return NestedDictionary(values: [
            "token_embedding": .value(.module(tokenEmbedding)),
            "positional_embedding": .value(.parameters(positionalEmbedding)),
            "blocks": .array(blockItems),
            "ln": .value(.module(ln))
        ])
    }

    func callAsFunction(
        _ tokens: MLXArray,
        audioFeatures: MLXArray,
        kvCache: [WhisperBlockCache]?
    ) -> (MLXArray, [WhisperBlockCache]) {
        let offset: Int
        if let cache = kvCache, let first = cache.first, let key = first.selfKV?.key {
            offset = key.dim(1)
        } else {
            offset = 0
        }

        let length = tokens.dim(1)
        let posSlice = positionalEmbedding[offset ..< (offset + length), .ellipsis]
        var x = tokenEmbedding(tokens) + posSlice

        let cache = kvCache ?? Array(repeating: WhisperBlockCache(), count: blocks.count)
        var newCache: [WhisperBlockCache] = []
        newCache.reserveCapacity(blocks.count)

        for (index, block) in blocks.enumerated() {
            let (y, updated) = block(x, xa: audioFeatures, mask: mask, cache: cache[index])
            x = y
            newCache.append(updated)
        }

        x = ln(x)
        let logits = tokenEmbedding.asLinear(x)
        return (logits, newCache)
    }
}

nonisolated final class WhisperModel: Module {
    let dims: WhisperModelDimensions
    let encoder: WhisperAudioEncoder
    let decoder: WhisperTextDecoder

    init(dims: WhisperModelDimensions, dtype: DType) {
        self.dims = dims
        self.encoder = WhisperAudioEncoder(dims: dims)
        self.decoder = WhisperTextDecoder(dims: dims, dtype: dtype)
        super.init()
    }

    override func items() -> ModuleItems {
        NestedDictionary(values: [
            "encoder": .value(.module(encoder)),
            "decoder": .value(.module(decoder))
        ])
    }

    static func sinusoids(length: Int, channels: Int, maxTimescale: Double = 10_000) -> MLXArray {
        precondition(channels % 2 == 0)
        let half = channels / 2
        let logIncrement = log(maxTimescale) / Double(half - 1)
        let invTimescales = exp(-MLXArray(0 ..< half).asType(.float32) * Float(logIncrement))
        let scaledTime = MLXArray(0 ..< length).asType(.float32).reshaped(length, 1) * invTimescales.reshaped(1, half)
        let sinValues = MLX.sin(scaledTime)
        let cosValues = MLX.cos(scaledTime)
        return concatenated([sinValues, cosValues], axis: 1)
    }

    var isMultilingual: Bool { dims.n_vocab >= 51865 }
}
#endif
