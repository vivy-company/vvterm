import Testing
@testable import VVTerm

struct SSHExecOutputBudgetTests {
    @Test
    func exactLimitIsAccepted() {
        var budget = SSHExecOutputBudget(maximumBytes: 8)

        let acceptedFirstReservation = budget.reserve(3)
        let acceptedSecondReservation = budget.reserve(5)

        #expect(acceptedFirstReservation)
        #expect(acceptedSecondReservation)
        #expect(budget.retainedBytes == 8)
    }

    @Test
    func combinedStreamsCannotExceedLimit() {
        var budget = SSHExecOutputBudget(maximumBytes: 8)

        let acceptedFirstReservation = budget.reserve(6)
        let acceptedOverflow = budget.reserve(3)

        #expect(acceptedFirstReservation)
        #expect(!acceptedOverflow)
        #expect(budget.retainedBytes == 6)
    }

    @Test
    func negativeOrOverflowingReservationsAreRejected() {
        var budget = SSHExecOutputBudget(maximumBytes: 8)

        let acceptedNegativeReservation = budget.reserve(-1)
        let acceptedOverflow = budget.reserve(Int.max)

        #expect(!acceptedNegativeReservation)
        #expect(!acceptedOverflow)
        #expect(budget.retainedBytes == 0)
    }
}
