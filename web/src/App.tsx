import React, { useState, lazy, Suspense } from "react";
import {
  Server,
  Terminal,
  Cloud,
  Lock,
  Mic,
  Folder,
  Layers,
  Key,
  Check,
} from "lucide-react";
import logo from "./logo.png";
import appStoreBadge from "./app-store-badge.svg";
import previewScreenshot from "./preview.png";
import { useLanguage, LanguageProvider } from "./i18n/LanguageContext";
import type { Language } from "./i18n/i18n";

declare global {
  interface Window {
    umami?: {
      track: (eventName: string) => void;
    };
  }
}

const APP_STORE_URL = "https://apps.apple.com/app/vvterm/id6757482822";

const FAQSection = lazy(() => import("./components/FAQSection"));

type BillingCycle = "monthly" | "yearly";

function LanguageSwitcher({ onLanguageChange }: { onLanguageChange?: (lang: string) => void }) {
  const { language, setLanguage, availableLanguages } = useLanguage();

  return (
    <select
      value={language}
      onChange={(e) => {
        const newLang = e.target.value as Language;
        setLanguage(newLang);
        onLanguageChange?.(newLang);
      }}
      className="bg-transparent border-none text-sm text-zinc-500 cursor-pointer hover:text-blue-500 transition-colors appearance-none"
    >
      {Object.entries(availableLanguages).map(([code, name]) => (
        <option key={code} value={code} className="bg-[#1d1d1f] text-white">
          {name}
        </option>
      ))}
    </select>
  );
}

