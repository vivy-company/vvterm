# Biometric Locks (Face ID / Touch ID) Spec

## Summary
Add two security features:
- `Per-server lock`: selected servers require biometric authentication before opening/connecting.
- `Full-app lock`: VVTerm requires biometric authentication when the app becomes active.

This spec targets:
- iOS 16+
- macOS 13.3+

## Problem
VVTerm currently protects credentials in Keychain, but opening the app or selecting a server does not require a local user-presence check. On shared devices this increases exposure risk.

## Goals (V1)
- Allow users to enable biometric lock for individual servers.
- Allow users to enable full-app lock.
- Keep per-server lock synced with CloudKit as server metadata.
- Keep full-app lock local-only (not synced).
- Handle iOS and macOS with one shared auth service.
- Minimize accidental prompt loops and support graceful cancel behavior.

## Non-Goals (V1)
- Remote or server-side auth changes.
- New account/login system.
- Policy hardening with MDM-specific controls.
- Making SSH credentials themselves biometry-bound (can be V2).

## Current Code Touchpoints
### Connection/open flows
- iOS server open path: `VVTerm/Views/iOS/iOSContentView.swift`
- iOS session open API: `VVTerm/Managers/ConnectionSessionManager.swift`
- macOS server connect UI path: `VVTerm/ContentView.swift`
- macOS tab open API: `VVTerm/Managers/TerminalTabManager.swift`

### Server metadata + sync
- Server model: `VVTerm/Models/Server.swift`
- Server CloudKit encode/decode: `VVTerm/Models/Server+CloudKit.swift`
- Server CRUD/rebuild paths: `VVTerm/Managers/ServerManager.swift`

### App lifecycle
- App root and delegates: `VVTerm/VVTermApp.swift`
- iOS background hook already exists: `applicationDidEnterBackground`

### Settings and server edit UI
- General settings: `VVTerm/Views/Settings/GeneralSettingsView.swift`
- Settings navigation: `VVTerm/Views/Settings/SettingsView.swift`
- Server edit form: `VVTerm/Views/ServerDetail/ServerFormSheet.swift`

## APIs Needed
### 1) LocalAuthentication (required)
- `LAContext`
- `canEvaluatePolicy(_:error:)`
- `evaluatePolicy(_:localizedReason:reply:)` (or async Swift form)
- `LAPolicy.deviceOwnerAuthenticationWithBiometrics`
- `LAPolicy.deviceOwnerAuthentication`
- `LABiometryType`
- `LAError` handling (`userCancel`, `systemCancel`, `appCancel`, `biometryNotAvailable`, `biometryNotEnrolled`, `biometryLockout`, `passcodeNotSet`, `authenticationFailed`)

Compatibility note:
- Do not use SwiftUI-only `LocalAuthenticationView` for V1 because VVTerm supports iOS 16, while those newer APIs are iOS 18+.

### 2) Info.plist (iOS required)
- `NSFaceIDUsageDescription`
- No equivalent Face ID usage key is required on macOS.

### 3) Security framework (optional, V2-hardening)
- `SecAccessControlCreateWithFlags`
- `kSecAttrAccessControl`
- `kSecUseAuthenticationContext`
- `SecAccessControlCreateFlags.biometryCurrentSet`

Use this only if we later decide to store a biometry-gated local secret/token in Keychain.

## Product Behavior
### Per-server lock
- New server property: `requiresBiometricUnlock: Bool` (default `false`).
- When enabled, opening/connecting that server requires successful local authentication.
- Canceling auth aborts open/connect with no state mutation.
- If auth succeeds, open flow continues as normal.

### Full-app lock
- New local setting: `fullAppLockEnabled`.
- When enabled, app shows a lock gate when app/scene becomes active.
- App content remains obscured until unlock succeeds.
- Backgrounding immediately returns app to locked state.

### Combined behavior
- If full-app lock and per-server lock are both enabled, app unlock happens first.
- Per-server lock still applies (defense in depth).
- Add short in-memory grace window (default: 30s) to avoid immediate double-prompt after full-app unlock.

## Policy Choice
Use this policy split in V1:
- Preflight and feature availability checks: `.deviceOwnerAuthenticationWithBiometrics`
- Runtime auth prompt: `.deviceOwnerAuthentication`

Rationale:
- Users primarily authenticate with Face ID / Touch ID.
- Passcode fallback remains available in lockout scenarios.
- Avoids hard-dead-end behavior after biometry lockout.

## Data Model & Persistence
### Server (synced)
Add field to `Server`:
- `requiresBiometricUnlock: Bool = false`

Update:
- `Codable` keys and init/encode in `VVTerm/Models/Server.swift`
- CloudKit record read/write in `VVTerm/Models/Server+CloudKit.swift`
- All manual `Server(...)` rebuild callsites in `VVTerm/Managers/ServerManager.swift`

### App lock settings (local)
Use `@AppStorage` (device-local):
- `security.fullAppLockEnabled` (Bool, default `false`)
- `security.lockOnBackground` (Bool, default `true`)
- `security.authGraceSeconds` (Int, default `30`)

Never persist unlocked session state.

## Architecture
Create:
- `VVTerm/Services/Security/BiometricAuthService.swift`
- `VVTerm/Managers/AppLockManager.swift`

