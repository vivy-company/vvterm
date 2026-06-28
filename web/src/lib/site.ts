export const SITE = {
  name: "VVTerm",
  siteUrl: "https://vvterm.com",
  title: "VVTerm - SSH Terminal and SFTP Client for iPhone, iPad, and Mac",
  description:
    "Your servers. Everywhere. Native SSH terminal and SFTP client for iPhone, iPad, and Mac with tmux session persistence, Mosh, Tailscale & Cloudflare Tunnel SSH, live monitoring, iCloud sync, and Keychain security.",
  appStoreUrl: "https://apps.apple.com/app/vvterm/id6757482822",
  githubUrl: "https://github.com/vivy-company/vvterm",
  discordUrl: "https://discord.gg/zemMZtrkSb",
  appStoreId: "6757482822",
  umamiWebsiteId: "22711a63-9ec0-491c-ad86-71cb0b6ad4dd",
  gtagId: "AW-17966112771",
  gtagConversionId: "AW-17966112771/kskJCIz44oUcEIPA9PZC",
};

// Factory for per-page SoftwareApplication JSON-LD (centralizes author/image/offers/category).
export function softwareAppSchema(opts: {
  name: string;
  operatingSystem: string;
  path: string;
  description: string;
  applicationCategory?: string;
}) {
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: opts.name,
    applicationCategory: opts.applicationCategory ?? "DeveloperApplication",
    operatingSystem: opts.operatingSystem,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    description: opts.description,
    url: `${SITE.siteUrl}${opts.path}`,
    image: `${SITE.siteUrl}/og.png`,
    author: { "@type": "Organization", name: "Vivy Technologies" },
  };
}

export const faqSchema = [
  {
    "@type": "Question",
    name: "What is VVTerm?",
    acceptedAnswer: {
      "@type": "Answer",
      text: "VVTerm is an SSH terminal app for iOS and macOS. It helps you manage and connect to remote servers with iCloud sync across Apple devices.",
    },
  },
  {
    "@type": "Question",
    name: "How does iCloud sync work?",
    acceptedAnswer: {
      "@type": "Answer",
      text: "Server configurations sync through iCloud, while passwords and SSH keys stay in Apple Keychain and can sync through iCloud Keychain when enabled.",
    },
  },
  {
    "@type": "Question",
    name: "Which authentication methods are supported?",
    acceptedAnswer: {
      "@type": "Answer",
      text: "VVTerm supports password authentication, SSH keys, SSH keys with passphrase, plus Mosh, Tailscale SSH, and Cloudflare Tunnel SSH.",
    },
  },
  {
    "@type": "Question",
    name: "What are the system requirements?",
    acceptedAnswer: {
      "@type": "Answer",
      text: "VVTerm requires iOS 16 or later on iPhone and iPad, or macOS 13 Ventura or later on Apple Silicon Macs.",
    },
  },
  {
    "@type": "Question",
    name: "Does VVTerm include remote file browsing?",
    acceptedAnswer: {
      "@type": "Answer",
      text: "Yes. VVTerm includes a built-in SFTP file browser for browsing folders, previewing text, image, and video files, uploading and downloading, renaming or moving items, creating folders, and editing POSIX permissions on supported servers.",
    },
  },
];

export const softwareSchema = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "VVTerm",
  applicationCategory: "UtilitiesApplication",
  operatingSystem: "iOS 16+, macOS 13+",
  offers: [
    {
      "@type": "Offer",
      price: "0",
      priceCurrency: "USD",
      description: "Free tier with 1 workspace, 1 server",
    },
    {
      "@type": "Offer",
      price: "49.99",
      priceCurrency: "USD",
      description: "Lifetime Pro - unlimited everything",
    },
  ],
  description:
    "SSH terminal and SFTP remote file browser for iPhone, iPad, and Mac with standard SSH, Mosh, Tailscale SSH, and Cloudflare Tunnel SSH.",
  url: "https://vvterm.com/",
  image: "https://vvterm.com/og.png",
  author: {
    "@type": "Organization",
    name: "Vivy Technologies",
  },
  softwareVersion: "1.0",
  features: [
    "Standard SSH",
    "Mosh transport with SSH fallback",
    "Tailscale SSH",
    "Cloudflare Tunnel SSH",
    "SFTP remote file browser",
    "Inline text, image, and video previews",
    "Remote file upload, download, rename, move, and delete",
    "POSIX permission editing on supported servers",
    "iCloud sync",
    "Keychain security",
    "GPU terminal (libghostty)",
    "Multiple workspaces",
    "Environment filters",
    "Voice-to-command",
    "Multiple connection tabs",
  ],
};

export const websiteSchema = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      name: "VVTerm",
      url: "https://vvterm.com/",
    },
    {
      "@type": "Organization",
      name: "Vivy Technologies",
      url: "https://vvterm.com/",
      logo: "https://vvterm.com/logo.png",
    },
    {
      "@type": "FAQPage",
      mainEntity: faqSchema,
    },
  ],
};
