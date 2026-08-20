import XCTest
@testable import VVTerm

@MainActor
final class TranscriptionSettingsStoreTests: XCTestCase {
    func testPersistenceMigratesLegacyValuesAndRemovesLegacyKeys() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("whisper", forKey: TranscriptionSettingsKeys.provider)
        defaults.set("mlx-community/whisper-small", forKey: TranscriptionSettingsKeys.legacyWhisperModelID)
        defaults.set("mlx-community/parakeet-tdt-0.6b-v2", forKey: TranscriptionSettingsKeys.legacyParakeetModelID)
        defaults.set(" JA ", forKey: TranscriptionSettingsKeys.language)
        defaults.set(false, forKey: TranscriptionSettingsKeys.terminalVoiceButtonEnabled)

        let settings = UserDefaultsVoiceSettingsPersistence(defaults: defaults).loadSettings()

        XCTAssertEqual(settings.provider, .mlxWhisper)
        XCTAssertEqual(settings.whisperModelID, "mlx-community/whisper-small-mlx")
        XCTAssertEqual(settings.parakeetModelID, "mlx-community/parakeet-tdt-0.6b-v2")
        XCTAssertEqual(settings.languageCode, "ja")
        XCTAssertFalse(settings.terminalVoiceButtonEnabled)
        XCTAssertEqual(
            defaults.string(forKey: TranscriptionSettingsKeys.provider),
            TranscriptionProvider.mlxWhisper.rawValue
        )
        XCTAssertNil(defaults.object(forKey: TranscriptionSettingsKeys.legacyWhisperModelID))
        XCTAssertNil(defaults.object(forKey: TranscriptionSettingsKeys.legacyParakeetModelID))
    }

    func testSemanticSettersPersistOneSharedSnapshot() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UserDefaultsVoiceSettingsPersistence(defaults: defaults)
        let store = VoiceSettingsStore(persistence: persistence)

        store.setProvider(.mlxParakeet)
        store.setWhisperModelID("mlx-community/whisper-medium-mlx")
        store.setParakeetModelID("mlx-community/parakeet-tdt-0.6b-v2")
        store.setLanguageCode("fr")
        store.setTerminalVoiceButtonEnabled(false)

        XCTAssertEqual(persistence.loadSettings(), store.settings)
    }

    func testTwoSettingsOwnersAreIsolated() {
        let (firstDefaults, firstSuiteName) = makeDefaults()
        let (secondDefaults, secondSuiteName) = makeDefaults()
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuiteName)
            secondDefaults.removePersistentDomain(forName: secondSuiteName)
        }
        let first = VoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(defaults: firstDefaults)
        )
        let second = VoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(defaults: secondDefaults)
        )

        first.setProvider(.mlxWhisper)
        first.setLanguageCode("de")
        first.setTerminalVoiceButtonEnabled(false)

        XCTAssertEqual(first.settings.provider, .mlxWhisper)
        XCTAssertEqual(first.settings.languageCode, "de")
        XCTAssertFalse(first.settings.terminalVoiceButtonEnabled)
        XCTAssertEqual(second.settings, TranscriptionSettingsDefaults.settings)
    }

    func testMLXUnavailableFallbackPersistsSystemProvider() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(defaults: defaults)
        )
        store.setProvider(.mlxWhisper)

        store.useSystemProviderWhenMLXIsUnavailable()

        XCTAssertEqual(store.settings.provider, .system)
        XCTAssertEqual(
            defaults.string(forKey: TranscriptionSettingsKeys.provider),
            TranscriptionProvider.system.rawValue
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "TranscriptionSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
