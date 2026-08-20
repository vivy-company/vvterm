import Foundation

@MainActor
final class CancellationIgnoringGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var isStarted = false

    func wait() async {
        isStarted = true
        let continuations = startContinuations
        startContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func open() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
