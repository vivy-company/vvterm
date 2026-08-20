//
//  EnvironmentFilterMenu+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
// MARK: - Environment Filter Menu

struct EnvironmentFilterMenu: View {
    @Binding var selected: ServerEnvironment?
    let environments: [ServerEnvironment]
    let serverCounts: [UUID: Int]
    let onCreateCustom: () -> Void
    let onEditCustom: (ServerEnvironment) -> Void
    let onDeleteCustom: (ServerEnvironment) -> Void

    private var totalCount: Int {
        serverCounts.values.reduce(0, +)
    }

    var body: some View {
        Menu {
            // Built-in environments
            ForEach(ServerEnvironment.builtInEnvironments) { env in
                environmentButton(env)
            }

            // Custom environments
            let customEnvs = environments.filter { !$0.isBuiltIn }
            if !customEnvs.isEmpty {
                Divider()
                ForEach(customEnvs) { env in
                    environmentButton(env)
                }
            }

            Divider()

            Button {
                selected = nil
            } label: {
                HStack {
                    Text("All")
                    Spacer()
                    Text(String(format: String(localized: "(%lld)"), Int64(totalCount)))
                        .foregroundStyle(.secondary)
                    if selected == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                onCreateCustom()
            } label: {
                Label(String(localized: "Custom..."), systemImage: "plus")
            }

            if let selectedEnvironment = selected, !selectedEnvironment.isBuiltIn {
                Divider()

                Button {
                    onEditCustom(selectedEnvironment)
                } label: {
                    Label(
                        String(format: String(localized: "Edit \"%@\"..."), selectedEnvironment.displayName),
                        systemImage: "pencil"
                    )
                }

                Button(role: .destructive) {
                    onDeleteCustom(selectedEnvironment)
                } label: {
                    Label(
                        String(format: String(localized: "Delete \"%@\"..."), selectedEnvironment.displayName),
                        systemImage: "trash"
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(selected?.displayShortName ?? String(localized: "All"))
                    .font(.caption)
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func environmentButton(_ env: ServerEnvironment) -> some View {
        Button {
            selected = env
        } label: {
            HStack {
                Circle()
                    .fill(env.color)
                    .frame(width: 8, height: 8)
                Text(env.displayName)
                Spacer()
                Text(String(format: String(localized: "(%lld)"), Int64(serverCounts[env.id] ?? 0)))
                    .foregroundStyle(.secondary)
                if selected?.id == env.id {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
#endif
