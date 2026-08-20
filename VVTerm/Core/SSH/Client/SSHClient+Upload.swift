import Foundation
import os.log

extension SSHClient {
    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        guard !isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }

        logger.info(
            "Starting SSH upload [path: \(remotePath, privacy: .private(mask: .hash))] [bytes: \(data.count)] [strategy: \(String(describing: strategy), privacy: .public)]"
        )
        try await SSHClient.runWithDeadline(
            uploadTimeout,
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }
}
