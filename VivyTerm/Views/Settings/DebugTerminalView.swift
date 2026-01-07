//
//  DebugTerminalView.swift
//  VivyTerm
//
//  Debug view to test Ghostty terminal rendering in isolation
//

import SwiftUI
import os.log

#if os(iOS)
import UIKit

// MARK: - Debug Terminal View

struct DebugTerminalView: View {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @State private var terminalReady = false
    @State private var logs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Terminal area
            GeometryReader { geo in
                DebugTerminalRepresentable(
                    size: geo.size,
                    onReady: {
                        terminalReady = true
                        addLog("Terminal ready")
                    },
                    onLog: { msg in
                        addLog(msg)
                    }
                )
            }
            .frame(maxHeight: .infinity)
            .background(Color.black)

            // Debug info panel
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Status:")
                        .fontWeight(.semibold)
                    Text(terminalReady ? "Ready" : "Loading...")
                        .foregroundColor(terminalReady ? .green : .orange)
                    Spacer()
                    Button("Clear Logs") {
                        logs.removeAll()
                    }
                    .font(.caption)
                }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: logs.count) { _, _ in
                        if let lastIndex = logs.indices.last {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
                .frame(height: 150)
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .navigationTitle("Terminal Debug")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ghosttyApp.startIfNeeded()
        }
    }

    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
    }
}

// MARK: - Debug Terminal Representable

private struct DebugTerminalRepresentable: UIViewRepresentable {
    let size: CGSize
    let onReady: () -> Void
    let onLog: (String) -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onLog: onLog)
    }

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            onLog("ERROR: ghosttyApp.app is nil")
            let placeholder = UIView(frame: CGRect(origin: .zero, size: size))
            placeholder.backgroundColor = .red
            return placeholder
        }

        onLog("Creating GhosttyTerminalView...")
        onLog("  size: \(size.width)x\(size.height)")
        onLog("  scale: \(UIScreen.main.scale)")

        // Create terminal view WITHOUT custom I/O (will use local shell simulation)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: size),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: "debug-terminal",
            useCustomIO: true  // Use custom I/O so we can feed test data
        )

        context.coordinator.terminalView = terminalView

        terminalView.onReady = { [weak terminalView] in
            // Defer state changes to avoid "Modifying state during view update" warning
            DispatchQueue.main.async {
                onLog("onReady callback fired")
                onReady()

                // Feed some test data to see if rendering works
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    feedTestData(to: terminalView)
                }
            }
        }

        // Log layer state after layout has had time to run
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak terminalView] in
            guard let view = terminalView else { return }
            onLog("View bounds: \(view.bounds.width)x\(view.bounds.height)")
            onLog("View scale: \(view.contentScaleFactor)")
            if let sublayers = view.layer.sublayers {
                for (i, sublayer) in sublayers.enumerated() {
                    onLog("Sublayer[\(i)]: \(type(of: sublayer))")
                    onLog("  frame: \(sublayer.frame.width)x\(sublayer.frame.height)")
                    onLog("  bounds: \(sublayer.bounds.width)x\(sublayer.bounds.height)")
                    onLog("  contentsScale: \(sublayer.contentsScale)")
                    onLog("  contents: \(sublayer.contents != nil ? "exists" : "nil")")
                }
            } else {
                onLog("No sublayers found!")
            }
        }

        return terminalView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }
        terminalView.sizeDidChange(size)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // Critical: Clean up terminal view to prevent blocking main thread
        if let terminalView = uiView as? GhosttyTerminalView {
            terminalView.pauseRendering()
            terminalView.resignFirstResponder()

            // Defer cleanup so the navigation pop animation can finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminalView] in
                guard let terminalView = terminalView else { return }
                terminalView.cleanup()
                terminalView.removeFromSuperview()
            }
        }
        coordinator.terminalView = nil
    }

    private func feedTestData(to terminalView: GhosttyTerminalView?) {
        guard let terminalView = terminalView else { return }

        onLog("Feeding test data...")

        // Feed ANSI test pattern
        let testData = """
        \u{1B}[2J\u{1B}[H
        \u{1B}[1;32m=== Terminal Rendering Test ===\u{1B}[0m

        \u{1B}[31mRed text\u{1B}[0m
        \u{1B}[32mGreen text\u{1B}[0m
        \u{1B}[33mYellow text\u{1B}[0m
        \u{1B}[34mBlue text\u{1B}[0m
        \u{1B}[35mMagenta text\u{1B}[0m
        \u{1B}[36mCyan text\u{1B}[0m

        \u{1B}[1mBold\u{1B}[0m \u{1B}[4mUnderline\u{1B}[0m \u{1B}[7mInverse\u{1B}[0m

        If you can see this, rendering works!

        $ _
        """

        if let data = testData.data(using: .utf8) {
            terminalView.feedData(data)
            onLog("Fed \(data.count) bytes of test data")

            // Check layer state after feeding data
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let sublayers = terminalView.layer.sublayers {
                    for sublayer in sublayers {
                        onLog("After feedData - contents: \(sublayer.contents != nil ? "exists" : "nil")")
                    }
                }
            }
        }
    }

    class Coordinator {
        weak var terminalView: GhosttyTerminalView?
        let onReady: () -> Void
        let onLog: (String) -> Void

        init(onReady: @escaping () -> Void, onLog: @escaping (String) -> Void) {
            self.onReady = onReady
            self.onLog = onLog
        }
    }
}

#endif
