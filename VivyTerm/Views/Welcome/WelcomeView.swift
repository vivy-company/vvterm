//
//  WelcomeView.swift
//  VivyTerm
//

import SwiftUI

struct WelcomeView: View {
    @Binding var hasSeenWelcome: Bool

    var body: some View {
        #if os(iOS)
        iOSWelcomeContent(hasSeenWelcome: $hasSeenWelcome)
        #else
        macOSWelcomeContent(hasSeenWelcome: $hasSeenWelcome)
        #endif
    }
}

// MARK: - iOS Welcome

#if os(iOS)
private struct iOSWelcomeContent: View {
    @Binding var hasSeenWelcome: Bool

    private let features: [(icon: String, title: String, description: String, color: Color)] = [
        ("terminal.fill", String(localized: "SSH Terminal"), String(localized: "Connect to servers with GPU-accelerated terminal emulation."), .blue),
        ("icloud.fill", String(localized: "iCloud Sync"), String(localized: "Servers and credentials sync across all your devices."), .cyan),
        ("clock.arrow.circlepath", String(localized: "Session Persistence"), String(localized: "Keep sessions alive with tmux, even after disconnects."), .teal),
        ("key.fill", String(localized: "Secure Storage"), String(localized: "Passwords and SSH keys protected by Keychain."), .green),
        ("waveform", String(localized: "Voice Commands"), String(localized: "Speak commands with on-device speech recognition."), .orange)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 40)

            // App Icon (load 1024px version for best quality)
            if let iconImage = UIImage(named: "icon-ios-1024") {
                Image(uiImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            }

            // Header
            Text("Welcome to VVTerm")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 20)
                .padding(.bottom, 32)

            // Features
            VStack(alignment: .leading, spacing: 28) {
                ForEach(features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(feature.color)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title)
                                .font(.headline)

                            Text(feature.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            // Continue button
            Button {
                hasSeenWelcome = true
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
}
#endif

// MARK: - macOS Welcome

#if os(macOS)
private struct macOSWelcomeContent: View {
    @Binding var hasSeenWelcome: Bool

    private let features: [(icon: String, title: String, description: String, color: Color)] = [
        ("terminal.fill", String(localized: "SSH Terminal"), String(localized: "Connect to servers with GPU-accelerated terminal emulation."), .blue),
        ("icloud.fill", String(localized: "iCloud Sync"), String(localized: "Servers and credentials sync across all your devices."), .cyan),
        ("clock.arrow.circlepath", String(localized: "Session Persistence"), String(localized: "Keep sessions alive with tmux, even after disconnects."), .teal),
        ("key.fill", String(localized: "Secure Storage"), String(localized: "Passwords and SSH keys protected by Keychain."), .green),
        ("waveform", String(localized: "Voice Commands"), String(localized: "Speak commands with on-device speech recognition."), .orange)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 40)

            // App Icon (load 512@2x for best quality)
            if let iconImage = NSImage(named: "icon-mac-512@2x") {
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
            }

            // Header
            Text("Welcome to VVTerm")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 16)
                .padding(.bottom, 8)

            Text("Your secure SSH terminal")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)

            // Features
            VStack(alignment: .leading, spacing: 20) {
                ForEach(features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(feature.color)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.system(size: 13, weight: .semibold))

                            Text(feature.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 48)

            Spacer()
                .frame(minHeight: 40)

            // Continue button
            Button {
                hasSeenWelcome = true
            } label: {
                Text("Continue")
                    .frame(maxWidth: 420)
                    .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShapeCompat()
            .tint(Color(red: 1.0, green: 0.27, blue: 0.35))
            .controlSize(.large)
            .padding(.horizontal, 48)
            .padding(.bottom, 32)
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif

#Preview {
    WelcomeView(hasSeenWelcome: .constant(false))
}

private extension View {
    @ViewBuilder
    func buttonBorderShapeCompat() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }
}
