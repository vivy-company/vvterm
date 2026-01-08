import SwiftUI

#if os(iOS)
// MARK: - Terminal Keyboard Toolbar

struct TerminalKeyboardToolbar: View {
    let onKey: (TerminalKey) -> Void

    @State private var isCtrlActive = false
    @State private var isAltActive = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Modifier Keys
                ModifierKeyButton(
                    label: "Ctrl",
                    isActive: $isCtrlActive
                )

                ModifierKeyButton(
                    label: "Alt",
                    isActive: $isAltActive
                )

                Divider()
                    .frame(height: 24)

                // Common Keys
                KeyButton(label: "Esc", icon: "escape") {
                    sendKey(.escape)
                }

                KeyButton(label: "Tab", icon: "arrow.right.to.line") {
                    sendKey(.tab)
                }

                Divider()
                    .frame(height: 24)

                // Arrow Keys
                KeyButton(label: nil, icon: "arrow.up") {
                    sendKey(.arrowUp)
                }

                KeyButton(label: nil, icon: "arrow.down") {
                    sendKey(.arrowDown)
                }

                KeyButton(label: nil, icon: "arrow.left") {
                    sendKey(.arrowLeft)
                }

                KeyButton(label: nil, icon: "arrow.right") {
                    sendKey(.arrowRight)
                }

                Divider()
                    .frame(height: 24)

                // Function Keys
                KeyButton(label: "F1", icon: nil) {
                    sendKey(.f1)
                }

                KeyButton(label: "F2", icon: nil) {
                    sendKey(.f2)
                }

                KeyButton(label: "F3", icon: nil) {
                    sendKey(.f3)
                }

                KeyButton(label: "F4", icon: nil) {
                    sendKey(.f4)
                }

                Divider()
                    .frame(height: 24)

                // Control Sequences
                KeyButton(label: "^C", icon: nil) {
                    sendKey(.ctrlC)
                }

                KeyButton(label: "^D", icon: nil) {
                    sendKey(.ctrlD)
                }

                KeyButton(label: "^Z", icon: nil) {
                    sendKey(.ctrlZ)
                }

                KeyButton(label: "^L", icon: nil) {
                    sendKey(.ctrlL)
                }

                Divider()
                    .frame(height: 24)

                // Special Keys
                KeyButton(label: "Home", icon: nil) {
                    sendKey(.home)
                }

                KeyButton(label: "End", icon: nil) {
                    sendKey(.end)
                }

                KeyButton(label: "PgUp", icon: nil) {
                    sendKey(.pageUp)
                }

                KeyButton(label: "PgDn", icon: nil) {
                    sendKey(.pageDown)
                }

                KeyButton(label: "Del", icon: nil) {
                    sendKey(.delete)
                }

                KeyButton(label: "Ins", icon: nil) {
                    sendKey(.insert)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .adaptiveBarBackground()
    }

    private func sendKey(_ key: TerminalKey) {
        var modifiedKey = key
        if isCtrlActive {
            modifiedKey = key.withCtrl()
            isCtrlActive = false
        }
        if isAltActive {
            modifiedKey = key.withAlt()
            isAltActive = false
        }
        onKey(modifiedKey)
    }
}

// MARK: - Key Button

private struct KeyButton: View {
    let label: String?
    let icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = icon {
                    if let label = label {
                        Label(label, systemImage: icon)
                            .labelStyle(.iconOnly)
                    } else {
                        Image(systemName: icon)
                    }
                } else if let label = label {
                    Text(label)
                        .font(.system(.footnote, design: .monospaced))
                        .fontWeight(.medium)
                }
            }
            .frame(minWidth: 36, minHeight: 32)
            .contentShape(Rectangle())
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Modifier Key Button

private struct ModifierKeyButton: View {
    let label: String
    @Binding var isActive: Bool

