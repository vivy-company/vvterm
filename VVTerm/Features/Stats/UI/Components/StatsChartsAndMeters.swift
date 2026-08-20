import SwiftUI
import Charts

// MARK: - Charts

struct MetricPreviewChart: View {
    let history: [StatsPoint]
    let color: Color
    let yDomain: ClosedRange<Double>
    let style: StatsVisualStyle

    var body: some View {
        if history.count < 2 {
            PreviewPlaceholder(color: color, style: style)
        } else {
            Chart {
                ForEach(history) { point in
                    AreaMark(
                        x: .value(String(localized: "Time"), point.timestamp),
                        y: .value(String(localized: "Value"), point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.30), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value(String(localized: "Time"), point.timestamp),
                        y: .value(String(localized: "Value"), point.value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
        }
    }
}

struct NetworkLineChart: View {
    let rxHistory: [StatsPoint]
    let txHistory: [StatsPoint]
    let style: StatsVisualStyle
    private let minimumWindow: TimeInterval = 60
    private let maximumWindow: TimeInterval = 300

    private var rxSamples: [StatsPoint] {
        Array(rxHistory.suffix(30)).sorted { $0.timestamp < $1.timestamp }
    }

    private var txSamples: [StatsPoint] {
        Array(txHistory.suffix(30)).sorted { $0.timestamp < $1.timestamp }
    }

    private var chartMax: Double {
        let maxValue = max(
            rxSamples.map(\.value).max() ?? 0,
            txSamples.map(\.value).max() ?? 0
        )
        return max(maxValue * 1.15, 1)
    }

    private var timeWindow: (start: Date, end: Date)? {
        let timestamps = (rxSamples + txSamples).map(\.timestamp)
        guard let first = timestamps.min(), let last = timestamps.max() else { return nil }
        let span = min(max(last.timeIntervalSince(first), minimumWindow), maximumWindow)
        return (last.addingTimeInterval(-span), last)
    }

    var body: some View {
        if rxSamples.count < 2, txSamples.count < 2 {
            NetworkLinePlaceholder()
        } else {
            GeometryReader { proxy in
                if let window = timeWindow {
                    let rxPoints = points(for: rxSamples, in: proxy.size, window: window)
                    let txPoints = points(for: txSamples, in: proxy.size, window: window)

                    ZStack {
                        Rectangle()
                            .fill(style.tertiaryText.opacity(0.30))
                            .frame(height: 1)
                            .frame(maxHeight: .infinity, alignment: .center)

                        NetworkAreaShape(points: txPoints)
                            .fill(networkGradient(.orange, opacity: 0.14))
                        NetworkAreaShape(points: rxPoints)
                            .fill(networkGradient(.cyan, opacity: 0.22))

                        NetworkLineShape(points: txPoints)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        NetworkLineShape(points: rxPoints)
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    NetworkLinePlaceholder()
                }
            }
        }
    }

    private func points(
        for samples: [StatsPoint],
        in size: CGSize,
        window: (start: Date, end: Date)
    ) -> [CGPoint] {
        guard size.width > 0, size.height > 0 else { return [] }
        let duration = max(window.end.timeIntervalSince(window.start), 1)
        let topInset = max(size.height * 0.08, 4)
        let bottomInset = max(size.height * 0.10, 5)
        let plotHeight = max(size.height - topInset - bottomInset, 1)

        return samples.compactMap { point in
            guard point.timestamp >= window.start, point.timestamp <= window.end else { return nil }
            let xProgress = point.timestamp.timeIntervalSince(window.start) / duration
            let yProgress = min(max(point.value / chartMax, 0), 1)
            return CGPoint(
                x: size.width * xProgress,
                y: topInset + plotHeight * (1 - yProgress)
            )
        }
    }

    private func networkGradient(_ color: Color, opacity: Double) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(opacity), color.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private nonisolated struct NetworkLineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        NetworkPath.smoothLine(points)
    }
}

private nonisolated struct NetworkAreaShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        guard points.count >= 2 else { return Path() }
        var path = NetworkPath.smoothLine(points)
        if let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

private nonisolated enum NetworkPath {
    static func smoothLine(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }

        for index in 0..<(points.count - 1) {
            let previous = points[max(index - 1, 0)]
            let current = points[index]
            let next = points[index + 1]
            let following = points[min(index + 2, points.count - 1)]
            let controlA = clampedControlPoint(
                CGPoint(
                    x: current.x + (next.x - previous.x) / 6,
                    y: current.y + (next.y - previous.y) / 6
                ),
                between: current,
                and: next
            )
            let controlB = clampedControlPoint(
                CGPoint(
                    x: next.x - (following.x - current.x) / 6,
                    y: next.y - (following.y - current.y) / 6
                ),
                between: current,
                and: next
            )
            path.addCurve(to: next, control1: controlA, control2: controlB)
        }

        return path
    }

    private static func clampedControlPoint(_ point: CGPoint, between start: CGPoint, and end: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, min(start.x, end.x)), max(start.x, end.x)),
            y: min(max(point.y, min(start.y, end.y)), max(start.y, end.y))
        )
    }
}

private struct NetworkLinePlaceholder: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.02, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.28, y: height * 0.44))
                    path.addLine(to: CGPoint(x: width * 0.54, y: height * 0.56))
                    path.addLine(to: CGPoint(x: width * 0.78, y: height * 0.34))
                    path.addLine(to: CGPoint(x: width * 0.98, y: height * 0.48))
                }
                .stroke(Color.cyan.opacity(0.42), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: CGPoint(x: width * 0.02, y: height * 0.84))
                    path.addLine(to: CGPoint(x: width * 0.24, y: height * 0.66))
                    path.addLine(to: CGPoint(x: width * 0.52, y: height * 0.76))
                    path.addLine(to: CGPoint(x: width * 0.76, y: height * 0.58))
                    path.addLine(to: CGPoint(x: width * 0.98, y: height * 0.68))
                }
                .stroke(Color.orange.opacity(0.34), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PreviewPlaceholder: View {
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(index == 4 ? color : style.tertiaryText)
                    .frame(width: 10, height: CGFloat([28, 50, 35, 76, 44, 18][index]))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 6)
        .padding(.bottom, 6)
    }
}

// MARK: - Meters

struct CapacitySegment {
    let value: Double
    let color: Color
}

struct SegmentedCapacityBar: View {
    let segments: [CapacitySegment]
    let total: Double
    let style: StatsVisualStyle

    private var visibleSegments: [CapacitySegment] {
        segments.filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing = CGFloat(max(visibleSegments.count - 1, 0)) * 3
            let availableWidth = max(proxy.size.width - spacing, 0)
            let effectiveTotal = max(total, visibleSegments.map(\.value).reduce(0, +), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(style.meterTrack)

                HStack(spacing: 3) {
                    ForEach(Array(visibleSegments.enumerated()), id: \.offset) { _, segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: max(availableWidth * CGFloat(segment.value / effectiveTotal), 2))
                    }
                }
            }
        }
        .frame(height: 9)
    }
}

struct MiniMeter: View {
    let value: Double
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(style.meterTrack)

            Capsule()
                .fill(color)
                .scaleEffect(x: min(max(value, 0), 1), y: 1, anchor: .leading)
        }
        .frame(height: 6)
    }
}

// MARK: - Error

struct ConnectionErrorOverlay: View {
    let error: String
    let style: StatsVisualStyle
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text(String(localized: "Connection Failed"))
                .font(.headline)
                .foregroundStyle(style.primaryText)

            Text(error)
                .font(.caption)
                .foregroundStyle(style.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(String(localized: "Retry"), action: retry)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
