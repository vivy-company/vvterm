#if os(iOS)
import SwiftUI

struct IOSZenModePanel: View {
    let width: CGFloat
    let serverName: String
    let selectedView: ConnectionViewTabID
    let selectedViewBinding: Binding<ConnectionViewTabID>
    let viewTabs: [ConnectionViewTabID]
    let terminalTabs: [TerminalTab]
    let selectedTerminalTabId: Binding<UUID?>
    let terminalTabTitle: (TerminalTab) -> String
    let paneState: (TerminalTab) -> TerminalPaneState?
    let onCloseTerminalTab: (TerminalTab) -> Void
    let fileTabs: [RemoteFileTab]
    let selectedFileTabId: Binding<UUID?>
    let fileTabTitle: (RemoteFileTab) -> String
    let onSelectFileTab: (RemoteFileTab) -> Void
    let onCloseFileTab: (RemoteFileTab) -> Void
    let onNewTerminalTab: () -> Void
    let onNewFileTab: () -> Void
    let onOpenSettings: () -> Void
    let onEditServer: () -> Void
    let onDisconnect: () -> Void
    let onBack: () -> Void
    let onExitZen: () -> Void

    var body: some View {
        ZenModePanelCard(width: width) {
            ZenModeStatusLine(
                title: serverName,
                subtitle: statusText,
                indicatorColor: indicatorColor
            )

            ZenModeSection("View") {
                HStack(spacing: 8) {
                    ForEach(viewTabs) { tab in
                        ZenModeChoiceChip(
                            title: LocalizedStringKey(tab.localizedKey),
                            systemImage: tab.icon,
                            isSelected: selectedView == tab.id
                        ) {
                            selectedViewBinding.wrappedValue = tab.id
                        }
                        .accessibilityIdentifier("vvterm.terminal.zen.view.\(tab.rawValue)")
                    }
                }
            }

            ZenModeSection("Tabs") {
                ZenModeActionButton(title: "New Tab", systemImage: "plus") {
                    if selectedView == .files {
                        onNewFileTab()
                    } else {
                        onNewTerminalTab()
                    }
                }
                .accessibilityIdentifier("vvterm.terminal.zen.newTab")

                tabList
            }

            ZenModeSection("Server") {
                ZenModeActionButton(title: "Settings", systemImage: "gear", action: onOpenSettings)
                    .accessibilityIdentifier("vvterm.terminal.zen.settings")

                ZenModeActionButton(title: "Edit Server", systemImage: "pencil", action: onEditServer)
                    .accessibilityIdentifier("vvterm.terminal.zen.editServer")

                ZenModeActionButton(title: "Back", systemImage: "chevron.left", action: onBack)
                    .accessibilityIdentifier("vvterm.terminal.zen.back")
            }

            ZenModeSection("Session") {
                ZenModeActionButton(
                    title: "Disconnect",
                    systemImage: "xmark.circle",
                    tint: .red,
                    action: onDisconnect
                )
                .accessibilityIdentifier("vvterm.terminal.zen.disconnect")
            }

            ZenModeSection("Zen") {
                ZenModeActionButton(
                    title: "Exit Zen Mode",
                    systemImage: "arrow.down.right.and.arrow.up.left",
                    action: onExitZen
                )
                .accessibilityIdentifier("vvterm.terminal.exitZenMode")
            }
        }
        .accessibilityIdentifier("vvterm.terminal.zenPanel")
    }

    @ViewBuilder
    private var tabList: some View {
        if selectedView == .files {
            if fileTabs.isEmpty {
                emptyTabsLabel("No file tabs open.")
            } else {
                VStack(spacing: 8) {
                    ForEach(fileTabs) { tab in
                        fileTabRow(tab)
                    }
                }
            }
        } else if terminalTabs.isEmpty {
            emptyTabsLabel("No terminals open.")
        } else {
            VStack(spacing: 8) {
                ForEach(terminalTabs) { tab in
                    terminalTabRow(tab)
                }
            }
        }
    }

    private func emptyTabsLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func terminalTabRow(_ tab: TerminalTab) -> some View {
        let isSelected = selectedTerminalTabId.wrappedValue == tab.id
        let tint = paneState(tab)?.connectionState.statusTintColor ?? .secondary

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = .terminal
                selectedTerminalTabId.wrappedValue = tab.id
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(terminalTabTitle(tab))
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)

                        if tab.paneCount > 1 {
                            Text(String(format: String(localized: "%lld panes"), Int64(tab.paneCount)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(tabBackground(isSelected: isSelected))
            }
            .buttonStyle(.plain)

            closeButton {
                onCloseTerminalTab(tab)
            }
        }
    }

    private func fileTabRow(_ tab: RemoteFileTab) -> some View {
        let isSelected = selectedFileTabId.wrappedValue == tab.id

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = .files
                selectedFileTabId.wrappedValue = tab.id
                onSelectFileTab(tab)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)

                    Text(fileTabTitle(tab))
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(tabBackground(isSelected: isSelected))
            }
            .buttonStyle(.plain)

            closeButton {
                onCloseFileTab(tab)
            }
        }
    }

    private func tabBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.14 : 0.07))
    }

    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.12))
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close"))
    }

    private var statusText: String {
        if selectedView == .files {
            return fileTabs.isEmpty
                ? String(localized: "No open file tabs")
                : String(format: String(localized: "%lld open file tabs"), Int64(fileTabs.count))
        }

        return terminalTabs.isEmpty
            ? String(localized: "No open terminals")
            : String(format: String(localized: "%lld open tabs"), Int64(terminalTabs.count))
    }

    private var indicatorColor: Color {
        if selectedView == .files {
            return fileTabs.isEmpty ? .secondary : .green
        }

        guard let selectedId = selectedTerminalTabId.wrappedValue,
              let selectedTab = terminalTabs.first(where: { $0.id == selectedId }) else {
            return terminalTabs.isEmpty ? .secondary : .green
        }
        return paneState(selectedTab)?.connectionState.statusTintColor ?? .secondary
    }
}
#endif
