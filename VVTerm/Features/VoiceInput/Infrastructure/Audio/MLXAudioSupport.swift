import Foundation
import Metal

enum MLXAudioSupport {
    static var isSupported: Bool {
        #if arch(arm64)
        #if os(iOS) || os(tvOS)
        let platform = MLXAudioPlatform.appleMobile
        #elseif os(macOS)
        let platform = MLXAudioPlatform.macOS
        #else
        let platform = MLXAudioPlatform.unsupported
        #endif

        return MLXAudioCapabilityPolicy.isSupported(
            platform: platform,
            supportsNonuniformThreadgroups: MTLCreateSystemDefaultDevice()?.supportsFamily(.apple4)
        )
        #else
        return false
        #endif
    }

    nonisolated static var unavailableDescription: String {
        String(localized: "On-device MLX transcription isn't supported on this device. Apple Speech will be used instead.")
    }
}
