nonisolated enum CloudKitAccountState: Equatable, Sendable {
    case checking
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable
    case unknown(rawValue: Int)
    case failed(detail: String)
    case disabled
}
