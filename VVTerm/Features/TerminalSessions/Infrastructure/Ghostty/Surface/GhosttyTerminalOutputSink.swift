import Foundation

extension GhosttyTerminalView: TerminalOutputSink {
    func receiveTerminalOutput(_ data: Data) {
        feedData(data)
    }
}
