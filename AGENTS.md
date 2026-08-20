# VVTerm

Cross-platform (iOS/macOS) SSH terminal app with iCloud sync and Keychain credential storage.

## Target Versions

- **macOS**: 13.3+ (Ventura), arm64 only
- **iOS**: 16.1+, arm64 only
- **Xcode**: 16.0+

## Architecture

```
VVTerm/
├── App/
│   ├── VVTermApp.swift           # App entry point and composition root
│   ├── ContentView.swift         # Shared root container
│   ├── Localization/             # App-scoped localization preferences
│   └── iOS/                      # iOS app shell and root navigation views
├── Core/                         # Shared infrastructure and platform glue
│   ├── Logging/
│   ├── Network/
│   ├── UI/
│   ├── SSH/
│   ├── Security/
│   ├── Sync/
│   └── Terminal/
│       └── Ghostty/              # Shared libghostty bridge
├── Features/                     # Feature-first product features
│   ├── ConnectionViews/
│   │   ├── Domain/
│   │   └── Application/
│   ├── LocalDiscovery/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Servers/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── RemoteFiles/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── VoiceInput/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Security/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Settings/
│   │   ├── Application/
│   │   └── UI/
│   ├── Store/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── Support/
│   │   └── UI/
│   ├── TerminalThemes/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── TerminalAccessories/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── TerminalPresets/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── TerminalSessions/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/       # Session runtimes and Ghostty surfaces
│   │   └── UI/
│   ├── Stats/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   └── Welcome/
│       ├── Domain/
│       └── UI/
└── Resources/                    # Bundled assets, themes, terminfo, l10n
```

## Architecture Direction

VVTerm uses a **feature-first architecture** for app-owned source code.

Current architecture:
- `App` owns app entry, composition roots, shared root containers, localization preferences, and iOS app-shell navigation.
- `Core/Sync` owns CloudKit sync infrastructure.
- `Core/Security` owns keychain, device identity, and privacy-mode infrastructure.
- `Core/Network` owns shared connectivity monitoring and Cloudflare transport support.
- `Core/UI` owns shared view primitives and presentation helpers reused across features.
- `Core/Terminal` owns shared clipboard, paste, terminal text/default helpers, and the shared libghostty bridge.
- `Core/Logging` owns shared logging utilities.
- `Core/SSH` owns shared SSH bootstrap, known-hosts, key generation, environment detection, rich-paste support, tmux/mosh runtime helpers, and `SSHClient`.
- `Features/ConnectionViews` owns connection view tab configuration types and state.
- `Features/RemoteFiles` owns remote file browsing, preview, transfer, and SFTP integration.
- `Features/LocalDiscovery` owns discovery-specific code and UI.
- `Features/Servers` owns server/workspace domain models, server management, and server/workspace UI flows.
- `Features/Stats` owns server metrics collection and presentation.
- `Features/Security` owns app lock and biometric authentication flows.
- `Features/Settings` owns settings window presentation and settings screens.
- `Features/Store` owns Pro entitlements, purchases, and upgrade surfaces.
- `Features/Support` owns support/contact UI surfaces.
- `Features/TerminalThemes` owns theme models, validation, storage paths, parsing, and theme management.
- `Features/TerminalAccessories` owns keyboard accessory models, preferences, settings UI, and accessory validation flows.
- `Features/TerminalPresets` owns terminal preset models, persistence, and preset form UI.
- `Features/TerminalSessions` owns terminal session/tab domain models, session/tab managers, tmux prompt coordination, live activity support, Ghostty runtime surfaces, and platform terminal UI.
- `Features/VoiceInput` owns transcription/audio capture infrastructure, MLX model management, and transcription settings UI.
- `Features/Welcome` owns welcome/onboarding copy and presentation.
- New app code should land in `Features`, `Core`, or `App` based on ownership.
- New work inside a feature should stay inside its `Features/<FeatureName>` subtree and should not reintroduce app-wide bucket folders.

Feature-first shape:
- `Domain`: pure feature types and rules
- `Application`: authoritative feature state, user intents, tasks, cancellation, and workflows
- `Infrastructure`: transport, persistence, adapters, external integrations
- `UI`: SwiftUI/AppKit/UIKit presentation that renders state and forwards user intents

