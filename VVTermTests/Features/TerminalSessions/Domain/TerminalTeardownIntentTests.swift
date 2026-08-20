import Foundation
import Combine
import Testing
@testable import VVTerm

struct TerminalTeardownIntentTests {
    @Test
    func onlyApplicationTerminationPreservesReconnectableDescriptorsAndETCredentials() {
        for intent in TerminalTeardownIntent.allCases {
            let preservesReconnectableState = intent == .applicationTermination
            #expect(intent.removesPersistedDescriptor != preservesReconnectableState)
            #expect(intent.deletesResumableSessionState != preservesReconnectableState)
        }
    }

    @Test
    func onlyExplicitUserActionsTerminateManagedTmux() {
        #expect(TerminalTeardownIntent.explicitClose.terminatesManagedTmux)
        #expect(TerminalTeardownIntent.explicitServerDisconnect.terminatesManagedTmux)
        #expect(!TerminalTeardownIntent.remoteSessionEnded.terminatesManagedTmux)
        #expect(!TerminalTeardownIntent.applicationTermination.terminatesManagedTmux)
    }
}

