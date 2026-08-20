//
//  GhosttyTerminalZoomPresentation+iOS.swift
//  VVTerm
//
//  iOS terminal zoom presentation.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    func showZoomIndicator() {
        showZoomIndicator(fontSize: surfacePresentationOverrides.resolvedFontSize())
    }

    func showZoomIndicator(fontSize: Double) {
        zoomIndicatorView.update(fontSize: fontSize)
        updateZoomIndicatorLayout()
        bringSubviewToFront(zoomIndicatorView)

        zoomIndicatorHideWorkItem?.cancel()
        zoomIndicatorView.isHidden = false
        UIView.animate(withDuration: TerminalZoomPresentation.indicatorFadeInDuration) {
            self.zoomIndicatorView.alpha = 1
        }
        scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorHideDelay)
    }

    func scheduleZoomIndicatorHide(after delay: TimeInterval) {
        zoomIndicatorHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: TerminalZoomPresentation.indicatorFadeOutDuration, animations: {
                self.zoomIndicatorView.alpha = 0
            }, completion: { _ in
                self.zoomIndicatorView.isHidden = true
            })
        }
        zoomIndicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func updateZoomIndicatorLayout() {
        setNeedsLayout()
        layoutIfNeeded()
        zoomIndicatorView.layoutIfNeeded()
    }
}

final class TerminalZoomIndicatorView: UIVisualEffectView {
    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let stackView = UIStackView()

    override init(effect: UIVisualEffect? = UIBlurEffect(style: .systemChromeMaterialDark)) {
        super.init(effect: effect)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .center

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        titleLabel.textAlignment = .center
        titleLabel.text = TerminalZoomPresentation.indicatorTitle

        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 3
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(valueLabel)
        stackView.addArrangedSubview(titleLabel)
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -18),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(fontSize: Double) {
        valueLabel.text = TerminalZoomPresentation.formattedFontSize(fontSize)
    }
}

#endif
