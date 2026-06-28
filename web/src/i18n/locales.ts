// ─────────────────────────────────────────────────────────────────────────────
// SINGLE SOURCE OF TRUTH FOR LOCALES.
// To add a language (see src/i18n/README.md for detail). Nothing in the page components
// needs to change — untranslated strings fall back to the default locale:
//   1. Add its code to LOCALES below and a LOCALE_META entry.
//   2. In utils.ts: import `./translations/xx.json` + `./pages/xx.json` and register them
//      in `dicts` and `pageDicts`.
//   3. Translate `src/i18n/translations/xx.json` (chrome/home/sidebar) and
//      `src/i18n/pages/xx.json` (page content).
//   4. Create the `/xx/` route wrappers (copy the `src/pages/zh/**` tree).
// astro.config.mjs reads LOCALES/DEFAULT_LOCALE from here, so routing updates automatically.
// ─────────────────────────────────────────────────────────────────────────────

export const LOCALES = ["en", "zh", "ja", "ko", "th", "vi", "pl", "es", "uk", "ru", "be", "de"] as const;
export type Locale = (typeof LOCALES)[number];

export const DEFAULT_LOCALE: Locale = "en";

export const LOCALE_META: Record<Locale, { label: string; htmlLang: string; ogLocale: string; hreflang: string }> = {
  en: { label: "English", htmlLang: "en", ogLocale: "en_US", hreflang: "en" },
  zh: { label: "中文", htmlLang: "zh-CN", ogLocale: "zh_CN", hreflang: "zh-Hans" },
  ja: { label: "日本語", htmlLang: "ja", ogLocale: "ja_JP", hreflang: "ja" },
  ko: { label: "한국어", htmlLang: "ko", ogLocale: "ko_KR", hreflang: "ko" },
  th: { label: "ไทย", htmlLang: "th", ogLocale: "th_TH", hreflang: "th" },
  vi: { label: "Tiếng Việt", htmlLang: "vi", ogLocale: "vi_VN", hreflang: "vi" },
  pl: { label: "Polski", htmlLang: "pl", ogLocale: "pl_PL", hreflang: "pl" },
  es: { label: "Español", htmlLang: "es", ogLocale: "es_ES", hreflang: "es" },
  uk: { label: "Українська", htmlLang: "uk", ogLocale: "uk_UA", hreflang: "uk" },
  ru: { label: "Русский", htmlLang: "ru", ogLocale: "ru_RU", hreflang: "ru" },
  be: { label: "Беларуская", htmlLang: "be", ogLocale: "be_BY", hreflang: "be" },
  de: { label: "Deutsch", htmlLang: "de", ogLocale: "de_DE", hreflang: "de" },
};

export const isLocale = (value: string): value is Locale => (LOCALES as readonly string[]).includes(value);
