# Terminal Accessory Bar Customization (Spec)

## Summary
Add iOS settings that let users customize the terminal keyboard accessory bar by reordering, adding, and removing quick actions, plus custom text snippets/macros. Sync this configuration across devices with CloudKit.

## Problem
The current accessory bar is hard-coded in `GhosttyTerminalView+iOS.swift` and shows one fixed action order for every user. Power users need:
- personalized quick actions
- reusable command snippets
- the same setup on every device

## Goals (V1)
- Let users reorder, add, and remove accessory actions.
- Support custom text snippets/macros that can be added to the accessory bar.
- Persist locally and sync through CloudKit (private database).
- Apply changes immediately to active/new terminal views (no reconnect/restart required).
- Keep modifier behavior (`Ctrl`, `Alt`) stable and predictable.

## Non-Goals (V1)
- Scripted/conditional macros (variables, loops, shell templating).
- Secret management for snippets (Keychain-backed secret snippets).
- Per-server/per-workspace accessory layouts.
- macOS accessory customization UI (feature remains iOS-focused).

## Platforms
- iOS 16+
- macOS: no accessory customization UI in V1

## User Stories
- As an iOS terminal user, I can drag and reorder accessory items.
- As an iOS terminal user, I can add/remove built-in key actions.
- As an iOS terminal user, I can create/edit/delete custom snippets.
- As an iOS terminal user, I can place snippets on my accessory bar.
- As a multi-device user, my layout and snippets sync via iCloud.

## UX Design

### Entry Point
Inside `TerminalSettingsView`, add section `Keyboard Accessory`:
- `Customize Accessory Bar` -> `TerminalAccessoryCustomizationView`
- `Manage Snippets` -> `TerminalSnippetLibraryView`
- Keep `Show voice input button` unchanged

### Customize Accessory Screen
Sections:
1. `Preview` (horizontal chips mirroring runtime order)
2. `Active Items` (reorderable, remove)
3. `Available System Actions` (add)
4. `Available Snippets` (add)
5. `Reset to Default`

Behavior:
- `Ctrl` and `Alt` stay fixed at leading edge and are non-removable.
- Active item count bounds: min 4, max 28.
- No duplicate items.
- If active items become invalid/empty, normalize back to defaults.
- Changes apply immediately to currently open terminal accessory bars.

### Snippet Library Screen
Each snippet:
- `title` (shown on accessory button, max 12 visible chars)
- `content` (text payload)
- `sendMode`: `insert` or `insertAndEnter`

Actions:
- Create, edit, delete snippets
- Optional test send from terminal context (future toggle)

### Default Active Layout (V1)
`Esc`, `Tab`, `Arrow Up`, `Arrow Down`, `Arrow Left`, `Arrow Right`, `Backspace`, `Ctrl+C`, `Ctrl+D`, `Ctrl+Z`, `Ctrl+L`, `Home`, `End`, `Page Up`, `Page Down`

### System Action Catalog (V1)
- Navigation/editing: `Esc`, `Tab`, `Enter`, `Backspace`, `Delete`, `Insert`, `Home`, `End`, `Page Up`, `Page Down`, arrows
- Function keys: `F1`...`F12`
- Control shortcuts: `Ctrl+C`, `Ctrl+D`, `Ctrl+Z`, `Ctrl+L`, `Ctrl+A`, `Ctrl+E`, `Ctrl+K`, `Ctrl+U`

## Technical Design

### Data Model
Create:
- `VVTerm/Models/TerminalAccessoryModels.swift`

Types:
- `enum TerminalAccessorySystemActionID: String, Codable, CaseIterable, Hashable`
- `enum TerminalAccessoryItemRef: Codable, Hashable`
  - `.system(TerminalAccessorySystemActionID)`
  - `.snippet(UUID)`
- `struct TerminalSnippet: Identifiable, Codable, Equatable`
  - `id: UUID`
  - `title: String`
  - `content: String`
  - `sendMode: TerminalSnippetSendMode`
  - `updatedAt: Date`
  - `deletedAt: Date?` (tombstone for sync-safe deletes)
- `struct TerminalAccessoryLayout: Codable, Equatable`
  - `version: Int`
  - `activeItems: [TerminalAccessoryItemRef]`
  - `updatedAt: Date`
- `struct TerminalAccessoryProfile: Codable, Equatable`
  - `schemaVersion: Int`
  - `layout: TerminalAccessoryLayout`
  - `snippets: [TerminalSnippet]`
  - `updatedAt: Date`
  - `lastWriterDeviceId: String`

### Local Persistence
- `UserDefaults` key: `terminalAccessoryProfileV1` (JSON encoded profile)
- Source of truth on device is local profile; sync is eventually consistent.

Normalization rules:
- Drop unknown system action IDs.
- Remove duplicate `activeItems`.
- Remove snippet refs that point to deleted/missing snippets.
- Clamp active item count.
- Restore default items if below minimum.

