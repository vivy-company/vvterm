import en from "./translations/en.json";
import zh from "./translations/zh.json";
import enPages from "./pages/en.json";
import zhPages from "./pages/zh.json";
import es from "./translations/es.json";
import esPages from "./pages/es.json";
import pl from "./translations/pl.json";
import plPages from "./pages/pl.json";
import vi from "./translations/vi.json";
import viPages from "./pages/vi.json";
import th from "./translations/th.json";
import thPages from "./pages/th.json";
import ko from "./translations/ko.json";
import koPages from "./pages/ko.json";
import ja from "./translations/ja.json";
import jaPages from "./pages/ja.json";
import { LOCALES, DEFAULT_LOCALE, LOCALE_META, isLocale, type Locale } from "./locales";

export { LOCALES, DEFAULT_LOCALE, LOCALE_META, type Locale };
// Back-compat aliases (older code imports these names).
export type Lang = Locale;
export const DEFAULT_LANG = DEFAULT_LOCALE;
export const LANG_LABELS: Record<Locale, string> = Object.fromEntries(
  LOCALES.map((l) => [l, LOCALE_META[l].label]),
) as Record<Locale, string>;
export const HTML_LANG: Record<Locale, string> = Object.fromEntries(
  LOCALES.map((l) => [l, LOCALE_META[l].htmlLang]),
) as Record<Locale, string>;

// Register every locale's shared-chrome dictionary here (the ONE place to add a language).
const dicts: Record<Locale, Record<string, unknown>> = { en, zh, ja, ko, th, vi, pl, es };
// Per-page content dictionaries, keyed by page id (e.g. "mac", "features/mosh"). Register new locales here too.
type PageDict = Record<string, Record<string, unknown>>;
const pageDicts: Partial<Record<Locale, PageDict>> = { en: enPages, zh: zhPages, ja: jaPages, ko: koPages, th: thPages, vi: viPages, pl: plPages, es: esPages };

/** A page's content for `locale`, with the default-locale dictionary filling any keys the translation omits. */
export function pickPage(id: string, locale: Locale): any {
  const base = (pageDicts[DEFAULT_LOCALE] as PageDict)[id] ?? {};
  if (locale === DEFAULT_LOCALE) return base;
  const override = pageDicts[locale]?.[id];
  return override ? { ...base, ...override } : base;
}

/** Active locale from the URL: the first path segment if it is a non-default locale, else the default. */
export function getLocale(url: URL): Locale {
  const seg = url.pathname.split("/")[1] ?? "";
  return isLocale(seg) && seg !== DEFAULT_LOCALE ? seg : DEFAULT_LOCALE;
}
// Back-compat alias.
export const getLang = getLocale;

/** Prefix an internal path with the locale (default locale stays at root). */
export function localizePath(path: string, locale: Locale): string {
  if (locale === DEFAULT_LOCALE || !path.startsWith("/")) return path;
  return path === "/" ? `/${locale}/` : `/${locale}${path}`;
}

/** The current page's path in another locale (for the language switcher / hreflang). */
export function alternatePath(url: URL, to: Locale): string {
  let path = url.pathname;
  for (const l of LOCALES) {
    if (l === DEFAULT_LOCALE) continue;
    if (path === `/${l}` || path.startsWith(`/${l}/`)) {
      path = path.slice(l.length + 1) || "/";
      break;
    }
  }
  return localizePath(path, to);
}

/** The full shared-chrome dictionary for a locale (default-locale dict as fallback for an unregistered locale). */
export function chrome(locale: Locale): typeof en {
  return (dicts[locale] ?? dicts[DEFAULT_LOCALE]) as typeof en;
}

/** Look up a dotted key in the shared dictionary for `locale`, falling back to the default, then the key. */
export function useT(locale: Locale) {
  const read = (dict: Record<string, unknown>, key: string) =>
    key.split(".").reduce<unknown>((o, k) => (o == null ? o : (o as Record<string, unknown>)[k]), dict);
  return (key: string): string => {
    const v = read(dicts[locale], key);
    if (typeof v === "string") return v;
    const fallback = read(dicts[DEFAULT_LOCALE], key);
    return typeof fallback === "string" ? fallback : key;
  };
}

/** Pick a locale's branch from a per-page dictionary, falling back to the default locale. */
export function pick<T>(dict: Partial<Record<Locale, T>>, locale: Locale): T {
  return (dict[locale] ?? dict[DEFAULT_LOCALE]) as T;
}

type SidebarEntry = { title: string; group: string };
/** Localized docs/guides sidebar labels, per slug, with default-locale titles/groups as fallback. */
export function sidebar(locale: Locale, kind: "docs" | "guides"): Record<string, SidebarEntry> {
  const read = (l: Locale) => ((dicts[l] as { sidebar?: Record<string, Record<string, SidebarEntry>> }).sidebar?.[kind]) ?? {};
  const base = read(DEFAULT_LOCALE);
  const over = read(locale);
  return Object.fromEntries(Object.keys(base).map((slug) => [slug, { ...base[slug], ...(over[slug] ?? {}) } as SidebarEntry]));
}
