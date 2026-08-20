/// Infrastructure-only addressing for a health probe. Locators are never
/// persisted, rendered, or included in a health report.
nonisolated struct StorageHealthProbeTarget: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case linux(devicePath: String, isEMMC: Bool)
        case darwin(nativeIdentifier: String, smartctlDevicePath: String?)
        case windows(diskNumber: UInt32)
        case freeBSD(devicePath: String)
        case openBSD(devicePath: String)
        case netBSD(devicePath: String)
    }

    let deviceID: StorageDeviceIdentity
    let kind: Kind
}

nonisolated enum StorageHealthResolvedMember: Hashable, Sendable {
    case target(
        role: StorageHealthMemberRole,
        StorageHealthProbeTarget,
        findings: [StorageHealthFinding]
    )
    case unresolved(
        id: StorageDeviceIdentity,
        role: StorageHealthMemberRole,
        reason: StorageHealthUnavailableReason
    )

    var id: StorageDeviceIdentity {
        switch self {
        case .target(_, let target, _): target.deviceID
        case .unresolved(let id, _, _): id
        }
    }

    var role: StorageHealthMemberRole {
        switch self {
        case .target(let role, _, _), .unresolved(_, let role, _): role
        }
    }

}

nonisolated struct StorageHealthResolvedTopology: Hashable, Sendable {
    let kind: StorageTopologyKind
    let name: String?
    let findings: [StorageHealthFinding]
    let members: [StorageHealthResolvedMember]

    var coverage: StorageHealthCoverage {
        members.contains {
            if case .unresolved = $0 { return true }
            return false
        } ? .partial : .complete
    }
}