function AppContent() {
  const { t } = useLanguage();
  const [billingCycle, setBillingCycle] = useState<BillingCycle>("yearly");
  const currentYear = new Date().getFullYear();

  const trackEvent = (eventName: string) => {
    if (typeof window !== "undefined" && window.umami) {
      window.umami.track(eventName);
    }
  };

  const features = [
    { icon: Server, bg: "rgba(0,122,255,0.1)", color: "#007aff", key: "servers", span: true },
    { icon: Terminal, bg: "rgba(48,209,88,0.1)", color: "#30d158", key: "terminal", span: true },
    { icon: Key, bg: "rgba(255,149,0,0.1)", color: "#ff9500", key: "ssh" },
    { icon: Cloud, bg: "rgba(90,200,250,0.1)", color: "#5ac8fa", key: "sync" },
    { icon: Folder, bg: "rgba(175,82,222,0.1)", color: "#af52de", key: "workspaces" },
    { icon: Mic, bg: "rgba(255,59,48,0.1)", color: "#ff3b30", key: "voice" },
    { icon: Layers, bg: "rgba(52,199,89,0.1)", color: "#34c759", key: "tabs", span: true },
    { icon: Lock, bg: "rgba(255,204,0,0.1)", color: "#ffcc00", key: "keychain", span: true },
  ];

  return (
    <div className="w-full overflow-x-hidden">

      {/* Hero Section */}
      <main className="relative text-center py-20 px-6 pb-10 bg-[radial-gradient(ellipse_80%_50%_at_50%_-20%,rgba(0,113,227,0.15),transparent)] animate-[gradient-shift_15s_ease-in-out_infinite]">
        <div className="max-w-[980px] mx-auto">
          <div className="inline-flex flex-col items-center mb-8 relative">
            <img src={logo} alt="VVTerm" className="w-32 h-32 rounded-[28px] drop-shadow-[0_0_40px_rgba(0,113,227,0.3)]" />
          </div>
          <h1 className="text-8xl font-semibold tracking-tight mb-6 leading-none">{t("hero.title")}</h1>
          <p className="text-[28px] text-[#86868b] mb-12">
            {t("hero.subtitle")}
          </p>
          <div className="flex flex-col sm:flex-row gap-4 justify-center items-center mb-6">
            <a
              href={APP_STORE_URL}
              target="_blank"
              rel="noopener noreferrer"
              onClick={() => trackEvent("appstore_click")}
              className="transition-opacity duration-200 hover:opacity-80"
            >
              <img src={appStoreBadge} alt="Download on the App Store" className="h-[52px] block rounded-[8px]" />
            </a>
          </div>
          <p className="text-sm text-[#86868b]">
            {t("hero.requirements")}
          </p>
        </div>
      </main>

      {/* Visual Showcase */}
      <section className="py-12 px-6 pb-20">
        <div className="max-w-[1200px] mx-auto">
          <div className="min-h-[520px] flex items-center justify-center">
            <img
              src={previewScreenshot}
              alt="VVTerm app preview"
              className="w-full block scale-115"
              fetchPriority="high"
              loading="eager"
              onError={(e) => {
                (e.target as HTMLImageElement).style.display = 'none';
              }}
            />
          </div>
        </div>
      </section>

      {/* Features Bento Grid */}
      <section className="py-20 px-6">
        <div className="max-w-[1200px] mx-auto">
          <h2 className="text-[56px] md:text-[56px] text-[36px] font-semibold text-center mb-16 tracking-tight">{t("features.title")}</h2>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
            {features.map((feature, i) => (
              <div
                key={i}
                className={`bg-white/[0.03] border border-white/8 rounded-3xl p-8 backdrop-blur-xl transition-all duration-300 hover:-translate-y-1.5 hover:shadow-[0_20px_40px_rgba(0,0,0,0.3)] hover:border-white/12 relative overflow-hidden group ${feature.span ? "md:col-span-2 lg:col-span-2" : ""}`}
              >
                <div className="absolute inset-0 bg-[radial-gradient(circle_at_50%_0%,rgba(0,113,227,0.1),transparent)] opacity-0 group-hover:opacity-100 transition-opacity duration-300" />
                <div
                  className="w-12 h-12 rounded-xl flex items-center justify-center mb-4 border border-white/8"
                  style={{ background: feature.bg }}
                >
                  <feature.icon size={24} color={feature.color} />
                </div>
                <h3 className="text-2xl font-semibold mb-3 tracking-tight">{t(`features.${feature.key}.title`)}</h3>
                <p className="text-[#86868b] text-[17px] leading-[1.47059]">{t(`features.${feature.key}.desc`)}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* How It Works */}
      <section className="py-20 px-6">
        <div className="max-w-[720px] mx-auto">
          <h2 className="text-[56px] font-semibold text-center mb-16 tracking-tight">{t("howItWorks.title")}</h2>
          <div className="flex flex-col gap-10">
            {[
              { num: "1", key: "step1" },
              { num: "2", key: "step2" },
              { num: "3", key: "step3" },
            ].map((step) => (
              <div key={step.num} className="flex gap-6 items-start">
                <span className="text-[40px] font-bold text-blue-500 font-mono min-w-[60px]">{step.num}</span>
                <div>
                  <h3 className="text-2xl font-semibold mb-2 tracking-tight">{t(`howItWorks.${step.key}.title`)}</h3>
                  <p className="text-[#86868b] text-[17px] leading-[1.47059]">{t(`howItWorks.${step.key}.desc`)}</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Pricing */}
      <section className="py-20 px-6">
        <div className="max-w-[1200px] mx-auto">
          <h2 className="text-[56px] font-semibold text-center mb-4 tracking-tight">{t("pricing.title")}</h2>
          <p className="text-[#86868b] text-center text-lg mb-16">{t("pricing.subtitle")}</p>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
            {/* Free Tier */}
            <div className="bg-white/[0.03] border border-white/8 rounded-3xl p-8 flex flex-col">
              <h3 className="text-2xl font-semibold mb-2">{t("pricing.free.name")}</h3>
              <p className="text-[#86868b] mb-6">{t("pricing.free.description")}</p>
              <div className="text-4xl font-bold mb-6">{t("pricing.free.price")}<span className="text-lg font-normal text-[#86868b]">{t("pricing.free.period")}</span></div>
              <ul className="space-y-3 mb-8 flex-1">
                {(t("pricing.free.features") as unknown as string[]).map((feature: string) => (
                  <li key={feature} className="flex items-center gap-3 text-[#86868b]">
                    <Check size={18} className="text-green-500 flex-shrink-0" />
                    {feature}
                  </li>
                ))}
              </ul>
              <a
                href={APP_STORE_URL}
                target="_blank"
                rel="noopener noreferrer"
                onClick={() => trackEvent("pricing_free_click")}
                className="block w-full py-3 text-center text-[17px] font-normal border border-white/20 text-white rounded-full hover:bg-white/5 transition-all duration-200"
              >
                {t("pricing.free.cta")}
              </a>
            </div>

            {/* Pro */}
            <div className="bg-white/[0.03] border border-white/8 rounded-3xl p-8 flex flex-col">
              <h3 className="text-2xl font-semibold mb-2">{t("pricing.pro.name")}</h3>
              <p className="text-[#86868b] mb-4">{t("pricing.pro.description")}</p>
              {/* Billing Toggle */}
              <div className="flex bg-white/[0.05] rounded-full p-1 mb-6">
                <button
                  onClick={() => { trackEvent("billing_toggle_monthly"); setBillingCycle("monthly"); }}
                  className={`flex-1 py-2 px-4 text-sm font-medium rounded-full transition-all duration-200 ${billingCycle === "monthly" ? "bg-white/10 text-white" : "text-[#86868b] hover:text-white"}`}
                >
                  Monthly
                </button>
                <button
                  onClick={() => { trackEvent("billing_toggle_yearly"); setBillingCycle("yearly"); }}
                  className={`flex-1 py-2 px-4 text-sm font-medium rounded-full transition-all duration-200 relative ${billingCycle === "yearly" ? "bg-white/10 text-white" : "text-[#86868b] hover:text-white"}`}
                >
                  Yearly
                  <span className="absolute -top-2 -right-2 px-1.5 py-0.5 text-[10px] font-semibold bg-green-500 text-white rounded-full">{t("pricing.pro.yearly.save")}</span>
                </button>
              </div>
              <div className="text-4xl font-bold mb-6">
                {billingCycle === "monthly" ? t("pricing.pro.monthly.price") : t("pricing.pro.yearly.price")}
                <span className="text-lg font-normal text-[#86868b]">{billingCycle === "monthly" ? t("pricing.pro.monthly.period") : t("pricing.pro.yearly.period")}</span>
              </div>
              <ul className="space-y-3 mb-8 flex-1">
                {(t("pricing.pro.features") as unknown as string[]).map((feature: string) => (
                  <li key={feature} className="flex items-center gap-3 text-[#86868b]">
                    <Check size={18} className="text-blue-500 flex-shrink-0" />
                    {feature}
                  </li>
                ))}
              </ul>
              <a
                href={APP_STORE_URL}
                target="_blank"
                rel="noopener noreferrer"
                onClick={() => trackEvent(billingCycle === "monthly" ? "pricing_pro_monthly_click" : "pricing_pro_yearly_click")}
                className="block w-full py-3 text-center text-[17px] font-normal border border-white/20 text-white rounded-full hover:bg-white/5 transition-all duration-200"
              >
                {billingCycle === "monthly" ? t("pricing.pro.ctaMonthly") : t("pricing.pro.ctaYearly")}
              </a>
            </div>

            {/* Lifetime */}
            <div className="bg-gradient-to-b from-blue-500/10 to-transparent border border-blue-500/30 rounded-3xl p-8 relative flex flex-col">
              <div className="absolute top-4 right-4 px-3 py-1 text-xs font-medium bg-blue-500 text-white rounded-full">
                {t("pricing.lifetime.badge")}
              </div>
              <h3 className="text-2xl font-semibold mb-2">{t("pricing.lifetime.name")}</h3>
              <p className="text-[#86868b] mb-6">{t("pricing.lifetime.description")}</p>
              <div className="text-4xl font-bold mb-6">{t("pricing.lifetime.price")}</div>
              <ul className="space-y-3 mb-8 flex-1">
                {(t("pricing.lifetime.features") as unknown as string[]).map((feature: string) => (
                  <li key={feature} className="flex items-center gap-3 text-[#86868b]">
                    <Check size={18} className="text-blue-500 flex-shrink-0" />
                    {feature}
                  </li>
                ))}
              </ul>
              <div>
                <a
                  href={APP_STORE_URL}
                  target="_blank"
                  rel="noopener noreferrer"
                  onClick={() => trackEvent("pricing_lifetime_click")}
                  className="block w-full py-3 text-center text-[17px] font-normal bg-blue-500 text-white rounded-full hover:bg-blue-600 transition-all duration-200"
                >
                  {t("pricing.lifetime.cta")}
                </a>
                <p className="text-xs text-[#86868b] text-center mt-4">{t("pricing.lifetime.guarantee")}</p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* FAQ */}
      <Suspense fallback={<div className="py-20 px-6"><div className="max-w-[720px] mx-auto text-center text-zinc-500">Loading...</div></div>}>
        <FAQSection />
      </Suspense>

      {/* Footer */}
      <footer className="py-12 px-6 border-t border-white/8 mt-20">
        <div className="max-w-[1200px] mx-auto flex flex-col md:flex-row justify-between items-center md:items-center gap-6">
          <p className="text-sm text-[#86868b] text-center md:text-left">© {currentYear} {t("footer.copyright")}</p>
          <div className="flex flex-col sm:flex-row gap-4 sm:gap-6 items-center">
            <a href="https://discord.gg/zemMZtrkSb" onClick={() => trackEvent("discord_click")} className="text-sm text-zinc-500 hover:text-blue-500 transition-colors duration-200" target="_blank" rel="noopener noreferrer">
              {t("footer.discord")}
            </a>
            <span className="text-zinc-700 hidden sm:inline">|</span>
            <a href="/privacy" className="text-sm text-zinc-500 hover:text-blue-500 transition-colors duration-200">
              Privacy
            </a>
            <a href="/terms" className="text-sm text-zinc-500 hover:text-blue-500 transition-colors duration-200">
              Terms
            </a>
            <a href="/refund" className="text-sm text-zinc-500 hover:text-blue-500 transition-colors duration-200">
              Refunds
            </a>
            <a href="/support" className="text-sm text-zinc-500 hover:text-blue-500 transition-colors duration-200">
              Support
            </a>
            <span className="text-zinc-700 hidden sm:inline">|</span>
            <LanguageSwitcher onLanguageChange={(lang) => trackEvent(`language_change_${lang}`)} />
          </div>
        </div>
      </footer>
    </div>
  );
}

export function App() {
  return (
    <LanguageProvider>
      <AppContent />
    </LanguageProvider>
  );
}

export default App;
