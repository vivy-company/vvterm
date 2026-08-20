import Foundation

extension StoreError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return String(localized: "Purchase verification failed")
        case .productNotFound:
            return String(localized: "Product not found")
        case .purchaseFailed(let message):
            return String(format: String(localized: "Purchase failed: %@"), message)
        }
    }
}
