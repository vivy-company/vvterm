import Foundation

nonisolated enum GPUKind: String, Codable, Equatable, Sendable {
    case nvidia
    case amd
    case intel
    case apple
    case unknown
}

nonisolated enum GPUSource: String, Codable, Equatable, Sendable {
    case nvidiaSMI
    case rocmSMI
    case intelGPU
    case systemProfiler
    case powerMetrics
    case wmi
    case unknown
}

nonisolated struct GPUDevice: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var vendor: String
    var kind: GPUKind
    var driverVersion: String
    var memoryTotal: UInt64
    var source: GPUSource

    var displayName: String {
        name.isEmpty ? vendor : name
    }
}

nonisolated struct GPUSample: Identifiable, Codable, Equatable, Sendable {
    var id: String { deviceID }
    var deviceID: String
    var utilizationPercent: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var temperatureCelsius: Double?
    var powerWatts: Double?
    var processes: [GPUProcess]
    var source: GPUSource
    var timestamp: Date

    var memoryPercent: Double? {
        guard let memoryUsed,
              let memoryTotal,
              memoryTotal > 0 else {
            return nil
        }
        return min(max(Double(memoryUsed) / Double(memoryTotal) * 100, 0), 100)
    }
}

nonisolated struct GPUProcess: Identifiable, Codable, Equatable, Sendable {
    var id: Int { pid }
    var pid: Int
    var name: String
    var memoryUsed: UInt64?
    var utilizationPercent: Double?
}
