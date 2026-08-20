import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit

struct RemoteFileRow: View {
    let entry: RemoteFileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.iconName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(entry.type == .directory ? folderTint : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if entry.type == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []

        if let modifiedAt = entry.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }

        switch entry.type {
        case .directory:
            parts.append(String(localized: "Folder"))
        default:
            if let size = entry.size {
                parts.append(RemoteFileByteCountFormatter.string(from: size))
            }
        }

        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var folderTint: Color {
        Color.blue
    }
}

struct RemoteFileShareSheet: UIViewControllerRepresentable {
    let item: RemoteFileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [item.sourceURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.finish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    final class Coordinator {
        private let onComplete: () -> Void
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            onComplete()
        }
    }
}

struct RemoteFileImportPicker: UIViewControllerRepresentable {
    let onComplete: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .folder],
            asCopy: true
        )
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Result<[URL], Error>) -> Void
        private var didFinish = false

        init(onComplete: @escaping (Result<[URL], Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.success([]))
        }

        private func finish(_ result: Result<[URL], Error>) {
            guard !didFinish else { return }
            didFinish = true
            onComplete(result)
        }
    }
}
#endif
