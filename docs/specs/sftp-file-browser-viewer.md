# SFTP Remote File Browser & Viewer (Spec)

## Summary
Add a read-only SFTP file browser and file viewer for remote hosts. The feature is exposed as a new server view tab placed after Terminal:
- `Stats`
- `Terminal`
- `Files`

This is a cross-platform feature for macOS and iOS.

## Problem
VVTerm can connect and run shell commands, but users cannot browse remote files or quickly inspect file contents without typing shell commands (`ls`, `cat`, `less`) in Terminal. This adds friction for routine tasks like checking config files, logs, and deployment artifacts.

## Goals (V1)
- Add a `Files` view tab after `Terminal` in the per-server view selector.
- Browse remote directories over SFTP.
- View file metadata and read file contents (read-only).
- Support both macOS and iOS UI patterns.
- Reuse existing SSH credentials and host-key verification flow.
- Keep tab/session limits unchanged (no new Pro gating in V1).
- Preserve current terminal behavior and performance.

## Non-Goals (V1)
- Upload, rename, delete, chmod/chown, or create files/directories.
- Remote file editing and save-back.
- Recursive search / grep across remote trees.
- Git-aware file diffing.
- Offline caching of full file contents.

## User Stories
- As a user, I can switch from Terminal to Files without disconnecting.
- As a user, I can navigate directories with breadcrumbs.
- As a user, I can open a file and preview its contents quickly.
- As a user, I can refresh the current directory when files change remotely.
- As a user, I can see clear error states for permission denied, not found, and connection issues.

## UX Design

### View Tab Placement
- Add `Files` to the per-server view selector after `Terminal`.
- Final order: `Stats`, `Terminal`, `Files`.
- Keep per-server selected-view persistence (`selectedViewByServer`) and accept `"files"` values.
- Update `ConnectionViewTab.defaultOrder` to include `.files` and append missing tab IDs during order migration.

### macOS
- Update `ConnectionTerminalContainer` toolbar picker in `VVTerm/Views/Tabs/ConnectionTabsView.swift`:
  - `Stats` (`chart.bar.xaxis`)
  - `Terminal` (`terminal`)
  - `Files` (`folder`)
- Show terminal tab strip only when `selectedView == "terminal"`.
- In `Files` view, toolbar actions:
  - Back / Up directory
  - Refresh
  - Sort menu (name/date/size)
  - Show hidden files toggle

### iOS
- Update segmented control in `VVTerm/Views/iOS/iOSContentView.swift`:
  - Tags: `["stats", "terminal", "files"]`
  - Icons: `["chart.bar.xaxis", "terminal", "folder"]`
- Keep Terminal-only actions (`+` new terminal tab) hidden unless `selectedView == "terminal"`.
- Add Files-specific actions in trailing menu: Refresh, toggle hidden files, sort.

### Browser Behavior
- First open path selection priority:
  1. Last successful path for that server (local cache).
  2. Active terminal working directory for that server (if available).
  3. Remote home directory (`.` realpath fallback).
- Directory list behavior:
  - directories first, then files
  - default sort: name ascending
  - pull-to-refresh (iOS) / refresh button (macOS)
  - tap directory to navigate into it
  - tap file to open viewer

### Viewer Behavior
- V1 viewer is read-only.
- Text files:
  - UTF-8 text preview with monospaced font.
  - Show truncation banner when preview limit is hit.
- Binary/unknown files:
  - Show metadata card and message that inline preview is unavailable in V1.
- Always show metadata header:
  - path, size, permissions, modified time, type

## Technical Design

### New Models
Create `VVTerm/Models/RemoteFile.swift`:
- `enum RemoteFileType: String, Codable` (`file`, `directory`, `symlink`, `other`)
- `struct RemoteFileEntry: Identifiable, Hashable`
  - `id` (full path)
  - `name`
  - `path`
  - `type`
  - `size: UInt64?`
  - `modifiedAt: Date?`
  - `permissions: UInt32?`
  - `symlinkTarget: String?`
- `enum RemoteFileSort: String, Codable, CaseIterable` (`name`, `modifiedAt`, `size`)
- `struct RemoteFileViewerPayload`
  - `entry: RemoteFileEntry`
  - `textPreview: String?`
  - `isTruncated: Bool`

### SSH / SFTP Layer
Extend `SSHClient` + `SSHSession` in `VVTerm/Services/SSH/SSHClient.swift` with SFTP operations backed by `libssh2_sftp`:
- `listDirectory(path:)`
- `stat(path:)`
- `readFile(path:maxBytes:offset:)`
- `resolveHomeDirectory()`

