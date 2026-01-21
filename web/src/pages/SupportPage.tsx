import React from "react";

export function SupportPage() {
  return (
    <div className="min-h-screen px-6 py-20">
      <div className="max-w-[800px] mx-auto">
        <a href="/" className="inline-block mb-8">
          <img src="/logo.png" alt="VVTerm" className="w-12 h-12 rounded-xl" />
        </a>
        <h1 className="text-4xl font-semibold tracking-tight mb-2">Support</h1>
        <p className="text-[#86868b] mb-8">We’re here to help with any questions about VVTerm.</p>

        <div className="prose prose-invert max-w-none space-y-6 text-[#86868b]">
          <section>
            <h2 className="text-xl font-semibold text-white mb-3">Contact</h2>
            <p>
              Email us at{" "}
              <a href="mailto:vvterm@vivy.company" className="text-blue-500 hover:underline">
                vvterm@vivy.company
              </a>
              . We typically respond within 1–2 business days.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">App Support</h2>
            <p>Please include the following so we can help faster:</p>
            <ul className="list-disc list-inside space-y-1 mt-2">
              <li>Device model and OS version</li>
              <li>VVTerm app version</li>
              <li>Steps to reproduce the issue</li>
              <li>Any relevant screenshots or logs</li>
            </ul>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">Billing & Subscriptions</h2>
            <p>
              Purchases are handled by the App Store. If you have billing questions, you can contact us
              or manage subscriptions in your Apple ID settings.
            </p>
          </section>
        </div>

        <div className="mt-12 pt-8 border-t border-white/8">
          <a href="/" className="text-blue-500 hover:underline">← Back to Home</a>
        </div>
      </div>
    </div>
  );
}
