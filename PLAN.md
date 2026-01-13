# VivyTerm - Remote Server Manager

## Overview

VivyTerm is a cross-platform (iOS/macOS) terminal application for managing and connecting to remote servers (VPS, cloud instances, etc.) with seamless iCloud sync and Keychain-based credential storage.

## Target Versions

| Platform | Minimum | Recommended | Architecture |
|----------|---------|-------------|--------------|
| macOS | 13.0 (Ventura) | 26.0 (Tahoe) | arm64 only |
| iOS | 16.0 | 26.0 | arm64 only |
| Xcode | 26.0 | 26.0 | - |

### Why These Versions?

- **macOS 13.0+**: libghostty minimum (Metal renderer, AppKit stability)
- **iOS 16.0+**: All arm64 devices, stable Metal 3
- **arm64 only**: Metal GPU acceleration for libghostty terminal rendering
- **No x86_64**: Intel Macs have Metal GPU driver bugs, libghostty drops support

### Conditional Liquid Glass

```swift
// Liquid Glass only on iOS 26+ / macOS 26+
// Fallback to standard materials on older versions

extension View {
    @ViewBuilder
    func adaptiveGlass() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular.interactive())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func adaptiveGlassTint(_ color: Color) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular.tint(color).interactive())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(color, lineWidth: 1))
        }
    }
}

// Usage in views
Button("Connect") { connect() }
    .adaptiveGlassTint(.green)
```

### Version Feature Matrix

| Feature | iOS 16-25 | iOS 26+ | macOS 13-25 | macOS 26+ |
|---------|-----------|---------|-------------|-----------|
| Terminal (libghostty) | ✅ | ✅ | ✅ | ✅ |
| SSH connections | ✅ | ✅ | ✅ | ✅ |
| iCloud sync | ✅ | ✅ | ✅ | ✅ |
| Keychain | ✅ | ✅ | ✅ | ✅ |
| Liquid Glass | ❌ `.ultraThinMaterial` | ✅ `.glassEffect()` | ❌ `.ultraThinMaterial` | ✅ `.glassEffect()` |
| Glass morphing | ❌ | ✅ `glassEffectID` | ❌ | ✅ `glassEffectID` |
| Interactive glass | ❌ | ✅ `.interactive()` | ❌ | ✅ `.interactive()` |

## Core Features

1. **Server Management** - Add, edit, delete, organize servers
2. **SSH Connections** - Connect to servers via SSH with terminal emulator
3. **iCloud Sync** - Sync server configurations across all Apple devices
4. **Keychain Storage** - Secure credential storage (passwords, SSH keys, passphrases)
5. **Quick Connect** - Fast access to frequently used servers
6. **Voice-to-Command** - Speech-to-text for terminal input (MLX Whisper + System fallback)
7. **Workspaces** - Group servers by category (Production, Staging, Home Lab, etc.)
8. **Pro Tier** - Freemium model with $5.99 one-time purchase for unlimited servers/workspaces
9. **Settings & About** - Native settings window with transcription, appearance, terminal config

---

## UI Design (Liquid Glass)

### Design Philosophy

- Terminal content is the focus - glass floats above as navigation layer
- Never apply glass to terminal/content itself
- Use `GlassEffectContainer` to group related controls
- Interactive glass for buttons (`.interactive()`)
- Tinting only for semantic meaning (connected = green, error = red)

### iOS Layout

```
┌─────────────────────────────────────────┐
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  ← Status bar
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  🖥  Production Server          │    │  ← Server list
│  │     prod.example.com            │    │     (scrollable content)
│  └─────────────────────────────────┘    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  🧪  Staging                    │    │
│  │     staging.example.com         │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  🏠  Home Lab                   │    │
│  │     192.168.1.100               │    │
│  └─────────────────────────────────┘    │
│                                         │
│                                         │
│                                         │
├─────────────────────────────────────────┤
│  ╭───────────────────────────────────╮  │  ← Liquid Glass Tab Bar
│  │  🖥️ Servers    ⚙️ Settings        │  │     (shrinks on scroll)
│  ╰───────────────────────────────────╯  │
└─────────────────────────────────────────┘
```

### iOS Terminal View

```
┌─────────────────────────────────────────┐
│  ╭─────────────────────────────────╮    │  ← Liquid Glass Toolbar
│  │  ← Back    prod.example.com  ⋯  │    │     (floats above terminal)
│  ╰─────────────────────────────────╯    │
├─────────────────────────────────────────┤
│ root@prod:~# ls -la                     │
│ total 48                                │  ← Terminal content
│ drwxr-xr-x  5 root root 4096 Jan 5      │     (libghostty, full screen)
│ -rw-r--r--  1 root root  220 Jan 5      │
│ root@prod:~# _                          │
│                                         │
│                                         │
│                                         │
│                                         │
│                                         │
│                                         │
├─────────────────────────────────────────┤
│  ╭─────────────────────────────────╮    │  ← Liquid Glass Keyboard Toolbar
│  │ Esc  Tab  Ctrl  ↑  ↓  ←  →  ⌘  │    │     (.interactive() buttons)
│  ╰─────────────────────────────────╯    │
│  ┌─────────────────────────────────┐    │
│  │         iOS Keyboard            │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

### macOS Layout (Left Sidebar + Right Panel with Toolbar Tabs)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ● ● ●                         VivyTerm                                      │
├───────────────────────┬──────────────────────────────────────────────────────┤
│                       │  ◀ ▶  ✕ 🖥 prod  ✕ 🖥 db  ✕ 🖥 cache  +      ⋯     │ ← Toolbar (tabs)
│  🔵 Acme Corp      ▼  ├──────────────────────────────────────────────────────┤
│  ─────────────────    │                                                      │
│  🔍 Search...         │  root@prod:~# systemctl status nginx                 │
│  ─────────────────    │  ● nginx.service - A high performance...             │
│  SERVERS   🔴 Prod ▼  │    Loaded: loaded (/lib/systemd/system/...)          │
│  ─────────────────    │    Active: active (running) since Mon...             │
│    🟢 api             │  root@prod:~# _                                      │
│    🟢 db              │                                                      │
│    🟢 cache           │                                                      │
│    🟢 redis           │                                                      │
│                       │                                                      │
│                       │                                                      │
│                       │                                                      │
│                       │                                                      │
├───────────────────────┤                                                      │
│  +  Add Server  💬  ⚙️ │                                                      │
└───────────────────────┴──────────────────────────────────────────────────────┘
          ↑                                        ↑
    LEFT SIDEBAR                            RIGHT PANEL
    - Workspace dropdown (project/client)   - Toolbar with connection tabs
    - Search field                          - Terminal content below
    - Environment menu (compact dropdown)
    - Server list filtered by environment
    - Footer: Add, Chat, Settings
```

### Toolbar Style

```swift
// Always use unified toolbar style for consistent macOS look
.windowToolbarStyle(.unified)

// In main window scene
WindowGroup {
    ContentView()
}
.windowToolbarStyle(.unified)
```

### View Switcher (Stats | Terminal)

Like aizen, we have a Picker in the toolbar to switch between views:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ● ● ●                         VivyTerm                                      │
├───────────────────────┬──────────────────────────────────────────────────────┤
│                       │  [📊 Stats | 🖥 Terminal]  ◀ ▶ ✕ prod ✕ db  +    ⋯  │ ← View Picker + Tabs
│  🔵 Acme Corp      ▼  ├──────────────────────────────────────────────────────┤
│  ─────────────────    │                                                      │
│  🔍 Search...         │  ┌────────────────────────────────────────────────┐  │
│  ─────────────────    │  │           SERVER STATISTICS                   │  │
│  SERVERS   🔴 Prod ▼  │  │                                                │  │
│  ─────────────────    │  │  CPU ████████░░░░░░░░░░ 42%    Memory 6.2/8GB │  │
│    🟢 api             │  │  ┌──────────────────────────────────────────┐  │  │
│    🟢 db              │  │  │     CPU Usage (24h)                      │  │  │
│    🟢 cache           │  │  │  ╱╲    ╱╲                               │  │  │
│    🟢 redis           │  │  │ ╱  ╲╱╱  ╲____╱╲___                      │  │  │
│                       │  │  └──────────────────────────────────────────┘  │  │
│                       │  │                                                │  │
│                       │  │  Disk  ███████████████░░░░░ 78%   Network ↑↓  │  │
│                       │  │  120GB / 160GB                  23 MB/s       │  │
│                       │  └────────────────────────────────────────────────┘  │
├───────────────────────┤                                                      │
│  +  Add Server  💬  ⚙️ │                                                      │
└───────────────────────┴──────────────────────────────────────────────────────┘
```

---

## Server Statistics View

### Purpose

When connecting to a server, show real-time statistics before/alongside terminal:
- Quick overview of server health
- Identify issues before running commands
- Beautiful graphs for monitoring

### Metrics to Display

| Metric | Source | Update Interval |
|--------|--------|-----------------|
| CPU Usage | `/proc/stat` or `top` | 2s |
| Memory | `/proc/meminfo` or `free` | 2s |
| Disk Usage | `df -h` | 30s |
| Network I/O | `/proc/net/dev` or `ifstat` | 2s |
| Load Average | `/proc/loadavg` or `uptime` | 5s |
| Uptime | `/proc/uptime` or `uptime` | 60s |
| Process Count | `/proc` count or `ps aux` | 10s |
| Top Processes | `ps aux --sort=-%cpu` | 5s |

### Data Collection

```swift
// Stats collector runs commands over SSH and parses output
actor ServerStatsCollector {
    private let sshClient: SSHClient
    private var isCollecting = false

    struct ServerStats {
        var cpuUsage: Double           // 0-100%
        var memoryUsed: UInt64         // bytes
        var memoryTotal: UInt64        // bytes
        var diskUsed: UInt64           // bytes
        var diskTotal: UInt64          // bytes
        var networkRx: UInt64          // bytes/sec
        var networkTx: UInt64          // bytes/sec
        var loadAverage: (Double, Double, Double)  // 1m, 5m, 15m
        var uptime: TimeInterval       // seconds
        var processCount: Int
        var topProcesses: [ProcessInfo]
        var timestamp: Date
    }

    struct ProcessInfo {
        let pid: Int
        let name: String
        let cpuPercent: Double
        let memoryPercent: Double
    }

    func startCollecting() -> AsyncStream<ServerStats>
    func stopCollecting()

    // Parse Linux /proc filesystem
    private func parseProcStat(_ output: String) -> Double
    private func parseProcMeminfo(_ output: String) -> (used: UInt64, total: UInt64)
    private func parseDf(_ output: String) -> (used: UInt64, total: UInt64)
    private func parseProcNetDev(_ output: String) -> (rx: UInt64, tx: UInt64)
}
```

### UI Components

```swift
// View picker in toolbar (like aizen's TabItem)
struct ConnectionViewTab: Identifiable, Hashable {
    let id: String
    let localizedKey: String
    let icon: String

    static let stats = ConnectionViewTab(id: "stats", localizedKey: "connection.view.stats", icon: "chart.bar.xaxis")
    static let terminal = ConnectionViewTab(id: "terminal", localizedKey: "connection.view.terminal", icon: "terminal")

    static let allTabs: [ConnectionViewTab] = [.stats, .terminal]
}

// Main connection view with picker
struct ServerConnectionView: View {
    let server: Server
    @State private var selectedView: String = "stats"  // Default to stats

