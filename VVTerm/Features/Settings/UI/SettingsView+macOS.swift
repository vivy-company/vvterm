#if os(macOS)
import SwiftUI

private extension View {
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

extension SettingsView {
    var platformBody: some View {
        NavigationSplitView {
            List(selection: $selectedRouteRaw) {
                ForEach(visibleRoutes(from: SettingsRouteCatalog.leadingRoutes)) { route in
                    routeLabel(for: route)
                        .tag(route.rawValue)
                }

                ForEach(SettingsRouteCatalog.groups) { group in
                    let routes = visibleRoutes(in: group)
                    if !routes.isEmpty {
                        Section(group.title) {
                            ForEach(routes) { route in
                                routeLabel(for: route)
                                    .tag(route.rawValue)
                            }
                        }
                    }
                }

                ForEach(visibleRoutes(from: SettingsRouteCatalog.trailingRoutes)) { route in
                    routeLabel(for: route)
                        .tag(route.rawValue)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search Settings"))
            .frame(minWidth: 240, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(240)
            .removingSidebarToggle()
        } detail: {
            if let visibleDetailRoute {
                destination(for: visibleDetailRoute)
                    .navigationTitle(visibleDetailRoute.title)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Search Settings")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { Text("") }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
        .accessibilityIdentifier("vvterm.settings.root")
    }
}
#endif
