//
//  GhosttyTerminalSelectionMenuPresentation+iOS.swift
//  VVTerm
//
//  iOS selection-menu presentation.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if editMenuPresentation == .pointerContext {
            return UIMenu(children: pointerContextMenuElements())
        }

        return UIMenu(children: nativeSelectionMenuElements())
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        editMenuPresentation = .selection
    }
}

extension GhosttyTerminalView {
    func presentNativeSelectionEditMenu(at point: CGPoint) {
        editMenuPresentation = .selection
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction?.presentEditMenu(with: configuration)
    }

    func dismissEditMenuIfNeeded() {
        editMenuInteraction?.dismissMenu()
    }

    func normalizedSelectionMenuText() -> String? {
        guard let text = currentSelectionText()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private func selectionMenuSourceRect() -> CGRect {
        if let selectedTextRange = imeProxyTextView.selectedTextRange {
            let rect = imeProxyTextView.firstRect(for: selectedTextRange)
            if !rect.isNull, !rect.isEmpty {
                return rect
            }
        }
        return CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
    }

    func nearestPresentingViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController.topMostPresentedViewController
            }
            responder = current.next
        }
        return window?.rootViewController?.topMostPresentedViewController
    }

    private func presentSelectionMenuController(_ controller: UIViewController) {
        guard let presenter = nearestPresentingViewController() else { return }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = selectionMenuSourceRect()
        }
        presenter.present(controller, animated: true)
    }

    private func presentShareSheet(for text: String) {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        presentSelectionMenuController(controller)
    }

    private func presentDictionaryLookup(for text: String) {
        guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text) else { return }
        let controller = UIReferenceLibraryViewController(term: text)
        presentSelectionMenuController(controller)
    }

    private func searchWeb(for text: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components?.url else { return }
        UIApplication.shared.open(url)
    }

    @available(iOS 16.0, *)
    func nativeSelectionMenuElements() -> [UIMenuElement] {
        let selectionText = allowsHostTextSelection ? normalizedSelectionMenuText() : nil
        var actions: [UIMenuElement] = []

        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        if allowsHostTextSelection, nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil {
            actions.append(UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.selectAll(nil)
            })
        }

        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Find"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.presentFindNavigator(prefillingSelectedText: true)
            })
        }

        return actions
    }
}

#endif
