import SwiftUI

struct StatsAppearanceSettingsSheet: View {
    let store: PreferencesStore

    var body: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "Stats Appearance"),
            systemImage: "slider.horizontal.3",
            tint: .blue
        ) {
            AppearanceSettings(store: store)
        }
        #else
        NavigationStack {
            AppearanceSettings(store: store)
                .navigationTitle(Text("Stats Appearance"))
                .navigationBarTitleDisplayMode(.inline)
                .statsSheetCloseToolbar(placement: .leading)
        }
        .presentationDetents([.large])
        .adaptiveSoftScrollEdges()
        #endif
    }
}

struct AppearanceSettings: View {
    @ObservedObject private var store: PreferencesStore
    @State private var preferences: StatsPreferences
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    init(store: PreferencesStore) {
        _store = ObservedObject(wrappedValue: store)
        _preferences = State(initialValue: store.preferences)
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Presentation"), selection: styleBinding) {
                    ForEach(StatsPreferences.Style.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(String(localized: "Layout")) {
                ForEach(preferences.orderedBlocks) { block in
                    StatsBlockLayoutRow(
                        block: block,
                        isVisible: visibilityBinding(for: block.id),
                        subtitle: visibilitySubtitle(for: block)
                    )
                }
                .onMove { source, destination in
                    moveBlocks(fromOffsets: source, toOffset: destination)
                }
            }

            Section(String(localized: "Preview")) {
                StatsAppearancePreviewContent(preferences: preferences)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .environment(\.editMode, $editMode)
        .toolbar {
            Button(editMode.isEditing ? String(localized: "Done") : String(localized: "Edit")) {
                editMode = editMode.isEditing ? .inactive : .active
            }
        }
        #endif
        .onChange(of: store.preferences) { newPreferences in
            preferences = newPreferences
        }
    }

    private var styleBinding: Binding<StatsPreferences.Style> {
        Binding(
            get: { preferences.style },
            set: { style in
                store.setStyle(style)
                preferences = store.preferences
            }
        )
    }

    private func visibilityBinding(for id: StatsPreferences.BlockID) -> Binding<Bool> {
        Binding(
            get: { preferences.isBlockVisible(id) },
            set: { isVisible in
                store.setBlockVisibility(id, isVisible: isVisible)
                preferences = store.preferences
            }
        )
    }

    private func moveBlocks(fromOffsets source: IndexSet, toOffset destination: Int) {
        var blocks = preferences.orderedBlocks
        moveLocalBlocks(&blocks, fromOffsets: source, toOffset: destination)
        store.setBlockOrder(blocks.map(\.id))
        preferences = store.preferences
    }

    private func moveLocalBlocks(
        _ blocks: inout [StatsPreferences.Block],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        let validSource = IndexSet(source.filter { blocks.indices.contains($0) })
        guard !validSource.isEmpty else { return }

        let movingBlocks = validSource.map { blocks[$0] }
        for index in validSource.sorted(by: >) {
            blocks.remove(at: index)
        }

        let removedBeforeDestination = validSource.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - removedBeforeDestination, blocks.count))
        blocks.insert(contentsOf: movingBlocks, at: adjustedDestination)
    }

    private func visibilitySubtitle(for block: StatsPreferences.Block) -> String {
        if block.id == .system {
            return String(localized: "Required")
        }
        return block.isVisible ? String(localized: "Visible") : String(localized: "Hidden")
    }
}

private struct StatsBlockLayoutRow: View {
    let block: StatsPreferences.Block
    @Binding var isVisible: Bool
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: block.id.systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(block.id.tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(block.id.title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle(isOn: $isVisible) {
                EmptyView()
            }
            .labelsHidden()
            .disabled(block.id == .system)
        }
        .contentShape(Rectangle())
    }
}

private extension StatsPreferences.Style {
    var title: String {
        switch self {
        case .cardsCompact:
            return String(localized: "Cards Compact")
        case .cardsDetailed:
            return String(localized: "Cards Detailed")
        case .classic:
            return String(localized: "Classic")
        }
    }
}

private extension StatsPreferences.BlockID {
    var title: String {
        switch self {
        case .system:
            return String(localized: "System")
        case .cpu:
            return String(localized: "CPU")
        case .memory:
            return String(localized: "Memory")
        case .gpu:
            return String(localized: "GPU")
        case .network:
            return String(localized: "Network")
        case .storage:
            return String(localized: "Storage")
        case .processes:
            return String(localized: "Processes")
        case .docker:
            return String(localized: "Docker")
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "server.rack"
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .gpu:
            return "display"
        case .network:
            return "arrow.up.arrow.down"
        case .storage:
            return "internaldrive"
        case .processes:
            return "list.bullet.rectangle"
        case .docker:
            return "shippingbox"
        }
    }

    var tint: Color {
        switch self {
        case .system:
            return .cyan
        case .cpu:
            return .pink
        case .memory:
            return .blue
        case .gpu:
            return .green
        case .network:
            return .cyan
        case .storage:
            return .orange
        case .processes:
            return .purple
        case .docker:
            return .blue
        }
    }
}
