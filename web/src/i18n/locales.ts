// ─────────────────────────────────────────────────────────────────────────────
// SINGLE SOURCE OF TRUTH FOR LOCALES.
// To add a language, do these (and nothing in the page components needs to change
// for the build to stay green — untranslated strings fall back to the default):
//   1. Add its code to LOCALES below and a LOCALE_META entry.
//   2. Add `import xx from "./translations/xx.json"` + register it in `dicts` in utils.ts.
//   3. Translate `src/i18n/translations/xx.json` (chrome/shared strings).
//   4. Add a per-page `xx:` branch to each page's local dictionary as you translate it
//      (missing branches render the default language until you do).
//   5. Create the `/xx/` route wrappers (copy the `src/pages/zh/**` tree).
// astro.config.mjs reads LOCALES/DEFAULT_LOCALE from here, so routing updates automatically.
// ─────────────────────────────────────────────────────────────────────────────

export const LOCALES = ["en", "zh"] as const;
export type Locale = (typeof LOCALES)[number];

export const DEFAULT_LOCALE: Locale = "en";

export const LOCALE_META: Record<Locale, { label: string; htmlLang: string; ogLocale: string; hreflang: string }> = {
  en: { label: "English", htmlLang: "en", ogLocale: "en_US", hreflang: "en" },
  zh: { label: "中文", htmlLang: "zh-CN", ogLocale: "zh_CN", hreflang: "zh-Hans" },
};

export const isLocale = (value: string): value is Locale => (LOCALES as readonly string[]).includes(value);
