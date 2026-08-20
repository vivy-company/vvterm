//
//  WelcomeView.swift
//  VVTerm
//

import SwiftUI

struct WelcomeView: View {
    @Binding var hasSeenWelcome: Bool
    let onCompleted: () -> Void

    var body: some View {
        platformContent
    }
}

#Preview {
    WelcomeView(hasSeenWelcome: .constant(false), onCompleted: {})
}
