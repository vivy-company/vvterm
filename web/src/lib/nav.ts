// Central site map: drives the header nav, footer, hub pages, breadcrumbs, and sitemap.
// Keep slugs stable — they are public URLs.

export interface PlatformMeta {
  slug: string;
  name: string;
  shortName: string;
  navLabel: string;
  icon: string;
  tagline: string;
  summary: string;
  requirement: string;
}

export interface FeatureMeta {
  slug: string;
  navLabel: string;
  title: string;
  summary: string;
  icon: string;
}

export interface CompareMeta {
  slug: string;
  competitor: string;
  navLabel: string;
  title: string;
  summary: string;
}

export interface GuideMeta {
  slug: string;
  title: string;
  summary: string;
  category: string;
  minutes: number;
}

export interface DocMeta {
  slug: string;
  title: string;
  summary: string;
  section: string;
}

export const PLATFORMS: PlatformMeta[] = [
  {
    slug: "mac",
    name: "Mac",
    shortName: "Mac",
    navLabel: "VVTerm for Mac",
    icon: "lucide:laptop",
    tagline: "A native SSH terminal for macOS",
    summary:
      "GPU-rendered terminal with tabs and split panes, tmux session persistence, an SFTP file browser, live monitoring, and iCloud-synced servers — built for Apple Silicon Macs.",
    requirement: "macOS 13 Ventura or later · Apple Silicon",
  },
  {
    slug: "ipad",
    name: "iPad",
    shortName: "iPad",
    navLabel: "VVTerm for iPad",
    icon: "lucide:tablet",
    tagline: "Turn iPad into a real SSH workstation",
    summary:
      "Hardware-keyboard shortcuts, Stage Manager multitasking, a customizable terminal toolbar, tmux persistence, and Mosh sessions that survive network drops.",
    requirement: "iPadOS 16 or later",
  },
  {
    slug: "iphone",
    name: "iPhone",
    shortName: "iPhone",
    navLabel: "VVTerm for iPhone",
    icon: "lucide:smartphone",
    tagline: "Your servers in your pocket",
    summary:
      "Reconnect from anywhere with Mosh, keep sessions alive with tmux, check live server stats, browse remote files, and keep credentials in Keychain.",
    requirement: "iOS 16 or later",
  },
];

export const FEATURES: FeatureMeta[] = [
  {
    slug: "ssh-terminal",
    navLabel: "SSH terminal",
    title: "GPU SSH terminal",
    summary:
      "A fast, accurate terminal powered by libghostty — the rendering engine from Ghostty — with true color, ligatures, and crisp Metal drawing.",
    icon: "lucide:square-terminal",

  },
  {
    slug: "tmux-session-persistence",
    navLabel: "tmux persistence",
    title: "tmux session persistence",
    summary:
      "Sessions survive disconnects, sleep, and app switches. VVTerm manages tmux for you — auto-installing it, reattaching on reconnect, and tuning it out of the box.",
    icon: "lucide:history",

  },
  {
    slug: "terminal-customization",
    navLabel: "Customization",
    title: "Themes & customization",
    summary:
      "Hundreds of built-in themes, Nerd Fonts, cursor styles, and a custom keyboard toolbar with your own command snippets and shortcuts.",
    icon: "lucide:palette",

  },
  {
    slug: "sftp-file-browser",
    navLabel: "SFTP files",
    title: "SFTP file browser",
    summary:
      "Browse remote folders, upload and download, rename, move, delete, create directories, and edit POSIX permissions without a separate app.",
    icon: "lucide:folder-open-dot",

  },
  {
    slug: "server-monitoring",
    navLabel: "Server monitoring",
    title: "Live server monitoring",
    summary:
      "Watch CPU, memory, network, disk, load average, and top processes in real time — on Linux, macOS, BSD, and Windows hosts.",
    icon: "lucide:activity",

  },
  {
    slug: "windows-ssh",
    navLabel: "Windows SSH",
    title: "Windows server support",
    summary:
      "Connect to Windows and PowerShell hosts, browse files over SFTP, see live stats, and keep persistent sessions with psmux.",
    icon: "lucide:monitor",

  },
  {
    slug: "mosh",
    navLabel: "Mosh",
    title: "Mosh roaming sessions",
    summary:
      "Mosh keeps your session alive across network changes, sleep, and flaky connections, with instant local echo and SSH fallback.",
    icon: "lucide:radio",

  },
  {
    slug: "tailscale-ssh",
    navLabel: "Tailscale SSH",
    title: "Tailscale SSH",
    summary:
      "Reach machines on your tailnet by their MagicDNS name — no port forwarding, no exposed ports, no extra keys to manage.",
    icon: "lucide:waypoints",

  },
  {
    slug: "cloudflare-tunnel-ssh",
    navLabel: "Cloudflare Tunnel SSH",
    title: "Cloudflare Tunnel SSH",
    summary:
      "Connect to servers behind Cloudflare Tunnel without opening inbound ports, straight from VVTerm.",
    icon: "lucide:cloud",

  },
  {
    slug: "icloud-sync-keychain",
    navLabel: "iCloud sync & Keychain",
    title: "iCloud sync & Keychain security",
    summary:
      "Server metadata syncs through iCloud while passwords and SSH keys stay in Apple Keychain — synced only through iCloud Keychain when you allow it.",
    icon: "lucide:cloudy",

  },
];

