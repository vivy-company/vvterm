@MainActor
struct AnalyticsOptOutAction {
    private let emitAnalyticsDisabled: @MainActor () -> Void

    init(emitAnalyticsDisabled: @escaping @MainActor () -> Void) {
        self.emitAnalyticsDisabled = emitAnalyticsDisabled
    }

    func applyTransition(
        from currentValue: Bool,
        to newValue: Bool,
        persist: (Bool) -> Void
    ) {
        if currentValue && !newValue {
            emitAnalyticsDisabled()
        }
        persist(newValue)
    }
}