    var body: some View {
        Group {
            switch selectedView {
            case "stats":
                ServerStatsView(server: server)
            case "terminal":
                ConnectionTerminalContainer(...)
            default:
                EmptyView()
            }
        }
        .toolbar {
            // View picker
            ToolbarItem(placement: .automatic) {
                Picker("View", selection: $selectedView) {
                    ForEach(ConnectionViewTab.allTabs) { tab in
                        Label(LocalizedStringKey(tab.localizedKey), systemImage: tab.icon)
                            .tag(tab.id)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Connection tabs
            ToolbarItem(placement: .automatic) {
                ConnectionTabsScrollView(...)
            }
        }
        .windowToolbarStyle(.unified)
    }
}
```

### Stats View Layout

```swift
struct ServerStatsView: View {
    let server: Server
    @StateObject private var statsCollector: ServerStatsCollector

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Quick stats row
                HStack(spacing: 16) {
                    QuickStatCard(
                        title: "CPU",
                        value: "\(Int(stats.cpuUsage))%",
                        icon: "cpu",
                        color: cpuColor
                    )
                    QuickStatCard(
                        title: "Memory",
                        value: "\(formatBytes(stats.memoryUsed))/\(formatBytes(stats.memoryTotal))",
                        icon: "memorychip",
                        color: memoryColor
                    )
                    QuickStatCard(
                        title: "Disk",
                        value: "\(Int(diskPercent))%",
                        icon: "internaldrive",
                        color: diskColor
                    )
                    QuickStatCard(
                        title: "Network",
                        value: "↑\(formatSpeed(stats.networkTx)) ↓\(formatSpeed(stats.networkRx))",
                        icon: "network",
                        color: .blue
                    )
                }

                // CPU Graph (sparkline or full chart)
                ChartCard(title: "CPU Usage") {
                    Chart(cpuHistory) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Usage", point.value)
                        )
                        .foregroundStyle(.blue.gradient)
                    }
                    .chartYScale(domain: 0...100)
                }

                // Memory Graph
                ChartCard(title: "Memory Usage") {
                    Chart(memoryHistory) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Used", point.value)
                        )
                        .foregroundStyle(.green.gradient.opacity(0.3))
                    }
                }

                // Top Processes
                ProcessListCard(processes: stats.topProcesses)

                // System Info
                SystemInfoCard(
                    uptime: stats.uptime,
                    loadAverage: stats.loadAverage,
                    processCount: stats.processCount
                )
            }
            .padding()
        }
    }
}
```

### Folder Structure

```
Views/Stats/
├── ServerStatsView.swift           # Main stats container
├── QuickStatCard.swift             # CPU/Memory/Disk/Network cards
├── ChartCard.swift                 # Reusable chart container
├── ProcessListCard.swift           # Top processes table
├── SystemInfoCard.swift            # Uptime, load, etc.
└── ConnectionViewTab.swift         # View picker model

Services/Stats/
├── ServerStatsCollector.swift      # SSH-based stats collection
├── StatsParser.swift               # Parse /proc, df, etc.
└── StatsHistory.swift              # Time-series data storage
```

### Charts Library

Use Swift Charts (iOS 16+ / macOS 13+):

```swift
import Charts

// CPU sparkline
Chart(cpuHistory) { point in
    LineMark(
        x: .value("Time", point.timestamp),
        y: .value("CPU", point.value)
    )
}
.chartXAxis(.hidden)
.chartYAxis(.hidden)
.frame(height: 50)
```

### Toolbar Tab Bar Features (macOS)

- **Multiple connections** - Connect to several servers simultaneously
- **Tab navigation** - ◀ ▶ arrows to cycle through tabs
- **Close button** - ✕ on each tab (with confirmation if process running)
- **New tab** - + button to connect to another server
- **Context menu** - Right-click for "Close", "Close Others", "Close All to Left/Right"
- **Drag to reorder** - Rearrange tabs
- **Keyboard shortcuts** - ⌘1-9 to switch tabs, ⌘W to close, ⌘T for new

### Server Form (Add/Edit) - Sheet

```
┌─────────────────────────────────────────┐
│  ╭─────────────────────────────────╮    │  ← Liquid Glass Header
│  │  Cancel    Add Server    Save   │    │
│  ╰─────────────────────────────────╯    │
├─────────────────────────────────────────┤
│                                         │
│  Name                                   │
│  ┌─────────────────────────────────┐    │
│  │ Production Server               │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Host                                   │
│  ┌─────────────────────────────────┐    │
│  │ prod.example.com                │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Port                                   │
│  ┌─────────────────────────────────┐    │
│  │ 22                              │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Username                               │
│  ┌─────────────────────────────────┐    │
│  │ root                            │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Authentication                         │
│  ╭─────────────────────────────────╮    │  ← Liquid Glass Segmented
│  │ Password │ SSH Key │ Key+Pass  │    │     Control
│  ╰─────────────────────────────────╯    │
│                                         │
│  Password                               │
│  ┌─────────────────────────────────┐    │
│  │ ••••••••••••                    │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Group                                  │
│  ╭─────────────────────────────────╮    │
│  │ Production                   ▼  │    │
│  ╰─────────────────────────────────╯    │
│                                         │
└─────────────────────────────────────────┘
```

### Quick Connect (macOS Menu Bar)

```
        ┌─────────────────────────┐
        │  ╭───────────────────╮  │  ← Liquid Glass Menu
        │  │   🖥️  VivyTerm    │  │
        │  ╰───────────────────╯  │
        ├─────────────────────────┤
        │  Recent                 │
        │  ├─ 🟢 prod.example.com │
        │  ├─ 🟡 staging          │
        │  └─ 🟢 home-nas         │
        ├─────────────────────────┤
        │  All Servers →          │
        │  Settings...            │
        │  ──────────────         │
        │  Quit VivyTerm          │
        └─────────────────────────┘
```

---

## Liquid Glass API Reference

### Core Modifiers

```swift
// Basic glass effect
.glassEffect()
.glassEffect(.regular)
.glassEffect(.clear)        // For media-rich backgrounds
.glassEffect(.identity)     // Disable (for accessibility)

// With shape
.glassEffect(.regular, in: .capsule)
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
.glassEffect(.regular, in: .rect(cornerRadius: .containerConcentric))

// With tint (semantic only)
.glassEffect(.regular.tint(.green))     // Connected
.glassEffect(.regular.tint(.red))       // Error
.glassEffect(.regular.tint(.orange))    // Warning

// Interactive (iOS only - press effects)
.glassEffect(.regular.interactive())
```

### Grouping & Morphing

```swift
// Group glass elements (unified sampling)
GlassEffectContainer(spacing: 20) {
    Button("Esc") { sendKey(.escape) }
        .glassEffect(.regular.interactive())
    Button("Tab") { sendKey(.tab) }
        .glassEffect(.regular.interactive())
    Button("Ctrl") { toggleCtrl() }
        .glassEffect(.regular.interactive())
}

// Morphing transitions
@Namespace private var glassNamespace

GlassEffectContainer {
    if isConnected {
        Button("Disconnect") { disconnect() }
            .glassEffect(.regular.tint(.red).interactive())
            .glassEffectID("connection", in: glassNamespace)
    } else {
        Button("Connect") { connect() }
            .glassEffect(.regular.tint(.green).interactive())
            .glassEffectID("connection", in: glassNamespace)
    }
}
```

### Guidelines

| Do | Don't |
|----|-------|
| Apply glass to navigation/toolbars | Apply glass to content (terminal, lists) |
| Use `GlassEffectContainer` for grouped controls | Have glass elements sample other glass |
| Use `.interactive()` for buttons | Use tints for decoration |
| Use tints for semantic meaning | Overuse tints (one per view max) |
| Support accessibility (reduce transparency) | Ignore reduced motion settings |

### Accessibility Support

```swift
@Environment(\.accessibilityReduceTransparency) var reduceTransparency

// Auto-adapts: increased frosting, stark borders
.glassEffect(reduceTransparency ? .identity : .regular)
```

---

## Tabs (Multiple Connections)

### Purpose

Connect to multiple servers simultaneously in tabs, similar to browser tabs or terminal multiplexers.

### Data Model

```swift
// Connection/Tab session (not synced - local only)
struct ConnectionSession: Identifiable {
    let id: UUID
    let serverId: UUID              // Reference to server
    var title: String               // Tab title (server name or custom)
    var isConnected: Bool
    var createdAt: Date
    var lastActivity: Date

    // Terminal state (managed by libghostty)
    var terminalSurfaceId: String?
}
```

### Toolbar Tab Bar UI (macOS)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│  ● ● ●  │  ◀ ▶  ✕ 🖥 prod  ✕ 🖥 staging  ✕ 🖥 nas  +           │  ⋯  │  ← Toolbar
└────────────────────────────────────────────────────────────────────────────────┘
   ↑  ↑         ↑              ↑                        ↑             ↑
 Window Nav    Active      Inactive tabs            New tab       Menu
 controls      tab                                              (settings, etc)
```

The tabs are placed inside the toolbar using SwiftUI's `.toolbar { }` modifier with `ToolbarItem(placement: .automatic)`, exactly like aizen's `WorktreeDetailView` implementation.

### Tab Bar UI (iOS - Horizontal Scroll)

```
┌─────────────────────────────────────────┐
│  ╭─────────────────────────────────╮    │
│  │  ← Back    3 connections    +   │    │  ← Glass Header with count
│  ╰─────────────────────────────────╯    │
├─────────────────────────────────────────┤
│  ┌────────┐ ┌────────┐ ┌────────┐       │  ← Horizontal scroll tabs
│  │  prod  │ │staging │ │  nas   │  ...  │
│  │   🟢   │ │   🟢   │ │   🟢   │       │
│  └────────┘ └────────┘ └────────┘       │
├─────────────────────────────────────────┤
│                                         │
│  Terminal content here                  │
│                                         │
└─────────────────────────────────────────┘
```

### Implementation (Toolbar Integration - from Aizen)

```swift
// Main container view with toolbar tabs
struct ServerConnectionView: View {
    @ObservedObject var server: Server
    @Binding var selectedSessionId: UUID?
    let sessions: [ConnectionSession]

    var body: some View {
        ConnectionTerminalContainer(
            sessions: sessions,
            selectedSessionId: selectedSessionId
        )
        .toolbar {
            sessionToolbarItems
        }
    }

    // Tabs live in the toolbar (like aizen's WorktreeDetailView)
    @ToolbarContentBuilder
    var sessionToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            ConnectionTabsScrollView(
                sessions: sessions,
                selectedSessionId: $selectedSessionId,
                onClose: { session in closeSession(session) },
                onNew: { createNewSession() }
            )
        }
    }
}

// Tab bar component (placed in toolbar via ToolbarItem)
struct ConnectionTabsScrollView: View {
    let sessions: [ConnectionSession]
    @Binding var selectedSessionId: UUID?
    let onClose: (ConnectionSession) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Navigation arrows
            NavigationArrowButton(icon: "chevron.left", action: selectPrevious)
            NavigationArrowButton(icon: "chevron.right", action: selectNext)

            // Tabs scroll view
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessions) { session in
                        ConnectionTabButton(
                            session: session,
                            isSelected: selectedSessionId == session.id,
                            onSelect: { selectedSessionId = session.id },
                            onClose: { onClose(session) }
                        )
                        .contextMenu { tabContextMenu(session) }
                    }
                }
            }

            // New tab button
            Button(action: onNew) {
                Image(systemName: "plus")
            }
        }
    }
}

// Keep all terminals alive (opacity switch, not conditional)
struct ConnectionTerminalContainer: View {
    let sessions: [ConnectionSession]
    let selectedSessionId: UUID?

    var body: some View {
        ZStack {
            ForEach(sessions) { session in
                let isSelected = selectedSessionId == session.id
                TerminalView(session: session)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
            }
        }
    }
}
```

### Keyboard Shortcuts (macOS)

