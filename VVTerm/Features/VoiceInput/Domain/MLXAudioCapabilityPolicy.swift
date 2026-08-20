nonisolated enum MLXAudioPlatform: Sendable {
    case appleMobile
    case macOS
    case unsupported
}

nonisolated enum MLXAudioCapabilityPolicy {
    static func isSupported(
        platform: MLXAudioPlatform,
        supportsNonuniformThreadgroups: Bool?
    ) -> Bool {
        guard let supportsNonuniformThreadgroups else { return false }

        switch platform {
        case .appleMobile:
            return supportsNonuniformThreadgroups
        case .macOS:
            return true
        case .unsupported:
            return false
        }
    }
}
