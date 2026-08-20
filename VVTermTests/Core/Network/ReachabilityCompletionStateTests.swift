import Foundation
import Testing
@testable import VVTerm

struct ReachabilityCompletionStateTests {
    @Test
    func concurrentCompletionsHaveExactlyOneWinner() async {
        let state = ReachabilityCompletionState()

        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    state.completeOnce()
                }
            }

            var count = 0
            for await didComplete in group where didComplete {
                count += 1
            }
            return count
        }

        #expect(winners == 1)
        #expect(!state.completeOnce())
    }
}
