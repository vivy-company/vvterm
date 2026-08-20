import Foundation

nonisolated enum MLXModelStorageSizeFormatter {
    static func string(
        fromByteCount byteCount: Int64,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let bytes = max(byteCount, 0)
        let value: Double
        let unit: UnitInformationStorage

        switch bytes {
        case 1_000_000_000...:
            value = Double(bytes) / 1_000_000_000
            unit = .gigabytes
        case 1_000_000...:
            value = Double(bytes) / 1_000_000
            unit = .megabytes
        case 1_000...:
            value = Double(bytes) / 1_000
            unit = .kilobytes
        default:
            value = Double(bytes)
            unit = .bytes
        }

        let style = Measurement<UnitInformationStorage>.FormatStyle(
            width: .abbreviated,
            numberFormatStyle: .number.precision(.fractionLength(0))
        )
        .locale(locale)

        return Measurement(value: value, unit: unit).formatted(style)
    }
}

nonisolated struct MLXModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: MLXModelKind

    var expectedDownloadBytes: Int64? {
        MLXModelCatalog.downloadManifest(for: id, kind: kind)?.expectedBytes
    }

    var downloadSizeLabel: String {
        guard let expectedDownloadBytes else { return "" }
        return MLXModelStorageSizeFormatter.string(fromByteCount: expectedDownloadBytes)
    }
}

nonisolated enum MLXModelCatalog {
    static let whisperPresets: [MLXModelOption] = [
        MLXModelOption(
            id: "mlx-community/whisper-tiny-mlx",
            title: String(localized: "Tiny"),
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-tiny.en-mlx",
            title: String(localized: "Tiny (EN)"),
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-base-mlx",
            title: String(localized: "Base"),
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-small-mlx",
            title: String(localized: "Small"),
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-medium-mlx",
            title: String(localized: "Medium"),
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-large-v3-mlx",
            title: String(localized: "Large v3"),
            kind: .whisper
        ),
        MLXModelOption(
            id: "mlx-community/whisper-large-v3-mlx-4bit",
            title: String(localized: "Large v3 4-bit"),
            kind: .whisper
        )
    ]

    static let parakeetPresets: [MLXModelOption] = [
        MLXModelOption(
            id: "mlx-community/parakeet-tdt-0.6b-v2",
            title: String(localized: "Parakeet TDT 0.6B v2"),
            kind: .parakeetTDT
        )
    ]

    static func option(for modelId: String, kind: MLXModelKind) -> MLXModelOption? {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return allOptions.first { $0.kind == kind && $0.id == normalized }
    }

    static func options(for kind: MLXModelKind) -> [MLXModelOption] {
        allOptions.filter { $0.kind == kind }
    }

    static func defaultModelID(for kind: MLXModelKind) -> String {
        switch kind {
        case .whisper:
            return "mlx-community/whisper-tiny-mlx"
        case .parakeetTDT:
            return "mlx-community/parakeet-tdt-0.6b-v2"
        }
    }

    static var allOptions: [MLXModelOption] {
        whisperPresets + parakeetPresets
    }
}
