# Internationalization (i18n)

The site is statically rendered in each language at build time. English lives at the root
(`/mac`, `/guides/...`) and every other locale lives under its code (`/zh/mac`, `/zh/guides/...`).
Chinese text ships in the HTML, so it's indexable, and each page only loads its own language.

Everything is driven by **one locale registry** — there are no `lang === "zh"` conditionals in
page or layout logic.

## Files

| File | Role |
| --- | --- |
| `src/i18n/locales.ts` | **Source of truth.** `LOCALES`, `DEFAULT_LOCALE`, `LOCALE_META` (label / htmlLang / ogLocale / hreflang). |
| `src/i18n/utils.ts` | Helpers: `getLocale(url)`, `localizePath(path, locale)`, `alternatePath(url, to)`, `useT(locale)`, `pick(dict, locale)`. Registers each locale's chrome dictionary in `dicts`. |
| `src/i18n/translations/<locale>.json` | Shared-chrome + home strings (header, footer nav, CTA band, home page, FAQ, pricing). |
| `astro.config.mjs` | Reads `LOCALES` / `DEFAULT_LOCALE` from `locales.ts` (routing updates automatically). |
| `src/pages/<locale>/**` | Thin per-locale route wrappers (e.g. `src/pages/zh/mac.astro` just renders the English page; `Astro.currentLocale` resolves the locale from the URL). |
| `src/lib/nav.ts` → `SIDEBAR_I18N` | Locale-keyed sidebar titles for the docs/guides `DocsLayout`. |

## How a page is localized

Each page reads its locale and selects copy from a **local dictionary**, falling back to the
default language for any missing branch:

```astro
---
import { localizePath, pick } from "../i18n/utils";
const lang = (Astro.currentLocale ?? "en") as "en" | "zh";
const C = pick({
  en: { heroTitle: "A real terminal for your Mac." },
  zh: { heroTitle: "为你的 Mac 打造的真正的终端。" },
}, lang);
---
<h1>{C.heroTitle}</h1>
<a href={localizePath("/pricing", lang)}>…</a>   {/* internal links MUST be wrapped */}
```

Rules:
- **Every internal `href`** (starts with `/`) goes through `localizePath(path, lang)`. External
  links (App Store, GitHub, Discord) stay as-is.
- Pass the **locale-agnostic** `canonicalPath` (e.g. `"/mac"`) to the layout — `BaseLayout`
  localizes the canonical URL and emits `hreflang` for every locale.
- Keep brand/product terms and shell commands in English (VVTerm, SSH, Mosh, Tailscale SSH,
  tmux, SFTP, iCloud, Keychain, `apt install mosh`, …).
- Shared chrome strings (header/footer) use `useT(lang)("nav.key")` from the JSON dictionaries.

## Adding a language (example: Japanese `ja`)

1. **Register it** in `src/i18n/locales.ts`:
   ```ts
   export const LOCALES = ["en", "zh", "ja"] as const;
   export const LOCALE_META = {
     …,
     ja: { label: "日本語", htmlLang: "ja", ogLocale: "ja_JP", hreflang: "ja" },
   };
   ```
2. **Register its dictionary** in `src/i18n/utils.ts`:
   ```ts
   import ja from "./translations/ja.json";
   const dicts = { en, zh, ja };
   ```
3. **Translate** `src/i18n/translations/ja.json` (copy `en.json`, translate the values) and add a
   `ja:` block to `SIDEBAR_I18N` in `src/lib/nav.ts`.
4. **Create the routes**: copy the `src/pages/zh/**` wrapper tree to `src/pages/ja/**` (the
   wrappers are identical — they just import the English page component).
5. **Translate page copy incrementally**: add a `ja:` branch to each page's local dictionary.
   Until a page has one, `pick()` renders the **default language** for it — so the build never
   breaks and you can ship translations one page at a time.

`astro.config.mjs`, `BaseLayout` (hreflang/`og:locale`), the footer language switcher, and the
docs sidebar all read from the registry, so steps 1–2 wire routing, SEO, and the switcher for the
new language with **zero** changes to any page component.
