#if os(iOS)
import SwiftUI

extension SettingsView {
    var platformBody: some View {
        NavigationStack {
            List {
                ForEach(visibleRoutes(from: SettingsRouteCatalog.leadingRoutes)) { route in
                    NavigationLink(value: route) {
                        routeLabel(for: route)
                    }
                }

                ForEach(SettingsRouteCatalog.groups) { group in
                    let routes = visibleRoutes(in: group)
                    if !routes.isEmpty {
                        Section(group.title) {
                            ForEach(routes) { route in
                                NavigationLink(value: route) {
                                    routeLabel(for: route)
                                }
                            }
                        }
                    }
                }

                ForEach(visibleRoutes(from: SettingsRouteCatalog.trailingRoutes)) { route in
                    NavigationLink(value: route) {
                        routeLabel(for: route)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search Settings"))
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(for: route)
                    .navigationTitle(route.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .adaptiveSoftScrollEdges()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("vvterm.settings.close")
                }
            }
        }
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.root")
    }

}
#endif
