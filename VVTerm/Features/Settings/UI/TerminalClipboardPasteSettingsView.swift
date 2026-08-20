import SwiftUI

struct TerminalClipboardPasteSettingsView: View {
    @AppStorage("terminalCopyTrimTrailingWhitespace") private var copyTrimTrailingWhitespace = true
    @AppStorage("terminalCopyCollapseBlankLines") private var copyCollapseBlankLines = false
    @AppStorage("terminalCopyStripShellPrompts") private var copyStripShellPrompts = false
    @AppStorage("terminalCopyFlattenCommands") private var copyFlattenCommands = false
    @AppStorage("terminalCopyRemoveBoxDrawing") private var copyRemoveBoxDrawing = false
    @AppStorage("terminalCopyStripAnsiCodes") private var copyStripAnsiCodes = true
    @AppStorage("terminalImagePasteBehavior") private var imagePasteBehaviorRaw = ImagePasteBehavior.askOnce.rawValue
    @AppStorage(TerminalRemoteClipboardReadPolicy.userDefaultsKey)
    private var remoteClipboardReadPolicyRaw = TerminalRemoteClipboardReadPolicy.defaultValue.rawValue

    private var imagePasteBehavior: ImagePasteBehavior {
        ImagePasteBehavior(rawValue: imagePasteBehaviorRaw) ?? .askOnce
    }

    private var imagePasteBehaviorBinding: Binding<ImagePasteBehavior> {
        Binding(
            get: { imagePasteBehavior },
            set: { imagePasteBehaviorRaw = $0.rawValue }
        )
    }

    private var remoteClipboardReadPolicy: TerminalRemoteClipboardReadPolicy {
        TerminalRemoteClipboardReadPolicy(rawValue: remoteClipboardReadPolicyRaw) ?? .defaultValue
    }

    private var remoteClipboardReadPolicyBinding: Binding<TerminalRemoteClipboardReadPolicy> {
        Binding(
            get: { remoteClipboardReadPolicy },
            set: { remoteClipboardReadPolicyRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Trim trailing whitespace", isOn: $copyTrimTrailingWhitespace)
                Toggle("Collapse multiple blank lines", isOn: $copyCollapseBlankLines)
                Toggle("Strip shell prompts ($ #)", isOn: $copyStripShellPrompts)
                Toggle("Flatten multi-line commands", isOn: $copyFlattenCommands)
                Toggle("Remove box-drawing characters", isOn: $copyRemoveBoxDrawing)
                Toggle("Strip ANSI escape codes", isOn: $copyStripAnsiCodes)
            } header: {
                Text("Copy Text Processing")
            } footer: {
                Text("Transformations applied when copying text from terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Behavior", selection: imagePasteBehaviorBinding) {
                    Text(ImagePasteBehavior.automatic.settingsTitle).tag(ImagePasteBehavior.automatic)
                    Text(ImagePasteBehavior.askOnce.settingsTitle).tag(ImagePasteBehavior.askOnce)
                    Text(ImagePasteBehavior.disabled.settingsTitle).tag(ImagePasteBehavior.disabled)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Image Paste")
            } footer: {
                Text(imagePasteFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Remote Clipboard Reads", selection: remoteClipboardReadPolicyBinding) {
                    ForEach(TerminalRemoteClipboardReadPolicy.allCases) { policy in
                        Text(policy.settingsTitle).tag(policy)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Remote Clipboard")
            } footer: {
                Text(remoteClipboardReadPolicy.settingsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.clipboardAndPaste")
    }

    private var imagePasteFooter: String {
        switch imagePasteBehavior {
        case .disabled:
            String(localized: "Image paste is turned off.")
        case .askOnce:
            String(localized: "You’ll be asked before the image is uploaded.")
        case .automatic:
            String(localized: "Images upload right away without showing the confirmation sheet.")
        }
    }
}
