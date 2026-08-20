#if os(iOS) && DEBUG
import SwiftUI
import UIKit

struct TerminalScreenAwakeUITestHarness: View {
    private static let routeID = UUID(uuidString: "B166D8E5-E32E-44B8-BB0D-91145D4F7200")!

    @EnvironmentObject private var screenAwakeCoordinator: TerminalScreenAwakeCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TerminalDefaults.keepScreenAwakeKey) private var keepScreenAwakeEnabled = TerminalDefaults.defaultKeepScreenAwake
    @State private var idleTimerDisabled = false
    @State private var backgroundReleaseObserved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TerminalScreenAwakeSettingRow()
                } header: {
                    Text("Terminal Behavior")
                }
            }
            .navigationTitle("Terminal")
        }
        .overlay(alignment: .bottomLeading) {
            Text(diagnostics)
                .font(.system(size: 10, design: .monospaced))
                .padding(6)
                .background(.black.opacity(0.8))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
                .accessibilityIdentifier("vvterm.screenAwakeTest.diagnostics")
        }
        .onAppear {
            updateRequest(for: scenePhase)
        }
        .onChange(of: keepScreenAwakeEnabled) { _ in
            updateRequest(for: scenePhase)
        }
        .onChange(of: scenePhase) { phase in
            updateRequest(for: phase)
        }
        .onDisappear {
            screenAwakeCoordinator.update(isRequested: false, for: Self.routeID)
        }
    }

    private var diagnostics: String {
        "preference=\(keepScreenAwakeEnabled) idleTimerDisabled=\(idleTimerDisabled) backgroundReleased=\(backgroundReleaseObserved)"
    }

    private func updateRequest(for phase: ScenePhase) {
        let sceneIsInBackground = sceneIsInBackground(phase)
        let isRequested = TerminalScreenAwakeCoordinator.shouldRequest(
            preferenceEnabled: keepScreenAwakeEnabled,
            routeVisible: true,
            terminalSelected: true,
            sceneIsInBackground: sceneIsInBackground
        )
        screenAwakeCoordinator.update(isRequested: isRequested, for: Self.routeID)

        let currentValue = UIApplication.shared.isIdleTimerDisabled
        if sceneIsInBackground {
            backgroundReleaseObserved = !currentValue
        }
        idleTimerDisabled = currentValue
    }

    private func sceneIsInBackground(_ phase: ScenePhase) -> Bool {
        switch phase {
        case .active, .inactive:
            false
        case .background:
            true
        @unknown default:
            true
        }
    }
}
#endif
