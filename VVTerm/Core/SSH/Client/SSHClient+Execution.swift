import Foundation

extension SSHClient {
    // MARK: - Command Execution

    func execute(
        _ command: String,
        timeout: Duration? = nil,
        maxOutputBytes: Int = SSHExecOutputBudget.defaultMaximumBytes
    ) async throws -> String {
        guard !isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }
        let effectiveTimeout = timeout ?? execTimeout
        return try await SSHClient.runWithDeadline(
            effectiveTimeout,
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            return try await session.execute(command, maxOutputBytes: maxOutputBytes)
        }
    }
}
