import Testing
@testable import VVTerm

@Suite
struct GhosttyCallbackContextTests {
    private nonisolated final class Owner {}

    @Test
    func resolvesOwnerFromNativeUserdata() {
        let owner = Owner()
        let context = Ghostty.CallbackContext(owner: owner)

        #expect(context.resolve() === owner)
        #expect(Ghostty.CallbackContext<Owner>.resolve(context.userdata) === owner)
    }

    @Test
    func doesNotRetainOwner() {
        let context: Ghostty.CallbackContext<Owner>
        weak var weakOwner: Owner?

        do {
            let owner = Owner()
            weakOwner = owner
            context = Ghostty.CallbackContext(owner: owner)
        }

        #expect(weakOwner == nil)
        #expect(context.resolve() == nil)
    }

    @Test
    func invalidationRejectsLateCallbacks() {
        let owner = Owner()
        let context = Ghostty.CallbackContext(owner: owner)
        let userdata = context.userdata

        context.invalidate()

        withExtendedLifetime(owner) {
            #expect(context.resolve() == nil)
            #expect(Ghostty.CallbackContext<Owner>.resolve(userdata) == nil)
        }
    }
}
