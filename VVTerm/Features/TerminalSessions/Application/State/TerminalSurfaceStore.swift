import Combine
import Foundation

nonisolated enum TerminalSurfaceStoreChange: Equatable, Sendable {
    case registered(paneId: UUID, surfaceIdentity: ObjectIdentifier)
    case replaced(paneId: UUID, surfaceIdentity: ObjectIdentifier)
    case removed(paneId: UUID, surfaceIdentity: ObjectIdentifier)
    case drained(surfaceIdentitiesByPane: [UUID: ObjectIdentifier])
}

nonisolated struct TerminalSurfaceGeometry: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let pixelSize: TerminalPixelSize?
}

#if os(iOS)
@MainActor
struct TerminalSurfaceLifecycleCallbacks {
    let windowAttachmentChanged: (Bool) -> Void
    let directTouch: (_ isFocusTap: Bool) -> Void
    let keyboardAccessoryHideRequested: () -> Void
    let findNavigatorVisibilityChanged: (Bool) -> Void
}
#endif

@MainActor
protocol TerminalSurface: AnyObject, TerminalOutputSink, Sendable {
    var terminalGeometry: TerminalSurfaceGeometry? { get }
    var isHostingSceneActive: Bool? { get }

    func applyPresentationOverrides(_ overrides: TerminalPresentationOverrides)
    func cleanup()
    func installRichPasteInterceptor(_ interceptor: @escaping () -> Bool)
    func pasteTextFromClipboard()
    func sendText(_ text: String)

    #if os(iOS)
    var keyboardInputSession: any TerminalKeyboardInputSession { get }
    var isAttachedToWindow: Bool { get }
    var acceptsTerminalInput: Bool { get set }
    var shouldRestoreKeyboardFocusOnReconnect: Bool { get }
    var isFindNavigatorVisible: Bool { get }
    func setLifecycleCallbacks(_ callbacks: TerminalSurfaceLifecycleCallbacks?)
    #endif
}

@MainActor
protocol TerminalSurfaceStoring: AnyObject {
    var latestChange: TerminalSurfaceStoreChange? { get }
    var changes: AnyPublisher<TerminalSurfaceStoreChange, Never> { get }

    func surface(for paneId: UUID) -> (any TerminalSurface)?
    func isRegistered(_ surface: any TerminalSurface, for paneId: UUID) -> Bool

    @discardableResult
    func register(_ surface: any TerminalSurface, for paneId: UUID) -> Bool

    @discardableResult
    func remove(
        for paneId: UUID,
        prepareForRemoval: (any TerminalSurface) -> Void
    ) -> (any TerminalSurface)?

    @discardableResult
    func unregister(
        _ surface: any TerminalSurface,
        for paneId: UUID,
        prepareForRemoval: (any TerminalSurface) -> Void,
        cleanup: (any TerminalSurface) -> Void
    ) -> Bool

    func drain(
        prepareForRemoval: (UUID, any TerminalSurface) -> Void,
        cleanup: (any TerminalSurface) -> Void
    )
}
