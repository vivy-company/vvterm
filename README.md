# VVTerm

[![macOS](https://img.shields.io/badge/macOS-13.0+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![iOS](https://img.shields.io/badge/iOS-16.0+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![Swift](https://img.shields.io/badge/Swift-5.0+-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/License-GPL%203.0-blue?style=flat-square)](LICENSE)

Your servers. Everywhere.

![VVTerm macOS](https://github.com/user-attachments/assets/e33c7fff-1f18-4658-aaa9-964bab160544)

## What is VVTerm?

VVTerm is an SSH terminal app for iOS and macOS. Connect to your servers from anywhere with iCloud sync, Keychain security, and a GPU-accelerated terminal.

## Features

### Terminal
- **GPU-accelerated** — Powered by [libghostty](https://github.com/ghostty-org/ghostty)
- **Themes** — Built-in color schemes with custom theme support
- **iOS keyboard** — Toolbar with Esc, Tab, Ctrl, arrows, function keys

### SSH
- **Auth methods** — Password, SSH key, key with passphrase
- **Keychain storage** — Credentials secured in system Keychain
- **Multiple tabs** — Connect to several servers simultaneously

### Sync
- **iCloud** — Servers and workspaces sync across all devices
- **Keychain** — Credentials stored locally, not synced

### Organization
- **Workspaces** — Group servers by project or team
- **Environments** — Tag servers as Production, Staging, Dev
- **Color coding** — Visual workspace identification

### Voice
- **Voice-to-command** — On-device speech-to-text
- **MLX Whisper/Parakeet** — Local transcription, no cloud required

## Requirements

- macOS 13.0+ (Apple Silicon)
- iOS 16.0+

### Building from Source

- Xcode 16.0+
- Swift 5.0+
- Zig (for building libghostty): `brew install zig`

```bash
git clone https://github.com/vivy-company/vvterm.git
cd vvterm

# Build vendor libraries (GhosttyKit + libssh2/OpenSSL)
./scripts/build.sh all

# Open in Xcode and build
open VVTerm.xcodeproj
```

## Installation

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/vvterm)

## Pro Tier

| Feature | Free | Pro |
|---------|------|-----|
| Workspaces | 1 | Unlimited |
| Servers | 3 | Unlimited |
| Tabs | 1 | Unlimited |
| Voice commands | - | Yes |

**Pricing:** Monthly ($6.49), Yearly ($19.99), Lifetime ($29.99)

## Architecture

```
VVTerm/
├── Models/                 # Server, Workspace, Environment
├── Managers/
│   ├── ServerManager       # Server/Workspace CRUD + sync
│   └── ConnectionSession   # Tab/connection lifecycle
├── Services/
│   ├── SSH/                # libssh2 wrapper
│   ├── CloudKit/           # iCloud sync
│   ├── Keychain/           # Credential storage
│   ├── Store/              # StoreKit 2 (Pro tier)
│   └── Audio/              # Voice-to-command
├── Views/
│   ├── Sidebar/            # Server list, workspaces
│   ├── Terminal/           # Terminal container
│   ├── Tabs/               # Connection tabs
│   └── Settings/           # All settings panels
└── GhosttyTerminal/        # libghostty wrapper
```

**Patterns:**
- MVVM with `@Observable`
- Actor model for concurrency
- CloudKit for persistence
- SwiftUI + async/await

## Dependencies

- [libghostty](https://github.com/ghostty-org/ghostty) — Terminal emulator
- [libssh2](https://github.com/libssh2/libssh2) — SSH protocol
- [OpenSSL](https://github.com/openssl/openssl) — Cryptography

## Third-Party Notices

See `THIRD_PARTY_NOTICES.md`.

## License

GNU General Public License v3.0

Copyright © 2026 Vivy Technologies Co., Limited
