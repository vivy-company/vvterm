import SwiftUI

struct TmuxAttachPromptSheet: View {
    let prompt: TmuxAttachPrompt
    let onConfirm: (TmuxAttachSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    private var hasSessions: Bool {
        !prompt.existingSessionNames.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if hasSessions {
                    Section {
                        ForEach(prompt.existingSessionNames, id: \.self) { name in
                            Button {
                                confirm(.attachExisting(sessionName: name))
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "terminal")
                                        .foregroundStyle(.secondary)
                                    Text(name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Existing sessions")
                    } footer: {
                        Text("Select a session to attach immediately.")
                    }
                } else {
                    Section {
                        noSessionsView
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    Button {
                        confirm(.createManaged)
                    } label: {
                        Label("New session", systemImage: "plus.rectangle.on.rectangle")
                    }

                    Button {
                        confirm(.skipTmux)
                    } label: {
                        Label("Skip tmux", systemImage: "arrow.right.circle")
                    }
                } header: {
                    Text("Actions")
                }
            }
            .navigationTitle("Tmux on Connect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            #else
            .listStyle(.inset)
            .frame(minWidth: 360, minHeight: 300)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var noSessionsView: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            ContentUnavailableView(
                "No tmux sessions found",
                systemImage: "terminal",
                description: Text("Create a new session, or continue without tmux.")
            )
        } else {
            VStack(spacing: 8) {
                Label("No tmux sessions found", systemImage: "terminal")
                    .font(.headline)
                Text("Create a new session, or continue without tmux.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 8)
        }
    }

    private func confirm(_ selection: TmuxAttachSelection) {
        onConfirm(selection)
        dismiss()
    }
}
