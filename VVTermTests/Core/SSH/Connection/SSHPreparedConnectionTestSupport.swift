import Darwin
import Foundation
@testable import VVTerm

nonisolated final class SSHPreparedConnectionSpy: SSHPreparedConnection, @unchecked Sendable {
    private enum Ownership {
        case owned(Int32)
        case transferred(Int32)
        case closed
    }

    private let lock = NSLock()
    private var ownership: Ownership
    private var closedAfterDescriptor = false
    private var didTransfer = false

    let sshCertificate = Data("unused-certificate".utf8)
    let sshPrivateKey = Data("unused-private-key".utf8)

    init(descriptor: Int32) {
        ownership = .owned(descriptor)
    }

    deinit {
        if case .owned(let descriptor) = ownership { Darwin.close(descriptor) }
    }

    var transferred: Bool {
        lock.withLock { didTransfer }
    }

    var didCloseAfterDescriptor: Bool {
        lock.withLock { closedAfterDescriptor }
    }

    func takeSocketDescriptor() throws -> Int32 {
        try lock.withLock {
            guard case .owned(let descriptor) = ownership else { throw SSHError.notConnected }
            ownership = .transferred(descriptor)
            didTransfer = true
            return descriptor
        }
    }

    func verifyHostCertificate(_ certificate: Data) throws {
        throw SSHError.hostKeyVerificationFailed
    }

    func close() async {
        lock.withLock {
            switch ownership {
            case .owned(let descriptor):
                Darwin.close(descriptor)
                closedAfterDescriptor = true
            case .transferred(let descriptor):
                closedAfterDescriptor = fcntl(descriptor, F_GETFD) < 0 && errno == EBADF
            case .closed:
                return
            }
            ownership = .closed
        }
    }
}
