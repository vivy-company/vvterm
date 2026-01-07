import Foundation

struct MLXModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let sizeLabel: String
    let precisionLabel: String
    let languageLabel: String?
    let isPrimary: Bool
    let kind: MLXModelKind
}

enum MLXModelCatalog {
    static let whisperPresets: [MLXModelOption] = [
        MLXModelOption(
            id: "mlx-community/whisper-tiny-mlx",
            title: "Tiny",
            summary: "Fastest, smallest",
            sizeLabel: "Tiny",
            precisionLabel: "Full precision",
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-tiny.en-mlx",
            title: "Tiny (EN)",
            summary: "English-only, smaller",
            sizeLabel: "Tiny",
            precisionLabel: "Full precision",
            languageLabel: "English-only",
            isPrimary: false,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-base-mlx",
            title: "Base",
            summary: "Balanced speed/quality",
            sizeLabel: "Base",
            precisionLabel: "Full precision",
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-small-mlx",
            title: "Small",
            summary: "Better accuracy",
            sizeLabel: "Small",
            precisionLabel: "Full precision",
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-medium-mlx",
            title: "Medium",
            summary: "Higher accuracy, heavier",
            sizeLabel: "Medium",
            precisionLabel: "Full precision",
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-large-v3-mlx",
            title: "Large v3",
            summary: "Latest large model",
            sizeLabel: "Large",
            precisionLabel: "Full precision",
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-large-v3-mlx-4bit",
            title: "Large v3 4-bit",
            summary: "Smaller download",
            sizeLabel: "Large",
            precisionLabel: "4-bit quantized",
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        )
    ]

    static let parakeetPresets: [MLXModelOption] = [
        MLXModelOption(
            id: "mlx-community/parakeet-tdt-0.6b-v2",
            title: "Parakeet TDT 0.6B v2",
            summary: "Large, high-accuracy model",
            sizeLabel: "Large",
            precisionLabel: "Full precision",
            languageLabel: nil,
            isPrimary: true,
            kind: .parakeetTDT
        )
    ]

    static func option(for modelId: String, kind: MLXModelKind) -> MLXModelOption? {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return allOptions.first { $0.kind == kind && $0.id == normalized }
    }

    static var allOptions: [MLXModelOption] {
        whisperPresets + parakeetPresets
    }
}
