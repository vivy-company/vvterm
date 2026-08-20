import Foundation

nonisolated struct SSHExecOutputBudget: Sendable {
    static let defaultMaximumBytes = 1 * 1_024 * 1_024

    let maximumBytes: Int
    private(set) var retainedBytes = 0

    init(maximumBytes: Int = Self.defaultMaximumBytes) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func reserve(_ byteCount: Int) -> Bool {
        guard byteCount >= 0,
              byteCount <= maximumBytes - retainedBytes else {
            return false
        }
        retainedBytes += byteCount
        return true
    }
}