Dependency direction:
- `App` creates one explicit production dependency graph and injects it at app or feature roots.
- Keep the composition owner plain and non-observable. It assembles live dependencies but does not duplicate feature state.
- Preview and test compositions must not start live CloudKit, Keychain, network, StoreKit, or other external work.
- Leaf views, stores, coordinators, clients, repositories, and adapters must not create production dependencies through `.shared`, default live arguments, or hidden service locators.
- Feature code may depend on neutral `Core` contracts. `Core` must not expose or depend on feature-owned models or policies.
- Map feature models at Infrastructure boundaries. UI must not own transport, persistence, filesystem or path policy, shell syntax, or long-lived tasks.

Type meanings for new and touched code:
- `Store`: authoritative observable state.
- `Coordinator`: one asynchronous workflow or lifecycle, including task replacement and cancellation.
- `Client`: an external-system boundary.
- `Repository`: a persistence boundary.
- `Policy`: a pure deterministic rule.
- `Projection`: narrow read-only observable state derived from an authoritative owner.
- `Runtime`: a native resource lifecycle.
- `Composition`: live, preview, or test dependency assembly.
- Keep `ObservableObject` while iOS 16.1 and macOS 13.3 are supported. Do not start a whole-app Observation migration.
- Retire an ambiguous `Manager` name only when its owned implementation already changes. Do not perform naming-only migrations.

State and lifecycle rules:
- Model closed presentation and workflow states with feature-owned enums instead of independent flags, revision counters, or closure payloads.
- Store only facts that cannot be derived safely from authoritative state.
- The owner that starts a task also owns replacement, cancellation, stale-result rejection, and teardown.
- Prefer one stable dispatcher with typed command IDs for app and toolbar commands.

For Files/SFTP specifically:
- no non-view logic under `UI`
- no feature policy inside `SSHClient` beyond low-level transport/session behavior
- use explicit dependency injection at the feature boundary
- do direct cutovers, not compatibility shims

For every feature:
- keep `Domain`, `Application`, `Infrastructure`, and `UI` boundaries intact
- prefer view-owned dependencies to be injected from the app/screen boundary instead of created inside leaf views
- if shared cross-feature primitives are needed, extract them into `Core` instead of creating new app-wide bucket folders
- prefer one primary type per file and match the filename to that type
- When one type remains the clear lifecycle owner but has distinct capabilities, keep stored state, initialization, and lifecycle in `Type.swift`, then split cohesive capabilities into `Type+Capability.swift` extension files such as `Type+Commands.swift` or `Type+Parsing.swift`.
- Use capability extension files to clarify one owner, not to hide separate owners. Extract a new type when a capability owns independent state or lifecycle. Swift extensions cannot add stored properties.
- order files as inputs and owned state, initialization, public intents, then private helpers
- keep view-owned state private; comments explain reasons and invariants instead of repeating code
- review ownership when a file exceeds 600 lines; a file over 1,000 lines needs a clear reason

Architecture non-goals:
- no whole-app architecture rewrite, generic reducer framework, package explosion, mass rename, or UI redesign
- no behavior change only to reduce a file size
- use direct cutovers; do not add compatibility service locators or a second app dependency graph

Apple platform UI split pattern:
- Prefer `Type+iOS.swift` and `Type+macOS.swift` whenever app composition, lifecycle, adapters, or presentation behavior differs by platform. Keep the shared `Type.swift` focused on neutral contracts and shared state.
- Do not let shared SwiftUI files accumulate large inline `#if os(iOS)` / `#if os(macOS)` branches. If platform layout, lifecycle, modifiers, or state diverge, keep the shared feature shell neutral and move platform presentation into `Type+iOS.swift` and `Type+macOS.swift` files with file-level compile gates.
- Because VVTerm uses one multiplatform target, platform-specific files must still be guarded with `#if os(...)` unless target membership is explicitly changed; folder names such as `iOS/` or `macOS/` are not enough.
- Avoid `iOS`, `Mac`, `macOS`, and `MacOS` prefixes in product UI type names. Prefer feature/domain names and put platform ownership in the filename or folder.
- Platform prefixes are acceptable for true platform adapters and app-shell bridges, such as `NSViewRepresentable`, `UIViewRepresentable`, AppKit/UIKit delegates, toolbar/window/menu bridges, and Ghostty platform terminal views.
- Platform-specific stored SwiftUI state should usually live in platform child views or small platform models. Swift extensions cannot add stored properties, so do not keep long-term gated `@State` in shared views just to make an extension split compile.
- After platform UI splits, validate both iOS and macOS builds unless the change is documentation-only.

