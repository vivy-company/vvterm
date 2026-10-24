import AuthenticationServices

/// The form keeps a weak reference to its own window, including in multiple scenes.
@MainActor
final class TeleportPresentationWindow {
    weak var value: ASPresentationAnchor?
}
