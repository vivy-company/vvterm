//
//  TerminalDefaults.swift
//  VVTerm
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum TerminalDefaults {
    static let fontNameKey = "terminalFontName"
    static let fontSizeKey = "terminalFontSize"
    static let legacyDefaultFontName = "JetBrainsMono Nerd Font"
    #if os(macOS)
    static let defaultPrimaryFontName = "Menlo"
    static let macOSFallbackFontFamilies = [
        "Apple SD Gothic Neo",
        legacyDefaultFontName
    ]
    #endif

    static func applyIfNeeded() {
        applyIfNeeded(defaults: .standard)
    }

    static func applyIfNeeded(defaults: UserDefaults) {
        seedFontDefaultsIfNeeded(defaults: defaults)

        if defaults.object(forKey: ImagePasteBehavior.userDefaultsKey) == nil {
            let imagePasteBehavior = RichClipboardSettings.resolvedImagePasteBehavior(defaults: defaults)
            defaults.set(imagePasteBehavior.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)
        }
    }

    static var defaultFontSize: Double {
        #if os(macOS)
        return 12.0
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return 12.0
        case .phone:
            return 9.0
        default:
            return 10.0
        }
        #else
        return 10.0
        #endif
    }

    #if os(macOS)
    static var defaultFontName: String {
        defaultPrimaryFontName
    }
    #else
    static var defaultFontName: String {
        legacyDefaultFontName
    }
    #endif

    private static func seedFontDefaultsIfNeeded(defaults: UserDefaults) {
        #if os(macOS)
        seedMacOSFontDefaultsIfNeeded(defaults: defaults)
        #else
        if let fontName = defaults.string(forKey: fontNameKey) {
            if fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.set(defaultFontName, forKey: fontNameKey)
            }
        } else {
            defaults.set(defaultFontName, forKey: fontNameKey)
        }

        if defaults.object(forKey: fontSizeKey) == nil {
            defaults.set(defaultFontSize, forKey: fontSizeKey)
        }
        #endif
    }

    #if os(macOS)
    private static func seedMacOSFontDefaultsIfNeeded(defaults: UserDefaults) {
        let storedFontName = defaults.string(forKey: fontNameKey)
        let normalizedStoredFontName = storedFontName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedFontSize = defaults.object(forKey: fontSizeKey) as? Double

        if normalizedStoredFontName == nil || normalizedStoredFontName?.isEmpty == true {
            defaults.set(defaultPrimaryFontName, forKey: fontNameKey)
        }

        if storedFontSize == nil {
            defaults.set(defaultFontSize, forKey: fontSizeKey)
        }

        guard let resolvedFontName = defaults.string(forKey: fontNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedFontName.isEmpty else {
            return
        }

        let normalizedFontName = normalizedMacOSFontName(
            storedFontName: resolvedFontName,
            fontAvailability: { isAvailableMacOSFont(named: $0) }
        )

        if normalizedFontName != resolvedFontName {
            defaults.set(normalizedFontName, forKey: fontNameKey)
        }
    }

    static func normalizedMacOSFontName(
        storedFontName: String,
        fontAvailability: (String) -> Bool
    ) -> String {
        fontAvailability(storedFontName) ? storedFontName : defaultPrimaryFontName
    }

    private static func isAvailableMacOSFont(named fontName: String) -> Bool {
        NSFont(name: fontName, size: 12) != nil
    }
    #endif
}
