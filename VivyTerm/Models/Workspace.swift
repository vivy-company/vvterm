import Foundation
import SwiftUI

// MARK: - Workspace Model (CloudKit synced)

struct Workspace: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var colorHex: String
    var icon: String?
    var order: Int
    var environments: [ServerEnvironment]
    var lastSelectedEnvironmentId: UUID?
    var lastSelectedServerId: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#007AFF",
        icon: String? = nil,
        order: Int = 0,
        environments: [ServerEnvironment] = ServerEnvironment.builtInEnvironments,
        lastSelectedEnvironmentId: UUID? = nil,
        lastSelectedServerId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.order = order
        self.environments = environments
        self.lastSelectedEnvironmentId = lastSelectedEnvironmentId
        self.lastSelectedServerId = lastSelectedServerId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var color: Color {
        Color.fromHex(colorHex)
    }

    static let defaultColors: [String] = [
        "#007AFF", // Blue (default)
        "#AF52DE", // Purple
        "#FF2D55", // Pink
        "#FF3B30", // Red
        "#FF9500", // Orange
        "#FFCC00", // Yellow
        "#34C759", // Green
        "#5AC8FA", // Teal
        "#00C7BE", // Cyan
        "#5856D6"  // Indigo
    ]
}

// MARK: - Server Environment Model

struct ServerEnvironment: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var shortName: String
    var colorHex: String
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        shortName: String,
        colorHex: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
    }

    var color: Color {
        Color.fromHex(colorHex)
    }

    var displayName: String {
        guard isBuiltIn else { return name }
        switch id {
        case ServerEnvironment.production.id:
            return String(localized: "Production")
        case ServerEnvironment.staging.id:
            return String(localized: "Staging")
        case ServerEnvironment.development.id:
            return String(localized: "Development")
        default:
            return name
        }
    }

    var displayShortName: String {
        guard isBuiltIn else { return shortName }
        switch id {
        case ServerEnvironment.production.id:
            return String(localized: "Prod")
        case ServerEnvironment.staging.id:
            return String(localized: "Stag")
        case ServerEnvironment.development.id:
            return String(localized: "Dev")
        default:
            return shortName
        }
    }

    // MARK: - Built-in Environments

    static let production = ServerEnvironment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Production",
        shortName: "Prod",
        colorHex: "#FF3B30",
        isBuiltIn: true
    )

    static let staging = ServerEnvironment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Staging",
        shortName: "Stag",
        colorHex: "#FF9500",
        isBuiltIn: true
    )

    static let development = ServerEnvironment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Development",
        shortName: "Dev",
        colorHex: "#007AFF",
        isBuiltIn: true
    )

    static let builtInEnvironments: [ServerEnvironment] = [.production, .staging, .development]
}

// MARK: - Color Extension

extension Color {
    static func fromHex(_ hex: String) -> Color {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        return Color(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
