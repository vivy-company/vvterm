//
//  AboutView.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit

// MARK: - About Window Controller

final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: hostingView.fittingSize.width, height: hostingView.fittingSize.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "About VVTerm")
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
#endif

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    var body: some View {
        VStack(spacing: 0) {
            // App icon and name
            VStack(spacing: 12) {
                appIcon
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .cornerRadius(18)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                Text("VVTerm")
                    .font(.system(size: 24, weight: .bold))

                Text(String(format: String(localized: "Version %@ (%@)"), appVersion, buildNumber))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Tagline
            Text("Professional SSH client\nfor macOS & iOS")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

            // Links
            VStack(spacing: 12) {
                LinkButton(
                    title: String(localized: "Visit Website"),
                    icon: "globe",
                    isSystemImage: true,
                    url: "https://vvterm.com"
                )

                LinkButton(
                    title: String(localized: "Report an Issue"),
                    icon: "exclamationmark.bubble",
                    isSystemImage: true,
                    url: "https://github.com/vivy-company/vvterm/issues"
                )

                LinkButton(
                    title: String(localized: "Privacy Policy"),
                    icon: "hand.raised",
                    isSystemImage: true,
                    url: "https://vvterm.com/privacy"
                )
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            Divider()
                .padding(.horizontal, 32)

            // Copyright
        Text(String(format: String(localized: "© %lld Vivy Technologies Co., Limited"), Int64(Calendar.current.component(.year, from: Date()))))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 16)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
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
}

private struct LinkButton: View {
    @Environment(\.openURL) private var openURL

    let title: String
    let icon: String
    let isSystemImage: Bool
    let url: String

    var body: some View {
        Button {
            if let url = URL(string: url) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 10) {
                if isSystemImage {
                    Image(systemName: icon)
                        .frame(width: 18, height: 18)
                } else {
                    Image(icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }

                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AboutView()
}