Implementation notes:
- Keep operations actor-isolated in `SSHSession` to avoid races with shell/exec channels.
- Handle `LIBSSH2_ERROR_EAGAIN` using existing socket wait flow.
- Reuse existing authenticated SSH sessions when possible.
- If no reusable session exists, create a dedicated short-lived SSH client for file browsing.

### File Browser Manager
Create `VVTerm/Managers/RemoteFileBrowserManager.swift` (`@MainActor`, `ObservableObject`):
- Per-server state:
  - current path
  - breadcrumbs
  - entries
  - loading/error state
  - sort + hidden-file toggle
  - selected file payload
- Public APIs:
  - `loadInitialPath(for:)`
  - `refresh(serverId:)`
  - `openDirectory(_:serverId:)`
  - `openFile(_:serverId:)`
  - `goUp(serverId:)`
  - `disconnect(serverId:)`

### Connection Strategy
- Prefer existing shared SSH client from:
  - `TerminalTabManager` (macOS path)
  - `ConnectionSessionManager` (iOS path)
- If unavailable, manager creates an owned `SSHClient`, connects using `KeychainManager` credentials, and disconnects on idle/teardown.
- On explicit server disconnect, always tear down any owned SFTP connections.

### Local Persistence (No Cloud Sync in V1)
- Store lightweight per-server browser preferences in `UserDefaults`:
  - last visited path
  - sort mode
  - show hidden files
- Key example: `remoteFileBrowserState.v1`
- Do not sync file browser state with CloudKit in V1.

## View Integration

### macOS Path
Update `VVTerm/Views/Tabs/ConnectionTabsView.swift`:
- Add `Files` picker tag.
- Render new `RemoteFileBrowserView` when `selectedView == "files"`.
- Keep terminal-only rendering/background logic scoped to `selectedView == "terminal"`.

### iOS Path
Update `VVTerm/Views/iOS/iOSContentView.swift`:
- Add `files` segmented option in `iOSNativeSegmentedPicker`.
- In `sessionContent`, render `RemoteFileBrowserView` for the active server when selected view is files.
- Keep terminal warmup logic (`shouldShowTerminalBySession`) untouched and only for terminal mode.

### New Views
Create:
- `VVTerm/Views/Files/RemoteFileBrowserView.swift`
- `VVTerm/Views/Files/RemoteFileViewerView.swift`
- `VVTerm/Views/Files/RemoteFileRow.swift`

## Error Handling
- Map common SFTP failures to user-facing states:
  - permission denied
  - path not found
  - disconnected / timeout
  - unsupported encoding / binary file
- Preserve retry affordances (`Retry`, `Refresh`).
- Avoid dropping user path context on transient failures.

## Security & Privacy
- Reuse current SSH authentication and host-key trust flow.
- No credential changes in Keychain schema.
- No file content logging.
- No remote file metadata/content synced to CloudKit.

## Performance Limits (V1)
- Directory listing soft cap: 2,000 entries (show warning after cap).
- Text preview default cap: 512 KB.
- Hard read cap per viewer request: 2 MB.
- Lazy-load viewer data only when a file is selected.

## Testing Plan

### Unit Tests
- Add `VVTermTests/RemoteFileBrowserManagerTests.swift`:
  - path navigation
  - sort and hidden-file filtering
  - state restoration
- Add `VVTermTests/SFTPPathNormalizationTests.swift`:
  - `.` / `..` handling
  - root handling
  - symlink-safe display path logic
- Add `VVTermTests/SFTPPreviewTests.swift`:
  - text/binary detection
  - truncation behavior

### Integration / Behavior Tests
- Connect to test SSH server and validate:
  - list directory
  - read small text file
  - permission denied handling
  - reconnect and refresh behavior

### UI Tests
- macOS and iOS:
  - `Files` tab appears after `Terminal`.
  - switching `Terminal <-> Files` preserves session stability.
  - opening file shows viewer and metadata.
  - refresh and breadcrumb navigation work.

## Rollout
- Feature flag: `sftpBrowserEnabled` (default off for first internal build).
- Phase 1: internal QA with mixed host types (Linux/macOS/BSD).
- Phase 2: enable by default in public build after stability validation.

## Open Questions
- Should V1 include image preview (PNG/JPEG) or keep text-only preview?
- Should directory listing use pagination in V1 or defer until very large directory feedback appears?
- Should we add an `Open in Terminal` action from Files in V1.1?
