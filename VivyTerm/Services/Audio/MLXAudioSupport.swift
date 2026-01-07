import Foundation

enum MLXAudioSupport {
    static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