    var body: some View {
        Button {
            isActive.toggle()
        } label: {
            Text(label)
                .font(.system(.footnote, design: .monospaced))
                .fontWeight(.medium)
                .frame(minWidth: 40, minHeight: 32)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                }
                .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Terminal Key

indirect enum TerminalKey {
    // Basic Keys
    case escape
    case tab
    case enter
    case backspace
    case delete
    case insert

    // Arrow Keys
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    // Navigation
    case home
    case end
    case pageUp
    case pageDown

    // Function Keys
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    // Control Sequences
    case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlA, ctrlE, ctrlK, ctrlU

    // Modified Keys
    case ctrl(TerminalKey)
    case alt(TerminalKey)
    case ctrlAlt(TerminalKey)

    func withCtrl() -> TerminalKey {
        switch self {
        case .ctrl, .alt, .ctrlAlt:
            return self
        default:
            return .ctrl(self)
        }
    }

    func withAlt() -> TerminalKey {
        switch self {
        case .ctrl(let key):
            return .ctrlAlt(key)
        case .alt, .ctrlAlt:
            return self
        default:
            return .alt(self)
        }
    }

    // ANSI escape sequences
    var ansiSequence: Data {
        switch self {
        case .escape:
            return Data([0x1B])
        case .tab:
            return Data([0x09])
        case .enter:
            return Data([0x0D])
        case .backspace:
            return Data([0x7F])
        case .delete:
            return "\u{1B}[3~".data(using: .utf8)!
        case .insert:
            return "\u{1B}[2~".data(using: .utf8)!

        // Arrow Keys (Application mode)
        case .arrowUp:
            return "\u{1B}[A".data(using: .utf8)!
        case .arrowDown:
            return "\u{1B}[B".data(using: .utf8)!
        case .arrowRight:
            return "\u{1B}[C".data(using: .utf8)!
        case .arrowLeft:
            return "\u{1B}[D".data(using: .utf8)!

        // Navigation
        case .home:
            return "\u{1B}[H".data(using: .utf8)!
        case .end:
            return "\u{1B}[F".data(using: .utf8)!
        case .pageUp:
            return "\u{1B}[5~".data(using: .utf8)!
        case .pageDown:
            return "\u{1B}[6~".data(using: .utf8)!

        // Function Keys
        case .f1:
            return "\u{1B}OP".data(using: .utf8)!
        case .f2:
            return "\u{1B}OQ".data(using: .utf8)!
        case .f3:
            return "\u{1B}OR".data(using: .utf8)!
        case .f4:
            return "\u{1B}OS".data(using: .utf8)!
        case .f5:
            return "\u{1B}[15~".data(using: .utf8)!
        case .f6:
            return "\u{1B}[17~".data(using: .utf8)!
        case .f7:
            return "\u{1B}[18~".data(using: .utf8)!
        case .f8:
            return "\u{1B}[19~".data(using: .utf8)!
        case .f9:
            return "\u{1B}[20~".data(using: .utf8)!
        case .f10:
            return "\u{1B}[21~".data(using: .utf8)!
        case .f11:
            return "\u{1B}[23~".data(using: .utf8)!
        case .f12:
            return "\u{1B}[24~".data(using: .utf8)!

        // Control Sequences
        case .ctrlC:
            return Data([0x03])
        case .ctrlD:
            return Data([0x04])
        case .ctrlZ:
            return Data([0x1A])
        case .ctrlL:
            return Data([0x0C])
        case .ctrlA:
            return Data([0x01])
        case .ctrlE:
            return Data([0x05])
        case .ctrlK:
            return Data([0x0B])
        case .ctrlU:
            return Data([0x15])

        // Modified Keys
        case .ctrl(let key):
            // Add Ctrl modifier to ANSI sequence
            return key.ansiSequence
        case .alt(let key):
            // Alt prefix with ESC
            var data = Data([0x1B])
            data.append(key.ansiSequence)
            return data
        case .ctrlAlt(let key):
            var data = Data([0x1B])
            data.append(key.ansiSequence)
            return data
        }
    }
}

// MARK: - Compact Toolbar (For iPhone)

struct CompactTerminalToolbar: View {
    let onKey: (TerminalKey) -> Void

    @State private var showExtendedKeys = false

    var body: some View {
        HStack(spacing: 4) {
            // Quick access keys
            Button {
                onKey(.escape)
            } label: {
                Text("Esc")
                    .font(.system(.caption2, design: .monospaced))
                    .frame(minWidth: 32, minHeight: 28)
                    .contentShape(Rectangle())
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)

            Button {
                onKey(.tab)
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.caption2)
                    .frame(minWidth: 32, minHeight: 28)
                    .contentShape(Rectangle())
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)

            Button {
                onKey(.ctrlC)
            } label: {
                Text("^C")
                    .font(.system(.caption2, design: .monospaced))
                    .frame(minWidth: 32, minHeight: 28)
                    .contentShape(Rectangle())
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)

            Spacer()

            // Arrow keys
            HStack(spacing: 2) {
                Button { onKey(.arrowLeft) } label: {
                    Image(systemName: "arrow.left")
                        .font(.caption2)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.borderless)

                VStack(spacing: 2) {
                    Button { onKey(.arrowUp) } label: {
                        Image(systemName: "arrow.up")
                            .font(.caption2)
                            .frame(minWidth: 28, minHeight: 13)
                            .contentShape(Rectangle())
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.borderless)

                    Button { onKey(.arrowDown) } label: {
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                            .frame(minWidth: 28, minHeight: 13)
                            .contentShape(Rectangle())
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.borderless)
                }

                Button { onKey(.arrowRight) } label: {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.borderless)
            }

            // More button
            Button {
                showExtendedKeys = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .frame(minWidth: 32, minHeight: 28)
                    .contentShape(Rectangle())
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showExtendedKeys) {
                ExtendedKeysPopover(onKey: onKey)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .adaptiveBarBackground()
    }
}

// MARK: - Extended Keys Popover

private struct ExtendedKeysPopover: View {
    let onKey: (TerminalKey) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            // Control Keys
            HStack(spacing: 8) {
                ForEach(["^C", "^D", "^Z", "^L"], id: \.self) { key in
                    Button {
                        switch key {
                        case "^C": onKey(.ctrlC)
                        case "^D": onKey(.ctrlD)
                        case "^Z": onKey(.ctrlZ)
                        case "^L": onKey(.ctrlL)
                        default: break
                        }
                        dismiss()
                    } label: {
                        Text(key)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Function Keys
            HStack(spacing: 8) {
                ForEach(1...4, id: \.self) { num in
                    Button {
                        switch num {
                        case 1: onKey(.f1)
                        case 2: onKey(.f2)
                        case 3: onKey(.f3)
                        case 4: onKey(.f4)
                        default: break
                        }
                        dismiss()
                    } label: {
                        Text("F\(num)")
                            .font(.system(.footnote, design: .monospaced))
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Navigation Keys
            HStack(spacing: 8) {
                ForEach(["Home", "End", "PgUp", "PgDn"], id: \.self) { key in
                    Button {
                        switch key {
                        case "Home": onKey(.home)
                        case "End": onKey(.end)
                        case "PgUp": onKey(.pageUp)
                        case "PgDn": onKey(.pageDown)
                        default: break
                        }
                        dismiss()
                    } label: {
                        Text(key)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Preview

#Preview("Full Toolbar") {
    VStack {
        Spacer()
        TerminalKeyboardToolbar { _ in }
    }
}

#Preview("Compact Toolbar") {
    VStack {
        Spacer()
        CompactTerminalToolbar { _ in }
    }
}
#endif
