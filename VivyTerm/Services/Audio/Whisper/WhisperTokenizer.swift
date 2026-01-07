import Foundation

struct WhisperEncoding {
    let baseTokens: [Data]
    let baseVocabCount: Int
    let specialTokens: [String: Int]
    let nVocab: Int
}

nonisolated final class WhisperTokenizer {
    static let supportedLanguages: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it",
        "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th",
        "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az",
        "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl",
        "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am",
        "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg",
        "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue"
    ]

    private static var cachedEncodings: [String: WhisperEncoding] = [:]

    let encoding: WhisperEncoding
    let language: String?
    let task: String?
    let numLanguages: Int

    init(multilingual: Bool, numLanguages: Int = 99, language: String? = "en", task: String? = "transcribe") throws {
        self.numLanguages = numLanguages

        let encodingName = multilingual ? "multilingual" : "gpt2"
        self.encoding = try Self.loadEncoding(name: encodingName, numLanguages: numLanguages)

        if multilingual {
            self.language = language
            self.task = task
        } else {
            self.language = nil
            self.task = nil
        }
    }

    var sot: Int { specialToken("<|startoftranscript|>") }
    var eot: Int { specialToken("<|endoftext|>") }
    var transcribe: Int { specialToken("<|transcribe|>") }
    var translate: Int { specialToken("<|translate|>") }
    var noTimestamps: Int { specialToken("<|notimestamps|>") }
    var timestampBegin: Int { specialToken("<|0.00|>") }

    var sotSequence: [Int] {
        var sequence = [sot]
        if let language, let languageToken = languageToken(for: language) {
            sequence.append(languageToken)
        }
        if let task {
            sequence.append(task == "translate" ? translate : transcribe)
        }
        return sequence
    }

    func initialTokens(withoutTimestamps: Bool = true) -> [Int] {
        var tokens = sotSequence
        if withoutTimestamps {
            tokens.append(noTimestamps)
        }
        return tokens
    }

    func decode(_ tokens: [Int]) -> String {
        let filtered = tokens.filter { $0 < timestampBegin && $0 < encoding.baseVocabCount }
        var data = Data()
        data.reserveCapacity(filtered.count * 2)
        for token in filtered {
            if token >= 0 && token < encoding.baseTokens.count {
                data.append(encoding.baseTokens[token])
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func languageToken(for language: String) -> Int? {
        guard let index = Self.supportedLanguages.prefix(numLanguages).firstIndex(of: language) else {
            return nil
        }
        return sot + 1 + index
    }

    private func specialToken(_ name: String) -> Int {
        encoding.specialTokens[name] ?? 0
    }

    private static func loadEncoding(name: String, numLanguages: Int) throws -> WhisperEncoding {
        if let cached = cachedEncodings[name] {
            return cached
        }

        guard let url = resourceURL(name: name, fileExtension: "tiktoken") else {
            throw NSError(domain: "WhisperTokenizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing tokenizer resource: \(name).tiktoken"])
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        var baseTokens: [Data] = []

        for line in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let rank = Int(parts[1]) else { continue }
            let tokenData = Data(base64Encoded: String(parts[0])) ?? Data()
            if rank >= baseTokens.count {
                baseTokens.append(contentsOf: Array(repeating: Data(), count: rank - baseTokens.count + 1))
            }
            baseTokens[rank] = tokenData
        }

        let baseVocabCount = baseTokens.count
        var specialTokens: [String: Int] = [:]
        var nVocab = baseVocabCount

        let languageTokens = supportedLanguages.prefix(numLanguages).map { "<|\($0)|>" }
        let timestampTokens = (0...1500).map { String(format: "<|%.2f|>", Double($0) * 0.02) }

        var specials: [String] = [
            "<|endoftext|>",
            "<|startoftranscript|>",
        ]
        specials.append(contentsOf: languageTokens)
        specials.append(contentsOf: [
            "<|translate|>",
            "<|transcribe|>",
            "<|startoflm|>",
            "<|startofprev|>",
            "<|nospeech|>",
            "<|notimestamps|>",
        ])
        specials.append(contentsOf: timestampTokens)

        for token in specials {
            specialTokens[token] = nVocab
            nVocab += 1
        }

        let encoding = WhisperEncoding(
            baseTokens: baseTokens,
            baseVocabCount: baseVocabCount,
            specialTokens: specialTokens,
            nVocab: nVocab
        )

        cachedEncodings[name] = encoding
        return encoding
    }

    private static func resourceURL(name: String, fileExtension: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Whisper") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/Whisper") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: fileExtension)
    }
}
