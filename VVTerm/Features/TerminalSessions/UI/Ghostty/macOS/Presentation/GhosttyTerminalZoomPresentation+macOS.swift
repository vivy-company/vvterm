//
//  GhosttyTerminalZoomPresentation+macOS.swift
//  VVTerm
//
//  macOS terminal zoom gesture and indicator presentation.
//

#if os(macOS)
import AppKit

extension GhosttyTerminalView {
    override func magnify(with event: NSEvent) {
        accumulatedMagnification += event.magnification

        if accumulatedMagnification >= CGFloat(TerminalZoomPresentation.magnificationStepThreshold) {
            if let result = onZoomAction?(.zoomIn) {
                showZoomIndicator(fontSize: result.effectiveFontSize)
            }
            accumulatedMagnification = 0
        } else if accumulatedMagnification <= -CGFloat(TerminalZoomPresentation.magnificationStepThreshold) {
            if let result = onZoomAction?(.zoomOut) {
                showZoomIndicator(fontSize: result.effectiveFontSize)
            }
            accumulatedMagnification = 0
        }

        if event.phase == .ended || event.phase == .cancelled {
            accumulatedMagnification = 0
            scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorGestureEndHideDelay)
        }
    }

    private func showZoomIndicator() {
        showZoomIndicator(fontSize: surfacePresentationOverrides.resolvedFontSize())
    }

    func showZoomIndicator(fontSize: Double) {
        zoomIndicatorView.update(fontSize: fontSize)
        updateZoomIndicatorLayout()
        addSubview(zoomIndicatorView, positioned: .above, relativeTo: nil)

        zoomIndicatorHideWorkItem?.cancel()
        zoomIndicatorView.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TerminalZoomPresentation.indicatorFadeInDuration
            zoomIndicatorView.animator().alphaValue = 1
        }
        scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorHideDelay)
    }

    private func scheduleZoomIndicatorHide(after delay: TimeInterval) {
        zoomIndicatorHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = TerminalZoomPresentation.indicatorFadeOutDuration
                self.zoomIndicatorView.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.zoomIndicatorView.isHidden = true
                }
            })
        }
        zoomIndicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func updateZoomIndicatorLayout() {
        let fittingSize = zoomIndicatorView.fittingSize
        let width = max(fittingSize.width, CGFloat(TerminalZoomPresentation.indicatorMinimumWidth))
        let height = max(fittingSize.height, CGFloat(TerminalZoomPresentation.indicatorMinimumHeight))
        zoomIndicatorView.frame = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}

final class TerminalZoomIndicatorView: NSVisualEffectView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: TerminalZoomPresentation.indicatorTitle)
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.alignment = .center

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        titleLabel.alignment = .center

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 3
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(valueLabel)
        stackView.addArrangedSubview(titleLabel)
        addSubview(stackView)

        // Padding constraints are non-required so they break silently while the
        // view still has a zero-size autoresizing frame (before it's shown),
        // instead of logging "unable to satisfy" conflicts. They hold normally
        // once the view is sized.
        let padding = [
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ]
        padding.forEach { $0.priority = NSLayoutConstraint.Priority(999) }
        NSLayoutConstraint.activate(padding + [
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(fontSize: Double) {
        valueLabel.stringValue = TerminalZoomPresentation.formattedFontSize(fontSize)
    }
}

#endif
