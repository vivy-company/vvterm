//
//  GhosttyTerminalWriteCallback.swift
//  VVTerm
//
//  Thread-safe native custom I/O callback boundary.
//

import Foundation

nonisolated func ghosttyTerminalWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) {
    guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata) else { return }
    guard let bytes, length > 0 else { return }
    let data = Data(bytes: bytes, count: length)

    DispatchQueue.main.async {
        terminalView.writeCallback?(data)
    }
}