Stats UI ownership:
- Keep `ServerStatsView.swift` as a thin root wrapper for injected inputs, app/storage state, sheet triggers, and composition. Do not add metric cards, charts, detail sheets, or collector operations back into this file.
- Keep collection lifecycle, visibility handling, retry overlay, and collector action closures in `ServerStatsDashboard.swift`.
- Keep block ordering, style selection, preview composition, and page layout in `StatsBlocksContent.swift`, `StatsDashboardCards.swift`, and `ClassicStatsContent.swift`.
- Keep reusable cards, charts, gauges, and meters under `Features/Stats/UI/Components`, and detail sheets/rows under `Features/Stats/UI/Details`.
- Keep platform sheet chrome and close/search presentation behind `DetailPresentation.swift`, `DetailPresentation+iOS.swift`, and `DetailPresentation+macOS.swift`. Product UI types inside those files should use neutral names such as `StatsDetailShell` or `StatsSearchField`; the filename carries the platform ownership.
- Small inline platform gates are acceptable only for platform constants or narrow modifiers such as native colors, toolbar placement, or iOS detents. If a platform branch grows into a body/layout/lifecycle variant, split it into a platform file.

Status presentation:
- Keep blocking states local to the screen that owns them.
- Use `Core/UI/Notices` for shared non-blocking presentation: one top banner for persistent or degraded state and ID-keyed bottom operations for user-initiated progress or failure.
- Keep destructive decisions in native alerts and confirmation dialogs.
- Scope notice hosts to their app or feature surface. Do not add a global toast bus or move feature policy into `Core/UI`.

Remote shell and multiplexer ownership:
- Resolve the remote platform and shell through `SSHClient.remoteEnvironment()` and build startup or working-directory commands through `RemoteShellProfile` and `RemoteTerminalBootstrap`.
- UI and session orchestration must not construct POSIX, PowerShell, or `cmd.exe` syntax. Runtime capability fallback must not rewrite persisted transport or tmux preferences.
- Windows tmux-compatible sessions use the explicit psmux backend and must not use POSIX tmux command construction.
- Probe `psmux`, then `pmux`, and accept `tmux.exe` only after a psmux-specific compatibility check.
- Apply VVTerm-generated tmux or psmux configuration only to VVTerm-managed sessions, never external user sessions.

## Product Planning and Repository Documentation

- Keep product ideas, future specifications, roadmap decisions, pricing or packaging strategy, and internal rollout plans in the VVTerm Linear project, not in this repository.
- Search Linear before creating work. Reuse or update an existing issue when it owns the same scope.
- Create a Linear issue before a large implementation begins, and keep its decisions, acceptance criteria, and status current as the scope changes.
- Keep repository documentation limited to current architecture, build, test, security, contribution, protocol, and intentionally public user contracts that must evolve with code.
- Enforce completed behavior with tests and concise current architecture rules instead of retaining speculative or completed implementation plans.
- Linear is not a secret manager. Do not store credentials, tokens, private keys, customer data, or production secrets in either Linear or the repository.

## Refactoring Rules

When doing architectural refactors:
- prioritize structural splits and ownership cleanup over behavior changes
- preserve existing UI, UX, and visual behavior unless the user explicitly asks for a change
- do not bundle redesigns or new features into a refactor
- keep platform parity intact unless a platform-specific bug is being fixed
- if a behavior change is necessary for correctness or safety, keep it minimal and isolated

Safe refactor expectation:
- same screens
- same entry points
- same interactions
- same user-facing flows
- smaller files, clearer boundaries, better ownership

## Testing and Regression Policy

