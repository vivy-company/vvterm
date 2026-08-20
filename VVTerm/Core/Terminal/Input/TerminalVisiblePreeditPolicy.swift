import Foundation

nonisolated enum TerminalVisiblePreeditPolicy {
    static func isDictationInputMode(_ inputModePrimaryLanguage: String?) -> Bool {
        inputModePrimaryLanguage?.lowercased() == "dictation"
    }

    static func shouldDisplay(_ text: String, inputModePrimaryLanguage: String?) -> Bool {
        let normalized = text.precomposedStringWithCanonicalMapping
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if isDictationInputMode(inputModePrimaryLanguage) {
            // Show in-progress dictation text regardless of script so the user
            // gets live feedback while the buffer is still revisable.
            return true
        }

        if containsNativePreeditScript(in: normalized) {
            return true
        }

        guard allowsRomanizedPreedit(for: inputModePrimaryLanguage) else {
            return false
        }

        return normalized.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                scalar == "'" ||
                scalar == "-"
        }
    }

    private static func allowsRomanizedPreedit(for inputModePrimaryLanguage: String?) -> Bool {
        guard let normalizedLanguage = inputModePrimaryLanguage?.lowercased() else { return false }
        return normalizedLanguage.hasPrefix("zh") || normalizedLanguage.hasPrefix("ja")
    }

    private static func containsNativePreeditScript(in text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1100...0x11FF,   // Hangul Jamo
                 0x3130...0x318F,   // Hangul Compatibility Jamo
                 0xA960...0xA97F,   // Hangul Jamo Extended-A
                 0xAC00...0xD7AF,   // Hangul Syllables
                 0xD7B0...0xD7FF,   // Hangul Jamo Extended-B
                 0x3040...0x309F,   // Hiragana
                 0x30A0...0x30FF,   // Katakana
                 0x31F0...0x31FF,   // Katakana Phonetic Extensions
                 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
                 0x2A700...0x2B73F, // Extension C
                 0x2B740...0x2B81F, // Extension D
                 0x2B820...0x2CEAF, // Extension E/F
                 0x2CEB0...0x2EBEF, // Extension G/I
                 0x3100...0x312F,   // Bopomofo
                 0x31A0...0x31BF:   // Bopomofo Extended
                return true
            default:
                continue
            }
        }
        return false
    }
}
