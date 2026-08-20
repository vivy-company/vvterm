nonisolated enum TranscriptionProviderResolutionPolicy {
    static func resolve(
        requested: TranscriptionProvider,
        mlxSupported: Bool,
        requestedModelAvailable: Bool
    ) -> TranscriptionProvider {
        guard requested != .system else { return .system }
        guard mlxSupported, requestedModelAvailable else { return .system }
        return requested
    }
}
