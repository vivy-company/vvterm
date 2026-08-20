import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Owns the one current terminal surface identity for each pane.
@MainActor
final class GhosttyTerminalSurfaceStore: TerminalSurfaceStoring {
    @Published private(set) var latestChange: TerminalSurfaceStoreChange?

    private var surfacesByPane: [UUID: any TerminalSurface] = [:]

    var changes: AnyPublisher<TerminalSurfaceStoreChange, Never> {
        $latestChange
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    func surface(for paneId: UUID) -> (any TerminalSurface)? {
        surfacesByPane[paneId]
    }

    func isRegistered(_ surface: any TerminalSurface, for paneId: UUID) -> Bool {
        guard let current = surfacesByPane[paneId] else { return false }
        return current === surface
    }

    @discardableResult
    func register(_ surface: any TerminalSurface, for paneId: UUID) -> Bool {
        if isRegistered(surface, for: paneId) {
            return false
        }

        let replacedExistingSurface = surfacesByPane[paneId] != nil
        surfacesByPane[paneId] = surface
        latestChange = replacedExistingSurface
            ? .replaced(
                paneId: paneId,
                surfaceIdentity: ObjectIdentifier(surface)
            )
            : .registered(
                paneId: paneId,
                surfaceIdentity: ObjectIdentifier(surface)
            )
        return replacedExistingSurface
    }

    @discardableResult
    func remove(
        for paneId: UUID,
        prepareForRemoval: (any TerminalSurface) -> Void
    ) -> (any TerminalSurface)? {
        guard let surface = surfacesByPane[paneId] else { return nil }
        prepareForRemoval(surface)
        surfacesByPane.removeValue(forKey: paneId)
        latestChange = .removed(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(surface)
        )
        return surface
    }

    @discardableResult
    func unregister(
        _ surface: any TerminalSurface,
        for paneId: UUID,
        prepareForRemoval: (any TerminalSurface) -> Void,
        cleanup: (any TerminalSurface) -> Void
    ) -> Bool {
        let removedCurrentSurface: Bool
        if isRegistered(surface, for: paneId) {
            prepareForRemoval(surface)
            surfacesByPane.removeValue(forKey: paneId)
            latestChange = .removed(
                paneId: paneId,
                surfaceIdentity: ObjectIdentifier(surface)
            )
            removedCurrentSurface = true
        } else {
            removedCurrentSurface = false
        }
        cleanup(surface)
        return removedCurrentSurface
    }

    func drain(
        prepareForRemoval: (UUID, any TerminalSurface) -> Void,
        cleanup: (any TerminalSurface) -> Void
    ) {
        guard !surfacesByPane.isEmpty else { return }
        let drained = surfacesByPane
        surfacesByPane.removeAll()
        var cleanedSurfaceIdentities: Set<ObjectIdentifier> = []
        for (paneId, surface) in drained {
            prepareForRemoval(paneId, surface)
            if cleanedSurfaceIdentities.insert(ObjectIdentifier(surface)).inserted {
                cleanup(surface)
            }
        }
        latestChange = .drained(
            surfaceIdentitiesByPane: drained.mapValues(ObjectIdentifier.init)
        )
    }
}

extension TerminalSurfaceStoring {
    func ghosttySurface(for paneId: UUID) -> GhosttyTerminalView? {
        surface(for: paneId) as? GhosttyTerminalView
    }
}

extension GhosttyTerminalView: TerminalSurface {
    var terminalGeometry: TerminalSurfaceGeometry? {
        guard let size = terminalSize() else { return nil }
        let columns = Int(size.columns)
        let rows = Int(size.rows)
        guard columns > 0, rows > 0 else { return nil }
        return TerminalSurfaceGeometry(
            columns: columns,
            rows: rows,
            pixelSize: currentTerminalPixelSize
        )
    }

    var isHostingSceneActive: Bool? {
        #if os(iOS)
        guard let scene = window?.windowScene else { return nil }
        return scene.activationState == .foregroundActive
        #else
        nil
        #endif
    }

    func installRichPasteInterceptor(_ interceptor: @escaping () -> Bool) {
        richPasteInterceptor = { _ in interceptor() }
    }

    #if os(iOS)
    var keyboardInputSession: any TerminalKeyboardInputSession { self }
    var isAttachedToWindow: Bool { window != nil }

    func setLifecycleCallbacks(_ callbacks: TerminalSurfaceLifecycleCallbacks?) {
        onWindowAttachmentChange = callbacks?.windowAttachmentChanged
        onTerminalDirectTouch = callbacks?.directTouch
        onKeyboardAccessoryHideRequested = callbacks?.keyboardAccessoryHideRequested
        onFindNavigatorVisibilityChange = callbacks?.findNavigatorVisibilityChanged
    }
    #endif
}
