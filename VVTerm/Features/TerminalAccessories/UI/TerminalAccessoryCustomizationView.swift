import SwiftUI

struct TerminalAccessoryCustomizationView: View {
    @EnvironmentObject private var preferences: TerminalAccessoryPreferencesManager
    @EnvironmentObject private var storeManager: StoreManager
    @State private var showingCreateActionSheet = false
    @State private var showingProGateAlert = false

    private var activeItems: [TerminalAccessoryItemRef] {
        preferences.activeItems
    }

    private var activeSystemActions: Set<TerminalAccessorySystemActionID> {
        Set(activeItems.compactMap { item in
            if case .system(let actionID) = item {
                return actionID
            }
            return nil
        })
    }

    private var activeCustomActionIDs: Set<UUID> {
        Set(activeItems.compactMap { item in
            if case .custom(let id) = item {
                return id
            }
            return nil
        })
    }

    private var availableSystemActions: [TerminalAccessorySystemActionID] {
        TerminalAccessoryProfile.availableSystemActions
            .filter { !activeSystemActions.contains($0) }
    }

    private var availableCustomActions: [TerminalAccessoryCustomAction] {
        preferences.customActions.filter { !activeCustomActionIDs.contains($0.id) }
    }

    private var hasAnyCustomActions: Bool {
        !preferences.customActions.isEmpty
    }

    private var activeCustomActionsByID: [UUID: TerminalAccessoryCustomAction] {
        Dictionary(uniqueKeysWithValues: preferences.customActions.map { ($0.id, $0) })
    }

    var body: some View {
        Form {
            Section("Preview") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        previewChip(String(localized: "Ctrl"))
                        previewChip(String(localized: "Alt"))
                        previewChip(String(localized: "Shift"))
                        ForEach(activeItems, id: \.self) { item in
                            previewChip(label(for: item))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                ForEach(activeItems, id: \.self) { item in
                    HStack(spacing: 10) {
                        Text(label(for: item))
                        Spacer(minLength: 8)
                        if let detail = detailLabel(for: item) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: preferences.removeActiveItems)
                .onMove(perform: preferences.moveActiveItems)
            } header: {
                Text("Active Items")
            } footer: {
                Text(
                    String(
                        format: String(localized: "Ctrl, Alt, and Shift stay fixed. Add Cmd if you want it on the bar. %lld/%lld active items."),
                        Int64(activeItems.count),
                        Int64(TerminalAccessoryProfile.maxActiveItems)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Available System Actions") {
                if availableSystemActions.isEmpty {
                    Text("All system actions are already added.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableSystemActions) { actionID in
                        HStack {
                            Text(actionID.listTitle)
                            Spacer(minLength: 8)
                            Button("Add") {
                                preferences.addActiveItem(.system(actionID))
                            }
                            .disabled(activeItems.count >= TerminalAccessoryProfile.maxActiveItems)
                        }
                    }
                }
            }

            Section {
                if availableCustomActions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            hasAnyCustomActions
                                ? String(localized: "All custom actions are already added.")
                                : String(localized: "No custom actions yet.")
                        )
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(availableCustomActions) { action in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title)
                                Text(action.detailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Add") {
                                preferences.addActiveItem(.custom(action.id))
                            }
                            .disabled(activeItems.count >= TerminalAccessoryProfile.maxActiveItems)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Available Custom Actions")
                    Spacer(minLength: 8)
                    Button {
                        if preferences.isCustomActionCreationProGated(
                            hasProAccess: storeManager.allowsProFeatures
                        ) {
                            showingProGateAlert = true
                        } else {
                            showingCreateActionSheet = true
                        }
                    } label: {
                        Label("Create Action", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!preferences.canCreateCustomAction)
                }
            }

            Section {
                Button("Reset to Default") {
                    preferences.resetToDefaultLayout()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Customize Accessory Bar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        #endif
        .proFeatureAlert(
            title: String(localized: "Custom Actions"),
            message: String(
                format: String(localized: "The free plan includes %lld custom actions. Upgrade to Pro for unlimited custom actions."),
                Int64(FreeTierLimits.maxCustomActions)
            ),
            source: .snippetLimit,
            isPresented: $showingProGateAlert
        )
        .sheet(isPresented: $showingCreateActionSheet) {
            TerminalCustomActionFormView()
                .adaptiveSoftScrollEdges()
        }
        .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private func previewChip(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    private func label(for item: TerminalAccessoryItemRef) -> String {
        switch item {
        case .system(let actionID):
            return actionID.listTitle
        case .custom(let id):
            return activeCustomActionsByID[id]?.title ?? String(localized: "Custom Action")
        }
    }

    private func detailLabel(for item: TerminalAccessoryItemRef) -> String? {
        switch item {
        case .system:
            return nil
        case .custom(let id):
            return activeCustomActionsByID[id]?.kind.title
        }
    }
}
