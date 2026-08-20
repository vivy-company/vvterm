//
//  GhosttyRenderingSetup.swift
//  VVTerm
//
//  Shared Ghostty rendering setup.
//

import Foundation
import OSLog

/// Manages Metal rendering setup and configuration for Ghostty terminal.
@MainActor
class GhosttyRenderingSetup {
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "GhosttyRendering"
    )

    /// Snap the desired pixel size down to the nearest full terminal cell to avoid partial-cell artifacts.
    /// Snap size to whole pixels (scaledSize is already in pixel units).
    func snapSizeToCell(surface: ghostty_surface_t, scaledSize: CGSize) -> CGSize {
        CGSize(width: floor(scaledSize.width), height: floor(scaledSize.height))
    }
}
