import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class UserDefaultsTerminalThemePersistenceTests: XCTestCase {
    private let keys = TerminalThemeUserDefaultsKeys(
        customThemes: "test.themes",
        darkTheme: "test.theme.dark",
        lightTheme: "test.theme.light",
        usesPerAppearanceTheme: "test.theme.per-appearance",
        preferenceUpdatedAt: "test.theme.updated-at",
        activeBackgroundCache: "test.theme.background"
    )

    func testMissingValuesLoadSemanticDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = makePersistence(defaults: defaults)

        XCTAssertEqual(try persistence.loadCustomThemes(), [])
        XCTAssertEqual(
            persistence.loadSelection(),
            TerminalThemeSelection(
                darkThemeName: "Aizen Dark",
                lightThemeName: "Aizen Light",
                usePerAppearanceTheme: true
            )
        )
        XCTAssertEqual(persistence.loadPreferenceUpdatedAt(), .distantPast)
    }

    func testMalformedThemeDataIsReportedAndPreserved() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformedData = Data("not-json".utf8)
        defaults.set(malformedData, forKey: keys.customThemes)
        let persistence = makePersistence(defaults: defaults)

        XCTAssertThrowsError(try persistence.loadCustomThemes())
        XCTAssertEqual(defaults.data(forKey: keys.customThemes), malformedData)
    }

    func testThemesSelectionTimestampAndBackgroundRoundTrip() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = makePersistence(defaults: defaults)
        let theme = TerminalTheme(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Persisted",
            content: "background = #010203\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSince1970: 100),
            deletedAt: nil
        )
        let selection = TerminalThemeSelection(
            darkThemeName: "Persisted",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: false
        )
        let updatedAt = Date(timeIntervalSince1970: 200)

        try persistence.saveCustomThemes([theme])
        persistence.saveSelection(selection)
        persistence.savePreferenceUpdatedAt(updatedAt)
        persistence.cacheActiveBackgroundHex("#010203")

        XCTAssertEqual(try persistence.loadCustomThemes(), [theme])
        XCTAssertEqual(persistence.loadSelection(), selection)
        XCTAssertEqual(persistence.loadPreferenceUpdatedAt(), updatedAt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [TerminalTheme].self,
                from: XCTUnwrap(defaults.data(forKey: keys.customThemes))
            ),
            [theme]
        )
        XCTAssertEqual(defaults.string(forKey: keys.activeBackgroundCache), "#010203")
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "UserDefaultsTerminalThemePersistenceTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func makePersistence(
        defaults: UserDefaults
    ) -> UserDefaultsTerminalThemePersistence {
        UserDefaultsTerminalThemePersistence(defaults: defaults, keys: keys)
    }
}
