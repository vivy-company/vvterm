import XCTest
@testable import VVTerm

#if arch(arm64)
final class MLXModelConfigurationValidatorTests: XCTestCase {
    func testValidWhisperDimensionsPass() throws {
        try MLXModelConfigurationValidator.validateWhisper(validWhisperDimensions())
    }

    func testWhisperRejectsInvalidAttentionAndSinusoidDimensions() {
        let zeroHeads = WhisperModelDimensions(
            n_mels: 80,
            n_audio_ctx: 1_500,
            n_audio_state: 384,
            n_audio_head: 0,
            n_audio_layer: 4,
            n_vocab: 51_865,
            n_text_ctx: 448,
            n_text_state: 384,
            n_text_head: 6,
            n_text_layer: 4
        )
        XCTAssertThrowsError(try MLXModelConfigurationValidator.validateWhisper(zeroHeads))

        let oddState = WhisperModelDimensions(
            n_mels: 80,
            n_audio_ctx: 1_500,
            n_audio_state: 383,
            n_audio_head: 1,
            n_audio_layer: 4,
            n_vocab: 51_865,
            n_text_ctx: 448,
            n_text_state: 384,
            n_text_head: 6,
            n_text_layer: 4
        )
        XCTAssertThrowsError(try MLXModelConfigurationValidator.validateWhisper(oddState))
    }

    func testWhisperRejectsNondivisibleAndOversizedDimensions() {
        let nondivisible = WhisperModelDimensions(
            n_mels: 80,
            n_audio_ctx: 1_500,
            n_audio_state: 384,
            n_audio_head: 5,
            n_audio_layer: 4,
            n_vocab: 51_865,
            n_text_ctx: 448,
            n_text_state: 384,
            n_text_head: 6,
            n_text_layer: 4
        )
        XCTAssertThrowsError(try MLXModelConfigurationValidator.validateWhisper(nondivisible))

        let oversized = WhisperModelDimensions(
            n_mels: 80,
            n_audio_ctx: 1_500,
            n_audio_state: 16_384,
            n_audio_head: 16,
            n_audio_layer: 256,
            n_vocab: 1_000_000,
            n_text_ctx: 448,
            n_text_state: 16_384,
            n_text_head: 16,
            n_text_layer: 256
        )
        XCTAssertThrowsError(try MLXModelConfigurationValidator.validateWhisper(oversized))
    }

    func testKnownParakeetConfigurationPasses() throws {
        let config = try decodeParakeet(durations: [0, 1, 2, 3, 4])

        try MLXModelConfigurationValidator.validateParakeet(config)
    }

    func testParakeetRejectsUnsafeDurationTables() throws {
        XCTAssertThrowsError(
            try MLXModelConfigurationValidator.validateParakeet(
                decodeParakeet(durations: [])
            )
        )
        XCTAssertThrowsError(
            try MLXModelConfigurationValidator.validateParakeet(
                decodeParakeet(durations: [0, 0, 0, 0, 0])
            )
        )
        XCTAssertThrowsError(
            try MLXModelConfigurationValidator.validateParakeet(
                decodeParakeet(durations: [-1, 1, 2, 3, 4])
            )
        )
        XCTAssertThrowsError(
            try MLXModelConfigurationValidator.validateParakeet(
                decodeParakeet(durations: [0, 1, 2, 3, 1_025])
            )
        )
    }

    func testParakeetRejectsFormerFatalConfigurationPaths() throws {
        var localAttention = try parakeetJSONObject(durations: [0, 1, 2, 3, 4])
        var encoder = try XCTUnwrap(localAttention["encoder"] as? [String: Any])
        encoder["self_attention_model"] = "rel_pos_local_attn"
        encoder["att_context_size"] = [1]
        localAttention["encoder"] = encoder
        XCTAssertThrowsError(
            try MLXModelConfigurationValidator.validateParakeet(
                decodeParakeet(localAttention)
            )
        )

        var collapsed = try parakeetJSONObject(durations: [0, 1, 2, 3, 4])
        encoder = try XCTUnwrap(collapsed["encoder"] as? [String: Any])
        encoder["feat_in"] = 0
        encoder["subsampling_factor"] = 8
        collapsed["encoder"] = encoder
        var preprocessor = try XCTUnwrap(collapsed["preprocessor"] as? [String: Any])
        preprocessor["features"] = 0
        collapsed["preprocessor"] = preprocessor
        XCTAssertThrowsError(
            try MLXModelConfigurationValidator.validateParakeet(
                decodeParakeet(collapsed)
            )
        )

        var unsupportedSubsampling = try parakeetJSONObject(durations: [0, 1, 2, 3, 4])
        encoder = try XCTUnwrap(unsupportedSubsampling["encoder"] as? [String: Any])
        encoder["subsampling"] = "stacking"
        unsupportedSubsampling["encoder"] = encoder
        XCTAssertThrowsError(
            try MLXModelConfigurationValidator.validateParakeet(
                decodeParakeet(unsupportedSubsampling)
            )
        )
    }

    private func validWhisperDimensions() -> WhisperModelDimensions {
        WhisperModelDimensions(
            n_mels: 80,
            n_audio_ctx: 1_500,
            n_audio_state: 384,
            n_audio_head: 6,
            n_audio_layer: 4,
            n_vocab: 51_865,
            n_text_ctx: 448,
            n_text_state: 384,
            n_text_head: 6,
            n_text_layer: 4
        )
    }

    private func decodeParakeet(durations: [Int]) throws -> ParakeetTDTConfig {
        try decodeParakeet(parakeetJSONObject(durations: durations))
    }

    private func decodeParakeet(_ object: [String: Any]) throws -> ParakeetTDTConfig {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ParakeetTDTConfig.self, from: data)
    }

    private func parakeetJSONObject(durations: [Int]) throws -> [String: Any] {
        [
            "preprocessor": [
                "sample_rate": 16_000,
                "normalize": "per_feature",
                "window_size": 0.025,
                "window_stride": 0.01,
                "window": "hann",
                "features": 128,
                "n_fft": 512,
                "dither": 0.00001,
                "pad_to": 0,
                "pad_value": 0.0
            ],
            "encoder": [
                "feat_in": 128,
                "n_layers": 24,
                "d_model": 1_024,
                "n_heads": 8,
                "ff_expansion_factor": 4,
                "subsampling_factor": 8,
                "self_attention_model": "rel_pos",
                "subsampling": "dw_striding",
                "conv_kernel_size": 9,
                "subsampling_conv_channels": 256,
                "pos_emb_max_len": 5_000,
                "att_context_size": [-1, -1]
            ],
            "decoder": [
                "blank_as_pad": true,
                "vocab_size": 1_024,
                "prednet": [
                    "pred_hidden": 640,
                    "pred_rnn_layers": 2
                ]
            ],
            "joint": [
                "num_classes": 1_024,
                "vocabulary": (0..<1_024).map { "token-\($0)" },
                "jointnet": [
                    "joint_hidden": 640,
                    "activation": "relu",
                    "encoder_hidden": 1_024,
                    "pred_hidden": 640
                ],
                "num_extra_outputs": durations.count
            ],
            "decoding": [
                "model_type": "tdt",
                "durations": durations,
                "greedy": ["max_symbols": 10]
            ]
        ]
    }
}
#endif
