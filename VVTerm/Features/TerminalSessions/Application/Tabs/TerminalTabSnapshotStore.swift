import Foundation

@MainActor
protocol TerminalTabSnapshotStoring: AnyObject {
    func loadSnapshotData() -> Data?
    func saveSnapshotData(_ data: Data)
    func removeSnapshotData()
}
