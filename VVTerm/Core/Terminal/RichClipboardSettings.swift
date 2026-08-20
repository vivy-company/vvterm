import Foundation

nonisolated enum ImagePasteBehavior: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case askOnce
    case automatic

    static let userDefaultsKey = "terminalImagePasteBehavior"

    var id: String { rawValue }

    var settingsTitle: String {
        switch self {
        case .automatic:
            return String(localized: "Automatically")
        case .askOnce:
            return String(localized: "Ask Before Upload")
        case .disabled:
            return String(localized: "Off")
        }
    }
}

nonisolated struct RichClipboardSettings: Sendable {
    static let maximumImageBytes = 50 * 1024 * 1024

    let imagePasteBehavior: ImagePasteBehavior
    let maximumImageBytes: Int

    init(defaults: UserDefaults = .standard) {
        self.imagePasteBehavior = Self.resolvedImagePasteBehavior(defaults: defaults)
        self.maximumImageBytes = Self.maximumImageBytes
    }

    var isImagePasteEnabled: Bool {
        imagePasteBehavior != .disabled
    }

    static func resolvedImagePasteBehavior(defaults: UserDefaults = .standard) -> ImagePasteBehavior {
        if let rawValue = defaults.string(forKey: ImagePasteBehavior.userDefaultsKey),
           let behavior = ImagePasteBehavior(rawValue: rawValue) {
            return behavior
        }

        return .askOnce
    }

    static func persistImagePasteBehavior(
        _ behavior: ImagePasteBehavior,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(behavior.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)
    }
}
