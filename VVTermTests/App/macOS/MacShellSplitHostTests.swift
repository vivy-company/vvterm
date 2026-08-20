#if os(macOS)
import Testing
@testable import VVTerm

struct MacShellSplitHostTests {
    @Test
    func hostedRootsAreKeptForUnchangedContentIdentity() {
        let identity = AnyHashable("server-a|connected|dark")

        #expect(
            MacShellContentReplacementPolicy.shouldReplace(
                current: identity,
                next: identity
            ) == false
        )
        #expect(
            MacShellContentReplacementPolicy.shouldReplace(
                current: identity,
                next: AnyHashable("server-b|connected|dark")
            )
        )
    }
}
#endif
