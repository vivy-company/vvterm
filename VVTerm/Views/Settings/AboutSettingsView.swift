//
//  AboutSettingsView.swift
//  VVTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Contact Option

private struct ContactOption: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let iconImage: String?
    let iconText: String?
    let color: Color
    let url: String
}

private let contactOptions: [ContactOption] = [
    ContactOption(title: String(localized: "Developer"), subtitle: "@wiedymi", icon: "", iconImage: nil, iconText: "𝕏", color: .primary, url: "https://x.com/wiedymi"),
    ContactOption(title: String(localized: "Discord"), subtitle: String(localized: "Join Community"), icon: "", iconImage: "DiscordLogo", iconText: nil, color: Color(red: 0.345, green: 0.396, blue: 0.949), url: "https://discord.gg/zemMZtrkSb"),
    ContactOption(title: String(localized: "Email"), subtitle: "dev@vivy.company", icon: "envelope.fill", iconImage: nil, iconText: nil, color: .orange, url: "mailto:dev@vivy.company")
]

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
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last,
           let uiImage = UIImage(named: lastIcon) {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "terminal")
        #endif
    }

    private var subtitleColor: Color {
        #if os(macOS)
        return Color(nsColor: .secondaryLabelColor)
        #else
        return Color(uiColor: .secondaryLabel)
        #endif
    }

    private var footerColor: Color {
        #if os(macOS)
        return Color(nsColor: .secondaryLabelColor)
        #else
        return Color(uiColor: .secondaryLabel)
        #endif
    }

    private var copyrightLine: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Vivy Technologies Co., Limited"
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

                    Text(verbatim: "Version \(appVersion) (\(buildNumber))")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text("Professional SSH client\nfor macOS & iOS")
                        .font(.footnote)
                        .foregroundStyle(subtitleColor)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Section("Links") {
                Link(destination: URL(string: "https://vvterm.com")!) {
                    Label("Visit Website", systemImage: "globe")
                }
                .tint(.primary)
                .foregroundStyle(.primary)

                Link(destination: URL(string: "https://vvterm.com/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .tint(.primary)
                .foregroundStyle(.primary)
            }

            #if os(iOS)
            Section("Get in Touch") {
                ForEach(contactOptions) { option in
                    Button {
                        openURL(option.url)
                    } label: {
                        HStack(spacing: 14) {
                            Group {
                                if let imageName = option.iconImage {
                                    Image(imageName)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else if let text = option.iconText {
                                    Text(text)
                                        .font(.system(size: 18, weight: .bold))
                                } else {
                                    Image(systemName: option.icon)
                                }
                            }
                            .frame(width: 24, height: 24)
                            .foregroundStyle(option.color)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(subtitleColor)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                }
            }
            #endif

            Section {
                #if os(iOS)
                Button {
                    openURL("https://x.com/vivytech")
                } label: {
                    HStack {
                        Text(verbatim: copyrightLine)
                            .font(.footnote)
                            .foregroundStyle(footerColor)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                #else
                Text(verbatim: copyrightLine)
                    .font(.footnote)
                    .foregroundStyle(footerColor)
                    .frame(maxWidth: .infinity)
                #endif
            }
        }
        .formStyle(.grouped)
    }

    #if os(iOS)
    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}
