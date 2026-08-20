import SwiftUI

struct ServerLocalStorageNotice: View {
    let serverManager: ServerManager
    @ObservedObject var stateStore: ServerStateStore
    @State private var isShowingCloudRecovery = false
    @State private var recoveryFailure: String?

    init(serverManager: ServerManager) {
        self.serverManager = serverManager
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
    }

    var body: some View {
        if stateStore.ambiguousCloudRecovery != nil || !stateStore.localStorageIssues.isEmpty {
            Group {
                if stateStore.ambiguousCloudRecovery != nil {
                    NoticeBannerView(
                        item: NoticeItem(
                            id: "server-cloud-recovery",
                            lane: .topBanner,
                            level: .warning,
                            leading: .icon("icloud.slash"),
                            title: String(localized: "Cloud data needs review"),
                            message: String(localized: "Your local data is safe. Choose how to continue."),
                            action: NoticeAction(
                                id: "review-cloud-recovery",
                                title: String(localized: "Review"),
                                handler: { isShowingCloudRecovery = true }
                            )
                        )
                    )
                } else {
                    NoticeBannerView(
                        item: NoticeItem(
                            id: "server-local-storage-unreadable",
                            lane: .topBanner,
                            level: .warning,
                            leading: .icon("externaldrive.badge.exclamationmark"),
                            title: String(localized: "Local data could not be read"),
                            message: String(localized: "VVTerm preserved a backup before using replacement data."),
                            dismissAction: stateStore.dismissLocalStorageIssues
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .confirmationDialog(
                String(localized: "Cloud data needs review"),
                isPresented: $isShowingCloudRecovery,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Keep Local Data")) {
                    resolve(.keepLocal)
                }
                Button(String(localized: "Upload Local Data")) {
                    resolve(.uploadLocal)
                }
                Button(String(localized: "Replace with Cloud Data"), role: .destructive) {
                    resolve(.replaceWithCloud)
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(
                    String(
                        localized: "VVTerm could not confirm that missing local items were intentionally removed."
                    )
                )
            }
            .alert(
                String(localized: "Recovery Failed"),
                isPresented: Binding(
                    get: { recoveryFailure != nil },
                    set: { if !$0 { recoveryFailure = nil } }
                )
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(recoveryFailure ?? "")
            }
        }
    }

    private func resolve(_ choice: AmbiguousCloudRecoveryChoice) {
        Task {
            do {
                try await serverManager.resolveAmbiguousCloudRecovery(choice)
            } catch {
                recoveryFailure = error.localizedDescription
            }
        }
    }
}
