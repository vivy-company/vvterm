#if os(macOS)
import Testing
@testable import VVTerm

@MainActor
private final class SettingsWindowTestHandle: SettingsWindowHandling {
    var isVisible = false
    private(set) var presentationCount = 0

    func presentSettingsWindow() {
        presentationCount += 1
        isVisible = true
    }
}

@Suite
@MainActor
struct SettingsWindowPresenterTests {
    @Test
    func visibleWindowIsReused() {
        var createdWindows: [SettingsWindowTestHandle] = []
        let presenter = SettingsWindowPresenter {
            let window = SettingsWindowTestHandle()
            createdWindows.append(window)
            return window
        }

        presenter.show()
        presenter.show()

        #expect(createdWindows.count == 1)
        #expect(createdWindows[0].presentationCount == 2)
    }

    @Test
    func closedWindowIsReplaced() {
        var createdWindows: [SettingsWindowTestHandle] = []
        let presenter = SettingsWindowPresenter {
            let window = SettingsWindowTestHandle()
            createdWindows.append(window)
            return window
        }

        presenter.show()
        createdWindows[0].isVisible = false
        presenter.show()

        #expect(createdWindows.count == 2)
        #expect(createdWindows[0] !== createdWindows[1])
        #expect(createdWindows[0].presentationCount == 1)
        #expect(createdWindows[1].presentationCount == 1)
    }
}
#endif
