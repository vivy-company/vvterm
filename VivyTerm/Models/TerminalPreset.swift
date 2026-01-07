//
//  TerminalPreset.swift
//  aizen
//
//  Created by Uladzislau Yakauleu on 10.12.25.
//

import Foundation

/// Preset configuration for launching terminal sessions
struct TerminalPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var command: String
    var icon: String
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        icon: String = "terminal",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.isBuiltIn = isBuiltIn
    }

    static let defaultTerminal = TerminalPreset(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Terminal",
        command: "",
        icon: "terminal",
        isBuiltIn: true
    )
}
