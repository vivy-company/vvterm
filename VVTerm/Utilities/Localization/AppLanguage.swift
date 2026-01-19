import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"
    case ja = "ja"
    case th = "th"
    case vi = "vi"
    case es = "es"
    case ru = "ru"
    case fr = "fr"
    case de = "de"
    case be = "be"
    case uk = "uk"
    case pl = "pl"
    case cs = "cs"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System (Default)")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        case .th: return "ไทย"
        case .vi: return "Tiếng Việt"
        case .es: return "Español"
        case .ru: return "Русский"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .be: return "Беларуская"
        case .uk: return "Українська"
        case .pl: return "Polski"
        case .cs: return "Čeština"
        }
    }

    var locale: Locale {
        if self == .system {
            return Locale.current
        }
        return Locale(identifier: rawValue)
    }

    static func applySelection(_ rawValue: String) {
        if rawValue == AppLanguage.system.rawValue {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}
