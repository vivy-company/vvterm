# Internationalization (i18n)

The site is statically rendered in each language at build time. English lives at the root
(`/mac`, `/guides/...`) and every other locale lives under its code (`/zh/mac`, `/zh/guides/...`).
Translated text ships in the HTML, so it's indexable, and each page only loads its own language.

Everything is driven by **one locale registry** — there are no `lang === "zh"` conditionals in
page or layout logic. Adding a language is creating locale-unique files plus two registration lines.

## Files

| File | Role |
| --- | --- |
| `src/i18n/locales.ts` | **Source of truth.** `LOCALES`, `DEFAULT_LOCALE`, `LOCALE_META` (label / htmlLang / ogLocale / hreflang). |
| `src/i18n/utils.ts` | Helpers: `getLocale(url)`, `localizePath(path, locale)`, `alternatePath(url, to)`, `useT(locale)`, `pickPage(id, locale)`, `sidebar(locale, kind)`. Registers each locale's chrome dict (`dicts`) and page-content dict (`pageDicts`). |
| `src/i18n/translations/<locale>.json` | **Shared chrome + home meta + docs/guides sidebar.** Header, footer, nav, CTA band, home strings, pricing, FAQ, and the `sidebar` namespace. |
| `src/i18n/pages/<locale>.json` | **Per-page content**, keyed by page id (`mac`, `features/mosh`, `docs/getting-started`, `pricingCards`, …). The English file is the translation source. |
| `astro.config.mjs` | Reads `LOCALES` / `DEFAULT_LOCALE` from `locales.ts` (routing updates automatically). |
| `src/pages/<locale>/**` | Thin per-locale route wrappers (e.g. `src/pages/zh/mac.astro` just renders the English page component; `Astro.currentLocale` resolves the locale from the URL). |

## How a page is localized

Page content lives in `src/i18n/pages/<locale>.json`, not in the `.astro` file. A page reads its
content for the active locale with `pickPage(id, lang)`, which merges the locale's entry over the
English one (so any key a translation omits falls back to English):

```astro
---
import { localizePath, pickPage } from "../i18n/utils";
const lang = (Astro.currentLocale ?? "en") as "en" | "zh";
const C = pickPage("mac", lang);   // -> src/i18n/pages/<lang>.json["mac"]
---
<h1 set:html={C.heroTitle} />
<a href={localizePath("/pricing", lang)}>{C.seePricing}</a>   {/* internal links MUST be wrapped */}
```

Rules:
- **Every internal `href`** (starts with `/`) goes through `localizePath(path, lang)`. External
  links (App Store, GitHub, Discord) stay as-is.
- Pass the **locale-agnostic** `canonicalPath` (e.g. `"/mac"`) to the layout — `BaseLayout`
  localizes the canonical URL and emits `hreflang` for every locale.
- Keep brand/product terms and shell commands in English (VVTerm, SSH, Mosh, Tailscale SSH,
  tmux, SFTP, iCloud, Keychain, `apt install mosh`, …). Keep HTML tags (`<strong>`, `<br />`) and
  placeholders like `{m}` intact when translating.
- Shared chrome strings (header/footer) use `useT(lang)("nav.key")`; the docs/guides sidebar comes
  from `sidebar(lang, kind)` (the `sidebar` namespace in the translations JSON).

## Adding a language (example: Japanese `ja`)

1. **Register it** in `src/i18n/locales.ts`:
   ```ts
   export const LOCALES = ["en", "zh", "ja"] as const;
   export const LOCALE_META = {
     …,
     ja: { label: "日本語", htmlLang: "ja", ogLocale: "ja_JP", hreflang: "ja" },
   };
   ```
2. **Register its dictionaries** in `src/i18n/utils.ts`:
   ```ts
   import ja from "./translations/ja.json";
   import jaPages from "./pages/ja.json";
   const dicts = { en, zh, ja };
   const pageDicts = { en: enPages, zh: zhPages, ja: jaPages };
   ```
3. **Translate two files** (copy the English file, translate the values):
   - `src/i18n/translations/ja.json` — chrome, home meta, and the `sidebar` namespace.
   - `src/i18n/pages/ja.json` — all page content.
4. **Create the routes**: copy the `src/pages/zh/**` wrapper tree to `src/pages/ja/**` (the
   wrappers are identical — they just render the English page component).
5. **Incremental is safe**: `pickPage` and `useT` fall back to English per missing key, so a
   partially-translated `ja.json` never breaks the build — untranslated bits render in English.

`astro.config.mjs`, `BaseLayout` (hreflang/`og:locale`), the footer language switcher, and the
docs sidebar all read from the registry, so steps 1–2 wire routing, SEO, and the switcher for the
new language with **zero** changes to any page component.