export const COMPARISONS: CompareMeta[] = [
  {
    slug: "vvterm-vs-termius",
    competitor: "Termius",
    navLabel: "VVTerm vs Termius",
    title: "VVTerm vs Termius",
    summary:
      "A native, Apple-first SSH client with lifetime pricing versus a cross-platform subscription suite. See how they compare.",
  },
  {
    slug: "vvterm-vs-blink-shell",
    competitor: "Blink Shell",
    navLabel: "VVTerm vs Blink Shell",
    title: "VVTerm vs Blink Shell",
    summary:
      "Two Mosh-capable Apple terminals compared — UI, SFTP file browsing, sync, and pricing.",
  },
];

export const GUIDES: GuideMeta[] = [
  {
    slug: "how-to-ssh-from-iphone",
    title: "How to SSH into a server from your iPhone",
    summary: "Add a server, choose an auth method, and open your first secure shell session on iOS.",
    category: "Getting started",
    minutes: 4,
  },
  {
    slug: "ssh-from-mac",
    title: "How to SSH from your Mac with VVTerm",
    summary: "Set up a native macOS terminal with tabs, keys, and iCloud-synced servers.",
    category: "Getting started",
    minutes: 4,
  },
  {
    slug: "set-up-mosh-on-ios",
    title: "Set up Mosh on iPhone and iPad",
    summary: "Keep SSH sessions alive across network drops and sleep with Mosh.",
    category: "Connections",
    minutes: 5,
  },
  {
    slug: "tailscale-ssh-setup",
    title: "Connect with Tailscale SSH",
    summary: "Reach machines on your tailnet by MagicDNS name without exposing ports.",
    category: "Connections",
    minutes: 5,
  },
  {
    slug: "cloudflare-tunnel-ssh-setup",
    title: "Connect over Cloudflare Tunnel SSH",
    summary: "SSH to servers behind Cloudflare Tunnel with no inbound ports open.",
    category: "Connections",
    minutes: 6,
  },
  {
    slug: "sftp-file-transfer-on-ios",
    title: "Transfer files over SFTP on iOS",
    summary: "Browse, upload, download, and edit remote files from iPhone and iPad.",
    category: "Files",
    minutes: 4,
  },
];

export const DOCS: DocMeta[] = [
  {
    slug: "getting-started",
    title: "Getting started",
    summary: "Install VVTerm, add your first server, and connect.",
    section: "Basics",
  },
  {
    slug: "adding-a-server",
    title: "Adding a server",
    summary: "Hosts, ports, usernames, environments, and workspaces.",
    section: "Basics",
  },
  {
    slug: "authentication-and-keys",
    title: "Authentication and SSH keys",
    summary: "Passwords, SSH keys, passphrases, and where credentials are stored.",
    section: "Basics",
  },
  {
    slug: "sftp-file-browser",
    title: "Using the SFTP file browser",
    summary: "Browse, transfer, preview, and edit remote files and permissions.",
    section: "Working remotely",
  },
  {
    slug: "icloud-sync",
    title: "iCloud sync and Keychain",
    summary: "How server metadata and credentials sync across your devices.",
    section: "Working remotely",
  },
  {
    slug: "workspaces-and-tabs",
    title: "Workspaces, environments, and tabs",
    summary: "Organize servers and run multiple connections at once.",
    section: "Working remotely",
  },
];

// Header mega-nav grouping.
export const NAV = {
  platforms: PLATFORMS.map((p) => ({ href: `/${p.slug}`, label: p.navLabel, icon: p.icon })),
  features: FEATURES.map((f) => ({ href: `/features/${f.slug}`, label: f.navLabel, icon: f.icon })),
  resources: [
    { href: "/guides", label: "Guides", icon: "lucide:book-open" },
    { href: "/docs", label: "Documentation", icon: "lucide:file-text" },
    { href: "/compare", label: "Comparisons", icon: "lucide:git-compare" },
  ],
};
