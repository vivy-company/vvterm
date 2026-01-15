import React from "react";

export function PrivacyPage() {
  return (
    <div className="min-h-screen px-6 py-20">
      <div className="max-w-[800px] mx-auto">
        <a href="/" className="inline-block mb-8">
          <img src="/logo.png" alt="VVTerm" className="w-12 h-12 rounded-xl" />
        </a>
        <h1 className="text-4xl font-semibold tracking-tight mb-2">Privacy Policy</h1>
        <p className="text-[#86868b] mb-8">Last updated: January 15, 2026</p>

        <div className="prose prose-invert max-w-none space-y-6 text-[#86868b]">
          <section>
            <h2 className="text-xl font-semibold text-white mb-3">1. Introduction</h2>
            <p>
              Vivy Technologies Co., Limited ("we", "our", or "us") operates VVTerm, an SSH terminal application for iOS and macOS.
              This Privacy Policy explains how we collect, use, and protect your information.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">2. Information We Collect</h2>
            <h3 className="text-lg font-medium text-white mb-2">Server Configurations</h3>
            <p>
              VVTerm stores your server configurations (host, port, username) locally and syncs them via iCloud to your other devices.
              This data is encrypted in transit and at rest by Apple's iCloud infrastructure.
            </p>
            <h3 className="text-lg font-medium text-white mb-2 mt-4">Credentials</h3>
            <p>
              SSH passwords and private keys are stored in Apple Keychain. If iCloud sync is enabled, credentials sync via iCloud Keychain
              across your devices. We never receive these credentials, and they are protected by your device's security (Face ID, Touch ID, or passcode).
            </p>
            <h3 className="text-lg font-medium text-white mb-2 mt-4">Analytics Data</h3>
            <p>
              We use Umami Analytics, a privacy-focused analytics service, to collect anonymous usage statistics on our website.
              No personal information is collected or stored.
            </p>
            <h3 className="text-lg font-medium text-white mb-2 mt-4">Purchase Information</h3>
            <p>
              If you purchase VVTerm Pro, your purchase is processed through the App Store. We receive confirmation of your purchase
              but do not have access to your payment details.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">3. How We Use Your Information</h2>
            <ul className="list-disc list-inside space-y-1">
              <li>To provide and maintain the app functionality</li>
              <li>To sync server configurations across your devices via iCloud</li>
              <li>To verify Pro subscription status</li>
              <li>To improve our website and application</li>
            </ul>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">4. Data Storage and Security</h2>
            <p>
              Server configurations are synced via Apple iCloud, subject to Apple's security measures.
              Credentials are stored in Apple Keychain and may sync via iCloud Keychain when enabled. We do not operate our own servers to store your data.
              We do not sell or share your personal information with third parties.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">5. Your Rights</h2>
            <p>You have the right to:</p>
            <ul className="list-disc list-inside space-y-1 mt-2">
              <li>Delete all app data by removing VVTerm from your devices</li>
              <li>Disable iCloud sync in Settings to keep data local only</li>
              <li>Remove stored credentials from Keychain at any time</li>
              <li>Request information about data we may have collected</li>
            </ul>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">6. Contact Us</h2>
            <p>
              If you have questions about this Privacy Policy, please contact us at:{" "}
              <a href="mailto:vvterm@vivy.company" className="text-blue-500 hover:underline">vvterm@vivy.company</a>
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
