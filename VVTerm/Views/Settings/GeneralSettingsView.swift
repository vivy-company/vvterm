//
//  GeneralSettingsView.swift
//  VVTerm
//

import SwiftUI
import os.log
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
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
        let mode = AppearanceMode(rawValue: appearanceMode) ?? .system
        #if os(iOS)
        content
            .background(
                AppearanceWindowBridge(mode: mode)
                    .frame(width: 0, height: 0)
            )
        #else
        content
            .preferredColorScheme(mode.colorScheme)
            .background(
                AppearanceWindowBridge(mode: mode)
                    .frame(width: 0, height: 0)
            )
        #endif
    }
}

// MARK: - Appearance Picker View

#if os(macOS)
struct AppearanceWindowBridge: NSViewRepresentable {
    let mode: AppearanceMode

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        let targetName: NSAppearance.Name? = {
            switch mode {
            case .system:
                return nil
            case .light:
                return .aqua
            case .dark:
                return .darkAqua
            }
        }()

        if window.appearance?.name != targetName {
            window.appearance = targetName.flatMap(NSAppearance.init(named:))
        }
    }
}
#endif

#if os(iOS)
final class AppearanceWindowController: UIViewController {
    var mode: AppearanceMode = .system

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyAppearance()
    }

    func applyAppearance() {
        let targetStyle: UIUserInterfaceStyle = {
            switch mode {
            case .system:
                return .unspecified
            case .light:
                return .light
            case .dark:
                return .dark
            }
        }()

        if let controller = topHostingController(),
           controller.overrideUserInterfaceStyle != targetStyle {
            controller.overrideUserInterfaceStyle = targetStyle
            return
        }

        if let window = view.window, window.overrideUserInterfaceStyle != targetStyle {
            window.overrideUserInterfaceStyle = targetStyle
        }
    }

    private func topHostingController() -> UIViewController? {
        var controller: UIViewController? = self
        while let parent = controller?.parent {
            controller = parent
        }
        return controller
    }
}

struct AppearanceWindowBridge: UIViewControllerRepresentable {
    let mode: AppearanceMode

    func makeUIViewController(context: Context) -> AppearanceWindowController {
        let controller = AppearanceWindowController()
        controller.view.isHidden = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AppearanceWindowController, context: Context) {
        uiViewController.mode = mode
        uiViewController.applyAppearance()
    }
}
#endif

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
    @StateObject private var appLockManager = AppLockManager.shared

    private let authGraceOptions = [0, 15, 30, 60, 120, 300]

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

            Section {
                Toggle(
                    String(format: String(localized: "Require %@ to open VVTerm"), appLockManager.biometryDisplayName),
                    isOn: Binding(
                        get: { appLockManager.fullAppLockEnabled },
                        set: { newValue in
                            Task {
                                await appLockManager.requestSetFullAppLockEnabled(newValue)
                            }
                        }
                    )
                )
                .disabled(appLockManager.isAuthenticating || (!appLockManager.isBiometryAvailable && !appLockManager.fullAppLockEnabled))

                if appLockManager.fullAppLockEnabled {
                    Toggle("Lock when app goes to background", isOn: $appLockManager.lockOnBackground)

                    Picker("Re-auth grace period", selection: $appLockManager.authGraceSeconds) {
                        ForEach(authGraceOptions, id: \.self) { seconds in
                            if seconds == 0 {
                                Text("Always")
                                    .tag(seconds)
                            } else {
                                Text(String(format: String(localized: "%lld seconds"), Int64(seconds)))
                                    .tag(seconds)
                            }
                        }
                    }
                }

                if let message = appLockManager.biometryAvailabilityMessage,
                   !appLockManager.isBiometryAvailable {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = appLockManager.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Biometric lock protects app and server access on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appLockManager.refreshBiometryAvailability()
        }
        .onChange(of: appLanguage) { newValue in
            AppLanguage.applySelection(newValue)
        }
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 500, height: 400)
}
