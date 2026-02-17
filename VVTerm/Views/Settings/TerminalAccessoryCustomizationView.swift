import SwiftUI

struct TerminalAccessoryCustomizationView: View {
    @StateObject private var preferences = TerminalAccessoryPreferencesManager.shared
    @State private var showingCreateSnippetSheet = false

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

    private var activeSnippetIDs: Set<UUID> {
        Set(activeItems.compactMap { item in
            if case .snippet(let id) = item {
                return id
            }
            return nil
        })
    }

    private var availableSystemActions: [TerminalAccessorySystemActionID] {
        TerminalAccessoryProfile.availableSystemActions
            .filter { !activeSystemActions.contains($0) }
    }

    private var availableSnippets: [TerminalSnippet] {
        preferences.snippets.filter { !activeSnippetIDs.contains($0.id) }
    }

    private var hasAnySnippets: Bool {
        !preferences.snippets.isEmpty
    }

    private var activeSnippetsByID: [UUID: TerminalSnippet] {
        Dictionary(uniqueKeysWithValues: preferences.snippets.map { ($0.id, $0) })
    }

    var body: some View {
        Form {
            Section("Preview") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        previewChip("Ctrl")
                        previewChip("Alt")
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
                        if case .snippet = item {
                            Text("Snippet")
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
                    "Ctrl and Alt stay fixed. \(activeItems.count)/\(TerminalAccessoryProfile.maxActiveItems) active items."
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
                if availableSnippets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(hasAnySnippets ? "All snippets are already added." : "No snippets yet.")
                            .foregroundStyle(.secondary)
                        if hasAnySnippets {
                            Divider()
                        }
                        Button {
                            showingCreateSnippetSheet = true
                        } label: {
                            Label("Create Snippet", systemImage: "plus")
                        }
                        .disabled(!preferences.canCreateSnippet)
                    }
                } else {
                    ForEach(availableSnippets) { snippet in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snippet.title)
                                Text(snippet.sendMode.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Add") {
                                preferences.addActiveItem(.snippet(snippet.id))
                            }
                            .disabled(activeItems.count >= TerminalAccessoryProfile.maxActiveItems)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Available Snippets")
                    Spacer(minLength: 8)
                    Button {
                        showingCreateSnippetSheet = true
                    } label: {
                        Label("Create Snippet", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!preferences.canCreateSnippet)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $showingCreateSnippetSheet) {
            TerminalSnippetFormView()
        }
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
        case .snippet(let id):
            return activeSnippetsByID[id]?.title ?? "Snippet"
        }
    }
}
