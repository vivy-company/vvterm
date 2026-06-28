import { defineConfig } from "astro/config";
import icon from "astro-icon";
import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";
import { LOCALES, DEFAULT_LOCALE } from "./src/i18n/locales.ts";

export default defineConfig({
  integrations: [
    icon(),
    // Auto-generates sitemap-index.xml from every built route, so it never goes stale.
    sitemap(),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
  site: "https://vvterm.com",
  output: "static",
  // English at /, Chinese at /zh/. Pages are authored per-locale; Astro.currentLocale
  // resolves from the URL so the shared chrome localizes automatically.
  i18n: {
    locales: [...LOCALES],
    defaultLocale: DEFAULT_LOCALE,
    routing: {
      prefixDefaultLocale: false,
      redirectToDefaultLocale: false,
    },
  },
  build: {
    format: "directory",
  },
});
