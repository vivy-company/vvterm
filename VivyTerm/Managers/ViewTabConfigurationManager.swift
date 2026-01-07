//
//  ViewTabConfigurationManager.swift
//  VivyTerm
//

import Foundation
import SwiftUI
import Combine
import os.log

extension Notification.Name {
    static let viewTabConfigurationDidChange = Notification.Name("viewTabConfigurationDidChange")
}

class ViewTabConfigurationManager: ObservableObject {
    static let shared = ViewTabConfigurationManager()

    private let defaults: UserDefaults
    private let orderKey = "connectionViewTabOrder"
    private let defaultTabKey = "connectionDefaultViewTab"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivy.vivyterm", category: "ViewTabConfigurationManager")

    @Published private(set) var tabOrder: [ConnectionViewTab] = ConnectionViewTab.defaultOrder
    @Published private(set) var defaultTab: String = "stats"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadConfiguration()
    }

    // MARK: - Load/Save

    private func loadConfiguration() {
        loadTabOrder()
        loadDefaultTab()
    }

    private func loadTabOrder() {
        guard let data = defaults.data(forKey: orderKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            tabOrder = ConnectionViewTab.defaultOrder
            return
        }

        // Rebuild order from stored IDs, validating each exists
        var order: [ConnectionViewTab] = []
        for id in decoded {
            if let tab = ConnectionViewTab.from(id: id) {
                order.append(tab)
            }
        }

        // Add any missing tabs at the end (future-proofing)
        for defaultTab in ConnectionViewTab.defaultOrder {
            if !order.contains(defaultTab) {
                order.append(defaultTab)
            }
        }

        tabOrder = order
    }

    private func loadDefaultTab() {
        if let stored = defaults.string(forKey: defaultTabKey),
           ConnectionViewTab.from(id: stored) != nil {
            defaultTab = stored
        } else {
            defaultTab = "stats"
        }
    }

    private func saveTabOrder() {
        do {
            let ids = tabOrder.map { $0.id }
            let data = try JSONEncoder().encode(ids)
            defaults.set(data, forKey: orderKey)
            NotificationCenter.default.post(name: .viewTabConfigurationDidChange, object: nil)
        } catch {
            logger.error("Failed to encode tab order: \(error.localizedDescription)")
        }
    }

    private func saveDefaultTab() {
        defaults.set(defaultTab, forKey: defaultTabKey)
        NotificationCenter.default.post(name: .viewTabConfigurationDidChange, object: nil)
    }

    // MARK: - Public API

    func moveTab(from source: IndexSet, to destination: Int) {
        tabOrder.move(fromOffsets: source, toOffset: destination)
        saveTabOrder()
    }

    func setDefaultTab(_ tabId: String) {
        guard ConnectionViewTab.from(id: tabId) != nil else { return }
        defaultTab = tabId
        saveDefaultTab()
    }

    func resetToDefaults() {
        tabOrder = ConnectionViewTab.defaultOrder
        defaultTab = "stats"
        saveTabOrder()
        saveDefaultTab()
    }

    /// Returns the first tab from the configured order
    func firstTab() -> String {
        tabOrder.first?.id ?? "stats"
    }

    /// Returns the effective default tab
    func effectiveDefaultTab() -> String {
        let showStats = defaults.object(forKey: "showStatsTab") as? Bool ?? true
        let showTerminal = defaults.object(forKey: "showTerminalTab") as? Bool ?? true
        return effectiveDefaultTab(showStats: showStats, showTerminal: showTerminal)
    }

    /// Returns the effective default tab, accounting for visibility
    func effectiveDefaultTab(showStats: Bool, showTerminal: Bool) -> String {
        let isVisible: Bool
        switch defaultTab {
        case "stats": isVisible = showStats
        case "terminal": isVisible = showTerminal
        default: isVisible = false
        }

        if isVisible {
            return defaultTab
        }

        // Default tab is hidden, fall back to first visible
        return firstVisibleTab(showStats: showStats, showTerminal: showTerminal)
    }

    /// Returns the first visible tab from the configured order
    func firstVisibleTab(showStats: Bool, showTerminal: Bool) -> String {
        for tab in tabOrder {
            switch tab.id {
            case "stats" where showStats: return "stats"
            case "terminal" where showTerminal: return "terminal"
            default: continue
            }
        }
        return "terminal" // Fallback - terminal should always work
    }

    /// Returns only visible tabs in order
    func visibleTabs(showStats: Bool, showTerminal: Bool) -> [ConnectionViewTab] {
        tabOrder.filter { tab in
            switch tab.id {
            case "stats": return showStats
            case "terminal": return showTerminal
            default: return false
            }
        }
    }
}
