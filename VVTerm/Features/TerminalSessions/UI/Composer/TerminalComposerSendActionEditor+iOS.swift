#if os(iOS)
import SwiftUI

struct TerminalComposerSendActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var action: TerminalComposerSendAction
    let onSave: (TerminalComposerSendAction) -> Void

    init(action: TerminalComposerSendAction, onSave: @escaping (TerminalComposerSendAction) -> Void) {
        _action = State(initialValue: action)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $action.name)
                    .accessibilityIdentifier("vvterm.composer.action-name")
            } header: { Text("Custom Action") } footer: {
                Text(String(format: String(localized: "Title length: %lld/%lld"), Int64(action.name.count), 120))
            }
            Section {
                ForEach($action.steps) { $step in
                    NavigationLink {
                        TerminalComposerSendStepEditor(step: $step)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title)
                                if let detail = step.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        } icon: { Image(systemName: step.symbol).foregroundStyle(.secondary) }
                    }
                    .accessibilityIdentifier("vvterm.composer.step.\(step.id)")
                }
                .onDelete { action.steps.remove(atOffsets: $0) }
                .onMove { action.steps.move(fromOffsets: $0, toOffset: $1) }
                Menu {
                    Button("Insert draft") { action.steps.append(.insertDraft) }
                    Button("Text") { action.steps.append(.text("")) }
                    Button("Shortcut") { action.steps.append(.key(.enter, .none)) }
                } label: {
                    Label("Add Step", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(action.steps.count >= 64)
                .accessibilityIdentifier("vvterm.composer.add-step")
            } header: {
                HStack { Text("Steps"); Spacer(); EditButton().textCase(nil) }
            } footer: {
                Text("Steps run in order.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Send Action")
        .navigationBarTitleDisplayMode(.inline)
        .adaptiveSoftScrollEdges()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { SheetDismissButton(title: "Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                SheetConfirmationButton(title: "Save") { onSave(action) }
                    .disabled(!TerminalComposerSendActions(actions: [action]).isValid)
                    .accessibilityIdentifier("vvterm.composer.save-action")
            }
        }
    }
}
#endif
