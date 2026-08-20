import Foundation

extension Ghostty {
    /// Stable userdata for C callbacks without extending the owner's lifetime.
    nonisolated final class CallbackContext<Owner: AnyObject>: @unchecked Sendable {
        private let lock = NSLock()
        private weak var owner: Owner?

        init(owner: Owner) {
            self.owner = owner
        }

        var userdata: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(self).toOpaque()
        }

        func resolve() -> Owner? {
            lock.withLock { owner }
        }

        func invalidate() {
            lock.withLock {
                owner = nil
            }
        }

        static func resolve(_ userdata: UnsafeMutableRawPointer?) -> Owner? {
            guard let userdata else { return nil }
            return Unmanaged<CallbackContext>
                .fromOpaque(userdata)
                .takeUnretainedValue()
                .resolve()
        }
    }
}
