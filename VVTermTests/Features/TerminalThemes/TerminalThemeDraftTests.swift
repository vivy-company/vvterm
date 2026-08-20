import XCTest
@testable import VVTerm

final class TerminalThemeDraftTests: XCTestCase {
    func testDecodeAndEncodeRoundTripKnownAndAdvancedValues() throws {
        let content = """
        background = #101418
        foreground = #d8e0ea
        cursor-color = #f8b26a
        palette = 3=#f0c674
        minimum-contrast = 4.5
        """

        let draft = TerminalThemeDraft.decode(content)
        let encoded = try draft.encodedContent()

        XCTAssertEqual(draft.foreground, "#D8E0EA")
        XCTAssertEqual(draft.paletteColors[3], "#F0C674")
        XCTAssertEqual(draft.advancedLines, "minimum-contrast = 4.5")
        XCTAssertTrue(encoded.contains("palette = 3=#F0C674"))
        XCTAssertTrue(encoded.contains("minimum-contrast = 4.5"))
    }

    func testDecodeKeepsInvalidOrOutOfRangePaletteForRepair() {
        let draft = TerminalThemeDraft.decode(
            """
            background = #101418
            foreground = #D8E0EA
            palette = 16=#FFFFFF
            palette = bad
            """
        )

        XCTAssertEqual(draft.paletteColors.count, TerminalThemeDraft.paletteCount)
        XCTAssertEqual(
            draft.advancedLines,
            "palette = 16=#FFFFFF\npalette = bad"
        )
    }

    func testInitializerNormalizesPaletteCapacity() {
        let short = TerminalThemeDraft(paletteColors: ["#000000"])
        let long = TerminalThemeDraft(
            paletteColors: Array(repeating: "#000000", count: 20)
        )

        XCTAssertEqual(short.paletteColors.count, TerminalThemeDraft.paletteCount)
        XCTAssertEqual(short.paletteColors[0], "#000000")
        XCTAssertEqual(short.paletteColors[1], "")
        XCTAssertEqual(long.paletteColors.count, TerminalThemeDraft.paletteCount)
    }

    func testBuilderValidationRejectsInvalidRequiredAndPaletteColors() {
        var draft = TerminalThemeDraft()
        XCTAssertTrue(draft.hasValidBuilderValues)

        draft.background = "invalid"
        XCTAssertFalse(draft.hasValidBuilderValues)

        draft.background = "#101418"
        draft.paletteColors[15] = "invalid"
        XCTAssertFalse(draft.hasValidBuilderValues)
    }
}
