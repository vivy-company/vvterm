# Local Network SSH Device Discovery (Spec)

## Summary
Add a user-initiated "Discover Local Devices" flow that finds nearby SSH hosts on the current LAN and pre-fills `Add Server` for fast setup.

## Problem
Creating a server currently requires users to know host/IP details in advance and manually type them into `ServerFormSheet`. This is high-friction when setting up home-lab devices, local VMs, Raspberry Pis, or newly provisioned machines on the same network.

## Goals (V1)
- Discover SSH-capable hosts on local network with user action (no background scanning).
- Make discovery accessible from the same place users already add servers.
- Let users select a discovered host and open `ServerFormSheet` with prefilled `name`, `host`, and `port`.
- Keep existing Pro limits unchanged (`ServerManager.canAddServer` remains source of truth).
- Keep all discovery data local-only (no CloudKit sync).

## Non-Goals (V1)
- Automatic login without credentials.
- Background/continuous network scanning.
- WAN discovery (outside current LAN).
- Auto-creating servers without opening form confirmation.
- Changes to existing SSH trust/fingerprint behavior.

## User Stories
- As a new user, I can quickly find machines on my Wi-Fi and avoid typing IP addresses.
- As an existing user, I can prefill a server from discovered hosts and complete credentials quickly.
- As a privacy-conscious user, discovery runs only when I explicitly request it.

## UX Design

### Action Placement (Seamless Entry)

#### iOS
- `Servers` screen `+` menu (`iOSContentView`) adds:
  - `Discover Local Devices` (icon: `dot.radiowaves.left.and.right`)
  - existing `Add Server`
  - existing `Add Workspace`
- `NoServersEmptyState` adds secondary CTA:
  - `Discover Local Devices`
  - keep `Add Server` CTA for manual path.
- In `ServerFormSheet`, add inline action in `Server` section:
  - `Pick from Local Discovery...`
  - opens discovery sheet and applies selected host back into current form.

#### macOS
- Sidebar footer (`ServerSidebarView`) keeps primary `Add Server` button.
- Add adjacent discover icon button (same symbol) beside `Add Server`.
- Add menu command in `VVTermCommands`:
  - `Discover Local Devices...`
  - shortcut: `Cmd+Shift+D`

Rationale:
- No extra tap for current manual add flow.
- Discovery is one tap away from every existing add path.
- Action naming is explicit and consistent across platforms.

### Sheet Consistency (Pattern Reuse)
- Reuse the same sheet conventions already used by `ServerFormSheet`, `EnvironmentFormSheet`, and settings sheets.
- iOS requirements:
  - `NavigationStack` as sheet root.
  - grouped `Form`/`List` styling.
  - `.navigationBarTitleDisplayMode(.inline)`.
  - toolbar actions in standard placements (`.cancellationAction`, `.confirmationAction` where applicable).
  - helper/footer text in caption + secondary style.
- macOS requirements:
  - use existing modal shell patterns (`DialogSheetHeader`, divider, content, bottom action row) where applicable.
  - keep sizing in the same family as current add/edit server sheets (avoid introducing a new modal style).

### Discovery Sheet
- New cross-platform sheet: `LocalDeviceDiscoverySheet`.
- Presentation:
  - iOS: follow standard grouped sheet pattern used elsewhere in app.
  - macOS: modal sheet reusing existing VVTerm sheet container conventions.
- Sections:
1. `Nearby SSH Hosts` (live updating)
2. `Scanning Status` (Bonjour / Port scan progress)
3. `No Results Help` (tips and manual add fallback)

Device row content:
- Display name (Bonjour name or reverse-DNS hostname fallback).
- Host/IP.
- Port badge (usually `22`).
- Source badges: `Bonjour`, `Port Scan`.
- Optional latency text if available from probe.

Row actions:
- `Use` -> returns selection to `ServerFormSheet`.
- If opened from server list directly, `Use` opens `ServerFormSheet` with prefill.

### Permission and Failure UX
- Discovery starts only after user taps action.
- If local network permission is denied/restricted:
  - show inline explanation and `Open Settings` button (iOS).
  - keep manual add fallback button visible.
- If on non-LAN path (e.g. no Wi-Fi/ethernet), show empty guidance instead of scanning.
- Timeout behavior:
  - initial scan window: 6s
  - users can tap `Rescan`.

## Technical Design

### Discovery Sources (Combined)
Use two sources in parallel and merge results:

