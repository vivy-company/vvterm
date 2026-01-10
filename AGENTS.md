# VVTerm

Cross-platform (iOS/macOS) SSH terminal app with iCloud sync and Keychain credential storage.

## Target Versions

- **macOS**: 13.0+ (Ventura), arm64 only
- **iOS**: 16.0+, arm64 only
- **Xcode**: 16.0+

## Architecture

```
VivyTerm/
├── Models/
│   ├── Server.swift              # Server entity (CloudKit synced)
│   ├── Workspace.swift           # Workspace grouping
│   └── ServerEnvironment.swift   # Prod/Staging/Dev environments
├── Managers/
│   ├── ServerManager.swift       # Server/Workspace CRUD + sync
│   └── ConnectionSessionManager.swift  # Tab/connection lifecycle
├── Services/
│   ├── SSH/SSHClient.swift       # libssh2 wrapper
│   ├── CloudKit/CloudKitManager.swift  # iCloud sync
│   ├── Keychain/KeychainManager.swift  # Credential storage
│   ├── Store/StoreManager.swift  # StoreKit 2 (Pro tier)
│   └── Audio/                    # Voice-to-command (MLX Whisper/Parakeet)
├── Views/
│   ├── Sidebar/ServerSidebarView.swift
│   ├── Terminal/TerminalContainerView.swift
│   ├── Tabs/ConnectionTabsView.swift
│   ├── Settings/SettingsView.swift
│   └── Store/ProUpgradeSheet.swift
└── GhosttyTerminal/              # libghostty terminal emulation
```

## Key Components

### Terminal
- Uses **libghostty** (Ghostty terminal emulator) via xcframework
- Metal GPU rendering (arm64 only)
- iOS keyboard toolbar with special keys (Esc, Tab, Ctrl, arrows)

### SSH
- **libssh2** + **OpenSSL** for SSH connections
- Auth methods: Password, SSH Key, Key+Passphrase
- Credentials stored in Keychain

### Data Sync
- **CloudKit** for server/workspace sync across devices
- Container: `iCloud.app.vivy.VivyTerm`
- Local fallback via UserDefaults

### Pro Tier (StoreKit 2)
- Free: 1 workspace, 3 servers, 1 tab
- Pro: Unlimited everything
- Products: Monthly ($6.49), Yearly ($19.99), Lifetime ($29.99)

## Build Dependencies

### libghostty
Pre-built xcframework at `Vendor/libghostty/GhosttyKit.xcframework`

### libssh2 + OpenSSL
Build with: `./scripts/build-libssh2.sh [macos|ios|simulator|all]`
Output: `Vendor/libssh2/{macos,ios,ios-simulator}/`

## Data Models

### Server
```swift
struct Server: Identifiable, Codable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var keychainCredentialId: String
}
```

### Workspace
```swift
struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorHex: String
    var environments: [ServerEnvironment]
    var order: Int
}
```

### ConnectionSession (local only, not synced)
```swift
struct ConnectionSession: Identifiable {
    let id: UUID
    let serverId: UUID
    var title: String
    var connectionState: ConnectionState
}
```

## UI Patterns

### macOS Layout
- NavigationSplitView with sidebar (workspaces/servers) and detail (terminal)
- Toolbar tabs for multiple connections
- `.windowToolbarStyle(.unified)`

### iOS Layout
- NavigationStack with server list
- Full-screen terminal with keyboard toolbar
- Sheet-based forms

### Liquid Glass (iOS 26+ / macOS 26+)
```swift
// Use adaptive helpers for backwards compatibility
.adaptiveGlass()           // Falls back to .ultraThinMaterial
.adaptiveGlassTint(.green) // For semantic tinting
```

## Important Notes

1. **Never apply glass to terminal content** - only navigation/toolbars
2. **Deduplicate by ID** when syncing from CloudKit
3. **Pro limits enforced in**: `ServerManager.canAddServer`, `canAddWorkspace`, `ConnectionSessionManager.canOpenNewTab`
4. **Keychain credentials** are NOT synced - only server metadata syncs via CloudKit
5. **iOS keyboard toolbar** provides Esc, Tab, Ctrl, arrows, function keys
6. **Voice-to-command** uses MLX Whisper/Parakeet on-device or Apple Speech fallback
