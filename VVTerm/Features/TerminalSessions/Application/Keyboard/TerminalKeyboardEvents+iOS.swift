#if os(iOS)
import CoreGraphics
import Foundation

nonisolated struct TerminalKeyboardCoordinatorDiagnosticSnapshot: Equatable, Sendable {
    var windowAttached: Bool
    var windowIsKey: Bool
    var sceneActivationState: String
    var isFirstResponder: Bool
    var isSoftwareInputActive: Bool
    var keyboardLayoutFrame: CGRect? = nil
    var screenFrame: CGRect? = nil
    var screenIdentifier: ObjectIdentifier? = nil
    var isSoftwareKeyboardSuppressed = false
    var isKeyboardInBrowseMode = false

    var lifecycleDescription: String {
        [
            "windowAttached=\(windowAttached)",
            "keyWindow=\(windowIsKey)",
            "scene=\(sceneActivationState)",
            "firstResponder=\(isFirstResponder)",
            "softwareInput=\(isSoftwareInputActive)",
            "softwareSuppressed=\(isSoftwareKeyboardSuppressed)",
            "browse=\(isKeyboardInBrowseMode)",
            "keyboardLayoutFrame=\(keyboardLayoutFrame?.debugDescription ?? "nil")",
        ].joined(separator: " ")
    }
}

nonisolated enum TerminalKeyboardAnimationCurve: Int, Equatable, Sendable {
    case easeInOut
    case easeIn
    case easeOut
    case linear
}

nonisolated struct TerminalKeyboardEvent: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case frameChanged(CGRect?)
        case hidden
    }

    nonisolated struct Diagnostics: Equatable, Sendable {
        let name: String
        let object: String
        let beginFrame: CGRect?
        let endFrame: CGRect?
    }

    let kind: Kind
    let isLocal: Bool?
    let sourceScreenIdentifier: ObjectIdentifier?
    let animationDuration: TimeInterval?
    let animationCurve: TerminalKeyboardAnimationCurve?
    let diagnostics: Diagnostics?
}

@MainActor
protocol TerminalKeyboardEventSource: AnyObject {
    func start(
        handler: @escaping @MainActor @Sendable (TerminalKeyboardEvent) -> Void
    )
    func stop()
}
#endif
