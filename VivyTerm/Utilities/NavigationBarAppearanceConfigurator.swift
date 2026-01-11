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

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let navBar = uiViewController.navigationController?.navigationBar else { return }

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
    }
}

extension View {
    func navigationBarAppearance(backgroundColor: UIColor, isTranslucent: Bool = false, shadowColor: UIColor? = nil) -> some View {
        background(
            NavigationBarAppearanceConfigurator(
                backgroundColor: backgroundColor,
                isTranslucent: isTranslucent,
                shadowColor: shadowColor
            )
        )
    }
}
#endif
