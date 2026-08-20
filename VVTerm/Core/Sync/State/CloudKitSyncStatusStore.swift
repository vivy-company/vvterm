import Combine
import Foundation

@MainActor
final class CloudKitSyncStatusStore: ObservableObject {
    @Published var syncState = CloudKitSyncState()
    @Published var lastSyncDate: Date?
    @Published var accountState: CloudKitAccountState = .checking
}
