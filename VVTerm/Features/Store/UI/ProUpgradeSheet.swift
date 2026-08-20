import SwiftUI

// MARK: - Pro Upgrade Sheet

struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var serverManager: ServerManager
    private let source: PaywallSource
    private let onDismiss: (() -> Void)?

    @State private var selectedPlan: ProPlanKind = .yearly
    @State private var yearlyOfferState: ProPlanIntroductoryOfferState = .unavailable
    @State private var showSuccess = false
    @State private var alertInfo: AlertInfo?
    @State private var showCancelSubscriptionAlert = false
    @State var showManageSubscription = false

    private struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let isRestore: Bool
    }

    init(source: PaywallSource = .general, onDismiss: (() -> Void)? = nil) {
        self.source = source
        self.onDismiss = onDismiss
    }

    var body: some View {
        platformBody(
            sheetContent: sheetContent,
            source: source,
            onClose: close
        )
    }

    private var sheetContent: some View {
        platformSheetLayout(
            content: contentStack,
            footer: purchaseFooter,
            source: source
        )
        .task {
            await preparePaywall()
        }
        .onChange(of: storeManager.purchaseState) { newState in
            handlePurchaseStateChange(newState)
        }
        .onChange(of: storeManager.restoreState) { newState in
            handleRestoreStateChange(newState)
        }
        .overlay {
            if showSuccess {
                successOverlay
            }
        }
        .alert(alertInfo?.title ?? "", isPresented: .init(
            get: { alertInfo != nil },
            set: { isPresented in
                if !isPresented {
                    if alertInfo?.isRestore == true {
                        storeManager.dismissRestoreResult()
                    }
                    alertInfo = nil
                }
            }
        ), presenting: alertInfo) { info in
            Button("OK") {
                if info.isRestore {
                    storeManager.dismissRestoreResult()
                }
                alertInfo = nil
            }
        } message: { info in
            Text(info.message)
        }
        .alert(String(localized: "Cancel Subscription?"), isPresented: $showCancelSubscriptionAlert) {
            Button(String(localized: "Manage Subscription")) {
                openSubscriptionManagement()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    close()
                }
            }
            Button(String(localized: "Later"), role: .cancel) {
                close()
            }
        } message: {
            Text("You now have lifetime access. You should cancel your existing subscription to avoid being charged.")
        }
        #if os(iOS)
        .manageSubscriptionsSheetCompat(
            isPresented: $showManageSubscription,
            subscriptionGroupID: VVTermProducts.subscriptionGroupId
        )
        #endif
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            comparisonSection
            crossPlatformBenefitSection
            planSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: String(localized: "Compare plans"))

            NativeSectionCard(padding: 0) {
                ComparisonTable(rows: comparisonRows)
            }
        }
    }

    private var crossPlatformBenefitSection: some View {
        NativeSectionCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(crossPlatformBenefitTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(crossPlatformBenefitMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: String(localized: "Choose a plan"))

            if availablePlans.isEmpty {
                NativeSectionCard {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading plans...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 82)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(availablePlans) { plan in
                        if let product = product(for: plan) {
                            PlanSelectionCard(
                                presentation: presentation(for: plan, product: product),
                                isSelected: selectedPlan == plan
                            ) {
                                selectedPlan = plan
                            }
                        }
                    }
                }
            }
        }
    }

    private var purchaseFooter: some View {
        VStack(spacing: 5) {
            Button {
                if let product = selectedProduct {
                    storeManager.notePaywallCTATapped(product: product)
                    Task { await storeManager.purchase(product) }
                }
            } label: {
                ZStack {
                    Text(subscribeButtonTitle)
                        .fontWeight(.semibold)
                        .opacity(storeManager.purchaseState == .purchasing ? 0 : 1)

                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)

                        Text("Processing...")
                            .fontWeight(.semibold)
                    }
                    .opacity(storeManager.purchaseState == .purchasing ? 1 : 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedProduct == nil || storeManager.accessState == .checking)
            .allowsHitTesting(storeManager.purchaseState != .purchasing)
            .accessibilityLabel(selectedPresentation?.purchaseButtonAccessibilityLabel ?? subscribeButtonTitle)

            footerSupportRow

            Text(selectedPresentation?.renewalDisclosure ?? String(localized: "Auto-renews until canceled."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        #if os(macOS)
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.55)
        }
        .background(sheetBackground)
        #else
        .background(.bar)
        #endif
    }

    private var footerSupportRow: some View {
        HStack(spacing: 6) {
            restoreButton

            Text(verbatim: "•")
                .foregroundStyle(.tertiary)

            legalLink(title: "Terms", url: "https://vvterm.com/terms")

            Text(verbatim: "•")
                .foregroundStyle(.tertiary)

            legalLink(title: "Privacy", url: "https://vvterm.com/privacy")

            Text(verbatim: "•")
                .foregroundStyle(.tertiary)

            legalLink(title: "Refund", url: "https://vvterm.com/refund")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var restoreButton: some View {
        Button {
            Task { await storeManager.restorePurchases() }
        } label: {
            HStack(spacing: 8) {
                if storeManager.restoreState == .restoring {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                        .imageScale(.small)
                }
                Text(storeManager.restoreState == .restoring
                     ? String(localized: "Restoring...")
                     : String(localized: "Restore Purchases"))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(storeManager.restoreState == .restoring)
    }

    // MARK: - Success Overlay

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)

                Text("Welcome to Pro")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("You now have unlimited access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
        .transition(.opacity)
    }

    // MARK: - Products

    private var availablePlans: [ProPlanKind] {
        ProPlanKind.displayOrder.filter { product(for: $0) != nil }
    }

    private var selectedProduct: StoreProduct? {
        product(for: selectedPlan)
    }

    private var selectedPresentation: ProPlanPresentation? {
        selectedProduct.map { presentation(for: selectedPlan, product: $0) }
    }

    private var defaultPlan: ProPlanKind {
        if storeManager.yearlyProduct != nil { return .yearly }
        if storeManager.monthlyProduct != nil { return .monthly }
        if storeManager.lifetimeProduct != nil { return .lifetime }
        return .yearly
    }

    private func product(for plan: ProPlanKind) -> StoreProduct? {
        switch plan {
        case .monthly:
            return storeManager.monthlyProduct
        case .yearly:
            return storeManager.yearlyProduct
        case .lifetime:
            return storeManager.lifetimeProduct
        }
    }

    private func presentation(for plan: ProPlanKind, product: StoreProduct) -> ProPlanPresentation {
        ProPlanPresentation(
            plan: plan,
            displayPrice: product.displayPrice,
            introductoryOfferState: yearlyOfferState
        )
    }

    private func refreshYearlyOfferState() async {
        guard let yearlyProduct = storeManager.yearlyProduct else {
            yearlyOfferState = .unavailable
            return
        }
        yearlyOfferState = await storeManager.introductoryOfferState(for: yearlyProduct)
    }

    private func preparePaywall() async {
        storeManager.notePaywallPresented(source: source)
        await storeManager.loadProducts()
        selectedPlan = defaultPlan
        await refreshYearlyOfferState()
    }

    private var crossPlatformBenefitTitle: String {
        #if os(macOS)
        return String(localized: "Also on iPhone and iPad")
        #else
        return String(localized: "Also on Mac")
        #endif
    }

    private var crossPlatformBenefitMessage: String {
        String(localized: "One Pro purchase works on iPhone, iPad, and Mac with the same Apple ID.")
    }

    private var subscribeButtonTitle: String {
        selectedPresentation?.purchaseButtonTitle ?? String(localized: "Select a Plan")
    }

    // MARK: - Comparison

    private var comparisonRows: [ComparisonFeature] {
        [
            ComparisonFeature(
                icon: "server.rack",
                title: String(localized: "Servers"),
                free: .number(String(serverManager.freeServerLimit)),
                pro: .unlimited(accessibilityLabel: String(localized: "Unlimited servers"))
            ),
            ComparisonFeature(
                icon: "square.stack.3d.up",
                title: String(localized: "Workspaces"),
                free: .number(String(FreeTierLimits.maxWorkspaces)),
                pro: .unlimited(accessibilityLabel: String(localized: "Unlimited workspaces"))
            ),
            ComparisonFeature(
                icon: "rectangle.stack",
                title: String(localized: "Connections"),
                free: .number(String(FreeTierLimits.maxTabs)),
                pro: .unlimited(accessibilityLabel: String(localized: "Multiple connections"))
            ),
            ComparisonFeature(
                icon: "doc.on.doc",
                title: String(localized: "File tabs"),
                free: .number("1"),
                pro: .unlimited(accessibilityLabel: String(localized: "Multiple file tabs"))
            ),
            ComparisonFeature(
                icon: "rectangle.split.2x1",
                title: String(localized: "Split panes"),
                free: .notIncluded(accessibilityLabel: String(localized: "Split panes not included on Free")),
                pro: .included(accessibilityLabel: String(localized: "Split panes included on Pro"))
            ),
            ComparisonFeature(
                icon: "command",
                title: String(localized: "Custom actions"),
                free: .number(String(FreeTierLimits.maxCustomActions)),
                pro: .unlimited(accessibilityLabel: String(localized: "Unlimited custom actions"))
            ),
            ComparisonFeature(
                icon: "terminal",
                title: String(localized: "SSH terminal"),
                free: .included(accessibilityLabel: String(localized: "SSH terminal included on Free")),
                pro: .included(accessibilityLabel: String(localized: "SSH terminal included on Pro"))
            ),
            ComparisonFeature(
                icon: "folder",
                title: String(localized: "SFTP browser"),
                free: .included(accessibilityLabel: String(localized: "SFTP browser included on Free")),
                pro: .included(accessibilityLabel: String(localized: "SFTP browser included on Pro"))
            ),
            ComparisonFeature(
                icon: "icloud",
                title: String(localized: "iCloud sync"),
                free: .included(accessibilityLabel: String(localized: "iCloud sync included on Free")),
                pro: .included(accessibilityLabel: String(localized: "iCloud sync included on Pro"))
            ),
            ComparisonFeature(
                icon: "chart.bar.xaxis",
                title: String(localized: "Server stats"),
                free: .included(accessibilityLabel: String(localized: "Server stats included on Free")),
                pro: .included(accessibilityLabel: String(localized: "Server stats included on Pro"))
            ),
            ComparisonFeature(
                icon: "shippingbox",
                title: String(localized: "Docker monitoring"),
                free: .notIncluded(accessibilityLabel: String(localized: "Docker monitoring not included on Free")),
                pro: .included(accessibilityLabel: String(localized: "Docker monitoring included on Pro"))
            ),
            ComparisonFeature(
                icon: "paintbrush",
                title: String(localized: "Environments"),
                free: .text(String(localized: "Built-in"), emphasized: false),
                pro: .text(String(localized: "Custom"), emphasized: true)
            )
        ]
    }

    // MARK: - State Change Handlers

    private func handlePurchaseStateChange(_ newState: PurchaseState) {
        switch newState {
        case .purchased:
            withAnimation(.easeInOut(duration: 0.3)) {
                showSuccess = true
            }
            if storeManager.lastPurchasedProductId == VVTermProducts.proLifetime,
               storeManager.hasActiveSubscriptionWithLifetime {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showSuccess = false
                    showCancelSubscriptionAlert = true
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    close()
                    storeManager.requestReviewAfterPurchase()
                }
            }
        case .failed(let message):
            alertInfo = AlertInfo(
                title: String(localized: "Purchase Failed"),
                message: message,
                isRestore: false
            )
        default:
            break
        }
    }

    private func handleRestoreStateChange(_ newState: RestoreState) {
        switch newState {
        case .restored(let hasAccess):
            alertInfo = AlertInfo(
                title: String(localized: "Restore Purchases"),
                message: hasAccess
                    ? String(localized: "Your purchases have been restored.")
                    : String(localized: "No active purchases were found for this Apple ID."),
                isRestore: true
            )
        case .failed(let message):
            alertInfo = AlertInfo(
                title: String(localized: "Restore Failed"),
                message: message,
                isRestore: true
            )
        default:
            break
        }
    }

    private func sectionHeader(title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legalLink(title: LocalizedStringKey, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Text(title)
                .underline()
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

extension View {
    func proUpgradePresentation(isPresented: Binding<Bool>, source: PaywallSource = .general) -> some View {
        modifier(ProUpgradePresentationModifier(isPresented: isPresented, source: source))
    }
}

struct ProUpgradePresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let source: PaywallSource
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var serverManager: ServerManager

    func body(content: Content) -> some View {
        platformBody(content: content)
    }
}


// MARK: - Source Copy

extension PaywallSource {
    var paywallTitle: String {
        switch self {
        case .general, .settings, .sidebarBanner:
            return String(localized: "Upgrade to Pro")
        case .serverLimit:
            return String(localized: "Unlock unlimited servers")
        case .workspaceLimit:
            return String(localized: "Unlock unlimited workspaces")
        case .tabLimit:
            return String(localized: "Unlock simultaneous connections")
        case .fileTabLimit:
            return String(localized: "Unlock multiple file tabs")
        case .splitPane:
            return String(localized: "Unlock split panes")
        case .customEnvironment:
            return String(localized: "Unlock custom environments")
        case .snippetLimit:
            return String(localized: "Unlock unlimited custom actions")
        case .welcome:
            return String(localized: "VVTerm Pro")
        case .dockerStats:
            return String(localized: "Unlock Docker monitoring")
        }
    }

    var paywallSubtitle: String {
        switch self {
        case .general, .settings, .sidebarBanner, .welcome:
            return String(localized: "Connect everywhere, without limits.")
        case .serverLimit:
            return String(localized: "Pro removes every limit on servers, tabs, and workspaces.")
        case .workspaceLimit:
            return String(localized: "Pro removes every limit on workspaces, servers, and tabs.")
        case .tabLimit:
            return String(localized: "Run all your servers side by side.")
        case .fileTabLimit:
            return String(localized: "Browse files on all your servers at once.")
        case .splitPane:
            return String(localized: "Split your terminal into multiple panes.")
        case .customEnvironment:
            return String(localized: "Organize servers with your own environments.")
        case .snippetLimit:
            return String(localized: "Keep every command one tap away.")
        case .dockerStats:
            return String(localized: "Track containers, health, CPU, memory, and network from Stats.")
        }
    }
}

// MARK: - Plans

private struct PlanSelectionCard: View {
    let presentation: ProPlanPresentation
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(presentation.plan.title)
                            .font(.headline)
                            .fontWeight(.semibold)

                        if let badge = presentation.plan.badge {
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }

                    Text(presentation.priceLine)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(presentation.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : cardStroke, lineWidth: isSelected ? 3 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.planAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardFill: Color {
        paywallCardFillColor
    }

    private var cardStroke: Color {
        paywallCardBorderColor
    }
}

// MARK: - Comparison Table

private struct ComparisonFeature: Identifiable {
    let icon: String
    let title: String
    let free: ComparisonValue
    let pro: ComparisonValue

    var id: String { title }
}

private enum ComparisonValue {
    case included(accessibilityLabel: String)
    case number(String)
    case notIncluded(accessibilityLabel: String)
    case text(String, emphasized: Bool)
    case unlimited(accessibilityLabel: String)
}

private struct ComparisonTable: View {
    let rows: [ComparisonFeature]

    var body: some View {
        VStack(spacing: 0) {
            ComparisonTableRow(isHeader: true) {
                ComparisonHeaderCell(title: String(localized: "Feature"), alignment: .leading)
            } free: {
                ComparisonHeaderCell(title: String(localized: "Free"), alignment: .center)
            } pro: {
                ComparisonHeaderCell(title: String(localized: "Pro"), alignment: .center)
            }

            separator

            ForEach(rows) { row in
                ComparisonTableRow {
                    ComparisonFeatureCell(feature: row)
                } free: {
                    ComparisonValueCell(value: row.free)
                } pro: {
                    ComparisonValueCell(value: row.pro)
                }

                if row.id != rows.last?.id {
                    separator
                }
            }
        }
        .overlay {
            GeometryReader { proxy in
                Path { path in
                    let featureBoundary = proxy.size.width - (ComparisonTableLayout.valueColumnWidth * 2)
                    let proBoundary = proxy.size.width - ComparisonTableLayout.valueColumnWidth

                    path.move(to: CGPoint(x: featureBoundary, y: 0))
                    path.addLine(to: CGPoint(x: featureBoundary, y: proxy.size.height))
                    path.move(to: CGPoint(x: proBoundary, y: 0))
                    path.addLine(to: CGPoint(x: proBoundary, y: proxy.size.height))
                }
                .stroke(paywallTableGridColor, lineWidth: 0.5)
            }
            .allowsHitTesting(false)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(paywallTableGridColor)
            .frame(height: 0.5)
    }
}

private struct ComparisonTableRow<Feature: View, Free: View, Pro: View>: View {
    var isHeader = false
    @ViewBuilder let feature: Feature
    @ViewBuilder let free: Free
    @ViewBuilder let pro: Pro

    var body: some View {
        HStack(spacing: 0) {
            feature
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, verticalPadding)

            free
                .frame(width: ComparisonTableLayout.valueColumnWidth, alignment: .center)
                .frame(minHeight: rowHeight, alignment: .center)
                .padding(.vertical, verticalPadding)

            pro
                .frame(width: ComparisonTableLayout.valueColumnWidth, alignment: .center)
                .frame(minHeight: rowHeight, alignment: .center)
                .padding(.vertical, verticalPadding)
        }
    }

    private var rowHeight: CGFloat {
        isHeader ? 20 : 20
    }

    private var verticalPadding: CGFloat {
        isHeader ? 6 : 4
    }

}

private enum ComparisonTableLayout {
    static let valueColumnWidth: CGFloat = 68
}

private struct ComparisonFeatureCell: View {
    let feature: ComparisonFeature

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: feature.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15)

            Text(feature.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ComparisonHeaderCell: View {
    let title: String
    let alignment: Alignment

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct ComparisonValueCell: View {
    let value: ComparisonValue

    var body: some View {
        Group {
            switch value {
            case .included(let accessibilityLabel):
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel(accessibilityLabel)

            case .number(let text):
                Text(text)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

            case .notIncluded(let accessibilityLabel):
                Text(verbatim: "-")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(accessibilityLabel)

            case .text(let text, let emphasized):
                Text(text)
                    .font(.caption2)
                    .fontWeight(emphasized ? .semibold : .regular)
                    .foregroundStyle(emphasized ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

            case .unlimited(let accessibilityLabel):
                Image(systemName: "infinity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel(accessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Native Card

private struct NativeSectionCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        content
            .padding(padding)
            .background(
                shape.fill(cardFill)
            )
            .clipShape(shape)
            .overlay(
                shape.stroke(cardStroke, lineWidth: 0.5)
            )
    }

    private var cardFill: Color {
        paywallCardFillColor
    }

    private var cardStroke: Color {
        paywallCardBorderColor
    }
}
