import Foundation

// MARK: - Tokenizer Module

nonisolated public struct ParakeetTokenizer {
    /// Decode token IDs to text using vocabulary
    public static func decode(_ tokenIds: [Int], _ vocabulary: [String]) -> String {
        return tokenIds.compactMap { id in
            guard id >= 0 && id < vocabulary.count else { return nil }
            // Replace SentencePiece "▁" character with spaces, matching Python implementation
            return vocabulary[id].replacingOccurrences(of: "▁", with: " ")
        }.joined()
    }

    /// Encode text to token IDs using vocabulary
    public static func encode(_ text: String, _ vocabulary: [String]) -> [Int] {
        // Simple character-based encoding for now
        // This would need to be more sophisticated for real use
        var tokens: [Int] = []
        for char in text {
            if let index = vocabulary.firstIndex(of: String(char)) {
                tokens.append(index)
            }
        }
        return tokens
    }
}
