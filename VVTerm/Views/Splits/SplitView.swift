//
//  SplitView.swift
//  VVTerm
//
//  A split view shows a left and right (or top and bottom) view with a divider
//  Adapted from Ghostty terminal emulator
//

#if os(macOS)
import SwiftUI
import AppKit

/// Direction of the split
enum SplitViewDirection: Codable {
    case horizontal, vertical
}

/// A split view shows a left and right (or top and bottom) view with a divider in the middle to do resizing.
struct SplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection

    /// Divider color
    let dividerColor: Color

    /// Minimum increment (in points) that this split can be resized by
    let resizeIncrements: NSSize

    /// The left and right views to render.
    let left: L
    let right: R

    /// Called when the divider is double-tapped to equalize splits.
    let onEqualize: () -> Void

    /// The minimum size (in points) of a split
    let minSize: CGFloat = 10

    /// The current fractional width of the split view. 0.5 means L/R are equally sized.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points.
    private let splitterVisibleSize: CGFloat = 1
    private let splitterInvisibleSize: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let leftRect = self.leftRect(for: geo.size)
            let rightRect = self.rightRect(for: geo.size, leftRect: leftRect)
            let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect)

            ZStack(alignment: .topLeading) {
                left
                    .frame(width: leftRect.size.width, height: leftRect.size.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(leftPaneLabel)
                right
                    .frame(width: rightRect.size.width, height: rightRect.size.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rightPaneLabel)
                Divider(direction: direction,
                        visibleSize: splitterVisibleSize,
                        invisibleSize: splitterInvisibleSize,
                        color: dividerColor,
                        split: $split)
                    .position(splitterPoint)
                    .gesture(dragGesture(geo.size, splitterPoint: splitterPoint))
                    .onTapGesture(count: 2) {
                        onEqualize()
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
        }
    }

    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.resizeIncrements = resizeIncrements
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    private func dragGesture(_ size: CGSize, splitterPoint: CGPoint) -> some Gesture {
        return DragGesture()
            .onChanged { gesture in
                switch (direction) {
                case .horizontal:
                    let new = min(max(minSize, gesture.location.x), size.width - minSize)
                    split = new / size.width

                case .vertical:
                    let new = min(max(minSize, gesture.location.y), size.height - minSize)
                    split = new / size.height
                }
            }
    }

    private func leftRect(for size: CGSize) -> CGRect {
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch (direction) {
        case .horizontal:
            result.size.width = result.size.width * split
            result.size.width -= splitterVisibleSize / 2
            result.size.width -= result.size.width.truncatingRemainder(dividingBy: self.resizeIncrements.width)

        case .vertical:
            result.size.height = result.size.height * split
            result.size.height -= splitterVisibleSize / 2
            result.size.height -= result.size.height.truncatingRemainder(dividingBy: self.resizeIncrements.height)
        }

        return result
    }

    private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch (direction) {
        case .horizontal:
            result.origin.x += leftRect.size.width
            result.origin.x += splitterVisibleSize / 2
            result.size.width -= result.origin.x

        case .vertical:
            result.origin.y += leftRect.size.height
            result.origin.y += splitterVisibleSize / 2
            result.size.height -= result.origin.y
        }

        return result
    }

    private func splitterPoint(for size: CGSize, leftRect: CGRect) -> CGPoint {
        switch (direction) {
        case .horizontal:
            return CGPoint(x: leftRect.size.width, y: size.height / 2)

        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.size.height)
        }
    }

    // MARK: Accessibility

    private var splitViewLabel: String {
        switch direction {
        case .horizontal:
            return String(localized: "Horizontal split view")
        case .vertical:
            return String(localized: "Vertical split view")
        }
    }

    private var leftPaneLabel: String {
        switch direction {
        case .horizontal:
            return String(localized: "Left pane")
        case .vertical:
            return String(localized: "Top pane")
        }
    }

    private var rightPaneLabel: String {
        switch direction {
        case .horizontal:
            return String(localized: "Right pane")
        case .vertical:
            return String(localized: "Bottom pane")
        }
    }
}

// MARK: - Divider

extension SplitView {
    /// The split divider that is rendered and can be used to resize a split view.
    struct Divider: View {
        let direction: SplitViewDirection
        let visibleSize: CGFloat
        let invisibleSize: CGFloat
        let color: Color
        @Binding var split: CGFloat

        private var visibleWidth: CGFloat? {
            switch (direction) {
            case .horizontal:
                return visibleSize
            case .vertical:
                return nil
            }
        }

        private var visibleHeight: CGFloat? {
            switch (direction) {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize
            }
        }

        private var invisibleWidth: CGFloat? {
            switch (direction) {
            case .horizontal:
                return visibleSize + invisibleSize
            case .vertical:
                return nil
            }
        }

        private var invisibleHeight: CGFloat? {
            switch (direction) {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize + invisibleSize
            }
        }

        var body: some View {
            ZStack {
                Color.clear
                    .frame(width: invisibleWidth, height: invisibleHeight)
                    .contentShape(Rectangle())
                Rectangle()
                    .fill(color)
                    .frame(width: visibleWidth, height: visibleHeight)
            }
            .onHover { isHovered in
                if (isHovered) {
                    switch (direction) {
                    case .horizontal:
                        NSCursor.resizeLeftRight.push()
                    case .vertical:
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel)
            .accessibilityValue("\(Int(split * 100))%")
            .accessibilityHint(axHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat = 0.025
                switch direction {
                case .increment:
                    split = min(split + adjustment, 0.9)
                case .decrement:
                    split = max(split - adjustment, 0.1)
                @unknown default:
                    break
                }
            }
        }

        private var axLabel: String {
            switch direction {
            case .horizontal:
                return String(localized: "Horizontal split divider")
            case .vertical:
                return String(localized: "Vertical split divider")
            }
        }

        private var axHint: String {
            switch direction {
            case .horizontal:
                return String(localized: "Drag to resize the left and right panes")
            case .vertical:
                return String(localized: "Drag to resize the top and bottom panes")
            }
        }
    }
}

#endif
