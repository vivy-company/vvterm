#if os(macOS)
import AppKit
import Combine
import SwiftUI

extension ProUpgradeSheet {
    func platformBody<Content: View>(
        sheetContent: Content,
        source: PaywallSource,
        onClose: @escaping () -> Void
    ) -> some View {
        sheetContent
    }

    func platformSheetLayout<Content: View, Footer: View>(
        content: Content,
        footer: Footer,
        source: PaywallSource
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
            }
            .scrollIndicators(.automatic)

            footer
        }
        .frame(
            minWidth: 500,
            idealWidth: 520,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 780,
            maxHeight: .infinity
        )
        .background(sheetBackground)
        .background(ProUpgradeWindowConfigurator(source: source))
    }

    func openSubscriptionManagement() {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            NSWorkspace.shared.open(url)
        }
    }

    var sheetBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

extension ProUpgradePresentationModifier {
    func platformBody(content: Content) -> some View {
        content.modifier(ProUpgradeWindowPresentationHost(
            isPresented: $isPresented,
            source: source,
            storeManager: storeManager,
            serverManager: serverManager
        ))
    }
}

private struct ProUpgradeWindowPresentationHost: ViewModifier {
    @Binding var isPresented: Bool
    let source: PaywallSource
    @StateObject private var presenter: ProUpgradeWindowPresenter

    init(
        isPresented: Binding<Bool>,
        source: PaywallSource,
        storeManager: StoreManager,
        serverManager: ServerManager
    ) {
        _isPresented = isPresented
        self.source = source
        _presenter = StateObject(wrappedValue: ProUpgradeWindowPresenter(
            storeManager: storeManager,
            serverManager: serverManager
        ))
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isPresented {
                    presentWindow()
                }
            }
            .onChange(of: isPresented) { shouldPresent in
                if shouldPresent {
                    presentWindow()
                } else {
                    presenter.close()
                }
            }
            .onChange(of: source) { _ in
                if isPresented {
                    presentWindow()
                }
            }
            .onDisappear {
                presenter.close()
            }
    }

    private func presentWindow() {
        presenter.show(source: source) {
            isPresented = false
        }
    }
}

var paywallTableGridColor: Color {
    Color.primary.opacity(0.13)
}

var paywallCardFillColor: Color {
    Color(nsColor: .controlBackgroundColor)
}

var paywallCardBorderColor: Color {
    Color.primary.opacity(0.16)
}

struct ProUpgradeWindowConfigurator: NSViewRepresentable {
    let source: PaywallSource

    func makeNSView(context: Context) -> WindowConfigurationView {
        WindowConfigurationView(source: source)
    }

    func updateNSView(_ nsView: WindowConfigurationView, context: Context) {
        nsView.source = source
        nsView.applyWindowConfiguration()
    }

    final class WindowConfigurationView: NSView {
        var source: PaywallSource

        init(source: PaywallSource) {
            self.source = source
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowConfiguration()
        }

        func applyWindowConfiguration() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                ProUpgradeWindowChrome.configure(window, setInitialSize: false, source: self.source)
            }
        }
    }
}

@MainActor
protocol ProUpgradeWindowHandling: AnyObject {
    var isVisible: Bool { get }

    func refresh(source: PaywallSource)
    func present()
    func close()
}

@MainActor
final class ProUpgradeWindowPresenter: ObservableObject {
    typealias MakeWindow = @MainActor (
        _ source: PaywallSource,
        _ onDismiss: @escaping @MainActor () -> Void,
        _ onWindowClosed: @escaping @MainActor () -> Void
    ) -> any ProUpgradeWindowHandling

    private struct ActiveWindow {
        let id: UUID
        let handle: any ProUpgradeWindowHandling
    }

    private let makeWindow: MakeWindow
    private let noteReusedPresentation: @MainActor (PaywallSource) -> Void
    private var activeWindow: ActiveWindow?
    private var onClose: (() -> Void)?

    init(
        storeManager: StoreManager,
        serverManager: ServerManager
    ) {
        makeWindow = { source, onDismiss, onWindowClosed in
            ProUpgradeAppKitWindow(
                storeManager: storeManager,
                serverManager: serverManager,
                source: source,
                onDismiss: onDismiss,
                onWindowClosed: onWindowClosed
            )
        }
        noteReusedPresentation = { source in
            storeManager.notePaywallPresented(source: source)
        }
    }

    init(
        makeWindow: @escaping MakeWindow,
        noteReusedPresentation: @escaping @MainActor (PaywallSource) -> Void
    ) {
        self.makeWindow = makeWindow
        self.noteReusedPresentation = noteReusedPresentation
    }

