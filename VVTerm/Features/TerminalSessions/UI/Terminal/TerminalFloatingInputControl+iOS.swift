#if os(iOS)
import SwiftUI

struct TerminalFloatingInputControl: View {
    let style: TerminalFloatingControlPreferences.ActiveStyle
    let preferences: TerminalFloatingControlPreferences
    let hasProAccess: Bool
    let voiceEnabled: Bool
    let terminalIsReady: Bool
    let phase: TerminalFloatingInputPhase
    let audioService: AudioService
    let onVoiceToggle: () -> Void
    let onCancelVoice: () -> Void
    let onShowKeyboard: () -> Void
    let onSendReturn: () -> Void
    let onSystemAction: (TerminalAccessorySystemActionID) -> Void
    let onMove: (Double, Double) -> Void
    let onHide: (TerminalFloatingControlPreferences.HiddenSide, Double) -> Void
    let onShow: () -> Void
    let onResetPosition: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var controlMorphNamespace
    @State private var dragState = DragState.idle

    private let controlDragMinimumDistance: CGFloat = 10
    private let edgeDragMinimumDistance: CGFloat = 4

    private enum SecondaryAction: Hashable {
        case configured(TerminalFloatingControlPreferences.Action)
        case cancelVoice
    }

    private nonisolated enum SecondarySlot: Int, CaseIterable, Hashable, Identifiable, Sendable {
        case first
        case second
        case third
        case fourth
        case fifth
        case sixth
        case seventh

        var id: Self { self }
    }

    private struct SecondaryControlItem: Identifiable {
        let id: SecondarySlot
        let action: SecondaryAction
        let center: CGPoint
    }

    private nonisolated enum GlassElementID: Hashable, Sendable {
        case primary
        case secondary(SecondarySlot)
    }

    private enum DragState: Equatable {
        case idle
        case control(CGSize)
        case edge(CGSize)

        var controlTranslation: CGSize {
            switch self {
            case .idle: .zero
            case .control(let translation): translation
            case .edge: .zero
            }
        }

        var edgeTranslation: CGSize {
            switch self {
            case .idle, .control: .zero
            case .edge(let translation): translation
            }
        }

        var isDraggingControl: Bool {
            if case .control = self { return true }
            return false
        }
    }

    private var idleActionLayout: TerminalFloatingControlPreferences.ActionLayout {
        preferences.resolvedActionLayout(
            for: style,
            hasProAccess: hasProAccess,
            voiceEnabled: voiceEnabled
        )
    }

    private var secondaryActions: [SecondaryAction] {
        switch phase {
        case .starting, .recording:
            return [.cancelVoice]
        case .processing:
            return []
        case .pendingReturn:
            let maximumSystemActionCount = max(
                style.maximumSecondaryActionCount - 1,
                0
            )
            let systemActions: [TerminalAccessorySystemActionID] =
                idleActionLayout.allActions.compactMap { action in
                    guard case .system(let systemAction) = action else { return nil }
                    return systemAction
                }
            return ([TerminalFloatingControlPreferences.Action.keyboard]
                + systemActions
                    .prefix(maximumSystemActionCount)
                    .map(TerminalFloatingControlPreferences.Action.system))
                .map(SecondaryAction.configured)
        case .idle:
            return idleActionLayout.secondaryActions.map(SecondaryAction.configured)
        }
    }