- Every bug fix and regression fix must include automated test coverage unless it is genuinely not automatable. If coverage is not added, explain the blocker and the manual validation that was used.
- For regressions, write or update a deterministic failing test first when feasible, then fix the production path.
- Match test level to risk:
  - use unit tests for domain rules, parser behavior, state machines, focus policies, coordinators, and model logic
  - use UI tests/XCUITest for SwiftUI/UIKit lifecycle, keyboard behavior, navigation, accessibility, focus, sheet, and platform integration regressions
  - use integration or end-to-end tests when behavior crosses SSH/session/terminal rendering boundaries and can be exercised locally or in simulator
- Refactors must keep existing tests passing and should add coverage before simplifying risky or previously untested behavior.
- Keyboard and terminal input changes require focused regression coverage. At minimum, cover the relevant policy/model path in unit tests and the user-visible iOS behavior in XCUITest when software keyboard, accessory bar, hardware keyboard, IME/preedit, backspace repeat, find UI, floating controls, focus, or tab/view switching behavior is touched.
- Do not rely on "checked on my phone" or manual Xcode testing as the only validation for keyboard/input regressions. Keep simulator UI tests or unit tests that can be rerun by future agents.
- Before finishing non-documentation code changes, run the narrowest reliable build/test commands that exercise the touched behavior and report exactly what was run. If a test cannot run because of tooling or environment issues, report that as a residual risk.

## Test Source Organization

- Put each new test under the same `App`, `Core`, or `Features/<FeatureName>` owner as the production behavior that it verifies. Do not add unrelated tests to the `VVTermTests` or `VVTermUITests` root.
- In a dense feature test folder, use `Domain`, `Application`, `Infrastructure`, and `UI` when those boundaries identify real owners. Mirror deeper production capability folders only when they prevent another flat list or make ownership clearer.
- Keep a small single-owner test folder flat. File count and line count are review signals, not design targets. Do not create a folder only to reduce a number.
- Put environment-dependent tests that cross product owners under `Integration/<Boundary>`, such as `Integration/SSH`. Keep their external prerequisites and skip conditions explicit.
- Keep test support beside the feature or boundary that owns it. Use top-level `Support` only for helpers with real cross-feature users. Do not create generic `Utils`, `Common`, or broad `Mocks` folders.
- Name unit files `TypeTests.swift`, cross-boundary files `FlowIntegrationTests.swift`, and UI files `FlowUITests+iOS.swift` or `FlowUITests+macOS.swift`.
- Group UI tests by feature and platform. Keep file-level `#if os(iOS)` or `#if os(macOS)` gates; a platform folder or filename is not enough for the multiplatform test target.
- Split an oversized test file only when it contains independent behaviors or suite owners. Prefer separate behavior-named suites and local shared support. Do not split one suite into extensions only to reduce line count.
- Preserve serialized execution, actor isolation, reset hooks, environment gates, and test identifiers when reorganizing tests. Compare the meaningful test inventory before and after a large test refactor.
- Do not combine test-source reorganization with XCTest-to-Swift-Testing migration, new product behavior, or unrelated coverage work.

## Commits

- Use **atomic commits**.
- Each commit must represent one coherent change that can be reviewed and reverted independently.
- Do not mix architecture docs, code moves, behavioral fixes, and unrelated cleanup in one commit unless they are inseparable.
- Prefer a sequence such as:
  - architecture/spec update
  - domain extraction
  - application/store extraction
  - infrastructure extraction
  - UI split
  - targeted safety fix
- Before committing, verify the diff matches a single intent.

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
- Free: 1 workspace, 1 server, 1 tab
- Pro: Unlimited everything
- Products: Monthly ($6.49), Yearly ($24.99), Lifetime ($49.99)

## Build Dependencies

### libghostty
Pre-built xcframework at `Vendor/libghostty/GhosttyKit.xcframework`
Build with: `./scripts/build.sh ghostty`

### libssh2 + OpenSSL
Build with: `./scripts/build.sh ssh`
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
4. **Keychain credentials** use opt-in iCloud Keychain sync. Device identity, session resume secrets, and derived caches stay device-only.
5. **iOS keyboard toolbar** provides Esc, Tab, Ctrl, arrows, function keys
6. **Voice-to-command** uses MLX Whisper/Parakeet on-device or Apple Speech fallback
