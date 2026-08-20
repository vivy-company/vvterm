import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ClassicStatsCardSurfaceStyle: Equatable {
    let fill: Color
    let stroke: Color
    let pageBackground: Color

    static func make(for backgroundColor: Color) -> ClassicStatsCardSurfaceStyle {
        #if os(iOS)
        ClassicStatsCardSurfaceStyle(
            fill: Color(UIColor.secondarySystemGroupedBackground),
            stroke: .clear,
            pageBackground: Color(UIColor.systemGroupedBackground)
        )
        #else
        ClassicStatsCardSurfaceStyle(
            fill: Color.primary.opacity(0.06),
            stroke: Color.primary.opacity(0.08),
            pageBackground: backgroundColor
        )
        #endif
    }
}

private struct ClassicStatsCardModifier: ViewModifier {
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background(surfaceStyle.fill, in: shape)
            .overlay {
                shape.stroke(surfaceStyle.stroke, lineWidth: 1)
            }
    }
}

extension View {
    func classicStatsCardSurface(_ surfaceStyle: ClassicStatsCardSurfaceStyle) -> some View {
        modifier(ClassicStatsCardModifier(surfaceStyle: surfaceStyle))
    }
}

enum StatsIcon {
    static let gpu = "display"
}

struct StatsVisualStyle {
    enum Density {
        case compact
        case detailed
        case classic
    }

    enum Surface {
        case dashboard
        case grouped
    }

    let density: Density
    let pageBackground: Color
    let cardFill: Color
    let cardStroke: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let meterTrack: Color

    init(
        preferencesStyle: StatsPreferences.Style = .cardsCompact,
        surface: Surface = .dashboard,
        colorScheme: ColorScheme = .dark
    ) {
        switch preferencesStyle {
        case .cardsCompact:
            density = .compact
        case .cardsDetailed:
            density = .detailed
        case .classic:
            density = .classic
        }

        switch surface {
        case .dashboard:
            #if os(macOS)
            pageBackground = colorScheme == .light ? Self.nativeGroupedBackground : .clear
            #else
            pageBackground = Self.nativeGroupedBackground
            #endif
            if preferencesStyle == .classic {
                cardFill = Color.white.opacity(0.08)
                cardStroke = Color.white.opacity(0.06)
            } else {
                if colorScheme == .light {
                    cardFill = Self.nativeGroupedCardFill
                    cardStroke = Self.nativeGroupedCardStroke
                } else {
                    #if os(macOS)
                    cardFill = Color.white.opacity(0.045)
                    cardStroke = Color.white.opacity(0.075)
                    #else
                    cardFill = Color(red: 0.11, green: 0.11, blue: 0.12)
                    cardStroke = Color.white.opacity(0.04)
                    #endif
                }
            }
            if colorScheme == .light, preferencesStyle != .classic {
                primaryText = Color.primary
                secondaryText = Color.secondary
                tertiaryText = Color.secondary.opacity(0.45)
                meterTrack = Color.primary.opacity(0.10)
            } else {
                primaryText = Color.white
                secondaryText = Color.white.opacity(0.58)
                tertiaryText = Color.white.opacity(0.34)
                meterTrack = Color.white.opacity(0.10)
            }
        case .grouped:
            pageBackground = Self.nativeGroupedBackground
            cardFill = Self.nativeGroupedCardFill
            cardStroke = Self.nativeGroupedCardStroke
            primaryText = Color.primary
            secondaryText = Color.secondary
            tertiaryText = Color.secondary.opacity(0.35)
            meterTrack = Color.primary.opacity(0.10)
        }
    }

    var cardSpacing: CGFloat {
        density == .detailed ? 18 : 14
    }

    var gridMinimumColumnWidth: CGFloat {
        density == .detailed ? 320 : 292
    }

    var gridMaximumWidth: CGFloat {
        density == .detailed ? 1_360 : 1_180
    }

    var horizontalPadding: CGFloat {
        density == .detailed ? 18 : 14
    }

    var topPadding: CGFloat {
        density == .detailed ? 22 : 16
    }

    var bottomPadding: CGFloat {
        density == .detailed ? 28 : 22
    }

    var cardPadding: CGFloat {
        density == .detailed ? 22 : 18
    }

    var cardCornerRadius: CGFloat {
        density == .classic ? 22 : 28
    }

    var titleSize: CGFloat {
        density == .detailed ? 44 : 38
    }

    var prominentValueSize: CGFloat {
        density == .detailed ? 44 : 38
    }

    var metricValueSize: CGFloat {
        density == .detailed ? 44 : 38
    }

    var networkValueSize: CGFloat {
        density == .detailed ? 34 : 30
    }

    var metricPreviewWidth: CGFloat {
        density == .detailed ? 168 : 136
    }

    var metricPreviewHeight: CGFloat {
        density == .detailed ? 118 : 92
    }

    var overviewMinHeight: CGFloat {
        density == .detailed ? 164 : 136
    }

    var metricMinHeight: CGFloat {
        density == .detailed ? 196 : 164
    }

    var networkMinHeight: CGFloat {
        density == .detailed ? 246 : 222
    }

    var networkChartHeight: CGFloat {
        density == .detailed ? 142 : 122
    }

    var networkValuesWidth: CGFloat {
        density == .detailed ? 150 : 132
    }

    var processLimit: Int {
        density == .detailed ? 5 : 4
    }

    var volumeLimit: Int {
        density == .detailed ? 6 : 4
    }

    private static var nativeGroupedBackground: Color {
        #if os(iOS)
        Color(UIColor.systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }

    private static var nativeGroupedCardFill: Color {
        #if os(iOS)
        Color(UIColor.secondarySystemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    private static var nativeGroupedCardStroke: Color {
        #if os(iOS)
        Color(UIColor.separator).opacity(0.28)
        #elseif os(macOS)
        Color(nsColor: .separatorColor).opacity(0.45)
        #else
        Color.primary.opacity(0.08)
        #endif
    }
}

enum StatsResolvedAppearance {
    static let storageKey = "appearanceMode"

    static func colorScheme(from rawValue: String, fallback: ColorScheme) -> ColorScheme {
        switch rawValue {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return fallback
        }
    }
}
