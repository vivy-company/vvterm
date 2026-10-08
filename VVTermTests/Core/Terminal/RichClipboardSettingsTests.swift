import Foundation
import Testing
@testable import VVTerm

struct RichClipboardSettingsTests {
    @Test
    func settingsDefaultToAutomaticWhenUnsetOrInvalid() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let settings = RichClipboardSettings(defaults: defaults)

        #expect(settings.imagePasteBehavior == .automatic)
        #expect(settings.isImagePasteEnabled)
        defaults.set("bogus", forKey: ImagePasteBehavior.userDefaultsKey)
        #expect(RichClipboardSettings(defaults: defaults).imagePasteBehavior == .automatic)
    }

    @Test
    func settingsPreservePersistedAskBeforeUpload() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.set(ImagePasteBehavior.askOnce.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)
        #expect(RichClipboardSettings(defaults: defaults).imagePasteBehavior == .askOnce)
    }

    @Test
    func settingsReadPersistedAutomaticBehavior() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.set(ImagePasteBehavior.automatic.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)

        let settings = RichClipboardSettings(defaults: defaults)

        #expect(settings.imagePasteBehavior == .automatic)
        #expect(settings.isImagePasteEnabled)
    }

    @Test
    func settingsReadPersistedDisabledBehavior() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.set(ImagePasteBehavior.disabled.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)

        let settings = RichClipboardSettings(defaults: defaults)

        #expect(settings.imagePasteBehavior == .disabled)
        #expect(!settings.isImagePasteEnabled)
    }
}
