import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A compact, native-looking status card for terminal overlays.
struct TerminalStatusCard<Content: View>: View {
    var maxWidth: CGFloat = 320
    var showsScrim: Bool = true
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(maxWidth: CGFloat = 320, showsScrim: Bool = true, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.showsScrim = showsScrim
        self.content = content()
    }

    var body: some View {
        ZStack {
            if showsScrim {
                Color.black
                    .opacity(colorScheme == .dark ? 0.35 : 0.25)
                    .ignoresSafeArea()
            }

            content
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(cardBackground)
                .overlay(cardBorder)
                .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
                .padding(24)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(cardFill)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
    }

    private var cardFill: Color {
        let base: Color = {
            #if os(iOS)
            return Color(UIColor.secondarySystemBackground)
            #elseif os(macOS)
            return Color(NSColor.windowBackgroundColor)
            #else
            return Color.black
            #endif
        }()

        if reduceTransparency {
            return base
        }

        return base.opacity(colorScheme == .dark ? 0.92 : 0.98)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.45 : 0.2)
    }
}

#Preview("Terminal Status Card") {
    ZStack {
        Color.black.ignoresSafeArea()
        TerminalStatusCard {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Reconnecting...")
                    .font(.headline)
                Text("Attempt 2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }
}
