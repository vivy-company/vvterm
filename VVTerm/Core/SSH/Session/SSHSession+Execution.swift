import Foundation
import os.log

extension SSHSession {
    func failAllExecRequests(error: Error) {
        let requests = execRequests
        execRequests.removeAll()
        for request in requests.values {
            request.channel = nil
            request.continuation.resume(throwing: error)
        }
    }

    func ensureExecChannelReady(_ request: ExecRequest) async -> Bool {
        guard let session = libssh2Session else {
            await finishExecRequest(request.id, error: SSHError.notConnected)
            return false
        }

        if request.channel == nil {
            let newChannel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            )
            if let newChannel = newChannel {
                request.channel = newChannel
            } else {
                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    return false
                }
                await finishExecRequest(request.id, error: SSHError.channelOpenFailed)
                return false
            }
        }

        if !request.isStarted, let execChannel = request.channel {
            let execResult = libssh2_channel_process_startup(
                execChannel,
                "exec",
                4,
                request.command,
                UInt32(request.command.utf8.count)
            )
            if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                return false
            }
            if execResult != 0 {
                await finishExecRequest(request.id, error: SSHError.unknown("Exec failed: \(execResult)"))
                return false
            }
            request.isStarted = true
        }

        return true
    }

    func cancelExecRequest(_ requestId: UUID, error: Error) async {
        guard execRequests[requestId] != nil else { return }
        await finishExecRequest(requestId, error: error)
    }

    func finishExecRequest(_ requestId: UUID, error: Error?) async {
        guard let request = execRequests.removeValue(forKey: requestId) else { return }

        if let channel = request.channel {
            request.channel = nil

            if let session = libssh2Session {
                // Do not resume the command until its close packet is sent.
                // Windows OpenSSH otherwise keeps that channel slot occupied.
                let closeResult = await completeActiveChannelCleanupCall(session: session) {
                    libssh2_channel_close(channel)
                }
                if closeResult != 0 {
                    logger.warning("Exec channel close failed: \(closeResult)")
                }

                let freeResult = await completeActiveChannelCleanupCall(session: session) {
                    libssh2_channel_free(channel)
                }
                if freeResult != 0 {
                    logger.warning("Exec channel free failed: \(freeResult)")
                }
            }
        }

        if let error = error {
            request.continuation.resume(throwing: error)
        } else {
            if !request.stderr.isEmpty,
               let stderr = String(data: request.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !stderr.isEmpty {
                logger.debug("Exec command produced stderr [bytes: \(stderr.utf8.count)]")
            }
            let output = String(data: request.output, encoding: .utf8) ?? ""
            request.continuation.resume(returning: output)
        }
    }

    // MARK: - Execute Command

    func execute(
        _ command: String,
        maxOutputBytes: Int = SSHExecOutputBudget.defaultMaximumBytes
    ) async throws -> String {
        guard libssh2Session != nil else {
            throw SSHError.notConnected
        }
        startIOLoop()

        let requestId = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let request = ExecRequest(
                    id: requestId,
                    command: command,
                    maximumOutputBytes: maxOutputBytes,
                    continuation: continuation
                )
                execRequests[request.id] = request
            }
        }, onCancel: { [weak self] in
            Task {
                await self?.cancelExecRequest(requestId, error: CancellationError())
            }
        })
    }
}
