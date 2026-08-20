#if os(iOS)
import SwiftUI
import UIKit

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
                        .frame(height: 24)

                    // App Icon (load 1024px version for best quality)
                    if let iconImage = UIImage(named: "icon-ios-1024") {
                        Image(uiImage: iconImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 108, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }

                    // Header
                    Text("Welcome to VVTerm")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.top, 18)
                        .multilineTextAlignment(.center)

                    Text("Your secure SSH terminal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)

                    // Features
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(WelcomeFeaturePresentationCatalog.features(
                            companionPlatformTitle: "Available on Mac"
                        )) { feature in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: feature.icon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 46, height: 46)
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
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }

            // Continue button
            VStack(spacing: 14) {
                Button {
                    hasSeenWelcome = true
                    onCompleted()
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

                Button {
                    showingProUpgrade = true
                } label: {
                    Text("Explore Pro")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
            .proUpgradePresentation(isPresented: $showingProUpgrade, source: .welcome)
        }
    }
}
#endif
