//
//  SubscriptionManagementRoute.swift
//  VVTerm
//

import Foundation

nonisolated enum SubscriptionManagementRoute: Equatable, Sendable {
    case nativeSheet
    case web(URL)

    static func resolve(nativeSheetAvailable: Bool) -> Self {
        if nativeSheetAvailable {
            return .nativeSheet
        }

        return .web(URL(string: "https://apps.apple.com/account/subscriptions")!)
    }
}
