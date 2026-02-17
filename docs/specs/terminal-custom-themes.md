# Terminal Custom Themes (Spec)

## Summary
Add first-class custom terminal themes with a single entry point in settings: `Custom Theme...` -> `Paste from Clipboard`, `Import from File`, `Builder`. Support per-appearance assignment (dark/light) and sync custom themes through iCloud from V1.

## Problem
VVTerm ships many built-in Ghostty themes, but users cannot create or import their own themes. Theme choice is currently name-based and built-in-oriented, which blocks:
- importing popular Ghostty-compatible theme files
- quick sharing via clipboard
- simple in-app theme authoring
- iCloud syncing of custom theme library and assignments

## Goals (V1)
- Add one `Custom Theme...` action in `TerminalSettingsView`.
- Support three creation flows:
  - paste full theme text from clipboard
  - import from file
  - create/edit in a basic builder UI
- Allow assigning custom themes to dark/light/both targets only when `Use different themes for Light/Dark mode` is enabled.
- When that toggle is disabled, apply custom themes to the single active theme slot only.
- Sync custom themes via CloudKit private database.
- Keep Ghostty compatibility by storing themes in Ghostty theme file format.
- Apply changes immediately to active/new terminal sessions.

## Non-Goals (V1)
- Theme marketplace/community browsing.
- Per-server or per-workspace theme overrides.
- Arbitrary color expression formats beyond validated hex-compatible values.
- Full advanced visual theme editor (gradients, transparency model, previews of all terminal states).

## User Stories
- As a user, I can tap `Custom Theme...` and choose paste/import/builder.
- As a user, when per-appearance mode is enabled, I can assign a new custom theme to dark, light, or both slots.
- As a user, when per-appearance mode is disabled, I can apply a custom theme to the single theme slot.
- As a user, I can see custom themes in the same picker flow as built-ins.
- As a multi-device user, my custom themes sync through iCloud.

## UX Design

### Entry Point
In `TerminalSettingsView`, under `Theme` section:
- Keep current controls:
  - `Use different themes for Light/Dark mode`
  - dark/light pickers (or single picker)
- Add button:
  - `Custom Theme...`

### Custom Theme Action Sheet / Menu
`Custom Theme...` opens three options:
1. `Paste from Clipboard`
2. `Import from File`
3. `Builder`

### Paste from Clipboard Flow
1. Read clipboard text.
2. Validate theme content and required keys.
3. Ask for theme name (pre-filled from parsed metadata if available, else generated).
4. Ask `Apply to`:
   - `Dark`
   - `Light`
   - `Both` (shown only when per-appearance is enabled)
5. Save, apply, and reload terminal config.

### Import from File Flow
1. Use `.fileImporter` (single file selection).
2. Read file as UTF-8 text.
3. Validate content.
4. Pre-fill name from file name.
5. Ask `Apply to` target.
6. Save, apply, reload.

### Builder Flow (V1 basic)
Form fields:
- Name
- Background
- Foreground
- Cursor color
- Cursor text
- Selection background
- Selection foreground
- Optional advanced section: ANSI palette `0...15`

Actions:
- `Save Theme`
- `Save and Apply`

Builder emits canonical Ghostty-compatible text content.

### Theme Picker Presentation
Theme pickers show grouped options:
- Built-in
- Custom

Selection persists as theme refs, not raw display names.

### Custom Theme Management
For each custom theme:
- Rename
- Duplicate
- Delete
- Export (optional in V1 if effort stays low)

## Technical Design

### Data Model
Create `VVTerm/Models/TerminalTheme.swift`:
- `struct TerminalTheme: Identifiable, Codable, Equatable`
  - `id: UUID`
  - `name: String`
  - `content: String`
  - `updatedAt: Date`
  - `deletedAt: Date?` (tombstone for sync-safe delete)

Create theme reference type:
- `enum TerminalThemeRef: Codable, Equatable`
  - `.builtin(String)` (built-in theme file name)
  - `.custom(UUID)` (custom theme id)

Persisted selection keys:
- `terminalThemeRefDark`
- `terminalThemeRefLight`
- `terminalUsePerAppearanceTheme` (existing)

### Managers
Create `VVTerm/Managers/TerminalThemeManager.swift` (`@MainActor`, `ObservableObject`):
- Source of truth for custom themes.
- CRUD operations + validation.
- Helpers:
  - list built-in names
  - list custom themes
  - resolve `TerminalThemeRef` to effective theme file/name
  - apply/fallback logic
