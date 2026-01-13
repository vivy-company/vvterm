//
//  NavigationBarAppearanceConfigurator.swift
//  VivyTerm
//

#if os(iOS)
import SwiftUI
import UIKit

struct NavigationBarAppearanceConfigurator: UIViewControllerRepresentable {
    let backgroundColor: UIColor
    var isTranslucent: Bool = false
    var shadowColor: UIColor? = nil
    var onDisappearBackgroundColor: UIColor? = nil
    var onDisappearIsTranslucent: Bool? = nil
    var onDisappearShadowColor: UIColor? = nil

    func makeUIViewController(context: Context) -> AppearanceController {
        AppearanceController()
    }

    func updateUIViewController(_ uiViewController: AppearanceController, context: Context) {
        uiViewController.updateConfig(
            backgroundColor: backgroundColor,
            isTranslucent: isTranslucent,
            shadowColor: shadowColor,
            onDisappearBackgroundColor: onDisappearBackgroundColor,
            onDisappearIsTranslucent: onDisappearIsTranslucent,
            onDisappearShadowColor: onDisappearShadowColor
        )
        uiViewController.applyAppearance()
    }
}

final class AppearanceController: UIViewController {
    private var backgroundColor: UIColor = .clear
    private var isTranslucent: Bool = false
    private var shadowColor: UIColor? = nil
    private var onDisappearBackgroundColor: UIColor? = nil
    private var onDisappearIsTranslucent: Bool? = nil
    private var onDisappearShadowColor: UIColor? = nil

    func updateConfig(
        backgroundColor: UIColor,
        isTranslucent: Bool,
        shadowColor: UIColor?,
        onDisappearBackgroundColor: UIColor?,
        onDisappearIsTranslucent: Bool?,
        onDisappearShadowColor: UIColor?
    ) {
        self.backgroundColor = backgroundColor
        self.isTranslucent = isTranslucent
        self.shadowColor = shadowColor
        self.onDisappearBackgroundColor = onDisappearBackgroundColor
        self.onDisappearIsTranslucent = onDisappearIsTranslucent
        self.onDisappearShadowColor = onDisappearShadowColor
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let bg = onDisappearBackgroundColor else { return }
        applyAppearance(
            backgroundColor: bg,
            isTranslucent: onDisappearIsTranslucent ?? isTranslucent,
            shadowColor: onDisappearShadowColor ?? shadowColor,
            disableAnimation: true
        )
    }

    func applyAppearance() {
        applyAppearance(
            backgroundColor: backgroundColor,
            isTranslucent: isTranslucent,
            shadowColor: shadowColor,
            disableAnimation: false
        )
    }

    private func applyAppearance(
        backgroundColor: UIColor,
        isTranslucent: Bool,
        shadowColor: UIColor?,
        disableAnimation: Bool
    ) {
        guard let navBar = navigationController?.navigationBar else { return }

        let applyBlock = {
            let appearance = UINavigationBarAppearance()
            if isTranslucent {
                appearance.configureWithTransparentBackground()
            } else {
                appearance.configureWithOpaqueBackground()
            }
            appearance.backgroundColor = backgroundColor
            appearance.shadowColor = shadowColor

            navBar.standardAppearance = appearance
            navBar.scrollEdgeAppearance = appearance
            navBar.compactAppearance = appearance
            navBar.isTranslucent = isTranslucent
            navBar.layer.removeAllAnimations()
            navBar.layoutIfNeeded()
        }

        if disableAnimation {
            UIView.performWithoutAnimation {
                applyBlock()
            }
        } else {
            applyBlock()
        }
    }
}

extension View {
    func navigationBarAppearance(
        backgroundColor: UIColor,
        isTranslucent: Bool = false,
        shadowColor: UIColor? = nil,
        onDisappearBackgroundColor: UIColor? = nil,
        onDisappearIsTranslucent: Bool? = nil,
        onDisappearShadowColor: UIColor? = nil
    ) -> some View {
        background(
            NavigationBarAppearanceConfigurator(
                backgroundColor: backgroundColor,
                isTranslucent: isTranslucent,
                shadowColor: shadowColor,
                onDisappearBackgroundColor: onDisappearBackgroundColor,
                onDisappearIsTranslucent: onDisappearIsTranslucent,
                onDisappearShadowColor: onDisappearShadowColor
            )
        )
    }
}
#endif