    func show(
        source: PaywallSource,
        onClose: @escaping () -> Void
    ) {
        if let activeWindow, activeWindow.handle.isVisible {
            self.onClose = onClose
            activeWindow.handle.refresh(source: source)
            noteReusedPresentation(source)
            activeWindow.handle.present()
            return
        }

        let windowID = UUID()
        let window = makeWindow(
            source,
            { [weak self] in self?.close() },
            { [weak self] in self?.windowDidClose(id: windowID) }
        )
        activeWindow = ActiveWindow(id: windowID, handle: window)
        self.onClose = onClose
        window.present()
    }

    func close() {
        activeWindow?.handle.close()
    }

    private func windowDidClose(id: UUID) {
        guard activeWindow?.id == id else { return }
        activeWindow = nil
        let closeHandler = onClose
        onClose = nil
        closeHandler?()
    }
}

@MainActor
final class ProUpgradeWindowContentModel: ObservableObject {
    @Published private(set) var source: PaywallSource

    init(source: PaywallSource) {
        self.source = source
    }

    func refresh(source: PaywallSource) {
        self.source = source
    }
}

private struct ProUpgradeWindowContent: View {
    @ObservedObject var model: ProUpgradeWindowContentModel
    let onDismiss: () -> Void

    var body: some View {
        ProUpgradeSheet(source: model.source, onDismiss: onDismiss)
    }
}

@MainActor
private final class ProUpgradeAppKitWindow: NSObject, ProUpgradeWindowHandling, NSWindowDelegate {
    private let model: ProUpgradeWindowContentModel
    private let window: NSWindow
    private let onWindowClosed: @MainActor () -> Void

    init(
        storeManager: StoreManager,
        serverManager: ServerManager,
        source: PaywallSource,
        onDismiss: @escaping @MainActor () -> Void,
        onWindowClosed: @escaping @MainActor () -> Void
    ) {
        let model = ProUpgradeWindowContentModel(source: source)
        let rootView = ProUpgradeWindowContent(model: model, onDismiss: onDismiss)
            .environmentObject(storeManager)
            .environmentObject(serverManager)
        let hostingController = NSHostingController(rootView: rootView)

        self.model = model
        self.window = NSWindow(contentViewController: hostingController)
        self.onWindowClosed = onWindowClosed
        super.init()

        ProUpgradeWindowChrome.configure(window, setInitialSize: true, source: source)
        window.delegate = self
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    func refresh(source: PaywallSource) {
        model.refresh(source: source)
        ProUpgradeWindowChrome.configure(window, setInitialSize: false, source: source)
    }

    func present() {
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed()
    }
}

private enum ProUpgradeWindowChrome {
    private static let toolbarIdentifier = NSToolbar.Identifier("ProUpgradeWindowToolbar")
    private static let titlebarAccessoryIdentifier = NSUserInterfaceItemIdentifier("ProUpgradeTitlebarAccessory")

    static func configure(_ window: NSWindow, setInitialSize: Bool, source: PaywallSource = .general) {
        window.title = source.paywallTitle
        window.subtitle = source.paywallSubtitle
        window.styleMask.insert([.titled, .closable, .resizable])
        window.styleMask.remove(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 620)

        if setInitialSize {
            window.setContentSize(NSSize(width: 520, height: 780))
        }

        if window.toolbar?.identifier != toolbarIdentifier {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        } else {
            window.toolbar?.showsBaselineSeparator = false
        }
        window.toolbarStyle = .unified

        installTitlebarAccessory(in: window, source: source)
    }

    private static func installTitlebarAccessory(in window: NSWindow, source: PaywallSource) {
        if let existing = window.titlebarAccessoryViewControllers.first(where: {
            $0.view.identifier == titlebarAccessoryIdentifier
        }) {
            (existing.view as? ProUpgradeTitlebarView)?.updateText(source: source)
            return
        }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = ProUpgradeTitlebarView(identifier: titlebarAccessoryIdentifier, source: source)
        window.addTitlebarAccessoryViewController(accessory)
    }
}

private final class ProUpgradeTitlebarView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, source: PaywallSource) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 42))
        self.identifier = identifier
        setup()
        updateText(source: source)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updateText(source: PaywallSource) {
        titleField.stringValue = source.paywallTitle
        subtitleField.stringValue = source.paywallSubtitle
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        subtitleField.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            heightAnchor.constraint(equalToConstant: 42),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1)
        ])
    }
}
#endif