### `BiometricAuthService`
Responsibilities:
- Build fresh `LAContext` per evaluation.
- Perform policy preflight.
- Perform authentication and map `LAError` into app-level errors.
- Surface current biometry type (`faceID`, `touchID`, `none`) for UI labels.

Notes:
- Keep strong reference to context during evaluation.
- Always hop back to `MainActor` before UI state updates.

### `AppLockManager`
Responsibilities:
- Source of truth for lock state.
- Track temporary in-memory grants:
  - app-wide unlock timestamp
  - per-server unlock timestamps
- Provide APIs:
  - `ensureAppUnlocked() async -> Bool`
  - `ensureServerUnlocked(_ server: Server) async -> Bool`
  - `lockAppNow()`
  - `canAttemptBiometric` / capability state

## UI Changes
### Server form
File: `VVTerm/Views/ServerDetail/ServerFormSheet.swift`
- Add `Security` section with toggle:
  - Label adapts by biometry type, e.g. `Require Face ID to open this server`.
- If unsupported/unavailable, disable toggle and show helper text.
- On save, persist `requiresBiometricUnlock`.

### Settings
Files:
- `VVTerm/Views/Settings/SettingsView.swift`
- `VVTerm/Views/Settings/GeneralSettingsView.swift`

Add security section in General:
- `Require Face ID to open VVTerm` toggle
- Optional `Lock when app goes to background` toggle
- Optional `Require re-auth after` (grace period picker)

Enabling full-app lock should do a confirmation auth before committing the toggle.

### App lock gate UI
Add shared lock overlay view:
- `VVTerm/Views/Security/AppLockGateView.swift`

Behavior:
- Full-window overlay in app root, above all content.
- Primary action: `Unlock`.
- Auto-attempt on appear.
- Keep sensitive content obscured while locked.

## Integration Points
### iOS
- `VVTerm/Views/iOS/iOSContentView.swift`
  - Gate `onServerSelected` with `ensureServerUnlocked`.
- `VVTerm/Managers/ConnectionSessionManager.swift`
  - Fail-safe check at start of `openConnection(to:forceNew:)`.
- `VVTerm/VVTermApp.swift`
  - Listen to `scenePhase` and lock on background/inactive transitions.

### macOS
- `VVTerm/ContentView.swift`
  - Gate connect actions before mutating connected state.
- `VVTerm/Views/Tabs/ConnectionTabsView.swift`
  - Gate `openNewTab` for protected server.
- `VVTerm/Managers/TerminalTabManager.swift`
  - Fail-safe check in `openTab(for:)` (or return nil/throw variant).
- `VVTerm/VVTermApp.swift`
  - On app active, require unlock if full-app lock enabled.

## Error Handling & UX
Map `LAError` to user-facing behavior:
- `userCancel`, `systemCancel`, `appCancel`: silent abort.
- `biometryNotEnrolled`: show action hint to enroll Face ID/Touch ID.
- `biometryNotAvailable`: show unsupported/unavailable message.
- `biometryLockout`: retry with `.deviceOwnerAuthentication` (passcode path).
- `passcodeNotSet`: disable feature and show requirement message.
- `authenticationFailed`: allow retry.

Do not log sensitive reasons or per-attempt details.

## Security Notes
- Keep unlock grants in memory only.
- Do not store raw biometric state hashes for V1.
- Do not gate terminal rendering internals; gate entry points.
- Keep SSH credentials storage unchanged in V1 (existing Keychain manager remains source of truth).

## Testing Plan
### Unit tests
Add test files:
- `VVTermTests/BiometricAuthServiceTests.swift`
- `VVTermTests/AppLockManagerTests.swift`
- Extend model serialization tests for `requiresBiometricUnlock`.

Cases:
- Server Codable backward compatibility (missing key => false).
- CloudKit encode/decode for new field.
- Grace window behavior.
- Combined full-app + per-server prompt logic.
- Cancel/error mapping.

### UI tests
- Enable full-app lock, background/foreground, verify lock gate.
- Per-server lock prompt appears only for protected servers.
- Cancel auth keeps user on server list.
- Success opens terminal normally.
- iOS first-run Face ID permission prompt path (manual + automated where possible).

## Rollout
- Add feature flag for first internal release:
  - `securityBiometricLocksEnabled`
- Ship staged:
  1. Per-server lock
  2. Full-app lock
  3. Grace tuning and UX polish

## Open Questions
- Should per-server lock be strict biometry-only (no passcode fallback), or allow passcode fallback as designed above?
- Should full-app lock be immediate-only, or default to a configurable timeout?
- Should disabling iCloud sync affect per-server lock metadata sync semantics?
- Do we want a dedicated `Security` page in settings instead of General section if scope grows?

## References
- Apple LocalAuthentication framework docs: https://developer.apple.com/documentation/localauthentication
- LAContext docs: https://developer.apple.com/documentation/localauthentication/lacontext
- Face ID/Touch ID guide: https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id
- Keychain + biometrics guide: https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id
- `SecAccessControlCreateFlags` docs: https://developer.apple.com/documentation/security/secaccesscontrolcreateflags
- `kSecAttrAccessControl` docs: https://developer.apple.com/documentation/security/ksecattraccesscontrol
- Info.plist key reference (`NSFaceIDUsageDescription`): https://developer-mdn.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html
- API details verified against Xcode SDK headers:
  - `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/LocalAuthentication.framework/Headers/LAContext.h`
  - `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/LocalAuthentication.framework/Headers/LAError.h`
