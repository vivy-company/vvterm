import en from "./translations/en.json";
import zh from "./translations/zh.json";
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
const dicts: Record<Locale, Record<string, unknown>> = { en, zh };

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
