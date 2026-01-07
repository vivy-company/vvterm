import en from "./translations/en.json";
import zh from "./translations/zh.json";

export type Language = "en" | "zh";

export const languages: Record<Language, string> = {
  en: "English",
  zh: "中文",
};

export const translations: Record<Language, typeof en> = {
  en,
  zh,
};

const STORAGE_KEY = "vvterm-language";

export function detectLanguage(): Language {
  if (typeof window === "undefined") return "en";
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored && (stored === "en" || stored === "zh")) {
    return stored as Language;
  }
  const browserLang = navigator.language.toLowerCase();
  if (browserLang.startsWith("zh")) {
    return "zh";
  }
  return "en";
}

export function saveLanguage(lang: Language): void {
  localStorage.setItem(STORAGE_KEY, lang);
}

export function getTranslation(lang: Language, key: string): string {
  const keys = key.split(".");
  let value: any = translations[lang];

  for (const k of keys) {
    value = value?.[k];
    if (value === undefined) {
      value = translations.en;
      for (const k2 of keys) {
        value = value?.[k2];
      }
      break;
    }
  }

  return value || key;
}
