import SwiftUI

struct TmuxAttachPromptSheet: View {
    let prompt: TmuxAttachPrompt
    let onConfirm: (TmuxAttachSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    private var hasSessions: Bool {
        !prompt.existingSessions.isEmpty
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            contentBody
            .navigationTitle("Choose tmux session")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionRow
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    closeButton
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        #else
        VStack(spacing: 0) {
            macHeader

            Divider()

            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            actionRow
        }
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(spacing: 12) {
            Text("Choose tmux session")
                .font(.title3.weight(.semibold))
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
    #endif

    @ViewBuilder
    private var contentBody: some View {
        if hasSessions {
            #if os(macOS)
            Form {
                Section {
                    ForEach(prompt.existingSessions) { session in
                        Button {
                            confirm(.attachExisting(sessionName: session.name))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "terminal")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(sessionDetailsText(for: session))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
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
            }
            .formStyle(.grouped)
            #else
            List {
                Section {
                    ForEach(prompt.existingSessions) { session in
                        Button {
                            confirm(.attachExisting(sessionName: session.name))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "terminal")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(sessionDetailsText(for: session))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
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
            }
            .listStyle(.insetGrouped)
            #endif
        } else {
            VStack {
                Spacer(minLength: 0)
                noSessionsView
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
    }

    private func sessionDetailsText(for session: TmuxAttachSessionInfo) -> String {
        let attachment = session.attachedClients > 0 ? "Attached" : "Detached"
        let clients = session.attachedClients == 1 ? "1 client" : "\(session.attachedClients) clients"
        let windows = session.windowCount == 1 ? "1 window" : "\(session.windowCount) windows"
        return "\(attachment) • \(clients) • \(windows)"
    }

    private var actionRow: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Button {
                confirm(.skipTmux)
            } label: {
                Label("Skip tmux", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 38)
                    .font(.callout.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 220)

            Button {
                confirm(.createManaged)
            } label: {
                Label("New session", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 38)
                    .font(.callout.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(.white)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 220)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        #else
        VStack(spacing: 10) {
            Button {
                confirm(.createManaged)
            } label: {
                Label("New session", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)

            Button {
                confirm(.skipTmux)
            } label: {
                Label("Skip tmux", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            #if os(macOS)
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                )
            #else
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
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
