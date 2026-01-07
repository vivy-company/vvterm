//
//  DetailHeaderBar.swift
//  VivyTerm
//
//  Shared header for sheet views
//

import SwiftUI

struct DetailHeaderBar<Leading: View, Trailing: View>: View {
    let showsBackground: Bool
    let padding: EdgeInsets?
    let leading: Leading
    let trailing: Trailing

    init(
        showsBackground: Bool = true,
        padding: EdgeInsets? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.showsBackground = showsBackground
        self.padding = padding
        self.leading = leading()
        self.trailing = trailing()
    }

    init(
        showsBackground: Bool = true,
        padding: EdgeInsets? = nil,
        @ViewBuilder leading: () -> Leading
    ) where Trailing == EmptyView {
        self.showsBackground = showsBackground
        self.padding = padding
        self.leading = leading()
        self.trailing = EmptyView()
    }

    var body: some View {
        let content = HStack {
            leading
            Spacer()
            trailing
        }

        if let padding = padding {
            content
                .padding(padding)
                .modifier(DetailHeaderBackground(enabled: showsBackground))
        } else {
            content
                .padding()
                .modifier(DetailHeaderBackground(enabled: showsBackground))
        }
    }
}

struct DetailCloseButton: View {
    let action: () -> Void
    var size: CGFloat = 20
    var color: Color = .secondary

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

private struct DetailHeaderBackground: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.background(.ultraThinMaterial)
        } else {
            content
        }
    }
}
