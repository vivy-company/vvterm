#if os(macOS)
import Testing
@testable import VVTerm

@MainActor
private final class AboutWindowTestHandle: AboutWindowHandling {
    private(set) var presentationCount = 0

    func presentAboutWindow() {
        presentationCount += 1
    }
}

@Suite
@MainActor
struct AboutWindowPresenterTests {
    @Test
    func presenterReusesItsExactWindowAndActivatesForEveryPresentation() {
        var createdWindows: [AboutWindowTestHandle] = []
        var activationCount = 0
        let presenter = AboutWindowPresenter(
            makeWindow: {
                let window = AboutWindowTestHandle()
                createdWindows.append(window)
                return window
            },
            activateApplication: {
                activationCount += 1
            }
        )

        presenter.show()
        presenter.show()

        #expect(createdWindows.count == 1)
        #expect(createdWindows[0].presentationCount == 2)
        #expect(activationCount == 2)
    }
}
#endif