    private var mainButtonSize: CGFloat {
        TerminalFloatingControlLayout.mainButtonSize(for: style)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let hiddenSide = preferences.hiddenSide,
                   phase.allowsHiding {
                    draggableEdgeHandle(for: hiddenSide, in: proxy)
                        .transition(.opacity)
                } else {
                    let bounds = anchorBounds(in: proxy)
                    let storedAnchor = TerminalFloatingControlLayout.center(
                        horizontalFraction: preferences.horizontalFraction,
                        verticalFraction: preferences.verticalFraction,
                        in: bounds
                    )
                    let controlAnchor = displayedAnchor(
                        from: storedAnchor,
                        bounds: bounds,
                        in: proxy
                    )
                    let currentSecondaryActions = secondaryActions
                    let placement = TerminalFloatingControlLayout.placement(
                        for: style,
                        anchorCenter: controlAnchor,
                        secondaryActionCount: currentSecondaryActions.count,
                        containerSize: proxy.size,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
                    let secondaryItems = secondaryControlItems(
                        actions: currentSecondaryActions,
                        centers: placement.secondaryCenters
                    )

                    if phase.showsVoiceStatus {
                        voiceStatus(in: proxy, controlFrame: placement.frame)
                    }

                    groupedControl(
                        placement: placement,
                        secondaryItems: secondaryItems
                    )
                        .frame(
                            width: placement.frame.width,
                            height: placement.frame.height
                        )
                        .simultaneousGesture(
                            controlDragGesture(in: proxy, from: storedAnchor)
                        )
                        .position(placement.frameCenter)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("vvterm.terminal.floatingInputControl")
                        .accessibilityValue(
                            style == .radial
                                ? String(localized: "Radial Control")
                                : String(localized: "Compact Buttons")
                        )
                        .accessibilityAction(named: Text("Move Up")) {
                            moveVertically(by: -0.1)
                        }
                        .accessibilityAction(named: Text("Move Down")) {
                            moveVertically(by: 0.1)
                        }
                        .accessibilityAction(named: Text("Move to Left")) {
                            moveHorizontally(by: -0.1)
                        }
                        .accessibilityAction(named: Text("Move to Right")) {
                            moveHorizontally(by: 0.1)
                        }
                        .accessibilityAction(named: Text("Reset Position")) {
                            onResetPosition()
                        }
                        .modifier(
                            FloatingControlHideAccessibility(
                                isEnabled: phase.allowsHiding,
                                onHideLeft: { hideOnSide(.left) },
                                onHideRight: { hideOnSide(.right) }
                            )
                        )
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Measure the full container; the layout applies its safe-area insets once.
        .ignoresSafeArea(.container)
        .animation(controlAnimation, value: phase)
        .animation(controlAnimation, value: preferences.hiddenSide)
    }

    private var controlAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .smooth(duration: 0.34)
    }

    private func draggableEdgeHandle(
        for side: TerminalFloatingControlPreferences.HiddenSide,
        in proxy: GeometryProxy
    ) -> some View {
        TerminalFloatingControlEdgeHandle(side: side, action: onShow)
            .matchedGeometryEffect(
                id: "floating-control-primary",
                in: controlMorphNamespace
            )
            .position(
                TerminalFloatingControlLayout.edgeHandleDragCenter(
                    for: side,
                    verticalFraction: preferences.verticalFraction,
                    translation: dragState.edgeTranslation,
                    containerSize: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets
                )
            )
            .highPriorityGesture(edgeHandleDragGesture(for: side, in: proxy))
    }

    @ViewBuilder
    private func groupedControl(
        placement: TerminalFloatingControlLayout.Placement,
        secondaryItems: [SecondaryControlItem]
    ) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: TerminalFloatingControlLayout.buttonSpacing) {
                controlLayout(
                    placement: placement,
                    secondaryItems: secondaryItems
                )
            }
        } else {
            controlLayout(
                placement: placement,
                secondaryItems: secondaryItems
            )
        }
    }

    private func controlLayout(
        placement: TerminalFloatingControlLayout.Placement,
        secondaryItems: [SecondaryControlItem]
    ) -> some View {
        ZStack {
            mainControl(size: mainButtonSize)
                .position(placement.localCenter(for: placement.mainCenter))
                .accessibilitySortPriority(10)

            ForEach(secondaryItems) { item in
                let mainCenter = placement.localCenter(for: placement.mainCenter)
                let actionCenter = placement.localCenter(for: item.center)
                secondaryControl(
                    item.action,
                    size: TerminalFloatingControlLayout.radialSecondaryButtonSize,
                    glassElementID: .secondary(item.id)
                )
                .position(actionCenter)
                .accessibilitySortPriority(Double(9 - item.id.rawValue))
                .transition(
                    secondaryActionTransition(
                        from: actionCenter,
                        toward: mainCenter
                    )
                )
            }
        }
    }

    private func mainControl(size: CGFloat) -> some View {
        actionButton(
            mainControlPresentation,
            size: size,
            glassElementID: .primary
        )
            .matchedGeometryEffect(
                id: "floating-control-primary",
                in: controlMorphNamespace
            )
    }

    private var mainControlPresentation: TerminalFloatingInputControlPresentation {
        .main(
            for: phase,
            idleAction: idleActionLayout.primaryAction,
            terminalIsReady: terminalIsReady
        )
    }

    private func secondaryControl(
        _ action: SecondaryAction,
        size: CGFloat,
        glassElementID: GlassElementID
    ) -> some View {
        actionButton(
            secondaryPresentation(for: action),
            size: size,
            glassElementID: glassElementID
        )
    }

    private func secondaryPresentation(
        for action: SecondaryAction
    ) -> TerminalFloatingInputControlPresentation {
        switch action {
        case .configured(let configuredAction):
            .configured(
                configuredAction,
                isPrimary: false,
                terminalIsReady: terminalIsReady
            )
        case .cancelVoice:
            .cancelVoice
        }
    }

    @ViewBuilder
    private func actionButton(
        _ presentation: TerminalFloatingInputControlPresentation,
        size: CGFloat,
        glassElementID: GlassElementID
    ) -> some View {
        let button = TerminalFloatingControlButton(
            content: presentation.content,
            accessibilityLabel: presentation.accessibilityLabel,
            accessibilityIdentifier: presentation.accessibilityIdentifier,
            size: size,
            tint: presentation.tint.color,
            isEnabled: presentation.isEnabled,
            isInteractive: presentation.isInteractive,
            isRepeatable: presentation.isRepeatable,
            suppressesTap: dragState.isDraggingControl,
            action: { perform(presentation.intent) }
        )

        if #available(iOS 26, *) {
            button
                .glassEffectID(glassElementID, in: controlMorphNamespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            button
        }
    }

    private func secondaryControlItems(
        actions: [SecondaryAction],
        centers: [CGPoint]
    ) -> [SecondaryControlItem] {
        zip(SecondarySlot.allCases, zip(actions, centers)).map { slot, value in
            SecondaryControlItem(
                id: slot,
                action: value.0,
                center: value.1
            )
        }
    }

    private func perform(_ intent: TerminalFloatingInputControlPresentation.Intent) {
        switch intent {
        case .none:
            break
        case .toggleVoice:
            onVoiceToggle()
        case .cancelVoice:
            onCancelVoice()
        case .showKeyboard:
            onShowKeyboard()
        case .sendReturn:
            onSendReturn()
        case .system(let action):
            onSystemAction(action)
        }
    }

    private func secondaryActionTransition(
        from center: CGPoint,
        toward mainCenter: CGPoint
    ) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .offset(
            x: mainCenter.x - center.x,
            y: mainCenter.y - center.y
        )
        .combined(with: .scale(scale: 0.46))
        .combined(with: .opacity)
    }

    private func anchorBounds(in proxy: GeometryProxy) -> CGRect {
        TerminalFloatingControlLayout.anchorBounds(
            containerSize: proxy.size,
            safeAreaInsets: proxy.safeAreaInsets,
            mainButtonSize: mainButtonSize
        )
    }

    private func displayedAnchor(
        from storedAnchor: CGPoint,
        bounds: CGRect,
        in proxy: GeometryProxy
    ) -> CGPoint {
        let translation = dragState.controlTranslation
        let proposedCenter = CGPoint(
            x: storedAnchor.x + translation.width,
            y: storedAnchor.y + translation.height
        )
        return draggableCenter(proposedCenter, bounds: bounds, in: proxy)
    }

    private func draggableCenter(
        _ proposedCenter: CGPoint,
        bounds: CGRect,
        in proxy: GeometryProxy
    ) -> CGPoint {
        guard dragState.isDraggingControl, phase.allowsHiding else {
            return TerminalFloatingControlLayout.clampedCenter(
                proposedCenter,
                in: bounds
            )
        }
        return TerminalFloatingControlLayout.edgeDragCenter(
            proposedCenter,
            containerSize: proxy.size,
            safeAreaInsets: proxy.safeAreaInsets,
            anchorBounds: bounds
        )
    }

    private func controlDragGesture(
        in proxy: GeometryProxy,
        from storedAnchor: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: controlDragMinimumDistance, coordinateSpace: .global)
            .onChanged { value in
                let bounds = anchorBounds(in: proxy)
                let proposedCenter = CGPoint(
                    x: storedAnchor.x + value.translation.width,
                    y: storedAnchor.y + value.translation.height
                )
                let center = phase.allowsHiding
                    ? TerminalFloatingControlLayout.edgeDragCenter(
                        proposedCenter,
                        containerSize: proxy.size,
                        safeAreaInsets: proxy.safeAreaInsets,
                        anchorBounds: bounds
                    )
                    : TerminalFloatingControlLayout.clampedCenter(
                        proposedCenter,
                        in: bounds
                    )
                let nextState = DragState.control(
                    CGSize(
                        width: center.x - storedAnchor.x,
                        height: center.y - storedAnchor.y
                    )
                )
                if dragState != nextState {
                    dragState = nextState
                }
            }
            .onEnded { value in
                let bounds = anchorBounds(in: proxy)
                let proposedCenter = CGPoint(
                    x: storedAnchor.x + value.translation.width,
                    y: storedAnchor.y + value.translation.height
                )
                let predictedEndCenter = CGPoint(
                    x: storedAnchor.x + value.predictedEndTranslation.width,
                    y: storedAnchor.y + value.predictedEndTranslation.height
                )
                let center = TerminalFloatingControlLayout.clampedCenter(
                    proposedCenter,
                    in: bounds
                )
                let position = TerminalFloatingControlLayout.normalizedPosition(
                    for: center,
                    in: bounds
                )
                if phase.allowsHiding,
                   let side = TerminalFloatingControlLayout.hiddenSide(
                       for: proposedCenter,
                       predictedEndCenter: predictedEndCenter,
                       containerSize: proxy.size,
                       safeAreaInsets: proxy.safeAreaInsets
                   ) {
                    onHide(side, position.verticalFraction)
                } else {
                    onMove(position.horizontalFraction, position.verticalFraction)
                }
                DispatchQueue.main.async {
                    dragState = .idle
                }
            }
    }

    private func edgeHandleDragGesture(
        for side: TerminalFloatingControlPreferences.HiddenSide,
        in proxy: GeometryProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: edgeDragMinimumDistance, coordinateSpace: .global)
            .onChanged { value in
                let nextState = DragState.edge(value.translation)
                if dragState != nextState {
                    dragState = nextState
                }
            }
            .onEnded { value in
                switch TerminalFloatingControlLayout.edgeHandleRelease(
                    for: side,
                    verticalFraction: preferences.verticalFraction,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    style: style,
                    containerSize: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets
                ) {
                case .hidden(let verticalFraction):
                    onHide(side, verticalFraction)
                case .visible(let position):
                    onMove(position.horizontalFraction, position.verticalFraction)
                }
                DispatchQueue.main.async {
                    dragState = .idle
                }
            }
    }

    private func hideOnSide(_ side: TerminalFloatingControlPreferences.HiddenSide) {
        guard phase.allowsHiding else { return }
        onHide(
            side,
            TerminalFloatingControlLayout.normalizedFraction(
                preferences.verticalFraction,
                fallback: TerminalFloatingControlPreferences.defaultVerticalFraction
            )
        )
    }

    private func moveHorizontally(by amount: Double) {
        let horizontalFraction = TerminalFloatingControlLayout.normalizedFraction(
            preferences.horizontalFraction,
            fallback: TerminalFloatingControlPreferences.defaultHorizontalFraction
        )
        onMove(
            min(max(horizontalFraction + amount, 0), 1),
            TerminalFloatingControlLayout.normalizedFraction(
                preferences.verticalFraction,
                fallback: TerminalFloatingControlPreferences.defaultVerticalFraction
            )
        )
    }

    private func moveVertically(by amount: Double) {
        let verticalFraction = TerminalFloatingControlLayout.normalizedFraction(
            preferences.verticalFraction,
            fallback: TerminalFloatingControlPreferences.defaultVerticalFraction
        )
        onMove(
            TerminalFloatingControlLayout.normalizedFraction(
                preferences.horizontalFraction,
                fallback: TerminalFloatingControlPreferences.defaultHorizontalFraction
            ),
            min(max(verticalFraction + amount, 0), 1)
        )
    }

    private func voiceStatus(
        in proxy: GeometryProxy,
        controlFrame: CGRect
    ) -> some View {
        let panelWidth = TerminalFloatingControlLayout.voiceStatusWidth(
            containerSize: proxy.size,
            safeAreaInsets: proxy.safeAreaInsets
        )
        return TerminalFloatingVoiceStatus(
            phase: phase,
            audioService: audioService
        )
        .frame(width: panelWidth, alignment: .leading)
        .position(
            TerminalFloatingControlLayout.voiceStatusCenter(
                controlFrame: controlFrame,
                panelWidth: panelWidth,
                containerSize: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets
            )
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
    }
}

private struct FloatingControlHideAccessibility: ViewModifier {
    let isEnabled: Bool
    let onHideLeft: () -> Void
    let onHideRight: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityHint(
                    "Drag past the left or right edge to hide the controls."
                )
                .accessibilityAction(named: Text("Hide on Left"), onHideLeft)
                .accessibilityAction(named: Text("Hide on Right"), onHideRight)
        } else {
            content
        }
    }
}
#endif
