#if os(macOS)
import SwiftUI
import AppKit

extension WelcomeView {
    var platformContent: some View {
        WelcomeContent(
            hasSeenWelcome: $hasSeenWelcome,
            onCompleted: onCompleted
        )
    }
}

private struct WelcomeContent: View {
    @Binding var hasSeenWelcome: Bool
    let onCompleted: () -> Void
    @State private var showingProUpgrade = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 32)

                    // App Icon (load 512@2x for best quality)
                    if let iconImage = NSImage(named: "icon-mac-512@2x") {
                        Image(nsImage: iconImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                    } else {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                    }

                    // Header
                    Text("Welcome to VVTerm")
                        .font(.system(size: 28, weight: .bold))
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    Text("Your secure SSH terminal")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(WelcomeFeaturePresentationCatalog.features(
                            companionPlatformTitle: "Available on iPhone and iPad"
                        )) { feature in
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
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }

            // Continue button
            VStack(spacing: 12) {
                Button {
                    hasSeenWelcome = true
                    onCompleted()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: 420)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShapeCompat()
                .tint(Color(red: 1.0, green: 0.27, blue: 0.35))
                .controlSize(.large)

                Button {
                    showingProUpgrade = true
                } label: {
                    Text("Explore Pro")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 28)
            .proUpgradePresentation(isPresented: $showingProUpgrade, source: .welcome)
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private extension View {
    @ViewBuilder
    func buttonBorderShapeCompat() -> some View {
        if #available(macOS 14.0, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }
}
#endif
