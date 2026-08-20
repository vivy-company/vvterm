import Foundation

nonisolated enum RemotePlatform: String, Sendable {
    case linux = "linux"
    case darwin = "darwin"
    case freebsd = "freebsd"
    case openbsd = "openbsd"
    case netbsd = "netbsd"
    case windows = "windows"
    case unknown = "unknown"

    static func detect(from unameOutput: String) -> RemotePlatform {
        let os = unameOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if os.contains("darwin") {
            return .darwin
        } else if os.contains("freebsd") {
            return .freebsd
        } else if os.contains("openbsd") {
            return .openbsd
        } else if os.contains("netbsd") {
            return .netbsd
        } else if os.contains("linux") {
            return .linux
        } else if os.contains("mingw") || os.contains("msys") || os.contains("cygwin") || os.contains("windows") {
            return .windows
        }

        return .linux
    }
}
