import React from "react";
import { useLanguage } from "../i18n/LanguageContext";

export default function FAQSection() {
  const { t } = useLanguage();

  const highlightTerms = (text: string): string => {
    return text
      .replace(/VVTerm/g, '<span class="text-blue-400">VVTerm</span>')
      .replace(/libghostty/g, '<span class="text-[#30d158]">libghostty</span>')
      .replace(/Ghostty/g, '<span class="text-[#30d158]">Ghostty</span>')
      .replace(/iCloud/g, '<span class="text-[#5ac8fa]">iCloud</span>')
      .replace(/Keychain/g, '<span class="text-[#ffcc00]">Keychain</span>')
      .replace(/Apple Keychain/g, '<span class="text-[#ffcc00]">Apple Keychain</span>')
      .replace(/SSH/g, '<span class="text-[#ff9500]">SSH</span>')
      .replace(/MLX Whisper/g, '<span class="text-[#af52de]">MLX Whisper</span>')
      .replace(/App Store/g, '<span class="text-blue-400">App Store</span>')
      .replace(/Apple ID/g, '<span class="text-zinc-300">Apple ID</span>')
      .replace(/iOS 16\+/g, '<span class="text-blue-500">iOS 16+</span>')
      .replace(/macOS 13\+/g, '<span class="text-blue-500">macOS 13+</span>')
      .replace(/macOS 13\+ Ventura/g, '<span class="text-blue-500">macOS 13+ Ventura</span>')
      .replace(/Apple Silicon/g, '<span class="text-zinc-400">Apple Silicon</span>')
      .replace(/Intel Macs/g, '<span class="text-zinc-400">Intel Macs</span>')
      .replace(/iPhone/g, '<span class="text-zinc-300">iPhone</span>')
      .replace(/iPad/g, '<span class="text-zinc-300">iPad</span>')
      .replace(/Mac/g, '<span class="text-zinc-300">Mac</span>')
      .replace(/\$6\.49/g, '<span class="text-green-400">$6.49</span>')
      .replace(/\$19\.99/g, '<span class="text-green-400">$19.99</span>')
      .replace(/\$29\.99/g, '<span class="text-green-400">$29.99</span>')
      .replace(/30-day/g, '<span class="text-green-400">30-day</span>')
      .replace(/Esc/g, '<code class="text-[#89dceb] font-mono text-[15px]">Esc</code>')
      .replace(/Tab/g, '<code class="text-[#89dceb] font-mono text-[15px]">Tab</code>')
      .replace(/Ctrl/g, '<code class="text-[#89dceb] font-mono text-[15px]">Ctrl</code>');
  };

  return (
    <section className="py-20 px-6">
      <div className="max-w-[720px] mx-auto">
        <h2 className="text-[56px] font-semibold text-center mb-16 tracking-tight">{t("faq.title")}</h2>
        <div className="flex flex-col gap-8">
          {["q1", "q2", "q3", "q4", "q5", "q6", "q7", "q8", "q9"].map((qKey) => {
            const answer = t(`faq.${qKey}.answer`);

            return (
              <div key={qKey}>
                <h3 className="text-[21px] font-semibold mb-3 tracking-tight">{t(`faq.${qKey}.question`)}</h3>
                <p className="text-[#86868b] text-[17px] leading-[1.47059]">
                  <span dangerouslySetInnerHTML={{ __html: highlightTerms(answer) }} />
                </p>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
