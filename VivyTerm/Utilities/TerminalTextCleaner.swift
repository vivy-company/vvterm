//
//  TerminalTextCleaner.swift
//  aizen
//

import Foundation

struct TerminalCopySettings {
    var trimTrailingWhitespace: Bool = true
    var collapseBlankLines: Bool = false
    var stripShellPrompts: Bool = false
    var flattenCommands: Bool = false
    var removeBoxDrawing: Bool = false
    var stripAnsiCodes: Bool = true
}

nonisolated struct TerminalTextCleaner {
    private static let boxDrawingCharacterClass = "[│┃╎╏┆┇┊┋╽╿￨｜]"
    private static let knownCommandPrefixes: [String] = [
        "sudo", "./", "~/", "apt", "brew", "git", "python", "pip", "pnpm", "npm", "yarn", "cargo",
        "bundle", "rails", "go", "make", "xcodebuild", "swift", "kubectl", "docker", "podman", "aws",
        "gcloud", "az", "ls", "cd", "cat", "echo", "env", "export", "open", "node", "java", "ruby",
        "perl", "bash", "zsh", "fish", "pwsh", "sh",
    ]

    static func cleanText(_ text: String, settings: TerminalCopySettings) -> String {
        var result = text

        if settings.stripAnsiCodes {
            result = stripAnsiCodes(result)
        }

        if settings.removeBoxDrawing {
            if let cleaned = stripBoxDrawingCharacters(in: result) {
                result = cleaned
            }
        }

        if settings.stripShellPrompts {
            if let stripped = stripPromptPrefixes(result) {
                result = stripped
            }
        }

        if settings.flattenCommands {
            if let flattened = flattenMultilineCommand(result) {
                result = flattened
            }
        }

        if settings.trimTrailingWhitespace {
            result = trimTrailingWhitespace(result)
        }

        if settings.collapseBlankLines {
            result = collapseBlankLines(result)
        }

        return result
    }

    // MARK: - ANSI Codes

    static func stripAnsiCodes(_ text: String) -> String {
        // Match ANSI escape sequences: ESC[ followed by params and command
        // Covers: colors, cursor movement, clearing, etc.
        let patterns = [
            #"\x1b\[[0-9;]*[A-Za-z]"#,  // CSI sequences (colors, cursor, etc.)
            #"\x1b\][^\x07]*\x07"#,      // OSC sequences (title, etc.)
            #"\x1b\][^\x1b]*\x1b\\"#,    // OSC with ST terminator
            #"\x1b[PX^_][^\x1b]*\x1b\\"#, // DCS, SOS, PM, APC sequences
            #"\x1b[@-Z\\-_]"#,           // Fe escape sequences
        ]

        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result
    }

    // MARK: - Trailing Whitespace

    static func trimTrailingWhitespace(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.map { line -> String in
            var s = String(line)
            while s.last?.isWhitespace == true && s.last != "\n" {
                s.removeLast()
            }
            return s
        }
        return trimmed.joined(separator: "\n")
    }

    // MARK: - Blank Lines

    static func collapseBlankLines(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
    }

    // MARK: - Shell Prompts

    static func stripPromptPrefixes(_ text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        var strippedCount = 0
        var rebuilt: [String] = []
        rebuilt.reserveCapacity(lines.count)

        for line in lines {
            if let stripped = stripPrompt(in: line) {
                strippedCount += 1
                rebuilt.append(stripped)
            } else {
                rebuilt.append(String(line))
            }
        }

        let majorityThreshold = nonEmptyLines.count / 2 + 1
        let shouldStrip = nonEmptyLines.count == 1 ? strippedCount == 1 : strippedCount >= majorityThreshold
        guard shouldStrip else { return nil }

        let result = rebuilt.joined(separator: "\n")
        return result == text ? nil : result
    }

    private static func stripPrompt(in line: Substring) -> String? {
        let leadingWhitespace = line.prefix { $0.isWhitespace }
        let remainder = line.dropFirst(leadingWhitespace.count)

        guard let first = remainder.first, first == "#" || first == "$" else { return nil }

        let afterPrompt = remainder.dropFirst().drop { $0.isWhitespace }
        guard isLikelyPromptCommand(afterPrompt) else { return nil }

        return String(leadingWhitespace) + String(afterPrompt)
    }

    private static func isLikelyPromptCommand(_ content: Substring) -> Bool {
        let trimmed = String(content.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.last, [".", "?", "!"].contains(last) { return false }

        let hasCommandPunctuation =
            trimmed.contains(where: { "-./~$".contains($0) }) || trimmed.contains(where: \.isNumber)
        let firstToken = trimmed.split(separator: " ").first?.lowercased() ?? ""
        let startsWithKnown = knownCommandPrefixes.contains(where: { firstToken.hasPrefix($0) })

        guard hasCommandPunctuation || startsWithKnown else { return false }
        return isLikelyCommandLine(trimmed[...])
    }

    // MARK: - Command Flattening

    static func flattenMultilineCommand(_ text: String) -> String? {
        guard text.contains("\n") else { return nil }

        let lines = text.split(whereSeparator: { $0.isNewline })
        guard lines.count >= 2, lines.count <= 10 else { return nil }

        // Check for command-like patterns
        let hasLineContinuation = text.contains("\\\n")
        let hasLineJoinerAtEOL = text.range(
            of: #"(?m)(\\|[|&]{1,2}|;)\s*$"#,
            options: .regularExpression) != nil
        let hasIndentedPipeline = text.range(
            of: #"(?m)^\s*[|&]{1,2}\s+\S"#,
            options: .regularExpression) != nil
        let hasExplicitLineJoin = hasLineContinuation || hasLineJoinerAtEOL || hasIndentedPipeline

        // Only flatten if it looks like a command
        guard hasExplicitLineJoin || looksLikeCommand(text, lines: lines) else { return nil }

        let flattened = flatten(text)
        return flattened == text ? nil : flattened
    }

    private static func looksLikeCommand(_ text: String, lines: [Substring]) -> Bool {
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Check for strong command signals
        let strongSignals = text.contains("\\\n")
            || text.range(of: #"[|&]{1,2}"#, options: .regularExpression) != nil
            || text.range(of: #"(^|\n)\s*\$"#, options: .regularExpression) != nil

        if strongSignals { return true }

        // Check if lines look like commands
        let commandLineCount = nonEmptyLines.count(where: isLikelyCommandLine(_:))
        if commandLineCount == nonEmptyLines.count { return true }

        // Check for known command prefixes
        let hasKnownPrefix = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstToken = trimmed.split(separator: " ").first else { return false }
            let lower = firstToken.lowercased()
            return knownCommandPrefixes.contains(where: { lower.hasPrefix($0) })
        }

        return hasKnownPrefix
    }

    private static func isLikelyCommandLine(_ lineSubstr: Substring) -> Bool {
        let line = lineSubstr.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        if line.hasPrefix("[[") { return true }
        if line.last == "." { return false }
        let pattern = #"^(sudo\s+)?[A-Za-z0-9./~_-]+(?:\s+|\z)"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func flatten(_ text: String) -> String {
        var result = text

        // Join uppercase segment line breaks
        result = result.replacingOccurrences(
            of: #"(?<!\n)([A-Z0-9_.-])\s*\n\s*([A-Z0-9_.-])(?!\n)"#,
            with: "$1$2",
            options: .regularExpression)

        // Join path line breaks
        result = result.replacingOccurrences(
            of: #"(?<=[/~])\s*\n\s*([A-Za-z0-9._-])"#,
            with: "$1",
            options: .regularExpression)

        // Replace backslash continuations
        result = result.replacingOccurrences(of: #"\\\s*\n"#, with: " ", options: .regularExpression)

        // Collapse newlines to spaces
        result = result.replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)

        // Collapse multiple spaces
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Box Drawing

    static func stripBoxDrawingCharacters(in text: String) -> String? {
        let boxRegex = try? NSRegularExpression(pattern: boxDrawingCharacterClass, options: [])
        if boxRegex?.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) == nil {
            return nil
        }

        var result = text

        if result.contains("│ │") {
            result = result.replacingOccurrences(of: "│ │", with: " ")
        }

        let lines = result.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if !nonEmptyLines.isEmpty {
            let leadingPattern = #"^\s*\#(boxDrawingCharacterClass)+ ?"#
            let trailingPattern = #" ?\#(boxDrawingCharacterClass)+\s*$"#
            let majorityThreshold = nonEmptyLines.count / 2 + 1

            let leadingMatches = nonEmptyLines.count(where: {
                $0.range(of: leadingPattern, options: .regularExpression) != nil
            })
            let trailingMatches = nonEmptyLines.count(where: {
                $0.range(of: trailingPattern, options: .regularExpression) != nil
            })

            let stripLeading = leadingMatches >= majorityThreshold
            let stripTrailing = trailingMatches >= majorityThreshold

            if stripLeading || stripTrailing {
                var rebuilt: [String] = []
                rebuilt.reserveCapacity(lines.count)

                for line in lines {
                    var lineStr = String(line)
                    if stripLeading {
                        lineStr = lineStr.replacingOccurrences(
                            of: leadingPattern,
                            with: "",
                            options: .regularExpression)
                    }
                    if stripTrailing {
                        lineStr = lineStr.replacingOccurrences(
                            of: trailingPattern,
                            with: "",
                            options: .regularExpression)
                    }
                    rebuilt.append(lineStr)
                }

                result = rebuilt.joined(separator: "\n")
            }
        }

        // Clean up box chars in mid-token positions
        let boxAfterPipePattern = #"\|\s*\#(boxDrawingCharacterClass)+\s*"#
        result = result.replacingOccurrences(
            of: boxAfterPipePattern,
            with: "| ",
            options: .regularExpression)

        let boxMidTokenPattern = #"(\S)\s*\#(boxDrawingCharacterClass)+\s*(\S)"#
        result = result.replacingOccurrences(
            of: boxMidTokenPattern,
            with: "$1 $2",
            options: .regularExpression)

        result = result.replacingOccurrences(
            of: #"\s*\#(boxDrawingCharacterClass)+\s*"#,
            with: " ",
            options: .regularExpression)

        let collapsed = result.replacingOccurrences(
            of: #" {2,}"#,
            with: " ",
            options: .regularExpression)

        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == text ? nil : trimmed
    }
}
