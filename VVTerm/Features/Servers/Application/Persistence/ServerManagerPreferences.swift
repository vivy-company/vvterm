import Foundation

@MainActor
protocol ServerManagerPreferences: AnyObject {
    var didBootstrapDefaultWorkspace: Bool { get set }
    var hasSeenWelcome: Bool { get }
    var freePlanGeneration: FreePlanGeneration? { get set }
    var pendingBootstrapWorkspaceID: UUID? { get set }
}