| Shortcut | Action |
|----------|--------|
| ⌘T | New tab (connect to server) |
| ⌘W | Close current tab |
| ⌘1-9 | Switch to tab 1-9 |
| ⌃Tab | Next tab |
| ⌃⇧Tab | Previous tab |
| ⌘⇧] | Next tab |
| ⌘⇧[ | Previous tab |

### Context Menu

```
┌─────────────────────────┐
│ Close Tab               │
│ ───────────────────     │
│ Close All to the Left   │
│ Close All to the Right  │
│ Close Other Tabs        │
│ ───────────────────     │
│ Duplicate Tab           │
│ Rename Tab...           │
└─────────────────────────┘
```

### Folder Structure

```
Views/Tabs/
├── ConnectionTabsScrollView.swift    # Tab bar (placed in toolbar via ToolbarItem)
├── ConnectionTabButton.swift         # Individual tab button
├── ConnectionTerminalContainer.swift # ZStack of terminals (opacity switching)
└── NavigationArrowButton.swift       # ◀ ▶ navigation buttons

Views/Server/
└── ServerConnectionView.swift        # Main view with .toolbar { sessionToolbarItems }

Managers/
└── ConnectionSessionManager.swift    # Tab/session lifecycle
```

---

## Workspaces & Environments

### Concept

**Workspace** = Project or client grouping (Acme Corp, Personal, Home Lab)
**Environment** = Deployment stage filter within workspace (Production, Staging, Development)

This allows you to:
- Group all servers for a client/project in one workspace
- Quickly switch between Production/Staging/Dev environments
- See only relevant servers for current context

### Data Model

```swift
// Workspace entity (CloudKit synced)
struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String              // "Acme Corp", "Personal", "Home Lab"
    var colorHex: String          // Visual identity (#FF5733)
    var icon: String?             // SF Symbol name
    var order: Int                // Sort order
    var environments: [Environment] // Available environments for this workspace
    var lastSelectedEnvironment: Environment?
    var lastSelectedServerId: UUID?
    var createdAt: Date
    var updatedAt: Date
}

// Environment - prebuilt + custom (Pro only)
struct Environment: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var shortName: String
    var colorHex: String
    var isBuiltIn: Bool           // true = prebuilt, false = custom (Pro)

    var color: Color {
        Color(hex: colorHex)
    }

    // Prebuilt environments (available to all users)
    static let production = Environment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Production", shortName: "Prod", colorHex: "#FF3B30", isBuiltIn: true
    )
    static let staging = Environment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Staging", shortName: "Stag", colorHex: "#FF9500", isBuiltIn: true
    )
    static let development = Environment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Development", shortName: "Dev", colorHex: "#007AFF", isBuiltIn: true
    )

    static let builtInEnvironments: [Environment] = [.production, .staging, .development]
}

// Note: Use Environment? where nil = "All" filter (show all servers)

// Server belongs to workspace + tagged with environment
struct Server: Identifiable, Codable {
    let id: UUID
    var workspaceId: UUID         // Parent workspace
    var environment: Environment  // Which environment (prod/staging/dev)
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    // ...
}
```

### Hierarchy

```
Workspace: Acme Corp
├── Environment: Production
│   ├── Server (api.acme.com)
│   ├── Server (db.acme.com)
│   └── Server (cache.acme.com)
├── Environment: Staging
│   ├── Server (staging-api.acme.com)
│   └── Server (staging-db.acme.com)
└── Environment: Development
    └── Server (dev.acme.local)

Workspace: Home Lab
├── Environment: Production (main)
│   ├── Server (nas.local)
│   ├── Server (proxmox.local)
│   └── Server (pi.local)
└── Environment: Development (testing)
    └── Server (test-vm.local)
```

### UI Components

```
Sidebar with Workspace + Environment:
┌─────────────────────────┐
│ ╭─────────────────────╮ │  ← Workspace Dropdown
│ │ 🔵 Acme Corp      ▼ │ │
│ ╰─────────────────────╯ │
├─────────────────────────┤
│  SERVERS                │
│  🔴 Production       ▼  │  ← Environment Menu (compact)
│  ─────────────────────  │
│    🟢 api               │
│    🟢 db                │
│    🟢 cache             │
│    🟢 redis             │
│                         │
│                         │
│                         │
├─────────────────────────┤
│ ✨ Upgrade to Pro -     │  ← Upgrade Banner (if not Pro)
│    Support VivyTerm     │     Opens ProUpgradeSheet
├─────────────────────────┤
│  +    💬    ⚙️          │  ← Footer: Add, Chat, Settings
└─────────────────────────┘

Environment Menu (dropdown on click):
┌─────────────────────────┐
│  ✓ 🔴 Production   (4)  │  ← Current
│    🟠 Staging      (2)  │
│    🔵 Development  (1)  │
│  ─────────────────────  │
│    ⚪ All          (7)  │
│  ─────────────────────  │
│  + Custom...       ⭐   │  ← Pro only (shows paywall if free)
└─────────────────────────┘

Workspace Switcher Popup:
┌─────────────────────────┐
│  🔵 Acme Corp (8)       │  ← Current
│  🟣 StartupX (4)        │
│  🟢 Home Lab (6)        │
│  ⚪ Personal (2)        │
├─────────────────────────┤
│  + New Workspace        │
│  ⚙️ Manage Workspaces   │
└─────────────────────────┘
```

### Environment Selector Options

**Option A: Inline Menu (Recommended)**
- Compact dropdown next to "SERVERS" header
- Shows current environment with color dot
- Click to open menu with all options

**Option B: Filter Pills**
- Small toggleable pills below header
- Can show multiple or single selection

**Option C: Section Groups**
- Group servers by environment in collapsible sections
- No explicit filter, just expand/collapse

### Environment Menu Implementation

```swift
// Compact environment menu (inline with section header)
struct EnvironmentMenu: View {
    @Binding var selected: Environment?
    let environments: [Environment]       // Built-in + custom
    let serverCounts: [UUID: Int]         // Count per environment ID
    let onCreateCustom: () -> Void

    @ObservedObject private var storeManager = StoreManager.shared
    @State private var showingProUpgrade = false

    private var totalCount: Int {
        serverCounts.values.reduce(0, +)
    }

    var body: some View {
        Menu {
            // Built-in environments
            ForEach(Environment.builtInEnvironments) { env in
                environmentButton(env)
            }

            // Custom environments (Pro users only see these)
            let customEnvs = environments.filter { !$0.isBuiltIn }
            if !customEnvs.isEmpty {
                Divider()
                ForEach(customEnvs) { env in
                    environmentButton(env)
                }
            }

            Divider()

            // All filter
            Button {
                selected = nil  // nil = show all
            } label: {
                HStack {
                    Text("All")
                    Spacer()
                    Text("(\(totalCount))")
                        .foregroundStyle(.secondary)
                    if selected == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Create custom (Pro only)
            Button {
                if storeManager.isPro {
                    onCreateCustom()
                } else {
                    showingProUpgrade = true
                }
            } label: {
                HStack {
                    Label("Custom...", systemImage: "plus")
                    Spacer()
                    if !storeManager.isPro {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(selected?.shortName ?? "All")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeSheet()
        }
    }

    private func environmentButton(_ env: Environment) -> some View {
        Button {
            selected = env
        } label: {
            HStack {
                Circle()
                    .fill(env.color)
                    .frame(width: 8, height: 8)
                Text(env.name)
                Spacer()
                Text("(\(serverCounts[env.id] ?? 0))")
                    .foregroundStyle(.secondary)
                if selected?.id == env.id {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

// Filter servers by environment (nil = show all)
extension ServerManager {
    func servers(in workspace: Workspace, environment: Environment?) -> [Server] {
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }

        guard let env = environment else {
            return workspaceServers  // nil = show all
        }
        return workspaceServers.filter { $0.environment.id == env.id }
    }
}
```

### Sidebar Implementation (from Aizen patterns)

```swift
// Main layout with NavigationSplitView
struct ContentView: View {
    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: Environment?  // nil = show all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // LEFT: Sidebar with workspace + servers
            ServerSidebarView(
                selectedWorkspace: $selectedWorkspace,
                selectedServer: $selectedServer,
                selectedEnvironment: $selectedEnvironment
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            // RIGHT: Terminal with toolbar tabs
            if let server = selectedServer {
                ServerConnectionView(server: server)
            } else {
                ContentUnavailableView(
                    "Select a Server",
                    systemImage: "server.rack",
                    description: Text("Choose a server from the sidebar to connect")
                )
            }
        }
        .windowToolbarStyle(.unified)  // Always use unified toolbar
    }
}

// Sidebar structure (mirrors aizen's WorkspaceSidebarView)
struct ServerSidebarView: View {
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedServer: Server?
    @Binding var selectedEnvironment: Environment?  // nil = show all
    @State private var showingWorkspaceSwitcher = false
    @State private var showingProUpgrade = false
    @State private var showingAddServer = false
    @State private var showingSupportSheet = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // 1. Workspace Section Header
            VStack(alignment: .leading, spacing: 8) {
                Text("WORKSPACE")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 12)

                // Current workspace button (opens switcher)
                Button {
                    showingWorkspaceSwitcher = true
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: selectedWorkspace?.colorHex ?? "#007AFF"))
                            .frame(width: 8, height: 8)

                        Text(selectedWorkspace?.name ?? "Select Workspace")
                            .font(.body)
                            .fontWeight(.semibold)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        // Server count pill
                        PillBadge(text: "\(serverCount)", color: .secondary)

                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // 2. Search Field
            SearchField(placeholder: "Search servers...", text: $searchText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // 3. Server List with Environment Header
            VStack(alignment: .leading, spacing: 0) {
                // Section header with environment menu
                HStack {
                    Text("SERVERS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer()

                    // Compact environment menu
                    EnvironmentMenu(
                        selected: $selectedEnvironment,
                        serverCounts: serverCountsByEnvironment
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // Server list
                List {
                    ForEach(filteredServers, id: \.id) { server in
                        ServerRow(
                            server: server,
                            isSelected: selectedServer?.id == server.id,
                            onSelect: { selectedServer = server }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider()

            // 4. Upgrade Banner (only when not Pro)
            if !StoreManager.shared.isPro {
                Button {
                    showingProUpgrade = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("Upgrade to Pro - Support VivyTerm")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08))
            }

            // 5. Footer Buttons (Add, Chat, Settings - like aizen)
            HStack(spacing: 0) {
                Button {
                    showingAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Spacer()

                Button {
                    showingSupportSheet = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .help("Support & Feedback")

                Button {
                    SettingsWindowManager.shared.show()
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help("Settings")
            }
            .background(Color.primary.opacity(0.04))
        }
        .sheet(isPresented: $showingWorkspaceSwitcher) {
            WorkspaceSwitcherSheet(
                selectedWorkspace: $selectedWorkspace
            )
        }
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeSheet()
        }
        .sheet(isPresented: $showingAddServer) {
            ServerFormSheet(mode: .add)
        }
        .sheet(isPresented: $showingSupportSheet) {
            SupportSheet()
        }
    }
}

// Server row with selection background
struct ServerRow: View {
    let server: Server
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(server.isConnected ? .green : .secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? .accent : .primary)
                    .lineLimit(1)

                Text(server.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(selectionBackground)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Connect") { /* ... */ }
            Button("Edit") { /* ... */ }
            Divider()
            Button("Remove", role: .destructive) { /* ... */ }
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.15))
        }
    }
}
```

### Folder Structure

```
Views/Sidebar/
├── ServerSidebarView.swift         # Main sidebar container (macOS)
├── ServerRow.swift                 # Server list row with selection
├── EnvironmentMenu.swift           # Compact environment dropdown menu
├── SearchField.swift               # Search input (from aizen)
└── PillBadge.swift                 # Count badge (from aizen)

Views/Workspace/
├── WorkspaceSwitcherSheet.swift    # Workspace popup switcher
├── WorkspaceCreateSheet.swift      # Create modal
├── WorkspaceEditSheet.swift        # Edit modal
└── WorkspaceNameGenerator.swift    # Random name generator

Views/Server/
├── ServerConnectionView.swift      # Main view with toolbar tabs
├── ServerFormSheet.swift           # Add/edit server form
└── ServerDetailView.swift          # Server info panel

Views/Support/
└── SupportSheet.swift              # Support & feedback sheet (from aizen)
```

### Color Palette

```swift
let workspaceColors: [String] = [
    "#007AFF", // Blue (default)
    "#AF52DE", // Purple
    "#FF2D55", // Pink
    "#FF3B30", // Red
    "#FF9500", // Orange
    "#FFCC00", // Yellow
    "#34C759", // Green
    "#5AC8FA", // Teal
    "#00C7BE", // Cyan
    "#5856D6"  // Indigo
]
```

---

## Payments (StoreKit 2)

### Freemium Model

| Tier | Price | Billing | Limits |
|------|-------|---------|--------|
| **Free** | $0 | - | 1 workspace, 3 servers, 1 tab |
| **Pro Monthly** | $6.49 | /month | Unlimited |
| **Pro Yearly** | $19.99 | /year (save 74%) | Unlimited |
| **Pro Lifetime** | $29.99 | once | Unlimited forever |

### Free vs Pro Comparison

| Feature | Free | Pro |
|---------|------|-----|
| Workspaces | 1 | Unlimited |
| Servers | 3 | Unlimited |
| Simultaneous connections (tabs) | 1 | Unlimited |
| Environments | 3 built-in (Prod/Stag/Dev) | Unlimited custom |
| iCloud sync | ✅ | ✅ |
| Voice-to-command | ✅ | ✅ |
| All terminal themes | ✅ | ✅ |

### Product Configuration

```swift
// Product IDs for App Store Connect
struct VivyTermProducts {
    // Auto-renewable subscriptions (same group)
    static let proMonthly = "com.vivy.vivyterm.pro.monthly"
    static let proYearly = "com.vivy.vivyterm.pro.yearly"

    // Non-consumable (one-time)
    static let proLifetime = "com.vivy.vivyterm.pro.lifetime"

    static let subscriptionGroupId = "vivyterm_pro"
    static let allProducts = [proMonthly, proYearly, proLifetime]
}
```

### StoreKit 2 Implementation

```swift
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published var isPro: Bool = false
    @Published var isLifetime: Bool = false
    @Published var subscriptionStatus: Product.SubscriptionInfo.Status?
    @Published var products: [Product] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var isLoading: Bool = false

    private var updateListenerTask: Task<Void, Error>?

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case purchased
        case failed(String)
    }

    // Sorted products for display
    var monthlyProduct: Product? { products.first { $0.id == VivyTermProducts.proMonthly } }
    var yearlyProduct: Product? { products.first { $0.id == VivyTermProducts.proYearly } }
    var lifetimeProduct: Product? { products.first { $0.id == VivyTermProducts.proLifetime } }

    init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await checkEntitlements()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // Load all products from App Store
    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            products = try await Product.products(for: VivyTermProducts.allProducts)
        } catch {
            print("Failed to load products: \(error)")
        }
    }

    // Purchase any product
    func purchase(_ product: Product) async {
        purchaseState = .purchasing

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
                purchaseState = .purchased
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // Restore purchases
    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        try? await AppStore.sync()
        await checkEntitlements()
    }

    // Check current entitlements (subscriptions + lifetime)
    func checkEntitlements() async {
        var hasAccess = false
        var hasLifetime = false

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                // Skip revoked transactions
                if transaction.revocationDate != nil {
                    continue
                }

                switch transaction.productID {
                case VivyTermProducts.proMonthly,
                     VivyTermProducts.proYearly:
                    hasAccess = true
                case VivyTermProducts.proLifetime:
                    hasAccess = true
                    hasLifetime = true
                default:
                    break
                }
            }
        }

        isPro = hasAccess
        isLifetime = hasLifetime

        // Get subscription group status properly
        await updateSubscriptionStatus()
    }

    // Get subscription status from the subscription group
    private func updateSubscriptionStatus() async {
        do {
            let statuses = try await Product.SubscriptionInfo.status(
                for: VivyTermProducts.subscriptionGroupId
            )
            // Find active subscription (subscribed or in grace period)
            subscriptionStatus = statuses.first { status in
                switch status.state {
                case .subscribed, .inGracePeriod:
                    return true
                default:
                    return false
                }
            }
        } catch {
            // No active subscription or error fetching
            subscriptionStatus = nil
        }
    }

    // Listen for transaction updates
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await self.checkEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }
}

enum StoreError: Error, LocalizedError {
    case verificationFailed
    case purchaseFailed(String)

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "Transaction verification failed"
        case .purchaseFailed(let reason):
            return "Purchase failed: \(reason)"
        }
    }
}
```

### Paywall UI (Two-Step Flow)

**Step 1: Features Sheet**
```
┌─────────────────────────────────────────┐
│  Upgrade                        Cancel  │
│                                         │
│              ⭐ (yellow star)           │
│                                         │
│            VivyTerm Pro                 │
│   Unlock unlimited servers & workspaces │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │ 🗂  Unlimited Servers            │    │
│  │     Connect to as many servers   │    │
│  │     as you need                  │    │
│  │                                  │    │
│  │ 📁 Unlimited Workspaces          │    │
│  │     Organize servers into        │    │
│  │     unlimited workspaces         │    │
│  │                                  │    │
│  │ 📑 Multiple Tabs                 │    │
│  │     Connect to multiple servers  │    │
│  │     simultaneously               │    │
│  │                                  │    │
│  │ 🔧 Custom Environments           │    │
│  │     Create custom environments   │    │
│  │     beyond Prod/Staging/Dev      │    │
│  │                                  │    │
│  │ ☁️  iCloud Sync                  │    │
│  │     Sync servers across all      │    │
│  │     your Apple devices           │    │
│  │                                  │    │
│  │ ⭐ All Future Features           │    │
│  │     Get access to all new        │    │
│  │     features                     │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ╭─────────────────────────────────╮    │  ← Coral/salmon button
│  │         Select a Plan           │    │
│  ╰─────────────────────────────────╯    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │       Restore Purchases         │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Cancel anytime. Subscription auto-     │
│  renews. Terms of Service • Privacy     │
│  Policy                                 │
│                                         │
└─────────────────────────────────────────┘
```

**Step 2: Plan Selection Sheet**
```
┌─────────────────────────────────────────┐
│  Select Plan                            │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │ ○ Monthly            $6.49/mo   │    │
│  │   Billed monthly                │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ╔═════════════════════════════════╗    │  ← Selected (Best Value)
│  ║ ● Yearly    $19.99/yr  SAVE 74% ║    │
│  ║   Billed annually               ║    │
│  ╚═════════════════════════════════╝    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │ ○ Lifetime           $29.99     │    │
│  │   One-time purchase             │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ╭─────────────────────────────────╮    │
│  │           Continue              │    │
│  ╰─────────────────────────────────╯    │
│                                         │
└─────────────────────────────────────────┘
```

### Paywall Implementation

```swift
// MARK: - Pro Features Sheet (Step 1)
struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var storeManager = StoreManager.shared
    @State private var showingPlanSelection = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Upgrade")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                VStack(spacing: 24) {
                    // Icon + Title
                    VStack(spacing: 12) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.yellow)

                        Text("VivyTerm Pro")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Unlock unlimited servers & workspaces")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // Features List
                    VStack(alignment: .leading, spacing: 16) {
                        ProFeatureRow(
                            icon: "server.rack",
                            title: "Unlimited Servers",
                            description: "Connect to as many servers as you need"
                        )
                        ProFeatureRow(
                            icon: "folder",
                            title: "Unlimited Workspaces",
                            description: "Organize servers into unlimited workspaces"
                        )
                        ProFeatureRow(
                            icon: "rectangle.stack",
                            title: "Multiple Tabs",
                            description: "Connect to multiple servers simultaneously"
                        )
                        ProFeatureRow(
                            icon: "wrench.and.screwdriver",
                            title: "Custom Environments",
                            description: "Create custom environments beyond Prod/Staging/Dev"
                        )
                        ProFeatureRow(
                            icon: "icloud",
                            title: "iCloud Sync",
                            description: "Sync servers across all your Apple devices"
                        )
                        ProFeatureRow(
                            icon: "star",
                            title: "All Future Features",
                            description: "Get access to all new features"
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .padding(.horizontal, 20)
                }
            }

            // Bottom Buttons
            VStack(spacing: 12) {
                Button {
                    showingPlanSelection = true
                } label: {
                    Text("Select a Plan")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.96, green: 0.45, blue: 0.45))  // Coral
                )
                .foregroundStyle(.white)

                Button {
                    Task { await storeManager.restorePurchases() }
                } label: {
                    Text("Restore Purchases")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )

                Text("Cancel anytime. Subscription auto-renews.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Link("Terms of Service", destination: URL(string: "https://vivy.dev/terms")!)
                    Text("•")
                    Link("Privacy Policy", destination: URL(string: "https://vivy.dev/privacy")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            // Cancel button
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 380, minHeight: 600)
        .sheet(isPresented: $showingPlanSelection) {
            PlanSelectionSheet()
        }
    }
}

// MARK: - Feature Row
struct ProFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.96, green: 0.45, blue: 0.45))  // Coral
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Plan Selection Sheet (Step 2)
struct PlanSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var storeManager = StoreManager.shared
    @State private var selectedPlan: SelectedPlan = .yearly

    enum SelectedPlan {
        case monthly, yearly, lifetime
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Select Plan")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                // Monthly
                PlanOptionRow(
                    title: "Monthly",
                    price: storeManager.monthlyProduct?.displayPrice ?? "$6.49",
                    period: "/mo",
                    subtitle: "Billed monthly",
                    isSelected: selectedPlan == .monthly
                ) {
                    selectedPlan = .monthly
                }

                // Yearly (Best Value)
                PlanOptionRow(
                    title: "Yearly",
                    price: storeManager.yearlyProduct?.displayPrice ?? "$19.99",
                    period: "/yr",
                    subtitle: "Billed annually",
                    badge: "SAVE 74%",
                    isSelected: selectedPlan == .yearly
                ) {
                    selectedPlan = .yearly
                }

                // Lifetime
                PlanOptionRow(
                    title: "Lifetime",
                    price: storeManager.lifetimeProduct?.displayPrice ?? "$29.99",
                    period: "",
                    subtitle: "One-time purchase",
                    isSelected: selectedPlan == .lifetime
                ) {
                    selectedPlan = .lifetime
                }
            }

            Button {
                Task { await purchaseSelected() }
            } label: {
                Group {
                    if storeManager.purchaseState == .purchasing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Text("Continue")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.96, green: 0.45, blue: 0.45))
            )
            .foregroundStyle(.white)
            .disabled(storeManager.purchaseState == .purchasing)
        }
        .padding(24)
        .frame(width: 340)
        .onChange(of: storeManager.purchaseState) { newState in
            if newState == .purchased {
                dismiss()
            }
        }
    }

    private func purchaseSelected() async {
        let product: Product?
        switch selectedPlan {
        case .monthly: product = storeManager.monthlyProduct
        case .yearly: product = storeManager.yearlyProduct
        case .lifetime: product = storeManager.lifetimeProduct
        }
        if let product {
            await storeManager.purchase(product)
        }
    }
}

// MARK: - Plan Option Row
struct PlanOptionRow: View {
    let title: String
    let price: String
    let period: String
    let subtitle: String
    var badge: String? = nil
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                // Radio button
                Circle()
                    .strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.3), lineWidth: 2)
                    .background(Circle().fill(isSelected ? Color(red: 0.96, green: 0.45, blue: 0.45) : Color.clear))
                    .overlay {
                        if isSelected {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title)
                            .fontWeight(.semibold)
                        if let badge {
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green))
                                .foregroundStyle(.white)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(price)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(period)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color(red: 0.96, green: 0.45, blue: 0.45) : Color.primary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
```

### Limit Enforcement

```swift
// Free tier limits
enum FreeTierLimits {
    static let maxWorkspaces = 1
    static let maxServers = 3
    static let maxTabs = 1
    // Environments: only built-in allowed (Prod/Stag/Dev)
}

extension ServerManager {
    var canAddServer: Bool {
        if StoreManager.shared.isPro { return true }
        return servers.count < FreeTierLimits.maxServers
    }

    var canAddWorkspace: Bool {
        if StoreManager.shared.isPro { return true }
        return workspaces.count < FreeTierLimits.maxWorkspaces
    }

    var canCreateCustomEnvironment: Bool {
        StoreManager.shared.isPro
    }

    func addServer(_ server: Server) throws {
        guard canAddServer else {
            throw VivyTermError.proRequired("Upgrade to Pro for unlimited servers")
        }
        // ... add server
    }

    func createCustomEnvironment(name: String, color: String) throws -> Environment {
        guard canCreateCustomEnvironment else {
            throw VivyTermError.proRequired("Upgrade to Pro for custom environments")
        }
        return Environment(
            id: UUID(),
            name: name,
            shortName: String(name.prefix(4)),
            colorHex: color,
            isBuiltIn: false
        )
    }
}

extension ConnectionSessionManager {
    var canOpenNewTab: Bool {
        if StoreManager.shared.isPro { return true }
        return activeSessions.count < FreeTierLimits.maxTabs
    }

    func openConnection(to server: Server) throws -> ConnectionSession {
        guard canOpenNewTab else {
            throw VivyTermError.proRequired("Upgrade to Pro for multiple connections")
        }
        // ... create session
    }
}
```

### Upgrade Prompt (When Limit Reached)

```swift
// Show when user tries to open second tab on free tier
struct TabLimitPromptView: View {
    @ObservedObject var storeManager = StoreManager.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("Multiple Tabs is a Pro Feature")
                .font(.headline)

            Text("Upgrade to connect to multiple servers simultaneously")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Upgrade to Pro") {
                // Show paywall
            }
            .adaptiveGlassTint(.blue)
        }
        .padding()
    }
}
```

### SwiftUI Integration (iOS 17+ / macOS 14+)

```swift
// Using built-in ProductView
ProductView(id: VivyTermProducts.pro) {
    // Custom icon
    Image(systemName: "star.fill")
        .foregroundStyle(.yellow)
}
.productViewStyle(.compact)

// Or SubscriptionStoreView for subscription-style display
// (works for non-consumables too)
```

### Folder Structure

```
Services/Store/
├── StoreManager.swift          # Main StoreKit 2 manager
├── StoreProducts.swift         # Product IDs
└── StoreError.swift            # Custom errors

Views/Store/
├── ProUpgradeSheet.swift       # Paywall sheet
├── ProBadgeView.swift          # Pro badge indicator
└── UpgradePromptView.swift     # Inline upgrade prompt
```

### App Store Connect Setup

**1. Create Subscription Group**
- Name: "VivyTerm Pro"
- Group ID: `vivyterm_pro`

**2. Create Auto-Renewable Subscriptions (in group)**

| Product ID | Name | Price | Duration |
|------------|------|-------|----------|
| `com.vivy.vivyterm.pro.monthly` | Pro Monthly | $6.49 | 1 month |
| `com.vivy.vivyterm.pro.yearly` | Pro Yearly | $19.99 | 1 year |

**3. Create Non-Consumable**

| Product ID | Name | Price |
|------------|------|-------|
| `com.vivy.vivyterm.pro.lifetime` | Pro Lifetime | $29.99 |

**4. Subscription Settings**
- Grace period: 16 days (recommended)
- Billing retry: Enabled
- Family Sharing: Disabled (optional)

### Testing

```swift
// VivyTermStoreKit.storekit - StoreKit Configuration file
// Add all 3 products with matching IDs

// Enable in scheme:
// Edit Scheme → Run → Options → StoreKit Configuration → VivyTermStoreKit.storekit

// Test scenarios:
// - New subscription
// - Upgrade monthly → yearly
// - Downgrade yearly → monthly
// - Lifetime purchase while subscribed (should override)
// - Restore purchases
// - Subscription expiration
// - Renewal
```

---

## Speech-to-Text (Voice-to-Command)

### Use Cases

- Dictate terminal commands on iOS (faster than typing complex commands)
- Hands-free server interaction
- Accessibility support

### Architecture (from Aizen)

```
┌─────────────────────────────────────────────────────────────┐
│                      AudioService                            │
│  (Orchestrator - manages recording, provider selection)      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                 │
│  │ TranscriptionProvider                   │                 │
│  ├──────────────────┴──────────────────────┤                 │
│  │  .system        │ Apple Speech Framework │ ← Fallback     │
│  │  .mlxWhisper    │ On-device Whisper     │ ← arm64 only   │
│  │  .mlxParakeet   │ On-device Parakeet    │ ← arm64 only   │
│  └─────────────────────────────────────────┘                 │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                 │
│  │ AudioCaptureService │ AudioPermissionManager │            │
│  │ (AVAudioEngine)     │ (Mic + Speech perms)   │            │
│  └──────────────────┘  └──────────────────┘                 │
│                                                              │
│  ┌──────────────────┐                                        │
│  │ MLXModelManager  │ Downloads from HuggingFace             │
│  │ ~/.vivyterm/models/ │                                     │
│  └──────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

### Folder Structure (Services/Audio/)

```
Services/Audio/
├── AudioService.swift              # Main orchestrator
├── AudioCaptureService.swift       # AVAudioEngine recording (16kHz)
├── AudioPermissionManager.swift    # Mic + Speech permissions
├── SpeechRecognitionService.swift  # Apple Speech Framework
├── TranscriptionProvider.swift     # Provider enum + settings
├── MLXModelManager.swift           # HuggingFace model downloads
├── MLXModelCatalog.swift           # Available model presets
├── MLXAudioSupport.swift           # arm64 architecture check
├── Whisper/
│   ├── MLXWhisperProvider.swift    # Whisper transcription
│   ├── WhisperModel.swift          # Encoder-decoder architecture
│   ├── WhisperAudio.swift          # Mel-spectrogram processing
│   └── WhisperTokenizer.swift      # Token handling
└── Parakeet/
    ├── MLXParakeetProvider.swift   # Parakeet transcription
    ├── ParakeetModel.swift         # Conformer + RNNT
    ├── ParakeetAudioProcessing.swift
    ├── ParakeetAttention.swift
    ├── ParakeetConformer.swift
    ├── ParakeetRNNT.swift
    └── ParakeetTokenizer.swift
```

### UI Component

```
iOS Terminal with Voice Input:
┌─────────────────────────────────────────┐
│  ╭─────────────────────────────────╮    │
│  │  ← Back    prod.example.com  ⋯  │    │
│  ╰─────────────────────────────────╯    │
├─────────────────────────────────────────┤
│ root@prod:~# systemctl restart nginx    │
│ root@prod:~# _                          │
│                                         │
│                                         │
├─────────────────────────────────────────┤
│  ╭─────────────────────────────────╮    │  ← Voice Recording Pill
│  │  ✕  ● 0:03  "restart nginx"  ➤ │    │     (real-time transcription)
│  ╰─────────────────────────────────╯    │
├─────────────────────────────────────────┤
│  ╭─────────────────────────────────╮    │
│  │ Esc Tab Ctrl ↑ ↓ ← → 🎤        │    │  ← Mic button in toolbar
│  ╰─────────────────────────────────╯    │
└─────────────────────────────────────────┘
```

### Published State

```swift
@MainActor
final class AudioService: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var partialTranscription = ""
    @Published var audioLevel: Float = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var permissionStatus: PermissionStatus = .notDetermined

    func startRecording() async
    func stopRecording() async -> String
    func cancelRecording()
}
```

### Permissions Required

```xml
<!-- Info.plist -->
<key>NSMicrophoneUsageDescription</key>
<string>VivyTerm needs microphone access to transcribe voice commands.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>VivyTerm needs speech recognition to convert voice to terminal commands.</string>
```

---

## Settings & About Windows

### Settings Structure

```
Settings Navigation:
┌────────────────────┬─────────────────────────────────────────┐
│                    │                                         │
│  ⭐ VivyTerm Pro   │  Subscription Status                    │  ← First item (Pro)
│  ─────────────────  │                                         │
│  ⚙️  General       │  ┌─────────────────────────────────┐    │
│  🎙️ Transcription │  │ Status      ✅ Active            │    │
│  🖥️ Terminal      │  │ Plan        Pro Yearly           │    │
│  ☁️  Sync         │  │ Renews      Jan 15, 2027         │    │
│  ℹ️  About        │  └─────────────────────────────────┘    │
│                    │                                         │
│                    │  ╭─────────────────────────────╮        │
│                    │  │    Manage Subscription      │        │
│                    │  ╰─────────────────────────────╯        │
│                    │                                         │
└────────────────────┴─────────────────────────────────────────┘

