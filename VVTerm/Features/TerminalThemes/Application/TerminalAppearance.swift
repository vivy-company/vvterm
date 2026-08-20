//
//  TerminalAppearance.swift
//  VVTerm
//

nonisolated enum TerminalColorAppearance: Equatable, Sendable {
    case light
    case dark
}

nonisolated struct TerminalThemeSelection: Equatable, Sendable {
    let darkThemeName: String
    let lightThemeName: String
    let usePerAppearanceTheme: Bool
}

nonisolated struct TerminalThemePalette: Equatable, Sendable {
    let backgroundHex: String
    let foregroundHex: String
    let cursorHex: String
    let cursorTextHex: String

    static let fallback = TerminalThemePalette(
        backgroundHex: "#101418",
        foregroundHex: "#D8E0EA",
        cursorHex: "#F8B26A",
        cursorTextHex: "#101418"
    )
}

nonisolated struct ResolvedTerminalTheme: Equatable, Sendable {
    let name: String
    let palette: TerminalThemePalette
}

nonisolated struct TerminalAppearanceSnapshot: Equatable, Sendable {
    let activeAppearance: TerminalColorAppearance
    let lightTheme: ResolvedTerminalTheme
    let darkTheme: ResolvedTerminalTheme

    var activeTheme: ResolvedTerminalTheme {
        theme(for: activeAppearance)
    }

    func theme(for appearance: TerminalColorAppearance) -> ResolvedTerminalTheme {
        switch appearance {
        case .light:
            lightTheme
        case .dark:
            darkTheme
        }
    }

    static let fallback = TerminalAppearanceSnapshot(
        activeAppearance: .dark,
        lightTheme: ResolvedTerminalTheme(
            name: "Aizen Light",
            palette: .fallback
        ),
        darkTheme: ResolvedTerminalTheme(
            name: "Aizen Dark",
            palette: .fallback
        )
    )
}