- Emits change notifications for UI + Ghostty reload.

### Local Persistence
Use `UserDefaults` JSON payload for custom theme metadata/content:
- key: `terminalCustomThemesV1`

Optional file mirror in Application Support (if needed later for export/debug), but V1 can operate from encoded content written into temp Ghostty theme dir during config generation.

### Theme Content Validation
Required keys:
- `background`
- `foreground`

Optional supported keys:
- `cursor-color`
- `cursor-text`
- `selection-background`
- `selection-foreground`
- `palette = N=#RRGGBB` for N in `0...15`

Rules:
- Trim comments/whitespace safely.
- Validate color format (`#RRGGBB`).
- Reject duplicate invalid key/value pairs with line-specific error messages.
- Canonicalize output order before save for stable sync/merges.

### Ghostty Integration
Update `VVTerm/GhosttyTerminal/Ghostty.App.swift`:
- During `setupThemes(...)`, materialize both built-in and custom themes into the temp Ghostty themes directory.
- Ensure copy/write behavior updates existing files (overwrite allowed for updated custom themes).
- Continue using `theme = <effective name>` in generated config.

### ThemeColorParser Integration
Update `VVTerm/Utilities/ThemeColorParser.swift`:
- Resolve custom themes through `TerminalThemeManager` or shared resolver before bundled lookup.
- Keep fallback behavior for missing themes.

### Theme Assignment Behavior
- If per-appearance is OFF:
  - assign chosen theme to dark slot ref (single effective slot behavior)
- If per-appearance is ON:
  - assignment prompt allows dark/light/both
  - UI keeps distinct picker values

## CloudKit Sync (V1)
Use existing container `iCloud.app.vivy.VivyTerm` and current custom zone.

Add record type:
- `TerminalTheme`
  - recordName: custom theme UUID
  - fields:
    - `id` (String UUID)
    - `name` (String)
    - `content` (String)
    - `updatedAt` (Date)
    - `deletedAt` (Date, optional)

Sync rules:
- Deduplicate by `id`.
- Prefer latest `updatedAt`.
- Respect tombstones (`deletedAt`) to avoid reappearing deletes.
- Pull on launch/foreground and existing sync refresh cadence.
- Push on create/update/delete with debounce.

Add record type:
- `TerminalThemePreference`
  - recordName: `terminal-theme-preference.v1`
  - fields:
    - `themeRefDark` (String, `builtin:<name>` or `custom:<uuid>`)
    - `themeRefLight` (String, `builtin:<name>` or `custom:<uuid>`)
    - `usePerAppearanceTheme` (Int/Bool)
    - `updatedAt` (Date)

Preference sync rules:
- Last-write-wins by `updatedAt`.
- On startup, load remote preference after local migration.
- If referenced custom theme is missing locally, keep pref but use runtime fallback until theme arrives or ref is changed.

## Migration Plan
- Migrate existing keys:
  - `terminalThemeName` -> `terminalThemeRefDark = builtin:<name>`
  - `terminalThemeNameLight` -> `terminalThemeRefLight = builtin:<name>`
- If selected ref is invalid/missing:
  - dark fallback: `Aizen Dark`
  - light fallback: `Aizen Light`
- Preserve existing per-appearance toggle.

## Error Handling
- Clipboard empty or unreadable: show inline error.
- File unreadable: show import error with reason.
- Invalid theme format: show line-specific parse error.
- Name collision:
  - if custom name conflicts with built-in/custom, append numeric suffix.

## Testing Plan

### Unit Tests
- Theme parser validation:
  - required keys
  - palette bounds
  - hex format checks
  - canonicalization
- Theme manager:
  - CRUD
  - assignment and fallback
  - duplicate/rename collision handling
- CloudKit merge:
  - newer wins
  - tombstone deletion propagation
  - deduplication by UUID

### UI Tests
- `Custom Theme...` shows 3 options.
- Paste/import flow creates and applies theme.
- Builder save creates valid theme and appears in picker.
- Per-appearance assignment correctly updates dark/light picker refs.
- Deleting active custom theme falls back safely.

## Rollout
- Introduce behind local feature flag for one internal build:
  - `terminalCustomThemesEnabled`
- Enable by default after validation.

## Open Questions
- Should V1 include export or move to V1.1?
- Should builder include live ANSI preview in V1?
