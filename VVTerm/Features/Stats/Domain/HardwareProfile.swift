import Foundation

nonisolated struct HardwareProfile: Equatable, Sendable {
    var hostname: String
    var osInfo: String
    var architecture: String
    var kernelVersion: String
    var cpuModel: String
    var cpuVendor: String
    var cpuCores: Int
    var cpuThreads: Int
    var memoryTotal: UInt64
    var gpus: [GPUDevice]
    var collectedAt: Date

    static let empty = HardwareProfile(
        hostname: "",
        osInfo: "",
        architecture: "",
        kernelVersion: "",
        cpuModel: "",
        cpuVendor: "",
        cpuCores: 0,
        cpuThreads: 0,
        memoryTotal: 0,
        gpus: [],
        collectedAt: .distantPast
    )

    var isEmpty: Bool {
        hostname.isEmpty
            && osInfo.isEmpty
            && architecture.isEmpty
            && kernelVersion.isEmpty
            && cpuModel.isEmpty
            && cpuVendor.isEmpty
            && cpuCores == 0
            && cpuThreads == 0
            && memoryTotal == 0
            && gpus.isEmpty
    }
}
