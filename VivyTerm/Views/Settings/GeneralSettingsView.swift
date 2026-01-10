//
//  GeneralSettingsView.swift
//  VivyTerm
//

import SwiftUI
import os.log
#if os(macOS)
import AppKit
#endif

enum AppearanceMode: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// View modifier that applies the app-wide appearance setting
struct AppearanceModifier: ViewModifier {
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue

    private var colorScheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearanceMode) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(colorScheme)
    }
}

// MARK: - Appearance Picker View

struct AppearancePickerView: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                AppearanceOptionView(
                    mode: mode,
                    isSelected: selection == mode.rawValue
                )
                .frame(maxWidth: .infinity)
                .onTapGesture {
                    selection = mode.rawValue
                }
            }
        }
    }
}

struct AppearanceOptionView: View {
    let mode: AppearanceMode
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                AppearancePreviewCard(mode: mode)
                    .frame(width: 100, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            }

            Text(mode.label)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}

struct AppearancePreviewCard: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .system:
            HStack(spacing: 0) {
                miniWindowPreview(isDark: false)
                miniWindowPreview(isDark: true)
            }
        case .light:
            miniWindowPreview(isDark: false)
        case .dark:
            miniWindowPreview(isDark: true)
        }
    }

    private func miniWindowPreview(isDark: Bool) -> some View {
        let bgColor = isDark ? Color(white: 0.15) : Color(white: 0.95)
        let windowBg = isDark ? Color(white: 0.22) : Color.white
        let sidebarBg = isDark ? Color(white: 0.18) : Color(white: 0.92)
        let accentBar = isDark ? Color.pink.opacity(0.8) : Color.pink
        let dotColors: [Color] = [.red, .yellow, .green]

        return ZStack {
            bgColor

            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(dotColors[i])
                            .frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(windowBg)

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(sidebarBg)
                        .frame(width: 16)

                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accentBar)
                            .frame(height: 8)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)

                        Spacer()
                    }
                    .background(windowBg)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(6)
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName)
                            .tag(language.rawValue)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Some changes may require restarting the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                AppearancePickerView(selection: $appearanceMode)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appLanguage) { newValue in
            AppLanguage.applySelection(newValue)
        }
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 500, height: 400)
}
