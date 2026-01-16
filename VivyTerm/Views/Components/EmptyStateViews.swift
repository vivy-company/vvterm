//
//  EmptyStateViews.swift
//  VivyTerm
//

import SwiftUI

// MARK: - Empty State Views

struct ServerConnectEmptyState: View {
    let server: Server
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(server.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(verbatim: "\(server.username)@\(server.host):\(server.port)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onConnect) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                    Text("Connect")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoServerSelectedEmptyState: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "arrow.left.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 8) {
                    Text("Select a Server")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Choose a server from the sidebar to connect")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MultiConnectionUpgradeEmptyState: View {
    let server: Server
    @State private var showingTabLimitAlert = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "star.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)

                VStack(spacing: 8) {
                    Text(server.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Multiple connections require Pro")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text(String(
                        format: String(localized: "Free plan allows %lld active connection. Disconnect another server or upgrade."),
                        Int64(FreeTierLimits.maxTabs)
                    ))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Button {
                showingTabLimitAlert = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "star.fill")
                    Text("Upgrade to Pro")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.orange, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
    }
}

struct NoServersEmptyState: View {
    let onAddServer: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 8) {
                    Text("No Servers")
                        .font(.headline)
                        .fontWeight(.semibold)

                    Text("Add a server to get started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onAddServer) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Server")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
