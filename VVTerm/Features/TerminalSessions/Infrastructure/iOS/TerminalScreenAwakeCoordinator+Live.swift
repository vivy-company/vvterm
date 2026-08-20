#if os(iOS)
import UIKit

@MainActor
private final class UIApplicationIdleTimerController: TerminalIdleTimerControlling {
    func setIdleTimerDisabled(_ isDisabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = isDisabled
    }
}

extension TerminalScreenAwakeCoordinator {
    convenience init() {
        self.init(idleTimer: UIApplicationIdleTimerController())
    }
}
#endif
