@MainActor
protocol BiometricAuthServing {
    func availability() -> BiometricAvailability
    func authenticate(
        reason: BiometricAuthenticationReason,
        allowPasscodeFallback: Bool
    ) async throws
}
