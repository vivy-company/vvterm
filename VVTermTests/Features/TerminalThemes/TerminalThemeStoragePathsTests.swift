import XCTest
@testable import VVTerm

final class TerminalThemeStoragePathsTests: XCTestCase {
    func testCustomThemeFilePathEndsWithThemeName() {
        let path = TerminalThemeStoragePaths.customThemeFilePath(for: "MyTheme")

        XCTAssertTrue(path?.hasSuffix("/CustomThemes/MyTheme") == true || path?.hasSuffix("\\CustomThemes\\MyTheme") == true)
    }

    func testCustomThemeFilePathRejectsTraversal() {
        XCTAssertNil(TerminalThemeStoragePaths.customThemeFilePath(for: "../../Outside"))
    }
}
