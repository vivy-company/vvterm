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

Teleport profiles store issued identities only in the device Keychain. Local
account passwords use the same server credential store as SSH. Save the server
to keep the password; Cancel keeps the previous saved value. The existing iCloud
sync setting controls password sync. The password and its account binding share
one Keychain item, so a partial sync cannot mix accounts. Each password is bound
to that server's Teleport proxy and account. Changing either clears the draft password.
Passwords are not shared automatically between entries. Duplicate Server copies
the password after the normal source-server approval. Proxy,
account, root cluster, exact node ID, and OS login settings can sync through CloudKit.
Local server data uses JSON. New transport settings share one versioned
`transportConfiguration` payload in local data and CloudKit. Each transport keeps
its own typed settings; adding another transport does not require another CloudKit
field. Unknown types or versions stay stored and cannot connect as ordinary SSH.
Released Cloudflare and Eternal Terminal fields retain their existing format.
Sign-out disconnects this device's sessions for the same proxy and account.
It does not revoke credentials on the server or other devices. Each profile
requires trusted HTTPS and a new local sign-in on each device.

The integration is still a draft. Older released VVTerm builds cannot read new
transport records and can reject a CloudKit server batch that includes them.
Update all devices before testing synced transport profiles. A generic payload
cannot change those older binaries. The old Teleport draft settings remain readable
so existing test entries survive; new writes use the generic field. The production
CloudKit schema needs the generic Data field before release. CloudKit stores the
payload as one Data value; the app decodes its settings. Updates apply to the whole
payload, like the current server sync.

Local accounts can use a password and TOTP, or a password with browser approval
from an existing passkey or security key. The latter button appears when the
proxy advertises WebAuthn. The server still decides whether browser MFA is
enabled. Browser MFA is separate from GitHub, OIDC, and SAML sign-in; those
buttons use the advertised SSO connector. Both paths use the system
authentication browser and device-only identity storage. Native access to saved
Apple passkeys is not part of this support.
Browser approval needs a separate passkey or security key registered in Teleport.
Use the same account in the browser and VVTerm. Start a new sign-in attempt if
the browser page is old or the app attempt was cancelled.
The local browser MFA path has callback and protocol unit checks. Its pinned
Chromium fixture download did not complete. Physical keys, system browser
approval, and real provider SSO still need live checks; see TeleportKit's
validation notes.

To add a server, select **Teleport**, enter its domain and your Teleport username,
then tap **Continue**. A port is optional, for example `teleport.example.com:8443`.
VVTerm adds HTTPS when no scheme is entered; explicit HTTPS also works. HTTP,
user information, non-root paths, query strings, and fragments are rejected.
Choose a sign-in method and sign in. Only that method's
fields appear. Then choose the server and SSH login. A single available choice
fills an empty field; existing choices stay. Manual IDs and an optional SSO
connector are under **Advanced**. The server list shows local access expiry and a
distinct Teleport icon. Access status refreshes on display, in the foreground, and
once per minute while visible. Expiry is never stored in CloudKit.

Local accounts can also set up a device-bound Secure Enclave credential in the
profile's **Security → Teleport verification** settings. Select **This device**
under **Verify with** to use it. The saved password is filled like an SSH password.
Face ID or Touch ID replaces code entry; this is MFA, not passwordless login.
The separate **Require Face ID or Touch ID to open this server** setting protects
local app access. It does not approve Teleport MFA; both can need a prompt.
That lock applies to one saved entry. It does not lock the shared account identity;
another entry can use the same account's valid issued access.
Setup stays inside the server form. Sign in first, then use a fresh
one-time code or browser approval from an existing credential to authorize setup.
Wait for a new authenticator code after login; Teleport rejects a reused code.
Setup first checks server policy. If a code is required, enter its 6–8 digits
before you can continue. Servers that require no existing approval need no code.
The server decides which approval is required. Later sign-in still needs the
Teleport password, plus Face ID or Touch ID. TeleportKit owns registration,
WebAuthn, key use, and certificate checks. VVTerm supplies the setup and recovery
screens, browser, prompt text, and storage settings.
Sign-out clears issued access and keeps the saved password. To forget it, open
sign-in, clear the password field, and save the server. Removing the
local device key keeps the password. Deleting the server removes its password
through the normal credential store; shared issued access is kept for other entries.

The library stores this authentication key under the injected identity Keychain
service plus `.secure-enclave`, in the app's default signing access group. It is
device-only and separate from App Lock and SSH/TLS keys. The iOS Face ID usage
text covers Teleport. Existing Keychain signing settings are used; no Associated
Domains capability is needed. Biometric enrollment changes or device replacement
can make the local key unusable. Keep another sign-in method. Local removal does
not remove the server credential, sign out, or revoke issued access. Remove a
stale or failed setup entry through Teleport before setup again. Hardware SSH
key policies and Device Trust remain unsupported.
This app-owned credential is not saved as an Apple passkey. Use the device
verification choice for it; the browser cannot use this private key.

Focused app tests cover transport settings, local and CloudKit storage, node
selection, cancellation, setup, and recovery. Password tests use memory storage
to check account binding, partial sync, deletion, and failed-save recovery.
UI fixtures do not create keys or
contact a server. Software-key protocol checks passed against Teleport 18.11.4.
Physical-device checks are still required for Secure Enclave, biometric prompts,
signed Keychain behavior, actual iCloud password sync, browser MFA, and real-provider SSO.

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow
- [SECURITY.md](SECURITY.md) for vulnerability reports
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices
- [CLA.md](CLA.md) for the contributor license agreement

## License

Source code in this repository is available under the [GNU General Public License v3.0](LICENSE). Official App Store binaries use the [VVTerm App Store EULA](LICENSE-APPSTORE.md).

Copyright © 2026 Vivy Technologies Co., Limited
