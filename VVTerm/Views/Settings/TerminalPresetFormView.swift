//
//  TerminalPresetFormView.swift
//  aizen
//
//  Created by Uladzislau Yakauleu on 10.12.25.
//

import SwiftUI

struct TerminalPresetFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var command: String
    @State private var selectedIcon: String
    @State private var showingIconPicker = false

    let existingPreset: TerminalPreset?
    let onSave: (TerminalPreset) -> Void
    let onCancel: () -> Void

    init(
        existingPreset: TerminalPreset? = nil,
        onSave: @escaping (TerminalPreset) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existingPreset = existingPreset
        self.onSave = onSave
        self.onCancel = onCancel

        if let preset = existingPreset {
            _name = State(initialValue: preset.name)
            _command = State(initialValue: preset.command)
            _selectedIcon = State(initialValue: preset.icon)
        } else {
            _name = State(initialValue: "")
            _command = State(initialValue: "")
            _selectedIcon = State(initialValue: "terminal")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(existingPreset == nil ? String(localized: "Add Terminal Preset") : String(localized: "Edit Preset"))
                    .font(.headline)
                Spacer()
            }
            .padding()
            #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
            #endif

            Divider()

            // Form
            Form {
                Section("Basic Information") {
                    TextField("Name", text: $name)
                        .help(Text("Display name for the preset (e.g., Claude, Helix, Vim)"))

                    TextField("Command", text: $command, axis: .vertical)
                        .lineLimit(2...4)
                        .help(Text("Command to run when preset is selected (e.g., claude, hx, nvim)"))
                }

                Section("Icon") {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)

                        Text(selectedIcon)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button("Choose Symbol...") {
                            showingIconPicker = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            // Footer
            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(existingPreset == nil ? String(localized: "Add") : String(localized: "Save")) {
                    savePreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
            #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
            #endif
        }
        .frame(width: 450, height: 360)
        .sheet(isPresented: $showingIconPicker) {
            SFSymbolPickerView(selectedSymbol: $selectedIcon, isPresented: $showingIconPicker)
        }
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        return !trimmedName.isEmpty && !trimmedCommand.isEmpty
    }

    private func savePreset() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)

        if let existing = existingPreset {
            var updated = existing
            updated.name = trimmedName
            updated.command = trimmedCommand
            updated.icon = selectedIcon
            TerminalPresetManager.shared.updatePreset(updated)
            onSave(updated)
        } else {
            TerminalPresetManager.shared.addPreset(
                name: trimmedName,
                command: trimmedCommand,
                icon: selectedIcon
            )
            let newPreset = TerminalPreset(
                name: trimmedName,
                command: trimmedCommand,
                icon: selectedIcon
            )
            onSave(newPreset)
        }
        dismiss()
    }
}