Pro Settings (when not subscribed):
┌────────────────────┬─────────────────────────────────────────┐
│                    │                                         │
│  ⭐ VivyTerm Pro   │  ┌─────────────────────────────────┐    │
│  ─────────────────  │  │ ✨ Upgrade to Pro               │    │
│  ⚙️  General       │  │    Priority support included    │    │
│  ...               │  │                    [View Plans] │    │
│                    │  └─────────────────────────────────┘    │
│                    │                                         │
│                    │  Status                                 │
│                    │  ┌─────────────────────────────────┐    │
│                    │  │ Status      ⚪ Free Tier         │    │
│                    │  │ Servers     2 of 3 used         │    │
│                    │  │ Workspaces  1 of 1 used         │    │
│                    │  └─────────────────────────────────┘    │
│                    │                                         │
│                    │  ╭─────────────────────────────╮        │
│                    │  │    Restore Purchases        │        │
│                    │  ╰─────────────────────────────╯        │
│                    │                                         │
└────────────────────┴─────────────────────────────────────────┘
```

### Settings Sections

| Section | Settings |
|---------|----------|
| **VivyTerm Pro** | Subscription status, Plan type, Renewal date, Manage subscription, Upgrade banner (if free) |
| **General** | Appearance (System/Light/Dark), Launch at login |
| **Transcription** | Provider (System/Whisper/Parakeet), Model selection, Download management |
| **Terminal** | Font name, Font size, Theme, Cursor style |
| **Sync** | iCloud status, Last sync time, Force sync |
| **About** | Version, Links (Discord, GitHub, Issues), Copyright |

### Folder Structure (Views/Settings/)

```
Views/Settings/
├── SettingsView.swift              # Main navigation container
├── ProSettingsView.swift           # Subscription status & management
├── GeneralSettingsView.swift       # Appearance, launch options
├── TranscriptionSettingsView.swift # Voice engine selection
├── TerminalSettingsView.swift      # Font, theme, cursor
├── SyncSettingsView.swift          # iCloud sync status
└── AboutView.swift                 # Version, links, copyright
```

### Pro Settings View Implementation

```swift
struct ProSettingsView: View {
    @ObservedObject var storeManager = StoreManager.shared
    @State private var showingPlans = false