1. Bonjour browse
- Browse `_ssh._tcp` and `_sftp-ssh._tcp`.
- Fast and low-cost for hosts that advertise SSH.

2. Active SSH probe
- Derive current local IPv4 subnet from active interface (`getifaddrs`).
- Probe TCP port `22` with bounded concurrency and short timeout.
- Add host when TCP connect reaches `.ready`.

Why both:
- Bonjour alone misses many OpenSSH hosts.
- Port probing alone misses user-friendly hostnames.
- Combined gives higher hit rate with useful labels.

### Data Model
Create `VVTerm/Models/DiscoveredSSHHost.swift`:
- `struct DiscoveredSSHHost: Identifiable, Equatable, Hashable`
  - `id: String` (`host:port`)
  - `displayName: String`
  - `host: String`
  - `port: Int`
  - `sources: Set<DiscoverySource>`
  - `lastSeenAt: Date`
  - `latencyMs: Int?`
- `enum DiscoverySource { bonjour, portScan }`

### Services and Manager
Create `VVTerm/Services/Discovery/LocalSSHDiscoveryService.swift`:
- Owns scan tasks and cancellation.
- API:
  - `startScan() -> AsyncStream<DiscoveryEvent>`
  - `stopScan()`
  - `rescan()`

Create `VVTerm/Managers/LocalSSHDiscoveryManager.swift` (`@MainActor`, `ObservableObject`):
- Publishes `hosts`, `isScanning`, `scanState`, `permissionState`, `error`.
- Merges/deduplicates events by `host:port`.
- Handles max result cap and sorting.

### Scan Guardrails
- Run only while sheet is visible.
- Cancel all tasks when sheet closes.
- Concurrency cap for active probe: `24`.
- Probe timeout per host: `350ms` (retry once for likely packet loss).
- Host cap per scan:
  - If subnet is `/24` or smaller: scan full host range.
  - If larger than `/24`: scan only current `/24` slice containing device IP.
- Max surfaced results: `200`.

### Prefill Integration
Create lightweight prefill type:
- `ServerFormPrefill` with `name`, `host`, `port`, optional `username`.

Update `ServerFormSheet`:
- Add initializer argument `prefill: ServerFormPrefill? = nil`.
- Apply prefill for new server only (`server == nil`).
- Preserve current defaults for auth/session/environment sections.

### Integration Points
- `VVTerm/Views/iOS/iOSContentView.swift`
  - add discovery action in `+` menu
  - present `LocalDeviceDiscoverySheet`
- `VVTerm/Views/Sidebar/ServerSidebarView.swift`
  - add discover icon button + sheet presentation
- `VVTerm/Views/ServerDetail/ServerFormSheet.swift`
  - add `Pick from Local Discovery...` action
  - accept and apply `ServerFormPrefill`
- `VVTerm/VVTermApp.swift`
  - add macOS command and shortcut
- `VVTerm-iOS/Info.plist` and `VVTerm-macOS/Info.plist`
  - add `NSBonjourServices` entries:
    - `_ssh._tcp`
    - `_sftp-ssh._tcp`

## Privacy and Security
- Discovery results stay on-device and are not synced to CloudKit.
- No credentials are collected during discovery.
- Do not log full host lists; only aggregate counts and failure categories in logs.
- Keep `ServerManager` and Keychain flows unchanged for credential storage.
- Keep existing SSH trust/fingerprint pipeline unchanged.

## Testing Plan

### Unit Tests
- `LocalSSHDiscoveryManagerTests`
  - dedupe/merge behavior when same host appears from both sources
  - sorting stability
  - cancellation resets state correctly
- `SubnetProbeTests`
  - CIDR slicing and host enumeration guardrails
  - timeout/retry behavior
- `ServerFormPrefillTests`
  - prefill applies only for create flow, not edit flow

### UI Tests
- iOS: `+` menu shows `Discover Local Devices`.
- iOS/macOS: selecting discovered host opens prefilled `ServerFormSheet`.
- Permission denied state presents guidance and manual fallback.
- Rescan updates list without duplicate rows.

## Rollout
- Ship behind feature flag: `localSSHDiscoveryEnabled`.
- Enable for internal builds first.
- After validation, enable by default in next minor release.

## Open Questions
- Should V1 include optional custom port scan (e.g. 2222), or keep strictly port 22?
- Should `username` prefill use a global default (if later added in settings)?
- Should we persist "recent discovered hosts" locally for instant first paint on re-open?
