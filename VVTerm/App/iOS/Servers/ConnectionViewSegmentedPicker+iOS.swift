//
//  ConnectionViewSegmentedPicker+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
import UIKit

struct ConnectionViewSegmentedPicker: UIViewRepresentable {
    @Binding var selection: ConnectionViewTabID
    let tabs: [ConnectionViewTabID]

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl()
        configure(control, tabs: tabs)
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        control.selectedSegmentIndex = selectedIndex
        control.apportionsSegmentWidthsByContent = true
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.tabs = tabs
        if context.coordinator.renderedTabs != tabs {
            configure(uiView, tabs: tabs)
            context.coordinator.renderedTabs = tabs
        }

        let resolvedSelection = tabs.contains(selection) ? selection : tabs.first ?? selection
        if resolvedSelection != selection {
            DispatchQueue.main.async {
                selection = resolvedSelection
            }
        }

        let targetIndex = selectedIndex
        guard uiView.selectedSegmentIndex != targetIndex else { return }
        UIView.performWithoutAnimation {
            uiView.selectedSegmentIndex = targetIndex
            uiView.setNeedsLayout()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        uiView.sizeToFit()
        return uiView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, tabs: tabs)
    }

    private var selectedIndex: Int {
        tabs.firstIndex(of: selection) ?? 0
    }

    private func configure(_ control: UISegmentedControl, tabs: [ConnectionViewTabID]) {
        control.removeAllSegments()
        for (index, tab) in tabs.enumerated() {
            control.insertSegment(with: UIImage(systemName: tab.icon), at: index, animated: false)
        }
        control.accessibilityLabel = tabs.map(\.localizedKey).joined(separator: ", ")
    }

    final class Coordinator: NSObject {
        var selection: Binding<ConnectionViewTabID>
        var tabs: [ConnectionViewTabID]
        var renderedTabs: [ConnectionViewTabID]

        init(selection: Binding<ConnectionViewTabID>, tabs: [ConnectionViewTabID]) {
            self.selection = selection
            self.tabs = tabs
            self.renderedTabs = tabs
        }

        @objc func valueChanged(_ sender: UISegmentedControl) {
            let index = sender.selectedSegmentIndex
            guard tabs.indices.contains(index) else { return }
            let selectedTabID = tabs[index]
            guard selection.wrappedValue != selectedTabID else { return }
            DispatchQueue.main.async { [selection] in
                selection.wrappedValue = selectedTabID
            }
        }
    }
}
#endif
