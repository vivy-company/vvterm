import SwiftUI

struct NavigationStatsSettingsView: View {
    let statsPreferencesStore: PreferencesStore

    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager
    @State private var isShowingStatsAppearance = false

    var body: some View {
        Form {
            Section {
                if viewTabConfig.currentVisibleTabs.isEmpty {
                    Text("At least one server view must remain enabled.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewTabConfig.tabOrder) { tab in
                        HStack(spacing: 12) {
                            Label(tab.localizedKey, systemImage: tab.icon)
                                .labelStyle(.titleAndIcon)

                            Spacer(minLength: 8)

                            Toggle("", isOn: visibilityBinding(for: tab.id))
                                .labelsHidden()
                        }
                    }
                    .onMove(perform: viewTabConfig.moveTab)
                }

                Button {
                    viewTabConfig.resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            } header: {
                HStack {
                    Text("Views")
                    Spacer()
                    #if os(iOS)
                    EditButton()
                    #endif
                }
            } footer: {
                Text("Choose which views appear. Drag rows to change their order.")
            }

            Section {
                Picker("Open Servers In", selection: defaultTabBinding) {
                    ForEach(viewTabConfig.currentVisibleTabs) { tab in
                        Label(tab.localizedKey, systemImage: tab.icon)
                            .tag(tab.id)
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("VVTerm uses the first enabled view if this view is unavailable.")
            }

            Section("View Options") {
                Button {
                    isShowingStatsAppearance = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stats")
                            Text("Appearance and layout")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vvterm.settings.navigationAndStats.statsAppearance")
            }
        }
        .statsDetailPresentation(
            isPresented: $isShowingStatsAppearance,
            size: StatsPresentationSize.large
        ) {
            StatsAppearanceSettingsSheet(store: statsPreferencesStore)
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.navigationAndStats")
    }

    private func visibilityBinding(for tabID: ConnectionViewTabID) -> Binding<Bool> {
        Binding(
            get: { viewTabConfig.isTabVisible(tabID) },
            set: { viewTabConfig.setVisibility(for: tabID, isVisible: $0) }
        )
    }

    private var defaultTabBinding: Binding<ConnectionViewTabID> {
        Binding(
            get: { viewTabConfig.effectiveDefaultTab() },
            set: { viewTabConfig.setDefaultTab($0) }
        )
    }
}
