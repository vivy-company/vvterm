import Foundation

nonisolated enum TmuxLifecycleEvent: String, Hashable, Sendable {
    case detached
    case ended
    case creationFailed
}

nonisolated enum TmuxLifecycleMarker {
    nonisolated private static let prefix = "\u{001B}]777;vvterm-tmux;"
    nonisolated private static let terminator = "\u{0007}"

    nonisolated static func sequence(token: String, event: TmuxLifecycleEvent) -> String {
        "\(prefix)\(token);\(event.rawValue)\(terminator)"
    }
}

nonisolated struct TmuxLifecycleStreamParser: Sendable {
    nonisolated struct Result: Equatable, Sendable {
        let output: Data
        let events: [TmuxLifecycleEvent]
    }

    private let markers: [(event: TmuxLifecycleEvent, data: Data)]
    private var pending = Data()

    nonisolated init(markerToken: String) {
        markers = TmuxLifecycleEvent.allCasesForParsing.map { event in
            (event, Data(TmuxLifecycleMarker.sequence(token: markerToken, event: event).utf8))
        }
    }

    nonisolated mutating func consume(_ data: Data) -> Result {
        pending.append(data)
        var output = Data()
        var events: [TmuxLifecycleEvent] = []

        while let match = earliestMarkerMatch() {
            output.append(pending[..<match.range.lowerBound])
            pending.removeSubrange(..<match.range.upperBound)
            events.append(match.event)
        }

        let suffixLength = longestPossibleMarkerPrefixSuffixLength()
        let outputEnd = pending.index(pending.endIndex, offsetBy: -suffixLength)
        output.append(pending[..<outputEnd])
        pending.removeSubrange(..<outputEnd)

        return Result(output: output, events: events)
    }

    nonisolated mutating func finish() -> Data {
        defer { pending.removeAll(keepingCapacity: false) }
        return pending
    }

    nonisolated private func earliestMarkerMatch() -> (event: TmuxLifecycleEvent, range: Range<Data.Index>)? {
        markers.compactMap { marker in
            pending.range(of: marker.data).map { (marker.event, $0) }
        }.min { lhs, rhs in
            lhs.1.lowerBound < rhs.1.lowerBound
        }
    }

    nonisolated private func longestPossibleMarkerPrefixSuffixLength() -> Int {
        let maximumLength = min(pending.count, markers.map(\.data.count).max() ?? 0)
        guard maximumLength > 0 else { return 0 }

        for length in stride(from: maximumLength, through: 1, by: -1) {
            let suffixStart = pending.index(pending.endIndex, offsetBy: -length)
            let suffix = pending[suffixStart...]
            if markers.contains(where: { marker in
                marker.data.prefix(length).elementsEqual(suffix)
            }) {
                return length
            }
        }

        return 0
    }
}

private extension TmuxLifecycleEvent {
    nonisolated static var allCasesForParsing: [TmuxLifecycleEvent] {
        [.detached, .ended, .creationFailed]
    }
}
