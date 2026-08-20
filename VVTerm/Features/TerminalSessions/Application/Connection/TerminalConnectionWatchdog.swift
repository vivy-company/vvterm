import Combine
import Foundation

@MainActor
final class TerminalConnectionWatchdog: ObservableObject {
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    @Published private(set) var token = UUID()

    private let delay: Duration
    private let sleep: Sleep
    private var task: Task<Void, Never>?

    init(
        delay: Duration = .seconds(20),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    func replace(action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        let scheduledToken = token
        let delay = delay
        let sleep = sleep
        task = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, self?.token == scheduledToken else { return }
            self?.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        token = UUID()
    }
}
