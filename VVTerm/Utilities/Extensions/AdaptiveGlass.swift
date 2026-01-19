import SwiftUI

// MARK: - Adaptive Glass Modifiers

/// Provides backwards-compatible Liquid Glass effects
/// - iOS 26+ / macOS 26+: Uses native `.glassEffect()` API
/// - Earlier versions: Falls back to `.ultraThinMaterial`

extension View {
    /// Apply adaptive glass effect with capsule shape
    @ViewBuilder
    func adaptiveGlass() -> some View {
        if #available(iOS 26, macOS 26, *) {
            #if swift(>=6.1)
            self.glassEffect(.regular.interactive(), in: .capsule)
            #else
            self.background(.ultraThinMaterial, in: Capsule())
            #endif
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Apply adaptive glass effect with circle shape
    @ViewBuilder
    func adaptiveGlassCircle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            #if swift(>=6.1)
            self.glassEffect(.regular.interactive(), in: Circle())
            #else
            self.background(.ultraThinMaterial, in: Circle())
            #endif
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }

    /// Apply adaptive glass effect with rounded rectangle shape
    @ViewBuilder
    func adaptiveGlassRect(cornerRadius: CGFloat = 12) -> some View {
        if #available(iOS 26, macOS 26, *) {
            #if swift(>=6.1)
            self.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
            #else
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            #endif
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Apply adaptive glass effect with semantic color tint
    @ViewBuilder
    func adaptiveGlassTint(_ color: Color) -> some View {
        if #available(iOS 26, macOS 26, *) {
            #if swift(>=6.1)
            self.glassEffect(.regular.tint(color).interactive(), in: .capsule)
            #else
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            #endif
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        }
    }

    /// Apply adaptive glass effect with semantic color tint and rounded rectangle
    @ViewBuilder
    func adaptiveGlassTintRect(_ color: Color, cornerRadius: CGFloat = 12) -> some View {
        if #available(iOS 26, macOS 26, *) {
            #if swift(>=6.1)
            self.glassEffect(.regular.tint(color).interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
            #else
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(color.opacity(0.5), lineWidth: 1))
            #endif
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(color.opacity(0.5), lineWidth: 1))
        }
    }

    /// Apply adaptive bar background (for toolbars, tab bars)
    @ViewBuilder
    func adaptiveBarBackground() -> some View {
        if #available(iOS 26, macOS 26, *) {
            #if swift(>=6.1)
            self.glassEffect(.regular)
            #else
            self.background(.bar)
            #endif
        } else {
            self.background(.bar)
        }
    }

    /// Apply glass effect with accessibility support
    @ViewBuilder
    func adaptiveGlassAccessible() -> some View {
        self.modifier(AccessibleGlassModifier())
    }
}

// MARK: - Accessible Glass Modifier

private struct AccessibleGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.regularMaterial, in: Capsule())
        } else {
            content
                .adaptiveGlass()
        }
    }
}

// MARK: - Glass Button Style

/// Button style that applies glass effect
struct GlassButtonStyle: ButtonStyle {
    var tint: Color?
    var cornerRadius: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if let tint {
                    glassBackground(tint: tint, isPressed: configuration.isPressed)
                } else {
                    glassBackground(isPressed: configuration.isPressed)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }

    @ViewBuilder
    private func glassBackground(tint: Color? = nil, isPressed: Bool) -> some View {
        if #available(iOS 26, macOS 26, *) {
            #if swift(>=6.1)
            if let tint {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(tint).interactive())
            } else {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.interactive())
            }
            #else
            fallbackBackground(tint: tint, isPressed: isPressed)
            #endif
        } else {
            fallbackBackground(tint: tint, isPressed: isPressed)
        }
    }

    @ViewBuilder
    private func fallbackBackground(tint: Color?, isPressed: Bool) -> some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay {
                if let tint {
                    Capsule()
                        .stroke(tint.opacity(isPressed ? 0.8 : 0.5), lineWidth: 1)
                }
            }
            .opacity(isPressed ? 0.8 : 1.0)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }

    static func glass(tint: Color) -> GlassButtonStyle {
        GlassButtonStyle(tint: tint)
    }
}

// MARK: - Glass Card View

/// A card container with glass effect
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content

    init(cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding()
            .adaptiveGlassRect(cornerRadius: cornerRadius)
    }
}

// MARK: - Glass Toolbar

/// A toolbar container with glass effect
struct GlassToolbar<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlass()
    }
}

// MARK: - Glass Tab Bar Item

struct GlassTabItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(.quaternary)
            }
        }
    }
}

// MARK: - Preview

#Preview("Glass Buttons") {
    VStack(spacing: 20) {
        Button(String(localized: "Standard Glass")) {}
            .buttonStyle(GlassButtonStyle())

        Button(String(localized: "Tinted Glass")) {}
            .buttonStyle(GlassButtonStyle(tint: .green))

        Button(String(localized: "Red Tint")) {}
            .buttonStyle(GlassButtonStyle(tint: .red))
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}

#Preview("Glass Card") {
    GlassCard {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Server Name"))
                .font(.headline)
            Text(String(localized: "192.168.1.1:22"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}

#Preview("Glass Toolbar") {
    VStack {
        GlassToolbar {
            Button {} label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(String(localized: "Terminal"))
                .font(.headline)
            Spacer()
            Button {} label: {
                Image(systemName: "ellipsis")
            }
        }
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}
