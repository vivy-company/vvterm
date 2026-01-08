//
//  TerminalSettingsView.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Terminal Settings View

struct TerminalSettingsView: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    @AppStorage("terminalThemeName") private var themeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var themeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true
    @AppStorage("terminalNotificationsEnabled") private var terminalNotificationsEnabled = true
    @AppStorage("terminalProgressEnabled") private var terminalProgressEnabled = true
    @AppStorage("terminalVoiceButtonEnabled") private var terminalVoiceButtonEnabled = true

    // Copy settings
    @AppStorage("terminalCopyTrimTrailingWhitespace") private var copyTrimTrailingWhitespace = true
    @AppStorage("terminalCopyCollapseBlankLines") private var copyCollapseBlankLines = false
    @AppStorage("terminalCopyStripShellPrompts") private var copyStripShellPrompts = false
    @AppStorage("terminalCopyFlattenCommands") private var copyFlattenCommands = false
    @AppStorage("terminalCopyRemoveBoxDrawing") private var copyRemoveBoxDrawing = false
    @AppStorage("terminalCopyStripAnsiCodes") private var copyStripAnsiCodes = true

    // SSH settings
    @AppStorage("sshKeepAliveEnabled") private var keepAliveEnabled = true
    @AppStorage("sshKeepAliveInterval") private var keepAliveInterval = 30
    @AppStorage("sshAutoReconnect") private var autoReconnect = true

    @State private var availableFonts: [String] = []
    @State private var themeNames: [String] = []

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font Family", selection: $fontName) {
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
                .disabled(availableFonts.isEmpty)

                HStack {
                    Text("Size: \(Int(fontSize))pt")
                        .frame(width: 100, alignment: .leading)
                    Slider(value: $fontSize, in: 8...24, step: 1)
                    Stepper("", value: $fontSize, in: 8...24, step: 1)
                        .labelsHidden()
                }
            }

            Section("Theme") {
                Toggle("Use different themes for Light/Dark mode", isOn: $usePerAppearanceTheme)

                if usePerAppearanceTheme {
                    Picker("Dark Mode Theme", selection: $themeName) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)

                    Picker("Light Mode Theme", selection: $themeNameLight) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)
                } else {
                    Picker("Theme", selection: $themeName) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)
                }
            }

            Section("Terminal Behavior") {
                Toggle("Enable terminal notifications", isOn: $terminalNotificationsEnabled)
                Toggle("Show progress overlays", isOn: $terminalProgressEnabled)
                Toggle("Show voice input button", isOn: $terminalVoiceButtonEnabled)
            }

            Section {
                Toggle("Trim trailing whitespace", isOn: $copyTrimTrailingWhitespace)
                Toggle("Collapse multiple blank lines", isOn: $copyCollapseBlankLines)
                Toggle("Strip shell prompts ($ #)", isOn: $copyStripShellPrompts)
                Toggle("Flatten multi-line commands", isOn: $copyFlattenCommands)
                Toggle("Remove box-drawing characters", isOn: $copyRemoveBoxDrawing)
                Toggle("Strip ANSI escape codes", isOn: $copyStripAnsiCodes)
            } header: {
                Text("Copy Text Processing")
            } footer: {
                Text("Transformations applied when copying text from terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH Connection") {
                Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
                Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)

                if keepAliveEnabled {
                    Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if availableFonts.isEmpty {
                availableFonts = loadSystemFonts()
            }
            if themeNames.isEmpty {
                themeNames = loadThemeNames()
            }
        }
    }

    #if os(macOS)
    private func loadSystemFonts() -> [String] {
        let fontManager = NSFontManager.shared
        return fontManager.availableFontFamilies.filter { familyName in
            guard let font = NSFont(name: familyName, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
    #else
    private func loadSystemFonts() -> [String] {
        ["Menlo", "Monaco", "SF Mono", "Courier New"]
    }
    #endif

    private func loadThemeNames() -> [String] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }

        let structuredPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        if FileManager.default.fileExists(atPath: structuredPath) {
            return loadThemesFromDirectory(structuredPath)
        }

        return loadThemesFromFlattenedResources(resourcePath)
    }

    private func loadThemesFromDirectory(_ path: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return files.filter { file in
            let fullPath = (path as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            return !isDir.boolValue && !file.hasPrefix(".")
        }.sorted()
    }

    private func loadThemesFromFlattenedResources(_ resourcePath: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) else { return [] }
        let knownNonThemes = Set(["Info", "Assets", "PkgInfo", "ghostty", "xterm-ghostty", "CodeSignature", "embedded", "_CodeSignature"])

        return files.filter { file in
            let fullPath = (resourcePath as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            guard !isDir.boolValue else { return false }
            guard !file.hasPrefix(".") else { return false }
            guard !file.contains(".") else { return false }
            guard !knownNonThemes.contains(file) else { return false }
            return true
        }.sorted()
    }
}
