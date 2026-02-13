import Foundation
import Metal

enum MLXAudioSupport {
    static var isSupported: Bool {
        #if arch(arm64)
        guard let device = MTLCreateSystemDefaultDevice() else { return false }

        #if os(iOS) || os(tvOS)
        // MLX kernels rely on modern Metal features used by dispatchThreads.
        // Older iOS/iPadOS GPU families can abort with
        // "Dispatch Threads with Non-Uniform Threadgroup Size is not supported".
        return device.supportsFamily(.apple4)
        #elseif os(macOS)
        _ = device
        return true
        #else
        return false
        #endif
        #else
        return false
        #endif
    }
}
