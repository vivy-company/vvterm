import Foundation

extension TerminalThemeValidationError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .emptyContent:
            return String(localized: "Theme content is empty.")
        case .invalidLine(let line):
            return String(
                format: String(localized: "Invalid theme line %lld. Expected key/value format."),
                Int64(line)
            )
        case .invalidHex(let line):
            return String(
                format: String(localized: "Invalid hex color at line %lld. Use #RRGGBB."),
                Int64(line)
            )
        case .invalidPalette(let line):
            return String(
                format: String(localized: "Invalid palette value at line %lld. Expected N=#RRGGBB where N is 0...255."),
                Int64(line)
            )
        case .invalidValue(let line, let key):
            return String(
                format: String(localized: "Invalid value for theme key at line %1$lld: %2$@."),
                Int64(line),
                key
            )
        case .unsupportedKey(let line, let key):
            return String(
                format: String(localized: "Unsupported theme key at line %1$lld: %2$@."),
                Int64(line),
                key
            )
        case .missingRequiredKey(let key):
            return String(
                format: String(localized: "Theme is missing required key: %@."),
                key
            )
        case .invalidName:
            return String(localized: "Theme name contains invalid characters.")
        case .themeNotFound:
            return String(localized: "Theme no longer exists.")
        }
    }
}
