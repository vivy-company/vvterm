//
//  ConnectionTabComponents.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Connection Tabs Scroll View

struct ConnectionTabsScrollView: View {
    @ObservedObject var sessionManager: ConnectionSessionManager
    let onNew: () -> Void

    @State private var isNewTabHovering = false
    @State private var showingProUpgrade = false

    var body: some View {
        HStack(spacing: 4) {
            // Navigation arrows group
            HStack(spacing: 4) {
                NavigationArrowButton(
                    icon: "chevron.left",
                    action: { sessionManager.selectPreviousSession() },
                    help: "Previous tab"
                )
                .disabled(sessionManager.sessions.count <= 1)

                NavigationArrowButton(
                    icon: "chevron.right",
                    action: { sessionManager.selectNextSession() },
                    help: "Next tab"
                )
                .disabled(sessionManager.sessions.count <= 1)
            }
            .padding(.leading, 8)

            // Tabs scroll view
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessionManager.sessions, id: \.id) { session in
                        ConnectionTabButton(
                            session: session,
                            isSelected: sessionManager.selectedSessionId == session.id,
                            onSelect: { sessionManager.selectSession(session) },
                            onClose: { sessionManager.closeSession(session) }
                        )
                        .contextMenu { tabContextMenu(session) }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: 600, maxHeight: 36)

            // New tab button (styled like Aizen)
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
                    #if os(macOS)
                    .background(
                        isNewTabHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                        in: Circle()
                    )
                    #else
                    .background(
                        isNewTabHovering ? Color.gray.opacity(0.3) : Color.clear,
                        in: Circle()
                    )
                    #endif
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { isNewTabHovering = $0 }
            #endif
            .help("New connection")
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeSheet()
        }
    }

    @ViewBuilder
    private func tabContextMenu(_ session: ConnectionSession) -> some View {
        Button("Close Terminal") {
            sessionManager.closeSession(session)
        }

        Divider()

        Button("Close All to the Left") {
            sessionManager.closeSessionsToLeft(of: session)
        }
        Button("Close All to the Right") {
            sessionManager.closeSessionsToRight(of: session)
        }
        Button("Close Other Tabs") {
            sessionManager.closeOtherSessions(except: session)
        }

        Divider()

        Button("Duplicate Tab") {
            duplicateTab(session)
        }
    }

    private func duplicateTab(_ session: ConnectionSession) {
        guard sessionManager.canOpenNewTab else {
            showingProUpgrade = true
            return
        }
        guard let server = sessionManager.sessions
            .first(where: { $0.id == session.id })
            .flatMap({ s in ServerManager.shared.servers.first { $0.id == s.serverId } })
        else { return }
        Task { try? await sessionManager.openConnection(to: server, forceNew: true) }
    }
}

// MARK: - Connection Tab Button

struct ConnectionTabButton: View {
    let session: ConnectionSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                // Close button (like Aizen's DetailCloseButton)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                        )
                }
                .buttonStyle(.plain)

                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                // Title
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            #if os(macOS)
            .background(
                isSelected ?
                Color(nsColor: .separatorColor) :
                (isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear),
                in: Capsule()
            )
            #else
            .background(
                isSelected ?
                Color.gray.opacity(0.4) :
                (isHovering ? Color.gray.opacity(0.2) : Color.clear),
                in: Capsule()
            )
            #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .idle: return .secondary
        case .failed: return .red
        }
    }
}

// MARK: - Navigation Arrow Button

struct NavigationArrowButton: View {
    let icon: String
    let action: () -> Void
    var help: String = ""

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                #if os(macOS)
                .background(
                    isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                    in: Circle()
                )
                #else
                .background(
                    isHovering ? Color.gray.opacity(0.3) : Color.clear,
                    in: Circle()
                )
                #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .help(help)
    }
}