### Managers / Services
Create:
- `VVTerm/Managers/TerminalAccessoryPreferencesManager.swift` (`@MainActor`, `ObservableObject`)

Update:
- `VVTerm/Services/CloudKit/CloudKitManager.swift`

Responsibilities:
- Preferences manager:
  - CRUD for snippets
  - reorder/add/remove active items
  - normalize and persist profile
  - publish profile changes for UI + runtime accessory rebuild
  - trigger debounced sync requests via `CloudKitManager`
- CloudKit manager additions:
  - pull remote accessory profile
  - push local accessory profile
  - merge local/remote on conflicts

### CloudKit Sync Design (V1)
Use existing private container `iCloud.app.vivy.VivyTerm` and same custom zone.
Accessory preference sync is implemented through `CloudKitManager` (centralized CloudKit ownership).

Record:
- `recordType`: `UserPreference`
- `recordName`: `terminalAccessory.v1`
- fields:
  - `schemaVersion: Int`
  - `payload: Bytes` (encoded `TerminalAccessoryProfile`)
  - `updatedAt: Date`
  - `lastWriterDeviceId: String`

Sync behavior:
- Honor existing global sync toggle (`SyncSettings.isEnabled`).
- On app foreground + settings save + periodic debounce: attempt push.
- On app launch and sync refresh: pull latest record.
- Offline/failure: keep local profile and retry later.

Conflict strategy:
- Use server record fetch on conflict (`serverRecordChanged`).
- Merge algorithm:
  - Layout: pick newer `layout.updatedAt`.
  - Snippets: merge by snippet `id`; keep newer by `updatedAt`; honor `deletedAt` tombstones.
  - Re-normalize `activeItems` against merged snippets.
- `updatedAt` is the only conflict winner signal in V1.
- If merge changed result, write merged profile back to CloudKit.

## Runtime Rendering Refactor
Update:
- `VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift`

Changes:
- Replace hard-coded action buttons with profile-driven item rendering.
- Keep leading `Ctrl` / `Alt` fixed.
- Render system actions and snippet buttons from `activeItems`.
- Snippet tap behavior:
  - snippets are independent actions (not modifier-aware)
  - if `Ctrl`/`Alt` is active, ignore and clear both modifier latches
  - `insert`: send snippet text exactly as stored
  - `insertAndEnter`: send snippet text exactly as stored, then `\r`
- Keep repeatable behavior for supported system actions.
- Rebuild accessory stack on profile updates without restarting SSH session.
- Open/reused terminal views subscribe to profile updates and rebuild accessory UI in place.

## Settings Integration
Update:
- `VVTerm/Views/Settings/TerminalSettingsView.swift`
- Add:
  - `VVTerm/Views/Settings/TerminalAccessoryCustomizationView.swift`
  - `VVTerm/Views/Settings/TerminalSnippetLibraryView.swift`
  - `VVTerm/Views/Settings/TerminalSnippetFormView.swift`

## Migration Plan
- Existing users with no stored profile get V1 default layout + empty snippets.
- Corrupt payload -> recover to normalized default profile.
- Future schema changes handled with `schemaVersion` and migrators.

## Limits (V1)
- Max snippets: 100
- Max snippet content length: 2048 chars
- Max snippet title length: 24 chars (12-14 target visible)
- Max active items: 28

## Accessibility
- Full VoiceOver labels for all system/snippet buttons.
- Reorder controls accessible via VoiceOver actions.
- Minimum tap target >= 32pt.

## Privacy & Safety
- Snippets sync only in user private CloudKit database.
- Do not log snippet content in analytics/logs.
- Show warning in snippet editor: avoid storing secrets in snippets.

## Testing Plan

### Unit Tests
- `TerminalAccessoryPreferencesManagerTests`
  - normalization and constraints
  - snippet CRUD
  - active item validation
- `TerminalAccessoryCloudSyncTests`
  - conflict merge correctness
  - tombstone delete propagation
  - corrupt payload recovery
  - CloudKit record read/write through `CloudKitManager`

### UI Tests (iOS)
- Settings navigation to customization + snippet screens.
- Reorder/add/remove reflects on runtime accessory bar.
- Snippet create/edit/delete and button send behavior.
- Relaunch persistence.
- Multi-device sync smoke scenario (mocked CloudKit service).

### Regression Checks
- `Ctrl`/`Alt` latch behavior unchanged.
- Repeatable keys still auto-repeat.
- Voice button toggle behavior unchanged.
- Snippet taps always ignore `Ctrl`/`Alt` and send raw snippet payload.

## Rollout
- Optional flag for one internal build: `terminalAccessoryCustomizationEnabled`.
- If stable, enable by default in next release.

## Open Questions
- Should snippet buttons support custom SF Symbol icons in V1?
- Should snippets optionally be local-only (not synced) in V1 or V2?
- Should we support import/export of snippet library (JSON) in V2?
