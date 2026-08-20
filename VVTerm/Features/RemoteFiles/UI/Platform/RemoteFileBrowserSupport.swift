import SwiftUI
import UniformTypeIdentifiers

struct RemoteFileDownloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        self.sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: .immediate)
    }
}

struct RemoteFileShareItem: Identifiable {
    let id: UUID
    let sourceURL: URL
    let title: String
}
