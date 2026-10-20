# VVTerm

[![macOS](https://img.shields.io/badge/macOS-13.3+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![iOS](https://img.shields.io/badge/iOS-16.1+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![Swift](https://img.shields.io/badge/Swift-6.2+-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Source License](https://img.shields.io/badge/Source-GPL%203.0-blue?style=flat-square)](LICENSE)
[![Binary License](https://img.shields.io/badge/Binary-App%20Store%20EULA-6e7681?style=flat-square)](LICENSE-APPSTORE.md)
[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub-ff69b4?style=flat-square&logo=github)](https://github.com/sponsors/vivy-company)

Your servers, always with you.

![VVTerm macOS](/web/src/preview.png)

VVTerm is an SSH terminal app for iOS and macOS. It uses Ghostty for terminal rendering, libssh2 and OpenSSL for SSH transport, CloudKit for sync, and Keychain for local credential storage.

## Installation

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/vvterm/id6757482822)

## Requirements

- Apple Silicon Mac
- Xcode with Swift 6.2 or later (required by the pinned package graph)
- macOS 13.3 or later
- iOS 16.1 or later
- Zig and CMake

Install the command-line build tools with Homebrew:

```sh
brew install zig cmake
```

## Build From Source

```sh
git clone https://github.com/vivy-company/vvterm.git
cd vvterm
./scripts/build.sh all
open VVTerm.xcodeproj
```

The build script supports `all`, `ghostty`, `ssh`, `ssh-engine`, `verify`, `clean`, and `help`.
Use `ssh-engine` to rebuild the pinned upstream libssh2 with the verified, existing
OpenSSL archives. The `ssh` command rebuilds both libraries.

## Project Structure

```text
VVTerm/
├── App/                 # App entry and dependency composition
├── Core/                # Shared infrastructure
├── Features/            # Product features
└── Resources/           # Assets, themes, terminfo, and localizations

VVTerm-iOS/              # iOS configuration
VVTerm-macOS/            # macOS configuration
VVTermLiveActivity/      # ActivityKit target
VVTermShared/            # Types shared with the ActivityKit target
VVTermTests/             # Unit and integration tests
VVTermUITests/           # UI tests
Vendor/                  # Native dependencies
scripts/                 # Build and validation scripts
web/                     # Website for vvterm.com
```

Feature code uses four boundaries:

- `Domain` for pure types and rules
- `Application` for state and workflows
- `Infrastructure` for persistence, transport, and adapters
- `UI` for SwiftUI, AppKit, and UIKit presentation

## Main Dependencies

- [libghostty](https://github.com/ghostty-org/ghostty) for terminal emulation and rendering
- [libssh2](https://github.com/libssh2/libssh2) for SSH transport
- [OpenSSL](https://github.com/openssl/openssl) for cryptography
- [TeleportKit](https://github.com/wiedymi/swift-teleport) for Teleport sign-in, node discovery, certificate trust, and proxy streams

Xcode resolves the Swift package dependencies in the project.

TeleportKit uses an exact source revision in the Xcode project and
`Package.resolved`. It does not fetch reference repositories or SSH engines.
VVTerm supplies its pinned upstream libssh2 engine. The engine has no local
patches and uses upstream defaults, which disable legacy DSA, SHA-1 SSH
algorithms, and several old ciphers and encrypted key formats.

Teleport profiles store issued identities only in the device Keychain. Profile,
root-cluster, exact node ID, and OS login settings can sync through CloudKit.
Sign-out disconnects this device's sessions for the same proxy and account.
It does not revoke credentials on the server or other devices. Each profile
requires trusted HTTPS and a new local sign-in on each device.

Local accounts can use a password and TOTP, or a password with browser approval
from an existing passkey or security key. The latter button appears when the
proxy advertises WebAuthn. The server still decides whether browser MFA is
enabled. Browser MFA is separate from GitHub, OIDC, and SAML sign-in; those
buttons use the advertised SSO connector. Both paths use the system
authentication browser and device-only identity storage. Native access to saved
Apple passkeys is not part of this support.
The local browser MFA path has callback and protocol unit checks. Its pinned
Chromium fixture download did not complete. Physical keys, system browser
approval, and real provider SSO still need live checks; see TeleportKit's
validation notes.

Local accounts can also set up a device-bound Secure Enclave credential in the
profile's **Device biometric sign-in** controls. Sign in first, then use a fresh
one-time code or browser approval from an existing credential to authorize setup.
The server decides which approval is required. Later sign-in still needs the
Teleport password, plus Face ID or Touch ID. TeleportKit owns registration,
WebAuthn, key use, and certificate checks. VVTerm supplies the setup and recovery
screens, browser, prompt text, and storage settings.

The library stores this authentication key under the injected identity Keychain
service plus `.secure-enclave`, in the app's default signing access group. It is
device-only and separate from App Lock and SSH/TLS keys. The iOS Face ID usage
text covers Teleport. Existing Keychain signing settings are used; no Associated
Domains capability is needed. Biometric enrollment changes or device replacement
can make the local key unusable. Keep another sign-in method. Local removal does
not remove the server credential, sign out, or revoke issued access. Remove a
stale or failed setup entry through Teleport before setup again. Hardware SSH
key policies and Device Trust remain unsupported.

Current focused app checks passed: 25 macOS tests, 22 iOS Simulator tests, and
one iOS form/recovery UI test. They cover cancellation, exclusive credential
operations, safe recovery messages, disabled setup before sign-in, and the local
removal warning/dismissal. The library's native protocol test also passed against
Teleport 18.11.4 with an injected software key. These checks do not prove Secure
Enclave, biometric prompts, signed Keychain persistence, or app-to-server traffic.
See the library's [exact validation limits](https://github.com/wiedymi/swift-teleport/blob/670d819ce7013af4e993ca55c3a12a93d1f34b13/docs/VALIDATION.md).

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow
- [SECURITY.md](SECURITY.md) for vulnerability reports
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices
- [CLA.md](CLA.md) for the contributor license agreement

## License

Source code in this repository is available under the [GNU General Public License v3.0](LICENSE). Official App Store binaries use the [VVTerm App Store EULA](LICENSE-APPSTORE.md).

Copyright © 2026 Vivy Technologies Co., Limited
