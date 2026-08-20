import Foundation

nonisolated struct RemoteFileBreadcrumb: Identifiable, Hashable, Sendable {
    let title: String
    let path: String

    var id: String { path }
}

nonisolated enum RemoteFilePath {
    static func normalize(_ path: String, relativeTo currentPath: String? = nil) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return currentPath ?? "/"
        }

        let basePath: String
        if trimmed.hasPrefix("/") {
            basePath = trimmed
        } else if let currentPath {
            let separator = currentPath == "/" ? "" : "/"
            basePath = currentPath + separator + trimmed
        } else {
            basePath = "/" + trimmed
        }

        let components = basePath.split(separator: "/", omittingEmptySubsequences: false)
        var normalized: [Substring] = []

        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            default:
                normalized.append(component)
            }
        }

        return "/" + normalized.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }

        var components = normalized.split(separator: "/")
        _ = components.popLast()
        if components.isEmpty {
            return "/"
        }
        return "/" + components.joined(separator: "/")
    }

    static func appending(_ name: String, to directoryPath: String) -> String {
        let separator = directoryPath == "/" ? "" : "/"
        return normalize(directoryPath + separator + name)
    }

    static func appending(_ leaf: RemoteFileLeaf, to directoryPath: String) -> String {
        let root = normalize(directoryPath)
        let candidate = appending(leaf.value, to: root)
        precondition(isStrictDescendant(candidate, of: root))
        return candidate
    }

    static func isStrictDescendant(_ candidatePath: String, of rootPath: String) -> Bool {
        let candidate = normalize(candidatePath)
        let root = normalize(rootPath)
        guard candidate != root else { return false }
        return root == "/" ? candidate.hasPrefix("/") : candidate.hasPrefix(root + "/")
    }

    static func breadcrumbs(for path: String) -> [RemoteFileBreadcrumb] {
        let normalized = normalize(path)
        guard normalized != "/" else {
            return [RemoteFileBreadcrumb(title: "/", path: "/")]
        }

        var breadcrumbs = [RemoteFileBreadcrumb(title: "/", path: "/")]
        let components = normalized.split(separator: "/")
        var current = ""
        for component in components {
            current += "/" + component
            breadcrumbs.append(
                RemoteFileBreadcrumb(title: String(component), path: current)
            )
        }
        return breadcrumbs
    }
}

nonisolated enum RemoteFileLocalPath {
    static func descendant(
        named leaf: RemoteFileLeaf,
        in parentURL: URL,
        operationRootURL: URL,
        isDirectory: Bool
    ) throws -> URL {
        let root = canonical(operationRootURL)
        let parent = canonical(parentURL)
        guard parent == root || isStrictDescendant(parent, of: root) else {
            throw RemoteFileBrowserError.destinationEscapedRoot
        }

        let candidate = canonical(
            parent.appendingPathComponent(leaf.value, isDirectory: isDirectory)
        )
        guard isStrictDescendant(candidate, of: root) else {
            throw RemoteFileBrowserError.destinationEscapedRoot
        }
        return candidate
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
