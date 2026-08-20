extension SSHSession {
    enum ShellStartupStage: Sendable {
        case channelOpenRetry
        case ptyRequest
        case shellRequest
    }
}
