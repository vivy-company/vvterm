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
            title: String(localized: "Tiny"),
            summary: String(localized: "Fastest, smallest"),
            sizeLabel: String(localized: "Tiny"),
            precisionLabel: String(localized: "Full precision"),
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-tiny.en-mlx",
            title: String(localized: "Tiny (EN)"),
            summary: String(localized: "English-only, smaller"),
            sizeLabel: String(localized: "Tiny"),
            precisionLabel: String(localized: "Full precision"),
            languageLabel: String(localized: "English-only"),
            isPrimary: false,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-base-mlx",
            title: String(localized: "Base"),
            summary: String(localized: "Balanced speed/quality"),
            sizeLabel: String(localized: "Base"),
            precisionLabel: String(localized: "Full precision"),
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-small-mlx",
            title: String(localized: "Small"),
            summary: String(localized: "Better accuracy"),
            sizeLabel: String(localized: "Small"),
            precisionLabel: String(localized: "Full precision"),
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-medium-mlx",
            title: String(localized: "Medium"),
            summary: String(localized: "Higher accuracy, heavier"),
            sizeLabel: String(localized: "Medium"),
            precisionLabel: String(localized: "Full precision"),
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-large-v3-mlx",
            title: String(localized: "Large v3"),
            summary: String(localized: "Latest large model"),
            sizeLabel: String(localized: "Large"),
            precisionLabel: String(localized: "Full precision"),
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-large-v3-mlx-4bit",
            title: String(localized: "Large v3 4-bit"),
            summary: String(localized: "Smaller download"),
            sizeLabel: String(localized: "Large"),
            precisionLabel: String(localized: "4-bit quantized"),
            languageLabel: nil,
            isPrimary: true,
            kind: .whisper
        )
    ]

    static let parakeetPresets: [MLXModelOption] = [
        MLXModelOption(
            id: "mlx-community/parakeet-tdt-0.6b-v2",
            title: String(localized: "Parakeet TDT 0.6B v2"),
            summary: String(localized: "Large, high-accuracy model"),
            sizeLabel: String(localized: "Large"),
            precisionLabel: String(localized: "Full precision"),
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
