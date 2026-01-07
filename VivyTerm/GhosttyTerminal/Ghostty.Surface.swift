import Foundation

extension Ghostty {
    /// Represents a single surface within Ghostty.
    ///
    /// Wraps a `ghostty_surface_t`
    final class Surface: Sendable {
        private let surface: ghostty_surface_t
        private struct Handle: @unchecked Sendable {
            let value: ghostty_surface_t
        }

        /// Read the underlying C value for this surface. This is unsafe because the value will be
        /// freed when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t {
            surface
        }

        /// Initialize from the C structure.
        init(cSurface: ghostty_surface_t) {
            self.surface = cSurface
        }

        deinit {
            // deinit is not guaranteed to happen on the main actor and our API
            // calls into libghostty must happen there so we capture the surface
            // value so we don't capture `self` and then we detach it in a task.
            // We can't wait for the task to succeed so this will happen sometime
            // but that's okay.
            let handle = Handle(value: surface)
            Task.detached { @MainActor in
                ghostty_surface_free(handle.value)
            }
        }

        /// Send text to the terminal as if it was typed. This doesn't send the key events so keyboard
        /// shortcuts and other encodings do not take effect.
        @MainActor
        func sendText(_ text: String) {
            let len = text.utf8CString.count
            if (len == 0) { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        @MainActor
        func sendKeyEvent(_ event: Input.KeyEvent) {
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        @MainActor
        var mouseCaptured: Bool {
            ghostty_surface_mouse_captured(surface)
        }

        /// Whether closing this terminal requires user confirmation.
        ///
        /// Returns true if the terminal is busy (command running, cursor not at prompt).
        /// Uses Ghostty's internal prompt detection to avoid confirming idle shells.
        @MainActor
        var needsConfirmQuit: Bool {
            ghostty_surface_needs_confirm_quit(surface)
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        @MainActor
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods)
        }

        /// Send a mouse position event to the terminal.
        ///
        /// This reports the current mouse position to the terminal, which may be used
        /// for mouse tracking, hover effects, or other position-dependent features.
        /// The terminal will only receive these events if mouse reporting is enabled.
        ///
        /// - Parameter event: The mouse position event to send to the terminal
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods)
        }

        /// Send a mouse scroll event to the terminal.
        ///
        /// This sends scroll wheel input to the terminal with delta values for both
        /// horizontal and vertical scrolling, along with precision and momentum information.
        /// The terminal processes this according to its scroll handling configuration.
        ///
        /// - Parameter event: The mouse scroll event to send to the terminal
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            ghostty_surface_mouse_scroll(
                surface,
                event.x,
                event.y,
                event.mods.cScrollMods)
        }

        /// Perform a keybinding action.
        ///
        /// The action can be any valid keybind parameter. e.g. `keybind = goto_tab:4`
        /// you can perform `goto_tab:4` with this.
        ///
        /// Returns true if the action was performed. Invalid actions return false.
        @MainActor
        func perform(action: String) -> Bool {
            let len = action.utf8CString.count
            if (len == 0) { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }

        /// Terminal grid size information
        struct TerminalSize {
            let columns: UInt16
            let rows: UInt16
            let widthPx: UInt32
            let heightPx: UInt32
            let cellWidthPx: UInt32
            let cellHeightPx: UInt32
        }

        /// Get current terminal size
        @MainActor
        func terminalSize() -> TerminalSize {
            let cSize = ghostty_surface_size(surface)
            return TerminalSize(
                columns: cSize.columns,
                rows: cSize.rows,
                widthPx: cSize.width_px,
                heightPx: cSize.height_px,
                cellWidthPx: cSize.cell_width_px,
                cellHeightPx: cSize.cell_height_px
            )
        }

        // MARK: - Custom I/O API (for SSH clients)

        /// Feed data into the terminal for display.
        ///
        /// This is used for custom I/O backends like SSH clients where data comes from
        /// an external source (e.g., SSH channel) instead of a local pty.
        /// The data should be raw terminal output including escape sequences.
        ///
        /// - Parameter data: The raw terminal data to display
        @MainActor
        func feedData(_ data: Data) {
            guard !data.isEmpty else { return }
            data.withUnsafeBytes { buffer in
                if let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    ghostty_surface_feed_data(surface, ptr, buffer.count)
                }
            }
        }

        /// Feed string data into the terminal for display.
        ///
        /// Convenience method that converts a string to UTF-8 data and feeds it to the terminal.
        ///
        /// - Parameter text: The text to display in the terminal
        @MainActor
        func feedText(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            feedData(data)
        }

        /// Callback type for receiving terminal write data.
        ///
        /// This callback is invoked when the terminal wants to send data to the external source
        /// (e.g., when the user types, the data should be sent to the SSH channel).
        typealias WriteCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void

        /// Set the write callback for custom I/O backend.
        ///
        /// When set, the terminal will call this callback instead of writing to a local pty.
        /// This is used for SSH clients where keyboard input should be sent to the SSH channel.
        ///
        /// - Parameters:
        ///   - callback: The callback function to receive write data, or nil to clear
        ///   - userdata: Opaque pointer passed to the callback (e.g., reference to SSH session)
        @MainActor
        func setWriteCallback(_ callback: WriteCallback?, userdata: UnsafeMutableRawPointer?) {
            ghostty_surface_set_write_callback(surface, callback, userdata)
        }
    }
}
