//
//  ViewTabConfigurationManager.swift
//  VVTerm
//

import Combine
import Foundation

@MainActor
protocol ConnectionViewTabConfigurationPersisting {
    func load() -> ConnectionViewTabConfiguration
    func save(_ configuration: ConnectionViewTabConfiguration)
}

@MainActor
final class ViewTabConfigurationManager: ObservableObject {
    private let persistence: any ConnectionViewTabConfigurationPersisting

    @Published private(set) var configuration: ConnectionViewTabConfiguration

    init(persistence: any ConnectionViewTabConfigurationPersisting) {
        self.persistence = persistence
        configuration = persistence.load()
    }

    var tabOrder: [ConnectionViewTabID] {
        configuration.order
    }

    var currentVisibleTabs: [ConnectionViewTabID] {
        configuration.orderedVisibleTabs
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        guard source.allSatisfy(configuration.order.indices.contains),
              destination >= 0,
              destination <= configuration.order.count else {
            return
        }

        var order = configuration.order
        let movingTabs = source.map { order[$0] }
        for index in source.sorted(by: >) {
            order.remove(at: index)
        }
        let removedBeforeDestination = source.count(in: ..<destination)
        order.insert(
            contentsOf: movingTabs,
            at: destination - removedBeforeDestination
        )
        updateConfiguration(
            ConnectionViewTabConfiguration(
                order: order,
                visibleTabs: configuration.visibleTabs,
                defaultTab: configuration.defaultTab
            )
        )
    }

    func setDefaultTab(_ tabID: ConnectionViewTabID) {
        updateConfiguration(
            ConnectionViewTabConfiguration(
                order: configuration.order,
                visibleTabs: configuration.visibleTabs,
                defaultTab: tabID
            )
        )
    }

    func setVisibility(for tabID: ConnectionViewTabID, isVisible: Bool) {
        var visibleTabs = configuration.visibleTabs

        if isVisible {
            visibleTabs.insert(tabID)
        } else {
            guard visibleTabs.contains(tabID), visibleTabs.count > 1 else { return }
            visibleTabs.remove(tabID)
        }

        updateConfiguration(
            ConnectionViewTabConfiguration(
                order: configuration.order,
                visibleTabs: visibleTabs,
                defaultTab: configuration.defaultTab
            )
        )
    }

    func resetToDefaults() {
        updateConfiguration(.default)
    }

    func effectiveDefaultTab() -> ConnectionViewTabID {
        configuration.effectiveDefaultTab
    }

    func isTabVisible(_ tabID: ConnectionViewTabID) -> Bool {
        configuration.visibleTabs.contains(tabID)
    }

    func effectiveView(for storedView: ConnectionViewTabID?) -> ConnectionViewTabID {
        configuration.effectiveView(for: storedView)
    }

    private func updateConfiguration(_ newConfiguration: ConnectionViewTabConfiguration) {
        guard newConfiguration != configuration else { return }
        configuration = newConfiguration
        persistence.save(newConfiguration)
    }
}
