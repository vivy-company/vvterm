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

Teleport identities and device keys stay in the device Keychain. VVTerm does not
store Teleport passwords. Proxy, account, root cluster, node ID, and SSH login can
sync through CloudKit. Local server data uses JSON. Transport settings use one
versioned `transportConfiguration` payload, so a new transport does not need a new
CloudKit field. Unknown types or versions stay stored and cannot connect as SSH.
Released Cloudflare and Eternal Terminal fields keep their existing format.

The integration is still a draft. Older released VVTerm builds cannot read new
transport records and can reject a CloudKit server batch that includes them.
Update all devices before testing synced transport profiles. A generic payload
cannot change those older binaries. The old Teleport draft settings remain readable
so existing test entries survive; new writes use the generic field. The production
CloudKit schema needs the generic Data field before release. CloudKit stores the
payload as one Data value; the app decodes its settings. Updates apply to the whole
payload, like the current server sync.

VVTerm supports local Teleport accounts only. GitHub, OIDC, and SAML sign-in
are not available in the app. The generic TeleportKit library keeps those APIs.

To add a server, select **Teleport**, enter its domain and Teleport username,
then tap **Continue** and **Sign in**. A port is optional, for example
`teleport.example.com:8443`. VVTerm adds HTTPS when the scheme is absent.
HTTP, user information, paths, query strings, and fragments are rejected.
After sign-in, choose the server and SSH login from the selectors. The app fills
the cluster and node ID. The list shows local access expiry with a distinct
Teleport icon. Expiry comes from local certificates and is not stored in CloudKit.

First sign-in opens the system browser for approval with an existing Teleport
passkey or security key. The library then registers a device key. Teleport can
ask for a second browser approval for device management. The temporary setup
certificate lasts one minute and stays in memory. Only the normal identity from
the final native sign-in is stored. Setup needs trusted HTTPS, server support for
headless and passwordless login, and working Face ID or Touch ID. TOTP alone
cannot approve this browser setup.

Setup and the first certificate request can each ask for biometric approval.
Later sign-ins use Face ID or Touch ID to obtain fresh SSH/TLS certificates.
Starting or retrying a connection with missing or expired access starts Face ID
or the browser directly. There is no app sign-in sheet. A failure offers Retry
and Cancel; Cancel stops the connection. The app rechecks the saved entry,
account, cluster, SSH login, and expiry before connecting. Server edits or deletion
cancel the attempt; connection-history updates do not. Existing sessions keep
running. Automatic reconnect does not wait for interactive sign-in.

The device-bound P-256 authentication key is separate from the SSH/TLS private
key. It stays under the app's identity Keychain service plus `.secure-enclave`,
in its default signing group. There is no Associated Domains requirement or
native access to saved Apple passkeys. The browser cannot use this app-owned key.
Hardware SSH-key and Device Trust policies remain unsupported.

The server's **Security** settings have a deliberate local-key removal action.
Local removal does not remove Teleport's registered device or revoke certificates.
Remove a stale entry in Teleport before setup again. Old MFA-only app keys need
this reset before passwordless use. Device replacement or biometric enrollment
changes can also require recovery. Keep a working browser passkey or security key.
Sign-out clears this device's issued access and keeps the device key.

The separate **Require Face ID or Touch ID to open this server** setting protects
one saved entry. It does not lock the shared account identity; another entry for
the same account can use its valid certificates. Local unlock and a new Teleport
signature can require separate biometric prompts.

Old Teleport password items are deleted by their exact Keychain key. Ordinary
SSH credentials stay intact. Cloud cleanup waits while sync is disabled; enabling
sync removes those old cloud items. No password value is read or copied.

Tests cover local-account policy, native-first sign-in, missing-key setup,
cancellation, certificate binding, storage cleanup, and UI retention. UI fixtures
use memory authentication and no real browser or device key. Connection fixtures
exercise automatic completion and Retry/Cancel through the same window host.
Real-server software-key tests are separate from browser and Apple hardware checks.
Secure Enclave, biometric prompts, signed Keychain behavior, full browser setup,
and app SSH/files still need real-device evidence. See TeleportKit's validation
notes for the exact checks.

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow
- [SECURITY.md](SECURITY.md) for vulnerability reports
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices
- [CLA.md](CLA.md) for the contributor license agreement

## License

Source code in this repository is available under the [GNU General Public License v3.0](LICENSE). Official App Store binaries use the [VVTerm App Store EULA](LICENSE-APPSTORE.md).

Copyright © 2026 Vivy Technologies Co., Limited