    var body: some View {
        VStack(spacing: 12) {
            // Upgrade banner (only when not Pro)
            if !storeManager.isPro {
                upgradeBanner
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            Form {
                Section("Status") {
                    HStack {
                        Text("Subscription")
                        Spacer()
                        statusBadge
                    }

                    if storeManager.isPro {
                        HStack {
                            Text("Plan")
                            Spacer()
                            Text(planName)
                                .foregroundStyle(.secondary)
                        }

                        if let renewalDate = renewalDate {
                            HStack {
                                Text(storeManager.isLifetime ? "Purchased" : "Renews")
                                Spacer()
                                Text(renewalDate, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        // Show usage for free tier
                        HStack {
                            Text("Servers")
                            Spacer()
                            Text("\(serverCount) of \(FreeTierLimits.maxServers) used")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Workspaces")
                            Spacer()
                            Text("\(workspaceCount) of \(FreeTierLimits.maxWorkspaces) used")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if storeManager.isPro && !storeManager.isLifetime {
                    Section("Billing") {
                        Button("Manage Subscription") {
                            Task { await openSubscriptionManagement() }
                        }
                    }
                }

                Section {
                    Button("Restore Purchases") {
                        Task { await storeManager.restorePurchases() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $showingPlans) {
            ProUpgradeSheet()
        }
    }

    private var statusBadge: some View {
        PillBadge(
            text: storeManager.isPro ? "Active" : "Free Tier",
            color: storeManager.isPro ? .green : .secondary,
            textColor: .white
        )
    }

    private var planName: String {
        if storeManager.isLifetime {
            return "Pro Lifetime"
        }
        guard let status = storeManager.subscriptionStatus else {
            return "Pro"
        }
        // Check which product is active
        if let productID = status.transaction.unsafePayloadValue.productID {
            switch productID {
            case VivyTermProducts.proMonthly:
                return "Pro Monthly"
            case VivyTermProducts.proYearly:
                return "Pro Yearly"
            default:
                return "Pro"
            }
        }
        return "Pro"
    }

    private var renewalDate: Date? {
        if storeManager.isLifetime {
            // For lifetime, show purchase date
            return nil  // Or get from transaction
        }
        return storeManager.subscriptionStatus?.transaction.unsafePayloadValue.expirationDate
    }

    private func openSubscriptionManagement() async {
        // Opens App Store subscription management
        if let windowScene = NSApp.keyWindow?.windowScene {
            try? await AppStore.showManageSubscriptions(in: windowScene)
        }
    }

    private var upgradeBanner: some View {
        Button {
            showingPlans = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.pink, Color.orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade to VivyTerm Pro")
                        .font(.headline)
                    Text("Unlimited servers & workspaces")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("View Plans")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
```

### Settings Window Manager (macOS)

```swift
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "Settings"
        window?.contentView = NSHostingView(rootView: settingsView)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
```

### About View

```
┌─────────────────────────────────────┐
│                                     │
│           ┌─────────┐               │
│           │  Icon   │               │
│           └─────────┘               │
│                                     │
│            VivyTerm                 │
│         Version 1.0 (1)             │
│                                     │
│   Remote server manager with        │
│   iCloud sync and Keychain          │
│                                     │
│  ╭─────────────────────────────╮    │
│  │  Join Discord Community  ↗  │    │
│  ╰─────────────────────────────╯    │
│  ╭─────────────────────────────╮    │
│  │  View on GitHub          ↗  │    │
│  ╰─────────────────────────────╯    │
│  ╭─────────────────────────────╮    │
│  │  Report an Issue         ↗  │    │
│  ╰─────────────────────────────╯    │
│                                     │
│   © 2025 Vivy Technologies          │
│                                     │
└─────────────────────────────────────┘
```

### AppStorage Keys

```swift
// General
@AppStorage("appearanceMode") var appearanceMode: AppearanceMode = .system

// Transcription
@AppStorage("transcriptionProvider") var provider: TranscriptionProvider = .system
@AppStorage("whisperModelId") var whisperModelId: String = "mlx-community/whisper-tiny"
@AppStorage("parakeetModelId") var parakeetModelId: String = "mlx-community/parakeet-tdt-0.6b"

// Terminal
@AppStorage("terminalFontName") var terminalFontName: String = "Menlo"
@AppStorage("terminalFontSize") var terminalFontSize: Double = 12.0
@AppStorage("terminalTheme") var terminalTheme: String = "Catppuccin Mocha"
```

---

## Complete Project Structure

```
VivyTerm/
├── scripts/
│   └── build.sh                        # Builds GhosttyKit + libssh2/OpenSSL (arm64 targets)
│
├── Vendor/
│   ├── libghostty/
│   │   ├── macos/
│   │   │   ├── lib/libghostty.a        # arm64 only (Apple Silicon)
│   │   │   └── include/ghostty.h
│   │   ├── ios/
│   │   │   ├── lib/libghostty.a        # arm64 (device)
│   │   │   └── include/ghostty.h
│   │   ├── ios-simulator/
│   │   │   ├── lib/libghostty.a        # arm64 (Apple Silicon simulator)
│   │   │   └── include/ghostty.h
│   │   └── VERSION                     # Commit hash
│   │
│   └── libssh2/
│       ├── macos/
│       │   ├── lib/                    # arm64 only
│       │   │   ├── libssh2.a
│       │   │   ├── libssl.a
│       │   │   └── libcrypto.a
│       │   └── include/
│       ├── ios/
│       │   ├── lib/                    # arm64
│       │   └── include/
│       ├── ios-simulator/
│       │   ├── lib/                    # arm64
│       │   └── include/
│       └── module.modulemap
│
├── VivyTerm.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/
│       └── xcschemes/
│           ├── VivyTerm-macOS.xcscheme
│           └── VivyTerm-iOS.xcscheme
│
├── VivyTerm/                           # Shared code (both platforms)
│   ├── App/
│   │   ├── VivyTermApp.swift           # @main entry point
│   │   ├── AppDelegate+macOS.swift     # macOS app delegate
│   │   └── AppDelegate+iOS.swift       # iOS app delegate
│   │
│   ├── Models/
│   │   ├── Server.swift                # Server model (CloudKit synced)
│   │   ├── Workspace.swift             # Workspace model (CloudKit synced)
│   │   ├── ServerCredential.swift      # Credential reference (keychain ID)
│   │   └── ConnectionHistory.swift     # Recent connections
│   │
│   ├── Services/
│   │   ├── CloudKit/
│   │   │   ├── CloudKitManager.swift   # iCloud sync orchestration
│   │   │   ├── CloudKitStore.swift     # CloudKit CRUD operations
│   │   │   └── CloudKitSubscription.swift # Real-time sync
│   │   ├── Keychain/
│   │   │   ├── KeychainManager.swift   # High-level credential API
│   │   │   └── KeychainStore.swift     # Generic keychain wrapper (from aizen)
│   │   ├── SSH/
│   │   │   ├── SSHClient.swift         # SSH connection (wraps libssh2)
│   │   │   ├── SSHSession.swift        # Active session management
│   │   │   └── SSHKeyManager.swift     # Key generation/import
│   │   ├── Terminal/
│   │   │   └── TerminalService.swift   # Terminal session coordination
│   │   ├── Audio/                      # Speech-to-text (from aizen)
│   │   │   ├── AudioService.swift      # Main orchestrator
│   │   │   ├── AudioCaptureService.swift
│   │   │   ├── AudioPermissionManager.swift
│   │   │   ├── SpeechRecognitionService.swift
│   │   │   ├── TranscriptionProvider.swift
│   │   │   ├── MLXModelManager.swift
│   │   │   ├── MLXModelCatalog.swift
│   │   │   ├── MLXAudioSupport.swift
│   │   │   ├── Whisper/                # MLX Whisper (from aizen)
│   │   │   │   ├── MLXWhisperProvider.swift
│   │   │   │   ├── WhisperModel.swift
│   │   │   │   ├── WhisperAudio.swift
│   │   │   │   └── WhisperTokenizer.swift
│   │   │   └── Parakeet/               # MLX Parakeet (from aizen)
│   │   │       ├── MLXParakeetProvider.swift
│   │   │       ├── ParakeetModel.swift
│   │   │       └── ...
│   │   └── Store/                      # StoreKit 2 payments
│   │       ├── StoreManager.swift      # Purchase management
│   │       ├── StoreProducts.swift     # Product IDs
│   │       └── StoreError.swift        # Custom errors
│   │
│   ├── Managers/
│   │   ├── ServerManager.swift         # Server CRUD + sync coordination
│   │   ├── ConnectionManager.swift     # Active connections state
│   │   ├── ConnectionSessionManager.swift # Tab/session lifecycle
│   │   └── SettingsWindowManager.swift # macOS settings window (from aizen)
│   │
│   ├── GhosttyTerminal/                # Terminal emulator (copied from aizen, adapted)
│   │   ├── GhosttyTerminalView.swift   # Main terminal view
│   │   ├── GhosttyRenderingSetup.swift # Metal rendering
│   │   ├── GhosttyInputHandler.swift   # Keyboard input
│   │   ├── GhosttyIMEHandler.swift     # Input method editor
│   │   ├── Ghostty.Action.swift
│   │   ├── Ghostty.App.swift
│   │   ├── Ghostty.Input.swift
│   │   ├── Ghostty.Key.swift
│   │   ├── Ghostty.KeyEvent.swift
│   │   ├── Ghostty.Mods.swift
│   │   ├── Ghostty.MouseEvent.swift
│   │   └── Ghostty.Surface.swift
│   │
│   ├── Views/
│   │   ├── ServerList/
│   │   │   ├── ServerListView.swift
│   │   │   ├── ServerRowView.swift
│   │   │   └── ServerGroupView.swift
│   │   ├── ServerDetail/
│   │   │   ├── ServerDetailView.swift
│   │   │   └── ServerFormView.swift
│   │   ├── Workspace/                      # Workspace management (from aizen)
│   │   │   ├── WorkspaceSidebarView.swift  # macOS sidebar
│   │   │   ├── WorkspaceListView.swift     # iOS list
│   │   │   ├── WorkspaceCreateSheet.swift  # Create modal
│   │   │   ├── WorkspaceEditSheet.swift    # Edit modal
│   │   │   └── WorkspaceSwitcherSheet.swift # Switcher popup
│   │   ├── Tabs/                           # Multiple connections (from aizen)
│   │   │   ├── ConnectionTabBar.swift      # Tab bar container
│   │   │   ├── ConnectionTabButton.swift   # Individual tab
│   │   │   ├── ConnectionTerminalContainer.swift # ZStack of terminals
│   │   │   └── NavigationArrowButton.swift # ◀ ▶ buttons
│   │   ├── Terminal/
│   │   │   ├── TerminalView.swift
│   │   │   ├── TerminalContainerView.swift
│   │   │   └── VoiceRecordingView.swift    # Voice input pill (from aizen)
│   │   ├── Store/                          # Paywall & Pro features
│   │   │   ├── ProUpgradeSheet.swift       # Main paywall
│   │   │   ├── ProBadgeView.swift          # Pro badge indicator
│   │   │   └── UpgradePromptView.swift     # Inline upgrade prompt
│   │   ├── Settings/
│   │   │   ├── SettingsView.swift          # Main navigation
│   │   │   ├── GeneralSettingsView.swift   # Appearance, launch
│   │   │   ├── TranscriptionSettingsView.swift # Voice engine (from aizen)
│   │   │   ├── TerminalSettingsView.swift  # Font, theme
│   │   │   ├── SyncSettingsView.swift      # iCloud status
│   │   │   └── AboutView.swift             # Version, links (from aizen)
│   │   └── Common/
│   │       ├── LoadingView.swift
│   │       └── EmptyStateView.swift
│   │
│   ├── Utilities/
│   │   └── Extensions/
│   │       ├── Date+Extensions.swift
│   │       └── String+Extensions.swift
│   │
│   └── Resources/
│       ├── Assets.xcassets/
│       │   ├── AppIcon.appiconset/
│       │   └── AccentColor.colorset/
│       ├── ghostty/
│       │   ├── themes/                 # 400+ terminal themes
│       │   └── shell-integration/
│       │       ├── bash/
│       │       ├── zsh/
│       │       ├── fish/
│       │       └── elvish/
│       └── terminfo/
│           ├── 67/ghostty
│           └── 78/xterm-ghostty
│
├── VivyTerm-macOS/                     # macOS-specific
│   ├── Info.plist
│   ├── VivyTerm.entitlements
│   └── Views/
│       ├── MacOSWindowView.swift       # Multi-window support
│       └── MenuBarView.swift           # Quick connect menu
│
├── VivyTerm-iOS/                       # iOS-specific
│   ├── Info.plist
│   ├── VivyTerm.entitlements
│   └── Views/
│       ├── KeyboardToolbarView.swift   # Ctrl, Esc, Tab, arrows
│       └── QuickActionsHandler.swift   # Home screen quick actions
│
└── README.md
```

---

## Build Script Detail

### `build.sh`
```bash
# Single entry point for vendor builds:
#   - GhosttyKit.xcframework + libghostty.a (macOS/iOS/simulator)
#   - OpenSSL 3.x + libssh2 (macOS/iOS/simulator, arm64 only)
#
# Usage:
#   ./scripts/build.sh all
#   ./scripts/build.sh ghostty
#   ./scripts/build.sh ssh
```

---

## Data Models

### Server (CloudKit Record)

```swift
struct Server: Identifiable, Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int                    // Default: 22
    var username: String
    var authMethod: AuthMethod       // password, key, keyWithPassphrase
    var groupId: UUID?
    var tags: [String]
    var notes: String?
    var lastConnected: Date?
    var createdAt: Date
    var updatedAt: Date

    // Not synced - credential reference only
    var keychainCredentialId: String // Reference to keychain item
}

enum AuthMethod: String, Codable {
    case password
    case sshKey
    case sshKeyWithPassphrase
}
```

### ServerGroup

```swift
struct ServerGroup: Identifiable, Codable {
    let id: UUID
    var name: String
    var icon: String?
    var color: String?
    var order: Int
}
```

---

## Services Implementation

### 1. KeychainManager (from Aizen Pattern)

```swift
@MainActor
final class KeychainManager {
    static let shared = KeychainManager()
    private let store = KeychainStore(service: "com.vivy.vivyterm")

    // Store SSH password
    func storePassword(for serverId: UUID, password: String) throws

    // Store SSH private key
    func storeSSHKey(for serverId: UUID, privateKey: Data, passphrase: String?) throws

    // Retrieve credentials
    func getPassword(for serverId: UUID) throws -> String?
    func getSSHKey(for serverId: UUID) throws -> (key: Data, passphrase: String?)?

    // Delete credentials
    func deleteCredentials(for serverId: UUID) throws

    // iCloud Keychain sync (uses kSecAttrSynchronizable)
    func enableiCloudSync(for serverId: UUID) throws
}
```

### 2. CloudKitManager

```swift
@MainActor
final class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?

    private let container = CKContainer(identifier: "iCloud.com.vivy.vivyterm")
    private let database: CKDatabase

    enum SyncStatus {
        case idle
        case syncing
        case error(String)
        case offline
    }

    // Sync operations
    func fetchServers() async throws -> [Server]
    func saveServer(_ server: Server) async throws
    func deleteServer(_ server: Server) async throws

    // Real-time sync
    func subscribeToChanges()
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any])

    // Conflict resolution
    func resolveConflict(_ local: Server, _ remote: Server) -> Server
}
```

### 3. ServerManager

```swift
@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var servers: [Server] = []
    @Published var groups: [ServerGroup] = []
    @Published var isLoading = false

    private let cloudKit = CloudKitManager.shared
    private let keychain = KeychainManager.shared

    // CRUD with sync
    func addServer(_ server: Server, credentials: Credentials) async throws
    func updateServer(_ server: Server) async throws
    func deleteServer(_ server: Server) async throws

    // Grouping
    func moveServer(_ server: Server, to group: ServerGroup?) async throws

    // Quick access
    func recentServers(limit: Int = 5) -> [Server]
    func favoriteServers() -> [Server]
}
```

### 4. SSHClient

```swift
actor SSHClient {
    private var session: SSHSession?

    func connect(to server: Server) async throws -> SSHSession
    func disconnect() async
    func execute(_ command: String) async throws -> String

    // Terminal stream
    func startShell() async throws -> AsyncStream<Data>
    func write(_ data: Data) async throws
}
```

---

## Platform-Specific Considerations

### Shared (Both Platforms)
- **libghostty** for terminal emulation (same as aizen)
- SwiftUI for UI
- Same data models
- Same services layer
- CloudKit for sync
- Keychain with iCloud sync enabled

### macOS
- Multiple windows/tabs support
- Menu bar quick connect
- Touch Bar support
- Keyboard shortcuts

### iOS
- Optimized for touch input
- Keyboard toolbar with common keys (Ctrl, Tab, Esc, arrows)
- Split view on iPad
- Home screen quick actions (3D Touch / Haptic Touch)
- Spotlight integration

---

## Implementation Phases

### Phase 1: Project Setup & Build System
- [ ] Create Xcode project with iOS + macOS targets
- [ ] Set up folder structure
- [ ] Consolidate vendor builds into scripts/build.sh (GhosttyKit + libssh2/OpenSSL)
- [ ] Build and verify vendor libraries
- [ ] Copy GhosttyTerminal from aizen, adapt for multiplatform

### Phase 2: Foundation
- [ ] Copy KeychainStore from aizen
- [ ] Implement Server model (CloudKit)
- [ ] Implement Workspace model (CloudKit)
- [ ] Set up CloudKit container in Apple Developer Portal
- [ ] CloudKitManager basic CRUD (servers + workspaces)
- [ ] ServerManager with local state
- [ ] KeychainManager implementation

### Phase 3: Workspaces (from aizen)
- [ ] Copy WorkspaceCreateSheet, WorkspaceEditSheet, WorkspaceSwitcherSheet
- [ ] WorkspaceSidebarView (macOS)
- [ ] WorkspaceListView (iOS)
- [ ] Workspace ↔ Server relationship
- [ ] Workspace color picker
- [ ] WorkspaceNameGenerator utility

### Phase 4: UI - Server Management
- [ ] ServerListView with workspace filtering
- [ ] ServerFormView (add/edit with workspace selection)
- [ ] ServerDetailView
- [ ] Adaptive glass helpers (Liquid Glass / .ultraThinMaterial fallback)

### Phase 5: SSH & Terminal
- [ ] SSHClient wrapping libssh2
- [ ] SSHSession management
- [ ] Terminal view integration with libghostty
- [ ] Connect SSH → Terminal data flow
- [ ] Connection lifecycle management
- [ ] ConnectionSessionManager for tabs
- [ ] Tab bar UI (ConnectionTabsScrollView, ConnectionTabButton)
- [ ] ConnectionTerminalContainer (ZStack with opacity)
- [ ] View switcher in toolbar (Stats | Terminal picker)
- [ ] Keyboard shortcuts (⌘T, ⌘W, ⌘1-9, etc.)

### Phase 5.5: Server Statistics
- [ ] ServerStatsCollector (SSH-based metrics collection)
- [ ] StatsParser (parse /proc/stat, /proc/meminfo, df, etc.)
- [ ] StatsHistory (time-series data storage)
- [ ] ServerStatsView (main stats container)
- [ ] QuickStatCard (CPU/Memory/Disk/Network cards)
- [ ] ChartCard with Swift Charts (CPU/Memory graphs)
- [ ] ProcessListCard (top processes table)
- [ ] SystemInfoCard (uptime, load average)

### Phase 6: Payments (StoreKit 2)
- [ ] Create StoreKit Configuration file for testing
- [ ] StoreManager implementation
- [ ] ProUpgradeSheet (paywall UI)
- [ ] Limit enforcement (3 servers, 1 workspace free)
- [ ] ProBadgeView, UpgradePromptView
- [ ] Restore purchases
- [ ] App Store Connect: Create non-consumable product

### Phase 7: Speech-to-Text (from aizen)
- [ ] Copy Services/Audio/* from aizen
- [ ] Copy VoiceRecordingView from aizen
- [ ] Integrate mic button in iOS keyboard toolbar
- [ ] MLX model download UI in settings
- [ ] Test System/Whisper/Parakeet providers

### Phase 8: Settings & About
- [ ] Copy SettingsWindowManager from aizen
- [ ] SettingsView with navigation
- [ ] GeneralSettingsView (appearance)
- [ ] TranscriptionSettingsView (voice engine)
- [ ] TerminalSettingsView (font, theme)
- [ ] SyncSettingsView (iCloud status)
- [ ] AboutView (version, links)
- [ ] Pro status in settings

### Phase 9: Sync & Polish
- [ ] CloudKit subscriptions (real-time sync)
- [ ] Conflict resolution
- [ ] Offline support
- [ ] iCloud Keychain sync option
- [ ] SSH key import/generation

### Phase 10: Platform Features
- [ ] macOS: Multiple windows, menu bar quick connect
- [ ] iOS: Keyboard toolbar (Ctrl, Esc, Tab, arrows, mic)
- [ ] iOS: Home screen quick actions
- [ ] Widgets for both platforms

---

## Dependencies

### Vendor Libraries (Static, built from source)
- **libghostty** - Terminal emulator (same as aizen, built for macOS + iOS)
- **libssh2** - SSH client library
- **OpenSSL** - Crypto backend for libssh2 (libssl.a, libcrypto.a)

### Swift Package Manager
- **MLX** / **MLXNN** / **MLXFFT** - On-device ML inference (arm64 only, for Whisper/Parakeet)

### System Frameworks
- CloudKit - iCloud sync
- Security - Keychain access
- Metal / MetalKit - Terminal rendering
- CryptoKit - Local crypto operations
- AVFoundation - Audio capture
- Speech - Apple Speech Framework (fallback transcription)
- StoreKit - In-app purchases (StoreKit 2)

---

## App Store Distribution & Sandboxing

### Sandbox Requirements

App Store apps **must** be sandboxed. VivyTerm needs these entitlements:

```xml
<!-- VivyTerm.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- App Sandbox (required for App Store) -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- Network: Outgoing connections (SSH) -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- Keychain: Credential storage -->
    <key>com.apple.security.keychain</key>
    <true/>

    <!-- iCloud/CloudKit -->
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.vivy.vivyterm</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>$(TeamIdentifierPrefix)com.vivy.vivyterm</string>

    <!-- Microphone (voice-to-command) -->
    <key>com.apple.security.device.audio-input</key>
    <true/>

    <!-- Hardened Runtime (required for notarization) -->
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <false/>
</dict>
</plist>
```

### Entitlements Explanation

| Entitlement | Purpose | Required |
|-------------|---------|----------|
| `app-sandbox` | App Store requirement | ✅ Yes |
| `network.client` | SSH connections to remote servers | ✅ Yes |
| `keychain` | Store SSH passwords/keys securely | ✅ Yes |
| `icloud-container-identifiers` | CloudKit sync | ✅ Yes |
| `device.audio-input` | Microphone for voice commands | ✅ Yes |

### What We CAN'T Do (Sandbox Limitations)

| Feature | Limitation | Workaround |
|---------|------------|------------|
| Local terminal | Can't spawn local shell | N/A (we're SSH-only anyway) |
| Read SSH keys from `~/.ssh` | No access to user home | Import keys via file picker or paste |
| System-wide SSH config | Can't read `~/.ssh/config` | User adds servers manually |
| File downloads | No arbitrary filesystem access | Download to app container, share via Share Sheet |

### SSH Key Import Flow

Since we can't read `~/.ssh/` directly, users import keys via:

```swift
// Option 1: File picker (user grants access)
.fileImporter(
    isPresented: $showingKeyImporter,
    allowedContentTypes: [.data, .text],
    allowsMultipleSelection: false
) { result in
    // Read key file content
    // Store in Keychain
}

// Option 2: Paste from clipboard
Button("Paste Private Key") {
    if let key = UIPasteboard.general.string {
        // Validate and store in Keychain
    }
}

// Option 3: Generate new key pair in-app
Button("Generate New Key") {
    let keyPair = SSHKeyManager.generateED25519()
    // Store private in Keychain
    // Show public key to copy to server
}
```

### Info.plist Requirements

```xml
<!-- Info.plist -->
<key>NSMicrophoneUsageDescription</key>
<string>VivyTerm needs microphone access to transcribe voice commands to terminal input.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>VivyTerm uses speech recognition to convert voice to terminal commands.</string>

<!-- iOS Background Modes (keep SSH alive briefly) -->
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>  <!-- For voice recording -->
</array>

<!-- App Transport Security (SSH uses custom ports) -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <!-- SSH is not HTTP, ATS doesn't apply -->
</dict>
```

### App Store Review Considerations

1. **Privacy Manifest** (required iOS 17+ / macOS 14+)
```json
{
    "NSPrivacyTracking": false,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [
        {
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]
        }
    ]
}
```

2. **Export Compliance** (for SSH/crypto)
   - VivyTerm uses encryption (SSH, libssh2 with OpenSSL)
   - Answer "Yes" to export compliance question
   - File for ERN exemption (ECCN 5D002) or use exemption for "mass market" apps
   - Most SSH apps qualify for TSU exception (publicly available encryption)

3. **In-App Purchases**
   - StoreKit 2 already planned
   - Restore purchases must work
   - Clear pricing display

4. **Demo/Test Account**
   - Provide a test server for reviewers OR
   - Explain this connects to user's own servers
   - Show screenshots of connection flow

### Folder Structure for Entitlements

```
VivyTerm/
├── VivyTerm-macOS/
│   ├── VivyTerm.entitlements      # macOS entitlements
│   └── Info.plist
├── VivyTerm-iOS/
│   ├── VivyTerm.entitlements      # iOS entitlements
│   └── Info.plist
└── PrivacyInfo.xcprivacy          # Privacy manifest (shared)
```

### Build Settings

```
// Xcode Build Settings
CODE_SIGN_ENTITLEMENTS = VivyTerm-$(PLATFORM_NAME)/VivyTerm.entitlements
ENABLE_HARDENED_RUNTIME = YES  // macOS
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

---

## Reliability

### Auto-Reconnect

```swift
actor ConnectionReliabilityManager {
    private var reconnectAttempts = 0
    private let maxAttempts = 5
    private let baseDelay: TimeInterval = 1.0  // Exponential backoff

    enum ConnectionState {
        case connected
        case disconnected
        case reconnecting(attempt: Int)
        case failed(Error)
    }

    func handleDisconnect(session: ConnectionSession) async {
        guard session.autoReconnect else { return }

        while reconnectAttempts < maxAttempts {
            reconnectAttempts += 1
            let delay = baseDelay * pow(2, Double(reconnectAttempts - 1))

            await updateState(.reconnecting(attempt: reconnectAttempts))
            try? await Task.sleep(for: .seconds(delay))

            do {
                try await session.reconnect()
                reconnectAttempts = 0
                await updateState(.connected)
                return
            } catch { continue }
        }

        await updateState(.failed(ConnectionError.maxRetriesExceeded))
    }
}
```

### Keep-Alive

```swift
// SSH keep-alive to prevent timeout
extension SSHClient {
    func startKeepAlive(interval: TimeInterval = 30) {
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                try? await sendKeepAlive()  // libssh2_keepalive_send
            }
        }
    }
}

// Settings
@AppStorage("sshKeepAliveInterval") var keepAliveInterval: Int = 30
@AppStorage("sshKeepAliveEnabled") var keepAliveEnabled: Bool = true
```

### Offline Indicator

```swift
import Network

@MainActor
class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    @Published var isConnected = true
    @Published var connectionType: ConnectionType = .unknown

    enum ConnectionType { case wifi, cellular, ethernet, unknown }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}

// Banner in UI
struct OfflineBanner: View {
    @ObservedObject var networkMonitor: NetworkMonitor

    var body: some View {
        if !networkMonitor.isConnected {
            HStack {
                Image(systemName: "wifi.slash")
                Text("No network connection")
            }
            .padding(8)
            .background(.red.opacity(0.9))
            .foregroundStyle(.white)
        }
    }
}
```

### Error Recovery

```swift
enum ConnectionError: LocalizedError {
    case timeout, authenticationFailed, hostUnreachable
    case connectionRefused, networkLost, maxRetriesExceeded

    var errorDescription: String? {
        switch self {
        case .timeout: return "Connection timed out"
        case .authenticationFailed: return "Authentication failed"
        case .hostUnreachable: return "Server unreachable"
        case .connectionRefused: return "Connection refused"
        case .networkLost: return "Network connection lost"
        case .maxRetriesExceeded: return "Could not reconnect"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .authenticationFailed: return "Verify username, password, or SSH key"
        case .hostUnreachable: return "Check hostname and network connection"
        case .networkLost: return "Waiting for network..."
        default: return "Tap to try again"
        }
    }
}
```

---

## Crash Reporting (Native Apple - No Dependencies)

### MetricKit (iOS 13+ / macOS 12+)

```swift
import MetricKit

class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            // Crash diagnostics
            if let crashes = payload.crashDiagnostics {
                for crash in crashes { logCrash(crash) }
            }
            // Hang diagnostics (app unresponsive)
            if let hangs = payload.hangDiagnostics {
                for hang in hangs { logHang(hang) }
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Daily performance metrics (launch time, hang rate, etc.)
    }

    private func logCrash(_ crash: MXCrashDiagnostic) {
        let report = CrashReport(
            timestamp: Date(),
            callStack: crash.callStackTree.jsonRepresentation()
        )
        CrashReportStore.shared.save(report)
    }
}

// Let users share crash reports voluntarily in Settings
struct DiagnosticsSettingsView: View {
    @State private var crashReports: [CrashReport] = []

    var body: some View {
        Section("Diagnostics") {
            ForEach(crashReports) { report in
                HStack {
                    Text(report.timestamp.formatted())
                    Spacer()
                    ShareLink(item: report.exportAsText())
                }
            }
        }
    }
}
```

### OSLog for Debugging

```swift
import os.log

extension Logger {
    static let connection = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Connection")
    static let ssh = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SSH")
    static let terminal = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Terminal")
    static let sync = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")
}

// Usage
Logger.connection.info("Connecting to \(host):\(port)")
Logger.connection.error("Failed: \(error.localizedDescription)")
```

---

## Accessibility

### VoiceOver Support

```swift
ServerRow(server: server)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(server.name), \(server.isConnected ? "connected" : "disconnected")")
    .accessibilityHint("Double tap to connect")
    .accessibilityAddTraits(server.isConnected ? .isSelected : [])
```

### Dynamic Type

```swift
// Use scalable fonts for non-terminal UI
Text("Server Name")
    .font(.headline)  // Automatically scales with system settings

// For custom sizes
@ScaledMetric var iconSize: CGFloat = 24

Image(systemName: "server.rack")
    .frame(width: iconSize, height: iconSize)
```

### Reduce Motion

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

// Respect user preference
withAnimation(reduceMotion ? nil : .easeInOut) {
    showingStats.toggle()
}

.animation(reduceMotion ? .none : .spring(), value: selectedTab)
```

---

## Terminal Settings (from Aizen)

### Settings Structure

```swift
struct TerminalSettingsView: View {
    // Font
    @AppStorage("terminalFontName") private var fontName = "Menlo"
    @AppStorage("terminalFontSize") private var fontSize: Double = 14

    // Theme
    @AppStorage("terminalThemeName") private var themeName = "VivyTerm Dark"
    @AppStorage("terminalThemeNameLight") private var themeNameLight = "VivyTerm Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = false

    // Behavior
    @AppStorage("terminalNotificationsEnabled") private var notificationsEnabled = true
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true

    // Copy Text Processing
    @AppStorage("terminalCopyTrimTrailingWhitespace") private var copyTrimWhitespace = true
    @AppStorage("terminalCopyCollapseBlankLines") private var copyCollapseBlankLines = false
    @AppStorage("terminalCopyStripShellPrompts") private var copyStripPrompts = false
    @AppStorage("terminalCopyFlattenCommands") private var copyFlattenCommands = false
    @AppStorage("terminalCopyRemoveBoxDrawing") private var copyRemoveBoxDrawing = false
    @AppStorage("terminalCopyStripAnsiCodes") private var copyStripAnsi = true

    // SSH specific
    @AppStorage("sshKeepAliveEnabled") private var keepAliveEnabled = true
    @AppStorage("sshKeepAliveInterval") private var keepAliveInterval = 30
    @AppStorage("sshAutoReconnect") private var autoReconnect = true

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font Family", selection: $fontName) {
                    ForEach(monospaceFonts, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Size: \(Int(fontSize))pt")
                    Slider(value: $fontSize, in: 8...24, step: 1)
                    Stepper("", value: $fontSize, in: 8...24).labelsHidden()
                }
            }

            Section("Theme") {
                Toggle("Different themes for Light/Dark", isOn: $usePerAppearanceTheme)
                if usePerAppearanceTheme {
                    Picker("Dark Mode", selection: $themeName) { /* themes */ }
                    Picker("Light Mode", selection: $themeNameLight) { /* themes */ }
                } else {
                    Picker("Theme", selection: $themeName) { /* themes */ }
                }
            }

            Section("Behavior") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                Toggle("Show voice input button", isOn: $voiceButtonEnabled)
            }

            Section("Copy Text Processing") {
                Toggle("Trim trailing whitespace", isOn: $copyTrimWhitespace)
                Toggle("Collapse blank lines", isOn: $copyCollapseBlankLines)
                Toggle("Strip shell prompts ($ #)", isOn: $copyStripPrompts)
                Toggle("Flatten multi-line commands", isOn: $copyFlattenCommands)
                Toggle("Remove box-drawing characters", isOn: $copyRemoveBoxDrawing)
                Toggle("Strip ANSI escape codes", isOn: $copyStripAnsi)
            }

            Section("Connection") {
                Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
                Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)
                if keepAliveEnabled {
                    Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

---

## Security Considerations

1. **Keychain Access**
   - Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for local-only
   - Use `kSecAttrSynchronizable` for cross-device sync
   - Never store raw passwords in CloudKit

2. **CloudKit**
   - Only sync server metadata (host, port, username)
   - Credential IDs reference keychain items
   - Private database only (user's iCloud)

3. **SSH Keys**
   - Support Ed25519, RSA keys
   - Encrypted storage with optional passphrase
   - Biometric unlock option (Face ID / Touch ID)
   - Import via file picker (sandbox-safe) or paste

---

## File Reuse from Aizen

### Copy Directly
| Source (aizen) | Destination (VivyTerm) |
|----------------|------------------------|
| `Services/License/KeychainStore.swift` | `Services/Keychain/KeychainStore.swift` |
| `GhosttyTerminal/*` (14 files) | `GhosttyTerminal/*` |
| `Services/Audio/*` (entire folder) | `Services/Audio/*` |
| `Views/Workspace/WorkspaceCreateSheet.swift` | `Views/Workspace/WorkspaceCreateSheet.swift` |
| `Views/Workspace/WorkspaceEditSheet.swift` | `Views/Workspace/WorkspaceEditSheet.swift` |
| `Views/Workspace/WorkspaceSwitcherSheet.swift` | `Views/Workspace/WorkspaceSwitcherSheet.swift` |
| `Utilities/WorkspaceNameGenerator.swift` | `Utilities/WorkspaceNameGenerator.swift` |
| `Views/Chat/VoiceRecordingView.swift` | `Views/Terminal/VoiceRecordingView.swift` |
| `Views/Settings/TranscriptionSettingsView.swift` | `Views/Settings/TranscriptionSettingsView.swift` |
| `Views/Settings/GeneralSettingsView.swift` | `Views/Settings/GeneralSettingsView.swift` |
| `Views/About/AboutView.swift` | `Views/Settings/AboutView.swift` |
| `Managers/SettingsWindowManager.swift` | `Managers/SettingsWindowManager.swift` |
| `Views/Common/SearchField.swift` | `Views/Common/SearchField.swift` |
| `Views/Common/PillBadge.swift` | `Views/Common/PillBadge.swift` |
| `Views/Workspace/WorkspaceSidebarView.swift` (SupportSheet) | `Views/Support/SupportSheet.swift` |
| `Views/Settings/TerminalSettingsView.swift` | `Views/Settings/TerminalSettingsView.swift` |
| `Views/Settings/Components/TerminalPresetFormView.swift` | `Views/Settings/TerminalPresetFormView.swift` |
| `Managers/TerminalPresetManager.swift` | `Managers/TerminalPresetManager.swift` |
| `scripts/build.sh` | `scripts/build.sh` (vendor build entry point) |
| `scripts/organize-resources.sh` | `scripts/organize-resources.sh` (adapt) |
| `Resources/ghostty/themes/*` | `Resources/ghostty/themes/*` |
| `Resources/ghostty/shell-integration/*` | `Resources/ghostty/shell-integration/*` |
| `Resources/terminfo/*` | `Resources/terminfo/*` |

### Reference for Patterns
| Source (aizen) | Use for |
|----------------|---------|
| `LicenseManager.swift` | `CloudKitManager.swift` singleton pattern |
| `LicenseClient.swift` | Network request patterns |
| `SettingsView.swift` | Settings navigation structure |
| `ContentView.swift` | **NavigationSplitView layout** with sidebar |
| `WorkspaceSidebarView.swift` | **Sidebar structure**: VStack sections, list styles, footer buttons |
| `WorktreeDetailView.swift` | **Toolbar tabs pattern** (`.toolbar { sessionToolbarItems }`) |
| `WorktreeSessionTabs.swift` | Tab bar scroll view (`SessionTabsScrollView`) |
| `TerminalTabView.swift` | Terminal container (ZStack with opacity switching) |
| `TerminalSessionManager.swift` | Session lifecycle management |
| `build-libgit2.sh` | `scripts/build.sh` (libssh2/OpenSSL section) |
