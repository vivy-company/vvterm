//
//  AboutSettingsView.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - About Settings View

struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var appIcon: Image {
        #if os(macOS)
        if let nsImage = NSImage(named: "AppIcon") {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "terminal")
        #else
        if let uiImage = UIImage(named: "AppIcon") {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "terminal")
        #endif
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    appIcon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 3)

                    Text("VVTerm")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Professional SSH client\nfor macOS & iOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Section("Links") {
                Link(destination: URL(string: "https://vivy.dev")!) {
                    Label("Visit Website", systemImage: "globe")
                }

                Link(destination: URL(string: "https://github.com/vivy-company/vivyterm/issues")!) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }

                Link(destination: URL(string: "https://vivy.dev/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }

            Section {
                Text("© 2025 Vivy Technologies Co., Limited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}
