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
    @StateObject private var storeManager = StoreManager.shared
    @State private var showingReviewSheet = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
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
                        .onTapGesture(count: 7) {
                            showingReviewSheet = true
                        }

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

                Link(destination: URL(string: "https://vvterm.com/terms")!) {
                    Label("Terms of Use (EULA)", systemImage: "doc.text")
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
        .sheet(isPresented: $showingReviewSheet) {
            ReviewModeSheet()
        }
    }

    #if os(iOS)
    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

// MARK: - Review Mode Sheet

private struct ReviewModeSheet: View {
    @ObservedObject private var storeManager = StoreManager.shared
    @State private var reviewCode = ""
    @State private var reviewError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusCard
                    if storeManager.isReviewModeEnabled {
                        enabledSection
                    } else {
                        codeSection
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
                #if os(macOS)
                .frame(minWidth: 420, maxWidth: 520)
                #endif
            }
            .navigationTitle("App Review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Review Mode")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Unlocks Pro features and loads demo servers for App Review.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        HStack {
            Text("Status")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(storeManager.isReviewModeEnabled ? "Enabled" : "Disabled")
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(storeManager.isReviewModeEnabled ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(storeManager.isReviewModeEnabled ? .green : .secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var enabledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review mode is active on this device.")
                .font(.subheadline)
            Text("Pro features are unlocked. Review mode expires after 5 hours or when the app restarts.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Disable Review Mode") {
                storeManager.setReviewModeEnabled(false)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the review code to enable Pro access for App Review.")
                .font(.subheadline)
            #if os(iOS)
            TextField("Review Code", text: $reviewCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            #else
            TextField("Review Code", text: $reviewCode)
                .textFieldStyle(.roundedBorder)
            #endif

            Button("Enable Review Mode") {
                let success = storeManager.enableReviewMode(code: reviewCode)
                if success {
                    reviewError = nil
                    reviewCode = ""
                } else {
                    reviewError = "Invalid review code."
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(reviewCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let reviewError {
                Text(reviewError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("Review mode is local-only and expires after 5 hours or when the app restarts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
