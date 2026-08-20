#if os(macOS)
import Testing
@testable import VVTerm

@MainActor
private final class ProUpgradeWindowTestHandle: ProUpgradeWindowHandling {
    let initialSource: PaywallSource
    private let onDismiss: @MainActor () -> Void
    private let onWindowClosed: @MainActor () -> Void

    var isVisible = false
    private(set) var refreshedSources: [PaywallSource] = []
    private(set) var presentationCount = 0

    init(
        source: PaywallSource,
        onDismiss: @escaping @MainActor () -> Void,
        onWindowClosed: @escaping @MainActor () -> Void
    ) {
        initialSource = source
        self.onDismiss = onDismiss
        self.onWindowClosed = onWindowClosed
    }

    func refresh(source: PaywallSource) {
        refreshedSources.append(source)
    }

    func present() {
        presentationCount += 1
        isVisible = true
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        onWindowClosed()
    }

    func dismissFromContent() {
        onDismiss()
    }
}

@MainActor
private final class ProUpgradeWindowTestRecorder {
    var createdWindows: [ProUpgradeWindowTestHandle] = []
    var reusedSources: [PaywallSource] = []
}

@Suite
@MainActor
struct ProUpgradeWindowPresenterTests {
    @Test
    func visibleWindowIsReusedAndRefreshedForTheNewSource() {
        let recorder = ProUpgradeWindowTestRecorder()
        var closeEvents: [String] = []
        let presenter = makePresenter(recorder: recorder)

        presenter.show(source: .serverLimit) {
            closeEvents.append("first")
        }
        presenter.show(source: .workspaceLimit) {
            closeEvents.append("second")
        }

        #expect(recorder.createdWindows.count == 1)
        #expect(recorder.createdWindows[0].initialSource == .serverLimit)
        #expect(recorder.createdWindows[0].refreshedSources == [.workspaceLimit])
        #expect(recorder.createdWindows[0].presentationCount == 2)
        #expect(recorder.reusedSources == [.workspaceLimit])

        recorder.createdWindows[0].dismissFromContent()
        #expect(closeEvents == ["second"])
    }

    @Test
    func closedWindowIsReplacedWithTheNextSource() {
        let recorder = ProUpgradeWindowTestRecorder()
        let presenter = makePresenter(recorder: recorder)

        presenter.show(source: .serverLimit, onClose: {})
        recorder.createdWindows[0].close()
        presenter.show(source: .tabLimit, onClose: {})

        #expect(recorder.createdWindows.map(\.initialSource) == [.serverLimit, .tabLimit])
        #expect(recorder.createdWindows.map(\.presentationCount) == [1, 1])
        #expect(recorder.reusedSources.isEmpty)
    }

    @Test
    func windowContentModelRefreshesItsSource() {
        let model = ProUpgradeWindowContentModel(source: .serverLimit)

        model.refresh(source: .fileTabLimit)

        #expect(model.source == .fileTabLimit)
    }

    private func makePresenter(
        recorder: ProUpgradeWindowTestRecorder
    ) -> ProUpgradeWindowPresenter {
        ProUpgradeWindowPresenter(
            makeWindow: { source, onDismiss, onWindowClosed in
                let window = ProUpgradeWindowTestHandle(
                    source: source,
                    onDismiss: onDismiss,
                    onWindowClosed: onWindowClosed
                )
                recorder.createdWindows.append(window)
                return window
            },
            noteReusedPresentation: { source in
                recorder.reusedSources.append(source)
            }
        )
    }
}
#endif
