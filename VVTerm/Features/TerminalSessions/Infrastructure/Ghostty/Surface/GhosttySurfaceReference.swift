extension Ghostty {
    /// Tracks a native surface without extending the terminal view lifetime.
    final class SurfaceReference {
        let surface: ghostty_surface_t
        weak var terminalView: GhosttyTerminalView?

        init(_ surface: ghostty_surface_t, terminalView: GhosttyTerminalView) {
            self.surface = surface
            self.terminalView = terminalView
        }
    }
}
